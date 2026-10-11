// OWNER: UX-16
//
// ToolStrip (ux.md §9, §6.3): the bottom tool strip of compactPortrait. One horizontally scrolling
// row (never wraps, ux.md §6.7 rule 3): the top-level tools when nothing is selected, else the
// leading `[✕ Video clip]` chip and the context tools of ToolSets.forSelection (or the open tool
// tab's sub-tools). Tiles are `EditorLayoutScope.toolTileHeight` tall and become icon-only at
// ladder step 3 (`iconOnlyTools`). See toolbar_model.dart for what each tile does.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../../debug/rebuild_counters.dart';
import '../editor_scope.dart';
import '../layout/editor_layout_scope.dart';
import 'tool_tile.dart';
import 'toolbar_chip.dart';
import 'toolbar_model.dart';
import 'toolbar_strings.dart';

/// Bottom tool strip in compact layouts (ux.md §9).
class ToolStrip extends ConsumerWidget {
  /// Creates the strip for the editor of the nearest `EditorScope`.
  const ToolStrip({super.key});

  /// Gap between tiles.
  static const double gap = 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    EditorRebuildCounters.count('ToolStrip');
    final id = EditorScope.idOf(context);
    final spec = EditorLayoutScope.maybeOf(context);
    final contents = ToolbarModel.watch(context, ref, id);
    final iconOnly = spec?.iconOnlyTools ?? false;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: VwishColors.surface,
        border: Border(top: VwishBorders.hairline),
      ),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: ToolbarStrings.toolsRegion,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final available = constraints.maxHeight.isFinite ? constraints.maxHeight : (spec?.toolStripHeight ?? 64);
            final height = math.max(0.0, math.min(spec?.toolTileHeight ?? available, available));
            final chip = contents.chip;
            return ListView(
              key: ValueKey<String>(_modeKey(contents)),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: VwishSpacing.sm),
              children: [
                if (chip != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: VwishSpacing.xs),
                    child: Center(child: ToolbarChipView(chip: chip, maxWidth: math.max(96, constraints.maxWidth * 0.4))),
                  ),
                for (final tile in contents.tiles)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: gap / 2),
                    child: Center(
                      child: ToolTile(key: ValueKey<String>('tile.${tile.key}'), data: tile, height: height, iconOnly: iconOnly),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _modeKey(ToolbarContents c) => c.set != null
      ? 'set.${c.set!.kind.name}.${c.set!.item}'
      : c.tab != null
          ? 'tab.${c.tab!.name}'
          : 'top';
}
