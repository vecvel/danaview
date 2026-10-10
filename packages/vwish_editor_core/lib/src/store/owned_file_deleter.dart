// OWNER: CORE-24
//
// The deletion guard (ARCH §9.6, D-44): `OwnedFileDeleter` is the **only** delete path of the
// editor in Dart. A delete is performed only when, after canonicalization (`..` removed, every
// symbolic link resolved), the target lies strictly inside `editorSupport` or `editorCache`
// (themselves canonicalized) and outside `documents`; an asset whose ownership is `external` is
// refused outright. A refusal is a bug in the caller: it is reported to [OwnedFileDeleter.onViolation],
// asserted in debug builds (`assertOnViolation`), and surfaced as [OwnershipViolation]; nothing is
// ever deleted.
//
// Symbolic links: a link is removed as a link (never its target) and only when both the link's own
// location and the place it points to are inside the allowed roots, so a link planted inside the
// editor tree can neither delete nor be used to reach a file outside it. Case variants and
// Unicode-normalization variants of a root are compared as plain strings after canonicalization:
// a spelling that does not match the configured root exactly is refused, never guessed at (a false
// refusal is safe; a false accept is not).
//
// This guard checks and then acts (it cannot hold a directory lock); it defends against bugs and
// stray paths in app code, not against another process rewriting the app's own container.
//
// `canConsume(tempPath)` answers the sibling question for *moving* app-owned temporary files into
// the editor roots (ARCH §9.1: picks and drops cloned by native code): only regular files under
// `<cache>/vwish/editor/work/picks/` or `work/drops/`, and the engine's own outputs (`work/export-*`
// by default), may be consumed.

import 'dart:developer' as developer;

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../model/pool/media_asset.dart';
import '../model/pool/media_locator.dart';
import 'store_fs.dart';
import 'store_roots.dart';

/// A delete (or consume) that the guard refused: a bug in the caller.
@immutable
final class OwnershipViolation implements Exception {
  /// Creates a violation.
  const OwnershipViolation(this.path, this.reason);

  /// The offending path as given (may be an asset's resolved path).
  final String path;

  /// Why it was refused (a stable short phrase).
  final String reason;

  @override
  String toString() => 'OwnershipViolation($reason: $path)';
}

/// The only delete path of the editor (see the file header).
final class OwnedFileDeleter {
  /// Creates the guard for [roots].
  ///
  /// [engineOutputPrefixes] names the entries directly under `<cache>/vwish/editor/work/` that
  /// native engines own and that [canConsume] therefore accepts (default `export-`).
  /// [onViolation] is told about every refusal (the app wires it to its logger). With
  /// [assertOnViolation] (default true) a refusal also trips an `assert` in debug builds, before
  /// [OwnershipViolation] is thrown; release builds only throw.
  OwnedFileDeleter(
    this.roots, {
    StoreFs fs = const LocalStoreFs(),
    this.engineOutputPrefixes = const ['export-'],
    this.onViolation,
    this.assertOnViolation = true,
  }) : _fs = fs;

  /// App roots.
  final StoreRoots roots;

  final StoreFs _fs;

  /// Name prefixes of engine outputs directly under `work/`.
  final List<String> engineOutputPrefixes;

  /// Called with every refused request.
  final void Function(OwnershipViolation violation)? onViolation;

  /// Whether a refusal asserts in debug builds.
  final bool assertOnViolation;

  /// Deletes [path] (a file, a link, or with [recursive] a directory tree) if the guard allows it.
  /// A path inside the roots that does not exist is a no-op; one outside them is refused whether or
  /// not it exists. Throws [OwnershipViolation] when refused and
  /// [StoreFailure] when the filesystem fails.
  Future<void> delete(String path, {bool recursive = false}) async {
    final target = await _authorize(path);
    if (target == null) return;
    await _fs.delete(target, recursive: recursive);
  }

  /// Deletes the file behind [asset]: refused for `external` ownership and for locators that do
  /// not name a file (bookmarks, content URIs); the file must still pass the same root checks as
  /// [delete].
  Future<void> deleteAsset(MediaAsset asset) async {
    if (asset.ownership == MediaOwnership.external) {
      throw _refuse(asset.displayName, 'asset is external');
    }
    final path = switch (asset.locator) {
      AppRelativeLocator(:final root, :final relPath) => roots.resolve(AppRelativeLocator(root, relPath)),
      FileLocator(:final path) => path,
      _ => null,
    };
    if (path == null) throw _refuse(asset.displayName, 'asset has no deletable file locator');
    await delete(path);
  }

