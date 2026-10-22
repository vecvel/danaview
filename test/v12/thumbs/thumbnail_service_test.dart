// OWNER: HOM-04
//
// ThumbnailService (BUILD_PLAN HOM-04; ARCH v1.2 V2-28, V2-104) over fake tiers: memory, disk and
// platform hits; coalescing of requests for one key; cancellation of queued jobs (they never
// reach the platform) and of running ones (the native request is cancelled); newest-first
// scheduling; failures remembered for the session; documents without a thumbnail; a damaged cache
// file regenerated; the prefetch window for ph: assets only; and the acceptance test: memory never
// exceeds 64 MB under a 10,000-cell fling with a fake decoder. A second group runs the service
// over the real dart:io disk tier: the cache survives a restart (no platform call) and is
// invalidated by a new modification time.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:danaview_features/src/library/thumbs/thumb_disk_cache.dart';
import 'package:danaview_features/src/library/thumbs/thumb_key.dart';
import 'package:danaview_features/src/library/thumbs/thumb_memory_cache.dart';
import 'package:danaview_features/src/library/thumbs/thumbnail_service.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'thumb_fakes.dart';

Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late PixelTracker tracker;
  late MemoryThumbDisk disk;
  late FakeGenerator gen;
  late FakeDecoder decoder;
  late ThumbnailService svc;

  ThumbnailService make({int max = 4, int? memoryBytes}) => ThumbnailService(
        disk: disk,
        generator: gen,
        decoder: decoder,
        maxConcurrent: max,
        format: NativeThumbnailFormat.jpeg,
        memory: memoryBytes == null ? null : ThumbMemoryCache(maxBytes: memoryBytes),
      );

  setUp(() {
    tracker = PixelTracker();
    disk = MemoryThumbDisk();
    gen = FakeGenerator(disk: disk);
    decoder = FakeDecoder(tracker, disk: disk);
    svc = make();
  });

  test('platform, then memory, then disk', () async {
    final r = req(1);
    final first = await svc.load(r).result;
    expect(first, isNotNull);
    expect(gen.started, ['/lib/item1.jpg']);
    expect(svc.stats.generated, 1);
    expect(disk.files.keys.single, disk.pathOf(r.key));
    first!.dispose();
    // Memory hit: completes without the platform.
    final second = await svc.load(r).result;
    expect(svc.stats.memoryHits, 1);
    second!.dispose();
    final peek = svc.peek(r)!;
    peek.dispose();
    // Memory dropped: disk hit, still no platform call.
    svc.trimMemory();
    expect(svc.peek(r), isNull);
    (await svc.load(r).result)!.dispose();
    expect(svc.stats.diskHits, 1);
    expect(gen.started, hasLength(1));
  });

  test('requests for one key coalesce into one job', () async {
    gen.gated = true;
    final hs = [for (var i = 0; i < 5; i++) svc.load(req(7))];
    await _settle();
    expect(gen.started, hasLength(1));
    expect(svc.stats.coalesced, 4);
    gen.releaseAll();
    final bs = await Future.wait(hs.map((h) => h.result));
    expect(bs.every((b) => b != null), isTrue);
    expect(decoder.decodes, 1);
    for (final b in bs) {
      b!.dispose();
    }
    // Each caller got its own clone; the cache still holds the original.
    expect(tracker.liveBytes, ThumbSizeClass.m.maxDecodedBytes);
  });

  test('a cancelled queued job never reaches the platform', () async {
    gen.gated = true;
    svc = make(max: 1);
    final running = svc.load(req(1));
    final queued = svc.load(req(2));
    await _settle();
    expect(svc.queued, 1);
    queued.cancel();
    expect(await queued.result, isNull);
    expect(svc.queued, 0);
    expect(svc.stats.dequeued, 1);
    gen.releaseAll();
    (await running.result)!.dispose();
    await _settle();
    expect(gen.started, ['/lib/item1.jpg']);
  });

  test('a running job whose cells all left cancels its native request and writes nothing', () async {
    gen.gated = true;
    final a = svc.load(req(3)), b = svc.load(req(3));
    await _settle();
    a.cancel();
    expect(gen.cancelled, isEmpty, reason: 'another cell still wants it');
    b.cancel();
    await _settle();
    expect(gen.cancelled, hasLength(1));
    expect(svc.stats.nativeCancels, 1);
    expect(await a.result, isNull);
    expect(await b.result, isNull);
    expect(disk.files, isEmpty);
    expect(disk.parts, isEmpty, reason: 'the part file is discarded');
    expect(svc.hasFailed(req(3)), isFalse, reason: 'a cancel is not a failure');
    // Asking again starts a fresh job.
    gen.gated = false;
    (await svc.load(req(3)).result)!.dispose();
  });

  test('newest request first: after a fling the cells on screen are served first', () async {
    gen.gated = true;
    svc = make(max: 1);
    final hs = [for (var i = 0; i < 6; i++) svc.load(req(i))];
    await _settle();
    expect(gen.started, ['/lib/item0.jpg']);
    gen.releaseAll();
    await _settle();
    gen.releaseAll();
    await _settle();
    expect(gen.started.sublist(0, 3), ['/lib/item0.jpg', '/lib/item5.jpg', '/lib/item4.jpg']);
    // A queued key asked again moves to the front.
    svc.load(req(1));
    gen.releaseAll();
    await _settle();
    expect(gen.started[3], '/lib/item1.jpg');
    gen.gated = false;
    gen.releaseAll();
    for (final h in hs) {
      (await h.result)?.dispose();
    }
  });

  test('failures are remembered for the session; cancelled and busy are not', () async {
    gen.failures['/lib/item1.jpg'] = LibraryNativeErrorCode.ioError;
    gen.failures['/lib/item2.jpg'] = LibraryNativeErrorCode.notSupportedOnDevice;
    gen.failures['/lib/item3.jpg'] = LibraryNativeErrorCode.busy;
    for (final i in [1, 2, 3]) {
      expect(await svc.load(req(i)).result, isNull);
    }
    expect(svc.hasFailed(req(1)), isTrue);
    expect(svc.hasFailed(req(2)), isTrue);
    expect(svc.hasFailed(req(3)), isFalse);
    expect(disk.parts, isEmpty);
    final before = gen.started.length;
    expect(await svc.load(req(1)).result, isNull);
    expect(gen.started.length, before, reason: 'not asked again');
    // Forgetting the item (it was replaced) allows a retry.
    gen.failures.remove('/lib/item1.jpg');
    svc.forgetItem('fe_000001');
    (await svc.load(req(1)).result)!.dispose();
  });

  test('documents go to documentThumbnail; none means the type icon', () async {
    gen.noDocumentThumbnail.add('/lib/doc.docx');
    final none = await svc.load(req(9, kind: ThumbSourceKind.document, source: '/lib/doc.docx')).result;
    expect(none, isNull);
    expect(svc.hasFailed(req(9, kind: ThumbSourceKind.document, source: '/lib/doc.docx')), isTrue);
    final pdf = await svc.load(req(10, kind: ThumbSourceKind.document, source: '/lib/a.pdf')).result;
    expect(pdf, isNotNull);
    pdf!.dispose();
  });

  test('a cache file that does not decode is dropped and regenerated', () async {
    final r = req(4);
    disk.files[disk.pathOf(r.key)] = 'corrupt';
    final b = await svc.load(r).result;
    expect(b, isNotNull);
    expect(gen.started, ['/lib/item4.jpg']);
    expect(disk.files[disk.pathOf(r.key)], 'generated');
    b!.dispose();
  });

  test('prefetch moves the native window for ph: assets only, and ignores errors', () async {
    await svc.updatePrefetch(
      entering: [req(1, source: 'ph:A/L0/001'), req(2)],
      leaving: [req(3, source: 'ph:C/L0/001')],
      sizeClass: ThumbSizeClass.m,
    );
    expect(gen.caching.single.start, ['ph:A/L0/001']);
    expect(gen.caching.single.stop, ['ph:C/L0/001']);
    await svc.updatePrefetch(entering: [req(2)], leaving: const [], sizeClass: ThumbSizeClass.m);
    expect(gen.caching, hasLength(1));
  });

  test('dispose cancels everything and releases memory', () async {
    (await svc.load(req(2)).result)!.dispose();
    expect(svc.memory.bytes, greaterThan(0));
    gen.gated = true;
    final h = svc.load(req(1));
    svc.dispose();
    expect(await h.result, isNull);
    gen.releaseAll();
    await _settle();
    expect(svc.memory.bytes, 0);
    expect(await svc.load(req(5)).result, isNull);
  });

  test('ACCEPTANCE: memory never exceeds 64 MB under a 10,000-cell fling (fake decoder)', () async {
    // A fling over a 3-column grid of M thumbnails: 10,000 cells enter the viewport (≈ 30 visible
    // at a time); each cell asks for its thumbnail on entering and cancels on leaving. Every
    // tenth step the fling pauses long enough for the visible cells to finish, and those cells
    // keep their clones while visible.
    gen.gated = true;
    const visible = 30, cells = 10000;
    final live = <int, ThumbHandle>{};
    final shown = <int, ThumbBitmap>{};
    var maxRetained = 0;
    for (var i = 0; i < cells; i++) {
      final h = svc.load(req(i));
      live[i] = h;
      final cell = i;
      h.result.then((b) {
        if (b == null) return;
        if (identical(live[cell], h)) {
          shown[cell] = b;
        } else {
          b.dispose();
        }
      });
      final leaving = i - visible;
      if (leaving >= 0) {
        live.remove(leaving)!.cancel();
        shown.remove(leaving)?.dispose();
      }
      if (i % 10 == 9) {
        gen.releaseAll();
        await _settle();
      }
      expect(svc.memory.bytes, lessThanOrEqualTo(64 * 1024 * 1024));
      if (tracker.liveBytes > maxRetained) maxRetained = tracker.liveBytes;
    }
    gen.releaseAll();
    await _settle();
    expect(svc.memory.peakBytes, lessThanOrEqualTo(64 * 1024 * 1024));
    expect(svc.memory.evictions, greaterThan(0), reason: 'the budget was actually exercised');
    // Retained pixels: the cache plus at most the visible cells' clones (shared with the cache).
    expect(maxRetained, lessThanOrEqualTo(64 * 1024 * 1024 + visible * ThumbSizeClass.m.maxDecodedBytes));
    expect(svc.stats.dequeued, greaterThan(cells ~/ 2), reason: 'most flung-past cells never reached the platform');
    expect(gen.started.length, lessThan(cells ~/ 2));
    for (final b in shown.values) {
      b.dispose();
    }
    for (final h in live.values) {
      h.cancel();
    }
  });

  group('over the dart:io disk tier', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('hom04_svc_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('the cache survives a restart and is invalidated by a new modification time', () async {
      final root = thumbsRootIn(tmp.path);
      Future<(ThumbnailService, FakeGenerator)> open() async {
        final d = IoThumbDiskCache(root);
        await d.open();
        final g = _WritingGenerator();
        return (ThumbnailService(disk: d, generator: g, decoder: FakeDecoder(tracker), format: NativeThumbnailFormat.jpeg), g);
      }

      final (s1, g1) = await open();
      final v1 = req(1, modified: DateTime.utc(2026, 1, 1));
      (await s1.load(v1).result)!.dispose();
      expect(g1.started, hasLength(1));
      s1.dispose();

      final (s2, g2) = await open();
      (await s2.load(v1).result)!.dispose();
      expect(g2.started, isEmpty, reason: 'served from disk after the restart');
      expect(s2.stats.diskHits, 1);

      final v2 = req(1, modified: DateTime.utc(2026, 3, 1));
      (await s2.load(v2).result)!.dispose();
      expect(g2.started, hasLength(1), reason: 'a newer modification time regenerates');
      final files = Directory(root).listSync(recursive: true).whereType<File>().map((f) => f.path).toList();
      expect(files, hasLength(1), reason: 'the old version was removed');
      expect(files.single, endsWith('${v2.modifiedAt.millisecondsSinceEpoch}.thumb'));
      s2.dispose();
    });
  });
}

/// Writes the part file like the platform would.
final class _WritingGenerator extends FakeGenerator {
  @override
  Future<NativeThumbnail> mediaThumbnail({
    required String requestId,
    required String source,
    required int width,
    required int height,
    required String outputPath,
    NativeThumbnailMode mode = NativeThumbnailMode.fill,
    NativeThumbnailFormat format = NativeThumbnailFormat.jpeg,
    double quality = 0.8,
  }) async {
    started.add(source);
    File(outputPath).writeAsBytesSync([0xFF, 0xD8, 0xFF]);
    return NativeThumbnail(path: outputPath, width: width, height: height, format: format);
  }
}
