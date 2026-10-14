// OWNER: UX-23
//
// Mask handles on the preview (ux.md §7.5, §10.10). The mask is drawn in the composite view relative
// to the clip's box at the playhead (core `boxAt`): its centre, size and rotation are in the
// layer-normalized space of the clip (`[0, 1]²` over the cropped, fitted picture, ARCH §11.6
// "Mask"), so the outline goes through `ItemBox.fromLocalNormalized` and follows the clip's
// position, scale, rotation and flips.
//
// Handles: drag inside the shape to move it; four corner handles resize it around its centre
// (keeping its proportions when the panel's aspect lock is on); a rotate handle above the top edge
// rotates it (snapping to multiples of 45° within 3°); a small diamond outside the right edge sets
// the feather (its outward distance is the feather width `feather·0.25·min(w, h)`). Each drag is one
// `EditTransaction` ("Move mask", "Resize mask", "Rotate mask", "Feather mask") updating
// `SetProperty` at the playhead, so keyed properties get a key there; release commits one history
// entry.
//
// Only the shape and its handles take pointers; elsewhere the preview's manipulation overlay below
// keeps working. The math is in `MaskHandles` (pure, unit-tested).

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show ItemBox, Offset2, boxAt, evaluate;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SetProperty;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/transform_strings.dart';
import '../editor_scope.dart';
import '../state/editor_controller.dart';
import 'canvas_geometry.dart';

/// What a mask handle changes.
enum MaskHandle {
  /// Inside the shape: moves the centre.
  move,

  /// Top-left corner: size.
  topLeft,

  /// Top-right corner: size.
  topRight,

  /// Bottom-right corner: size.
  bottomRight,

  /// Bottom-left corner: size.
  bottomLeft,

  /// Above the top edge: rotation.
  rotate,

  /// Outside the right edge: feather.
  feather;

  /// Whether it is a corner.
  bool get isCorner => this == topLeft || this == topRight || this == bottomRight || this == bottomLeft;
}

/// The mask's outline and handles in the view, and the drag math (pure).
@immutable
class MaskHandles {
  const MaskHandles._({
    required this.geometry,
    required this.box,
    required this.mask,
    required this.outline,
    required this.center,
    required this.corners,
    required this.rotate,
    required this.rotateAnchor,
    required this.feather,
    required this.featherAnchor,
  });

  /// Lays out the handles of [mask] on the clip [box] shown through [geometry].
  factory MaskHandles.layout({required CanvasGeometry geometry, required ItemBox box, required MaskSpec mask}) {
    Offset view(Offset2 n) => geometry.toView2(box.fromLocalNormalized(n));
    final c = mask.center;
    final w = mask.size.x;
    final h = mask.size.y;
    Offset2 at(double x, double y) => _local(c, mask.rotationDeg, x, y);
    final outline = <Offset>[];
    if (mask.shape == MaskShape.ellipse) {
      for (var i = 0; i < 64; i++) {
        final a = i / 64 * 2 * math.pi;
        outline.add(view(at(math.cos(a) * w / 2, math.sin(a) * h / 2)));
      }
    } else {
      final r = mask.cornerRadius.clamp(0.0, 0.5) * math.min(w, h);
      final hw = w / 2, hh = h / 2;
      // Corner centres, clockwise from the top-right, each with its arc start angle.
      final arcs = [(hw - r, -hh + r, -math.pi / 2), (hw - r, hh - r, 0.0), (-hw + r, hh - r, math.pi / 2), (-hw + r, -hh + r, math.pi)];
      for (final (x, y, a0) in arcs) {
        final steps = r > 0 ? 8 : 1;
        for (var i = 0; i < steps; i++) {
          final a = a0 + (math.pi / 2) * (r > 0 ? i / (steps - 1) : 0);
          outline.add(view(at(x + math.cos(a) * r, y + math.sin(a) * r)));
        }
      }
    }
    final center = view(Offset2(c.x, c.y));
    final corners = [view(at(-w / 2, -h / 2)), view(at(w / 2, -h / 2)), view(at(w / 2, h / 2)), view(at(-w / 2, h / 2))];
    final topMid = view(at(0, -h / 2));
    final up = _unit(topMid - center, fallback: const Offset(0, -1));
    final rightMid = view(at(w / 2, 0));
    final out = _unit(rightMid - center, fallback: const Offset(1, 0));
    final f = mask.feather.clamp(0.0, 1.0) * 0.25 * math.min(w, h);
    final featherEdge = view(at(w / 2 + f, 0));
    return MaskHandles._(
      geometry: geometry,
      box: box,
      mask: mask,
      outline: outline,
      center: center,
      corners: corners,
      rotate: topMid + up * rotateOffset,
      rotateAnchor: topMid,
      feather: featherEdge + out * featherOffset,
      featherAnchor: rightMid,
    );
  }

