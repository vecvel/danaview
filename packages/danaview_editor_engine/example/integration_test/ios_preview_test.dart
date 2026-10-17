// OWNER: IOS-11
//
// iOS preview session through the real plugin (BUILD_PLAN IOS-11, ARCH §12.2, §12.7, §13.2):
// MobileEditorEngine.openPreview -> ENG-02's MobilePreviewSession -> Pigeon -> IOS-11's
// PreviewSessionManager / PreviewSession (AVPlayer + DVCompositor) on a Flutter texture.
//
//   cd packages/danaview_editor_engine/example
//   flutter test integration_test/ios_preview_test.dart -d <iOS simulator or device>
//
// The plans hold only solid layers, so no media files are needed on the device: three full-canvas
// solids cut at frames 31 and 61 (red, green, blue: the colour names the segment, like
// grid_cuts_30fps.json's cuts), a white box moved by patches and transients, and a yellow marker
// whose x position is keyframed over time, so every captured frame identifies its frame index.
// Media-backed checks (barcoded fixture frames at every frame around the grid cuts, stills over
// the decode budget, rendered-range hook, background/foreground, degraded/recovered) run natively
// in example/ios/RunnerTests/Preview. The preview A/V offset on clap_flash (≤ 1 frame and ≤ 40 ms)
// needs an instrumented device run: deferred, no device available. Timings printed here are
// simulator numbers.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_example/engine_host.dart';

const int _w = 320;
const int _h = 180;
const int _fps = 30;
const int _frames = 90;

int _timeOfFrame(int k) => (k * 1000000 + _fps - 1) ~/ _fps;

/// x of the yellow marker at frame [k]: keyframes [[0, 10], [3000000, 310]]. The marker is 2 px
/// wide and moves 3.3 px per frame, so the pixel under its centre identifies the frame exactly.
double _markerX(int k) => 10 + 300 * _timeOfFrame(k) / 3000000;

Map<String, Object?> _solid(String id, int z, String color, List<num> base, Map<String, Object?> xf,
        {int from = 0, int to = _frames, Map<String, Object?>? anim}) =>
    {
      'id': id,
      'z': z,
      't': [_timeOfFrame(from), _timeOfFrame(to)],
      'kind': 'solid',
      'color': color,
      'base': base,
      'xf': xf,
      if (anim != null) 'anim': anim,
    };

Map<String, Object?> _boxLayer(num cx) => _solid('it_box#v', 10, '#FFFFFFFF', [40, 40], {'cx': cx, 'cy': 60});

RenderPlan _plan() => PlanTransport.decodePlan(Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'rev': 1,
      'target': 'preview',
      'canvas': {'w': _w, 'h': _h, 'fps': _fps, 'bg': '#000000FF'},
      'durUs': _timeOfFrame(_frames),
      'assets': <String, Object?>{},
      'layers': [
        _solid('it_a#v', 0, '#FF0000FF', [_w, _h], <String, Object?>{}, to: 31),
        _solid('it_b#v', 0, '#00FF00FF', [_w, _h], <String, Object?>{}, from: 31, to: 61),
        _solid('it_c#v', 0, '#0000FFFF', [_w, _h], <String, Object?>{}, from: 61),
        _boxLayer(60),
        _solid('it_mov#v', 20, '#FFFF00FF', [2, 20], {'cy': 150}, anim: {
          'xf.cx': [
            [0, 10],
            [3000000, 310],
          ],
        }),
      ],
      'audio': <Object?>[],
    }))));

RenderPlanPatch _patch(int from, {List<Map<String, Object?>> upsert = const [], List<String> remove = const []}) =>
    PlanTransport.decodePatch(Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'from': from,
      'to': from + 1,
      'layers': {'upsert': upsert, 'remove': remove},
    }))));

PlanTransient _transient(Map<String, Object?> xf) => PlanTransport.decodeTransient(Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'item': 'it_box',
      'layers': [
        {'id': 'it_box#v', 'xf': xf},
      ],
    }))));

List<int> _px(Uint8List rgba, int width, int x, int y) {
  final i = (y * width + x) * 4;
  return [rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]];
}

/// [value] typed as whatever the call site expects (core's `ItemId` extension type).
T _typed<T>(Object value) => value as T;

