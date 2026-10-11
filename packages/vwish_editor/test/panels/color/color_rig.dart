// OWNER: UX-24
//
// A rig for the Adjust and Filters panel tests: the editor harness with a real EditorController
// opened over FakeEditorEngine on a seeded project, a manual playhead ticker, a resolving plan
// compiler (so transients flow) and `RegionFrame` to place the panel at the spec's rect.
//
// The project (30 fps, 1920x1080): main lane with three picture clips (video 0-4 s, image 4-8 s, video
// 8-12 s), an overlay image 1-3 s, a text 0-3 s, a music clip, and a LUT asset "Film.cube" in the pool.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/editor_scope.dart';
import 'package:vwish_editor/src/editor/inspector/inspector_dock.dart';
import 'package:vwish_editor/src/editor/inspector/inspector_host.dart';
import 'package:vwish_editor/src/editor/layout/editor_layout.dart';
import 'package:vwish_editor/src/editor/state/editor_controller.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/state/plan_compiler_port.dart';
import 'package:vwish_editor/src/editor/state/playhead_controller.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_engine_api/testing.dart';

import '../../state/state_support.dart' show resolverFor;
import '../../inspector/inspector_rig.dart' show RegionFrame;
import '../../support/support.dart';
import '../../transport/transport_support.dart';

const int s = microsPerSecond;

/// Frame-grid time of frame [n] at 30 fps.
TimeUs f(int n) => FrameRate.fps30.timeOfFrame(n);

/// The ids of the seeded project.
class ColorIds {
  /// Main clip A (video, 0-4 s).
  static const ItemId a = ItemId('it_clipa000001');

  /// Main clip B (image, 4-8 s).
  static const ItemId b = ItemId('it_clipb000001');

  /// Main clip C (video, 8-12 s).
  static const ItemId c = ItemId('it_clipc000001');

  /// Overlay image (1-3 s).
  static const ItemId overlay = ItemId('it_overlay0001');

  /// Text (0-3 s).
  static const ItemId text = ItemId('it_text0000001');

  /// Music (0-10 s).
  static const ItemId music = ItemId('it_music000001');

  /// The LUT asset.
  static const MediaId lut = MediaId('md_lut0000001');

  /// The main track.
  static const TrackId main = TrackId('tr_main0000001');
}

MediaAsset _asset(String id, MediaKind kind, {String? name, MediaOwnership ownership = MediaOwnership.managedCopy, MediaLocator? locator}) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: name ?? '$id.mp4',
      locator: locator ?? AppRelativeLocator(AppRoot.support, 'vwish/editor/media/$id/file'),
      ownership: ownership,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: kind == MediaKind.image || kind == MediaKind.lut ? 0 : 60 * s,
        hasVideo: kind == MediaKind.video || kind == MediaKind.image,
        hasAudio: kind == MediaKind.video || kind == MediaKind.audio,
        width: kind == MediaKind.audio || kind == MediaKind.lut ? null : 1920,
        height: kind == MediaKind.audio || kind == MediaKind.lut ? null : 1080,
      ),
      origin: kind == MediaKind.lut ? MediaOrigin.imported : MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

/// A LUT asset like the pool service makes (project-owned, `.cube` locator).
MediaAsset lutAsset(String id, String name, {DateTime? addedAt}) => _asset(
      id,
      MediaKind.lut,
      name: name,
      ownership: MediaOwnership.projectOwned,
      locator: AppRelativeLocator(AppRoot.support, 'vwish/editor/projects/pr_color0000001/assets/luts/$id.cube'),
    ).copyWith(addedAt: addedAt ?? DateTime.utc(2026, 10, 2));

MediaClip _clip(ItemId id, String media, TimeUs start, TimeUs duration, {VisualProps? visual, KeyframeSet keys = KeyframeSet.empty}) =>
    MediaClip(id: id, start: start, duration: duration, media: MediaId(media), visual: visual ?? VisualProps.neutral, keyframes: keys);

