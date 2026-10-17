// OWNER: AND-10
//
// Android preview session through the real plugin (BUILD_PLAN AND-10, ARCH §12.2, §12.7, §13.3):
// MobileEditorEngine.openPreview -> ENG-02's MobilePreviewSession -> Pigeon -> AND-10's
// PreviewSession on a Flutter SurfaceProducer texture (resetInBackground).
//
//   cd packages/danaview_editor_engine/example
//   flutter test integration_test/android_preview_test.dart -d emulator-5554
//
// The plans hold only solid layers (no media files are needed on the device): a red background, a
// green box moved by patches and transients, and a blue marker whose x position is keyframed over
// time, so the frame on screen identifies the frame index (exact seeks are checked by pixels).
// Until AND-16 lands, playback runs on AND-10's StillFramesBackend (paused-exact stills, no
// audio); its playback criteria (200/200 exact acks around grid cuts, scrub coalescing, A/V
// offset) are re-run when AND-16 lands. Timings printed here are emulator numbers.

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

/// x of the blue marker at frame [k]: keyframes [[0, 10], [3000000, 310]].
double _markerX(int k) => 10 + 300 * _timeOfFrame(k) / 3000000;

Map<String, Object?> _solid(String id, int z, String color, List<num> base, Map<String, Object?> xf, {Map<String, Object?>? anim}) => {
      'id': id,
      'z': z,
      't': [0, _timeOfFrame(_frames)],
      'kind': 'solid',
      'color': color,
      'base': base,
      'xf': xf,
      if (anim != null) 'anim': anim,
    };

Map<String, Object?> _boxLayer(num cx) => _solid('it_box#v', 10, '#00FF00FF', [40, 40], {'cx': cx, 'cy': 60});

RenderPlan _plan() => PlanTransport.decodePlan(Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'rev': 1,
      'target': 'preview',
      'canvas': {'w': _w, 'h': _h, 'fps': _fps, 'bg': '#000000FF'},
      'durUs': _timeOfFrame(_frames),
      'assets': <String, Object?>{},
      'layers': [
        _solid('it_bg#v', 0, '#FF0000FF', [_w, _h], <String, Object?>{}),
        _boxLayer(60),
        _solid('it_mov#v', 20, '#0000FFFF', [20, 20], {'cy': 150}, anim: {
          'xf.cx': [
            [0, 10],
            [3000000, 310],
          ],
        }),
      ],
      'audio': <Object?>[],
    }))));

RenderPlanPatch _patch(int from, List<Map<String, Object?>> upserts) => PlanTransport.decodePatch(Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'from': from,
      'to': from + 1,
      'layers': {'upsert': upserts},
    }))));

PlanTransient _transient(Map<String, Object?> xf) => PlanTransport.decodeTransient(Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'item': 'it_box',
      'layers': [
        {'id': 'it_box#v', 'xf': xf},
      ],
    }))));

/// RGBA of pixel (x, y) of a top-down frame [width] wide.
List<int> _px(Uint8List rgba, int width, int x, int y) {
  final i = (y * width + x) * 4;
  return [rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]];
}

/// [value] typed as whatever the call site expects (core's `ItemId` extension type over String,
/// which the example cannot name: it depends on core only through the engine API).
T _typed<T>(Object value) => value as T;

bool _isRed(List<int> p) => p[0] > 200 && p[1] < 60 && p[2] < 60;
bool _isGreen(List<int> p) => p[1] > 200 && p[0] < 60 && p[2] < 60;
bool _isBlue(List<int> p) => p[2] > 200 && p[0] < 60 && p[1] < 60;