  /// View px between the top edge and the rotate handle.
  static const double rotateOffset = 28;

  /// View px between the feathered edge and the feather handle.
  static const double featherOffset = 16;

  /// Rotation magnet: snaps within this many degrees of a multiple of 45°.
  static const double rotationSnap = 3;

  /// The mapping.
  final CanvasGeometry geometry;

  /// The clip box.
  final ItemBox box;

  /// The mask.
  final MaskSpec mask;

  /// The outline (view px).
  final List<Offset> outline;

  /// The centre (view px).
  final Offset center;

  /// The corners, clockwise from the top-left (view px).
  final List<Offset> corners;

  /// The rotate handle (view px).
  final Offset rotate;

  /// The top-edge midpoint the rotate handle hangs from.
  final Offset rotateAnchor;

  /// The feather handle (view px).
  final Offset feather;

  /// The right-edge midpoint (feather 0).
  final Offset featherAnchor;

  /// The outline as a path.
  Path get path => Path()..addPolygon(outline, true);

  /// The handle under [p] (view px) within [slop], or null.
  MaskHandle? hit(Offset p, {required double slop}) {
    if ((rotate - p).distance <= slop) return MaskHandle.rotate;
    if ((feather - p).distance <= slop) return MaskHandle.feather;
    const kinds = [MaskHandle.topLeft, MaskHandle.topRight, MaskHandle.bottomRight, MaskHandle.bottomLeft];
    for (var i = 0; i < 4; i++) {
      if ((corners[i] - p).distance <= slop) return kinds[i];
    }
    if (path.contains(p) || (center - p).distance <= slop) return MaskHandle.move;
    return null;
  }

  /// The layer-normalized point of the view point [p], or null for a degenerate box.
  Offset2? toNormalized(Offset p) => box.toLocalNormalized(geometry.toCanvas2(p));

  /// The mask centre after a move from the view point [from] to [to].
  Vec2 moved(Offset from, Offset to) {
    final a = toNormalized(from);
    final b = toNormalized(to);
    if (a == null || b == null) return mask.center;
    return PropertyKeys.maskCenter.clamp(Vec2(mask.center.x + b.dx - a.dx, mask.center.y + b.dy - a.dy));
  }

  /// The mask size with a corner at the view point [p] (resized around the centre); [lockAspect]
  /// keeps the proportions.
  Vec2 resized(Offset p, {bool lockAspect = false}) {
    final n = toNormalized(p);
    if (n == null) return mask.size;
    final q = _unrotate(mask.center, mask.rotationDeg, n);
    var w = 2 * q.dx.abs();
    var h = 2 * q.dy.abs();
    if (lockAspect && mask.size.x > 0 && mask.size.y > 0) {
      final t = (w / mask.size.x + h / mask.size.y) / 2;
      w = mask.size.x * t;
      h = mask.size.y * t;
    }
    return PropertyKeys.maskSize.clamp(Vec2(w, h));
  }

  /// The rotation with the rotate handle at the view point [p]: the angle of [p] around the
  /// centre (0° straight up, clockwise), continued from the current rotation, snapped to
  /// multiples of 45° within [rotationSnap] unless [snap] is false.
  double rotated(Offset p, {bool snap = true}) {
    final n = toNormalized(p);
    if (n == null) return mask.rotationDeg;
    final vx = n.dx - mask.center.x;
    final vy = n.dy - mask.center.y;
    if (vx == 0 && vy == 0) return mask.rotationDeg;
    var deg = math.atan2(vx, -vy) * 180 / math.pi;
    // Continue from the current angle (no jump across ±180°).
    deg += 360 * ((mask.rotationDeg - deg) / 360).roundToDouble();
    if (snap) {
      final nearest = (deg / 45).roundToDouble() * 45;
      if ((deg - nearest).abs() <= rotationSnap) deg = nearest;
    }
    return PropertyKeys.maskRotation.clamp(deg);
  }

