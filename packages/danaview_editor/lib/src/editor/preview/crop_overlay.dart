// OWNER: UX-23
//
// Crop mode on the preview (ux.md §7.5) and the preview tool modes of UX-23.
//
// Preview tool modes. Crop, mask and eyedropper editing take over the preview while their panel (or
// a colour field's eyedropper) is active. `PreviewToolController` (one per open project,
// `previewToolProvider`) holds the active tool and drives the native editing mode:
//
//   CropPreviewTool(item)        preview.setEditingMode(cropSource(item)): native shows the clip's
//                                uncropped, untransformed source fitted to the canvas (native.md §4.8)
//   MaskPreviewTool(item)        the normal composite; MaskOverlay draws the shape and its handles
//   EyedropperPreviewTool(item)  the normal composite; EyedropperOverlay samples the pre-key source
//
// `PreviewToolLayer(geometry)` shows the overlay of the active tool and nothing otherwise; it is
// meant to sit above the manipulation overlay in the preview region's stack (UX-18 mounts it). An
// eyedropper pick started while crop or mask is active returns to that tool afterwards.
//
// Crop. `CropOverlay` maps the normalized, display-oriented crop (`CropRect`) onto the source
// rectangle (the source contain-fitted into the canvas, then letterboxed into the view by
// `CanvasGeometry`) and draws the outside dimmed, the frame, a rule-of-thirds grid and eight handles
// (corners and edges). Dragging a handle resizes, dragging inside moves; with an aspect chosen in
// the crop panel the frame keeps it. Each drag is one `EditTransaction` labelled "Crop" updating
// `SetCrop`, committed on release (one history entry, one plan patch); a cancelled drag restores
// the crop. The crop math is in `CropMath` (pure, unit-tested).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show Size2, sourceDisplaySize;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SetCrop;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show CropSourceMode, PreviewEditingMode, PreviewSession;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/transform_strings.dart';
import '../editor_scope.dart';
import '../state/editor_controller.dart';
import 'canvas_geometry.dart';
import 'eyedropper_overlay.dart';
import 'mask_overlay.dart';

// =================================================================================================
// Preview tool modes
// =================================================================================================

/// A tool that takes over the preview (ux.md §7.5).
@immutable
sealed class PreviewTool {
  const PreviewTool(this.item);

  /// The item the tool edits.
  final ItemId item;
}

/// Crop mode on [item]; [aspect] is the aspect chip chosen in the crop panel.
final class CropPreviewTool extends PreviewTool {
  /// Creates the tool.
  const CropPreviewTool(super.item, {this.aspect = CropAspect.free});

  /// The aspect the frame keeps while dragging.
  final CropAspect aspect;

  @override
  bool operator ==(Object other) => other is CropPreviewTool && other.item == item && other.aspect == aspect;

  @override
  int get hashCode => Object.hash(item, aspect);

  @override
  String toString() => 'CropPreviewTool($item, $aspect)';
}

/// Mask handles on [item]; [lockAspect] keeps the proportions when a corner is dragged.
final class MaskPreviewTool extends PreviewTool {
  /// Creates the tool.
  const MaskPreviewTool(super.item, {this.lockAspect = false});

  /// Whether corner drags keep the mask's proportions.
  final bool lockAspect;

  @override
  bool operator ==(Object other) => other is MaskPreviewTool && other.item == item && other.lockAspect == lockAspect;

  @override
  int get hashCode => Object.hash(item, lockAspect);

  @override
  String toString() => 'MaskPreviewTool($item${lockAspect ? ', locked' : ''})';
}

/// Colour picking on [item] (chroma key colour, colour fields).
final class EyedropperPreviewTool extends PreviewTool {
  const EyedropperPreviewTool._(super.item, this._completer, this.onSample);

  final Completer<Color?> _completer;

  /// Called with every colour sampled while dragging (live preview in the caller), or null.
  final ValueChanged<Color>? onSample;

  @override
  String toString() => 'EyedropperPreviewTool($item)';
}

/// The active preview tool of one project and the native editing mode it needs (see the file
/// comment).
class PreviewToolController extends ValueNotifier<PreviewTool?> {
  /// Creates the controller; [preview] returns the live preview session (or null).
  PreviewToolController(this._preview) : super(null);

  final PreviewSession? Function() _preview;
  PreviewTool? _resume;
  PreviewSession? _modeSession;
  bool _disposed = false;

