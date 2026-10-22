// OWNER: HOM-11
//
// The photo viewer's toolbar (ARCH v1.2 V2-106, §3, rule 23; BUILD_PLAN HOM-11): Share, Favourite,
// Edit, File info and Delete. Every action a photo can't take is hidden, not disabled (§3):
//
// * Share goes through [PhotoViewerHooks.share], which HOM-22 (system share sheet, temporary
//   read-only copy) supplies at the app root; without it the button is hidden.
// * Favourite stars Danaview photos in library.db (HOM-19's organiser); system and desktop photos
//   have no Danaview star, so the button is hidden for them.
// * Edit calls `HomeCallbacks.onEditPhoto` (Still Photo Mode, wired by INT-105); it is shown only
//   when that callback is set and the platform runs the editor (iOS and Android in 1.2.0).
// * File info opens the info sheet (EXIF and file facts).
// * Delete moves a Danaview photo to Recently deleted after a confirmation that names the
//   projects using it (V2-08); a system photo is deleted only through
//   [PhotoViewerHooks.deleteSystemPhoto] (the platform's own confirmation), otherwise hidden.
//   Linked-folder and desktop photos are never deleted from here.

import 'package:danaview_library/danaview_library.dart' show recentlyDeletedRetention;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_tabs.dart' show homeEditorPlatform;
import '../photos/photo_grid_item.dart';
import 'photo_viewer_entry.dart';

/// Optional platform actions the app root supplies (HOM-22, INT-103).
@immutable
final class PhotoViewerHooks {
  /// Hooks; null ones hide their buttons.
  const PhotoViewerHooks({this.share, this.deleteSystemPhoto});

  /// No hooks.
  static const PhotoViewerHooks none = PhotoViewerHooks();

  /// Shares a photo (a temporary read-only copy through the system share sheet).
  final Future<void> Function(BuildContext context, PhotoViewerEntry entry)? share;

  /// Deletes a system-library photo through the platform; true when it was deleted.
  final Future<bool> Function(BuildContext context, PhotoViewerEntry entry)? deleteSystemPhoto;
}

/// The viewer's hooks. The app root overrides it (HOM-22's share sheet).
final photoViewerHooksProvider = Provider<PhotoViewerHooks>((ref) => PhotoViewerHooks.none);

/// The toolbar's actions, in order.
enum PhotoViewerAction {
  /// Share sheet.
  share,

  /// Star or unstar.
  favourite,

  /// Edit in the editor's Still Photo Mode.
  edit,

  /// The info sheet.
  info,

  /// Move to Recently deleted.
  delete,
}

/// The actions the toolbar shows for [entry].
///
/// [hasEditCallback]: `HomeCallbacks.onEditPhoto` is set. [libraryWritable]: a library store is
/// open and writable.
List<PhotoViewerAction> photoViewerActionsFor({
  required PhotoViewerEntry entry,
  required TargetPlatform platform,
  required bool hasEditCallback,
  required bool libraryWritable,
  PhotoViewerHooks hooks = PhotoViewerHooks.none,
}) {
  final danaview = entry.item.origin == PhotoOrigin.danaview && entry.entryId != null;
  return [
    if (hooks.share != null) PhotoViewerAction.share,
    if (danaview && libraryWritable) PhotoViewerAction.favourite,
    if (hasEditCallback && homeEditorPlatform(platform)) PhotoViewerAction.edit,
    PhotoViewerAction.info,
    if ((danaview && libraryWritable) || (entry.item.origin == PhotoOrigin.system && hooks.deleteSystemPhoto != null))
      PhotoViewerAction.delete,
  ];
}

/// The confirmation text of deleting a Danaview photo used by [projects] projects (V2-08).
String photoDeleteMessage({required int projects, required int recipes}) {
  final used = <String>[
    if (projects > 0) projects == 1 ? 'Used in 1 project.' : 'Used in $projects projects.',
    if (recipes > 0) recipes == 1 ? 'Has 1 saved edit.' : 'Has $recipes saved edits.',
  ];
  final keep = 'It stays in Recently deleted for ${recentlyDeletedRetention.inDays} days.';
  return used.isEmpty ? keep : '${used.join(' ')} $keep';
}
