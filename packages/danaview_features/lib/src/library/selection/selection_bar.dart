// OWNER: HOM-12
//
// The multi-select bar of the Files & Media Home (ARCH v1.2 V2-107, D-92, Q-H2; BUILD_PLAN HOM-12).
// The Home shell (HOM-05) draws it over the bottom of every tab through `HomeTabSlots.selectionBar`;
// the app root (INT-103) fills that slot with `(context) => HomeSelectionBar(onOpenPlayer: …)`.
// It shows nothing until something is selected; then a count, a clear button and one horizontally
// scrolling row of the action groups the registered builders give for the selection
// (selection_actions.dart). Back (Android, the iOS edge swipe is not captured) and Escape leave
// selection mode before they leave the Home.

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_callbacks.dart';
import 'selection_actions.dart';
import 'selection_model.dart';

export 'selection_actions.dart';
export 'selection_gestures.dart';
export 'selection_model.dart';
export 'media_actions.dart' show mediaSelectionGroup, mediaSelectionGroupId, playQueueFor, playerDecodesPhoto, skippedPhotosNotice;

/// The text of the bar's count.
String selectionCountLabel(int count) => count == 1 ? '1 selected' : '$count selected';

/// The multi-select bar.
class HomeSelectionBar extends ConsumerWidget {
  /// The bar; [onOpenPlayer] shows the player after "Play all"; [extraGroups] adds groups to the
  /// registered ones (see [selectionActionGroupsProvider]).
  const HomeSelectionBar({super.key, this.onOpenPlayer, this.extraGroups = const []});

  /// Shows the player screen.
  final VoidCallback? onOpenPlayer;

  /// Group builders added after the registered ones.
  final List<SelectionGroupBuilder> extraGroups;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(homeSelectionProvider);
    if (selection.isEmpty) return const SizedBox.shrink();
    final actionContext = SelectionActionContext(
      selection: selection,
      callbacks: HomeCallbacksScope.of(context),
      platform: Theme.of(context).platform,
      playerShowsPhotos: ref.watch(playerShowsPhotosProvider),
      onOpenPlayer: onOpenPlayer,
    );
    final groups = selectionGroupsFor(actionContext, [...ref.watch(selectionActionGroupsProvider), ...extraGroups]);
    void clear() => ref.read(homeSelectionProvider.notifier).clear();
    void invoke(SelectionAction action) => action.onInvoke(
          SelectionInvocation(context: context, ref: ref, action: actionContext, clearSelection: clear),
        );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) clear();
      },
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): clear},
        child: Focus(
          autofocus: true,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: DanaviewSpacing.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.sm),
              child: Semantics(
                container: true,
                explicitChildNodes: true,
                label: 'Selection',
                child: DanaviewSurface(
                  key: const ValueKey('home-selection-bar'),
                  color: DanaviewColors.surfaceElevated,
                  borderRadius: DanaviewRadius.lgAll,
                  shadow: DanaviewShadow.soft,
                  padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs, vertical: DanaviewSpacing.xs),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        DanaviewIconButton(
                          key: const ValueKey('selection-clear'),
                          icon: Icons.close_rounded,
                          semanticLabel: 'Clear selection',
                          tooltip: 'Clear selection',
                          onPressed: clear,
                        ),
                        const SizedBox(width: DanaviewSpacing.xs),
                        Expanded(
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              selectionCountLabel(selection.length),
                              key: const ValueKey('selection-count'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DanaviewTextStyles.label.copyWith(
                                color: DanaviewColors.foregroundOn(DanaviewColors.surfaceElevated),
                              ),
                            ),
                          ),
                        ),
                      ]),
                      if (groups.isNotEmpty)
                        SingleChildScrollView(
                          key: const ValueKey('selection-actions'),
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            for (final (i, group) in groups.indexed) ...[
                              if (i > 0)
                                Container(
                                  width: 1,
                                  height: 24,
                                  margin: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs),
                                  color: DanaviewColors.border,
                                ),
                              Semantics(
                                key: ValueKey('selection-group-${group.id}'),
                                container: true,
                                explicitChildNodes: true,
                                label: group.title,
                                child: Row(children: [
                                  for (final action in group.actions)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xxs),
                                      child: DanaviewButton.tonal(
                                        key: ValueKey('selection-action-${action.id}'),
                                        label: action.label,
                                        icon: action.icon,
                                        semanticLabel: action.semanticLabel,
                                        onPressed: () => invoke(action),
                                      ),
                                    ),
                                ]),
                              ),
                            ],
                          ]),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
