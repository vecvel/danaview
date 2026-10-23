// OWNER: HOM-22
//
// The file group of the multi-select bar (ARCH v1.2 V2-107, V2-118; HOM plan §8.3, D-98e;
// BUILD_PLAN HOM-22): Share, Move, Copy, Favourite, Save out (Save to Files / Save to Downloads /
// Save…), Save to Photos (photos and videos only) and Delete for Danaview files; only the
// out actions when the selection holds read-only files (linked folders, 1.1 videos); "Merge into
// PDF" for two or more PDFs and photos when HOM-28's handler is wired. It sits after HOM-12's
// media group, so "Make video montage" and "Play all" stay first for media selections.
//
// The app root registers it next to the media group (INT-103):
// `selectionActionGroupsProvider.overrideWithValue([mediaSelectionGroup, fileSelectionGroup])`
// (or `fileSelectionGroupWith(canMerge: true)` once Merge into PDF is wired), or a screen passes
// it to `HomeSelectionBar.extraGroups`. Every action receives the items in selection order.

import 'package:danaview_library/danaview_library.dart';

import '../file_actions/file_action_providers.dart';
import '../file_actions/file_action_runner.dart';
import 'selection_actions.dart';

/// The id of the file group.
const String fileSelectionGroupId = 'files';

/// The file group without Merge into PDF.
SelectionActionGroup? fileSelectionGroup(SelectionActionContext context) => _group(context, canMerge: false);

/// The file group; [canMerge] shows Merge into PDF (set it when [mergeIntoPdfHandlerProvider] is
/// overridden).
SelectionGroupBuilder fileSelectionGroupWith({bool canMerge = false}) => (context) => _group(context, canMerge: canMerge);

SelectionActionGroup? _group(SelectionActionContext context, {required bool canMerge}) {
  final items = context.selection.items;
  if (items.isEmpty) return null;
  final caps = FileOutCapabilities.of(fileOutPlatformOf(context.platform));
  final actions = selectionFileActionsFor(
    [for (final i in items) FileActionTarget.of(i)],
    canShare: caps.canShare,
    canSaveOut: caps.primarySaveTarget != null,
    canSaveToPhotos: caps.canSaveToPhotos,
    canMerge: canMerge,
  );
  if (actions.isEmpty) return null;
  return SelectionActionGroup(
    id: fileSelectionGroupId,
    title: 'File actions',
    order: 10,
    actions: [
      for (final action in actions)
        SelectionAction(
          id: fileActionId(action),
          label: fileActionLabel(action, capabilities: caps, group: true),
          icon: fileActionIcon(action),
          onInvoke: (inv) => _invoke(inv, action),
        ),
    ],
  );
}

Future<void> _invoke(SelectionInvocation inv, FileAction action) async {
  final items = inv.selection.items;
  final done = await runFileAction(inv.context, inv.ref, action, items, anchor: anchorOf(inv.context));
  if (done && inv.context.mounted && action != FileAction.favourite) inv.clearSelection();
}
