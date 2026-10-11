// OWNER: ENG-03
//
// MobileMediaAccess: the core MediaAccessPort (plus the notification prompt) over
// `PlatformHostApi` (ARCH §9.1, §9.2, §12.4, §15, D-44).
//
// Locators:
// - AppRelativeLocator: the absolute path under its app root. Support and cache are derived from
//   the engine roots (`<support>/vwish/editor`, `<cache>/vwish/editor`); `documents` needs
//   [MobileMediaAccess.documentsRoot] (EditorBootstrap sets it from `StoreRoots.documents`,
//   INT-02). A relPath that escapes its root is refused.
// - FileLocator: the path as a `file://` URI.
// - ContentUriLocator: the URI as is (Android; access comes from the persisted grant).
// - BookmarkLocator: `resolveBookmark` → URI; a stale bookmark is refreshed natively and the
//   refreshed bytes travel in `ResolvedMedia.bookmark`.
//
// persist(picked): an iOS Files pick with a bookmark → BookmarkLocator; `content://` →
// `persistUriGrant` + ContentUriLocator; a `file://` path under an app root → AppRelativeLocator
// (never an absolute container path, ARCH §8.2); any other `file://` path (iOS in-place URL) →
// `createBookmark` + BookmarkLocator. release(ContentUriLocator) → `releaseUriGrant`; other
// locators hold nothing natively.
//
// Failures are MediaAccessFailure (the port contract): `mediaOffline` → notFound,
// `permissionDenied` → accessLost for bookmarks and content URIs (a revoked grant) and
// permissionDenied for paths, anything else → io (with the engine code, never a path).
//
// excludeFromBackup (D-44): only directories inside `<support>/vwish/editor`,
// `<cache>/vwish/editor` or `<support>/vwish/speech`, and never inside Documents. The check is
// lexical (`..`, `.` and duplicate slashes normalized) and, when the directory exists, repeated on
// symlink-resolved paths. A refusal never reaches native: it reports an OwnershipViolation to
// [MobileMediaAccess.onViolation] and throws MediaAccessFailure(outsideEditorRoots), the
// port's documented refusal that ManagedStore rethrows as a bug.

import 'dart:convert';
import 'dart:io' show Directory, Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/store.dart' show OwnershipViolation;
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import 'pigeon/conversions.dart';
import 'pigeon/engine_api.g.dart';
import 'pigeon/engine_channels.dart';

const String _editorSuffix = '/vwish/editor';

/// Media access over `PlatformHostApi` (ARCH §9.2, §12.4, D-44, ENG-03).
final class MobileMediaAccess implements MediaAccess {
  /// Creates the access service. [documentsRoot] is the absolute Documents directory (also
  /// settable later); [onViolation] is told about every refused `excludeFromBackup`.
  MobileMediaAccess(this._channels, {String? documentsRoot, this.onViolation, @visibleForTesting this.resolveSymlinks = true})
      : documentsRoot = documentsRoot == null ? null : normalizePosixPath(documentsRoot);

  final EngineChannels _channels;

  /// Absolute Documents directory (`StoreRoots.documents`); needed to resolve
  /// `AppRelativeLocator(documents, …)` and to refuse backup exclusion inside it.
  String? documentsRoot;

  /// Receives every refused `excludeFromBackup` (the app wires it to its logger).
  void Function(OwnershipViolation violation)? onViolation;

  /// Whether existing directories are also checked with symlinks resolved.
  final bool resolveSymlinks;

  String get _supportEditor => normalizePosixPath(_channels.config.supportRoot);
  String get _cacheEditor => normalizePosixPath(_channels.config.cacheRoot);

  /// `<support>/vwish/speech`, or null when the support root does not end with `/vwish/editor`.
  String? get speechRoot {
    final s = _supportEditor;
    return s.endsWith(_editorSuffix) ? '${s.substring(0, s.length - '/editor'.length)}/speech' : null;
  }

  /// Directories `excludeFromBackup` accepts (and their subdirectories).
  List<String> get backupExclusionRoots => [_supportEditor, _cacheEditor, if (speechRoot case final speech?) speech];

  String? _appRoot(AppRoot root) {
    String? strip(String editorRoot) =>
        editorRoot.endsWith(_editorSuffix) ? editorRoot.substring(0, editorRoot.length - _editorSuffix.length) : null;
    return switch (root) {
      AppRoot.support => strip(_supportEditor),
      AppRoot.cache => strip(_cacheEditor),
      AppRoot.documents => documentsRoot,
    };
  }

