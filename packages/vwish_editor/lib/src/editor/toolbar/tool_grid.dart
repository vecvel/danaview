// OWNER: UX-16
//
// ToolGrid: the tools of a side pane (compactLandscape and medium while the inspector is closed;
// the expanded pane when something is selected or a tool tab is open). A header with the leading
// chip (or "Tools"), then the tiles in a grid; everything scrolls together so the pane never
// overflows, however short it is.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import 'tool_tile.dart';
import 'toolbar_chip.dart';
import 'toolbar_model.dart';
import 'toolbar_strings.dart';

/// The tools of a side pane.
class ToolGrid extends StatelessWidget {
  /// Creates the grid for [contents]; tiles are [tileHeight] tall (icon-only when [iconOnly]).
  const ToolGrid({super.key, required this.contents, required this.tileHeight, this.iconOnly = false});

  /// What to show.
  final ToolbarContents contents;

  /// Tile height.
  final double tileHeight;

  /// Icon-only tiles (ladder step 3).
  final bool iconOnly;

  /// Largest cell width.
  static const double maxCellWidth = 96;

  @override
  Widget build(BuildContext context) {
    final chip = contents.chip;
    final cell = iconOnly ? ToolTile.iconOnlyWidth : maxCellWidth;
    return ColoredBox(
      color: VwishColors.surface,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: ToolbarStrings.toolsRegion,
        child: CustomScrollView(
          key: ValueKey<String>(contents.set?.kind.name ?? contents.tab?.name ?? 'top'),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(VwishSpacing.md, VwishSpacing.sm, VwishSpacing.md, VwishSpacing.xs),
              sliver: SliverToBoxAdapter(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: chip != null
                      ? ToolbarChipView(chip: chip)
                      : Semantics(
                          header: true,
                          child: Text(
                            ToolbarStrings.toolsTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: VwishTextStyles.label.copyWith(fontFamily: VwishFonts.family, color: VwishColors.textSecondary),
                          ),
                        ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(VwishSpacing.sm, 0, VwishSpacing.sm, VwishSpacing.sm),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: cell,
                  mainAxisExtent: math.max(1, tileHeight),
                  crossAxisSpacing: 2,
                  mainAxisSpacing: 2,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final tile = contents.tiles[i];
                    return ToolTile(
                      key: ValueKey<String>('tile.${tile.key}'),
                      data: tile,
                      height: tileHeight,
                      width: double.infinity,
                      iconOnly: iconOnly,
                    );
                  },
                  childCount: contents.tiles.length,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
