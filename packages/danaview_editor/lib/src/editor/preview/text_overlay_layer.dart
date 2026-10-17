// OWNER: UX-19
//
// TextOverlayLayer (D-05, ARCH §13.1): the text items and subtitle cues of the open project painted
// above the preview texture, letterboxed with the preview's `CanvasGeometry`. The editor preview
// (UX-18) and the fullscreen preview host the same layer.
//
// * The layer rebuilds only when the shown project changes (edits; the working copy while a
//   gesture runs); playback repaints the painter alone, once per frame change of the
//   frame-quantized `PlayheadController` (no widget rebuilds, nothing in EditorState changes).
// * [previewTextEngineProvider] is the app's one `TextLayoutEngine` for the preview overlay and the
//   manipulation handles' text metrics (UX-22). It resolves content-font ids through UX-30's
//   `FontCatalog` (`fontCatalogProvider`, unknown/unbundled -> Figtree), the same resolver the export
//   sprites use (UX-39's `ExportEnvironment`), so a chosen font shows identically in both (FIX-FONTS).
// * The layer is user content: it is wrapped in `EditorContentTextRegion` (the owner UI rules allow
//   content fonts there) and ignores pointers (the manipulation overlay above it handles them).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show EditProject, ProjectId;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show TextLayoutEngine;

import '../../app/editor_providers.dart';
import '../contracts/content_text.dart';
import '../editor_scope.dart';
import '../text/font_catalog.dart' show fontCatalogProvider;
import 'canvas_geometry.dart';
import 'text_overlay_painter.dart';

export 'text_overlay_painter.dart' show TextOverlayEntry, TextOverlayPainter, TextOverlayScene, activeItemOf;

/// The preview's text layout engine (API-04): text overlay layouts and handle metrics, with content
/// fonts resolved by the [fontCatalogProvider] catalog (FIX-FONTS).
///
/// See D-05, ARCH §13.1.
final previewTextEngineProvider = Provider<TextLayoutEngine>((ref) {
  final engine = TextLayoutEngine(fontResolver: ref.watch(fontCatalogProvider).resolve);
  ref.onDispose(engine.trim);
  return engine;
}, name: 'previewTextEngineProvider');

/// Text items and subtitle cues over the preview (D-05).
class TextOverlayLayer extends ConsumerStatefulWidget {
  /// Creates the layer for the project of the nearest `EditorScope` (or [projectId]) mapped through
  /// [geometry].
  const TextOverlayLayer({super.key, required this.geometry, this.projectId});

  /// Letterbox mapping of the preview this layer covers.
  final CanvasGeometry geometry;

  /// The project, when the layer is not below an `EditorScope` (fullscreen route).
  final ProjectId? projectId;

  @override
  ConsumerState<TextOverlayLayer> createState() => _TextOverlayLayerState();
}

class _TextOverlayLayerState extends ConsumerState<TextOverlayLayer> {
  TextOverlayScene? _scene;

  TextOverlayScene _sceneFor(TextLayoutEngine engine) {
    final s = _scene;
    if (s != null && identical(s.engine, engine)) return s;
    return _scene = TextOverlayScene(engine);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.projectId ?? EditorScope.idOf(context);
    final project = ref.watch(editorControllerProvider(id).select<EditProject?>((s) => s.project));
    final playhead = ref.watch(playheadProvider(id));
    final scene = _sceneFor(ref.watch(previewTextEngineProvider));
    return IgnorePointer(
      child: EditorContentTextRegion(
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: TextOverlayPainter(scene: scene, project: project, playhead: playhead, geometry: widget.geometry),
          ),
        ),
      ),
    );
  }
}
