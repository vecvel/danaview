// OWNER: HOM-18
//
// The `Videos` filter tab (ARCH v1.2 V2-114; HOM plan §5.2): pure video focus. From the top: the
// Now Playing strip (opens the player), Continue watching (the 1.1 history; plays through
// `danaviewPlayItems`, so the player still receives `MediaRef`, ARCH §1.5), the playlists, the
// video folders (linked folders; they open the 1.1 browser), then a grid of the Danaview library's
// videos with HOM-13's badge overlay (duration pill, resolution, frame rate >= 50, HDR; V2-110). The 1.1 sections themselves stay on the Overview tab
// unchanged; this tab only reads the same providers.

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/providers.dart';
import '../filters/entry_widgets.dart';
import '../filters/filter_providers.dart';
import '../filters/library_filters.dart';
import '../library_actions.dart';
import '../library_controller.dart';
import '../library_format.dart';
import '../library_providers.dart';
import '../library_widgets.dart';
import 'all_tab.dart' show LibraryFilterEmpty;

/// Continue watching rows shown before "Show all".
const int videosTabRecentPreview = 3;

/// The `Videos` tab.
class VideosTab extends ConsumerStatefulWidget {
  /// The tab. [onOpenPlayer] shows the player; [onOpenPlaylist] and [onOpenFolder] open the 1.1
  /// playlist and folder screens; [onOpenEntry] plays a Danaview video.
  const VideosTab({super.key, required this.onOpenPlayer, this.onOpenPlaylist, this.onOpenFolder, this.onOpenEntry});

  /// Shows the player.
  final VoidCallback onOpenPlayer;

  /// Opens a playlist by name.
  final ValueChanged<String>? onOpenPlaylist;

  /// Opens a linked folder's path in the 1.1 browser.
  final ValueChanged<String>? onOpenFolder;

  /// Plays a Danaview video.
  final LibraryEntryOpen? onOpenEntry;

  @override
  ConsumerState<VideosTab> createState() => _VideosTabState();
}

class _VideosTabState extends ConsumerState<VideosTab> {
  bool _showAllRecent = false;

  void _play(List<MediaRef> items) {
    if (items.isEmpty) return;
    danaviewPlayItems(ref, items);
    widget.onOpenPlayer();
  }

