// OWNER: CORE-07
//
// evaluateTextAnimation (ARCH §6.6): ease-out cubic sampled at 6 linear segments, values exact at
// the breakpoints and linear between them (so the compiler's linear plan channels reproduce it),
// fade/slide/scale/typewriter, out mirrors in, overlapping phases clamp, typewriter counts
// grapheme clusters.

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

const FrameRate rate = FrameRate.fps30;
TimeUs f(int k) => rate.timeOfFrame(k);
const CanvasSpec canvas = CanvasSpec(); // 1920×1080, slide distance 108 px

TextItem item({
  TextAnimKind inKind = TextAnimKind.none,
  int inFrames = 0,
  TextSlideDirection inDirection = TextSlideDirection.up,
  TextAnimKind outKind = TextAnimKind.none,
  int outFrames = 0,
  TextSlideDirection outDirection = TextSlideDirection.down,
  int startFrame = 30,
  int frames = 90,
  String text = 'Hello',
}) {
  final start = f(startFrame);
  final end = f(startFrame + frames);
  return TextItem(
    id: const ItemId('it_t'),
    start: start,
    duration: end - start,
    text: text,
    animation: TextAnimation(
      inKind: inKind,
      inDirection: inDirection,
      inDuration: f(startFrame + inFrames) - start,
      outKind: outKind,
      outDirection: outDirection,
      outDuration: end - f(startFrame + frames - outFrames),
    ),
  );
}

/// Linear interpolation of [samples] (breakpoint → value) at [t], held outside: what a plan
/// channel does (ARCH §11.1).
double planChannel(List<(TimeUs, double)> samples, TimeUs t) {
  if (t <= samples.first.$1) return samples.first.$2;
  if (t >= samples.last.$1) return samples.last.$2;
  for (var i = 0; i + 1 < samples.length; i++) {
    final (t0, v0) = samples[i];
    final (t1, v1) = samples[i + 1];
    if (t >= t0 && t < t1) return v0 + (v1 - v0) * (t - t0) / (t1 - t0);
  }
  return samples.last.$2;
}

