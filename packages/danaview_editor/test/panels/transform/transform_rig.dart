// OWNER: UX-23
//
// A rig for the Transform, Crop and Mask panel tests and the crop, mask and eyedropper preview
// modes: the editor harness with a real EditorController opened over FakeEditorEngine on a seeded
// project, a manual playhead ticker, a resolving plan compiler (so transients flow) and a frame that
// places the inspector (side pane or dock) and a preview area with the `PreviewToolLayer` at their
// layout rects.
//
// The project (30 fps, default canvas): main lane with a video clip A (1920x1080, 0-4 s) and a square
// image B (1000x1000, 4-8 s); an overlay image 1-3 s; a text 0-3 s; a music clip.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/contracts/inspector_routes.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/preview/canvas_geometry.dart';
import 'package:danaview_editor/src/editor/preview/crop_overlay.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/plan_compiler_port.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import '../../state/state_support.dart' show resolverFor;
import '../../inspector/inspector_rig.dart' show RegionFrame;
import '../../support/support.dart';
import '../../transport/transport_support.dart';

const int s = microsPerSecond;

/// Frame-grid time of frame [n] at 30 fps.
TimeUs f(int n) => FrameRate.fps30.timeOfFrame(n);

/// The ids of the seeded project.
class Ids {
  /// Main video clip (1920x1080, 0-4 s).
  static const ItemId a = ItemId('it_clipa000001');

  /// Main image clip (1000x1000, 4-8 s).
  static const ItemId b = ItemId('it_clipb000001');

  /// Overlay image (1-3 s).
  static const ItemId overlay = ItemId('it_overlay0001');

  /// Text (0-3 s).
  static const ItemId text = ItemId('it_text0000001');

  /// Music.
  static const ItemId music = ItemId('it_music000001');

  /// The main track.
  static const TrackId main = TrackId('tr_main0000001');
}

MediaAsset _asset(String id, MediaKind kind, {int? w, int? h, String? name}) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: name ?? '$id.mp4',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: kind == MediaKind.image ? 0 : 60 * s,
        hasVideo: kind == MediaKind.video || kind == MediaKind.image,
        hasAudio: kind == MediaKind.video || kind == MediaKind.audio,
        width: w,
        height: h,
      ),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

MediaClip _clip(ItemId id, String media, TimeUs start, TimeUs duration, {VisualProps? visual, KeyframeSet keys = KeyframeSet.empty}) =>
    MediaClip(id: id, start: start, duration: duration, media: MediaId(media), visual: visual ?? VisualProps.neutral, keyframes: keys);

/// The seeded project; [visuals] sets the visuals of clips by id, [keys] their keyframes.
EditProject transformProject(
  FakeProjectRepository repo, {
  Map<ItemId, VisualProps> visuals = const {},
  Map<ItemId, KeyframeSet> keys = const {},
  bool lockMain = false,
  bool unknownSize = false,
}) {
  final main = Track(
    id: Ids.main,
    kind: TrackKind.video,
    isMain: true,
    locked: lockMain,
    items: [
      _clip(Ids.a, 'md_vid0000001', 0, 4 * s, visual: visuals[Ids.a], keys: keys[Ids.a] ?? KeyframeSet.empty),
      _clip(Ids.b, 'md_img0000001', 4 * s, 4 * s, visual: visuals[Ids.b], keys: keys[Ids.b] ?? KeyframeSet.empty),
    ],
  );
  final overlay = Track(
    id: const TrackId('tr_over0000001'),
    kind: TrackKind.overlay,
    items: [_clip(Ids.overlay, 'md_img0000001', 1 * s, 2 * s, visual: visuals[Ids.overlay])],
  );
  final text = Track(
    id: const TrackId('tr_text0000001'),
    kind: TrackKind.text,
    items: [TextItem(id: Ids.text, start: 0, duration: 3 * s, text: 'Title')],
  );
  final music = Track(
    id: const TrackId('tr_musc0000001'),
    kind: TrackKind.audio,
    audioRole: AudioRole.music,
    items: [MediaClip(id: Ids.music, start: 0, duration: 10 * s, media: const MediaId('md_song0000001'))],
  );
  final now = DateTime.utc(2026, 10, 1);
  final project = EditProject(
    id: const ProjectId('pr_xform000001'),
    meta: ProjectMeta(name: 'Transform', createdAt: now, updatedAt: now),
    timeline: Timeline(tracks: [main, overlay, text, music]),
    pool: MediaPool({
      for (final a in [
        _asset('md_vid0000001', MediaKind.video, w: unknownSize ? null : 1920, h: unknownSize ? null : 1080),
        _asset('md_img0000001', MediaKind.image, w: 1000, h: 1000, name: 'photo.jpg'),
        _asset('md_song0000001', MediaKind.audio, name: 'song.m4a'),
      ])
        a.id: a,
    }),
  );
  repo.seed(project);
  return project;
}

