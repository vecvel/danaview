import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import '../controllers/providers.dart';
import '../player/danaview_player_actions.dart';

/// Queue panel; fills the size its parent allows (the player positions and bounds it).
class DanaviewQueueSheet extends ConsumerWidget {
  final VoidCallback onClose;

  const DanaviewQueueSheet({super.key, required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueControllerProvider);
    final queueCtrl = ref.read(queueControllerProvider.notifier);
    final count = queue.items.length;

    return DanaviewSurface(
      shadow: DanaviewShadow.subtle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Queue', maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.headline),
                      Text(
                        count == 1 ? '1 video' : '$count videos',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DanaviewTextStyles.caption,
                      ),
                    ],
                  ),
                ),
                DanaviewIconButton(
                  icon: Icons.shuffle_rounded,
                  size: 36,
                  iconSize: 18,
                  selected: queue.isShuffled,
                  tooltip: queue.isShuffled ? 'Shuffle on' : 'Shuffle off',
                  onPressed: () => queueCtrl.setShuffle(!queue.isShuffled),
                ),
                DanaviewIconButton(
                  icon: queue.repeatMode == RepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                  size: 36,
                  iconSize: 18,
                  selected: queue.repeatMode != RepeatMode.off,
                  tooltip: switch (queue.repeatMode) {
                    RepeatMode.off => 'Repeat off',
                    RepeatMode.all => 'Repeat all',
                    RepeatMode.one => 'Repeat one',
                  },
                  onPressed: queueCtrl.cycleRepeatMode,
                ),
                DanaviewIconButton(
                  icon: Icons.close_rounded,
                  size: 36,
                  iconSize: 18,
                  tooltip: 'Close',
                  semanticLabel: 'Close queue',
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Container(height: DanaviewBorders.width, color: DanaviewColors.hairline),
          Expanded(
            child: queue.items.isEmpty
                ? DanaviewEmptyState(
                    icon: Icons.queue_music_rounded,
                    title: 'Queue is empty',
                    message: 'Add videos to watch them one after another.',
                    actions: [
                      DanaviewButton.primary(
                        label: 'Add videos',
                        icon: Icons.add_rounded,
                        onPressed: () => openVideoFiles(context, ref, append: true),
                      ),
                    ],
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.all(6),
                    buildDefaultDragHandles: false,
                    itemCount: count,
                    proxyDecorator: (child, index, animation) => Material(
                      type: MaterialType.transparency,
                      child: DanaviewSurface(
                        color: DanaviewColors.surfaceElevatedHigher,
                        borderRadius: DanaviewRadius.controlAll,
                        shadow: DanaviewShadow.soft,
                        child: child,
                      ),
                    ),
                    onReorderItem: queueCtrl.move,
                    itemBuilder: (context, index) {
                      final item = queue.items[index];
                      final isCurrent = index == queue.currentIndex;
                      return _QueueRow(
                        key: ValueKey('${item.id}#$index'),
                        index: index,
                        item: item,
                        isCurrent: isCurrent,
                        onTap: () => queueCtrl.jumpTo(index),
                        onRemove: () => queueCtrl.remove(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.index,
    required this.item,
    required this.isCurrent,
    required this.onTap,
    required this.onRemove,
  });

  final int index;
  final MediaRef item;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final duration = item.duration > Duration.zero ? formatPlaybackDuration(item.duration) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: DanaviewListTile(
        dense: true,
        selected: isCurrent,
        title: item.title,
        titleMaxLines: 2,
        subtitle: isCurrent ? (duration == null ? 'Now playing' : 'Now playing · $duration') : duration,
        padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
        leading: isCurrent
            ? const DanaviewIconTile(Icons.play_arrow_rounded, size: 28)
            : SizedBox(
                width: 28,
                child: Text(
                  '${index + 1}',
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: DanaviewColors.textMuted,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DanaviewIconButton(
              icon: Icons.close_rounded,
              size: 32,
              iconSize: 16,
              color: DanaviewColors.textMuted,
              tooltip: 'Remove',
              semanticLabel: 'Remove ${item.title} from queue',
              onPressed: onRemove,
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Icon(Icons.drag_indicator_rounded, size: 20, color: DanaviewColors.textMuted),
              ),
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