  /// The editing mode last sent to the preview.
  @visibleForTesting
  PreviewEditingMode sentMode = PreviewEditingMode.normal;

  /// Enters crop mode on [item] (keeps the chosen aspect when crop is already on for it).
  void enterCrop(ItemId item) {
    final current = value;
    if (current is CropPreviewTool && current.item == item) return;
    _cancelPick();
    _set(CropPreviewTool(item));
  }

  /// The aspect the crop frame keeps.
  void setCropAspect(CropAspect aspect) {
    final current = value;
    if (current is CropPreviewTool) _set(CropPreviewTool(current.item, aspect: aspect));
    final resume = _resume;
    if (resume is CropPreviewTool) _resume = CropPreviewTool(resume.item, aspect: aspect);
  }

  /// Shows the mask handles of [item].
  void enterMask(ItemId item, {bool lockAspect = false}) {
    final current = value;
    if (current is MaskPreviewTool && current.item == item && current.lockAspect == lockAspect) return;
    if (current is! EyedropperPreviewTool) {
      _set(MaskPreviewTool(item, lockAspect: lockAspect));
    } else {
      _resume = MaskPreviewTool(item, lockAspect: lockAspect);
    }
  }

  /// Leaves [tool]'s kind of mode for [item] (when it is the active one or the one an eyedropper
  /// pick returns to).
  void exit<T extends PreviewTool>(ItemId item) {
    final resume = _resume;
    if (resume is T && resume.item == item) _resume = null;
    final current = value;
    if (current is T && current.item == item) {
      if (current is EyedropperPreviewTool) {
        _finish(current, null);
      } else {
        _set(null);
      }
    }
  }

  /// Runs [body] after the current frame (or at once outside a frame): panels enter and leave preview
/// tools from build and dispose, where notifying the preview layer is not allowed.
void afterFrame(VoidCallback body) {
  final binding = WidgetsBinding.instance;
  if (binding.schedulerPhase == SchedulerPhase.idle) {
    scheduleMicrotask(body);
  } else {
    binding.addPostFrameCallback((_) => body());
  }
}

/// Picks a colour of [item] on the preview (ux.md §7.5): shows the eyedropper overlay and
  /// completes with the colour sampled where the finger is released, or null when the pick is
  /// cancelled. [onSample] receives the colours sampled while dragging (≤ 15 Hz).
  Future<Color?> pickColor(ItemId item, {ValueChanged<Color>? onSample}) {
    final current = value;
    if (current is EyedropperPreviewTool) _finish(current, null);
    final completer = Completer<Color?>();
    if (_disposed) {
      completer.complete(null);
      return completer.future;
    }
    final active = value;
    _resume = active is EyedropperPreviewTool ? _resume : active;
    _set(EyedropperPreviewTool._(item, completer, onSample));
    return completer.future;
  }

  /// Completes the active pick with [color] (null cancels) and returns to the previous tool.
  void finishPick(Color? color) {
    final current = value;
    if (current is EyedropperPreviewTool) _finish(current, color);
  }

  /// Cancels the active pick; true when there was one.
  bool cancelPick() {
    final current = value;
    if (current is! EyedropperPreviewTool) return false;
    _finish(current, null);
    return true;
  }

  void _cancelPick() {
    final current = value;
    if (current is EyedropperPreviewTool) _finish(current, null);
  }

  void _finish(EyedropperPreviewTool tool, Color? color) {
    if (!tool._completer.isCompleted) tool._completer.complete(color);
    final resume = _resume;
    _resume = null;
    if (identical(value, tool)) _set(resume);
  }

  void _set(PreviewTool? tool) {
    if (_disposed) return;
    value = tool;
    _syncMode();
  }

  void _syncMode() {
    final active = value;
    final tool = active is EyedropperPreviewTool ? _resume : active;
    final want = tool is CropPreviewTool ? CropSourceMode(tool.item) : PreviewEditingMode.normal;
    if (_sameMode(want, sentMode)) return;
    sentMode = want;
    final session = want is CropSourceMode ? _preview() : _modeSession;
    _modeSession = want is CropSourceMode ? session : null;
    if (session == null) return;
    unawaited(_quietly(() => session.setEditingMode(want)));
  }

  static bool _sameMode(PreviewEditingMode a, PreviewEditingMode b) =>
      a is CropSourceMode ? b is CropSourceMode && b.item == a.item : b is! CropSourceMode && a.runtimeType == b.runtimeType;

