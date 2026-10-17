// OWNER: CORE-27
//
// ManagedStore (ARCH §8.1, §9.1): content-addressed managed copies under
// `<support>/danaview/editor/media/<hh>/<quickHash>/<sanitized name>` (shared by every project, so
// importing the same content twice, in any project, stores it once) and the project-owned files of
// a bundle (`projects/<id>/assets/{luts,recordings,stills}/`).
//
// Writes only inside the editor roots, through `StoreFs`:
// - a copy goes to a unique `.part-<rand>` sibling first and is renamed into place, so a crash
//   never leaves a truncated file under its final name;
// - a move happens only through `OwnedFileDeleter.consume`, i.e. only for app-owned temporary files
//   `canConsume` accepts (`work/picks/`, `work/drops/`, engine outputs);
// - temporary files that turn out to be duplicates are removed through the same guard.
// The source of a copy is only ever read.
//
// V-D8 (does `File.copy` clone on APFS?). Dart's `File.copy` on Apple platforms calls
// `copyfile(3)` without `COPYFILE_CLONE`, and `LocalStoreFs.copyFile` streams bytes, so neither is
// guaranteed to clone. The design does not depend on it: iOS Photos picks are cloned natively
// (`clonefile`, ARCH §9.1) into `work/picks/`, and this store *moves* them (a rename, zero copy).
// Plain copies happen only for Android cache copies and drops, where APFS does not apply. Confirm
// the native clone path with IOS-15 (performance only).
//
// Backup exclusion: [ManagedStore.ensureLayout] creates `media/` and `derived/` and marks both
// excluded from device backups through `MediaAccessPort.excludeFromBackup` (iOS
// `NSURLIsExcludedFromBackupKey`; the port refuses paths outside the editor roots, D-44).

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../model/pool/media_access_port.dart';
import '../model/pool/media_locator.dart';
import 'owned_file_deleter.dart';
import 'store_fs.dart';
import 'store_roots.dart';

/// Where a managed or project-owned file landed.
@immutable
final class StoredFile {
  /// Creates the result.
  const StoredFile({required this.locator, required this.path, required this.reused, required this.moved});

  /// Persistable locator (`AppRelativeLocator(support, …)`).
  final AppRelativeLocator locator;

  /// Absolute path at this moment (never persisted).
  final String path;

  /// Whether an existing copy with the same content was reused (nothing was written).
  final bool reused;

  /// Whether the source was moved (consumed) rather than copied.
  final bool moved;

  @override
  String toString() => 'StoredFile(${locator.relPath}, reused: $reused, moved: $moved)';
}

/// Content-addressed managed copies and project-owned files (see the file header).
final class ManagedStore {
  /// Creates the store over [roots]. [deleter] must share [fs] in tests.
  ManagedStore(
    this.roots, {
    StoreFs fs = const LocalStoreFs(),
    OwnedFileDeleter? deleter,
    this.access,
    math.Random? random,
  })  : _fs = fs,
        deleter = deleter ?? OwnedFileDeleter(roots, fs: fs),
        _random = random ?? math.Random.secure();

  /// App roots.
  final StoreRoots roots;

  /// The deletion/consume guard.
  final OwnedFileDeleter deleter;

  /// Port used for backup exclusion (null: no exclusion, e.g. pure-path tests).
  final MediaAccessPort? access;

  final StoreFs _fs;
  final math.Random _random;
  Future<void>? _layout;

  /// Longest sanitized file name, in UTF-16 units (well under every platform's 255-byte limit).
  static const int maxNameLength = 96;

  /// Creates `media/` and `derived/` and excludes both from backups (once per store; retried on
  /// the next call after a failure).
  Future<void> ensureLayout() => _layout ??= _makeLayout().catchError((Object e, StackTrace s) {
        _layout = null;
        Error.throwWithStackTrace(e, s);
      });

  Future<void> _makeLayout() async {
    for (final dir in [roots.mediaDir, roots.derivedDir]) {
      await _fs.createDirectory(dir);
      final port = access;
      if (port == null) continue;
      try {
        await port.excludeFromBackup(dir);
      } on MediaAccessFailure catch (e) {
        if (e.kind == MediaAccessFailureKind.outsideEditorRoots) rethrow; // a bug: never swallow
        developer.log('excludeFromBackup failed: ${e.kind.name}', name: 'danaview.editor.store', level: 900);
      }
    }
  }

