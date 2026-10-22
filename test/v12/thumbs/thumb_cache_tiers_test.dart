// OWNER: HOM-04
//
// The tiers of the Home thumbnail cache (BUILD_PLAN HOM-04; ARCH v1.2 V2-28, V2-104): size
// classes and keys (item id + modification time + size class, hashed so no file name carries an
// id), the byte-accounted 64 MB memory LRU, and the dart:io disk tier — atomic commit through a
// part file, invalidation of older versions by modification time, survival across a restart,
// clean-up of a crashed run's part files, the size trim and the backup flag on the root.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:danaview_features/src/library/thumbs/thumb_disk_cache.dart';
import 'package:danaview_features/src/library/thumbs/thumb_key.dart';
import 'package:danaview_features/src/library/thumbs/thumb_memory_cache.dart';
import 'package:danaview_features/src/library/thumbs/thumbnail_service.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'thumb_fakes.dart';

void main() {
  group('keys', () {
    test('size classes by box and pixel ratio', () {
      expect(ThumbSizeClass.forBox(64, 3), ThumbSizeClass.s);
      expect(ThumbSizeClass.forBox(65, 3), ThumbSizeClass.m);
      expect(ThumbSizeClass.forBox(120, 3), ThumbSizeClass.m);
      expect(ThumbSizeClass.forBox(129, 3), ThumbSizeClass.l);
      expect(ThumbSizeClass.forBox(380, 1), ThumbSizeClass.m);
      expect(ThumbSizeClass.forBox(1000, 2), ThumbSizeClass.l);
      expect(ThumbSizeClass.s.mode, NativeThumbnailMode.fill);
      expect(ThumbSizeClass.m.mode, NativeThumbnailMode.fill);
      expect(ThumbSizeClass.l.mode, NativeThumbnailMode.fit);
      expect(ThumbSizeClass.m.maxDecodedBytes, 384 * 384 * 4);
    });

    test('FNV-1a 64 of the UTF-16LE code units', () {
      expect(fnv1a64Hex(''), 'cbf29ce484222325');
      expect(fnv1a64Hex('a'), '089be207b544f1e4');
      expect(fnv1a64Hex('fe_000001'), 'd5ffbb164b2314e0');
      expect(fnv1a64Hex('ph:ABC/L0/001'), 'a3e169d76a6c1b82');
      expect(fnv1a64Hex('é漢'), 'a94596efda8538df');
    });

    test('the key is id + modification time + size class and its path carries no id', () {
      const a = ThumbKey(itemId: 'ph:ABC/L0/001', modifiedMs: 1700000000000, sizeClass: ThumbSizeClass.m);
      expect(a.relativePath, 'm/a3/a3e169d76a6c1b82/1700000000000.thumb');
      expect(a.relativeItemDir, 'm/a3/a3e169d76a6c1b82');
      expect(a.relativePath, isNot(contains('ABC')));
      expect(a, const ThumbKey(itemId: 'ph:ABC/L0/001', modifiedMs: 1700000000000, sizeClass: ThumbSizeClass.m));
      expect(a == const ThumbKey(itemId: 'ph:ABC/L0/001', modifiedMs: 1700000000001, sizeClass: ThumbSizeClass.m), isFalse);
      expect(a == const ThumbKey(itemId: 'ph:ABC/L0/001', modifiedMs: 1700000000000, sizeClass: ThumbSizeClass.s), isFalse);
      final r = req(1, source: '/private/IMG_secret.jpg');
      expect(r.toString(), isNot(contains('secret')));
      expect(r.key.toString(), isNot(contains('fe_')));
      expect(r.at(ThumbSizeClass.l).key.sizeClass, ThumbSizeClass.l);
    });

    test('platform formats (V2-28): WebP on Android, JPEG on iOS (HEIC unverified) and elsewhere', () {
      expect(thumbnailFormatFor(TargetPlatform.android), NativeThumbnailFormat.webp);
      expect(thumbnailFormatFor(TargetPlatform.iOS), NativeThumbnailFormat.jpeg);
      expect(thumbnailFormatFor(TargetPlatform.macOS), NativeThumbnailFormat.jpeg);
      expect(thumbnailFormatFor(TargetPlatform.windows), NativeThumbnailFormat.jpeg);
      expect(thumbnailFormatFor(TargetPlatform.linux), NativeThumbnailFormat.jpeg);
    });
  });

  group('memory LRU', () {
    final t = PixelTracker();
    ThumbKey k(int i) => req(i).key;

    test('is byte-accounted, evicts least recently used first and disposes', () {
      final m = ThumbMemoryCache(maxBytes: 3 * 100 * 100 * 4);
      final bs = [for (var i = 0; i < 4; i++) FakeBitmap.alloc(t, 100, 100, '$i')];
      for (var i = 0; i < 3; i++) {
        expect(m.put(k(i), bs[i]), isTrue);
      }
      expect(m.bytes, 120000);
      expect(m.get(k(0)), same(bs[0]), reason: 'touch 0, so 1 is the oldest');
      m.put(k(3), bs[3]);
      expect(m.contains(k(1)), isFalse);
      expect(bs[1].disposed, isTrue);
      expect([m.contains(k(0)), m.contains(k(2)), m.contains(k(3))], [true, true, true]);
      expect(m.bytes, 120000);
      expect(m.evictions, 1);
      expect(m.peakBytes, 120000);
    });

    test('a bitmap above the whole budget is not stored; replace disposes the old one', () {
      final m = ThumbMemoryCache(maxBytes: 1000);
      final big = FakeBitmap.alloc(t, 100, 100, 'big');
      expect(m.put(k(0), big), isFalse);
      expect(big.disposed, isTrue);
      final a = FakeBitmap.alloc(t, 10, 10, 'a'), b = FakeBitmap.alloc(t, 10, 10, 'b');
      m.put(k(1), a);
      m.put(k(1), b);
      expect(a.disposed, isTrue);
      expect(m.bytes, 400);
      expect(m.length, 1);
    });

    test('removeItem drops every class and version of an item; clear disposes all', () {
      final m = ThumbMemoryCache();
      final bs = [for (var i = 0; i < 3; i++) FakeBitmap.alloc(t, 10, 10, '$i')];
      m.put(req(1, c: ThumbSizeClass.s).key, bs[0]);
      m.put(req(1, c: ThumbSizeClass.m).key, bs[1]);
      m.put(req(2).key, bs[2]);
      m.removeItem('fe_000001');
      expect(m.length, 1);
      expect([bs[0].disposed, bs[1].disposed, bs[2].disposed], [true, true, false]);
      m.clear();
      expect(m.bytes, 0);
      expect(bs[2].disposed, isTrue);
    });

    test('default budget is 64 MB (V2-104)', () {
      expect(ThumbMemoryCache().maxBytes, 64 * 1024 * 1024);
    });
  });

  group('disk tier (dart:io)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('hom04_disk_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('root is <cache>/danaview/library/thumbs and the backup flag is applied to it', () async {
      final root = thumbsRootIn(tmp.path);
      expect(root, [tmp.path, 'danaview', 'library', 'thumbs'].join(Platform.pathSeparator));
      expect(thumbsRootIn('${tmp.path}${Platform.pathSeparator}'), root);
      final flagged = <String>[];
      await IoThumbDiskCache(root).open(excludeFromBackup: (p) async => flagged.add(p));
      expect(flagged, [root]);
      expect(Directory(root).existsSync(), isTrue);
      // A failing flag does not stop the cache.
      await IoThumbDiskCache(root).open(excludeFromBackup: (_) async => throw const LibraryNativeException(LibraryNativeErrorCode.ioError, 'x'));
    });

    test('commit is atomic, replaces older versions and survives a restart', () async {
      final root = thumbsRootIn(tmp.path);
      final d = IoThumbDiskCache(root);
      await d.open();
      final v1 = req(1, modified: DateTime.utc(2026, 1, 1)).key;
      expect(await d.lookup(v1), isNull);
      final p1 = await d.partPathFor(v1);
      File(p1).writeAsBytesSync([1, 2, 3]);
      expect(await d.lookup(v1), isNull, reason: 'a part file is not a thumbnail');
      final f1 = await d.commit(v1, p1);
      expect(await d.lookup(v1), f1);
      expect(File(p1).existsSync(), isFalse);
      // Another size class of the same item is independent.
      final s1 = req(1, c: ThumbSizeClass.s).key;
      await d.commit(s1, await _write(d, s1));
      // A new modification time invalidates the old file at that class.
      final v2 = req(1, modified: DateTime.utc(2026, 2, 1)).key;
      final f2 = await d.commit(v2, await _write(d, v2));
      expect(File(f1).existsSync(), isFalse);
      expect(await d.lookup(v1), isNull);
      expect(await d.lookup(v2), f2);
      expect(await d.lookup(s1), isNotNull);
      // Restart: a new instance over the same root finds it.
      final again = IoThumbDiskCache(root);
      await again.open();
      expect(await again.lookup(v2), f2);
      expect((await again.usage()).files, 2);
    });

    test('open removes part files a crashed run left; discard and evict never throw', () async {
      final root = thumbsRootIn(tmp.path);
      final d = IoThumbDiskCache(root);
      await d.open();
      final k = req(5).key;
      final part = await _write(d, k);
      await IoThumbDiskCache(root).open();
      expect(File(part).existsSync(), isFalse);
      await d.discard(part);
      await d.evict(k);
    });

    test('trim keeps the newest files under the budget; clear empties', () async {
      final root = thumbsRootIn(tmp.path);
      final d = IoThumbDiskCache(root);
      await d.open();
      final paths = <String>[];
      for (var i = 0; i < 5; i++) {
        final k = req(i).key;
        final f = await d.commit(k, await _write(d, k, bytes: 1000));
        File(f).setLastModifiedSync(DateTime.utc(2026, 1, 1 + i));
        paths.add(f);
      }
      expect((await d.usage()).bytes, 5000);
      await d.trim(2500);
      expect([for (final p in paths) File(p).existsSync()], [false, false, false, true, true]);
      await d.clear();
      expect((await d.usage()).files, 0);
      expect(Directory(root).existsSync(), isTrue);
    });
  });
}

Future<String> _write(IoThumbDiskCache d, ThumbKey k, {int bytes = 3}) async {
  final p = await d.partPathFor(k);
  File(p).writeAsBytesSync(List<int>.filled(bytes, 7));
  return p;
}
