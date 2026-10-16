// OWNER: FIX-A11Y
//
// ExpandedHitArea (ARCH §17.9 "touch targets ≥ 44×44", QA-08 FIX-UX-11-1, FIX-UX-14): gives a
// control that is laid out smaller than the minimum tap target a 44×44 hit area and screen-reader
// frame without growing its layout. A 32 px text lane keeps its 32 px header, a 40 px transport
// bar keeps its height; the button under it answers taps up to [minSize] around its centre.
//
// * Hit testing: a position inside the inflated rect is forwarded to the child clamped into the
//   child's bounds, so the child's own recognizers (DanaviewPressable) receive it. Ancestors still
//   hit-test their own bounds first, so the extra area works up to the edge of the enclosing region.
// * Semantics: the box is a semantics boundary that merges its descendants (the pressable's node
//   with its label, tooltip and actions) into one node whose rect is the inflated rect. Next to an
//   ancestor's clip edge (the last lane at the bottom of the header column) the rect is shifted
//   inward instead of being cut, so it keeps its full size.
// * Off ([enabled] false, or the child is already large enough): a plain pass-through.

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart' show DanaviewSpacing;

/// Expands the hit area and the semantics frame of [child] to at least [minSize] (centred),
/// without changing its layout.
class ExpandedHitArea extends SingleChildRenderObjectWidget {
  /// Creates the area.
  const ExpandedHitArea({
    super.key,
    required Widget super.child,
    this.minSize = const Size.square(DanaviewSpacing.minTapTarget),
    this.enabled = true,
  });

  /// The minimum hit and semantics size.
  final Size minSize;

  /// Whether the area expands (false: pass-through, e.g. on pointer platforms).
  final bool enabled;

  @override
  RenderExpandedHitArea createRenderObject(BuildContext context) => RenderExpandedHitArea(minSize: minSize, enabled: enabled);

  @override
  void updateRenderObject(BuildContext context, RenderExpandedHitArea renderObject) {
    renderObject
      ..minSize = minSize
      ..enabled = enabled;
  }
}

/// Render object of [ExpandedHitArea].
class RenderExpandedHitArea extends RenderProxyBox {
  /// Creates the render object.
  RenderExpandedHitArea({required Size minSize, bool enabled = true})
      : _minSize = minSize,
        _enabled = enabled;

  Size _minSize;

  /// The minimum hit and semantics size.
  Size get minSize => _minSize;
  set minSize(Size value) {
    if (value == _minSize) return;
    _minSize = value;
    markNeedsSemanticsUpdate();
  }

  bool _enabled;

  /// Whether the area expands.
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    markNeedsSemanticsUpdate();
  }

  bool get _expands => _enabled && hasSize && (size.width < _minSize.width || size.height < _minSize.height);

  /// The hit and semantics rect in local coordinates.
  Rect get expandedRect {
    final bounds = Offset.zero & size;
    if (!_expands) return bounds;
    final dx = math.max(0.0, (_minSize.width - size.width) / 2);
    final dy = math.max(0.0, (_minSize.height - size.height) / 2);
    return Rect.fromLTRB(bounds.left - dx, bounds.top - dy, bounds.right + dx, bounds.bottom + dy);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!_expands || size.contains(position)) return super.hitTest(result, position: position);
    if (!expandedRect.contains(position)) return false;
    final c = child;
    if (c == null || size.isEmpty) return false;
    // Forward to the nearest point inside the child so its recognizers take the pointer.
    final inside = Offset(
      position.dx.clamp(0.0, math.max(0.0, size.width - 0.01)),
      position.dy.clamp(0.0, math.max(0.0, size.height - 0.01)),
    );
    if (!c.hitTest(result, position: inside)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  Rect get semanticBounds {
    var rect = expandedRect;
    if (!_expands) return rect;
    // Shift (never shrink) the frame inside the paint clips of the ancestors, which would
    // otherwise cut it (the semantics geometry intersects every node with them).
    RenderObject child = this;
    var ancestor = parent;
    while (ancestor != null) {
      final clip = ancestor.describeApproximatePaintClip(child);
      if (clip != null) {
        final toAncestor = getTransformTo(ancestor);
        if (toAncestor.determinant() != 0) rect = _shiftInside(rect, MatrixUtils.inverseTransformRect(toAncestor, clip));
      }
      child = ancestor;
      ancestor = ancestor.parent;
    }
    return rect;
  }

  static Rect _shiftInside(Rect rect, Rect clip) {
    var dx = 0.0, dy = 0.0;
    if (rect.width <= clip.width) {
      if (rect.left < clip.left) dx = clip.left - rect.left;
      if (rect.right > clip.right) dx = clip.right - rect.right;
    }
    if (rect.height <= clip.height) {
      if (rect.top < clip.top) dy = clip.top - rect.top;
      if (rect.bottom > clip.bottom) dy = clip.bottom - rect.bottom;
    }
    return rect.shift(Offset(dx, dy));
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (!_enabled) return;
    config
      ..isSemanticBoundary = true
      ..isMergingSemanticsOfDescendants = true;
  }
}