  /// The feather with the feather handle at the view point [p]: its outward distance past the
  /// right edge (less [featherOffset]) over `0.25·min(w, h)`.
  double feathered(Offset p) {
    final dir = _unit(featherAnchor - center, fallback: const Offset(1, 0));
    final d = (p - featherAnchor).dx * dir.dx + (p - featherAnchor).dy * dir.dy - featherOffset;
    Offset view(Offset2 n) => geometry.toView2(box.fromLocalNormalized(n));
    final unit = (view(_local(mask.center, mask.rotationDeg, mask.size.x / 2 + 1, 0)) - featherAnchor).distance;
    final span = 0.25 * math.min(mask.size.x, mask.size.y);
    if (!(unit > 0) || !(span > 0)) return mask.feather;
    return PropertyKeys.maskFeather.clamp(math.max(0, d) / unit / span);
  }

  static Offset2 _local(Vec2 c, double deg, double x, double y) {
    final a = deg * math.pi / 180;
    final cos = math.cos(a), sin = math.sin(a);
    return Offset2(c.x + x * cos - y * sin, c.y + x * sin + y * cos);
  }

  static Offset _unrotate(Vec2 c, double deg, Offset2 n) {
    final a = -deg * math.pi / 180;
    final x = n.dx - c.x, y = n.dy - c.y;
    return Offset(x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a));
  }

  static Offset _unit(Offset v, {required Offset fallback}) {
    final d = v.distance;
    return d > 1e-9 ? v / d : fallback;
  }
}

/// Mask handles on the preview (ux.md §7.5).
class MaskOverlay extends ConsumerStatefulWidget {
  /// Creates the overlay for [item].
  const MaskOverlay({super.key, required this.geometry, required this.item, this.lockAspect = false});

  /// The canvas mapping of the preview.
  final CanvasGeometry geometry;

  /// The masked clip.
  final ItemId item;

  /// Whether corner drags keep the proportions.
  final bool lockAspect;

  @override
  ConsumerState<MaskOverlay> createState() => MaskOverlayState();
}

/// State of [MaskOverlay] (public for tests).
class MaskOverlayState extends ConsumerState<MaskOverlay> {
  EditTransaction? _tx;
  MaskHandle? _handle;
  MaskHandles? _start;
  Offset _origin = Offset.zero;
  MaskHandles? _shown;

  /// The handle being dragged.
  MaskHandle? get activeHandle => _handle;

  /// The handles as last laid out (tests).
  MaskHandles? get handles => _shown;

  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  bool get _touch => switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.android || TargetPlatform.fuchsia => true,
        _ => false,
      };

  double get _slop => _touch ? 22 : 12;

  @override
  void dispose() {
    final tx = _tx;
    _tx = null;
    if (tx != null && tx.isOpen) tx.commit();
    super.dispose();
  }

  TimeUs get _playhead => ref.read(playheadProvider(EditorScope.idOf(context))).value;

  /// The handles of the mask at [t], or null when the clip is not at the playhead or has no mask.
  MaskHandles? _layout(EditProject? project, TimeUs t) {
    if (project == null || widget.geometry.isEmpty) return null;
    final loc = project.index.locate(widget.item);
    final item = loc?.item;
    if (loc == null || item is! MediaClip || item.visual == null || loc.track.hidden) return null;
    if (!(item.start <= t && t < item.end)) return null;
    final mask = maskAt(item, t);
    if (mask.shape == MaskShape.none) return null;
    final box = boxAt(project, widget.item, t);
    if (box == null) return null;
    return MaskHandles.layout(geometry: widget.geometry, box: box, mask: mask);
  }

  void _onStart(DragStartDetails d) {
    final project = ref.read(editorControllerProvider(EditorScope.idOf(context))).project;
    final handles = _layout(project, _playhead);
    final handle = handles?.hit(d.localPosition, slop: _slop);
    if (handles == null || handle == null) return;
    _cancel();
    _handle = handle;
    _start = handles;
    _origin = d.localPosition;
    _tx = _editor.beginTransaction(switch (handle) {
      MaskHandle.move => TransformStrings.historyMoveMask,
      MaskHandle.rotate => TransformStrings.historyRotateMask,
      MaskHandle.feather => TransformStrings.historyFeatherMask,
      _ => TransformStrings.historyResizeMask,
    });
    setState(() {});
  }

  void _onUpdate(DragUpdateDetails d) {
    final tx = _tx;
    final handle = _handle;
    final start = _start;
    if (tx == null || !tx.isOpen || handle == null || start == null) return;
    final at = _playhead;
    final items = [widget.item];
    final p = d.localPosition;
    tx.update(switch (handle) {
      MaskHandle.move => SetProperty<Vec2>(items, PropertyKeys.maskCenter, start.moved(_origin, p), at: at),
      MaskHandle.rotate => SetProperty<double>(items, PropertyKeys.maskRotation, start.rotated(p), at: at),
      MaskHandle.feather => SetProperty<double>(items, PropertyKeys.maskFeather, start.feathered(p), at: at),
      _ => SetProperty<Vec2>(items, PropertyKeys.maskSize, start.resized(p, lockAspect: widget.lockAspect), at: at),
    });
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

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final project = ref.watch(editorControllerProvider(id).select((s) => s.project));
    final playhead = ref.watch(playheadProvider(id));
    return ValueListenableBuilder<TimeUs>(
      valueListenable: playhead,
      builder: (context, t, _) {
        final handles = _shown = _layout(project, t);
        if (handles == null) return const SizedBox.shrink();
        return Semantics(
          container: true,
          label: TransformStrings.maskFrame,
          hint: TransformStrings.maskFrameHint,
          child: RawGestureDetector(
            behavior: HitTestBehavior.deferToChild,
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
              painter: MaskPainter(handles: handles, active: _handle, slop: _slop),
            ),
          ),
        );
      },
    );
  }
}

