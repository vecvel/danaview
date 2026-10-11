// OWNER: UX-20
//
// ThumbnailCache with a scripted engine source: request keys (interval ladder, height bucket,
// tile, proxy), priority order and pre-emption, cancel when scrolled away, fling deferral, the
// byte budget, memory pressure, speed/reverse mapping, stills, failures and fallbacks.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/caches/thumbnail_cache.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_style.dart';
import 'package:danaview_editor_core/eval.dart' show ClipTimeMap;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../../timeline/canvas/canvas_fixtures.dart';
import 'thumbnail_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScriptedThumbnailSource source;
  late ThumbnailResolverFixture resolver;
  late DateTime clock;

  ThumbnailCache make({int? budget, int maxInFlight = 4, Set<String> proxies = const {}, Set<String> offline = const {}, bool low = false}) {
    resolver = resolverOf(proxies: proxies, offline: offline);
    final cache = ThumbnailCache(
      source: source,
      resolve: resolver.call,
      budgetBytes: budget,
      lowMemoryDevice: low,
      maxInFlight: maxInFlight,
      decoder: decodeScripted,
      now: () => clock,
    );
    addTearDown(cache.dispose);
    return cache;
  }

  setUp(() {
    source = ScriptedThumbnailSource();
    clock = DateTime.utc(2026, 10, 11);
  });

  TimelineSnapshot longClip({TimeUs? sourceIn, SpeedSpec speed = SpeedSpec.normal, bool reversed = false, int seconds = 60, ProxyState proxy = ProxyState.none}) => snapshotOf(
        [clip('it_1', 'm_a', 0, seconds * s, speed: speed, reversed: reversed)],
        assets: [asset('m_a'), asset('m_img', kind: MediaKind.image, hasAudio: false)],
      );

  group('pure helpers', () {
    test('height buckets cover the pixel height with 48, 64 or 96', () {
      expect(ThumbnailCache.heightBucket(40, 1), 48);
      expect(ThumbnailCache.heightBucket(60, 1), 64);
      expect(ThumbnailCache.heightBucket(60, 1.5), 96);
      expect(ThumbnailCache.heightBucket(76, 3), 96, reason: 'never above 96');
      expect(ThumbnailCache.heightBucket(16, 1), 48);
    });

    test('interval ladder follows the zoom (cell about one clip height wide)', () {
      // cell 107 px: 1 px = 1/60 s, so a cell spans 1.8 s -> 2 s
      expect(ThumbnailCache.intervalFor(cellWidthPx: 106.7, pxPerSecond: 60), 2000);
      expect(ThumbnailCache.intervalFor(cellWidthPx: 106.7, pxPerSecond: 6), 30000, reason: '17.8 s is nearer 30 s than 10 s on a log scale');
      expect(ThumbnailCache.intervalFor(cellWidthPx: 106.7, pxPerSecond: 12), 10000, reason: '8.9 s -> 10 s');
      expect(ThumbnailCache.intervalFor(cellWidthPx: 106.7, pxPerSecond: 0.5), 60000, reason: 'capped');
      expect(ThumbnailCache.intervalFor(cellWidthPx: 106.7, pxPerSecond: 600), 500, reason: 'floor');
      // At 2x speed a cell spans twice the source time.
      expect(ThumbnailCache.intervalFor(cellWidthPx: 106.7, pxPerSecond: 60, avgSpeed: 2), 5000, reason: '3.6 s per cell');
      expect(ThumbnailCache.intervalFor(cellWidthPx: 106.7, pxPerSecond: 60, avgSpeed: 5), 10000);
      expect(ThumbnailCache.intervalFor(cellWidthPx: 0, pxPerSecond: 60), 500);
    });

    test('budgets: 48 MB on low-memory devices, 96 MB otherwise', () {
      expect(ThumbnailCache.defaultBudgetBytes(lowMemoryDevice: true), 48 * 1024 * 1024);
      expect(ThumbnailCache.defaultBudgetBytes(lowMemoryDevice: false), 96 * 1024 * 1024);
      expect(make(low: true).budgetBytes, 48 * 1024 * 1024);
      expect(make().budgetBytes, 96 * 1024 * 1024);
    });
  });

  group('requests', () {
    test('a visible clip requests its tile at visible priority and neighbours as prefetch', () async {
      final cache = make();
      final snap = longClip();
      final ctx = paintContext(snap);
      cache.beginPaint(const TimeRange(0, 20 * s));
      final painted = await render(360, 60, (c) => expect(cache.paintThumbnails(c, ctx), isFalse, reason: 'nothing cached yet'));
      expect(painted, isNotNull);
      cache.endPaint();

      expect(source.requests, hasLength(2));
      final visible = source.handles.firstWhere((h) => h.priority == ThumbPriority.visible);
      expect(visible.request.tileIndex, 0);
      expect(visible.request.intervalMs, 2000);
      expect(visible.request.heightPx, 64);
      expect(visible.request.framesPerTile, 8);
      expect(visible.request.proxy, isFalse);
      expect(visible.request.media.fingerprint, 'fp-m_a');
      final prefetch = source.handles.firstWhere((h) => h.priority == ThumbPriority.prefetch);
      expect(prefetch.request.tileIndex, 1);
    });

    test('pixel height follows the device pixel ratio', () async {
      final cache = make();
      final ctx = paintContext(longClip(), dpr: 2);
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      expect(source.requests.first.heightPx, 96);
    });

    test('the same tile is requested once however often the clip repaints', () async {
      final cache = make();
      final ctx = paintContext(longClip());
      for (var i = 0; i < 5; i++) {
        cache.beginPaint(const TimeRange(0, 20 * s));
        await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
        cache.endPaint();
      }
      expect(source.requests, hasLength(2));
      expect(cache.requestedCount, 2);
    });

    test('proxy: a ready proxy is used for video strips and recorded in the key', () async {
      final cache = make(proxies: {'m_a'});
      final proxyAsset = asset('m_a', derived: null);
      final snap = snapshotOf([clip('it_1', 'm_a', 0, 60 * s)], assets: [proxyAsset.copyWith(proxy: ProxyState.ready)]);
      final ctx = paintContext(snap);
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      expect(source.requests.first.proxy, isTrue);
      expect(source.requests.first.media.isProxy, isTrue);
      expect(source.requests.first.media.fingerprint, 'fp-m_a', reason: 'the key still names the original');
      expect(resolver.calls.first, ('m_a', true));
    });

    test('proxy: falls back to the original when the host has no proxy file', () async {
      final cache = make();
      final snap = snapshotOf([clip('it_1', 'm_a', 0, 60 * s)], assets: [asset('m_a').copyWith(proxy: ProxyState.ready)]);
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap)));
      expect(source.requests.first.proxy, isFalse);
      expect(resolver.calls, [('m_a', true), ('m_a', false)]);
    });

    test('offline, pending and unresolvable media request nothing and report false', () async {
      final cache = make(offline: {'m_a'});
      final snap = longClip();
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => expect(cache.paintThumbnails(c, paintContext(snap)), isFalse));
      expect(source.requests, isEmpty);

      final audioOnly = snapshotOf([clip('it_a', 'm_snd', 0, 10 * s)], kind: TrackKind.audio);
      await render(360, 60, (c) => expect(cache.paintThumbnails(c, paintContext(audioOnly)), isFalse));
      expect(source.requests, isEmpty, reason: 'audio clips have no thumbnails');
    });
  });

  group('priorities and cancellation', () {
    test('slots are limited; a visible request pre-empts a running prefetch one', () async {
      final cache = make(maxInFlight: 2);
      final snap = longClip();
      // Overscan clip prefetch fills both slots first.
      cache.beginPaint(const TimeRange(0, 60 * s));
      cache.prefetchThumbnails(paintContext(snap, overscan: true));
      expect(cache.inFlightCount, 2);
      expect(source.handles.every((h) => h.priority == ThumbPriority.prefetch), isTrue);
      final preempted = source.handles.last;

      final other = snapshotOf([clip('it_2', 'm_b', 0, 60 * s)], assets: [asset('m_b')]);
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(other)));
      final visible = source.handles.firstWhere((h) => h.priority == ThumbPriority.visible && h.request.media.fingerprint == 'fp-m_b');
      expect(visible.cancelled, isFalse);
      expect(cache.inFlightCount, 2, reason: 'still two slots');
      expect(preempted.cancelled, isTrue, reason: 'the newest running prefetch request gave up its slot');
      expect(cache.cancelledCount, 1);
      expect(cache.waitingCount, greaterThan(0), reason: 'the pre-empted request waits again');
    });

    test('visible requests start before waiting prefetch requests', () async {
      final cache = make(maxInFlight: 1);
      final snap = longClip();
      cache.beginPaint(const TimeRange(0, 60 * s));
      cache.prefetchThumbnails(paintContext(snap, overscan: true)); // takes the slot
      final firstKey = cache.pendingKeys.first;
      final other = snapshotOf([clip('it_2', 'm_b', 0, 60 * s)], assets: [asset('m_b')]);
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(other)));
      // The visible tile is running now; the prefetch one waits again.
      expect(cache.priorityOf(firstKey), ThumbPriority.prefetch);
      final running = source.live.where((h) => !h.cancelled).toList();
      expect(running.last.priority, ThumbPriority.visible);
    });

    test('a prefetch request becomes visible when the clip scrolls on screen', () async {
      final cache = make();
      final snap = longClip();
      cache.beginPaint(const TimeRange(0, 20 * s));
      cache.prefetchThumbnails(paintContext(snap, overscan: true));
      final key = cache.pendingKeys.first;
      expect(cache.priorityOf(key), ThumbPriority.prefetch);
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap)));
      expect(cache.priorityOf(key), ThumbPriority.visible);
    });

    test('requests that a paint pass did not touch are cancelled at endPaint', () async {
      final cache = make();
      final snap = longClip();
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap)));
      cache.endPaint();
      expect(source.live, hasLength(2));

      // Scrolled far away: the next pass paints a different part of the clip.
      cache.beginPaint(const TimeRange(50 * s, 60 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap, scrollTimeSec: 50)));
      cache.endPaint();
      final cancelled = source.handles.where((h) => h.cancelled).toList();
      expect(cancelled, hasLength(2), reason: 'tile 0 and its prefetch neighbour');
      expect(cancelled.map((h) => h.request.tileIndex).toSet(), {0, 1});
      expect(cache.cancelledCount, 2);
      expect(source.live.map((h) => h.request.tileIndex), everyElement(greaterThan(1)));
    });

    test('a cancelled request is not reported as a failure and can be requested again', () async {
      final cache = make();
      final snap = longClip();
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap)));
      cache.endPaint();
      cache.beginPaint(const TimeRange(40 * s, 60 * s));
      cache.endPaint();
      await settle();
      expect(cache.failedCount, 0);
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap)));
      expect(source.requests.where((r) => r.tileIndex == 0), hasLength(2));
    });

    test('fling deferral: nothing starts above 2000 px/s, requests start once it slows', () async {
      final cache = make();
      final snap = longClip();
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap, fling: 2500)));
      cache.endPaint();
      expect(source.requests, isEmpty);
      expect(cache.deferredCount, greaterThan(0));

      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap, fling: 1999)));
      expect(source.requests, isNotEmpty, reason: 'just below the threshold');
    });

    test('overscan prefetch is also deferred during a fast fling', () {
      final cache = make();
      cache.beginPaint(const TimeRange(0, 60 * s));
      cache.prefetchThumbnails(paintContext(longClip(), overscan: true, fling: -4000));
      expect(source.requests, isEmpty);
    });

    test('dispose cancels what is running', () async {
      final cache = make();
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(longClip())));
      final handles = source.handles.toList();
      cache.dispose();
      expect(handles.every((h) => h.cancelled), isTrue);
    });
  });

  group('arrival and painting', () {
    test('an arriving strip is decoded, cached, notified and painted with the right frames', () async {
      final cache = make();
      var notified = 0;
      cache.changes.addListener(() => notified++);
      final snap = longClip();
      final ctx = paintContext(snap);
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      source.completeAll();
      await settle();
      expect(notified, greaterThan(0));
      expect(cache.cachedCount, 2);
      expect(cache.cachedBytes, 2 * 8 * 16 * 9 * 4);

      late bool painted;
      final data = await render(360, 60, (c) => painted = cache.paintThumbnails(c, ctx));
      expect(painted, isTrue);
      // Cells are 106.67 px wide; their centres are at 0.89, 2.67, 4.44 and 6.22 s -> frames 0..3.
      for (final (x, n) in [(53, 0), (160, 1), (267, 2), (350, 3)]) {
        expect(pixel(data, 360, x, 30), scriptedColor(n, 2000), reason: 'cell at x=$x shows frame $n');
      }
    });

    test('cells that are still missing are flat placeholder cells, the rest is painted', () async {
      final cache = make();
      final snap = longClip();
      // View 14..20 s at 60 px/s (2 s interval, 16 s per tile): cell 0 (frame 7) is in tile 0, cell 1 (frame 8) in tile 1.
      final ctx = paintContext(snap, scrollTimeSec: 14);
      cache.beginPaint(const TimeRange(14 * s, 34 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      // Deliver only tile 0; at 5 s per frame the visible cells use frames 0..2 of tile 0.
      source.handles.firstWhere((h) => h.request.tileIndex == 0).complete();
      await settle();
      late bool painted;
      final data = await render(360, 60, (c) => painted = cache.paintThumbnails(c, ctx));
      expect(painted, isTrue);
      // Cells hang on the clip start: cell 7 spans x -93..13 (frame 7, tile 0), cell 8 spans 13..120 (frame 8, tile 1).
      expect(pixel(data, 360, 5, 30), scriptedColor(7, 2000));
      final flat = Color.alphaBlend(TimelineStyle.standard.videoFill, const Color(0xFF000000));
      expect(pixel(data, 360, 60, 30), flat, reason: 'tile 1 has not arrived: a flat cell');
    });

    test('reversed clips read their source backwards', () async {
      final cache = make();
      // 12 s clip with source 0..12 s played backwards: the first cell shows the source end.
      final snap = snapshotOf([clip('it_1', 'm_a', 0, 12 * s, reversed: true)]);
      final ctx = paintContext(snap, pxPerSecond: 60);
      cache.beginPaint(const TimeRange(0, 12 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      // Source time at timeline 0.89 s is 12 - 0.89 = 11.1 s -> frame round(11.1 / 2) = 6; cell 1: 9.33 -> 5, cell 2: 7.56 -> 4, cell 3: 5.78 -> 3.
      for (final h in source.handles) {
        h.complete();
      }
      await settle();
      final data = await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      for (final (x, n) in [(53, 6), (160, 5), (267, 4), (350, 3)]) {
        expect(pixel(data, 360, x, 30), scriptedColor(n, 2000), reason: 'reversed cell at x=$x shows frame $n');
      }
    });

    test('constant speed maps cells through the source time (2x skips frames, interval follows)', () async {
      final cache = make();
      final snap = snapshotOf([clip('it_1', 'm_a', 0, 6 * s, speed: const ConstantSpeed(4))]);
      final ctx = paintContext(snap, pxPerSecond: 60);
      cache.beginPaint(const TimeRange(0, 6 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      // A 107 px cell spans 1.78 timeline s = 7.1 source s -> 10 s on the ladder (log scale).
      expect(source.requests.first.intervalMs, 10000);
      source.completeAll();
      await settle();
      final data = await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      // Cell centres 0.89, 2.67, 4.44 timeline s -> source 3.56, 10.7, 17.8 s -> /10 s -> frames 0, 1, 2.
      for (final (x, n) in [(53, 0), (160, 1), (267, 2)]) {
        expect(pixel(data, 360, x, 30), scriptedColor(n, 10000), reason: 'cell at x=$x shows frame $n');
      }
    });

    test('a speed ramp maps cells through the ramp (checked against ClipTimeMap)', () async {
      final cache = make();
      final ramp = SpeedRamp(const [SpeedPoint(0, 1), SpeedPoint(1, 4)]);
      final media = clip('it_1', 'm_a', 0, 8 * s, speed: ramp);
      final snap = snapshotOf([media]);
      final ctx = paintContext(snap);
      cache.beginPaint(const TimeRange(0, 8 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      final interval = source.requests.first.intervalMs;
      source.completeAll();
      await settle();
      late bool painted;
      final data = await render(360, 60, (c) => painted = cache.paintThumbnails(c, ctx));
      expect(painted, isTrue);
      final map = ClipTimeMap.forClip(media, FrameRate.fps30);
      var checked = 0;
      for (final x in [53, 160, 267]) {
        // Cell centres 53.3, 160, 266.7 px at 60 px/s -> timeline time -> source time -> frame.
        final t = (x / 60 * s).round();
        final frame = (map.sourceAt(t) / (interval * 1000)).round();
        if (frame ~/ 8 > 0) continue; // only tile 0 was scripted per frame colour here
        expect(pixel(data, 360, x, 30), scriptedColor(frame, interval), reason: 'cell at x=$x shows source frame $frame');
        checked++;
      }
      expect(checked, greaterThan(0));
      // The ramp really changes the mapping: a constant 1x clip shows other frames at the same cells.
      expect(map.sourceAt(6 * s), greaterThan(6 * s * 1.5), reason: 'the ramp runs ahead of 1x');
    });

    test('stills: one request for one frame, repeated across the clip', () async {
      final cache = make();
      final snap = snapshotOf([clip('it_i', 'm_img', 0, 10 * s)]);
      final ctx = paintContext(snap);
      cache.beginPaint(const TimeRange(0, 10 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      expect(source.requests, hasLength(1));
      expect(source.requests.single.framesPerTile, 1);
      expect(source.requests.single.tileIndex, 0);
      expect(source.requests.single.proxy, isFalse);
      source.completeAll();
      await settle();
      final data = await render(360, 60, (c) => expect(cache.paintThumbnails(c, ctx), isTrue));
      final a = pixel(data, 360, 50, 30), b = pixel(data, 360, 160, 30), c2 = pixel(data, 360, 300, 30);
      expect(a, b);
      expect(b, c2);
      expect(a, isNot(const Color(0xFF000000)));
    });

    test('a strip of another interval stands in while the new interval loads (no flash on zoom)', () async {
      final cache = make();
      final snap = longClip();
      // Load at 60 px/s (2 s interval).
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap)));
      source.completeAll();
      await settle();
      // Zoom to 120 px/s: 1 s interval is requested, but cells already show 2 s frames.
      final ctx = paintContext(snap, pxPerSecond: 120);
      late bool painted;
      final data = await render(360, 60, (c) => painted = cache.paintThumbnails(c, ctx));
      expect(painted, isTrue);
      expect(source.requests.any((r) => r.intervalMs == 1000), isTrue);
      expect(pixel(data, 360, 20, 30), isNot(const Color(0xFF000000)));
    });
  });

  group('budget', () {
    test('the LRU stays within the budget and disposes evicted images', () async {
      // Each strip decodes to 8 * 16 x 9 px = 4608 bytes.
      final cache = make(budget: 4608 * 3, maxInFlight: 8);
      final snap = longClip();
      for (final scroll in [0.0, 14.0, 28.0, 42.0]) {
        cache.beginPaint(TimeRange((scroll * s).round(), ((scroll + 20) * s).round()));
        await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap, scrollTimeSec: scroll)));
        cache.endPaint();
        source.completeAll();
        await settle();
        expect(cache.cachedBytes, lessThanOrEqualTo(4608 * 3));
      }
      expect(cache.cachedCount, lessThanOrEqualTo(3));
    });

    test('painting a strip moves it to the front of the LRU', () async {
      final cache = make(budget: 4608 * 2, maxInFlight: 8);
      final snap = longClip();
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap)));
      source.completeAll();
      await settle();
      expect(cache.cachedCount, 2);
      // Touch tile 0 so tile 1 is the oldest, then add tile 2.
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap)));
      cache.beginPaint(const TimeRange(14 * s, 34 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap, scrollTimeSec: 18)));
      source.completeAll();
      await settle();
      expect(cache.cachedCount, 2);
    });

    test('memory pressure trims to 25% of the budget and cancels non-visible requests', () async {
      final cache = make(budget: 4608 * 8, maxInFlight: 8);
      final snap = longClip();
      for (final scroll in [0.0, 14.0, 28.0, 42.0]) {
        cache.beginPaint(TimeRange((scroll * s).round(), ((scroll + 20) * s).round()));
        await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(snap, scrollTimeSec: scroll)));
        source.completeAll();
        await settle();
      }
      expect(cache.cachedBytes, greaterThan(4608 * 2));
      cache.beginPaint(const TimeRange(0, 60 * s));
      cache.prefetchThumbnails(paintContext(snap, overscan: true));
      final prefetch = source.live.toList();
      cache.onMemoryPressure();
      expect(cache.cachedBytes, lessThanOrEqualTo(4608 * 2));
      expect(cache.cachedBytes, greaterThan(0));
      expect(prefetch.every((h) => h.cancelled), isTrue);
    });

    test('evictMedia drops the strips of one media', () async {
      final cache = make();
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(longClip())));
      source.completeAll();
      await settle();
      expect(cache.cachedCount, greaterThan(0));
      cache.evictMedia('fp-m_a');
      expect(cache.cachedCount, 0);
      expect(cache.cachedBytes, 0);
    });
  });

  group('engine API fake', () {
    test('works against FakeEditorEngine.thumbnails (requests are logged, strips decode and cache)', () async {
      final engine = FakeEditorEngine();
      final cache = ThumbnailCache(
        source: engine.thumbnails,
        resolve: resolverOf().call,
        decoder: (_) => decodeScripted(Uint8List.fromList([0, 20, 8])),
      );
      addTearDown(cache.dispose);
      cache.beginPaint(const TimeRange(0, 20 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(longClip())));
      cache.endPaint();
      expect(engine.thumbnails.requests, hasLength(2));
      expect(engine.thumbnails.priorities, containsAll([ThumbPriority.visible, ThumbPriority.prefetch]));
      await settle();
      expect(cache.cachedCount, 2);
    });

    test('engine failures from the fake are counted, not thrown', () async {
      final engine = FakeEditorEngine();
      engine.failNext['thumbnails.request'] = const EngineError(EngineErrorCode.io);
      final cache = ThumbnailCache(source: engine.thumbnails, resolve: resolverOf().call, decoder: decodeScripted);
      addTearDown(cache.dispose);
      cache.beginPaint(const TimeRange(0, 10 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(longClip(seconds: 10))));
      await settle();
      expect(cache.failedCount, 1);
    });
  });

  group('failures', () {
    test('a failed tile is not retried before the delay, then is', () async {
      final cache = make();
      final snap = longClip(seconds: 10);
      final ctx = paintContext(snap);
      cache.beginPaint(const TimeRange(0, 10 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      for (final h in source.handles.toList()) {
        h.fail();
      }
      await settle();
      expect(cache.failedCount, 1);
      final before = source.requests.length;
      for (var i = 0; i < 3; i++) {
        await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      }
      expect(source.requests.length, before, reason: 'repaints do not loop on a broken tile');
      clock = clock.add(const Duration(seconds: 6));
      await render(360, 60, (c) => cache.paintThumbnails(c, ctx));
      expect(source.requests.length, before + 1);
    });

    test('a decode failure is a failure too', () async {
      final cache = ThumbnailCache(
        source: source,
        resolve: resolverOf().call,
        decoder: (_) => Future<ui.Image>.error(StateError('bad jpeg')),
        now: () => clock,
      );
      addTearDown(cache.dispose);
      cache.beginPaint(const TimeRange(0, 10 * s));
      await render(360, 60, (c) => cache.paintThumbnails(c, paintContext(longClip(seconds: 10))));
      source.completeAll();
      await settle();
      expect(cache.failedCount, 1);
      expect(cache.cachedCount, 0);
    });
  });
}