Future<T> _within<T>(Future<T> f, [int seconds = 30]) => f.timeout(Duration(seconds: seconds));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;

  setUp(() {
    base = Directory.systemTemp.createTempSync('danaview_preview_it');
  });

  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  testWidgets('preview session on Android: frames, paused edits, seq, seeks, quality, dispose', (tester) async {
    if (!Platform.isAndroid) return;
    final engine = createExampleEngine(base: base);
    final session = await _within(engine.openPreview(const PreviewConfig(canvasWidth: _w, canvasHeight: _h, fps: _fps, quality: PreviewQuality.full, useProxies: false)));
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
      debugPrint('AND10 setPlan -> firstFrame ${sw.elapsedMilliseconds} ms, ack applyMs ${ack1.applyMs} (emulator)');

      var frame = await _within(session.debugCaptureFrame());
      expect(frame.length, _w * _h * 4);
      expect(_isRed(_px(frame, _w, 300, 20)), isTrue, reason: 'background');
      expect(_isGreen(_px(frame, _w, 60, 60)), isTrue, reason: 'box');
      expect(_isBlue(_px(frame, _w, _markerX(0).round(), 150)), isTrue, reason: 'marker at frame 0');

      // ---- param patch (paused edit through AND-17's PausedFrameRenderer) ----
      final moved = await _within(session.applyPatch(_patch(1, [_boxLayer(260)])));
      expect(moved.rev, 2);
      expect(moved.structural, isFalse);
      frame = await session.debugCaptureFrame();
      expect(_isGreen(_px(frame, _w, 260, 60)), isTrue);
      expect(_isRed(_px(frame, _w, 60, 60)), isTrue);
      debugPrint('AND10 param patch ack applyMs ${moved.applyMs} (emulator)');

      // ---- transient, then clear ----
      final t0 = Stopwatch()..start();
      session.setTransient(_typed('it_box'), _transient({'cx': 160, 'cy': 60}));
      var transientShown = false;
      for (var i = 0; i < 200 && !transientShown; i++) {
        frame = await session.debugCaptureFrame();
        transientShown = _isGreen(_px(frame, _w, 160, 60)) && _isRed(_px(frame, _w, 260, 60));
      }
      expect(transientShown, isTrue);
      debugPrint('AND10 transient -> captured frame ${t0.elapsedMilliseconds} ms (includes capture round trips; emulator)');
      session.clearTransient(_typed('it_box'));
      var cleared = false;
      for (var i = 0; i < 200 && !cleared; i++) {
        frame = await session.debugCaptureFrame();
        cleared = _isGreen(_px(frame, _w, 260, 60)) && _isRed(_px(frame, _w, 160, 60));
      }
      expect(cleared, isTrue);

      // ---- structural patch ----
      final added = await _within(session.applyPatch(_patch(2, [
        _solid('it_new#v', 15, '#FFFFFFFF', [30, 30], {'cx': 160, 'cy': 120}),
      ])));
      expect(added.structural, isTrue);
      expect(added.rev, 3);
      frame = await session.debugCaptureFrame();
      final white = _px(frame, _w, 160, 120);
      expect(white[0] > 200 && white[1] > 200 && white[2] > 200, isTrue);
      debugPrint('AND10 paused structural patch ack applyMs ${added.applyMs} (emulator)');

      // ---- planOutOfSync surfaces as EngineFailure ----
      await expectLater(session.applyPatch(_patch(1, [_boxLayer(100)])), throwsA(isA<EngineFailure>().having((f) => f.code, 'code', EngineErrorCode.planOutOfSync)));

      // ---- exact seeks: the marker sits where frame k puts it ----
      var lastSeq = -1;
      for (final k in [45, 0, 89, 1, 30, 31, 60, 59, 15, 74]) {
        final t = _timeOfFrame(k) + (k.isEven ? 0 : 20000);
        final ack = await _within(session.seek(t));
        expect(ack.displayedFrame, k, reason: 'seek $t');
        expect(ack.displayedFrameTime, _timeOfFrame(k));
        expect(ack.requested, t);
        expect(ack.seq, greaterThan(lastSeq));
        lastSeq = ack.seq;
        frame = await session.debugCaptureFrame();
        expect(_isBlue(_px(frame, _w, _markerX(k).round(), 150)), isTrue, reason: 'marker of frame $k');
      }

      // ---- scrubs: coalesced; each ack reports a displayed frame ----
      final scrubs = [for (var k = 10; k < 40; k += 3) session.seek(_timeOfFrame(k), kind: SeekKind.scrub)];
      final scrubAcks = await _within(Future.wait(scrubs));
      for (final a in scrubAcks) {
        expect(a.displayedFrame, inInclusiveRange(0, _frames - 1));
        expect(a.displayedFrameTime, _timeOfFrame(a.displayedFrame));
      }
      final settle = await _within(session.seek(_timeOfFrame(20)));
      expect(settle.displayedFrame, 20);

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
      expect(last.time, _timeOfFrame((last.time * _fps) ~/ 1000000));

      // ---- quality: half size texture ----
      await _within(session.setQuality(PreviewQuality.half));
      for (var i = 0; i < 200 && session.frameSize.value?.width != _w / 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(session.frameSize.value?.width, _w / 2);
      expect(session.frameSize.value?.height, _h / 2);
      await _within(session.refresh());
      frame = await session.debugCaptureFrame();
      expect(frame.length, (_w ~/ 2) * (_h ~/ 2) * 4);

      expect(events.whereType<PreviewFailedEvent>(), isEmpty);
    } finally {
      await eventSub.cancel();
      await clockSub.cancel();
      await session.dispose();
    }
    // Calls after dispose fail with EngineCancelled.
    await expectLater(session.play(), throwsA(isA<EngineCancelled>()));
  });
}
