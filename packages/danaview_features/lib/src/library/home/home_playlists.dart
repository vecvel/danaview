// The Playlists tab's cards (DESIGN_SYSTEM §10.4): a 2×2 mosaic of the playlist's first items, the
// name and the count, in a media card with the row's More menu. The Home tab keeps the grouped
// list (§10.3 #4); only the tab shows the grid.

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';

import '../library_format.dart';
import 'home_grid.dart';
import 'home_media_card.dart';

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
