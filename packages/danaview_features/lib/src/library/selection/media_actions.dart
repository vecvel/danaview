// OWNER: HOM-12
//
// The media group of the multi-select bar (ARCH v1.2 V2-107, Q-H2 default; BUILD_PLAN HOM-12):
//
// * Make video montage: photos and/or videos → `HomeCallbacks.onMakeMontage` (editor platforms).
// * Batch edit photos: photos only → `HomeCallbacks.onBatchEditPhotos` (editor platforms).
// * Play all: queues the videos as `MediaRef`s in selection order; photos join the queue only
//   where the player shows them (V2-V4), otherwise they are skipped with a notice.
// * Add to playlist: the selected videos (playlists hold videos only).
//
// A selection holding documents gets no media group: documents can't go on a timeline, into the
// player or into a playlist; HOM-22's file group serves them. Every callback receives the items
// in the order the user picked them.

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';

import '../add_to_playlist_sheet.dart';
import '../library_actions.dart';
import 'selection_actions.dart';
import 'selection_model.dart';

/// The id of the media group.
const String mediaSelectionGroupId = 'media';

/// The media group for [context], or null when the selection holds documents or nothing fits.
SelectionActionGroup? mediaSelectionGroup(SelectionActionContext context) {
  final selection = context.selection;
  final mix = selection.mix;
  if (mix != SelectionMix.photos && mix != SelectionMix.videos && mix != SelectionMix.media) return null;
  final callbacks = context.callbacks;
  final onMontage = callbacks.onMakeMontage;
  final onBatchEdit = callbacks.onBatchEditPhotos;
  final actions = <SelectionAction>[
    if (context.editorAvailable && onMontage != null)
      SelectionAction(
        id: 'montage',
        label: 'Make video montage',
        icon: Icons.movie_creation_outlined,
        onInvoke: (inv) {
          final items = inv.selection.media;
          inv.clearSelection();
          onMontage(items);
        },
      ),
    if (context.editorAvailable && onBatchEdit != null && mix == SelectionMix.photos)
      SelectionAction(
        id: 'batch-edit',
        label: selection.length == 1 ? 'Edit photo' : 'Batch edit photos',
        icon: Icons.auto_fix_high_outlined,
        onInvoke: (inv) {
          final photos = inv.selection.photos;
          inv.clearSelection();
          onBatchEdit(photos);
        },
      ),
    if (mix != SelectionMix.photos || context.playerShowsPhotos)
      SelectionAction(
        id: 'play',
        label: 'Play all',
        icon: Icons.play_arrow_rounded,
        onInvoke: _playAll,
      ),
    if (mix != SelectionMix.photos)
      SelectionAction(
        id: 'add-to-playlist',
        label: mix == SelectionMix.media ? 'Add videos to playlist' : 'Add to playlist',
        icon: Icons.playlist_add_rounded,
        onInvoke: _addToPlaylist,
      ),
  ];
  if (actions.isEmpty) return null;
  return SelectionActionGroup(id: mediaSelectionGroupId, title: 'Media actions', actions: actions);
}

/// The queue "Play all" builds from [items]: videos always, photos only when [photosPlayable],
/// their URI is one the player opens (a file path or a `file://` URI, not a system-library asset
/// id) and their format is one the bundled libmpv decodes ([playerDecodesPhoto]: JPEG only, V2-V4).
/// Returns the refs in selection order and how many photos were left out.
({List<MediaRef> refs, int skippedPhotos}) playQueueFor(List<MediaItem> items, {required bool photosPlayable}) {
  final refs = <MediaRef>[];
  var skipped = 0;
  for (final item in items) {
    switch (item) {
      case VideoMediaItem():
        refs.add(item.toMediaRef());
      case PhotoMediaItem():
        if (photosPlayable && _playerOpens(item.uri) && playerDecodesPhoto(item)) {
          refs.add(MediaRef(id: item.id.value, title: item.name, pathOrUri: item.uri, fileSize: item.sizeBytes));
        } else {
          skipped++;
        }
      case DocumentMediaItem():
        break;
    }
  }
  return (refs: List.unmodifiable(refs), skippedPhotos: skipped);
}

/// Whether the bundled libmpv decodes [photo]'s format (ARCH V2-V4, HOM-12 2026-10-22): media_kit's
/// FFmpeg has the `mjpeg` decoder but no PNG, HEIF/HEIC, TIFF, GIF, BMP or WebP image decoder,
/// so only JPEG stills open (mpv's `mf` demuxer, shown for `image-display-duration`).
bool playerDecodesPhoto(PhotoMediaItem photo) {
  final mime = photo.mimeType.toLowerCase();
  if (mime == 'image/jpeg' || mime == 'image/jpg' || mime == 'image/pjpeg') return true;
  if (mime.isNotEmpty && mime != 'application/octet-stream') return false;
  final path = photo.uri.toLowerCase();
  return path.endsWith('.jpg') || path.endsWith('.jpeg') || path.endsWith('.jpe');
}

bool _playerOpens(String uri) => uri.startsWith('/') || uri.startsWith('file://') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(uri);

/// The notice shown when "Play all" left photos out.
String skippedPhotosNotice(int skipped, {required bool nothingQueued}) {
  final what = skipped == 1 ? 'The photo was' : '$skipped photos were';
  return nothingQueued ? "The player can't show photos yet" : "$what skipped: the player can't show photos yet";
}

void _playAll(SelectionInvocation inv) {
  final queue = playQueueFor(inv.selection.media, photosPlayable: inv.action.playerShowsPhotos);
  final context = inv.context;
  if (queue.skippedPhotos > 0) {
    DanaviewToast.show(
      context,
      skippedPhotosNotice(queue.skippedPhotos, nothingQueued: queue.refs.isEmpty),
      icon: Icons.info_outline_rounded,
    );
  }
  if (queue.refs.isEmpty) return;
  inv.clearSelection();
  danaviewPlayItems(inv.ref, queue.refs);
  inv.action.onOpenPlayer?.call();
}

Future<void> _addToPlaylist(SelectionInvocation inv) async {
  final refs = [for (final v in inv.selection.videos) v.toMediaRef()];
  if (refs.isEmpty) return;
  await showDanaviewAddToPlaylistSheet(inv.context, refs);
  if (inv.context.mounted) inv.clearSelection();
}
