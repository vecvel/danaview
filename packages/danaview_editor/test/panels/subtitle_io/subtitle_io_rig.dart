// OWNER: UX-32
//
// A rig for the SRT/VTT import and export tests: the editor harness with a real EditorController
// opened over FakeEditorEngine at 30 fps and the real inspector (so the captions panel opens after
// an import), plus a [SubtitleIoEnvironment] over an in-memory file system under `/mem` roots, the
// fake engine's picker, a [RecordingHandoff] and an inline parser (the isolate parser is tested
// on its own with real async).
//
// Lanes (bottom to top): the main video lane (one 60 s clip), the locked subtitle lane "Locked"
// (one cue), the subtitle lane "English" (en; cues 0–2 s "Bee one", 3–5 s "Bee two") and the
// topmost lane "Auto" (fr; generated cues 1–3 s "Bonjour", 4–6 s "Salut"). `subtitles: false`
// leaves only the main lane.

import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/panels/subtitle_io.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/formats.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart' show MemoryStoreFs;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import '../../inspector/inspector_rig.dart' show RegionFrame, RigTicker;
import '../../support/support.dart';

export '../../inspector/inspector_rig.dart' show RegionFrame;

const int s = microsPerSecond;

/// The fake roots of the rig.
const StoreRoots memRoots = StoreRoots(support: '/mem/support', cache: '/mem/cache', documents: '/mem/documents');

/// The bytes of fixture [name] (copied from the core corpus).
Uint8List fixture(String name) => File('test/panels/subtitle_io/fixtures/$name').readAsBytesSync();

/// Ids of the rig's project.
abstract final class Io {
  static const TrackId main = TrackId('tr_main');
  static const TrackId locked = TrackId('tr_locked');
  static const TrackId english = TrackId('tr_en');
  static const TrackId auto = TrackId('tr_auto');
}

SubtitleCue _cue(String id, TimeUs start, TimeUs end, String text, {CueOrigin origin = CueOrigin.manual}) =>
    SubtitleCue(id: ItemId(id), start: start, duration: end - start, text: text, origin: origin);

