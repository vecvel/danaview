// OWNER: UX-31
//
// A rig for the captions panel tests: the editor harness with a real EditorController opened over
// FakeEditorEngine at 30 fps, and the panel placed in the inspector region by the real
// InspectorHost / InspectorDock.
//
// Lanes (bottom to top): the main video lane (one 60 s clip), the locked subtitle lane L (one cue),
// the subtitle lane B "English" (cues b1 0–2 s, b2 3–5 s) and the topmost subtitle lane A (cues
// a1 1–3 s "Hello world", a2 4–6 s "Second caption", a3 8–9 s "Third", a4 10–12 s "Last one").
// `cueCount` replaces lane A's cues with that many 1 s cues (0.5 s apart) for the list tests.

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
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor/src/editor/state/transport_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import '../../inspector/inspector_rig.dart' show RegionFrame, RigTicker;
import '../../support/support.dart';

export '../../inspector/inspector_rig.dart' show RegionFrame;

const int s = microsPerSecond;

/// The frame grid of the rig's project.
final FrameRate rate = FrameRate.fps30;

TimeUs frames(int n) => rate.timeOfFrame(n);

/// Ids of the rig's project.
abstract final class Subs {
  static const TrackId main = TrackId('tr_main');
  static const TrackId a = TrackId('tr_a');
  static const TrackId b = TrackId('tr_b');
  static const TrackId locked = TrackId('tr_locked');

  static const ItemId a1 = ItemId('cu_a1');
  static const ItemId a2 = ItemId('cu_a2');
  static const ItemId a3 = ItemId('cu_a3');
  static const ItemId a4 = ItemId('cu_a4');
  static const ItemId b1 = ItemId('cu_b1');
  static const ItemId b2 = ItemId('cu_b2');
  static const ItemId l1 = ItemId('cu_l1');

  /// The id of the generated cue [i] (cueCount projects).
  static ItemId many(int i) => ItemId('cu_m$i');
}

SubtitleCue cue(ItemId id, TimeUs start, TimeUs end, String text) => SubtitleCue(id: id, start: start, duration: end - start, text: text);

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

/// The project of the rig; [subtitles] false leaves only the main lane.
EditProject subtitlesProject(ProjectId id, {bool subtitles = true, int? cueCount}) {
  final aCues = cueCount == null
      ? [
          cue(Subs.a1, 1 * s, 3 * s, 'Hello world'),
          cue(Subs.a2, 4 * s, 6 * s, 'Second caption'),
          cue(Subs.a3, 8 * s, 9 * s, 'Third'),
          cue(Subs.a4, 10 * s, 12 * s, 'Last one'),
        ]
      : [for (var i = 0; i < cueCount; i++) cue(Subs.many(i), frames(45 * i), frames(45 * i + 30), 'Caption number $i of the long list')];
  final mainLength = cueCount == null ? 60 * s : frames(45 * cueCount + 30);
  return EditProject(
    id: id,
    meta: ProjectMeta(name: 'Subtitles', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
    timeline: Timeline(
      tracks: [
        Track(id: Subs.main, kind: TrackKind.video, isMain: true, items: [
          MediaClip(id: const ItemId('it_main'), start: 0, duration: mainLength, media: const MediaId('m_a'), visual: const VisualProps()),
        ]),
        if (subtitles) ...[
          Track(
            id: Subs.locked,
            kind: TrackKind.subtitle,
            name: 'Locked',
            locked: true,
            subtitle: const SubtitleTrackData(),
            items: [cue(Subs.l1, 0, 2 * s, 'Locked cue')],
          ),
          Track(
            id: Subs.b,
            kind: TrackKind.subtitle,
            name: 'English',
            subtitle: const SubtitleTrackData(language: 'en'),
            items: [cue(Subs.b1, 0, 2 * s, 'Bee one'), cue(Subs.b2, 3 * s, 5 * s, 'Bee two')],
          ),
          Track(id: Subs.a, kind: TrackKind.subtitle, subtitle: const SubtitleTrackData(), items: aCues),
        ],
      ],
    ),
    pool: MediaPool({const MediaId('m_a'): _asset('m_a')}),
  );
}

/// The harness around the real inspector with a real, opened EditorController.
class SubtitlesRig {
  SubtitlesRig._(this.harness, this.id, this.tester, this.ticker);

  /// Harness.
  final EditorTestHarness harness;

  /// Project id.
  final ProjectId id;

  /// Tester.
  final WidgetTester tester;

  /// The playhead's ticker.
  final RigTicker ticker;

  /// The fake engine.
  FakeEditorEngine get engine => harness.engine;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The transport.
  TransportController get transport => container.read(transportProvider(id));

  /// The working project.
  EditProject get project => state.project!;

  /// The history position (entries applied).
  int get entries => state.history.position;

  /// The track [t].
  Track track(TrackId t) => project.tracks.firstWhere((x) => x.id == t);

  /// The cues of [t].
  List<SubtitleCue> cues(TrackId t) => [for (final i in track(t).items) i as SubtitleCue];

  /// The cue [c], or null.
  SubtitleCue? cueOf(ItemId c) => project.index.locate(c)?.item as SubtitleCue?;

  /// The subtitle data of [t].
  SubtitleTrackData data(TrackId t) => track(t).subtitle!;

  /// A context for invoking actions.
  WidgetActionContext actionContext({EditorActionSource source = EditorActionSource.toolTile}) => WidgetActionContext.container(
        projectId: id,
        context: tester.element(find.byType(RegionFrame)),
        container: container,
        source: source,
      );

  /// Pumps the panel host and opens the editor; [open] is the route opened first.
  static Future<SubtitlesRig> pump(
    WidgetTester tester, {
    EditorSurface surface = const EditorSurface(Size(1280, 900)),
    SubtitlesInspector? open = const SubtitlesInspector(track: Subs.a),
    bool subtitles = true,
    int? cueCount,
    TimeUs? playheadAt,
  }) async {
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('Subtitles');
    final project = subtitlesProject(empty.id, subtitles: subtitles, cueCount: cueCount);
    repo.seed(project);
    final ticker = RigTicker();
    final harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
      ],
    );
    final rig = SubtitlesRig._(harness, project.id, tester, ticker);
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
    await rig.real(() => rig.editor.open());
    if (playheadAt != null) await rig.seek(playheadAt);
    if (open != null) await rig.openPanel(open);
    return rig;
  }

  /// Opens [route].
  Future<void> openPanel(SubtitlesInspector route) async {
    editor.openInspector(route);
    await tester.pump();
    await tester.pump();
  }

  /// Runs [body] with real async and pumps.
  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }

  /// Seeks the playhead exactly to [t] and settles.
  Future<void> seek(TimeUs t) async {
    await real(() async {
      await playhead.seekExact(t);
    });
  }
}
