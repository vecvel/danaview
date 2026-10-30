// OWNER: HOM-18
// EXTENDED: Home four tabs (DESIGN_SYSTEM §10.4 `Videos`: Continue watching, Projects, Playlists,
// All videos)
//
// The `Videos` tab (ARCH v1.2 V2-114; HOM plan §5.2; DESIGN_SYSTEM §10.4), from the top:
//
// 1. **Continue watching**: a row of 16:9 media cards with progress (the 1.1 history; plays
//    through `danaviewPlayItems`, so the player still receives `MediaRef`, ARCH §1.5), "Clear" in
//    the header (asks first, as 1.1 does) and Show all / Show less wrapping it into a grid.
// 2. **Projects** (editor only, [HomeProjectsRow]): a "New project" card, then the project cards;
//    "See all" opens the Projects screen.
// 3. **Playlists** ([HomePlaylistsRow]): playlist cards (2×2 mosaic, name, count, the More menu);
//    "See all" opens the Playlists screen (New, Play, Shuffle, Rename, Delete).
// 4. **All videos**: the Danaview library's videos as a grid of 16:9 media cards (2 / 4 / 6
//    columns) with HOM-13's badge overlay (duration pill, resolution, frame rate >= 50, HDR;
//    V2-110), and "Sort" (Newest, Oldest, Name) in the header.
//
// Empty sections are hidden (All videos keeps its empty state). The 1.1 sections themselves stay
// on the Home tab unchanged; this tab only reads the same providers.

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../filters/entry_widgets.dart';
import '../filters/filter_providers.dart';
import '../filters/library_filters.dart';
import '../home/home_callbacks.dart';
import '../home/home_grid.dart';
import '../home/home_media_card.dart';
import '../home/home_playlists.dart';
import '../home/home_projects.dart';
import '../library_actions.dart';
import '../library_controller.dart';
import '../library_format.dart';
import '../library_providers.dart';
import '../library_widgets.dart';
import 'all_tab.dart' show LibraryAllSort, LibraryAllType, LibraryFilterEmpty, libraryAllEntriesProvider;

/// Continue watching cards shown in the row before "Show all".
const int videosTabRecentPreview = 6;

/// The `Videos` tab.
class VideosTab extends ConsumerStatefulWidget {
  /// The tab. [onOpenPlayer] shows the player; [onOpenPlaylist] opens the 1.1 playlist screen
  /// (null hides the Playlists row); [onOpenEntry] plays a Danaview video. [onOpenFolder] is kept
  /// for callers of the earlier tab (folders now live on the Home tab and the Folders screen).
  const VideosTab({super.key, required this.onOpenPlayer, this.onOpenPlaylist, this.onOpenFolder, this.onOpenEntry});

  /// Shows the player.
  final VoidCallback onOpenPlayer;

  /// Opens a playlist by name.
  final ValueChanged<String>? onOpenPlaylist;

  /// Opens a linked folder's path in the 1.1 browser (unused by this tab).
  final ValueChanged<String>? onOpenFolder;

  /// Plays a Danaview video.
  final LibraryEntryOpen? onOpenEntry;

  @override
  ConsumerState<VideosTab> createState() => _VideosTabState();
}

class _VideosTabState extends ConsumerState<VideosTab> {
  bool _showAllRecent = false;
  LibraryAllSort _sort = LibraryAllSort.newest;

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

  /// Clear, as on the 1.1 Home: asks first, then empties the watch history and resume points.
  Future<void> _clearHistory() async {
    final confirmed = await showDanaviewConfirm(
      context,
      title: 'Clear Continue watching',
      message: 'Your watch history and resume points will be cleared. Your files stay on disk.',
      confirmLabel: 'Clear',
      destructive: true,
      icon: Icons.history_rounded,
    );
    if (!confirmed) return;
    await ref.read(libraryControllerProvider.notifier).clearHistory();
    if (mounted) setState(() => _showAllRecent = false);
  }

  /// The videos in the current sort: the `Videos` filter list for Newest, else the All tab's
  /// paged query of videos.
  LibraryEntryPages _videos() => _sort == LibraryAllSort.newest
      ? ref.watch(libraryFilterEntriesProvider((filter: LibraryFilter.videos, subFilter: null)))
      : ref.watch(libraryAllEntriesProvider((sort: _sort, type: LibraryAllType.videos)));