  static Future<void> _quietly(Future<void> Function() body) async {
    try {
      await body();
    } catch (_) {}
  }

  @override
  void dispose() {
    final current = value;
    if (current is EyedropperPreviewTool && !current._completer.isCompleted) current._completer.complete(null);
    _resume = null;
    if (value != null) {
      value = null;
      _syncMode();
    }
    _disposed = true;
    super.dispose();
  }
}

/// The preview tool controller of the project (kept alive while a tool is active).
final previewToolProvider = Provider.autoDispose.family<PreviewToolController, ProjectId>((ref, id) {
  final controller = PreviewToolController(() => ref.read(editorSessionProvider(id)).preview);
  KeepAliveLink? link;
  void keep() {
    if (controller.value != null) {
      link ??= ref.keepAlive();
    } else {
      link?.close();
      link = null;
    }
  }

  controller.addListener(keep);
  ref.onDispose(controller.dispose);
  return controller;
}, name: 'previewToolProvider');

/// Runs [body] after the current frame (or at once outside a frame): panels enter and leave preview
/// tools from build and dispose, where notifying the preview layer is not allowed.
void afterFrame(VoidCallback body) {
  final binding = WidgetsBinding.instance;
  if (binding.schedulerPhase == SchedulerPhase.idle) {
    scheduleMicrotask(body);
  } else {
    binding.addPostFrameCallback((_) => body());
  }
}

/// Picks a colour of [item] on the preview of the open project (colour fields, the chroma key
/// panel); see [PreviewToolController.pickColor].
Future<Color?> pickPreviewColor(WidgetRef ref, ProjectId project, ItemId item, {ValueChanged<Color>? onSample}) =>
    ref.read(previewToolProvider(project)).pickColor(item, onSample: onSample);

/// The overlay of the active preview tool (see the file comment); empty and transparent to
/// pointers when no tool is active.
class PreviewToolLayer extends ConsumerWidget {
  /// Creates the layer.
  const PreviewToolLayer({super.key, required this.geometry});

  /// The canvas mapping of the preview.
  final CanvasGeometry geometry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(previewToolProvider(EditorScope.idOf(context)));
    return ValueListenableBuilder<PreviewTool?>(
      valueListenable: controller,
      builder: (context, tool, _) => switch (tool) {
        null => const SizedBox.shrink(),
        CropPreviewTool() => CropOverlay(key: ValueKey<Object>('crop:${tool.item}'), geometry: geometry, item: tool.item, aspect: tool.aspect),
        MaskPreviewTool() =>
          MaskOverlay(key: ValueKey<Object>('mask:${tool.item}'), geometry: geometry, item: tool.item, lockAspect: tool.lockAspect),
        EyedropperPreviewTool() => EyedropperOverlay(
            key: ValueKey<Object>(tool),
            geometry: geometry,
            item: tool.item,
            onSample: tool.onSample,
            onDone: controller.finishPick,
          ),
      },
    );
  }
}

// =================================================================================================
// Crop math
// =================================================================================================

/// The aspect chips of crop mode (ux.md §7.5).
enum CropAspect {
  /// No constraint.
  free(null, null),

  /// The source's own aspect.
  original(null, null),

  /// 16:9.
  r16x9(16, 9),

  /// 9:16.
  r9x16(9, 16),

  /// 1:1.
  r1x1(1, 1),

  /// 4:5.
  r4x5(4, 5),

  /// 4:3.
  r4x3(4, 3);

  const CropAspect(this.w, this.h);

  /// Width part of the ratio (null for free and original).
  final int? w;

  /// Height part of the ratio.
  final int? h;

  /// The chip label ("16:9", "Free").
  String get label => switch (this) {
        CropAspect.free => TransformStrings.aspectFree,
        CropAspect.original => TransformStrings.aspectOriginal,
        _ => '$w:$h',
      };

  /// The width/height ratio in source pixels, or null for free.
  double? pixelRatio(Size2 source) => switch (this) {
        CropAspect.free => null,
        CropAspect.original => source.width / source.height,
        _ => w! / h!,
      };
}

/// A crop handle (ux.md §7.5: corners, edges, and the frame itself).
enum CropHandle {
  /// Top-left corner.
  topLeft(-1, -1),

  /// Top edge.
  top(0, -1),