  // -------------------------------------------------------------------------------------------
  // Resolve, stat, hash
  // -------------------------------------------------------------------------------------------

  /// The absolute path of an app-relative locator.
  String pathOf(AppRelativeLocator locator) {
    final root = _appRoot(locator.root);
    if (root == null || root.isEmpty) {
      throw MediaAccessFailure(MediaAccessFailureKind.accessLost, '${locator.root.name} root not available');
    }
    final path = normalizePosixPath('$root/${locator.relPath}');
    if (!isWithinPosix(root, path)) {
      throw const MediaAccessFailure(MediaAccessFailureKind.permissionDenied, 'locator escapes its root');
    }
    return path;
  }

  /// URI and bookmark that grant access to [locator] now.
  Future<({String uri, Uint8List? bookmark})> _refOf(MediaLocator locator) async => switch (locator) {
        AppRelativeLocator() => (uri: _fileUri(pathOf(locator)), bookmark: null),
        FileLocator(:final path) => (uri: _fileUri(normalizePosixPath(path)), bookmark: null),
        ContentUriLocator(:final uri) => (uri: uri, bookmark: null),
        BookmarkLocator(:final bookmarkB64) => await _resolveBookmark(bookmarkB64),
      };

  Future<({String uri, Uint8List? bookmark})> _resolveBookmark(String b64) async {
    final Uint8List bytes;
    try {
      bytes = base64Decode(b64);
    } on FormatException {
      throw const MediaAccessFailure(MediaAccessFailureKind.accessLost, 'bookmark is not valid base64');
    }
    final resolved = await _native(() => _channels.platform.resolveBookmark(bytes), external: true);
    return (uri: resolved.uri, bookmark: resolved.refreshedBookmark ?? bytes);
  }

  @override
  Future<ResolvedMedia> resolve(MediaLocator locator) async {
    final ref = await _refOf(locator);
    final hash = await _native(() => _channels.platform.quickHash(MediaRefMsg(uri: ref.uri, bookmark: ref.bookmark)),
        external: _isExternal(locator));
    return ResolvedMedia(uri: ref.uri, fingerprint: hash, bookmark: ref.bookmark);
  }

  @override
  Future<MediaStat?> stat(MediaLocator locator) async {
    final ref = await _refOf(locator);
    final s =
        await _native(() => _channels.platform.stat(MediaRefMsg(uri: ref.uri, bookmark: ref.bookmark)), external: _isExternal(locator));
    return s == null ? null : mediaStatFromMsg(s);
  }

  @override
  Future<String> quickHash(MediaLocator locator) async {
    final ref = await _refOf(locator);
    return _native(() => _channels.platform.quickHash(MediaRefMsg(uri: ref.uri, bookmark: ref.bookmark)), external: _isExternal(locator));
  }

  // -------------------------------------------------------------------------------------------
  // Persist and release
  // -------------------------------------------------------------------------------------------

  @override
  Future<MediaLocator> persist(PickedMediaHandle handle) async {
    final uri = handle.uri;
    final bookmark = handle.bookmark;
    if (bookmark != null && bookmark.isNotEmpty) {
      return BookmarkLocator(base64Encode(bookmark), lastKnownPath: _filePathOf(uri) ?? '');
    }
    if (uri.startsWith('content://')) {
      await _native(() => _channels.platform.persistUriGrant(uri), external: true);
      return ContentUriLocator(uri);
    }
    final path = _filePathOf(uri);
    if (path == null) {
      throw const MediaAccessFailure(MediaAccessFailureKind.permissionDenied, 'not a file or content URI; not persistable');
    }
    final relative = _relativize(path);
    if (relative != null) return relative;
    final created = await _native(() => _channels.platform.createBookmark(_fileUri(path)), external: true);
    return BookmarkLocator(base64Encode(created), lastKnownPath: path);
  }

  AppRelativeLocator? _relativize(String path) {
    for (final root in AppRoot.values) {
      final base = _appRoot(root);
      if (base == null || base.isEmpty) continue;
      if (isWithinPosix(base, path) && path != base) {
        return AppRelativeLocator(root, path.substring(base.length + 1));
      }
    }
    return null;
  }

  @override
  Future<void> release(MediaLocator locator) async {
    if (locator case ContentUriLocator(:final uri)) {
      await _native(() => _channels.platform.releaseUriGrant(uri), external: true);
    }
  }