/// The mask of [item] at absolute time [t] (keyframes evaluated).
MaskSpec maskAt(MediaClip item, TimeUs t) {
  final mask = item.visual?.mask ?? MaskSpec.none;
  if (mask.shape == MaskShape.none) return mask;
  final local = (t - item.start).clamp(0, math.max(0, item.duration - 1)).toInt();
  return mask.copyWith(
    center: evaluate(item, PropertyKeys.maskCenter, local),
    size: evaluate(item, PropertyKeys.maskSize, local),
    rotationDeg: evaluate(item, PropertyKeys.maskRotation, local),
    feather: evaluate(item, PropertyKeys.maskFeather, local),
    opacity: evaluate(item, PropertyKeys.maskOpacity, local),
  );
}

/// Paints the mask outline and its handles; hit-tests only the shape and the handles.
class MaskPainter extends CustomPainter {
  /// Creates the painter.
  const MaskPainter({required this.handles, this.active, this.slop = 22});

  /// The layout.
  final MaskHandles handles;

  /// The handle being dragged.
  final MaskHandle? active;

  /// Hit radius of the handles.
  final double slop;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = DanaviewColors.primaryLight
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(handles.path, line);
    final dashed = Paint()
      ..color = const Color(0x99FFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(handles.rotateAnchor, handles.rotate, dashed);
    canvas.drawLine(handles.featherAnchor, handles.feather, dashed);
    final fill = Paint()..color = DanaviewColors.textPrimary;
    final shadow = Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    for (final c in handles.corners) {
      canvas.drawCircle(c, 7, shadow);
      canvas.drawCircle(c, 6, fill);
    }
    // Centre cross.
    canvas.drawLine(handles.center - const Offset(6, 0), handles.center + const Offset(6, 0), line);
    canvas.drawLine(handles.center - const Offset(0, 6), handles.center + const Offset(0, 6), line);
    // Rotate handle.
    canvas.drawCircle(handles.rotate, 11, shadow);
    canvas.drawCircle(handles.rotate, 10, Paint()..color = DanaviewColors.surfaceElevatedHigher);
    canvas.drawCircle(
      handles.rotate,
      5,
      Paint()
        ..color = DanaviewColors.textPrimary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    // Feather diamond.
    final f = handles.feather;
    final diamond = Path()
      ..moveTo(f.dx, f.dy - 6)
      ..lineTo(f.dx + 6, f.dy)
      ..lineTo(f.dx, f.dy + 6)
      ..lineTo(f.dx - 6, f.dy)
      ..close();
    canvas.drawPath(diamond, shadow);
    canvas.drawPath(diamond, Paint()..color = active == MaskHandle.feather ? DanaviewColors.primaryLight : DanaviewColors.textPrimary);
  }

  @override
  bool? hitTest(Offset position) => handles.hit(position, slop: slop) != null;

  @override
  bool shouldRepaint(MaskPainter old) =>
      old.handles.mask != handles.mask || old.handles.box != handles.box || old.handles.geometry != handles.geometry || old.active != active;
}