  /// Top-right corner.
  topRight(1, -1),

  /// Right edge.
  right(1, 0),

  /// Bottom-right corner.
  bottomRight(1, 1),

  /// Bottom edge.
  bottom(0, 1),

  /// Bottom-left corner.
  bottomLeft(-1, 1),

  /// Left edge.
  left(-1, 0),

  /// Inside the frame: moves it.
  move(0, 0);

  const CropHandle(this.sx, this.sy);

  /// −1 for a handle on the left, 1 on the right, 0 in the middle.
  final int sx;

  /// −1 for a handle on the top, 1 on the bottom, 0 in the middle.
  final int sy;

  /// Whether it is a corner.
  bool get isCorner => sx != 0 && sy != 0;
}

/// Crop geometry (pure; normalized source coordinates, ux.md §7.5).
abstract final class CropMath {
  /// The smallest crop side, as a fraction of the source side.
  static const double minSize = 0.05;

  /// The rect (view px) where crop mode shows the source of [source] px: contain-fitted into the
  /// canvas and letterboxed by [geometry] (native.md §4.8 `cropSource`).
  static Rect sourceRect(CanvasGeometry geometry, Size2 source) {
    if (geometry.isEmpty || !source.isPositive) return Rect.zero;
    final canvas = geometry.canvasPx;
    final s = math.min(canvas.width / source.width, canvas.height / source.height);
    final w = source.width * s;
    final h = source.height * s;
    final topLeft = geometry.toView(Offset((canvas.width - w) / 2, (canvas.height - h) / 2));
    return topLeft & Size(geometry.canvasToViewLength(w), geometry.canvasToViewLength(h));
  }

  /// [crop] in the view, inside [source] (the [sourceRect]).
  static Rect toView(CropRect crop, Rect source) => Rect.fromLTRB(
        source.left + crop.left * source.width,
        source.top + crop.top * source.height,
        source.left + crop.right * source.width,
        source.top + crop.bottom * source.height,
      );

  /// The ratio of a crop's normalized width to its normalized height that shows [pixelRatio]
  /// (width/height in px) of a [source] of that many px.
  static double normalizedRatio(double pixelRatio, Size2 source) => pixelRatio * source.height / source.width;

  /// The crop size in source px.
  static (int, int) pixels(CropRect crop, Size2 source) =>
      ((source.width * (crop.right - crop.left)).round(), (source.height * (crop.bottom - crop.top)).round());

  /// The largest crop of [aspect] centred where [current] is centred (shifted to stay inside the
  /// source); [current] itself for free, the full source for original.
  static CropRect forAspect(CropRect current, CropAspect aspect, Size2 source) {
    if (aspect == CropAspect.free) return current;
    if (aspect == CropAspect.original) return CropRect.full;
    final r = normalizedRatio(aspect.pixelRatio(source)!, source);
    var w = math.min(1.0, r);
    var h = w / r;
    if (h > 1) {
      h = 1;
      w = r;
    }
    final cx = (current.left + current.right) / 2;
    final cy = (current.top + current.bottom) / 2;
    final l = (cx - w / 2).clamp(0.0, 1 - w);
    final t = (cy - h / 2).clamp(0.0, 1 - h);
    return _tidy(CropRect(left: l, top: t, right: l + w, bottom: t + h));
  }

  /// The aspect chip [crop] matches (within one source pixel), or null; the full source is
  /// [CropAspect.original].
  static CropAspect? matching(CropRect crop, Size2 source) {
    if (crop.isFull) return CropAspect.original;
    final (w, h) = (source.width * (crop.right - crop.left), source.height * (crop.bottom - crop.top));
    if (!(w > 0 && h > 0)) return null;
    for (final a in CropAspect.values) {
      final ratio = a.pixelRatio(source);
      if (ratio == null || a == CropAspect.original) continue;
      if ((w - h * ratio).abs() <= 1) return a;
    }
    return null;
  }

  /// [start] after dragging [handle] by [delta] (normalized source units); [ratio] is the
  /// normalized width/height ratio to keep, or null for free. The result stays inside the source
  /// and at least [minSize] on each side.
  static CropRect drag(CropRect start, CropHandle handle, Offset delta, {double? ratio}) {
    if (handle == CropHandle.move) {
      final w = start.right - start.left;
      final h = start.bottom - start.top;
      final l = (start.left + delta.dx).clamp(0.0, 1 - w);
      final t = (start.top + delta.dy).clamp(0.0, 1 - h);
      return _tidy(CropRect(left: l, top: t, right: l + w, bottom: t + h));
    }
    if (ratio == null || !(ratio > 0)) return _free(start, handle, delta);
    return _locked(start, handle, delta, ratio);
  }

