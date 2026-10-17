// OWNER: UX-21
//
// WaveformCache: the mip pyramid (levels, min/max merging, isolate build), level selection by zoom,
// speed / reverse / ramp mapping of columns, the volume envelope, muted dimming, request
// scheduling (dedupe, concurrency, failures, retry), the 24 MB LRU and memory pressure.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Color, Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/caches/waveform_cache.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../../timeline/canvas/canvas_fixtures.dart';
import '../thumbnails/thumbnail_fixtures.dart' show paintContext, pixel, render, settle, snapshotOf;
import 'waveform_fixtures.dart';

const _white = Color(0xFFFFFFFF);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScriptedWaveformSource source;
  late WaveformResolverFixture resolver;
  late DateTime clock;

  WaveformCache make({int? budget, int maxConcurrent = 2, Set<String> offline = const {}, WaveformPyramidBuilder? builder}) {
    resolver = waveResolver(offline: offline);
    final cache = WaveformCache(
      source: source,
      resolve: resolver.call,
      budgetBytes: budget ?? WaveformCache.defaultBudgetBytes,
      maxConcurrent: maxConcurrent,
      builder: builder ?? (p) async => WaveformPyramid.fromPeaks(p),
      now: () => clock,
    );
    addTearDown(cache.dispose);
    return cache;
  }

  setUp(() {
    source = ScriptedWaveformSource();
    clock = DateTime.utc(2026, 10, 11);
  });

  /// A snapshot with one audio clip of media [media].
  TimelineSnapshot audioSnap({
    String media = 'm_snd',
    TimeUs start = 0,
    TimeUs duration = 10 * s,
    SpeedSpec speed = SpeedSpec.normal,
    bool reversed = false,
    AudioProps audio = AudioProps.unity,
    KeyframeSet keyframes = KeyframeSet.empty,
    int? stream,
  }) =>
      snapshotOf(
        [
          MediaClip(
            id: const ItemId('it_a'),
            start: start,
            duration: duration,
            media: MediaId(media),
            speed: speed,
            reversed: reversed,
            audio: audio,
            keyframes: keyframes,
            audioStream: stream,
          ),
        ],
        assets: [asset('m_snd', kind: MediaKind.audio), asset('m_snd2', kind: MediaKind.audio), asset('m_a')],
        kind: TrackKind.audio,
      );

  Future<WaveformCache> loaded(WaveformPeaks peaks, {String media = 'm_snd'}) async {
    final cache = make();
    // Trigger the request with a throw-away paint, then deliver.
    await render(100, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(media: media), height: 40), const Rect.fromLTWH(0, 0, 100, 40), _white));
    source.jobs.last.complete(peaks);
    await settle();
    return cache;
  }

  group('pyramid', () {
    test('level 0 is the peaks; each level halves the pairs and merges min/max', () {
      final base = Int8List.fromList([for (var i = 0; i < 64; i++) ...[-(i + 1), i + 1]]);
      final levels = WaveformPyramid.buildLevels(base);
      expect([for (final l in levels) l.length ~/ 2], [64, 32, 16, 8]);
      expect(identical(levels.first, base), isTrue);
      // Level 1 pair 0 merges pairs 0 and 1: min of (-1, -2) = -2, max of (1, 2) = 2.
      expect(levels[1][0], -2);
      expect(levels[1][1], 2);
      // Top level pair 7 merges source pairs 56..63.
      expect(levels[3][14], -64);
      expect(levels[3][15], 64);
    });

    test('odd pair counts keep the last pair', () {
      final base = Int8List.fromList([for (var i = 0; i < 21; i++) ...[-i, i]]);
      final levels = WaveformPyramid.buildLevels(base);
      expect(levels[1].length ~/ 2, 11);
      expect(levels[1][20], 0 - 20, reason: 'last pair passes through');
      expect(levels[1][21], 20);
    });

    test('short peaks are a single level; empty peaks work', () {
      expect(WaveformPyramid.buildLevels(Int8List(16)).length, 1);
      final p = WaveformPyramid.fromPeaks(WaveformPeaks(minMax: Int8List(0), duration: 0));
      expect(p.levelCount, 1);
      expect(p.range(0, 0, 1), isNull);
    });

    test('memory is about twice level 0', () {
      final p = WaveformPyramid.fromPeaks(peaksOf(60, (_) => 50));
      expect(p.byteSize, inInclusiveRange(p.levels.first.length, (p.levels.first.length * 2.05).round()));
    });

    test('pairs per second halve per level', () {
      final p = WaveformPyramid.fromPeaks(peaksOf(60, (_) => 50));
      expect(p.pairsPerSecondAt(0), 200);
      expect(p.pairsPerSecondAt(1), 100);
      expect(p.pairsPerSecondAt(3), 25);
    });

    test('built in Isolate.run gives the same levels as the synchronous build', () async {
      final peaks = peaksOf(30, (t) => 40 + 30 * (t % 3) / 3);
      final inIsolate = await WaveformPyramid.buildInIsolate(peaks);
      final inline = WaveformPyramid.fromPeaks(peaks);
      expect(inIsolate.levelCount, inline.levelCount);
      for (var l = 0; l < inline.levelCount; l++) {
        expect(inIsolate.levels[l], inline.levels[l]);
      }
      expect(inIsolate.basePairsPerSecond, 200);
      expect(inIsolate.duration, peaks.duration);
    });
  });

  group('level selection and range', () {
    final p = WaveformPyramid.fromPeaks(peaksOf(600, (_) => 50));

    test('picks the level whose pairs per px is closest to 1', () {
      expect(p.levelFor(200), 0, reason: '1 pair per px');
      expect(p.levelFor(100), 1);
      expect(p.levelFor(50), 2);
      expect(p.levelFor(12.5), 4);
      expect(p.levelFor(25), 3);
    });

    test('between levels the nearer one on a log scale wins', () {
      expect(p.levelFor(150), 0, reason: '1.33 pairs/px at level 0 vs 0.67 at level 1: tie-free choice is the nearer in log scale');
      expect(p.levelFor(140), 1);
    });

    test('zoomed far in uses level 0, far out the top level', () {
      expect(p.levelFor(4000), 0);
      expect(p.levelFor(0.0001), p.levelCount - 1);
      expect(p.levelFor(0), p.levelCount - 1);
    });

    test('range merges the pairs a span covers and is null past the end', () {
      final q = WaveformPyramid.fromPeaks(peaksOf(10, (t) => t * 10));
      final r = q.range(0, 2.0, 2.05)!;
      expect(r.$2, inInclusiveRange(20, 21));
      expect(q.range(0, 5.0, 3.0)!.$2, greaterThanOrEqualTo(49), reason: 'order of the ends does not matter');
      expect(q.range(0, 11, 12), isNull);
      expect(q.range(0, -2, -1)!.$2, 0, reason: 'before the start reads the first pair');
    });
  });

  group('volume envelope', () {
    ItemModel itemWith({AudioProps audio = AudioProps.unity, KeyframeSet keyframes = KeyframeSet.empty}) =>
        audioSnap(audio: audio, keyframes: keyframes).lanes.first.items.first;

    test('no keys: the clip volume', () {
      expect(WaveformEnvelope.gainAt(itemWith(audio: const AudioProps(volume: 0.5)), s), 0.5);
      expect(WaveformEnvelope.gainAt(itemWith(), 0), 1);
    });

    test('keys interpolate linearly and hold at both ends', () {
      final item = itemWith(keyframes: KeyframeSet({
        'audio.volume': KeyframeTrack([Keyframe(2 * s, 0.0), Keyframe(4 * s, 1.0)]),
      }));
      expect(WaveformEnvelope.gainAt(item, 0), 0, reason: 'held before the first key');
      expect(WaveformEnvelope.gainAt(item, 3 * s), closeTo(0.5, 1e-9));
      expect(WaveformEnvelope.gainAt(item, 9 * s), 1, reason: 'held after the last key');
    });
  });

  group('painting', () {
    test('not ready: false and a request; ready: true', () async {
      final cache = make();
      final ctx = paintContext(audioSnap(), height: 40);
      late bool first;
      await render(360, 40, (c) => first = cache.paintWaveform(c, ctx, const Rect.fromLTWH(0, 0, 360, 40), _white));
      expect(first, isFalse);
      expect(source.jobs, hasLength(1));
      expect(source.media.single.fingerprint, 'fp-m_snd');
      expect(source.streams.single, 0);
      source.jobs.single.complete(peaksOf(10, (_) => 60));
      await settle();
      late bool second;
      await render(360, 40, (c) => second = cache.paintWaveform(c, ctx, const Rect.fromLTWH(0, 0, 360, 40), _white));
      expect(second, isTrue);
    });

    test('arrival notifies the canvas', () async {
      final cache = make();
      var n = 0;
      cache.changes.addListener(() => n++);
      await render(360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(), height: 40), const Rect.fromLTWH(0, 0, 360, 40), _white));
      source.jobs.single.complete(peaksOf(10, (_) => 60));
      await settle();
      expect(n, 1);
    });

    test('a bar per pixel column, height from the peaks, centred in the area', () async {
      final cache = await loaded(peaksOf(10, (_) => 63.5));
      final ctx = paintContext(audioSnap(), height: 40, pxPerSecond: 36);
      const area = Rect.fromLTWH(0, 0, 360, 40);
      final data = await render(360, 40, (c) => cache.paintWaveform(c, ctx, area, _white));
      // half = (40 - 2) / 2 = 19; amplitude 63.5 -> max 64/127 and min -64/128 -> about 9.6 px each way.
      final extent = columnExtent(data, 360, 40, 100)!;
      expect(extent.$2 - extent.$1 + 1, inInclusiveRange(17, 21));
      expect((extent.$1 + extent.$2) / 2, closeTo(19.5, 1.5));
      expect(pixel(data, 360, 100, 20), _white);
    });

    test('silence is a thin line', () async {
      final cache = await loaded(peaksOf(10, (_) => 0));
      final data = await render(360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(), height: 40, pxPerSecond: 36), const Rect.fromLTWH(0, 0, 360, 40), _white));
      expect(barHeight(data, 360, 40, 50), inInclusiveRange(1, 2));
    });

    test('past the end of the peaks the clip draws a thin line', () async {
      final cache = await loaded(peaksOf(2, (_) => 100)); // 2 s of audio under a 10 s clip
      final data = await render(360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(), height: 40, pxPerSecond: 36), const Rect.fromLTWH(0, 0, 360, 40), _white));
      expect(barHeight(data, 360, 40, 30), greaterThan(20));
      expect(barHeight(data, 360, 40, 300), inInclusiveRange(1, 2));
    });

    test('the volume scales the amplitude (envelope)', () async {
      Future<int> heightAt(AudioProps audio) async {
        final cache = await loaded(peaksOf(10, (_) => 80));
        final data = await render(360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(audio: audio), height: 40, pxPerSecond: 36), const Rect.fromLTWH(0, 0, 360, 40), _white));
        return barHeight(data, 360, 40, 50);
      }

      final full = await heightAt(AudioProps.unity);
      final half = await heightAt(const AudioProps(volume: 0.5));
      final silent = await heightAt(const AudioProps(volume: 0));
      expect(half, closeTo(full / 2, 2));
      expect(silent, inInclusiveRange(1, 2));
    });

    test('volume keyframes shape the bars over time', () async {
      final cache = await loaded(peaksOf(10, (_) => 100));
      final snap = audioSnap(keyframes: KeyframeSet({
        'audio.volume': KeyframeTrack([Keyframe(0, 0.0), Keyframe(10 * s, 1.0)]),
      }));
      final data = await render(360, 40, (c) => cache.paintWaveform(c, paintContext(snap, height: 40, pxPerSecond: 36), const Rect.fromLTWH(0, 0, 360, 40), _white));
      expect(barHeight(data, 360, 40, 340), greaterThan(barHeight(data, 360, 40, 180)));
      expect(barHeight(data, 360, 40, 180), greaterThan(barHeight(data, 360, 40, 20)));
    });

    test('a muted clip is drawn dimmed', () async {
      final cache = await loaded(peaksOf(10, (_) => 80));
      final data = await render(360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(audio: const AudioProps(muted: true)), height: 40, pxPerSecond: 36), const Rect.fromLTWH(0, 0, 360, 40), _white));
      final c = pixel(data, 360, 50, 20);
      expect(c.r, lessThan(0.6));
      expect(c.r, greaterThan(0.2));
    });

    test('reversed clips read the pyramid backwards', () async {
      // Amplitude grows with source time: 0 at 0 s to 120 at 10 s.
      final cache = await loaded(peaksOf(10, (t) => 12 * t));
      Future<ByteData> draw(bool reversed) => render(
          360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(reversed: reversed), height: 40, pxPerSecond: 36), const Rect.fromLTWH(0, 0, 360, 40), _white));
      final forward = await draw(false);
      final backward = await draw(true);
      expect(barHeight(forward, 360, 40, 330), greaterThan(barHeight(forward, 360, 40, 30)));
      expect(barHeight(backward, 360, 40, 330), lessThan(barHeight(backward, 360, 40, 30)));
      // The mirror columns agree (x and 360 - x).
      expect(barHeight(backward, 360, 40, 30), closeTo(barHeight(forward, 360, 40, 329), 2));
    });

    test('constant speed maps columns through the source time', () async {
      // 5 s clip at 2x plays source 0..10 s; amplitude 12 * t. At x (50 px/s) timeline t = x/50 -> source 2t.
      final cache = await loaded(peaksOf(10, (t) => 12 * t));
      final snap = audioSnap(duration: 5 * s, speed: const ConstantSpeed(2));
      final data = await render(300, 40, (c) => cache.paintWaveform(c, paintContext(snap, height: 40, pxPerSecond: 50, width: 300), const Rect.fromLTWH(0, 0, 300, 40), _white));
      // Column 125 -> t 2.5 s -> source 5 s -> amplitude 60 -> half bar = 60/127 * 19.
      final expected = 2 * (60 / 127 * 19);
      expect(barHeight(data, 300, 40, 125), closeTo(expected, 3));
      expect(barHeight(data, 300, 40, 200), closeTo(2 * (96 / 127 * 19), 3));
    });

    test('a speed ramp maps through the ramp (faster part reads further into the source)', () async {
      final cache = await loaded(peaksOf(20, (t) => 6 * t));
      final ramp = SpeedRamp(const [SpeedPoint(0, 1), SpeedPoint(1, 4)]);
      final snap = audioSnap(duration: 8 * s, speed: ramp);
      final data = await render(400, 40, (c) => cache.paintWaveform(c, paintContext(snap, height: 40, pxPerSecond: 50, width: 400), const Rect.fromLTWH(0, 0, 400, 40), _white));
      // The bars grow with the source position and grow faster in the second half than a constant 1x would.
      final h1 = barHeight(data, 400, 40, 100), h2 = barHeight(data, 400, 40, 200), h3 = barHeight(data, 400, 40, 380);
      expect(h2, greaterThan(h1));
      expect(h3, greaterThan(h2));
      final constant = await render(400, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(duration: 8 * s), height: 40, pxPerSecond: 50, width: 400), const Rect.fromLTWH(0, 0, 400, 40), _white));
      expect(h3, greaterThan(barHeight(constant, 400, 40, 380)));
    });

    test('sourceIn moves the window into the peaks', () async {
      final cache = await loaded(peaksOf(10, (t) => 10 * t));
      final snap = snapshotOf(
        [MediaClip(id: const ItemId('it_a'), start: 0, duration: 4 * s, media: const MediaId('m_snd'), sourceIn: 6 * s)],
        assets: [asset('m_snd', kind: MediaKind.audio)],
        kind: TrackKind.audio,
      );
      final data = await render(200, 40, (c) => cache.paintWaveform(c, paintContext(snap, height: 40, pxPerSecond: 50, width: 200), const Rect.fromLTWH(0, 0, 200, 40), _white));
      // Column 0 -> source 6 s -> amplitude 60.
      expect(barHeight(data, 200, 40, 2), closeTo(2 * (60 / 127 * 19), 3));
    });

    test('video clips with no audio and offline media do not paint or request', () async {
      final cache = make(offline: {'m_snd'});
      final ctx = paintContext(audioSnap(), height: 40);
      late bool painted;
      await render(360, 40, (c) => painted = cache.paintWaveform(c, ctx, const Rect.fromLTWH(0, 0, 360, 40), _white));
      expect(painted, isFalse);
      expect(source.jobs, isEmpty);

      final silentVideo = snapshotOf([clip('it_v', 'm_a', 0, 5 * s, audio: const AudioProps(muted: false))], assets: [asset('m_a', hasAudio: false)]);
      await render(360, 40, (c) => painted = make().paintWaveform(c, paintContext(silentVideo, height: 40), const Rect.fromLTWH(0, 0, 360, 40), _white));
      expect(painted, isFalse);
      expect(source.jobs, isEmpty);
    });

    test('the audio stream of the clip is requested', () async {
      final cache = make();
      await render(360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(stream: 2), height: 40), const Rect.fromLTWH(0, 0, 360, 40), _white));
      expect(source.streams.single, 2);
    });
  });

  group('requests', () {
    test('a media is requested once however often it repaints; clips of one media share it', () async {
      final cache = make();
      final ctx = paintContext(audioSnap(), height: 40);
      for (var i = 0; i < 4; i++) {
        await render(360, 40, (c) => cache.paintWaveform(c, ctx, const Rect.fromLTWH(0, 0, 360, 40), _white));
      }
      expect(source.jobs, hasLength(1));
      expect(cache.pendingCount, 1);
    });

    test('at most maxConcurrent extractions run; the most recently painted waits least', () async {
      final cache = make(maxConcurrent: 1);
      Future<void> paint(String media) => render(
          360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(media: media), height: 40), const Rect.fromLTWH(0, 0, 360, 40), _white));
      await paint('m_snd');
      await paint('m_snd2');
      await paint('m_a');
      expect(source.jobs, hasLength(1), reason: 'one at a time');
      source.jobs.first.complete(peaksOf(2, (_) => 10));
      await settle();
      expect(source.jobs, hasLength(2));
      expect(source.media.last.fingerprint, 'fp-m_a', reason: 'the newest request goes first');
    });

    test('a failed extraction is not retried before the delay', () async {
      final cache = make();
      final ctx = paintContext(audioSnap(), height: 40);
      await render(360, 40, (c) => cache.paintWaveform(c, ctx, const Rect.fromLTWH(0, 0, 360, 40), _white));
      source.jobs.single.fail(const EngineError(EngineErrorCode.decodeFailed));
      await settle();
      expect(cache.failedCount, 1);
      late bool painted;
      await render(360, 40, (c) => painted = cache.paintWaveform(c, ctx, const Rect.fromLTWH(0, 0, 360, 40), _white));
      expect(painted, isFalse);
      expect(source.jobs, hasLength(1));
      clock = clock.add(const Duration(seconds: 11));
      await render(360, 40, (c) => cache.paintWaveform(c, ctx, const Rect.fromLTWH(0, 0, 360, 40), _white));
      expect(source.jobs, hasLength(2));
    });

    test('a failing builder is a failure', () async {
      final cache = make(builder: (_) => Future<WaveformPyramid>.error(StateError('x')));
      await render(360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(), height: 40), const Rect.fromLTWH(0, 0, 360, 40), _white));
      source.jobs.single.complete(peaksOf(2, (_) => 10));
      await settle();
      expect(cache.failedCount, 1);
      expect(cache.cachedCount, 0);
    });

    test('works over the engine API fake (flat peaks)', () async {
      final engine = FakeEditorEngine();
      final cache = WaveformCache(source: engine.waveforms, resolve: waveResolver().call, builder: (p) async => WaveformPyramid.fromPeaks(p));
      addTearDown(cache.dispose);
      final ctx = paintContext(audioSnap(), height: 40);
      await render(360, 40, (c) => cache.paintWaveform(c, ctx, const Rect.fromLTWH(0, 0, 360, 40), _white));
      await settle();
      expect(cache.cachedCount, 1);
      late bool painted;
      await render(360, 40, (c) => painted = cache.paintWaveform(c, ctx, const Rect.fromLTWH(0, 0, 360, 40), _white));
      expect(painted, isTrue);
    });

    test('dispose cancels what is running', () async {
      final cache = make();
      await render(360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(), height: 40), const Rect.fromLTWH(0, 0, 360, 40), _white));
      cache.dispose();
      expect(source.jobs.single.cancelled, isTrue);
    });
  });

  group('budget', () {
    test('the default budget is 24 MB', () => expect(WaveformCache.defaultBudgetBytes, 24 * 1024 * 1024));

    Future<WaveformCache> fill(int budget, List<String> media) async {
      final cache = make(budget: budget, maxConcurrent: 8);
      for (final m in media) {
        await render(360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(media: m), height: 40), const Rect.fromLTWH(0, 0, 360, 40), _white));
      }
      for (final j in source.jobs) {
        j.complete(peaksOf(10, (_) => 30)); // 4000 B + levels ~ 8 KB each
      }
      await settle();
      return cache;
    }

    test('the LRU evicts the least recently painted pyramid over budget', () async {
      final one = WaveformPyramid.fromPeaks(peaksOf(10, (_) => 30)).byteSize;
      final cache = await fill(one * 2 + 10, ['m_snd', 'm_snd2', 'm_a']);
      expect(cache.cachedCount, 2);
      expect(cache.cachedBytes, lessThanOrEqualTo(one * 2 + 10));
      expect(cache.contains(const WaveformKey('fp-m_snd', 0)), isFalse, reason: 'the oldest went');
      expect(cache.contains(const WaveformKey('fp-m_a', 0)), isTrue);
    });

    test('painting refreshes the LRU position', () async {
      final one = WaveformPyramid.fromPeaks(peaksOf(10, (_) => 30)).byteSize;
      final cache = await fill(one * 3 + 10, ['m_snd', 'm_snd2', 'm_a']);
      expect(cache.cachedCount, 3);
      await render(360, 40, (c) => cache.paintWaveform(c, paintContext(audioSnap(media: 'm_snd'), height: 40), const Rect.fromLTWH(0, 0, 360, 40), _white));
      // A fourth media pushes the oldest (now m_snd2) out.
      await render(360, 40, (c) => cache.paintWaveform(c, paintContext(snapshotOf([clip('it_x', 'm_x', 0, 10 * s)], assets: [asset('m_x', kind: MediaKind.audio)], kind: TrackKind.audio), height: 40), const Rect.fromLTWH(0, 0, 360, 40), _white));
      source.jobs.last.complete(peaksOf(10, (_) => 30));
      await settle();
      expect(cache.contains(const WaveformKey('fp-m_snd2', 0)), isFalse);
      expect(cache.contains(const WaveformKey('fp-m_snd', 0)), isTrue);
    });

    test('memory pressure keeps 25% of the budget', () async {
      final one = WaveformPyramid.fromPeaks(peaksOf(10, (_) => 30)).byteSize;
      final cache = await fill(one * 4, ['m_snd', 'm_snd2', 'm_a']);
      expect(cache.cachedCount, 3);
      cache.onMemoryPressure();
      expect(cache.cachedBytes, lessThanOrEqualTo(one));
      expect(cache.cachedCount, 1);
    });

    test('evictMedia drops one media', () async {
      final cache = await fill(WaveformCache.defaultBudgetBytes, ['m_snd', 'm_snd2']);
      cache.evictMedia('fp-m_snd');
      expect(cache.cachedCount, 1);
      expect(cache.contains(const WaveformKey('fp-m_snd2', 0)), isTrue);
    });
  });

  test('decoded pixels are real images (sanity for the golden rig)', () async {
    final data = await render(4, 4, (c) => c.drawRect(const Rect.fromLTWH(0, 0, 4, 4), ui.Paint()..color = _white));
    expect(pixel(data, 4, 1, 1), _white);
  });
}
