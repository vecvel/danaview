// OWNER: CORE-27
//
// DartIoMediaAccess (ARCH §9.2): the `MediaAccessPort` for plain file paths, used by tests and by
// the desktop build later. It only ever *reads* media files (stat, the 64 KiB head and tail for
// `quickHash`); it never writes, moves or deletes them. Content URIs and bookmarks need the engine
// (ENG-03 / IOS-15 / AND-14) and are reported as `accessLost`.
//
// `excludeFromBackup` refuses any directory outside the editor and speech roots (D-44). Plain
// file systems have no backup attribute, so an accepted call only records the directory in
// [DartIoMediaAccess.excludedDirs].

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../model/pool/fingerprint.dart';
import '../model/pool/media_access_port.dart';
import '../model/pool/media_locator.dart';
import '../model/pool/picked_media.dart';
import '../model/pool/resolved_media.dart';
import 'import_policy.dart';
import 'store_roots.dart';

/// `MediaAccessPort` over plain paths (see the file header).
final class DartIoMediaAccess implements MediaAccessPort {
  /// Creates the port for [roots].
  DartIoMediaAccess(this.roots, {this.grantBudget = 1 << 20});

  /// App roots (to resolve app-relative locators and guard backup exclusion).
  final StoreRoots roots;

  /// What [remainingGrantBudget] reports (plain paths need no grants).
  final int grantBudget;

  /// Directories accepted by [excludeFromBackup], in call order.
  final List<String> excludedDirs = [];

  /// The absolute path behind [locator]; throws [MediaAccessFailure] for locators that need the
  /// platform (content URIs, bookmarks).
  String pathOf(MediaLocator locator) => switch (locator) {
        AppRelativeLocator() => p.normalize(roots.resolve(locator)),
        FileLocator(:final path) => p.normalize(path),
        ContentUriLocator() => throw const MediaAccessFailure(MediaAccessFailureKind.accessLost, 'content URI needs the engine'),
        BookmarkLocator() => throw const MediaAccessFailure(MediaAccessFailureKind.accessLost, 'bookmark needs the engine'),
      };

  @override
  Future<ResolvedMedia> resolve(MediaLocator locator) async {
    final path = pathOf(locator);
    final hash = await quickHash(locator);
    return ResolvedMedia(uri: Uri.file(path).toString(), fingerprint: hash);
  }

  @override
  Future<MediaStat?> stat(MediaLocator locator) async {
    final path = pathOf(locator);
    final s = await FileStat.stat(path);
    if (s.type == FileSystemEntityType.notFound) return null;
    if (s.type != FileSystemEntityType.file) return null;
    return MediaStat(sizeBytes: s.size, modifiedMs: s.modified.millisecondsSinceEpoch);
  }

  @override
  Future<String> quickHash(MediaLocator locator) async {
    final path = pathOf(locator);
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      final size = await raf.length();
      final head = await raf.read(size < quickHashChunkBytes ? size : quickHashChunkBytes);
      var tail = Uint8List(0);
      if (size > quickHashChunkBytes) {
        await raf.setPosition(size - quickHashChunkBytes);
        tail = await raf.read(quickHashChunkBytes);
      }
      return computeQuickHash(head, tail, size);
    } on FileSystemException catch (e) {
      throw _failureOf(e);
    } finally {
      await raf?.close();
    }
  }

  @override
  Future<MediaLocator> persist(PickedMediaHandle handle) async {
    final path = ImportPolicy.pathOf(handle.uri);
    if (path == null) {
      throw const MediaAccessFailure(MediaAccessFailureKind.permissionDenied, 'not a plain path; not persistable');
    }
    return roots.relativize(path) ?? FileLocator(path);
  }

  @override
  Future<void> release(MediaLocator locator) async {}

  @override
  Future<void> excludeFromBackup(String dirPath) async {
    final n = p.normalize(dirPath);
    final allowed = [roots.editorSupport, roots.editorCache, roots.speechSupport].map(p.normalize);
    if (!p.isAbsolute(n) || !allowed.any((r) => n == r || p.isWithin(r, n))) {
      throw const MediaAccessFailure(MediaAccessFailureKind.outsideEditorRoots);
    }
    excludedDirs.add(n);
  }

  @override
  Future<int> remainingGrantBudget() async => grantBudget;

  static MediaAccessFailure _failureOf(FileSystemException e) {
    final code = e.osError?.errorCode;
    // ENOENT / ENOTDIR → notFound; EACCES / EPERM → permissionDenied.
    return switch (code) {
      2 || 20 => const MediaAccessFailure(MediaAccessFailureKind.notFound),
      1 || 13 => const MediaAccessFailure(MediaAccessFailureKind.permissionDenied),
      _ => MediaAccessFailure(MediaAccessFailureKind.io, code == null ? 'io' : 'errno $code'),
    };
  }
}