/// The editor harness around the inspector and a preview area with the preview tool layer.
class TransformRig {
  TransformRig._(this.harness, this.id, this.tester, this.ticker);

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

  /// The fake preview session.
  FakePreviewSession get preview => engine.sessions.last;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The preview tools.
  PreviewToolController get tools => container.read(previewToolProvider(id));

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

  /// How many times the fake engine saw [call].
  int calls(String call) => engine.calls.where((c) => c == call).length;

  /// The geometry of the preview area as laid out.
  CanvasGeometry get geometry {
    final size = tester.getSize(find.byKey(previewAreaKey));
    final c = project.settings.canvas;
    return CanvasGeometry.letterbox(Size(c.widthPx.toDouble(), c.heightPx.toDouble()), size);
  }

  /// The global position of the preview-area point [local].
  Offset global(Offset local) => tester.getTopLeft(find.byKey(previewAreaKey)) + local;

  /// Pumps the frame and opens the editor.
  static Future<TransformRig> pump(
    WidgetTester tester, {
    EditorSurface surface = SurfaceMatrix.phone,
    EditProject Function(FakeProjectRepository repo)? project,
    Widget Function(ProjectId id)? build,
  }) async {
    final repo = FakeProjectRepository();
    final id = (project ?? transformProject)(repo).id;
    final ticker = ManualTicker();
    final clock = ManualClock();
    final harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: clock.call)),
        planCompilerPortProvider.overrideWithValue(ResolvingPlanCompilerPort((_, p) => resolverFor(p))),
      ],
    );
    final rig = TransformRig._(harness, id, tester, ticker);
    await harness.pumpApp(tester, EditorScope(projectId: id, child: (build ?? transformFrame)(id)), surface: surface);
    await rig.real(() => rig.editor.open());
    // Let the app's first page transition finish (it would cover the frame for taps).
    await tester.pump(const Duration(seconds: 1));
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
  Future<void> seek(TimeUs t) => real(() async {
        await playhead.seekExact(t);
      });

  /// Selects [item] and opens [route].
  Future<void> open(ItemId item, InspectorRouteFor route) async {
    editor.select(item);
    await tester.pump();
    editor.openInspector(route(item));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }
}

/// Builds an inspector route for an item.
typedef InspectorRouteFor = InspectorRoute Function(ItemId item);

/// The key of the preview area.
const Key previewAreaKey = ValueKey<String>('test.previewArea');

/// The preview area: the preview tool layer over the letterboxed canvas.
class PreviewArea extends ConsumerWidget {
  /// Creates the area.
  const PreviewArea({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = EditorScope.idOf(context);
    final canvas = ref.watch(editorControllerProvider(id).select((s) => s.project?.settings.canvas));
    return LayoutBuilder(
      key: previewAreaKey,
      builder: (context, constraints) {
        if (canvas == null) return const SizedBox.shrink();
        final g = CanvasGeometry.letterbox(Size(canvas.widthPx.toDouble(), canvas.heightPx.toDouble()), constraints.biggest);
        return Stack(fit: StackFit.expand, children: [PreviewToolLayer(geometry: g)]);
      },
    );
  }
}

/// The inspector as the scaffold places it (side pane and compactPortrait dock) and the preview.
Widget transformFrame(ProjectId id) => const RegionFrame(
      inspectorOpen: true,
      regions: {EditorRegion.preview: PreviewArea(), EditorRegion.pane: InspectorHost()},
      dock: InspectorDock(),
    );

/// A surface that shows the side pane with room for every row (an iPad in landscape).
const EditorSurface wideSurface = EditorSurface(Size(1194, 834), platform: TargetPlatform.iOS);
