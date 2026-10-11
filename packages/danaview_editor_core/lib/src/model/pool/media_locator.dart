// OWNER: CORE-04
//
// Where a pool asset lives (ARCH §6.8, §9.1). Persisted locators never contain an absolute app
// container path (the iOS container UUID changes on update): app files use [AppRelativeLocator];
// [BookmarkLocator.lastKnownPath] is a display hint only.

import 'package:meta/meta.dart';

/// App roots an [AppRelativeLocator] can be relative to.
enum AppRoot {
  /// The user's "On This Device" library (`Documents`). Read-only to the editor.
  documents,

  /// Application Support (editor projects, managed copies, derived renditions).
  support,

  /// Caches (purgeable).
  cache,
}

/// Locates a media file. Sealed.
@immutable
sealed class MediaLocator {
  const MediaLocator();
}

/// A file under one of the app's own roots, stored relative to that root.
final class AppRelativeLocator extends MediaLocator {
  /// Creates a locator for [relPath] under [root].
  const AppRelativeLocator(this.root, this.relPath);

  /// Root.
  final AppRoot root;

  /// Path relative to [root], `/`-separated.
  final String relPath;

  /// A copy with the given fields replaced.
  AppRelativeLocator copyWith({AppRoot? root, String? relPath}) =>
      AppRelativeLocator(root ?? this.root, relPath ?? this.relPath);

  @override
  bool operator ==(Object other) => other is AppRelativeLocator && other.root == root && other.relPath == relPath;

  @override
  int get hashCode => Object.hash(root, relPath);
}

/// An absolute file path. Desktop only (later); never persisted on iOS/Android.
final class FileLocator extends MediaLocator {
  /// Creates a path locator.
  const FileLocator(this.path);

  /// Absolute path.
  final String path;

  /// A copy with the given path.
  FileLocator copyWith({String? path}) => FileLocator(path ?? this.path);

  @override
  bool operator ==(Object other) => other is FileLocator && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// An Android `content://` URI with a persisted read grant.
final class ContentUriLocator extends MediaLocator {
  /// Creates a content-URI locator.
  const ContentUriLocator(this.uri);

  /// The `content://` URI.
  final String uri;

  /// A copy with the given URI.
  ContentUriLocator copyWith({String? uri}) => ContentUriLocator(uri ?? this.uri);

  @override
  bool operator ==(Object other) => other is ContentUriLocator && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;
}

/// An iOS security-scoped bookmark (Files picks, player in-place URLs).
final class BookmarkLocator extends MediaLocator {
  /// Creates a bookmark locator.
  const BookmarkLocator(this.bookmarkB64, {this.lastKnownPath = ''});

  /// Base64 bookmark data.
  final String bookmarkB64;

  /// Display/diagnostic hint only; never used to open the file.
  final String lastKnownPath;

  /// A copy with the given fields replaced.
  BookmarkLocator copyWith({String? bookmarkB64, String? lastKnownPath}) =>
      BookmarkLocator(bookmarkB64 ?? this.bookmarkB64, lastKnownPath: lastKnownPath ?? this.lastKnownPath);

  @override
  bool operator ==(Object other) =>
      other is BookmarkLocator && other.bookmarkB64 == bookmarkB64 && other.lastKnownPath == lastKnownPath;

  @override
  int get hashCode => Object.hash(bookmarkB64, lastKnownPath);
}
