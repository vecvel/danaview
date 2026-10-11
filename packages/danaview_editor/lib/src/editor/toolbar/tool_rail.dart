// OWNER: UX-16
//
// ToolRail (ux.md §9, §6.3). The scaffold places it in two regions:
// * expanded: the 76 px rail at the leading edge, a vertical column of the nine top-level tool
//   tabs (the pane beside it shows the context tools, a tool tab or the inspector: InspectorHost);
// * compactLandscape and medium: the side pane while the inspector is closed, where it shows the
//   current tools as a ToolGrid (top-level tools, or the leading chip and the context tools).
// Which one it is follows from `EditorLayoutScope.kind`.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../debug/rebuild_counters.dart';
import '../editor_scope.dart';
import '../layout/editor_layout.dart';
import '../layout/editor_layout_scope.dart';
import 'tool_grid.dart';
import 'tool_tile.dart';
import 'toolbar_model.dart';
import 'toolbar_strings.dart';

/// Side tool rail in expanded layouts and the tool pane in compactLandscape and medium (ux.md §9).
class ToolRail extends ConsumerWidget {
  /// Creates the rail for the editor of the nearest `EditorScope`.
  const ToolRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    EditorRebuildCounters.count('ToolRail');
    final id = EditorScope.idOf(context);
    final spec = EditorLayoutScope.maybeOf(context);
    final iconOnly = spec?.iconOnlyTools ?? false;
    final tileHeight = spec?.toolTileHeight ?? 64;
    if (spec != null && spec.kind != EditorLayoutKind.expanded) {
      return ToolGrid(contents: ToolbarModel.watch(context, ref, id), tileHeight: tileHeight, iconOnly: iconOnly);
    }
    final contents = ToolbarModel.watch(context, ref, id, topLevelOnly: true);
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: DanaviewColors.surface,
        border: BorderDirectional(end: DanaviewBorders.hairline),
      ),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: ToolbarStrings.toolsRegion,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = math.max(0.0, (constraints.maxWidth.isFinite ? constraints.maxWidth : 76) - 2 * DanaviewSpacing.xs);
            return ListView(
              padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.sm, horizontal: DanaviewSpacing.xs),
              children: [
                for (final tile in contents.tiles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: ToolTile(
                      key: ValueKey<String>('tile.${tile.key}'),
                      data: tile,
                      height: tileHeight,
                      width: width,
                      iconOnly: iconOnly,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