  void _playRecent(LibraryRecentItem item) {
    if (!item.exists) {
      DanaviewToast.show(
        context,
        "This file isn't available anymore. It may have been moved or deleted.",
        kind: DanaviewToastKind.error,
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    _play([item.media]);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryControllerProvider);
    final videos = ref.watch(libraryFilterEntriesProvider((filter: LibraryFilter.videos, subFilter: null)));
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = danaviewLibraryInsets(constraints.maxWidth);
        final padding = insets.copyWith(top: DanaviewSpacing.lg, bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl);
        final side = padding.copyWith(top: 0, bottom: 0);
        final gridWidth = constraints.maxWidth - side.horizontal;
        final columns = (gridWidth / 180).floor().clamp(2, 6);
        final recent = state.recent;
        final shownRecent = _showAllRecent ? recent : recent.take(videosTabRecentPreview).toList();
        final folders = state.roots;
        final header = <Widget>[
          _NowPlayingStrip(onOpen: widget.onOpenPlayer),
          if (recent.isNotEmpty) ...[
            const DanaviewLibrarySectionHeader('Continue watching', topSpacing: 0),
            DanaviewLibraryGroup(
              children: [
                for (final item in shownRecent)
                  DanaviewLibraryRow(
                    leading: DanaviewTileIcon(mediaIcon(item.media), color: mediaIconColor(item.media), size: 40),
                    title: item.media.title,
                    badge: episodeLabel(item.media),
                    subtitle: mediaSubtitle(item.media, item.resume, exists: item.exists, fallback: parentFolderName(item.media.pathOrUri)),
                    progress: item.exists ? item.progress : null,
                    dimmed: !item.exists,
                    onTap: () => _playRecent(item),
                  ),
              ],
            ),
            if (recent.length > videosTabRecentPreview)
              Center(
                child: DanaviewButton.ghost(
                  label: _showAllRecent ? 'Show less' : 'Show all ${recent.length}',
                  trailingIcon: _showAllRecent ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: DanaviewButtonSize.sm,
                  onPressed: () => setState(() => _showAllRecent = !_showAllRecent),
                ),
              ),
          ],
          if (state.playlists.isNotEmpty) ...[
            const DanaviewLibrarySectionHeader('Playlists'),
            DanaviewLibraryGroup(
              children: [
                for (final p in state.playlists)
                  DanaviewLibraryRow(
                    leading: const DanaviewTileIcon(Icons.queue_music_rounded, color: DanaviewColors.purple, size: 40),
                    title: p.name,
                    subtitle: p.itemCount == 0 ? 'No videos yet' : formatCount(p.itemCount, 'video'),
                    onTap: widget.onOpenPlaylist == null ? null : () => widget.onOpenPlaylist!(p.name),
                  ),
              ],
            ),
          ],
          if (folders.isNotEmpty && widget.onOpenFolder != null) ...[
            const DanaviewLibrarySectionHeader('Video folders'),
            DanaviewLibraryGroup(
              children: [
                for (final f in folders)
                  DanaviewLibraryRow(
                    leading: DanaviewTileIcon.glyph(
                      f.isDevice ? DanaviewGlyphKind.device : DanaviewGlyphKind.folderVideo,
                      color: f.isDevice ? DanaviewColors.cyan : DanaviewColors.primaryLight,
                      size: 40,
                    ),
                    title: f.label,
                    subtitle: f.isDevice ? 'Device storage' : f.path,
                    onTap: () => widget.onOpenFolder!(f.path),
                  ),
              ],
            ),
          ],
          const DanaviewLibrarySectionHeader('Danaview videos'),
          if (videos.isEmpty) const LibraryFilterEmpty(filter: LibraryFilter.videos),
        ];
        return CustomScrollView(
          key: const PageStorageKey('library-videos-tab'),
          slivers: [
            SliverPadding(padding: padding.copyWith(bottom: 0), sliver: SliverList.list(children: header)),
            if (videos.length > 0)
              SliverPadding(
                padding: side.copyWith(top: DanaviewSpacing.xs),
                sliver: SliverGrid.builder(
                  key: const ValueKey('videos-grid'),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: DanaviewSpacing.md,
                    crossAxisSpacing: DanaviewSpacing.sm,
                    // 16:9 frame plus the name line, which grows with the text scale.
                    mainAxisExtent: (gridWidth - (columns - 1) * DanaviewSpacing.sm) / columns * 9 / 16 +
                        DanaviewSpacing.xs +
                        MediaQuery.textScalerOf(context).scale(DanaviewTextStyles.caption.fontSize ?? 12) * 1.6,
                  ),
                  itemCount: videos.length,
                  itemBuilder: (context, i) {
                    final entry = videos.at(i);
                    if (entry == null) return const SizedBox.shrink();
                    return LibraryVideoTile(entry: entry, onOpen: widget.onOpenEntry);
                  },
                ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: padding.bottom)),
          ],
        );
      },
    );
  }
}

/// The compact Now Playing strip: title and position, tap opens the player.
class _NowPlayingStrip extends ConsumerWidget {
  const _NowPlayingStrip({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = ref.watch(queueControllerProvider.select((q) => q.currentItem));
    if (media == null) return const SizedBox.shrink();
    final (position, duration) = ref.watch(playerControllerProvider.select((s) => (s.position.inSeconds, s.duration.inSeconds)));
    final subtitle = duration > 0
        ? '${formatClock(Duration(seconds: position))} / ${formatClock(Duration(seconds: duration))}'
        : mediaHost(media) ?? 'Ready to play';
    return Padding(
      padding: const EdgeInsets.only(bottom: DanaviewSpacing.md),
      child: DanaviewLibraryGroup(
        children: [
          DanaviewLibraryRow(
            key: const ValueKey('videos-now-playing'),
            leading: const DanaviewTileIcon(Icons.graphic_eq_rounded, color: DanaviewColors.primaryLight, size: 40),
            title: media.title,
            badge: 'Now playing',
            subtitle: subtitle,
            progress: duration > 0 ? position / duration : null,
            semanticLabel: 'Now playing: ${media.title}. Open player',
            onTap: onOpen,
          ),
        ],
      ),
    );
  }
}
