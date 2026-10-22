// OWNER: HOM-22
//
// Providers of the file actions (ARCH v1.2 V2-117, V2-118; BUILD_PLAN HOM-22): the library-side
// actions over the open store (null with DANAVIEW_FILES_HOME off: nothing opens the store), the
// getting-files-out port (the native plugin on iOS, macOS and Android; the app root overrides it
// with a [DesktopFileOut] on Windows and Linux) and the optional "Merge into PDF" handler that
// HOM-28 supplies through the app root (INT-103). Labels and icons of every action live here too,
// so the single-file menu and the multi-select bar say the same thing.

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../files/library_store_providers.dart';
import 'file_out_ports.dart';

/// The file-out platform of [platform].
FileOutPlatform fileOutPlatformOf(TargetPlatform platform) => switch (platform) {
      TargetPlatform.iOS => FileOutPlatform.iOS,
      TargetPlatform.android => FileOutPlatform.android,
      TargetPlatform.macOS => FileOutPlatform.macOS,
      TargetPlatform.windows => FileOutPlatform.windows,
      TargetPlatform.linux || TargetPlatform.fuchsia => FileOutPlatform.linux,
    };

/// The library-side file actions, or null without a library store.
final libraryFileActionsProvider = Provider<LibraryFileActions?>((ref) {
  final store = ref.watch(libraryStoreProvider);
  return store == null ? null : LibraryFileActions(store);
});

/// Getting files out: the native plugin on iOS, macOS and Android; null on Windows and Linux until
/// the app root overrides it with a [DesktopFileOut] over its save dialog.
final fileOutPortProvider = Provider<FileOutPort?>((ref) {
  final platform = fileOutPlatformOf(defaultTargetPlatform);
  return switch (platform) {
    FileOutPlatform.iOS || FileOutPlatform.android || FileOutPlatform.macOS => NativeFileOut(platform),
    FileOutPlatform.windows || FileOutPlatform.linux => null,
  };
});

/// Merges PDFs and photos into a new PDF (HOM-28, wired by the app root); null hides the action.
typedef MergeIntoPdfHandler = Future<void> Function(BuildContext context, List<MediaItem> items);

/// The "Merge into PDF" handler, or null (the action is hidden).
final mergeIntoPdfHandlerProvider = Provider<MergeIntoPdfHandler?>((ref) => null);

/// The label of [action]; [capabilities] names the save action, [favourite] says whether the
/// single item is starred already, [group] picks the short multi-select labels.
String fileActionLabel(FileAction action, {FileOutCapabilities? capabilities, bool favourite = false, bool group = false}) =>
    switch (action) {
      FileAction.share => 'Share',
      FileAction.copyTo => group ? 'Copy' : 'Copy to…',
      FileAction.moveTo => group ? 'Move' : 'Move to…',
      FileAction.rename => 'Rename',
      FileAction.info => 'File info',
      FileAction.openIn => 'Open in another app',
      FileAction.favourite => group ? 'Favourite' : (favourite ? 'Remove from favourites' : 'Add to favourites'),
      FileAction.saveOut => (capabilities ?? FileOutCapabilities.of(fileOutPlatformOf(defaultTargetPlatform))).saveLabel,
      FileAction.saveToPhotos => 'Save to Photos',
      FileAction.mergeIntoPdf => 'Merge into PDF',
      FileAction.delete => 'Delete',
    };

/// The icon of [action].
IconData fileActionIcon(FileAction action, {bool favourite = false}) => switch (action) {
      FileAction.share => Icons.ios_share_rounded,
      FileAction.copyTo => Icons.copy_rounded,
      FileAction.moveTo => Icons.drive_file_move_outline,
      FileAction.rename => Icons.drive_file_rename_outline_rounded,
      FileAction.info => Icons.info_outline_rounded,
      FileAction.openIn => Icons.open_in_new_rounded,
      FileAction.favourite => favourite ? Icons.star_rounded : Icons.star_outline_rounded,
      FileAction.saveOut => Icons.save_alt_rounded,
      FileAction.saveToPhotos => Icons.add_photo_alternate_outlined,
      FileAction.mergeIntoPdf => Icons.picture_as_pdf_outlined,
      FileAction.delete => Icons.delete_outline_rounded,
    };

/// The stable id of [action] in keys and tests (`file-share`, `file-move-to`, …).
String fileActionId(FileAction action) => switch (action) {
      FileAction.share => 'file-share',
      FileAction.copyTo => 'file-copy-to',
      FileAction.moveTo => 'file-move-to',
      FileAction.rename => 'file-rename',
      FileAction.info => 'file-info',
      FileAction.openIn => 'file-open-in',
      FileAction.favourite => 'file-favourite',
      FileAction.saveOut => 'file-save-out',
      FileAction.saveToPhotos => 'file-save-photos',
      FileAction.mergeIntoPdf => 'file-merge-pdf',
      FileAction.delete => 'file-delete',
    };
