// OWNER: HOM-22
//
// Which file actions an item or a selection gets (ARCH v1.2 V2-118, V2-08; HOM plan §8.3, D-98e):
//
// * A Danaview folder file (`fe_`): Share, Copy to…, Move to…, Rename, File info, Open in another
//   app, Add to favourites, Save a copy, Save to Photos (photos and videos), Delete.
// * A read-only file with a local path (a linked-folder file, a 1.1 library video): Share, File
//   info, Open in another app, Save a copy, Save to Photos — never rename, move or delete.
// * An item without a readable path (a system-library asset): File info only.
//
// The multi-select file group: Share, Move, Copy, Favourite, Delete and Save out when every item
// is a Danaview file; only the out actions otherwise; "Merge into PDF" when the selection holds
// only PDFs and photos, at least two (routed to HOM-28; one photo as a PDF is 1.3.0's Export as
// PDF, D-115d). Platform limits come from [FileOutCapabilities].

import '../model/document_item.dart';
import '../model/ids.dart';
import '../model/media_item.dart';

/// One file action.
enum FileAction {
  /// The system share sheet.
  share,

  /// Copy into a Danaview folder.
  copyTo,

  /// Move into a Danaview folder.
  moveTo,

  /// Rename the file.
  rename,

  /// The File info sheet.
  info,

  /// Open in another app.
  openIn,

  /// Add to (or remove from) favourites.
  favourite,

  /// Save a copy outside Danaview (Save to Files / Downloads / save dialog).
  saveOut,

  /// Save to the system photo library (add-only).
  saveToPhotos,

  /// Merge the selected PDFs and photos into a new PDF (HOM-28).
  mergeIntoPdf,

  /// Move to Recently deleted (with the "Used in N projects" warning).
  delete,
}

/// What an action needs to know about one item.
final class FileActionTarget {
  /// A target.
  const FileActionTarget({required this.item, required this.isLibraryEntry, required this.localPath});

  /// The target of [item]: library entries by their `fe_` id; other items are read-only and
  /// leave the app only when [MediaItem.uri] is a local path or `file://` URI.
  factory FileActionTarget.of(MediaItem item) {
    final entry = EntryId.tryParse(item.id.value) != null;
    return FileActionTarget(item: item, isLibraryEntry: entry, localPath: localPathOf(item.uri));
  }

  /// The item.
  final MediaItem item;

  /// True for a Danaview folder file (writable through the store).
  final bool isLibraryEntry;

  /// A readable local path, or null.
  final String? localPath;

  /// The entry id of a library file.
  EntryId? get entryId => isLibraryEntry ? EntryId.tryParse(item.id.value) : null;

  /// Whether the file can be handed out (share, open in, save out).
  bool get canLeave => isLibraryEntry || localPath != null;

  /// Photo or video.
  bool get isMedia => item is PhotoMediaItem || item is VideoMediaItem;

  /// A PDF or a photo (the inputs of Merge into PDF).
  bool get isPdfOrImage => switch (item) {
        PhotoMediaItem() => true,
        DocumentItem(docKind: DocumentKind.pdf) => true,
        _ => item.mimeType == 'application/pdf',
      };
}

/// The local path of [uri] (an absolute path, a Windows drive path or a `file://` URI), or null.
String? localPathOf(String uri) {
  if (uri.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(uri)) return uri;
  if (uri.startsWith('file://')) {
    try {
      return Uri.parse(uri).toFilePath();
    } on UnsupportedError {
      return null;
    } on FormatException {
      return null;
    }
  }
  return null;
}

/// The single-file menu of [target], in menu order, for a platform offering [canShare],
/// [canOpenIn], [canSaveOut] and [canSaveToPhotos].
List<FileAction> fileActionsFor(
  FileActionTarget target, {
  required bool canShare,
  required bool canOpenIn,
  required bool canSaveOut,
  required bool canSaveToPhotos,
}) {
  final out = target.canLeave;
  final lib = target.isLibraryEntry;
  return [
    if (out && canShare) FileAction.share,
    if (lib) FileAction.copyTo,
    if (lib) FileAction.moveTo,
    if (lib) FileAction.rename,
    FileAction.info,
    if (out && canOpenIn) FileAction.openIn,
    if (lib) FileAction.favourite,
    if (out && canSaveOut) FileAction.saveOut,
    if (out && canSaveToPhotos && target.isMedia) FileAction.saveToPhotos,
    if (lib) FileAction.delete,
  ];
}

/// The multi-select file group for [targets] (selection order), in bar order. [canMerge] is
/// whether a Merge into PDF handler exists (HOM-28 wired).
List<FileAction> selectionFileActionsFor(
  List<FileActionTarget> targets, {
  required bool canShare,
  required bool canSaveOut,
  required bool canSaveToPhotos,
  bool canMerge = false,
}) {
  if (targets.isEmpty) return const [];
  final allLibrary = targets.every((t) => t.isLibraryEntry);
  final allLeave = targets.every((t) => t.canLeave);
  return [
    if (allLeave && canShare) FileAction.share,
    if (allLibrary) FileAction.moveTo,
    if (allLibrary) FileAction.copyTo,
    if (allLibrary) FileAction.favourite,
    if (allLeave && canSaveOut) FileAction.saveOut,
    if (allLeave && canSaveToPhotos && targets.every((t) => t.isMedia)) FileAction.saveToPhotos,
    if (canMerge && allLeave && targets.length > 1 && targets.every((t) => t.isPdfOrImage)) FileAction.mergeIntoPdf,
    if (allLibrary) FileAction.delete,
  ];
}
