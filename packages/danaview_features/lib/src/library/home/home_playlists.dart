// The playlist cards (DESIGN_SYSTEM §10.4): a 2×2 mosaic of the playlist's first items, the name
// and the count, in a media card with the More menu (Play, Shuffle, Rename, Delete). The Videos
// tab shows them as a horizontal row with "See all" ([HomePlaylistsRow]); "See all" opens the
// Playlists screen, which lays the same cards in the adaptive grid with New. The 1.1 Home (flag
// off) keeps the grouped list. [HomePlaylistActions] holds the playlist actions all of them share.

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library_actions.dart';
import '../library_format.dart';
import '../library_providers.dart';
import '../library_widgets.dart';
import 'home_grid.dart';
import 'home_media_card.dart';
import 'home_tabs.dart';

/// The playlist actions of the Home, its Videos tab and the Playlists screen: New, Play, Shuffle,
/// Rename and Delete, with the 1.1 prompts, confirmations and toasts.
class HomePlaylistActions {
  /// Actions run from [context]; [onOpenPlayer] shows the player after Play, [onOpenPlaylist]
  /// opens a playlist (a new one is opened once created).
  const HomePlaylistActions(this.context, this.ref, {required this.onOpenPlayer, required this.onOpenPlaylist});

  /// Where prompts, confirmations and toasts show.
  final BuildContext context;

  /// The library and the queue.
  final WidgetRef ref;

  /// Shows the player.
  final VoidCallback onOpenPlayer;

  /// Opens a playlist by name.
  final ValueChanged<String> onOpenPlaylist;

  /// The count line of a playlist ("4 videos", "No videos yet").
  static String subtitle(PlaylistSummary playlist) =>
      playlist.itemCount == 0 ? 'No videos yet' : formatCount(playlist.itemCount, 'video');

  /// The items of playlist [name], in order.
  List<MediaRef> items(String name) => ref.read(libraryControllerProvider.notifier).playlistItems(name);

  /// Asks for a name, creates the playlist and opens it.
  Future<void> create() async {
    final name = await promptNewPlaylist(context, ref);
    if (name != null && context.mounted) onOpenPlaylist(name);
  }

  /// Plays playlist [name] (shuffled with [shuffle]); an empty one shows a toast.
  void play(String name, {bool shuffle = false}) {
    final list = items(name);
    if (list.isEmpty) {
      DanaviewToast.show(context, '"$name" is empty. Add videos to play it.', icon: Icons.info_outline_rounded);
      return;
    }
    danaviewPlayItems(ref, list, shuffle: shuffle);
    onOpenPlayer();
  }

  /// Asks for a new name.
  Future<void> rename(String name) async {
    final renamed = await promptRenamePlaylist(context, ref, name);
    if (renamed != null && context.mounted) showDanaviewSuccess(context, 'Renamed to "$renamed"');
  }

  /// Asks first, then deletes the playlist (never its videos).
  Future<void> delete(String name) async {
    if (!await confirmDeletePlaylist(context, name)) return;
    await ref.read(libraryControllerProvider.notifier).deletePlaylist(name);
    if (context.mounted) showDanaviewSuccess(context, 'Deleted "$name"');
  }

  /// The More menu of a playlist row or card: Play, Shuffle, Rename and Delete.
  Widget menu(PlaylistSummary playlist) => DanaviewMenuIconTrigger(
        icon: Icons.more_horiz_rounded,
        tooltip: 'More',
        entries: [
          DanaviewMenuItem(
            label: 'Play',
            icon: Icons.play_arrow_rounded,
            enabled: playlist.itemCount > 0,
            onTap: () => play(playlist.name),
          ),
          DanaviewMenuItem(
            label: 'Shuffle',
            icon: Icons.shuffle_rounded,
            enabled: playlist.itemCount > 1,
            onTap: () => play(playlist.name, shuffle: true),
          ),
          const DanaviewMenuDivider(),
          DanaviewMenuItem(
            label: 'Rename',
            icon: Icons.edit_rounded,
            onTap: () => rename(playlist.name),
          ),
          DanaviewMenuItem(
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onTap: () => delete(playlist.name),
          ),
        ],
      );