  static CropRect _free(CropRect s, CropHandle h, Offset d) {
    var l = s.left, t = s.top, r = s.right, b = s.bottom;
    if (h.sx < 0) l = (l + d.dx).clamp(0.0, r - minSize);
    if (h.sx > 0) r = (r + d.dx).clamp(l + minSize, 1.0);
    if (h.sy < 0) t = (t + d.dy).clamp(0.0, b - minSize);
    if (h.sy > 0) b = (b + d.dy).clamp(t + minSize, 1.0);
    return _tidy(CropRect(left: l, top: t, right: r, bottom: b));
  }

  static CropRect _locked(CropRect s, CropHandle h, Offset d, double ratio) {
    final w0 = s.right - s.left;
    final h0 = s.bottom - s.top;
    final minW = math.max(minSize, minSize * ratio);
    if (h.isCorner) {
      // The opposite corner stays; the new width follows the mean relative change of both axes.
      final ax = h.sx > 0 ? s.left : s.right;
      final ay = h.sy > 0 ? s.top : s.bottom;
      final fw = (w0 + h.sx * d.dx) / w0;
      final fh = (h0 + h.sy * d.dy) / h0;
      var w = w0 * (fw + fh) / 2;
      final maxW = math.min(h.sx > 0 ? 1 - ax : ax, (h.sy > 0 ? 1 - ay : ay) * ratio);
      w = w.clamp(math.min(minW, maxW), maxW);
      final hh = w / ratio;
      final l = h.sx > 0 ? ax : ax - w;
      final t = h.sy > 0 ? ay : ay - hh;
      return _tidy(CropRect(left: l, top: t, right: l + w, bottom: t + hh));
    }
    if (h.sx != 0) {
      // A side edge: the opposite edge stays, the height follows around the vertical centre.
      final ax = h.sx > 0 ? s.left : s.right;
      final cy = (s.top + s.bottom) / 2;
      var w = w0 + h.sx * d.dx;
      final maxW = math.min(h.sx > 0 ? 1 - ax : ax, 2 * math.min(cy, 1 - cy) * ratio);
      w = w.clamp(math.min(minW, maxW), maxW);
      final hh = w / ratio;
      final l = h.sx > 0 ? ax : ax - w;
      return _tidy(CropRect(left: l, top: cy - hh / 2, right: l + w, bottom: cy + hh / 2));
    }
    // A top or bottom edge: the opposite edge stays, the width follows around the horizontal centre.
    final ay = h.sy > 0 ? s.top : s.bottom;
    final cx = (s.left + s.right) / 2;
    var hh = h0 + h.sy * d.dy;
    final maxH = math.min(h.sy > 0 ? 1 - ay : ay, 2 * math.min(cx, 1 - cx) / ratio);
    hh = hh.clamp(math.min(minW / ratio, maxH), maxH);
    final w = hh * ratio;
    final t = h.sy > 0 ? ay : ay - hh;
    return _tidy(CropRect(left: cx - w / 2, top: t, right: cx + w / 2, bottom: t + hh));
  }

  /// [crop] grown (positive [by]) or shrunk around its centre by [by] of its size, inside the
  /// source and keeping its aspect.
  static CropRect scale(CropRect crop, double by) {
    final cx = (crop.left + crop.right) / 2;
    final cy = (crop.top + crop.bottom) / 2;
    final w0 = crop.right - crop.left;
    final h0 = crop.bottom - crop.top;
    var f = 1 + by;
    f = math.min(f, math.min(1 / w0, 1 / h0));
    f = math.max(f, math.max(minSize / w0, minSize / h0));
    final w = w0 * f;
    final h = h0 * f;
    final l = (cx - w / 2).clamp(0.0, 1 - w);
    final t = (cy - h / 2).clamp(0.0, 1 - h);
    return _tidy(CropRect(left: l, top: t, right: l + w, bottom: t + h));
  }

  /// Rounds away float noise (1e-9) and keeps the edges in [0, 1].
  static CropRect _tidy(CropRect c) {
    double q(double v) => ((v * 1e9).roundToDouble() / 1e9).clamp(0.0, 1.0);
    return CropRect(left: q(c.left), top: q(c.top), right: q(c.right), bottom: q(c.bottom));
  }

