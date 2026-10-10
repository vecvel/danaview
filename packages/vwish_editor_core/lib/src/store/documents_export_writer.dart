// OWNER: CORE-24
//
// The only code that writes into `Documents` (D-44, ARCH §9.6, §14.1 step 6 "Keep a copy in
// Vwish"). `Documents` is the user's "On This Device" library and is treated as originals, so the
// writer is deliberately narrow:
// - the target directory is `Documents/Exports/` only (`StoreRoots.documentsExportsDir`), created
//   when missing; it must be a real directory, never a symbolic link, and must resolve to the
//   same place as `<documents>/Exports`;
// - the file is created exclusively (`O_CREAT | O_EXCL`: `StoreFs.copyExclusive`), so an existing
//   file is never opened for writing, let alone overwritten or truncated; when `<name>.mp4` exists
//   the copy becomes `<name> (2).mp4`, `<name> (3).mp4`, … (the scheme of vwish_data's
//   `LibraryStorage._uniqueTarget`);
// - a symbolic link found at a candidate name aborts the operation (nothing is written through it);
// - the source must be a regular file (not a link) inside `editorSupport` or `editorCache` (an
//   export under `<cache>/vwish/editor/work/`).
//
// The writer never deletes anything; a failed copy removes only the partial file it created itself
// (inside `StoreFs.copyExclusive`).

import 'dart:convert';

import 'package:path/path.dart' as p;

import 'owned_file_deleter.dart';
import 'store_fs.dart';
import 'store_roots.dart';

/// Copies a finished export into `Documents/Exports/` without ever overwriting (D-44).
final class DocumentsExportWriter {
  /// Creates a writer for [roots].
  DocumentsExportWriter(this.roots, {StoreFs fs = const LocalStoreFs()}) : _fs = fs;

  /// App roots.
  final StoreRoots roots;

  final StoreFs _fs;

  /// The longest accepted file name in UTF-8 bytes (leaves room for the ` (n)` suffix under the
  /// common 255-byte limit).
  static const int maxFileNameBytes = 240;

  /// How many ` (n)` candidates are tried before giving up.
  static const int maxAttempts = 10000;

  /// Copies [sourcePath] to a new, uniquely named file `Documents/Exports/<fileName>` and returns
  /// its absolute path. Throws [ArgumentError] for a [fileName] that is not a plain file name,
  /// [OwnershipViolation] when the source is not an editor-root regular file or the target
  /// directory is unsafe, and [StoreFailure] on I/O errors (disk full, permission, …).
  Future<String> keepCopy(String sourcePath, {required String fileName}) async {
    _checkFileName(fileName);
    await _checkSource(sourcePath);
    final exports = await _prepareExportsDir();

    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    for (var n = 1; n <= maxAttempts; n++) {
      final candidate = p.join(exports, n == 1 ? fileName : '$base ($n)$ext');
      if ((await _fs.stat(candidate)).type == StoreEntityType.link) {
        throw OwnershipViolation(candidate, 'symbolic link in Documents/Exports');
      }
      if (await _fs.copyExclusive(sourcePath, candidate)) return candidate;
    }
    throw const StoreFailure(StoreFailureKind.io, 'no free file name');
  }

  void _checkFileName(String name) {
    final bad = name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\') ||
        name.runes.any((r) => r < 0x20 || r == 0x7F) ||
        utf8.encode(name).length > maxFileNameBytes;
    if (bad) throw ArgumentError.value(name, 'fileName', 'must be a plain file name');
  }

  Future<void> _checkSource(String path) async {
    if (!p.isAbsolute(path)) throw OwnershipViolation(path, 'export source is not absolute');
    final stat = await _fs.stat(path);
    if (stat.type != StoreEntityType.file) throw OwnershipViolation(path, 'export source is not a regular file');
    final entry = p.join(await _fs.canonicalize(p.dirname(path)), p.basename(path));
    final support = await _fs.canonicalize(roots.editorSupport);
    final cache = await _fs.canonicalize(roots.editorCache);
    if (!p.isWithin(support, entry) && !p.isWithin(cache, entry)) {
      throw OwnershipViolation(path, 'export source is outside the editor roots');
    }
  }

  /// The checked `Documents/Exports` directory (created when missing).
  Future<String> _prepareExportsDir() async {
    final exports = roots.documentsExportsDir;
    var stat = await _fs.stat(exports);
    if (stat.type == StoreEntityType.notFound) {
      await _fs.createDirectory(exports);
      stat = await _fs.stat(exports);
    }
    if (stat.type == StoreEntityType.link) throw OwnershipViolation(exports, 'Documents/Exports is a symbolic link');
    if (stat.type != StoreEntityType.directory) throw OwnershipViolation(exports, 'Documents/Exports is not a directory');
    final expected = p.join(await _fs.canonicalize(roots.documents), 'Exports');
    if (await _fs.canonicalize(exports) != expected) {
      throw OwnershipViolation(exports, 'Documents/Exports resolves elsewhere');
    }
    return exports;
  }
}