  /// The card of [playlist] with its menu.
  Widget card(PlaylistSummary playlist) => HomePlaylistCard(
        name: playlist.name,
        subtitle: subtitle(playlist),
        items: items(playlist.name),
        onOpen: () => onOpenPlaylist(playlist.name),
        trailing: menu(playlist),
      );
}

/// The Videos tab's Playlists section: playlist cards in one horizontal row, with "See all"
/// opening the Playlists screen. It draws nothing without playlists (New playlist stays in the
/// Import menu and on the Playlists screen).
class HomePlaylistsRow extends ConsumerWidget {
  /// The row; [onOpenPlayer] and [onOpenPlaylist] are the router's.
  const HomePlaylistsRow({super.key, required this.onOpenPlayer, required this.onOpenPlaylist, this.topSpacing});

  /// Shows the player after Play.
  final VoidCallback onOpenPlayer;

  /// Opens a playlist by name.
  final ValueChanged<String> onOpenPlaylist;

  /// Space above the header (the header's default when null).
  final double? topSpacing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(libraryControllerProvider.select((s) => s.playlists));
    // Re-read the mosaics when a playlist's contents change.
    ref.watch(libraryControllerProvider.select((s) => s.playlistRevision));
    if (playlists.isEmpty) return const SizedBox.shrink(key: ValueKey('home-playlists-row-hidden'));
    final actions = HomePlaylistActions(context, ref, onOpenPlayer: onOpenPlayer, onOpenPlaylist: onOpenPlaylist);
    return Column(
      key: const ValueKey('home-playlists-row'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DanaviewLibrarySectionHeader(
          'Playlists',
          prominent: true,
          topSpacing: topSpacing ?? DanaviewSpacing.xl,
          action: DanaviewButton.text(
            key: const ValueKey('home-playlists-see-all'),
            label: 'See all',
            size: DanaviewButtonSize.sm,
            onPressed: () => const HomeDestinationRequestNotification(HomeDestination.playlists).dispatch(context),
          ),
        ),
        HomeMediaCardRow(children: [for (final playlist in playlists) actions.card(playlist)]),
      ],
    );
  }
}

/// Columns of playlist cards in a [width]-wide page: the adaptive 2 / 4 / 6.
int homePlaylistColumns(double width) => homeAdaptiveColumns(width);

/// One playlist card.
class HomePlaylistCard extends StatelessWidget {
  /// The card of playlist [name] holding [items] ([count] in all); [onOpen] opens it, [trailing]
  /// is its More menu.
  const HomePlaylistCard({
    super.key,
    required this.name,
    required this.subtitle,
    required this.items,
    this.onOpen,
    this.trailing,
  });

  /// The playlist name.
  final String name;

  /// The count line ("4 videos", "No videos yet").
  final String subtitle;

  /// The first items (up to four are drawn in the mosaic).
  final List<MediaRef> items;

  /// Opens the playlist.
  final VoidCallback? onOpen;

  /// The More menu.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: ValueKey('home-playlist-$name'),
      child: HomeMediaCard(
        title: name,
        subtitle: subtitle,
        icon: Icons.queue_music_rounded,
        showPlay: false,
        thumbnail: items.isEmpty ? null : _Mosaic(items: items.take(4).toList()),
        onTap: onOpen,
        trailing: trailing,
      ),
    );
  }
}

/// A 2×2 mosaic of neutral item tiles with 2 pt gaps; missing cells stay placeholder grey.
class _Mosaic extends StatelessWidget {
  const _Mosaic({required this.items});

  final List<MediaRef> items;

  @override
  Widget build(BuildContext context) {
    Widget cell(int i) => i < items.length
        ? HomeMediaPlaceholder(icon: mediaIcon(items[i]))
        : const ColoredBox(color: DanaviewColors.mediaPlaceholder);
    Widget row(int first) => Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [Expanded(child: cell(first)), const SizedBox(width: 2), Expanded(child: cell(first + 1))],
          ),
        );
    return ColoredBox(
      color: DanaviewColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [row(0), const SizedBox(height: 2), row(2)],
      ),
    );
  }
}
