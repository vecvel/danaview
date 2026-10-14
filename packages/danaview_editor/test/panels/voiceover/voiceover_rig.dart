// OWNER: UX-34
//
// A rig for the voiceover panel tests: the editor harness with a real EditorController opened over
// FakeEditorEngine (its FakeVoiceRecorder scripts permissions, levels, interruptions and the
// recorded file) and a [RecordingPool] that imports recordings like the real media pool (a
// project-owned `MediaKind.recording` asset kept in `assets/recordings/`, added as a sticky
// `AddAssets`). The project (30 fps) has a 12 s main video, a music lane and, optionally, a voice
// lane whose clip covers 0-4 s. The panel sits in the inspector region of the real InspectorHost /
// InspectorDock.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/panels/voiceover_panel.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditSession;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MicPermission;
import 'package:danaview_editor_engine_api/testing.dart';

import '../../inspector/inspector_rig.dart' show RegionFrame, RigTicker;
import '../../support/support.dart';

export '../../inspector/inspector_rig.dart' show RegionFrame;

const int s = microsPerSecond;

/// Ids of the rig's project.
abstract final class VoIds {
  /// Main video clip 0-12 s.
  static const ItemId video = ItemId('it_video');

  /// Music clip 0-10 s.
  static const ItemId music = ItemId('it_music');

  /// Voice clip 0-4 s on [voiceLane] (with `voiceLane: true`).
  static const ItemId voice = ItemId('it_voice');

  /// The main lane.
  static const TrackId main = TrackId('tr_main');

  /// The music lane.
  static const TrackId musicLane = TrackId('tr_music');

  /// The existing voice lane.
  static const TrackId voiceLane = TrackId('tr_voice');
}

/// The folder the rig records into.
String recordingsDirOf(ProjectId id) => '/fake/support/danaview/editor/projects/${id.value}/assets/recordings';

MediaAsset _asset(String id, MediaKind kind) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: '$id.file',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: 60 * s,
        hasVideo: kind == MediaKind.video,
        hasAudio: true,
        width: kind == MediaKind.video ? 1920 : null,
        height: kind == MediaKind.video ? 1080 : null,
      ),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

MediaClip _clip(String id, String media, TimeUs start, TimeUs duration, {bool visual = true}) => MediaClip(
      id: ItemId(id),
      start: start,
      duration: duration,
      media: MediaId(media),
      visual: visual ? const VisualProps() : null,
    );

