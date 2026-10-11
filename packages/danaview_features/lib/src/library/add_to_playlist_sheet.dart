import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'library_actions.dart';
import 'library_format.dart';
import 'library_providers.dart';
import 'library_widgets.dart';

/// Lets the user pick (or create) a playlist for [items] and reports the result as a toast.
Future<void> showDanaviewAddToPlaylistSheet(BuildContext context, List<MediaRef> items) {
  if (items.isEmpty) return Future.value();
  return showDanaviewSheet<void>(
    context,
    title: items.length == 1 ? 'Add to playlist' : 'Add ${items.length} videos to playlist',
    builder: (context) => _DanaviewAddToPlaylistSheet(items: items),
  );
}

class _DanaviewAddToPlaylistSheet extends ConsumerWidget {
  const _DanaviewAddToPlaylistSheet({required this.items});

  final List<MediaRef> items;

  Future<void> _add(BuildContext context, WidgetRef ref, String playlist) async {
    final navigator = Navigator.of(context);
    await addToPlaylistWithFeedback(context, ref, playlist, items);
    if (navigator.mounted) navigator.pop();
  }

  Future<void> _createAndAdd(BuildContext context, WidgetRef ref) async {
    final created = await promptNewPlaylist(context, ref);
    if (created == null || !context.mounted) return;
    await _add(context, ref, created);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(libraryControllerProvider.select((s) => s.playlists));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DanaviewLibraryRow(
          leading: const DanaviewTileIcon(Icons.add_rounded, size: 40),
          title: 'New playlist…',
          onTap: () => _createAndAdd(context, ref),
        ),
        if (playlists.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              "You don't have any playlists yet. Create one to start collecting videos.",
              style: DanaviewTextStyles.caption,
            ),
          )
        else
          for (final playlist in playlists) ...[
            const DanaviewRowDivider(),
            DanaviewLibraryRow(
              leading: const DanaviewTileIcon(Icons.queue_music_rounded, color: DanaviewColors.purple, size: 40),
              title: playlist.name,
              subtitle: playlist.itemCount == 0 ? 'No videos yet' : formatCount(playlist.itemCount, 'video'),
              onTap: () => _add(context, ref, playlist.name),
            ),
          ],
      ],
    );
  }
}