  /// Whether [tempPath] is an app-owned temporary file that may be moved into the editor roots.
  Future<bool> canConsume(String tempPath) async {
    try {
      if (!p.isAbsolute(tempPath) || tempPath.contains('\u0000')) return false;
      final stat = await _fs.stat(tempPath);
      if (stat.type != StoreEntityType.file) return false; // not a link, not a directory
      final entry = p.join(await _fs.canonicalize(p.dirname(tempPath)), p.basename(tempPath));
      final cache = await _fs.canonicalize(roots.editorCache);
      final work = await _fs.canonicalize(roots.workDir);
      if (!p.isWithin(cache, work) || !p.isWithin(work, entry)) return false;
      final first = p.split(p.relative(entry, from: work)).first;
      final sub = p.split(p.relative(entry, from: work)).length >= 2;
      if (sub && (first == 'picks' || first == 'drops')) return true;
      return engineOutputPrefixes.any(first.startsWith);
    } on StoreFailure {
      return false;
    }
  }

  /// Moves the temporary file [tempPath] to [destination] inside the editor roots (a `rename`; a
  /// move across volumes falls back to copy and guarded delete). Refuses unless [canConsume]
  /// accepts [tempPath], the destination lies strictly inside `editorSupport` or `editorCache`
  /// outside `documents`, and nothing exists at the destination.
  Future<void> consume(String tempPath, {required String destination}) async {
    if (!await canConsume(tempPath)) throw _refuse(tempPath, 'not an app-owned temporary file');
    final dest = await _allowedTarget(destination);
    if (dest == null) throw _refuse(destination, 'destination outside the editor roots');
    if ((await _fs.stat(dest)).exists) throw _refuse(destination, 'destination exists');
    await _fs.createDirectory(p.dirname(dest));
    try {
      await _fs.rename(tempPath, dest);
    } on StoreFailure catch (e) {
      if (e.kind == StoreFailureKind.notFound) rethrow;
      await _fs.copyFile(tempPath, dest);
      await delete(tempPath);
    }
  }

  /// The canonical path to delete, or null when it does not exist; throws on refusal.
  Future<String?> _authorize(String path) async {
    final stat = await _checkShape(path);
    final entry = await _entryPath(path);
    final verdict = await _verdict(entry);
    if (verdict != null) throw _refuse(path, verdict);
    if (!stat.exists) return null; // inside the roots but already gone
    if (stat.type == StoreEntityType.link) {
      // Remove the link itself, but only when what it points to is also inside the roots.
      final resolved = await _fs.canonicalize(path);
      final linkVerdict = await _verdict(resolved);
      if (linkVerdict != null) throw _refuse(path, 'link target: $linkVerdict');
    }
    return entry;
  }

  Future<String?> _allowedTarget(String path) async {
    await _checkShape(path);
    final entry = await _entryPath(path);
    return await _verdict(entry) == null ? entry : null;
  }

  Future<StoreStat> _checkShape(String path) async {
    if (path.isEmpty || !p.isAbsolute(path)) throw _refuse(path, 'path is not absolute');
    if (path.contains('\u0000')) throw _refuse(path, 'path contains NUL');
    return _fs.stat(path);
  }

  /// The parent resolved through symbolic links plus the final component (a final link is kept).
  Future<String> _entryPath(String path) async {
    final normalized = p.normalize(path);
    return p.join(await _fs.canonicalize(p.dirname(normalized)), p.basename(normalized));
  }

  /// Null when [canonical] may be deleted, else the reason.
  Future<String?> _verdict(String canonical) async {
    final support = await _fs.canonicalize(roots.editorSupport);
    final cache = await _fs.canonicalize(roots.editorCache);
    final documents = await _fs.canonicalize(roots.documents);
    final inside = p.isWithin(support, canonical) || p.isWithin(cache, canonical);
    if (!inside) return 'outside the editor roots';
    if (canonical == support || canonical == cache) return 'an editor root itself';
    if (canonical == documents || p.isWithin(documents, canonical)) return 'inside Documents';
    return null;
  }

  OwnershipViolation _refuse(String path, String reason) {
    final violation = OwnershipViolation(path, reason);
    developer.log('refused: $reason', name: 'vwish.editor.store', level: 1000);
    onViolation?.call(violation);
    assert(!assertOnViolation, 'OwnershipViolation: $reason');
    return violation;
  }
}