/// The project of the rig.
EditProject voiceoverProject(ProjectId id, {bool voiceLane = false, bool ripple = true, TimeUs playhead = 0}) => EditProject(
      id: id,
      meta: ProjectMeta(name: 'Voiceover', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(
        tracks: [
          Track(id: VoIds.main, kind: TrackKind.video, isMain: true, items: [_clip('it_video', 'm_video', 0, 12 * s)]),
          Track(
            id: VoIds.musicLane,
            kind: TrackKind.audio,
            audioRole: AudioRole.music,
            items: [_clip('it_music', 'm_song', 0, 10 * s, visual: false)],
          ),
          if (voiceLane)
            Track(
              id: VoIds.voiceLane,
              kind: TrackKind.audio,
              audioRole: AudioRole.voice,
              items: [_clip('it_voice', 'm_song', 0, 4 * s, visual: false)],
            ),
        ],
      ),
      pool: MediaPool({
        for (final a in [_asset('m_video', MediaKind.video), _asset('m_song', MediaKind.audio)]) a.id: a,
      }),
      view: ViewState.initial.copyWith(rippleEnabled: ripple, playhead: playhead),
    );

/// A media pool that imports recordings like the real service: probe → `MediaKind.recording`,
/// project-owned, kept at its path in the bundle, added to the session's pool (sticky).
class RecordingPool extends FakeMediaPoolService {
  /// Duration of the next imported recording.
  TimeUs duration = 3 * s;

  /// Reject every import with this reason (null: import).
  String? rejectWith;

  /// Throw from import.
  bool throws = false;

  /// What was imported, in order.
  final List<PickedMedia> picks = [];

  var _n = 0;

  @override
  Future<List<ImportOutcome>> import(EditSession session, List<PickedMedia> picked, {ImportTarget? target}) async {
    calls.add('import');
    if (throws) throw const StoreFailure(StoreFailureKind.io, 'scripted');
    final out = <ImportOutcome>[];
    for (final p in picked) {
      picks.add(p);
      final reject = rejectWith;
      if (reject != null) {
        out.add(ImportRejected(p, reject));
        continue;
      }
      final n = ++_n;
      final rel = p.uri.substring('/fake/support/'.length);
      final asset = MediaAsset(
        id: MediaId('md_rec$n'),
        kind: MediaKind.recording,
        displayName: p.displayName,
        locator: AppRelativeLocator(AppRoot.support, rel),
        ownership: MediaOwnership.projectOwned,
        fingerprint: MediaFingerprint(sizeBytes: 288000, quickHash: 'rec$n'.padRight(40, '0'), duration: duration),
        probe: MediaProbe(kind: MediaKind.recording, duration: duration, hasVideo: false, hasAudio: true),
        origin: p.origin,
        addedAt: DateTime.utc(2026, 10, 14),
      );
      session.applyPoolChange(AddAssets([asset]));
      out.add(ImportedMedia(p, asset));
    }
    return out;
  }
}

/// The harness around the real inspector with a real, opened EditorController.
class VoiceoverRig {
  VoiceoverRig._(this.harness, this.id, this.tester, this.pool);

  /// Harness.
  final EditorTestHarness harness;

  /// Project id.
  final ProjectId id;

  /// Tester.
  final WidgetTester tester;

  /// The media pool.
  final RecordingPool pool;

  /// The fake engine.
  FakeEditorEngine get engine => harness.engine;

  /// The fake recorder.
  FakeVoiceRecorder get recorder => engine.recorder;

  /// The newest recording session.
  FakeRecordingSession get recording => recorder.sessions.last;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The working project.
  EditProject get project => state.project!;

  /// The history position (entries applied).
  int get entries => state.history.position;

  /// Label of the newest history entry.
  String? get undoLabel => state.history.undoLabel;

  /// The voice-role audio lanes, top to bottom.
  List<Track> get voiceLanes =>
      project.timeline.tracks.where((t) => t.kind == TrackKind.audio && t.audioRole == AudioRole.voice).toList();

  /// Clips of recordings on the timeline.
  List<(Track, MediaClip)> get recordedClips => [
        for (final t in project.timeline.tracks)
          for (final i in t.items)
            if (i is MediaClip && project.pool[i.media]?.kind == MediaKind.recording) (t, i),
      ];

  /// Pumps the panel and opens the editor (with [open], the voiceover panel is opened).
  static Future<VoiceoverRig> pump(
    WidgetTester tester, {
    EditorSurface surface = const EditorSurface(Size(1280, 900)),
    bool open = true,
    bool voiceLane = false,
    bool ripple = true,
    TimeUs playhead = 0,
    bool voiceRecording = true,
    MicPermission permission = MicPermission.granted,
    MicPermission? afterRequest,
    bool readOnly = false,
    bool reducedMotion = false,
    RecordingPool? pool,
  }) async {
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('Voiceover');
    final project = voiceoverProject(empty.id, voiceLane: voiceLane, ripple: ripple, playhead: playhead);
    repo.seed(project);
    if (readOnly) repo.openResults[project.id] = (p) => LoadedProject(project: p, health: ProjectHealth.readOnlyNewer);
    final ticker = RigTicker();
    final recordings = pool ?? RecordingPool();
    final engine = FakeEditorEngine(validatePlans: false, caps: fakeDefaultCapabilities.copyWith(voiceRecording: voiceRecording));
    engine.recorder
      ..permissionState = permission
      ..permissionAfterRequest = afterRequest;
    final harness = EditorTestHarness(
      engine: engine,
      repository: repo,
      mediaPool: recordings,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
        voiceoverRecordingPathProvider.overrideWith((ref, pid) => (name) => '${recordingsDirOf(pid)}/$name'),
      ],
    );
    final rig = VoiceoverRig._(harness, project.id, tester, recordings);
    EditorAnnouncer.instance.reset();
    addTearDown(EditorAnnouncer.instance.reset);
    final Widget frame = EditorScope(
      projectId: project.id,
      child: const RegionFrame(
        inspectorOpen: true,
        regions: {EditorRegion.pane: InspectorHost()},
        dock: InspectorDock(),
      ),
    );
    final child = reducedMotion
        ? Builder(builder: (context) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: frame))
        : frame;
    await harness.pumpApp(tester, child, surface: surface);
    await rig.real(() => rig.editor.open());
    if (open) rig.editor.openInspector(const VoiceoverInspector());
    await rig.settle();
    return rig;
  }

  /// Runs [body] with real async and pumps.
  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }

  /// Pumps a few frames so microtask chains (fake recorder, pool, editor) complete.
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  /// Seeks the playhead exactly to [t] and settles.
  Future<void> seek(TimeUs t) async {
    await real(() async {
      await playhead.seekExact(t);
    });
    await settle();
  }
}