  // ------------------------------------------------------------------------------------------
  // Paths
  // ------------------------------------------------------------------------------------------

  /// `danaview/editor/media/<hh>/<quickHash>` relative to the support root.
  static String mediaDirRel(String quickHash) {
    _checkHash(quickHash);
    return p.posix.join('danaview', 'editor', 'media', quickHash.substring(0, 2), quickHash);
  }

  /// `danaview/editor/media/<hh>/<quickHash>/<sanitized name>` relative to the support root.
  static String mediaRelPath(String quickHash, String displayName) =>
      p.posix.join(mediaDirRel(quickHash), sanitizeFileName(displayName));

  /// `danaview/editor/projects/<projectId>/assets/<folder>/<name>` relative to the support root.
  static String projectAssetRelPath(String projectId, String folder, String name) {
    if (!_safeSegment(projectId) || !_safeSegment(folder) || !_safeSegment(name)) {
      throw ArgumentError('unsafe project asset path segment');
    }
    return p.posix.join('danaview', 'editor', 'projects', projectId, 'assets', folder, name);
  }

  /// The `.vlut` companion of an imported LUT's `.cube` locator (same folder and base name).
  static AppRelativeLocator vlutOf(AppRelativeLocator cube) =>
      AppRelativeLocator(cube.root, '${p.posix.withoutExtension(cube.relPath)}.vlut');

  /// A file name that is safe on iOS, Android and desktop file systems: no separators, control
  /// or reserved characters, no leading dot, at most [maxNameLength] units with the extension
  /// kept. Empty results become `media` (plus the extension).
  static String sanitizeFileName(String name) {
    var base = p.basename(name.replaceAll('\\', '/'));
    final b = StringBuffer();
    for (final r in base.runes) {
      final bad = r < 0x20 || r == 0x7F || '<>:"/\\|?*'.runes.contains(r) || (r >= 0xD800 && r <= 0xDFFF);
      b.writeCharCode(bad ? 0x5F : r);
    }
    base = b.toString().trim().replaceAll('.part-', '_part-'); // reserved for in-flight copies
    while (base.startsWith('.')) {
      base = base.substring(1);
    }
    var ext = p.extension(base);
    if (ext.length > 12 || !RegExp(r'^\.[A-Za-z0-9]+$').hasMatch(ext)) ext = '';
    var stem = ext.isEmpty ? base : base.substring(0, base.length - ext.length);
    stem = stem.trim();
    while (stem.endsWith('.')) {
      stem = stem.substring(0, stem.length - 1);
    }
    if (stem.isEmpty) stem = 'media';
    final room = maxNameLength - ext.length;
    if (stem.length > room) stem = _truncate(stem, room);
    return '$stem${ext.toLowerCase()}';
  }

  // ------------------------------------------------------------------------------------------
  // Managed copies
  // ------------------------------------------------------------------------------------------