  @override
  Future<int> remainingGrantBudget() => _native(_channels.platform.remainingGrantBudget, external: true);

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      return await _channels.invoke(_channels.platform.requestNotificationPermission);
    } on EngineError catch (e) {
      // "true elsewhere": no prompt exists without the native engine.
      if (e.code == EngineErrorCode.notSupportedOnDevice) return true;
      rethrow;
    }
  }

  // -------------------------------------------------------------------------------------------
  // Backup exclusion (D-44)
  // -------------------------------------------------------------------------------------------

  @override
  Future<void> excludeFromBackup(String dirPath) async {
    final path = normalizePosixPath(dirPath);
    final reason = await _exclusionRefusal(dirPath, path);
    if (reason != null) {
      onViolation?.call(OwnershipViolation(dirPath, reason));
      throw MediaAccessFailure(MediaAccessFailureKind.outsideEditorRoots, 'excludeFromBackup refused: $reason');
    }
    await _native(() => _channels.platform.excludeFromBackup(path), external: false);
  }

  Future<String?> _exclusionRefusal(String raw, String path) async {
    if (!raw.startsWith('/')) return 'not an absolute path';
    String? check(String target, List<String> roots, String? documents) {
      if (documents != null && isWithinPosix(documents, target)) return 'inside Documents';
      if (!roots.any((r) => isWithinPosix(r, target))) return 'outside the editor roots';
      return null;
    }

    final roots = backupExclusionRoots;
    final lexical = check(path, roots, documentsRoot);
    if (lexical != null || !resolveSymlinks || Platform.isWindows) return lexical;
    final real = await _realPath(path);
    if (real == null) return null; // Does not exist (yet): the lexical check is all there is.
    final realRoots = [for (final r in roots) await _realPath(r) ?? r];
    final docs = documentsRoot;
    final realDocs = docs == null ? null : (await _realPath(docs) ?? docs);
    return check(real, realRoots, realDocs) == null ? null : 'resolves outside the editor roots';
  }

  static Future<String?> _realPath(String path) async {
    try {
      return normalizePosixPath(await Directory(path).resolveSymbolicLinks());
    } on Object {
      return null;
    }
  }

  // -------------------------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------------------------

  static bool _isExternal(MediaLocator l) => l is BookmarkLocator || l is ContentUriLocator;

  /// Runs a native call and maps engine failures to [MediaAccessFailure]. [external] says whether
  /// the access depends on a grant or bookmark (then `permissionDenied` means the access was lost).
  Future<T> _native<T>(Future<T> Function() call, {required bool external}) async {
    try {
      return await _channels.invoke(call);
    } on EngineFailure catch (f) {
      throw mediaAccessFailureOf(f, external: external);
    }
  }
}

/// The [MediaAccessFailure] for an engine failure of a media access call (see the file header).
MediaAccessFailure mediaAccessFailureOf(EngineFailure f, {required bool external}) => switch (f.code) {
      EngineErrorCode.mediaOffline => const MediaAccessFailure(MediaAccessFailureKind.notFound),
      EngineErrorCode.permissionDenied => external
          ? const MediaAccessFailure(MediaAccessFailureKind.accessLost)
          : const MediaAccessFailure(MediaAccessFailureKind.permissionDenied),
      _ => MediaAccessFailure(MediaAccessFailureKind.io, f.code.name),
    };

String _fileUri(String path) => Uri.file(path, windows: false).toString();

String? _filePathOf(String uri) {
  if (uri.startsWith('/')) return normalizePosixPath(uri);
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.scheme != 'file') return null;
  return normalizePosixPath(parsed.toFilePath(windows: false));
}

/// Lexically normalizes an absolute POSIX path: collapses duplicate slashes, `.` and `..` (never
/// above `/`) and drops a trailing slash. Relative input stays relative.
String normalizePosixPath(String path) {
  final absolute = path.startsWith('/');
  final out = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else if (!absolute) {
        out.add('..');
      }
      continue;
    }
    out.add(part);
  }
  final joined = out.join('/');
  return absolute ? '/$joined' : (joined.isEmpty ? '.' : joined);
}

/// Whether normalized [path] equals normalized [root] or lies below it.
bool isWithinPosix(String root, String path) => path == root || path.startsWith(root == '/' ? '/' : '$root/');