void main() {
  test('the easing samples are 1 − (1 − j/6)³', () {
    for (var j = 0; j <= 6; j++) {
      expect(easeSample(j), closeTo(1 - math.pow(1 - j / 6, 3), 1e-15));
    }
    expect(easeSample(0), 0);
    expect(easeSample(6), 1);
    expect(easeOutCubic(0.5), 0.875);
  });

  test('no animation is the identity', () {
    expect(evaluateTextAnimation(item(), f(40), canvas), TextAnimState.identity);
    expect(textAnimationBreakpoints(item()), isEmpty);
  });

  group('fade in', () {
    final t = item(inKind: TextAnimKind.fade, inFrames: 12);
    final bps = textAnimationBreakpoints(t);

    test('breakpoints: 7 in-samples plus the end', () {
      final s = t.start;
      final d = t.animation.inDuration;
      expect(bps, [for (var j = 0; j <= 6; j++) s + (d * j + 3) ~/ 6, t.end]);
    });

    test('values are exact at the breakpoints', () {
      for (var j = 0; j <= 6; j++) {
        expect(evaluateTextAnimation(t, bps[j], canvas).opacity, easeSample(j));
      }
      expect(evaluateTextAnimation(t, t.end - 1, canvas).opacity, 1);
    });

    test('linear interpolation of the breakpoint values reproduces every time', () {
      final samples = [for (final b in bps) (b, evaluateTextAnimation(t, b, canvas).opacity)];
      for (var x = t.start - 1000; x < t.end; x += 997) {
        expect(evaluateTextAnimation(t, x, canvas).opacity, closeTo(planChannel(samples, x), 1e-12), reason: 'at $x');
      }
    });
  });

  group('slide, scale and out mirror', () {
    test('slide in from the left starts 10% of min(W, H) left and fades in', () {
      final t = item(inKind: TextAnimKind.slide, inFrames: 6, inDirection: TextSlideDirection.left);
      final s0 = evaluateTextAnimation(t, t.start, canvas);
      expect(s0.offset, const Offset2(-108, 0));
      expect(s0.opacity, 0);
      final mid = evaluateTextAnimation(t, t.start + (t.animation.inDuration * 3 + 3) ~/ 6, canvas);
      expect(mid.opacity, easeSample(3));
      expect(mid.offset.dx, closeTo(-108 * (1 - easeSample(3)), 1e-9));
      expect(evaluateTextAnimation(t, t.start + t.animation.inDuration, canvas), TextAnimState.identity);
    });

    test('slide directions are y-down vectors', () {
      for (final (dir, v) in [
        (TextSlideDirection.left, const Offset2(-1, 0)),
        (TextSlideDirection.right, const Offset2(1, 0)),
        (TextSlideDirection.up, const Offset2(0, -1)),
        (TextSlideDirection.down, const Offset2(0, 1)),
      ]) {
        expect(slideVector(dir), v);
        final t = item(inKind: TextAnimKind.slide, inFrames: 6, inDirection: dir);
        expect(evaluateTextAnimation(t, t.start, const CanvasSpec(aspect: AspectRatio.portrait9x16, baseShortSide: 720)).offset, v * 72);
      }
    });

    test('scale in goes 0.6 → 1 with the fade', () {
      final t = item(inKind: TextAnimKind.scale, inFrames: 6);
      expect(evaluateTextAnimation(t, t.start, canvas).scale, 0.6);
      final bps = textAnimationBreakpoints(t);
      for (var j = 0; j <= 6; j++) {
        final s = evaluateTextAnimation(t, bps[j], canvas);
        expect(s.scale, 0.6 + 0.4 * easeSample(j));
        expect(s.opacity, easeSample(j));
      }
    });

    test('out mirrors in: the out curve played backwards from the end', () {
      final inOnly = item(inKind: TextAnimKind.fade, inFrames: 12);
      final outOnly = item(outKind: TextAnimKind.fade, outFrames: 12);
      final inBps = textAnimationBreakpoints(inOnly);
      final outBps = textAnimationBreakpoints(outOnly);
      // Out breakpoints: the item start, then end − round(D·j/6) for j = 6…0.
      expect(outBps.first, outOnly.start);
      expect(outBps.last, outOnly.end);
      for (var j = 0; j <= 6; j++) {
        final tIn = inBps[j] - inOnly.start;
        final tOut = outOnly.end - outBps[outBps.length - 1 - j];
        expect(tOut, tIn, reason: 'mirror sample $j');
        expect(evaluateTextAnimation(outOnly, outBps[outBps.length - 1 - j], canvas).opacity, easeSample(j));
      }
      final slideOut = item(outKind: TextAnimKind.slide, outFrames: 6, outDirection: TextSlideDirection.right);
      expect(evaluateTextAnimation(slideOut, slideOut.end, canvas).offset, const Offset2(108, 0));
      expect(evaluateTextAnimation(slideOut, slideOut.end - slideOut.animation.outDuration, canvas), TextAnimState.identity);
    });

    test('both phases: breakpoints are sorted and unique, channels are piecewise linear', () {
      final t = item(inKind: TextAnimKind.slide, inFrames: 9, outKind: TextAnimKind.scale, outFrames: 15);
      final bps = textAnimationBreakpoints(t);
      expect(bps, [...bps]..sort());
      expect(bps.toSet(), hasLength(bps.length));
      expect(bps, hasLength(14)); // 7 + 7 (the in end and out start are distinct here)
      final op = [for (final b in bps) (b, evaluateTextAnimation(t, b, canvas).opacity)];
      final dy = [for (final b in bps) (b, evaluateTextAnimation(t, b, canvas).offset.dy)];
      final sc = [for (final b in bps) (b, evaluateTextAnimation(t, b, canvas).scale)];
      for (var x = t.start; x < t.end; x += 1301) {
        final s = evaluateTextAnimation(t, x, canvas);
        expect(s.opacity, closeTo(planChannel(op, x), 1e-12));
        expect(s.offset.dy, closeTo(planChannel(dy, x), 1e-9));
        expect(s.scale, closeTo(planChannel(sc, x), 1e-12));
      }
    });

    test('phases longer than the item shrink proportionally and never overlap', () {
      final t = item(inKind: TextAnimKind.fade, inFrames: 60, outKind: TextAnimKind.fade, outFrames: 60, frames: 90);
      final spans = textAnimationSpans(t);
      expect(spans.inDuration + spans.outDuration, t.duration);
      expect(spans.inDuration, t.duration ~/ 2);
      final bps = textAnimationBreakpoints(t);
      expect(bps, [...bps]..sort());
      // Continuous at the seam: fully visible where in ends and out starts.
      expect(evaluateTextAnimation(t, t.start + spans.inDuration, canvas).opacity, 1);
    });
  });

  group('typewriter', () {
    test('reveals floor(n·x) grapheme clusters linearly over the in duration', () {
      final t = item(inKind: TextAnimKind.typewriter, inFrames: 10, text: 'Hello');
      expect(textAnimationBreakpoints(t), [t.start, t.start + t.animation.inDuration, t.end]);
      final d = t.animation.inDuration;
      expect(evaluateTextAnimation(t, t.start, canvas).revealCount, 0);
      final first = (d + 4) ~/ 5; // the first time with n·x ≥ 1
      expect(evaluateTextAnimation(t, t.start + first, canvas).revealCount, 1);
      expect(evaluateTextAnimation(t, t.start + first - 1, canvas).revealCount, 0);
      expect(evaluateTextAnimation(t, t.start + d - 1, canvas).revealCount, 4);
      expect(evaluateTextAnimation(t, t.start + d, canvas).revealCount, 5);
      expect(evaluateTextAnimation(t, t.end - 1, canvas).revealCount, 5);
      // Opacity, offset and scale are untouched; reveal is the continuous plan channel value.
      final mid = evaluateTextAnimation(t, t.start + d ~/ 2, canvas);
      expect(mid.opacity, 1);
      expect(mid.scale, 1);
      expect(mid.reveal, closeTo(2.5, 1e-9));
      // floor of the linear channel 0 → n equals revealCount at every time.
      for (var x = t.start; x <= t.start + d; x += 777) {
        final s = evaluateTextAnimation(t, x, canvas);
        expect(s.revealCount, (5 * (x - t.start) / d).floor());
      }
    });

    test('counts grapheme clusters: emoji ZWJ, flags, combining marks, CJK', () {
      for (final (text, n) in [
        ('👨‍👩‍👧‍👦', 1),
        ('🇯🇵🇫🇷', 2),
        ('été', 3),
        ('東京タワー', 5),
        ('नमस्ते', 3),
        ('a\r\nb', 3),
        ('Hi 👋🏽!', 5),
      ]) {
        expect(textGraphemeCount(text), n, reason: text);
        final t = item(inKind: TextAnimKind.typewriter, inFrames: 6, text: text);
        expect(evaluateTextAnimation(t, t.end - 1, canvas).revealCount, n);
      }
      final family = item(inKind: TextAnimKind.typewriter, inFrames: 6, text: 'ab👨‍👩‍👧‍👦c');
      final d = family.animation.inDuration;
      final third = evaluateTextAnimation(family, family.start + (d * 3 + 3) ~/ 4, canvas).revealCount!;
      expect(third, 3);
      expect(graphemePrefix(family.text, third), 'ab👨‍👩‍👧‍👦');
    });

    test('a typewriter with an out fade keeps every cluster shown while fading', () {
      final t = item(inKind: TextAnimKind.typewriter, inFrames: 6, outKind: TextAnimKind.fade, outFrames: 6);
      final s = evaluateTextAnimation(t, t.end - 1, canvas);
      expect(s.revealCount, 5);
      expect(s.opacity, lessThan(1));
    });

    test('a typewriter out (unsupported) is ignored', () {
      final t = item(outKind: TextAnimKind.typewriter, outFrames: 6);
      expect(evaluateTextAnimation(t, t.end - 1, canvas), TextAnimState.identity);
      expect(textAnimationSpans(t).outDuration, 0);
    });
  });
}