  /// The existing managed copy of [quickHash], if any (any complete file in its folder).
  Future<StoredFile?> findManaged(String quickHash) async {
    final dirRel = mediaDirRel(quickHash);
    final dir = roots.resolve(AppRelativeLocator(AppRoot.support, dirRel));
    if ((await _fs.stat(dir)).type != StoreEntityType.directory) return null;
    final entries = await _fs.list(dir);
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      final name = p.basename(e.path);
      if (e.type != StoreEntityType.file || name.contains('.part-')) continue;
      return StoredFile(
        locator: AppRelativeLocator(AppRoot.support, p.posix.join(dirRel, name)),
        path: e.path,
        reused: true,
        moved: false,
      );
    }
    return null;
  }

  /// Stores [sourcePath] as the managed copy of [quickHash]. An existing copy is reused (and a
  /// [temporary] source is then removed through the guard). A [temporary] source is moved when
  /// `canConsume` allows it; anything else is copied (the source is only read).
  Future<StoredFile> adopt(String sourcePath, {required String quickHash, required String displayName, bool temporary = false}) async {
    await ensureLayout();
    final existing = await findManaged(quickHash);
    if (existing != null) {
      if (temporary) await discardTemporary(sourcePath);
      return existing;
    }
    final rel = mediaRelPath(quickHash, displayName);
    return _place(sourcePath, rel, temporary: temporary);
  }

  // ------------------------------------------------------------------------------------------
  // Project-owned files
  // ------------------------------------------------------------------------------------------

  /// Moves (when [temporary] and allowed) or copies [sourcePath] to the project-owned
  /// [relPath] (from [projectAssetRelPath]). A file already at [relPath] is kept as is.
  Future<StoredFile> storeProjectFile(String sourcePath, String relPath, {bool temporary = false}) async {
    final dest = roots.resolve(AppRelativeLocator(AppRoot.support, relPath));
    if (p.equals(p.normalize(sourcePath), p.normalize(dest))) {
      return StoredFile(locator: AppRelativeLocator(AppRoot.support, relPath), path: dest, reused: true, moved: false);
    }
    return _place(sourcePath, relPath, temporary: temporary);
  }

  /// Writes [bytes] to the project-owned [relPath] (tmp + rename; replaces an existing file).
  Future<StoredFile> writeProjectBytes(String relPath, Uint8List bytes) async {
    final dest = _checkedDest(relPath);
    await _fs.createDirectory(p.dirname(dest));
    final part = _partOf(dest);
    try {
      await _fs.writeBytesSynced(part, bytes);
      await _fs.rename(part, dest);
    } on Object {
      await _cleanup(part);
      rethrow;
    }
    return StoredFile(locator: AppRelativeLocator(AppRoot.support, relPath), path: dest, reused: false, moved: false);
  }

  /// Removes a temporary source that is no longer needed, if the guard says it is app-owned.
  /// Anything else (an original) is left alone.
  Future<void> discardTemporary(String path) async {
    if (await deleter.canConsume(path)) await deleter.delete(path);
  }

  // ------------------------------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------------------------------

  Future<StoredFile> _place(String sourcePath, String relPath, {required bool temporary}) async {
    final dest = _checkedDest(relPath);
    final locator = AppRelativeLocator(AppRoot.support, relPath);
    if (temporary && await deleter.canConsume(sourcePath)) {
      if ((await _fs.stat(dest)).exists) {
        await discardTemporary(sourcePath);
        return StoredFile(locator: locator, path: dest, reused: true, moved: false);
      }
      await deleter.consume(sourcePath, destination: dest);
      return StoredFile(locator: locator, path: dest, reused: false, moved: true);
    }
    await _fs.createDirectory(p.dirname(dest));
    final part = _partOf(dest);
    try {
      await _fs.copyFile(sourcePath, part);
      await _fs.rename(part, dest);
    } on Object {
      await _cleanup(part);
      rethrow;
    }
    return StoredFile(locator: locator, path: dest, reused: false, moved: false);
  }

  String _checkedDest(String relPath) {
    final dest = p.normalize(roots.resolve(AppRelativeLocator(AppRoot.support, relPath)));
    if (!p.isWithin(roots.editorSupport, dest)) throw ArgumentError('destination outside the editor support root');
    return dest;
  }

  String _partOf(String dest) => '$dest.part-${_random.nextInt(1 << 32).toRadixString(36)}';

  Future<void> _cleanup(String part) async {
    try {
      await deleter.delete(part);
    } on Object catch (e) {
      if (e is SimulatedCrash) rethrow;
      // Best effort; GC (CORE-28) sweeps leftovers.
    }
  }

  static void _checkHash(String quickHash) {
    if (quickHash.length < 2 || !RegExp(r'^[0-9a-zA-Z_-]+$').hasMatch(quickHash)) {
      throw ArgumentError.value(quickHash, 'quickHash', 'not a content hash');
    }
  }

  static bool _safeSegment(String s) =>
      s.isNotEmpty && s != '.' && s != '..' && !s.contains('/') && !s.contains('\\') && !s.contains('\u0000');

  static String _truncate(String s, int maxUnits) {
    final b = StringBuffer();
    for (final c in s.characters) {
      if (b.length + c.length > maxUnits) break;
      b.write(c);
    }
    return b.toString();
  }
}