  /// The handle of [crop] (in the view) under [point], or null; [slop] is the hit radius.
  static CropHandle? hit(Rect crop, Offset point, {required double slop}) {
    for (final h in CropHandle.values) {
      if (h == CropHandle.move) continue;
      if ((handlePoint(crop, h) - point).distance <= slop) return h;
    }
    // Edges anywhere along their length.
    if (point.dy >= crop.top && point.dy <= crop.bottom) {
      if ((point.dx - crop.left).abs() <= slop / 2) return CropHandle.left;
      if ((point.dx - crop.right).abs() <= slop / 2) return CropHandle.right;
    }
    if (point.dx >= crop.left && point.dx <= crop.right) {
      if ((point.dy - crop.top).abs() <= slop / 2) return CropHandle.top;
      if ((point.dy - crop.bottom).abs() <= slop / 2) return CropHandle.bottom;
    }
    return crop.contains(point) ? CropHandle.move : null;
  }

  /// Where [handle] sits on [crop] (view px).
  static Offset handlePoint(Rect crop, CropHandle handle) =>
      Offset(crop.center.dx + handle.sx * crop.width / 2, crop.center.dy + handle.sy * crop.height / 2);
}

/// The display-oriented picture size of [item] (falls back to the media a derived still or
/// reversed rendition is made from), or null when unknown.
Size2? pictureSizeOf(EditProject project, TimelineItem item) {
  if (item is! MediaClip) return null;
  final asset = project.pool[item.media];
  if (asset == null) return null;
  final own = sourceDisplaySize(asset.probe);
  if (own != null) return own;
  final from = switch (asset.derived) {
    StillSpec(:final media) => project.pool[media],
    ReversedSpec(:final media) => project.pool[media],
    null => null,
  };
  return from == null ? null : sourceDisplaySize(from.probe);
}

// =================================================================================================
// Crop overlay
// =================================================================================================

/// Crop handles on the preview (ux.md §7.5).
class CropOverlay extends ConsumerStatefulWidget {
  /// Creates the overlay for [item].
  const CropOverlay({super.key, required this.geometry, required this.item, this.aspect = CropAspect.free});

  /// The canvas mapping of the preview.
  final CanvasGeometry geometry;

  /// The clip being cropped.
  final ItemId item;

  /// The aspect the frame keeps.
  final CropAspect aspect;

  @override
  ConsumerState<CropOverlay> createState() => CropOverlayState();
}

/// State of [CropOverlay] (public for tests).
class CropOverlayState extends ConsumerState<CropOverlay> {
  EditTransaction? _tx;
  CropHandle? _handle;
  CropRect? _start;
  Offset _origin = Offset.zero;

