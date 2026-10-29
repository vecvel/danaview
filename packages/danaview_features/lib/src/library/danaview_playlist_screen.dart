import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'library_actions.dart';
import 'library_format.dart';
import 'library_providers.dart';
import 'library_widgets.dart';
import 'media_picker.dart';
import 'open_link_dialog.dart';

/// A playlist: play/shuffle, add videos or links, reorder by dragging, rename and delete.
class DanaviewPlaylistScreen extends ConsumerStatefulWidget {
  const DanaviewPlaylistScreen({
    super.key,
    required this.name,
    required this.onBack,
    required this.onOpenPlayer,
    required this.onRenamed,
  });

  final String name;
  final VoidCallback onBack;
  final VoidCallback onOpenPlayer;

  /// Called with the new name after a rename so the route can be updated.
  final ValueChanged<String> onRenamed;

  @override
  ConsumerState<DanaviewPlaylistScreen> createState() => _DanaviewPlaylistScreenState();
}

class _DanaviewPlaylistScreenState extends ConsumerState<DanaviewPlaylistScreen> {
  late String _name = widget.name;
  List<MediaRef>? _lastItems;
  List<MediaRef>? _optimisticOrder;
  int _pendingMoves = 0;
  bool _closing = false;
  bool _busy = false;

  @override
  void didUpdateWidget(DanaviewPlaylistScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name) _name = widget.name;
  }

  void _playFrom(List<MediaRef> items, int index, {bool shuffle = false}) {
    if (!LibraryRepository.mediaExists(items[index])) {
      DanaviewToast.show(
        context,
        "This file isn't available anymore. It may have been moved or deleted.",
        kind: DanaviewToastKind.error,
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    final playable = [
      for (var i = 0; i < items.length; i++)
        if (i == index || LibraryRepository.mediaExists(items[i])) items[i],
    ];
    danaviewPlayItems(ref, playable, startIndex: playable.indexOf(items[index]), shuffle: shuffle);
    widget.onOpenPlayer();
  }

  void _playAll(List<MediaRef> items, {bool shuffle = false}) {
    final playable = items.where(LibraryRepository.mediaExists).toList();
    if (playable.isEmpty) {
      DanaviewToast.show(
        context,
        "None of these videos are available. They may have been moved or deleted.",
        kind: DanaviewToastKind.error,
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    danaviewPlayItems(ref, playable, shuffle: shuffle);
    widget.onOpenPlayer();
  }

  Future<void> _addVideos() async {
    if (_busy) return;
    _busy = true;
    try {
      final refs = await pickVideoRefs();
      if (refs.isNotEmpty && mounted) await addToPlaylistWithFeedback(context, ref, _name, refs);
    } catch (e) {
      if (mounted) showDanaviewError(context, e);
    } finally {
      _busy = false;
    }
  }

  Future<void> _addLink() async {
    final media = await showDanaviewOpenLinkDialog(
      context,
      title: 'Add link',
      confirmLabel: 'Add',
      confirmIcon: Icons.add_rounded,
    );
    if (media != null && mounted) await addToPlaylistWithFeedback(context, ref, _name, [media]);
  }

  Future<void> _rename() async {
    final renamed = await promptRenamePlaylist(context, ref, _name);
    if (renamed == null || !mounted) return;
    setState(() => _name = renamed);
    widget.onRenamed(renamed);
  }

  Future<void> _delete() async {
    final name = _name;
    if (!await confirmDeletePlaylist(context, name) || !mounted) return;
    setState(() => _closing = true);
    await ref.read(libraryControllerProvider.notifier).deletePlaylist(name);
    if (!mounted) return;
    showDanaviewSuccess(context, 'Deleted "$name"');
    widget.onBack();
  }

  Future<void> _move(List<MediaRef> items, int from, int to) async {
    if (to == from) return;
    final reordered = List.of(items);
    reordered.insert(to, reordered.removeAt(from));
    setState(() {
      _optimisticOrder = reordered;
      _pendingMoves++;
    });
    try {
      await ref.read(libraryControllerProvider.notifier).movePlaylistItem(_name, from, to);
    } finally {
      if (mounted) {
        setState(() {
          if (--_pendingMoves == 0) _optimisticOrder = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final watched = ref.watch(playlistItemsProvider(_name));
    if (watched != null) _lastItems = watched;
    final items = _optimisticOrder ?? watched ?? (_closing ? _lastItems : null);

    return DanaviewRefreshOnReturn(
      onReturn: () => ref.read(libraryControllerProvider.notifier).refresh(),
      child: Scaffold(
        backgroundColor: DanaviewColors.background,
        body: DanaviewLibraryFrame(
          topBar: DanaviewLibraryTopBar(
            title: _name,
            subtitle: items == null ? null : 'Playlist · ${formatCount(items.length, 'video')}',
            onBack: widget.onBack,
            actions: [
              if (items != null)
                DanaviewMenuIconTrigger(
                  icon: Icons.more_horiz_rounded,
                  tooltip: 'Playlist options',
                  entries: [
                    DanaviewMenuItem(label: 'Rename', icon: Icons.edit_rounded, onTap: _rename),
                    DanaviewMenuItem(
                      label: 'Delete playlist',
                      icon: Icons.delete_outline_rounded,
                      destructive: true,
                      onTap: _delete,
                    ),
                  ],
                ),
            ],
          ),
          body: _body(context, items),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, List<MediaRef>? items) {
    if (items == null) {
      return DanaviewEmptyState(
        icon: Icons.playlist_remove_rounded,
        title: 'Playlist not found',
        message: 'It may have been renamed or deleted.',
        actions: [DanaviewButton.secondary(label: 'Go back', icon: Icons.arrow_back_rounded, onPressed: widget.onBack)],
      );
    }
    if (items.isEmpty) {
      return DanaviewEmptyState(
        icon: Icons.queue_music_rounded,
        title: 'This playlist is empty',
        message: 'Add videos from your device or paste a link to a stream.',
        actions: [
          DanaviewButton.primary(label: 'Add videos', icon: Icons.video_library_rounded, onPressed: _addVideos),
          DanaviewButton.secondary(label: 'Add link', icon: Icons.link_rounded, onPressed: _addLink),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = danaviewLibraryInsets(constraints.maxWidth);
        return ReorderableListView.builder(
          buildDefaultDragHandles: false,
          padding:
              insets.copyWith(top: DanaviewSpacing.lg, bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl),
          header: _PlaylistHeader(
            count: items.length,
            onPlay: () => _playAll(items),
            onShuffle: () => _playAll(items, shuffle: true),
            onAddVideos: _addVideos,
            onAddLink: _addLink,
          ),
          itemCount: items.length,
          onReorderItem: (from, to) => _move(items, from, to),
          proxyDecorator: (child, index, animation) => AnimatedBuilder(
            animation: animation,
            builder: (context, _) {
              final t = Curves.easeOutCubic.transform(animation.value);
              return Transform.scale(
                scale: 1 + 0.02 * t,
                child: Material(
                  type: MaterialType.transparency,
                  child: DanaviewSurface(
                    color: DanaviewColors.surfaceElevated,
                    borderRadius: DanaviewRadius.mdAll,
                    shadow: DanaviewShadow.soft,
                    child: _row(items, index, divider: false),
                  ),
                ),
              );
            },
          ),
          itemBuilder: (context, index) => KeyedSubtree(
            key: ValueKey(items[index].pathOrUri),
            child: _row(items, index, divider: index < items.length - 1),
          ),
        );
      },
    );
  }

  Widget _row(List<MediaRef> items, int index, {required bool divider}) {
    final media = items[index];
    final exists = LibraryRepository.mediaExists(media);
    final resume = ref.read(libraryControllerProvider.notifier).resumeInfoFor(media);
    final row = DanaviewLibraryRow(
      leading: DanaviewIconTile(mediaIcon(media)),
      title: media.title,
      titleMaxLines: 2,
      badge: episodeLabel(media),
      subtitle: mediaSubtitle(media, resume, exists: exists, fallback: parentFolderName(media.pathOrUri)),
      progress: exists ? resume?.progress : null,
      dimmed: !exists,
      onTap: () => _playFrom(items, index),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DanaviewMenuIconTrigger(
            icon: Icons.more_horiz_rounded,
            tooltip: 'More',
            entries: [
              DanaviewMenuItem(
                label: 'Play from here',
                icon: Icons.play_arrow_rounded,
                enabled: exists,
                onTap: () => _playFrom(items, index),
              ),
              const DanaviewMenuDivider(),
              DanaviewMenuItem(
                label: 'Remove from playlist',
                icon: Icons.remove_circle_outline_rounded,
                destructive: true,
                onTap: () => ref.read(libraryControllerProvider.notifier).removeFromPlaylist(_name, index),
              ),
            ],
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Tooltip(
              message: 'Drag to reorder',
              child: SizedBox(
                width: 36,
                height: 44,
                child: Icon(Icons.drag_indicator_rounded, size: 20, color: DanaviewColors.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
    if (!divider) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [row, const DanaviewRowDivider()],
    );
  }
}

class _PlaylistHeader extends StatelessWidget {
  const _PlaylistHeader({
    required this.count,
    required this.onPlay,
    required this.onShuffle,
    required this.onAddVideos,
    required this.onAddLink,
  });

  final int count;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final VoidCallback onAddVideos;
  final VoidCallback onAddLink;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: DanaviewSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const DanaviewIconTile(Icons.queue_music_rounded, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatCount(count, 'video'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DanaviewTextStyles.title,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      count > 1 ? 'Drag the handle to change the order' : 'Add more videos or links anytime',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: DanaviewTextStyles.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: DanaviewSpacing.lg),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DanaviewButtonBar(
                    children: [
                      DanaviewButton.primary(label: 'Play', icon: Icons.play_arrow_rounded, onPressed: onPlay),
                      DanaviewButton.secondary(
                        label: 'Shuffle',
                        icon: Icons.shuffle_rounded,
                        onPressed: count > 1 ? onShuffle : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: DanaviewSpacing.sm),
                  DanaviewButtonBar(
                    reverseWhenStacked: false,
                    children: [
                      DanaviewButton.ghost(
                        label: 'Add videos',
                        icon: Icons.video_library_rounded,
                        size: DanaviewButtonSize.sm,
                        onPressed: onAddVideos,
                      ),
                      DanaviewButton.ghost(
                        label: 'Add link',
                        icon: Icons.add_link_rounded,
                        size: DanaviewButtonSize.sm,
                        onPressed: onAddLink,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
