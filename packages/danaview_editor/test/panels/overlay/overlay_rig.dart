// OWNER: UX-28
//
// A rig for the Overlay and Chroma key panel tests: UX-36's MediaRig (editor harness with a real
// EditorController over FakeEditorEngine, UX-06's ScriptedPool as the media pool service, a manual
// playhead) around UX-23's frame (the inspector in the side pane or the dock, and a preview area
// with the `PreviewToolLayer`), over a seeded project with three overlay lanes.
//
// The project (30 fps, default canvas): main lane with a video clip (0-10 s); overlay lanes bottom
// to top O1 (photo P1 1-4 s), O2 (video P2 2-5 s), O3 (photo P3 6-8 s, or 3-7 s when `crowded`);
// a text lane; a music lane.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/inspector_routes.dart';
import 'package:danaview_editor/src/editor/preview/canvas_geometry.dart';
import 'package:danaview_editor/src/editor/preview/crop_overlay.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import '../media/media_support.dart';
import '../transform/transform_rig.dart' show previewAreaKey, transformFrame;

export '../media/media_support.dart';

/// The ids of the seeded project.
abstract final class Ov {
  /// Main video clip (0-10 s).
  static const ItemId main = ItemId('it_mainclip001');

  /// Photo on O1 (1-4 s).
  static const ItemId p1 = ItemId('it_overlayp1001');

  /// Video on O2 (2-5 s).
  static const ItemId p2 = ItemId('it_overlayp2001');

  /// Photo on O3 (6-8 s; 3-7 s when crowded).
  static const ItemId p3 = ItemId('it_overlayp3001');

  /// Text (0-3 s).
  static const ItemId text = ItemId('it_textitem0001');

  /// Lanes.
  static const TrackId mainLane = TrackId('tr_mainlane0001');
  static const TrackId o1 = TrackId('tr_overlayo1001');
  static const TrackId o2 = TrackId('tr_overlayo2001');
  static const TrackId o3 = TrackId('tr_overlayo3001');

  /// Media.
  static const MediaId video = MediaId('md_ovvideo0001');
  static const MediaId photo = MediaId('md_ovphoto0001');
}

MediaClip _clip(ItemId id, MediaId media, TimeUs start, TimeUs duration, {VisualProps? visual}) =>
    MediaClip(id: id, start: start, duration: duration, media: media, visual: visual ?? VisualProps.neutral);

/// The seeded project (see the file header). [overlays] false leaves the overlay lanes out;
/// [lock] locks those lanes; [chroma] sets P1's chroma key.
EditProject overlayProject(
  FakeProjectRepository repo, {
  bool overlays = true,
  bool crowded = false,
  Set<TrackId> lock = const {},
  ChromaKey? chroma,
}) {
  final now = DateTime.utc(2026, 10, 1);
  final tracks = <Track>[
    Track(id: Ov.mainLane, kind: TrackKind.video, isMain: true, items: [_clip(Ov.main, Ov.video, 0, 10 * s)]),
    if (overlays) ...[
      Track(
        id: Ov.o1,
        kind: TrackKind.overlay,
        locked: lock.contains(Ov.o1),
        items: [_clip(Ov.p1, Ov.photo, 1 * s, 3 * s, visual: chroma == null ? null : VisualProps(chroma: chroma))],
      ),
      Track(id: Ov.o2, kind: TrackKind.overlay, locked: lock.contains(Ov.o2), items: [_clip(Ov.p2, Ov.video, 2 * s, 3 * s)]),
      Track(
        id: Ov.o3,
        kind: TrackKind.overlay,
        locked: lock.contains(Ov.o3),
        items: [_clip(Ov.p3, Ov.photo, crowded ? 3 * s : 6 * s, crowded ? 4 * s : 2 * s)],
      ),
    ],
    Track(id: const TrackId('tr_textlane0001'), kind: TrackKind.text, items: [TextItem(id: Ov.text, start: 0, duration: 3 * s, text: 'Title')]),
  ];
  final project = EditProject(
    id: const ProjectId('pr_overlay00001'),
    meta: ProjectMeta(name: 'Overlay', createdAt: now, updatedAt: now),
    timeline: Timeline(tracks: tracks),
    pool: MediaPool({
      for (final a in [
        binAsset(Ov.video.value, name: 'clip.mp4', duration: 60 * s),
        binAsset(Ov.photo.value, kind: MediaKind.image, name: 'photo.jpg', width: 1000, height: 1000),
      ])
        a.id: a,
    }),
  );
  repo.seed(project);
  return project;
}

/// The overlay rig: a MediaRig over [transformFrame] plus preview helpers.
class OverlayRig {
  OverlayRig._(this.media);

  /// The media rig.
  final MediaRig media;

  /// Pumps the frame over [project] (default [overlayProject]) and opens the editor.
  static Future<OverlayRig> pump(
    WidgetTester tester, {
    EditorSurface surface = const EditorSurface(Size(1194, 834), platform: TargetPlatform.iOS),
    EditProject Function(FakeProjectRepository repo)? project,
    ScriptedPool? pool,
  }) async {
    final media = await MediaRig.pump(tester, transformFrame, project: project ?? overlayProject, surface: surface, pool: pool);
    // Let the app's first page transition finish (it would cover the frame for taps).
    await tester.pump(const Duration(seconds: 1));
    return OverlayRig._(media);
  }

  WidgetTester get tester => media.tester;

  /// The fake engine.
  FakeEditorEngine get engine => media.engine;

  /// The fake preview session.
  FakePreviewSession get preview => engine.sessions.last;

  /// The preview tools.
  PreviewToolController get tools => media.container.read(previewToolProvider(media.id));

  /// The project.
  EditProject get project => media.project;

  /// The item [id].
  TimelineItem item(ItemId id) => project.index.item(id)!;

  /// The lane of [id].
  TrackId laneOf(ItemId id) => project.index.locate(id)!.track.id;

  /// The overlay lanes, bottom to top.
  List<Track> get overlayLanes => [
        for (final t in project.timeline.tracks)
          if (t.kind == TrackKind.overlay) t,
      ];

  /// The chroma key of [id].
  ChromaKey chroma(ItemId id) => (item(id) as MediaClip).visual!.chroma;

  /// Entries in the undo history.
  int get entries => media.historyDepth;

  /// The label of the newest history entry.
  String? get undoLabel => media.undoLabel;

  /// The geometry of the preview area as laid out.
  CanvasGeometry get geometry {
    final size = tester.getSize(find.byKey(previewAreaKey));
    final c = project.settings.canvas;
    return CanvasGeometry.letterbox(Size(c.widthPx.toDouble(), c.heightPx.toDouble()), size);
  }

  /// The global position of the preview-area point [local].
  Offset global(Offset local) => tester.getTopLeft(find.byKey(previewAreaKey)) + local;

  /// How many times the fake engine saw [call].
  int calls(String call) => engine.calls.where((c) => c == call).length;

  /// Selects [item] (when given) and opens [route].
  Future<void> open(InspectorRoute route, {ItemId? select}) async {
    if (select != null) media.editor.select(select);
    await tester.pump();
    media.editor.openInspector(route);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Taps the widget keyed [key] (scrolled into view first).
  Future<void> tapKey(String key) async {
    final target = find.byKey(ValueKey<String>(key));
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await tester.pump();
    await tester.pump();
  }
}
