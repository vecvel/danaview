// The card grids of the Home and its tabs (DESIGN_SYSTEM §5, §10.4): the adaptive 2 / 4 / 6
// column count, an eager grid for short Overview sections and a lazy sliver grid for whole tabs.
// Every card of a grid gets the same height (computed from the card width and the text scale), so
// the cards of a row are always equal and nothing needs intrinsic layout. Grids never clip their
// cells, so a keyboard focus ring is never cut.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'home_media_card.dart' show homeMediaCardExtent;

/// The gap between cards of a grid, both ways (§5: 10 between cards).
const double homeCardGridGap = 10;

/// The All tab's mixed grid columns for a content [width] (§10.4): 2 on phones, 4 on tablets,
/// 6 on wide windows.
int homeAdaptiveColumns(double width) {
  if (width < 560) return 2;
  if (width < 960) return 4;
  return 6;
}

/// The width of one cell of [columns] columns across [width].
double homeCardCellWidth(double width, int columns) =>
    math.max(0.0, (width - homeCardGridGap * (columns - 1)) / columns);

/// The height of a card [cellWidth] wide in [context].
typedef HomeCardExtent = double Function(double cellWidth, BuildContext context);

/// An eager grid of [children] (a handful of cards on the Overview): [columnsFor] picks the
/// columns for the available width, [extent] the cards' common height.
class HomeCardGrid extends StatelessWidget {
  /// A grid of [children].
  const HomeCardGrid({super.key, required this.children, this.columnsFor = homeAdaptiveColumns, this.extent});

  /// The cards.
  final List<Widget> children;

  /// Columns for a width.
  final int Function(double width) columnsFor;

  /// The cards' height; null uses the media card's.
  final HomeCardExtent? extent;

  @override
  Widget build(BuildContext context) {
    // Its own layer, like the grouped lists' card grid: the cards rasterize the same wherever the
    // grid sits, and a scroll repaints none of them.
    return RepaintBoundary(child: _grid());
  }

  Widget _grid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = math.max(1, columnsFor(constraints.maxWidth));
        final cell = homeCardCellWidth(constraints.maxWidth, columns);
        final height = (extent ?? homeMediaCardExtent)(cell, context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var start = 0; start < children.length; start += columns) ...[
              if (start > 0) const SizedBox(height: homeCardGridGap),
              SizedBox(
                height: height,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < columns; i++) ...[
                      if (i > 0) const SizedBox(width: homeCardGridGap),
                      Expanded(child: start + i < children.length ? children[start + i] : const SizedBox.shrink()),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// A lazy grid of [itemCount] cards in [columns] columns across [width], each [extent] high.
Widget homeSliverCardGrid({
  Key? key,
  required int columns,
  required double width,
  required HomeCardExtent extent,
  required int itemCount,
  required IndexedWidgetBuilder itemBuilder,
}) {
  return _HomeSliverCardGrid(
    key: key,
    columns: math.max(1, columns),
    width: width,
    extent: extent,
    itemCount: itemCount,
    itemBuilder: itemBuilder,
  );
}

class _HomeSliverCardGrid extends StatelessWidget {
  const _HomeSliverCardGrid({
    super.key,
    required this.columns,
    required this.width,
    required this.extent,
    required this.itemCount,
    required this.itemBuilder,
  });

  final int columns;
  final double width;
  final HomeCardExtent extent;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    final cell = homeCardCellWidth(width, columns);
    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: homeCardGridGap,
        crossAxisSpacing: homeCardGridGap,
        mainAxisExtent: extent(cell, context),
      ),
      itemCount: itemCount,
      itemBuilder: itemBuilder,
    );
  }
}
