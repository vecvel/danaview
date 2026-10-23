// OWNER: HOM-10
//
// A virtualised sliver over a [PhotoMasonryLayout] (ARCH v1.2 V2-102, §10.1): it builds and lays
// out only the children between the first one ending after the cache window's start and the last
// one starting before its end (two binary searches), garbage-collects the rest, and reports the
// exact scroll extent the layout computed, so a jump anywhere in a 50,000-photo library costs the
// same as a scroll of one row. Children get tight constraints from their rect.

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'photo_masonry_layout.dart';

/// Places [delegate]'s children at the rects of [layout].
class SliverPhotoMasonry extends SliverMultiBoxAdaptorWidget {
  /// A sliver of [layout]'s children built by [delegate] (its child count must be
  /// `layout.childCount`).
  const SliverPhotoMasonry({super.key, required super.delegate, required this.layout});

  /// The rects.
  final PhotoMasonryLayout layout;

  @override
  RenderSliverPhotoMasonry createRenderObject(BuildContext context) =>
      RenderSliverPhotoMasonry(childManager: context as SliverMultiBoxAdaptorElement, masonry: layout);

  @override
  void updateRenderObject(BuildContext context, RenderSliverPhotoMasonry renderObject) {
    renderObject.masonry = layout;
  }
}

/// The render object of [SliverPhotoMasonry].
class RenderSliverPhotoMasonry extends RenderSliverMultiBoxAdaptor {
  /// A render sliver over [masonry].
  RenderSliverPhotoMasonry({required super.childManager, required PhotoMasonryLayout masonry}) : _layout = masonry;

  PhotoMasonryLayout _layout;

  /// The rects.
  PhotoMasonryLayout get masonry => _layout;
  set masonry(PhotoMasonryLayout value) {
    if (identical(value, _layout)) return;
    _layout = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! SliverGridParentData) child.parentData = SliverGridParentData();
  }

  @override
  double childCrossAxisPosition(RenderBox child) => (child.parentData! as SliverGridParentData).crossAxisOffset ?? 0;

  BoxConstraints _constraintsOf(int index) =>
      BoxConstraints.tightFor(width: _layout.widthOf(index), height: _layout.heightOf(index));

  void _place(RenderBox child, int index) {
    final data = child.parentData! as SliverGridParentData;
    data.layoutOffset = _layout.topOf(index);
    data.crossAxisOffset = _layout.leftOf(index);
  }

  @override
  void performLayout() {
    final constraints = this.constraints;
    childManager.didStartLayout();
    childManager.setDidUnderflow(false);
    final layout = _layout;
    final total = layout.totalExtent;
    final scrollOffset = constraints.scrollOffset + constraints.cacheOrigin;
    final targetEnd = scrollOffset + constraints.remainingCacheExtent;
    final range = layout.childCount == 0 || childManager.childCount == 0 ? null : layout.visibleRange(scrollOffset, targetEnd);

    if (range == null) {
      collectGarbage(childCount, 0);
      geometry = SliverGeometry(scrollExtent: total, maxPaintExtent: total);
      childManager.didFinishLayout();
      return;
    }
    final lastAllowed = math.min(childManager.childCount, layout.childCount) - 1;
    final firstIndex = math.min(range.$1, lastAllowed);
    final targetLastIndex = math.min(range.$2, lastAllowed);

    if (firstChild != null) {
      collectGarbage(calculateLeadingGarbage(firstIndex: firstIndex), calculateTrailingGarbage(lastIndex: targetLastIndex));
    } else {
      collectGarbage(0, 0);
    }

    if (firstChild == null) {
      if (!addInitialChild(index: firstIndex, layoutOffset: layout.topOf(firstIndex))) {
        geometry = SliverGeometry(scrollExtent: total, maxPaintExtent: total);
        childManager.didFinishLayout();
        return;
      }
    }

    var leading = layout.topOf(firstIndex);
    var trailing = layout.bottomOf(firstIndex);
    RenderBox? trailingWithLayout;

    for (var index = indexOf(firstChild!) - 1; index >= firstIndex; --index) {
      final child = insertAndLayoutLeadingChild(_constraintsOf(index));
      if (child == null) break;
      _place(child, index);
      trailingWithLayout ??= child;
      trailing = math.max(trailing, layout.bottomOf(index));
    }

    if (trailingWithLayout == null) {
      final first = firstChild!;
      final index = indexOf(first);
      first.layout(_constraintsOf(index));
      _place(first, index);
      trailingWithLayout = first;
    }

    for (var index = indexOf(trailingWithLayout) + 1; index <= targetLastIndex; ++index) {
      var child = childAfter(trailingWithLayout!);
      if (child == null || indexOf(child) != index) {
        child = insertAndLayoutChild(_constraintsOf(index), after: trailingWithLayout);
        if (child == null) break;
      } else {
        child.layout(_constraintsOf(index));
      }
      _place(child, index);
      trailingWithLayout = child;
      trailing = math.max(trailing, layout.bottomOf(index));
    }

    leading = math.min(leading, layout.topOf(indexOf(firstChild!)));
    final paintExtent = calculatePaintOffset(constraints, from: math.min(constraints.scrollOffset, leading), to: trailing);
    final cacheExtent = calculateCacheOffset(constraints, from: leading, to: trailing);
    geometry = SliverGeometry(
      scrollExtent: total,
      paintExtent: paintExtent,
      maxPaintExtent: total,
      cacheExtent: cacheExtent,
      hasVisualOverflow: total > paintExtent || constraints.scrollOffset > 0.0 || constraints.overlap != 0.0,
    );
    if (indexOf(lastChild!) >= layout.childCount - 1) childManager.setDidUnderflow(true);
    childManager.didFinishLayout();
  }
}
