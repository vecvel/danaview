// OWNER: HOM-17
//
// LibraryFolder, one `folders` row (ARCH v1.2 §5.3), and EntryMeta, one `entry_meta` row. Folder
// membership is a column (V2-06), so a folder is pure database state; `Imported` and `Recovered` are
// system folders the store always keeps.

import 'package:meta/meta.dart';

import '../model/ids.dart';

/// The role of a system folder (`folders.system_role`).
enum FolderSystemRole {
  /// `Imported`: the default import target and the restore target of last resort (V2-08).
  imported('imported', 'Imported'),

  /// `Recovered`: files found without a database row (rebuild-from-files, ARCH §5.3).
  recovered('recovered', 'Recovered');

  const FolderSystemRole(this.code, this.defaultName);

  /// The stored string.
  final String code;

  /// The folder name the store creates it with.
  final String defaultName;

  /// The role stored as [code], or null (a user folder, or a role this build doesn't know).
  static FolderSystemRole? tryDecode(String? code) {
    for (final role in values) {
      if (role.code == code) return role;
    }
    return null;
  }
}

/// One Danaview folder (a `folders` row). Value equality over every field.
@immutable
final class LibraryFolder {
  /// A folder. [parentId] is null at the top level.
  const LibraryFolder({
    required this.id,
    required this.parentId,
    required this.name,
    required this.createdAt,
    required this.modifiedAt,
    this.isFavourite = false,
    this.sortMode,
    this.sortDescending = false,
    this.systemRole,
    this.trashedAt,
    this.expiresAt,
  });

  /// The folder id (`fd_…`).
  final FolderId id;

  /// The parent folder, null at the top level.
  final FolderId? parentId;

  /// The name shown.
  final String name;

  /// When it was created.
  final DateTime createdAt;

  /// When its name, place or settings last changed.
  final DateTime modifiedAt;

  /// Starred.
  final bool isFavourite;

  /// The remembered sort of this folder (HOM-19's codes), or null for the default.
  final String? sortMode;

  /// Whether [sortMode] runs descending.
  final bool sortDescending;

  /// The system role, or null for a user folder.
  final FolderSystemRole? systemRole;

  /// When it went to Recently deleted, if it is there.
  final DateTime? trashedAt;

  /// When Recently deleted removes it for good.
  final DateTime? expiresAt;

  /// True while in Recently deleted.
  bool get isTrashed => trashedAt != null;

  /// True for `Imported` and `Recovered`, which can't be renamed, moved or deleted.
  bool get isSystem => systemRole != null;

  @override
  bool operator ==(Object other) =>
      other is LibraryFolder &&
      other.id == id &&
      other.parentId == parentId &&
      other.name == name &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.modifiedAt.isAtSameMomentAs(modifiedAt) &&
      other.isFavourite == isFavourite &&
      other.sortMode == sortMode &&
      other.sortDescending == sortDescending &&
      other.systemRole == systemRole &&
      other.trashedAt?.millisecondsSinceEpoch == trashedAt?.millisecondsSinceEpoch &&
      other.expiresAt?.millisecondsSinceEpoch == expiresAt?.millisecondsSinceEpoch;

  @override
  int get hashCode => Object.hash(id, parentId, name, isFavourite, sortMode, systemRole, trashedAt?.millisecondsSinceEpoch);

  @override
  String toString() => 'LibraryFolder(${id.value}${isTrashed ? ', trashed' : ''})';
}

/// Photo, video and document facts of an entry (an `entry_meta` row). Every field is optional.
@immutable
final class EntryMeta {
  /// Facts of one entry.
  const EntryMeta({
    this.width,
    this.height,
    this.duration,
    this.fps,
    this.codec,
    this.pageCount,
    this.takenAt,
    this.camera,
    this.flags = 0,
  });

  /// `flags` bit: a RAW photo.
  static const int flagRaw = 1;

  /// `flags` bit: an HDR photo or video.
  static const int flagHdr = 2;

  /// `flags` bit: a Live Photo.
  static const int flagLive = 4;

  /// Pixel width.
  final int? width;

  /// Pixel height.
  final int? height;

  /// Video or audio duration.
  final Duration? duration;

  /// Video frame rate.
  final double? fps;

  /// Codec name.
  final String? codec;

  /// Document page count.
  final int? pageCount;

  /// Capture time from the file's metadata.
  final DateTime? takenAt;

  /// Camera model.
  final String? camera;

  /// [flagRaw] | [flagHdr] | [flagLive].
  final int flags;

  /// True when no fact is set.
  bool get isEmpty =>
      width == null &&
      height == null &&
      duration == null &&
      fps == null &&
      codec == null &&
      pageCount == null &&
      takenAt == null &&
      camera == null &&
      flags == 0;

  @override
  bool operator ==(Object other) =>
      other is EntryMeta &&
      other.width == width &&
      other.height == height &&
      other.duration == duration &&
      other.fps == fps &&
      other.codec == codec &&
      other.pageCount == pageCount &&
      other.takenAt?.millisecondsSinceEpoch == takenAt?.millisecondsSinceEpoch &&
      other.camera == camera &&
      other.flags == flags;

  @override
  int get hashCode => Object.hash(width, height, duration, fps, codec, pageCount, camera, flags);
}