  /// The handle being dragged, or null.
  CropHandle? get activeHandle => _handle;

  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  bool get _touch => switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.android || TargetPlatform.fuchsia => true,
        _ => false,
      };

  @override
  void dispose() {
    final tx = _tx;
    _tx = null;
    if (tx != null && tx.isOpen) tx.commit();
    super.dispose();
  }

  (MediaClip, Size2)? _target() {
    final project = ref.read(editorControllerProvider(EditorScope.idOf(context))).project;
    final item = project?.index.item(widget.item);
    if (project == null || item is! MediaClip || item.visual == null) return null;
    final size = pictureSizeOf(project, item);
    return size == null ? null : (item, size);
  }

  void _onStart(DragStartDetails d) {
    final target = _target();
    if (target == null) return;
    final (clip, source) = target;
    final src = CropMath.sourceRect(widget.geometry, source);
    final handle = CropMath.hit(CropMath.toView(clip.visual!.crop, src), d.localPosition, slop: _touch ? 22 : 12);
    if (handle == null) return;
    _cancel();
    _handle = handle;
    _start = clip.visual!.crop;
    _origin = d.localPosition;
    _tx = _editor.beginTransaction(TransformStrings.historyCrop);
    setState(() {});
  }

  void _onUpdate(DragUpdateDetails d) {
    final tx = _tx;
    final handle = _handle;
    final start = _start;
    final target = _target();
    if (tx == null || !tx.isOpen || handle == null || start == null || target == null) return;
    final (_, source) = target;
    final src = CropMath.sourceRect(widget.geometry, source);
    if (src.isEmpty) return;
    final delta = d.localPosition - _origin;
    final ratioPx = widget.aspect.pixelRatio(source);
    final next = CropMath.drag(
      start,
      handle,
      Offset(delta.dx / src.width, delta.dy / src.height),
      ratio: ratioPx == null ? null : CropMath.normalizedRatio(ratioPx, source),
    );
    tx.update(SetCrop([widget.item], next));
  }

  void _onEnd([DragEndDetails? _]) {
    final tx = _tx;
    _tx = null;
    _handle = null;
    _start = null;
    if (tx != null && tx.isOpen) tx.commit();
    if (mounted) setState(() {});
  }

  void _cancel() {
    final tx = _tx;
    _tx = null;
    _handle = null;
    _start = null;
    if (tx != null && tx.isOpen) tx.cancel();
  }

  void _step(double by) {
    final target = _target();
    if (target == null) return;
    final (clip, _) = target;
    _editor.apply(SetCrop([widget.item], CropMath.scale(clip.visual!.crop, by)));
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final project = ref.watch(editorControllerProvider(id).select((s) => s.project));
    final item = project?.index.item(widget.item);
    if (project == null || item is! MediaClip || item.visual == null) return const SizedBox.shrink();
    final source = pictureSizeOf(project, item);
    if (source == null) return const SizedBox.shrink();
    final src = CropMath.sourceRect(widget.geometry, source);
    final crop = item.visual!.crop;
    String sized(CropRect c) {
      final (w, h) = CropMath.pixels(c, source);
      return TransformStrings.cropSize(w, h);
    }

    return Semantics(
      container: true,
      label: TransformStrings.cropFrame,
      hint: TransformStrings.cropFrameHint,
      value: sized(crop),
      increasedValue: sized(CropMath.scale(crop, 0.05)),
      decreasedValue: sized(CropMath.scale(crop, -0.05)),
      onIncrease: () => _step(0.05),
      onDecrease: () => _step(-0.05),
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          PanGestureRecognizer: GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
            () => PanGestureRecognizer(debugOwner: this),
            (r) => r
              ..dragStartBehavior = DragStartBehavior.down
              ..onStart = _onStart
              ..onUpdate = _onUpdate
              ..onEnd = _onEnd
              ..onCancel = _cancel,
          ),
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: CropPainter(source: src, crop: CropMath.toView(crop, src), active: _handle),
        ),
      ),
    );
  }
}

/// Paints crop mode: the outside of the crop dimmed, the frame, the thirds and eight handles.
class CropPainter extends CustomPainter {
  /// Creates the painter.
  const CropPainter({required this.source, required this.crop, this.active});

  /// The source rect (view px).
  final Rect source;

  /// The crop rect (view px).
  final Rect crop;

  /// The handle being dragged.
  final CropHandle? active;

  @override
  void paint(Canvas canvas, Size size) {
    if (source.isEmpty) return;
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(source)
      ..addRect(crop);
    canvas.drawPath(outside, Paint()..color = DanaviewColors.scrim);
    final grid = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = crop.left + crop.width * i / 3;
      final y = crop.top + crop.height * i / 3;
      canvas.drawLine(Offset(x, crop.top), Offset(x, crop.bottom), grid);
      canvas.drawLine(Offset(crop.left, y), Offset(crop.right, y), grid);
    }
    canvas.drawRect(
      crop,
      Paint()
        ..color = DanaviewColors.primaryLight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final fill = Paint()..color = DanaviewColors.textPrimary;
    final shadow = Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    for (final h in CropHandle.values) {
      if (h == CropHandle.move) continue;
      final p = CropMath.handlePoint(crop, h);
      final r = h == active ? 8.0 : 6.0;
      if (h.isCorner) {
        canvas.drawCircle(p, r + 1, shadow);
        canvas.drawCircle(p, r, fill);
      } else {
        final bar = h.sx == 0 ? Rect.fromCenter(center: p, width: 22, height: 6) : Rect.fromCenter(center: p, width: 6, height: 22);
        final rr = RRect.fromRectAndRadius(bar, const Radius.circular(3));
        canvas.drawRRect(rr.inflate(1), shadow);
        canvas.drawRRect(rr, fill);
      }
    }
  }

  @override
  bool shouldRepaint(CropPainter old) => old.source != source || old.crop != crop || old.active != active;
}
