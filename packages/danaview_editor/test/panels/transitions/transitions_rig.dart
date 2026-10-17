// OWNER: UX-27
//
// A rig for the transitions panel tests: the editor harness with a real EditorController opened
// over FakeEditorEngine at 30 fps, and the panel placed in the inspector region by the real
// InspectorHost / InspectorDock.
//
// Main lane: A 0-4 s and B 4-8 s (10 s into 60 s sources: long handles), C 8-12 s (0.3 s into its
// source: 9 frames of handle before the B|C cut), image D 12-14 s. Overlay lane: O1 0-2 s (the last
// 2 s of its source) and O2 2-4 s (the first 2 s): no handles, so only non-overlap kinds fit.
// Locked overlay lane: L1 0-2 s, L2 2-4 s.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor/src/editor/state/transport_controller.dart';
import 'package:danaview_editor_core/eval.dart' show TransitionLimits;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import '../../inspector/inspector_rig.dart' show RegionFrame, RigTicker;
import '../../support/support.dart';

export '../../inspector/inspector_rig.dart' show RegionFrame, frameSpec;

const int s = microsPerSecond;

/// The frame grid of the rig's project.
final FrameRate rate = FrameRate.fps30;

TimeUs frames(int n) => rate.timeOfFrame(n);

/// Ids and cuts of the rig's project.
abstract final class Cuts {
  static const TrackId main = TrackId('tr_main');
  static const TrackId overlay = TrackId('tr_overlay');
  static const TrackId locked = TrackId('tr_locked');

  /// A|B at 4 s: long handles (every kind up to 2 s).
  static const TransitionRef ab = TransitionRef(main, ItemId('it_a'), ItemId('it_b'));

  /// B|C at 8 s: overlap kinds limited to 18 frames (0.6 s).
  static const TransitionRef bc = TransitionRef(main, ItemId('it_b'), ItemId('it_c'));

  /// C|D at 12 s (D is an image).
  static const TransitionRef cd = TransitionRef(main, ItemId('it_c'), ItemId('it_d'));

  /// O1|O2 at 2 s on the overlay lane: no handles.
  static const TransitionRef overlayCut = TransitionRef(overlay, ItemId('it_o1'), ItemId('it_o2'));

  /// L1|L2 on the locked lane.
  static const TransitionRef lockedCut = TransitionRef(locked, ItemId('it_l1'), ItemId('it_l2'));

  /// A ref that is not a cut (A and C do not touch).
  static const TransitionRef notACut = TransitionRef(main, ItemId('it_a'), ItemId('it_c'));
}

MediaAsset _asset(String id, MediaKind kind) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: '$id.file',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: kind == MediaKind.image ? 0 : 60 * s,
        hasVideo: true,
        hasAudio: kind != MediaKind.image,
        width: 1920,
        height: 1080,
      ),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

MediaClip _clip(String id, String media, TimeUs start, TimeUs duration, {TimeUs sourceIn = 0}) => MediaClip(
      id: ItemId(id),
      start: start,
      duration: duration,
      media: MediaId(media),
      sourceIn: sourceIn,
      visual: const VisualProps(),
    );

/// The project of the rig; [mainOnlyOneClip] leaves a single clip and no other lanes (no cut).
EditProject transitionsProject(ProjectId id, {bool mainOnlyOneClip = false}) => EditProject(
      id: id,
      meta: ProjectMeta(name: 'Transitions', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(
        tracks: mainOnlyOneClip
            ? [
                Track(id: Cuts.main, kind: TrackKind.video, isMain: true, items: [_clip('it_a', 'm_a', 0, 4 * s, sourceIn: 10 * s)]),
              ]
            : [
                Track(id: Cuts.main, kind: TrackKind.video, isMain: true, items: [
                  _clip('it_a', 'm_a', 0, 4 * s, sourceIn: 10 * s),
                  _clip('it_b', 'm_b', 4 * s, 4 * s, sourceIn: 10 * s),
                  _clip('it_c', 'm_c', 8 * s, 4 * s, sourceIn: frames(9)),
                  _clip('it_d', 'm_img', 12 * s, 2 * s),
                ]),
                Track(id: Cuts.overlay, kind: TrackKind.overlay, items: [
                  _clip('it_o1', 'm_o', 0, 2 * s, sourceIn: 58 * s),
                  _clip('it_o2', 'm_o', 2 * s, 2 * s),
                ]),
                Track(id: Cuts.locked, kind: TrackKind.overlay, locked: true, items: [
                  _clip('it_l1', 'm_a', 0, 2 * s, sourceIn: 10 * s),
                  _clip('it_l2', 'm_b', 2 * s, 2 * s, sourceIn: 10 * s),
                ]),
              ],
      ),
      pool: MediaPool({
        for (final a in [
          _asset('m_a', MediaKind.video),
          _asset('m_b', MediaKind.video),
          _asset('m_c', MediaKind.video),
          _asset('m_o', MediaKind.video),
          _asset('m_img', MediaKind.image),
        ])
          a.id: a,
      }),
    );

/// The harness around the real inspector with a real, opened EditorController.
class TransitionsRig {
  TransitionsRig._(this.harness, this.id, this.tester, this.ticker);

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

  /// The fake preview session of the engine.
  FakePreviewSession get preview => engine.sessions.last;

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

  /// The transition at [cut], if any.
  Transition? at(TransitionRef cut) => TransitionLimits.at(project, cut);

  /// The history position (entries applied).
  int get entries => state.history.position;

  /// Pumps the panel host and opens the editor; [open] is the cut whose panel opens (selected).
  static Future<TransitionsRig> pump(
    WidgetTester tester, {
    EditorSurface surface = const EditorSurface(Size(1280, 900)),
    TransitionRef? open = Cuts.ab,
    bool mainOnlyOneClip = false,
    TimeUs? playheadAt,
    bool playing = false,
    List<Override> overrides = const [],
  }) async {
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('Transitions');
    final project = transitionsProject(empty.id, mainOnlyOneClip: mainOnlyOneClip);
    repo.seed(project);
    final ticker = RigTicker();
    final engine = FakeEditorEngine(validatePlans: false);
    final harness = EditorTestHarness(
      engine: engine,
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
        ...overrides,
      ],
    );
    final rig = TransitionsRig._(harness, project.id, tester, ticker);
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
    if (playing) await rig.real(() => rig.transport.play());
    if (open != null) await rig.openPanel(open);
    return rig;
  }

  /// Selects [cut] and opens its panel; lets the loop preview start.
  Future<void> openPanel(TransitionRef cut) async {
    editor
      ..selectTransition(cut)
      ..openInspector(TransitionInspector(cut));
    await tester.pump();
    await settle();
  }

  /// Closes the inspector and lets the panel restore the transport.
  Future<void> closePanel() async {
    editor.closeInspector();
    await tester.pump();
    await settle();
  }

  /// Lets queued async work (transport operations) finish.
  Future<void> settle() async {
    await real(() async {});
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