MediaAsset _asset(String id) => MediaAsset(
      id: MediaId(id),
      kind: MediaKind.video,
      displayName: '$id.file',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(kind: MediaKind.video, duration: 600 * s, hasVideo: true, hasAudio: true, width: 1920, height: 1080),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

/// The rig's project ("My Film").
EditProject ioProject(ProjectId id, {bool subtitles = true}) => EditProject(
      id: id,
      meta: ProjectMeta(name: 'My Film', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(
        tracks: [
          Track(id: Io.main, kind: TrackKind.video, isMain: true, items: [
            MediaClip(id: const ItemId('it_main'), start: 0, duration: 60 * s, media: const MediaId('m_a'), visual: const VisualProps()),
          ]),
          if (subtitles) ...[
            Track(
              id: Io.locked,
              kind: TrackKind.subtitle,
              name: 'Locked',
              locked: true,
              subtitle: const SubtitleTrackData(),
              items: [_cue('cu_l1', 0, 2 * s, 'Locked cue')],
            ),
            Track(
              id: Io.english,
              kind: TrackKind.subtitle,
              name: 'English',
              subtitle: const SubtitleTrackData(language: 'en'),
              items: [_cue('cu_e1', 0, 2 * s, 'Bee one'), _cue('cu_e2', 3 * s, 5 * s, 'Bee two')],
            ),
            Track(
              id: Io.auto,
              kind: TrackKind.subtitle,
              name: 'Auto',
              subtitle: const SubtitleTrackData(language: 'fr'),
              items: [
                _cue('cu_a1', 1 * s, 3 * s, 'Bonjour', origin: CueOrigin.generated),
                _cue('cu_a2', 4 * s, 6 * s, 'Salut', origin: CueOrigin.generated),
              ],
            ),
          ],
        ],
      ),
      pool: MediaPool({const MediaId('m_a'): _asset('m_a')}),
    );

/// One handoff call.
typedef HandoffCall = ({String kind, String path, String? name, Uint8List bytes});

/// A [FileHandoff] that records the path, name and the file's content at the time of the call.
final class RecordingHandoff implements FileHandoff {
  /// Creates the fake over [fs].
  RecordingHandoff(this.fs);

  /// Where the exported file is read from.
  final MemoryStoreFs fs;

  /// What the next call returns.
  FileHandoffOutcome next = FileHandoffOutcome.done;

  /// Calls received.
  final List<HandoffCall> calls = [];

  Future<FileHandoffResult> _record(String kind, String path, String? name) async {
    calls.add((kind: kind, path: path, name: name, bytes: await fs.readBytes(path)));
    return FileHandoffResult(next);
  }

  @override
  Future<FileHandoffResult> saveToFiles(String path, String suggestedName) => _record('files', path, suggestedName);

  @override
  Future<FileHandoffResult> share(String path) => _record('share', path, null);

  @override
  Future<FileHandoffResult> saveToPhotos(String path) => _record('photos', path, null);
}

/// An environment over [fs] for unit tests.
SubtitleIoEnvironment memEnvironment(MemoryStoreFs fs, {MediaPicker? picker, FileHandoff? files, SubtitleParser? parse}) {
  [memRoots.support, memRoots.cache, memRoots.documents].forEach(fs.mkdirs);
  var n = 0;
  return SubtitleIoEnvironment(
    picker: picker ?? FakeMediaPicker(),
    files: files ?? RecordingHandoff(fs),
    fs: fs,
    deleter: OwnedFileDeleter(memRoots, fs: fs, assertOnViolation: false),
    workDir: memRoots.workDir,
    parse: parse ?? (bytes, hint) async => SubtitleCodec.parse(bytes, hint: hint),
    newToken: () => 't${n++}',
  );
}

/// The editor around the real inspector with the subtitle IO environment in memory.
class SubtitleIoRig {
  SubtitleIoRig._(this.harness, this.id, this.tester, this.fs, this.handoff);

  /// Harness.
  final EditorTestHarness harness;

  /// Project id.
  final ProjectId id;

  /// Tester.
  final WidgetTester tester;

  /// The in-memory files.
  final MemoryStoreFs fs;

  /// The recording handoff.
  final RecordingHandoff handoff;

  /// The fake engine.
  FakeEditorEngine get engine => harness.engine;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The working project.
  EditProject get project => state.project!;

  /// The history position.
  int get entries => state.history.position;

  /// The subtitle tracks, bottom to top.
  List<Track> get subtitleTracks => [for (final t in project.tracks) if (t.kind == TrackKind.subtitle) t];

  /// The track [t].
  Track track(TrackId t) => project.tracks.firstWhere((x) => x.id == t);

  /// The cues of [t].
  List<SubtitleCue> cues(TrackId t) => [for (final i in track(t).items) i as SubtitleCue];

  /// Puts [bytes] at `/mem/picks/<name>` and makes the picker return it next.
  PickedMedia offer(String name, Uint8List bytes, {bool temporary = false}) {
    final path = temporary ? '${memRoots.workDir}/picks/u1/$name' : '/mem/user/$name';
    fs.putFile(path, bytes);
    final picked = PickedMedia(uri: Uri.file(path).toString(), displayName: name, isTemporaryCopy: temporary, sizeBytes: bytes.length);
    engine.picker.nextPicks = [picked];
    return picked;
  }

  /// A context for invoking actions.
  WidgetActionContext actionContext({EditorActionSource source = EditorActionSource.button}) => WidgetActionContext.container(
        projectId: id,
        context: tester.element(find.byType(RegionFrame)),
        container: container,
        source: source,
      );

  /// The action [action]'s spec.
  EditorActionSpec spec(EditorActionId action) => container.read(editorActionRegistryProvider).spec(action);

  /// Invokes [action] and lets the picker, the parse and the sheet's entrance finish.
  Future<EditorActionResult> invoke(EditorActionId action) async {
    final r = container.read(editorActionRegistryProvider).invoke(action, actionContext());
    await settle();
    return r;
  }

  /// Pumps until the sheet transitions are done.
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Lets a toast run out.
  Future<void> drainToasts() async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
  }

  /// Taps [finder] and settles.
  Future<void> tap(Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await settle();
  }

  /// Pumps the panel host and opens the editor.
  static Future<SubtitleIoRig> pump(
    WidgetTester tester, {
    EditorSurface surface = const EditorSurface(Size(1280, 900)),
    bool subtitles = true,
    TrackId? selectLane,
  }) async {
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('My Film');
    final project = ioProject(empty.id, subtitles: subtitles);
    repo.seed(project);
    final ticker = RigTicker();
    final fs = MemoryStoreFs();
    final handoff = RecordingHandoff(fs);
    final engine = FakeEditorEngine(validatePlans: false);
    final env = memEnvironment(fs, picker: engine.picker, files: handoff);
    final harness = EditorTestHarness(
      engine: engine,
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
        subtitleIoEnvironmentProvider.overrideWithValue(env),
      ],
    );
    final rig = SubtitleIoRig._(harness, project.id, tester, fs, handoff);
    EditorAnnouncer.instance.reset();
    addTearDown(EditorAnnouncer.instance.reset);
    await harness.pumpApp(
      tester,
      EditorScope(
        projectId: project.id,
        child: const RegionFrame(
          inspectorOpen: true,
          regions: {EditorRegion.pane: InspectorHost()},
          dock: InspectorDock(),
        ),
      ),
      surface: surface,
    );
    await tester.runAsync(() async {
      await rig.editor.open();
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    if (selectLane != null) rig.editor.selectAt(selectLane, -1);
    await tester.pump();
    return rig;
  }
}
