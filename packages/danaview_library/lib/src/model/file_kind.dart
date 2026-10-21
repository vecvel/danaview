// OWNER: HOM-16
//
// FileKind, the open kind list (ARCH v1.2 §5.1, BUILD_PLAN HOM-16). The list is extended only by
// appending; a stored kind string this build doesn't know (1.3.0's `savedCode`, NATIVE_CAMERA_PLAN
// CAM-56) decodes to [FileKind.other] so the item still shows as a file. Callers that store kinds
// keep the raw string next to the decoded value (`FileEntry.kindCode`) so nothing is lost when a
// newer library is read and written back by this build.

import 'media_item.dart';

/// The kind of a library item (ARCH v1.2 §5.1). Open and append-only: never reorder or rename a
/// value, only add new ones at the end; [code] is what `library.db` stores.
enum FileKind {
  /// A video (the Videos filter).
  video('video'),

  /// A still photo (the Photos filter).
  photo('photo'),

  /// A document (the Documents filter and its sub-filters).
  document('document'),

  /// An audio file (shown under All).
  audio('audio'),

  /// Any other file, and every stored kind this build doesn't know (1.3.0: `savedCode`).
  other('other');

  const FileKind(this.code);

  /// The stable string stored in `library.db` (`entries.kind`).
  final String code;

  /// The kind stored as [code], or null when this build doesn't know it.
  static FileKind? tryDecode(String code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }

  /// The kind stored as [code]; [FileKind.other] for a code this build doesn't know (a kind
  /// appended by a later version). Keep [code] itself to write it back unchanged.
  static FileKind decode(String code) => tryDecode(code) ?? FileKind.other;

  /// True when [code] is a kind this build knows.
  static bool isKnownCode(String code) => tryDecode(code) != null;
}

/// The [FileKind] of a [MediaItem] (ARCH v1.2 §5.1 `MediaItem.kind`).
extension MediaItemKind on MediaItem {
  /// [FileKind.video], [FileKind.photo] or [FileKind.document] by subtype.
  FileKind get kind => switch (this) {
        VideoMediaItem() => FileKind.video,
        PhotoMediaItem() => FileKind.photo,
        DocumentMediaItem() => FileKind.document,
      };
}