/// The seeded project; [mainVisual] sets the visuals of the three main clips by id.
EditProject colorProject(FakeProjectRepository repo, {Map<ItemId, VisualProps> visuals = const {}, bool lockMain = false, bool withLut = true, KeyframeSet? keysOfA}) {
  final main = Track(
    id: ColorIds.main,
    kind: TrackKind.video,
    isMain: true,
    locked: lockMain,
    items: [
      _clip(ColorIds.a, 'md_vid0000001', 0, 4 * s, visual: visuals[ColorIds.a], keys: keysOfA ?? KeyframeSet.empty),
      _clip(ColorIds.b, 'md_img0000001', 4 * s, 4 * s, visual: visuals[ColorIds.b]),
      _clip(ColorIds.c, 'md_vid0000001', 8 * s, 4 * s, visual: visuals[ColorIds.c]),
    ],
  );
  final overlay = Track(
    id: const TrackId('tr_over0000001'),
    kind: TrackKind.overlay,
    items: [_clip(ColorIds.overlay, 'md_img0000001', 1 * s, 2 * s, visual: visuals[ColorIds.overlay])],
  );
  final text = Track(
    id: const TrackId('tr_text0000001'),
    kind: TrackKind.text,
    items: [TextItem(id: ColorIds.text, start: 0, duration: 3 * s, text: 'Title')],
  );
  final music = Track(
    id: const TrackId('tr_musc0000001'),
    kind: TrackKind.audio,
    audioRole: AudioRole.music,
    items: [MediaClip(id: ColorIds.music, start: 0, duration: 10 * s, media: const MediaId('md_song0000001'))],
  );
  final now = DateTime.utc(2026, 10, 1);
  final project = EditProject(
    id: const ProjectId('pr_color0000001'),
    meta: ProjectMeta(name: 'Colour', createdAt: now, updatedAt: now),
    timeline: Timeline(tracks: [main, overlay, text, music]),
    pool: MediaPool({
      for (final a in [
        _asset('md_vid0000001', MediaKind.video),
        _asset('md_img0000001', MediaKind.image, name: 'photo.jpg'),
        _asset('md_song0000001', MediaKind.audio, name: 'song.m4a'),
        if (withLut) lutAsset(ColorIds.lut, 'Film.cube'),
      ])
        a.id: a,
    }),
  );
  repo.seed(project);
  return project;
}

/// A [KeyframeSet] with keys of [channels] at the given frames (value [v]).
KeyframeSet keysAt(Map<String, List<int>> framesByChannel, {double v = 0.25}) => KeyframeSet({
      for (final e in framesByChannel.entries) e.key: KeyframeTrack([for (final fr in e.value) Keyframe(f(fr), v)]),
    });

/// The editor harness around a panel with a real, opened EditorController.
class ColorRig {
  ColorRig._(this.harness, this.id, this.tester, this.ticker);

  /// The harness.
  final EditorTestHarness harness;

  /// The project id.
  final ProjectId id;

  /// The tester.
  final WidgetTester tester;

  /// The manual ticker of the playhead.
  final ManualTicker ticker;

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

  /// The committed project.
  EditProject get project => state.project!;

  /// Entries in the undo history.
  int get entries => state.history.position;

  /// The label of the newest history entry.
  String? get undoLabel => state.history.undoLabel;

  /// The item [id] of the project.
  TimelineItem item(ItemId id) => project.index.item(id)!;

  /// The visual of the clip [id].
  VisualProps visual(ItemId id) => (item(id) as MediaClip).visual!;

  /// Pumps the widget [build] makes and opens the editor.
  static Future<ColorRig> pump(
    WidgetTester tester,
    Widget Function(ProjectId id) build, {
    EditorSurface surface = SurfaceMatrix.phone,
    EditProject Function(FakeProjectRepository repo)? project,
    List<Override> overrides = const [],
    FakeMediaPoolService? mediaPool,
  }) async {
    final repo = FakeProjectRepository();
    final id = (project ?? colorProject)(repo).id;
    final ticker = ManualTicker();
    final clock = ManualClock();
    final harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      mediaPool: mediaPool,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: clock.call)),
        planCompilerPortProvider.overrideWithValue(ResolvingPlanCompilerPort((_, p) => resolverFor(p))),
        ...overrides,
      ],
    );
    final rig = ColorRig._(harness, id, tester, ticker);
    await harness.pumpApp(tester, EditorScope(projectId: id, child: build(id)), surface: surface);
    await rig.real(() => rig.editor.open());
    return rig;
  }

  /// Runs [body] with real async, then pumps.
  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    await tester.pump();
  }

  /// Seeks the playhead exactly to [t] and settles.
  Future<void> seek(TimeUs t) async {
    await real(() async {
      await playhead.seekExact(t);
    });
  }

  /// Selects [item].
  Future<void> select(ItemId item) async {
    editor.select(item);
    await tester.pump();
  }
}

/// The inspector as the scaffold places it: the side pane (`InspectorHost`) and the compactPortrait
/// dock (`InspectorDock`), so the panels are tested under their real header.
Widget inspectorFrame(ProjectId id) => const RegionFrame(
      inspectorOpen: true,
      regions: {EditorRegion.pane: InspectorHost()},
      dock: InspectorDock(),
    );

/// A surface that shows the side pane with room for every row (an iPad in landscape).
const EditorSurface wideSurface = EditorSurface(Size(1194, 834), platform: TargetPlatform.iOS);
