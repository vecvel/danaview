// OWNER: CORE-29
//
// Benchmark gate: encoding a 2,000-layer plan takes at most 40 ms inside Isolate.run (the plan is
// built, encoded and measured inside the isolate, where the engine transport encodes it).

import 'dart:isolate';

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

/// A realistic 2,000-layer plan: media layers with 1–3 map segments, keyframed opacity and
/// transforms, some effects, plus audio segments.
RenderPlan buildPlan(int layerCount) {
  const rate = FrameRate.fps30;
  final layers = <PlanLayer>[];
  final audio = <AudioSeg>[];
  final assets = <String, PlanAsset>{
    for (var a = 0; a < 20; a++) 'md_$a': PlanAsset(kind: PlanAssetKind.video, uri: 'file:///media/clip_$a.mp4', fp: 'hash$a', w: 1920, h: 1080, durUs: 600000000, hasAudio: true),
    'lt_a': const PlanAsset(kind: PlanAssetKind.lut, uri: 'file:///looks/a.vlut', n: 33),
  };
  for (var i = 0; i < layerCount; i++) {
    final lane = i % 4;
    final startFrame = (i ~/ 4) * 30;
    final t0 = rate.timeOfFrame(startFrame);
    final t1 = rate.timeOfFrame(startFrame + 30);
    final mid = rate.timeOfFrame(startFrame + 15);
    layers.add(PlanLayer(
      id: 'it_${i.toString().padLeft(10, '0')}#v',
      z: const [10, 20, 10010, 10020][lane],
      seq: lane,
      t0: t0,
      t1: t1,
      kind: PlanLayerKind.media,
      asset: 'md_${i % 20}',
      map: i % 3 == 0 ? [MapSegment(t0, mid, i * 1000, i * 1000 + (mid - t0)), MapSegment(mid, t1, i * 1000 + (mid - t0), i * 1000 + (t1 - t0) * 2)] : [MapSegment(t0, t1, i * 1000, i * 1000 + (t1 - t0))],
      base: const PlanSize(1920, 1080),
      xf: i % 2 == 0 ? PlanTransform(cx: 960 + i % 300, cy: 540, s: 0.9 + (i % 10) / 100, op: 0.95) : PlanTransform.identity,
      fx: i % 5 == 0 ? const PlanEffects(adj: PlanAdjust(contrast: 0.2, saturation: -0.1), lut: PlanLut('lt_a', 0.5)) : PlanEffects.none,
      anim: i % 4 == 1 ? {'xf.op': [AnimKey(t0, 0), AnimKey(mid, 1), AnimKey(t1, 0.4)], 'xf.s': [AnimKey(t0, 1), AnimKey(t1, 1.2)]} : const {},
    ));
    if (i % 2 == 0) {
      audio.add(AudioSeg(
        id: 'it_${i.toString().padLeft(10, '0')}#a',
        asset: 'md_${i % 20}',
        t0: t0,
        t1: t1,
        map: [MapSegment(t0, t1, i * 1000, i * 1000 + (t1 - t0))],
        gain: [AnimKey(t0, 1), AnimKey(t1, 0.8)],
      ));
    }
  }
  layers.sort((a, b) {
    if (a.z != b.z) return a.z.compareTo(b.z);
    if (a.t0 != b.t0) return a.t0.compareTo(b.t0);
    return a.id.compareTo(b.id);
  });
  audio.sort((a, b) => a.t0 != b.t0 ? a.t0.compareTo(b.t0) : a.id.compareTo(b.id));
  return RenderPlan(rev: 1, target: PlanTarget.preview, canvas: const PlanCanvas(w: 1920, h: 1080, fps: 30), durUs: rate.timeOfFrame((layerCount ~/ 4) * 30), assets: assets, layers: layers, audio: audio);
}

/// Runs inside the isolate: builds the plan, warms up, then returns (bytes, median µs of 15 runs).
({int bytes, int medianUs, int firstUs}) measure(int layerCount) {
  final plan = buildPlan(layerCount);
  final sw = Stopwatch();
  var bytes = 0;
  final times = <int>[];
  int? first;
  for (var i = 0; i < 16; i++) {
    sw
      ..reset()
      ..start();
    bytes = PlanJson.encodePlanBytes(plan).length;
    sw.stop();
    first ??= sw.elapsedMicroseconds;
    if (i > 0) times.add(sw.elapsedMicroseconds);
  }
  times.sort();
  return (bytes: bytes, medianUs: times[times.length ~/ 2], firstUs: first!);
}

void main() {
  test('the benchmark plan is valid', () {
    final plan = buildPlan(2000);
    expect(plan.layers, hasLength(2000));
    expect(PlanValidator.validate(plan), isEmpty);
  });

  test('encode of a 2,000-layer plan takes at most 40 ms in Isolate.run (median of 15 warm runs; first cold run reported)', () async {
    final r = await Isolate.run(() => measure(2000));
    // ignore: avoid_print
    print('encode 2000 layers: ${r.bytes} bytes, cold ${(r.firstUs / 1000).toStringAsFixed(1)} ms, warm median ${(r.medianUs / 1000).toStringAsFixed(1)} ms');
    expect(r.medianUs, lessThanOrEqualTo(40000));
    // The cold run includes JIT compilation, which the AOT-compiled app does not pay (measured
    // with `dart compile exe`: cold 10–24 ms, warm 8 ms); this bound only catches regressions.
    expect(r.firstUs, lessThanOrEqualTo(250000));
  });

  test('the encoded 2,000-layer plan decodes back equal', () {
    final plan = buildPlan(2000);
    expect(PlanJson.decodePlanBytes(PlanJson.encodePlanBytes(plan)), plan);
  });
}
