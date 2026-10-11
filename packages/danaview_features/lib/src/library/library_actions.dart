import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../controllers/providers.dart';
import 'library_providers.dart';
import 'media_picker.dart';

/// Replaces the queue with [items] and starts playing. [shuffle] starts at a random item and
/// shuffles the rest, keeping the original order to restore when shuffle is turned off.
void danaviewPlayItems(WidgetRef ref, List<MediaRef> items, {int startIndex = 0, bool shuffle = false}) {
  if (items.isEmpty) return;
  final queue = ref.read(queueControllerProvider.notifier);
  final start = shuffle ? math.Random().nextInt(items.length) : startIndex;
  queue.playFrom(items, startIndex: start).catchError((Object e) {
    debugPrint('[Library] playFrom failed: $e');
  });
  if (shuffle) queue.setShuffle(true);
}

String danaviewErrorMessage(Object error) => switch (error) {
      MediaPickerException(:final message) => message,
      PlaylistException(:final message) => message,
      _ => 'Something went wrong. Please try again.',
    };

void showDanaviewError(BuildContext context, Object error) {
  if (error is! MediaPickerException && error is! PlaylistException) debugPrint('[Library] $error');
  DanaviewToast.show(context, danaviewErrorMessage(error), kind: DanaviewToastKind.error, icon: Icons.error_outline_rounded);
}

void showDanaviewSuccess(BuildContext context, String message) {
  DanaviewToast.show(context, message, kind: DanaviewToastKind.success, icon: Icons.check_circle_rounded);
}

/// Asks for a name and creates the playlist; returns its stored name, or null when cancelled.
Future<String?> promptNewPlaylist(BuildContext context, WidgetRef ref) async {
  final library = ref.read(libraryControllerProvider.notifier);
  final name = await showDanaviewPrompt(
    context,
    title: 'New playlist',
    hint: 'Playlist name',
    confirmLabel: 'Create',
    prefixIcon: Icons.queue_music_rounded,
    validator: (value) => library.validatePlaylistName(value),
  );
  if (name == null) return null;
  try {
    return await library.createPlaylist(name);
  } on PlaylistException catch (e) {
    if (context.mounted) showDanaviewError(context, e);
    return null;
  }
}

/// Returns the new name, or null when cancelled or unchanged.
Future<String?> promptRenamePlaylist(BuildContext context, WidgetRef ref, String name) async {
  final library = ref.read(libraryControllerProvider.notifier);
  final newName = await showDanaviewPrompt(
    context,
    title: 'Rename playlist',
    initialValue: name,
    hint: 'Playlist name',
    confirmLabel: 'Rename',
    prefixIcon: Icons.queue_music_rounded,
    validator: (value) => library.validatePlaylistName(value, renaming: name),
  );
  if (newName == null || newName == name) return null;
  try {
    return await library.renamePlaylist(name, newName);
  } on PlaylistException catch (e) {
    if (context.mounted) showDanaviewError(context, e);
    return null;
  }
}

/// Asks before deleting a playlist; deleting never touches its videos.
Future<bool> confirmDeletePlaylist(BuildContext context, String name) {
  return showDanaviewConfirm(
    context,
    title: 'Delete playlist',
    message: '"$name" will be deleted. The videos stay on disk.',
    confirmLabel: 'Delete',
    destructive: true,
    icon: Icons.delete_outline_rounded,
  );
}

/// Adds [items] to [playlist] and reports the result as a toast.
Future<void> addToPlaylistWithFeedback(
  BuildContext context,
  WidgetRef ref,
  String playlist,
  List<MediaRef> items,
) async {
  try {
    final added = await ref.read(libraryControllerProvider.notifier).addToPlaylist(playlist, items);
    if (!context.mounted) return;
    if (added == 0) {
      DanaviewToast.show(
        context,
        items.length == 1 ? 'Already in $playlist' : 'These videos are already in $playlist',
        icon: Icons.info_outline_rounded,
      );
    } else {
      showDanaviewSuccess(
        context,
        items.length == 1 ? 'Added to $playlist' : 'Added ${added == 1 ? '1 video' : '$added videos'} to $playlist',
      );
    }
  } on PlaylistException catch (e) {
    if (context.mounted) showDanaviewError(context, e);
  }
}