  /// "Sort" in the All videos header: Newest, Oldest or Name, the current one checked.
  Widget _sortButton() => DanaviewMenuAnchor(
        alignment: DanaviewMenuAlignment.end,
        width: 200,
        entries: [
          const DanaviewMenuHeader('Sort by'),
          for (final sort in LibraryAllSort.values)
            DanaviewMenuItem(
              label: sort.label,
              selected: sort == _sort,
              onTap: () => setState(() => _sort = sort),
            ),
        ],
        builder: (context, open, isOpen) => DanaviewButton.text(
          key: const ValueKey('videos-sort'),
          label: 'Sort',
          icon: Icons.swap_vert_rounded,
          size: DanaviewButtonSize.sm,
          semanticLabel: 'Sort videos: ${_sort.label}',
          onPressed: open,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryControllerProvider);
    final videos = _videos();
    final callbacks = HomeCallbacksScope.of(context);
    final projectsShown = homeProjectsRowShown(context) &&
        (callbacks.onNewProject != null || ref.watch(homeProjectsProvider).isNotEmpty);
    final openPlaylist = widget.onOpenPlaylist;
    final playlistsShown = openPlaylist != null && state.playlists.isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = danaviewLibraryInsets(constraints.maxWidth);
        final padding = insets.copyWith(top: DanaviewSpacing.lg, bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl);
        final side = padding.copyWith(top: 0, bottom: 0);
        final gridWidth = constraints.maxWidth - side.horizontal;
        final columns = homeAdaptiveColumns(gridWidth);
        final recent = state.recent;
        final shownRecent = _showAllRecent ? recent : recent.take(videosTabRecentPreview).toList();
        // The first section shown sits right under the page's top padding.
        var first = true;
        double spacing() {
          final value = first ? 0.0 : DanaviewSpacing.xl;
          first = false;
          return value;
        }

        final header = <Widget>[
          if (recent.isNotEmpty) ...[
            DanaviewLibrarySectionHeader(
              'Continue watching',
              key: const ValueKey('videos-continue-watching'),
              prominent: true,
              topSpacing: spacing(),
              action: DanaviewButton.text(
                key: const ValueKey('videos-continue-clear'),
                label: 'Clear',
                size: DanaviewButtonSize.sm,
                onPressed: _clearHistory,
              ),
            ),
            if (_showAllRecent)
              HomeMediaCardGrid(children: [for (final item in shownRecent) _recentCard(item)])
            else
              HomeMediaCardRow(children: [for (final item in shownRecent) _recentCard(item)]),
            if (recent.length > videosTabRecentPreview)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: DanaviewButton.text(
                  label: _showAllRecent ? 'Show less' : 'Show all ${recent.length}',
                  size: DanaviewButtonSize.sm,
                  onPressed: () => setState(() => _showAllRecent = !_showAllRecent),
                ),
              ),
          ],
          if (projectsShown) HomeProjectsRow(topSpacing: spacing()),
          if (playlistsShown)
            HomePlaylistsRow(onOpenPlayer: widget.onOpenPlayer, onOpenPlaylist: openPlaylist, topSpacing: spacing()),
          DanaviewLibrarySectionHeader(
            'All videos',
            key: const ValueKey('videos-all-header'),
            prominent: true,
            topSpacing: spacing(),
            action: videos.isEmpty ? null : _sortButton(),
          ),
          if (videos.isEmpty) const LibraryFilterEmpty(filter: LibraryFilter.videos),
        ];
        return CustomScrollView(
          key: const PageStorageKey('library-videos-tab'),
          slivers: [
            SliverPadding(padding: padding.copyWith(bottom: 0), sliver: SliverList.list(children: header)),
            if (videos.length > 0)
              SliverPadding(
                padding: side.copyWith(top: DanaviewSpacing.xs),
                sliver: homeSliverCardGrid(
                  key: ValueKey('videos-grid-${_sort.name}'),
                  columns: columns,
                  width: gridWidth,
                  // A 16:9 media card with the name and the size · date line; no menu.
                  extent: (cell, context) => homeMediaCardExtent(cell, context, menu: false),
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

extension on _VideosTabState {
  /// One Continue watching card: the 16:9 placeholder with play disc, length and progress.
  Widget _recentCard(LibraryRecentItem item) {
    final media = item.media;
    final resumeLength = item.resume?.duration ?? Duration.zero;
    final length = resumeLength > Duration.zero ? resumeLength : media.duration;
    return HomeMediaCard(
      icon: mediaIcon(media),
      title: media.title,
      badge: episodeLabel(media),
      subtitle: mediaSubtitle(media, item.resume, exists: item.exists, fallback: parentFolderName(media.pathOrUri)),
      duration: length > Duration.zero ? formatClock(length) : null,
      progress: item.exists ? item.progress : null,
      dimmed: !item.exists,
      onTap: () => _playRecent(item),
    );
  }
}