bool _isRed(List<int> p) => p[0] > 200 && p[1] < 60 && p[2] < 60;
bool _isGreen(List<int> p) => p[1] > 200 && p[0] < 60 && p[2] < 60;
bool _isBlue(List<int> p) => p[2] > 200 && p[0] < 60 && p[1] < 60;
bool _isWhite(List<int> p) => p[0] > 200 && p[1] > 200 && p[2] > 200;
bool _isYellow(List<int> p) => p[0] > 200 && p[1] > 200 && p[2] < 60;

/// The segment colour of frame [k] (cuts at 31 and 61).
bool Function(List<int>) _segment(int k) => k < 31 ? _isRed : (k < 61 ? _isGreen : _isBlue);

Future<T> _within<T>(Future<T> f, [int seconds = 30]) => f.timeout(Duration(seconds: seconds));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;

  setUp(() {
    base = Directory.systemTemp.createTempSync('danaview_ios_preview_it');
  });

  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  testWidgets('iOS preview session: first frame, exact seeks around cuts, seq, scrubs, paused edits, quality, dispose',
      (tester) async {
    if (!Platform.isIOS) return;
    final engine = createExampleEngine(base: base);
    final caps = await _within(engine.capabilities());
    if (!caps.supported) {
      debugPrint('IOS11 engine not supported here (${caps.unsupportedReason}); skipping');
      return;
    }
    final session = await _within(engine.openPreview(
        const PreviewConfig(canvasWidth: _w, canvasHeight: _h, fps: _fps, quality: PreviewQuality.full, useProxies: false)));
    final events = <PreviewEvent>[];
    final clocks = <PreviewClock>[];
    final eventSub = session.events.listen(events.add);
    final clockSub = session.clock.listen(clocks.add);
    try {
      expect(session.textureId, greaterThanOrEqualTo(0));

      // ---- first frame ----
      final sw = Stopwatch()..start();
      final ack1 = await _within(session.setPlan(_plan()));
      expect(ack1.rev, 1);
      expect(ack1.structural, isTrue);
      for (var i = 0; i < 300 && !events.any((e) => e is PreviewFirstFrame); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(events.whereType<PreviewFirstFrame>(), isNotEmpty);
      expect(session.frameSize.value?.width, _w);
      expect(session.frameSize.value?.height, _h);
      debugPrint('IOS11 setPlan -> firstFrame ${sw.elapsedMilliseconds} ms, ack applyMs ${ack1.applyMs} (simulator)');

      var frame = await _within(session.debugCaptureFrame());
      expect(frame.length, _w * _h * 4);
      expect(_isRed(_px(frame, _w, 300, 20)), isTrue, reason: 'segment A');
      expect(_isWhite(_px(frame, _w, 60, 60)), isTrue, reason: 'box');
      expect(_isYellow(_px(frame, _w, _markerX(0).floor(), 150)), isTrue, reason: 'marker at frame 0');

      // ---- exact seeks: 200, every frame around both cuts, the marker and segment colour of k ----
      final frames = <int>[
        for (final c in [31, 61]) ...[for (var k = c - 4; k <= c + 4; k++) k],
        0, 89,
      ];
      var x = 0x1011;
      while (frames.length < 200) {
        x = (x * 1103515245 + 12345) & 0x7fffffff;
        frames.add(x % _frames);
      }
      var lastSeq = -1;
      var wrong = 0;
      final ackMs = <int>[];
      for (var i = 0; i < frames.length; i++) {
        final k = frames[i];
        final t = _timeOfFrame(k) + (i.isOdd ? 20000 : 0);
        final s = Stopwatch()..start();
        final ack = await _within(session.seek(t));
        ackMs.add(s.elapsedMilliseconds);
        expect(ack.requested, t);
        expect(ack.seq, greaterThan(lastSeq));
        lastSeq = ack.seq;
        expect(ack.displayedFrameTime, _timeOfFrame(ack.displayedFrame));
        frame = await session.debugCaptureFrame();
        final ok = ack.displayedFrame == k &&
            _isYellow(_px(frame, _w, _markerX(k).floor(), 150)) &&
            _segment(k)(_px(frame, _w, 300, 20));
        if (!ok) wrong++;
      }
      ackMs.sort();
      debugPrint('IOS11 exact seeks ${200 - wrong}/200, p50 ${ackMs[100]} ms, p95 ${ackMs[190]} ms (incl. channel; simulator)');
      expect(wrong, 0);

      // ---- scrubs: coalesced; each ack reports a displayed frame ----
      final scrubs = [for (var k = 10; k < 40; k += 3) session.seek(_timeOfFrame(k), kind: SeekKind.scrub)];
      final scrubAcks = await _within(Future.wait(scrubs));
      for (final a in scrubAcks) {
        expect(a.displayedFrame, inInclusiveRange(0, _frames - 1));
        expect(a.displayedFrameTime, _timeOfFrame(a.displayedFrame));
      }
      final settle = await _within(session.seek(_timeOfFrame(20)));
      expect(settle.displayedFrame, 20);

      // ---- param patch while paused ----
      final moved = await _within(session.applyPatch(_patch(1, upsert: [_boxLayer(260)])));
      expect(moved.rev, 2);
      expect(moved.structural, isFalse);
      frame = await session.debugCaptureFrame();
      expect(_isWhite(_px(frame, _w, 260, 60)), isTrue);
      expect(_isRed(_px(frame, _w, 60, 60)), isTrue);
      debugPrint('IOS11 param patch ack applyMs ${moved.applyMs} (simulator)');

      // ---- transient, then clear ----
      final t0 = Stopwatch()..start();
      session.setTransient(_typed('it_box'), _transient({'cx': 160, 'cy': 60}));
      var transientShown = false;
      for (var i = 0; i < 200 && !transientShown; i++) {
        frame = await session.debugCaptureFrame();
        transientShown = _isWhite(_px(frame, _w, 160, 60)) && _isRed(_px(frame, _w, 260, 60));
      }
      expect(transientShown, isTrue);
      debugPrint('IOS11 transient -> captured frame ${t0.elapsedMilliseconds} ms (incl. Dart coalescing and capture round trips; simulator)');
      session.clearTransient(_typed('it_box'));
      var cleared = false;
      for (var i = 0; i < 200 && !cleared; i++) {
        frame = await session.debugCaptureFrame();
        cleared = _isWhite(_px(frame, _w, 260, 60)) && _isRed(_px(frame, _w, 160, 60));
      }
      expect(cleared, isTrue);

      // ---- structural patch while paused ----
      final added = await _within(session.applyPatch(_patch(2, upsert: [
        _solid('it_new#v', 15, '#FF00FFFF', [30, 30], {'cx': 160, 'cy': 120}),
      ])));
      expect(added.structural, isTrue);
      expect(added.rev, 3);
      frame = await session.debugCaptureFrame();
      final magenta = _px(frame, _w, 160, 120);
      expect(magenta[0] > 200 && magenta[1] < 60 && magenta[2] > 200, isTrue);
      expect(_isYellow(_px(frame, _w, _markerX(20).floor(), 150)), isTrue, reason: 'still frame 20 after the rebuild');
      debugPrint('IOS11 paused structural patch ack applyMs ${added.applyMs} (simulator)');

      // ---- planOutOfSync surfaces as EngineFailure ----
      await expectLater(session.applyPatch(_patch(1, upsert: [_boxLayer(100)])),
          throwsA(isA<EngineFailure>().having((f) => f.code, 'code', EngineErrorCode.planOutOfSync)));

      // ---- seq: play, pause and seek replies and clock samples ----
      clocks.clear();
      await _within(session.play());
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _within(session.pause());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(clocks, isNotEmpty);
      expect(clocks.any((c) => c.playing), isTrue);
      for (var i = 1; i < clocks.length; i++) {
        expect(clocks[i].seq, greaterThanOrEqualTo(clocks[i - 1].seq));
      }
      final last = clocks.last;
      expect(last.playing, isFalse);
      expect(last.seq, greaterThan(settle.seq));
      expect(last.time, greaterThan(_timeOfFrame(20)), reason: 'playback advanced');
      expect(last.time, _timeOfFrame((last.time * _fps) ~/ 1000000));

      // ---- pinned quality: half size texture ----
      await _within(session.setQuality(PreviewQuality.half));
      for (var i = 0; i < 200 && session.frameSize.value?.width != _w / 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(session.frameSize.value?.width, _w / 2);
      expect(session.frameSize.value?.height, _h / 2);
      await _within(session.refresh());
      frame = await session.debugCaptureFrame();
      expect(frame.length, (_w ~/ 2) * (_h ~/ 2) * 4);
      expect(events.whereType<PreviewDegraded>(), isEmpty, reason: 'a pinned quality is never changed by the governor');

      expect(events.whereType<PreviewFailedEvent>(), isEmpty);
    } finally {
      await eventSub.cancel();
      await clockSub.cancel();
      await session.dispose();
    }
    // Dispose released the session: calls after dispose fail with EngineCancelled.
    await expectLater(session.play(), throwsA(isA<EngineCancelled>()));
  });
}
