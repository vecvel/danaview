// OWNER: CORE-05
//
// Keyframe operations: shift (start trim), scale (speed change), partition at a split with
// boundary keys, set/remove/move for scalar and Vec2 properties, non-keyframable rejection.

import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../model/core/model_fixtures.dart';

KeyframeTrack _track(List<(TimeUs, double)> keys) => KeyframeTrack([for (final (t, v) in keys) Keyframe(t, v)]);

MediaClip _clipWith(int frames, Map<String, KeyframeTrack> keys) => MediaClip(
      id: const ItemId('it_k'),
      start: 0,
      duration: f(frames),
      media: const MediaId('md_a'),
      visual: VisualProps.neutral,
      keyframes: KeyframeSet(keys),
    );

List<(TimeUs, double)> _pairs(KeyframeSet s, String channel) => [for (final k in s[channel]?.keys ?? <Keyframe>[]) (k.t, k.v)];

void main() {
  group('shift (start trim of Δ shifts by −Δ)', () {
    final set = KeyframeSet({
      'transform.opacity': _track([(f(0), 0.0), (f(30), 1.0), (f(60), 0.5)]),
      'transform.scale': _track([(f(10), 2.0)]),
    });

    test('moves every channel', () {
      final s = KeyframeOps.shift(set, -f(10));
      expect(_pairs(s, 'transform.opacity'), [(-f(10), 0.0), (f(30) - f(10), 1.0), (f(60) - f(10), 0.5)]);
      expect(_pairs(s, 'transform.scale'), [(0, 2.0)]);
    });

    test('is exact under the T − start convention: a key authored at frame T stays at T − newStart', () {
      // An item starting at frame 100 with a key at absolute frame 130; trim the start by 10 frames.
      final start = f(100);
      final keyLocal = f(130) - start;
      final newStart = f(110);
      final shifted = KeyframeOps.shift(KeyframeSet({'transform.opacity': _track([(keyLocal, 1.0)])}), -(newStart - start));
      expect(_pairs(shifted, 'transform.opacity'), [(f(130) - newStart, 1.0)]);
    });

    test('keeps keys that fall before 0 (un-trim restores them)', () {
      final trimmed = KeyframeOps.shift(set, -f(40));
      expect(trimmed['transform.opacity']!.keys, hasLength(3));
      expect(KeyframeOps.shift(trimmed, f(40)), set, reason: 'shift is exactly reversible');
    });

    test('is identity for 0 and for empty sets', () {
      expect(identical(KeyframeOps.shift(set, 0), set), isTrue);
      expect(KeyframeOps.shift(KeyframeSet.empty, 5), KeyframeSet.empty);
    });
  });

  group('scale (speed change scales by oldDuration/newDuration)', () {
    test('2× faster halves key times, snapped to frames', () {
      final set = KeyframeSet({
        'transform.opacity': _track([(f(0), 0.0), (f(31), 1.0), (f(60), 0.5)]),
      });
      final s = KeyframeOps.scale(set, oldDuration: f(60), newDuration: f(30), rate: r30);
      expect(_pairs(s, 'transform.opacity'), [(f(0), 0.0), (r30.quantizeNearest((f(31) * 0.5).round()), 1.0), (f(30), 0.5)]);
      expect(s['transform.opacity']!.keys[1].t, f(16), reason: '15.5 frames rounds up to frame 16');
      for (final k in s['transform.opacity']!.keys) {
        expect(r30.isOnGrid(k.t), isTrue);
      }
    });

    test('keys keep their position relative to the content', () {
      final set = KeyframeSet({'transform.scale': _track([(f(20), 1.0), (f(40), 2.0)])});
      final slow = KeyframeOps.scale(set, oldDuration: f(60), newDuration: f(120), rate: r30);
      expect(_pairs(slow, 'transform.scale'), [(f(40), 1.0), (f(80), 2.0)]);
      expect(slow['transform.scale']!.keys.map((k) => r30.isOnGrid(k.t)), everyElement(isTrue));
      final back = KeyframeOps.scale(slow, oldDuration: f(120), newDuration: f(60), rate: r30);
      expect(back, set);
    });

    test('keys that collapse onto one frame keep the later value', () {
      final set = KeyframeSet({'transform.opacity': _track([(f(10), 0.1), (f(11), 0.2), (f(12), 0.3), (f(100), 1.0)])});
      final s = KeyframeOps.scale(set, oldDuration: f(100), newDuration: f(10), rate: r30);
      final keys = s['transform.opacity']!.keys;
      expect(keys.map((k) => k.t), [f(1), f(10)]);
      expect(keys.first.v, 0.3);
      for (var i = 1; i < keys.length; i++) {
        expect(keys[i].t, greaterThan(keys[i - 1].t), reason: 'sorted and unique');
      }
    });

    test('with itemStart the new key times are start-relative frame times', () {
      final start = f(100);
      final set = KeyframeSet({'transform.opacity': _track([(f(120) - start, 0.5)])});
      final s = KeyframeOps.scale(set, oldDuration: f(60), newDuration: f(120), rate: r30, itemStart: start);
      expect(s['transform.opacity']!.keys.single.t, f(140) - start, reason: '20 frames in becomes 40 frames in');
    });

    test('out-of-range keys scale as well; equal durations are identity; bad durations throw', () {
      final set = KeyframeSet({'transform.opacity': _track([(-f(10), 0.1), (f(5), 0.2)])});
      final s = KeyframeOps.scale(set, oldDuration: f(30), newDuration: f(60), rate: r30);
      expect(s['transform.opacity']!.keys.map((k) => r30.frameIndexNearest(k.t)), [-20, 10]);
      expect(identical(KeyframeOps.scale(set, oldDuration: 5, newDuration: 5, rate: r30), set), isTrue);
      expect(() => KeyframeOps.scale(set, oldDuration: 0, newDuration: 5, rate: r30), throwsArgumentError);
      expect(() => KeyframeOps.scale(set, oldDuration: 5, newDuration: -1, rate: r30), throwsArgumentError);
    });
  });

  group('partition', () {
    test('a simple fade: both halves evaluate like the original at every frame', () {
      final item = _clipWith(100, {'transform.opacity': _track([(0, 0.0), (f(100) - f(1), 1.0)])});
      _expectPartitionMatches(item, f(40));
    });

    test('boundary keys appear exactly where needed', () {
      final item = _clipWith(100, {'transform.opacity': _track([(f(0), 0.0), (f(90), 1.0)])});
      final p = KeyframeOps.partition(item.keyframes, at: f(40), duration: item.duration, rate: r30);
      final left = p.left['transform.opacity']!.keys;
      expect(left.map((k) => k.t), [f(0), f(39)]);
      expect(left.last.v, closeTo(f(39) / f(90), 1e-12));
      final right = _pairs(p.right, 'transform.opacity');
      expect(right.first.$1, 0, reason: 'boundary at the cut');
      expect(right.first.$2, closeTo(f(40) / f(90), 1e-12));
      expect(right.last, (f(90) - f(40), 1.0));
    });

    test('no boundary is added where the original already holds', () {
      final item = _clipWith(100, {'transform.opacity': _track([(f(0), 0.2), (f(10), 0.8)])});
      final p = KeyframeOps.partition(item.keyframes, at: f(40), duration: item.duration, rate: r30);
      expect(_pairs(p.left, 'transform.opacity'), [(f(0), 0.2), (f(10), 0.8)], reason: 'nothing continues past the cut');
      final right = _pairs(p.right, 'transform.opacity');
      expect(right, [(0, 0.8)], reason: 'the right half holds the last value from frame 0');
      _expectPartitionMatches(item, f(40));
    });

    test('keys all before or all after the cut', () {
      final allAfter = _clipWith(100, {'transform.opacity': _track([(f(60), 0.3), (f(80), 0.9)])});
      final p = KeyframeOps.partition(allAfter.keyframes, at: f(40), duration: allAfter.duration, rate: r30);
      expect(_pairs(p.left, 'transform.opacity'), [(f(39), 0.3)], reason: 'constant at the first key value');
      expect(_pairs(p.right, 'transform.opacity'), [(f(60) - f(40), 0.3), (f(80) - f(40), 0.9)]);
      _expectPartitionMatches(allAfter, f(40));
      _expectPartitionMatches(allAfter, f(70));
    });

    test('a key exactly on the cut goes right at 0 without an extra boundary', () {
      final item = _clipWith(100, {'transform.opacity': _track([(f(0), 0.0), (f(40), 0.5), (f(80), 1.0)])});
      final p = KeyframeOps.partition(item.keyframes, at: f(40), duration: item.duration, rate: r30);
      expect(_pairs(p.right, 'transform.opacity').first, (0, 0.5));
      expect(_pairs(p.right, 'transform.opacity'), hasLength(2));
      _expectPartitionMatches(item, f(40));
    });

    test('Vec2 and several channels partition together', () {
      final item = _clipWith(100, {
        'transform.position.x': _track([(0, -1.0), (f(80), 1.0)]),
        'transform.position.y': _track([(f(10), 0.0), (f(60), 1.0)]),
        'adjust.exposure': _track([(f(50), 0.5)]),
      });
      _expectPartitionMatches(item, f(30));
      _expectPartitionMatches(item, f(65));
    });

    test('keys outside the range stay on their side and never change evaluation', () {
      final item = _clipWith(100, {
        'transform.opacity': _track([(-f(10), 5.0), (f(10), 0.0), (f(90), 1.0), (f(120), -7.0)]),
      });
      final p = KeyframeOps.partition(item.keyframes, at: f(50), duration: item.duration, rate: r30);
      expect(p.left['transform.opacity']!.keys.first, Keyframe(-f(10), 5.0), reason: 'kept left');
      expect(p.right['transform.opacity']!.keys.last, Keyframe(f(120) - f(50), -7.0), reason: 'kept right, shifted');
      _expectPartitionMatches(item, f(50));
    });

    test('empty sets and invalid cut times', () {
      final p = KeyframeOps.partition(KeyframeSet.empty, at: 5, duration: 10, rate: r30);
      expect(p.left.isEmpty && p.right.isEmpty, isTrue);
      final set = KeyframeSet({'transform.opacity': _track([(0, 1.0)])});
      expect(() => KeyframeOps.partition(set, at: 0, duration: 10, rate: r30), throwsRangeError);
      expect(() => KeyframeOps.partition(set, at: 10, duration: 10, rate: r30), throwsRangeError);
    });

    test('property test: random keys, random cuts, every frame of both halves matches the original', () {
      final rnd = Random(5);
      for (var trial = 0; trial < 400; trial++) {
        final frames = 20 + rnd.nextInt(200);
        final channels = <String, KeyframeTrack>{};
        for (final ch in ['transform.opacity', 'transform.position.x', 'adjust.exposure']) {
          if (rnd.nextInt(4) == 0) continue;
          final times = <int>{};
          final n = 1 + rnd.nextInt(6);
          for (var i = 0; i < n; i++) {
            // Mostly in range, sometimes outside.
            times.add(rnd.nextInt(10) == 0 ? (rnd.nextBool() ? -1 - rnd.nextInt(30) : frames + rnd.nextInt(30)) : rnd.nextInt(frames));
          }
          final sorted = times.toList()..sort();
          channels[ch] = KeyframeTrack([for (final k in sorted) Keyframe(f(k), rnd.nextDouble() * 2 - 1)]);
        }
        final item = _clipWith(frames, channels);
        final at = 1 + rnd.nextInt(frames - 1);
        _expectPartitionMatches(item, f(at));
      }
    });
  });

  test('partition property test with a non-zero item start (T − start convention): both halves match at every frame', () {
    final rnd = Random(6);
    for (var trial = 0; trial < 300; trial++) {
      final startFrame = rnd.nextInt(500);
      final start = f(startFrame);
      final frames = 20 + rnd.nextInt(150);
      TimeUs local(int frame) => f(startFrame + frame) - start;
      final channels = <String, KeyframeTrack>{};
      for (final ch in ['transform.opacity', 'adjust.exposure']) {
        final frameSet = <int>{for (var i = 0; i < 1 + rnd.nextInt(5); i++) rnd.nextInt(frames)};
        final sorted = frameSet.toList()..sort();
        channels[ch] = KeyframeTrack([for (final k in sorted) Keyframe(local(k), rnd.nextDouble())]);
      }
      final item = MediaClip(
        id: const ItemId('it_k'),
        start: start,
        duration: f(startFrame + frames) - start,
        media: const MediaId('md_a'),
        visual: VisualProps.neutral,
        keyframes: KeyframeSet(channels),
      );
      final cut = 1 + rnd.nextInt(frames - 1);
      final at = local(cut);
      final p = KeyframeOps.partition(item.keyframes, at: at, duration: item.duration, rate: r30, itemStart: start);
      final left = item.copyWith(duration: at, keyframes: p.left);
      final right = item.copyWith(start: f(startFrame + cut), duration: item.duration - at, keyframes: p.right);
      for (var k = 0; k < frames; k++) {
        for (final key in [PropertyKeys.opacity, PropertyKeys.exposure]) {
          final original = evaluate(item, key, local(k));
          if (k < cut) {
            // Evaluate the left half at the same local time; tolerance covers the 1 µs grid skew.
            expect(evaluate(left, key, local(k)), closeTo(original, 1e-5), reason: 'trial $trial left $k');
          } else {
            final t = f(startFrame + k) - right.start;
            expect(evaluate(right, key, t), closeTo(original, 1e-5), reason: 'trial $trial right $k');
          }
        }
      }
    }
  });

  group('set / remove / move / clear', () {
    final opacity = PropertyKeys.opacity;
    final position = PropertyKeys.position;

    test('setKey writes one channel for scalars and both for Vec2 at the same t', () {
      var s = KeyframeOps.setKey(KeyframeSet.empty, opacity, f(10), 0.5);
      expect(_pairs(s, 'transform.opacity'), [(f(10), 0.5)]);
      s = KeyframeOps.setKey(s, position, f(20), const Vec2(0.1, -0.2));
      expect(_pairs(s, 'transform.position.x'), [(f(20), 0.1)]);
      expect(_pairs(s, 'transform.position.y'), [(f(20), -0.2)]);
      s = KeyframeOps.setKey(s, position, f(5), const Vec2(0.0, 0.0));
      expect(_pairs(s, 'transform.position.x'), [(f(5), 0.0), (f(20), 0.1)], reason: 'sorted');
    });

    test('setKey replaces a key at the same time and keeps tracks sorted and unique', () {
      var s = KeyframeSet.empty;
      for (final t in [f(30), f(10), f(20), f(10), f(30)]) {
        s = KeyframeOps.setKey(s, opacity, t, t / 1e6);
      }
      final keys = s['transform.opacity']!.keys;
      expect(keys.map((k) => k.t), [f(10), f(20), f(30)]);
    });

    test('setKey rejects non-keyframable keys and wrong value types', () {
      expect(() => KeyframeOps.setKey(KeyframeSet.empty, PropertyKeys.chromaSpill, 0, 0.5), throwsArgumentError);
      expect(() => KeyframeOps.setKey(KeyframeSet.empty, PropertyKeys.flipH, 0, true), throwsArgumentError);
      expect(() => KeyframeOps.setKey(KeyframeSet.empty, PropertyKeys.fontSize, 0, 40.0), throwsArgumentError);
      expect(() => KeyframeOps.setKey(KeyframeSet.empty, position, 0, 0.5), throwsArgumentError);
      expect(() => KeyframeOps.setKey(KeyframeSet.empty, opacity, 0, const Vec2(0, 0)), throwsArgumentError);
    });

    test('removeKey drops emptied channels and ignores missing keys', () {
      var s = KeyframeOps.setKey(KeyframeSet.empty, position, f(10), const Vec2(1, 2));
      s = KeyframeOps.setKey(s, position, f(20), const Vec2(3, 4));
      expect(KeyframeOps.removeKey(s, position, f(99)), s);
      final one = KeyframeOps.removeKey(s, position, f(10));
      expect(_pairs(one, 'transform.position.y'), [(f(20), 4.0)]);
      final none = KeyframeOps.removeKey(one, position, f(20));
      expect(none.isEmpty, isTrue, reason: 'the last remove makes the property static again');
      expect(() => KeyframeOps.removeKey(s, PropertyKeys.flipH, 0), throwsArgumentError);
    });

    test('moveKey moves both channels and replaces a key at the target', () {
      var s = KeyframeOps.setKey(KeyframeSet.empty, position, f(10), const Vec2(1, 2));
      s = KeyframeOps.setKey(s, position, f(30), const Vec2(5, 6));
      final m = KeyframeOps.moveKey(s, position, f(10), f(40));
      expect(_pairs(m, 'transform.position.x'), [(f(30), 5.0), (f(40), 1.0)]);
      expect(_pairs(m, 'transform.position.y'), [(f(30), 6.0), (f(40), 2.0)]);
      final over = KeyframeOps.moveKey(s, position, f(10), f(30));
      expect(_pairs(over, 'transform.position.x'), [(f(30), 1.0)]);
      expect(() => KeyframeOps.moveKey(s, position, f(11), f(12)), throwsStateError);
      expect(identical(KeyframeOps.moveKey(s, position, f(10), f(10)), s), isTrue);
    });

    test('clear, isAnimated, hasKeyAt, keyTimes', () {
      var s = KeyframeOps.setKey(KeyframeSet.empty, position, f(10), const Vec2(1, 2));
      s = KeyframeOps.setKey(s, opacity, f(20), 0.5);
      expect(KeyframeOps.isAnimated(s, position), isTrue);
      expect(KeyframeOps.isAnimated(s, PropertyKeys.scale), isFalse);
      expect(KeyframeOps.hasKeyAt(s, position, f(10)), isTrue);
      expect(KeyframeOps.hasKeyAt(s, position, f(11)), isFalse);
      s = KeyframeOps.setKey(s, position, f(30), const Vec2(0, 0));
      expect(KeyframeOps.keyTimes(s, position), [f(10), f(30)]);
      final c = KeyframeOps.clear(s, position);
      expect(KeyframeOps.isAnimated(c, position), isFalse);
      expect(KeyframeOps.isAnimated(c, opacity), isTrue);
      expect(() => KeyframeOps.clear(s, PropertyKeys.crop), throwsArgumentError);
    });

    test('keyframesOf / withKeyframes on clips and text; cues reject', () {
      final set = KeyframeSet({'transform.opacity': _track([(0, 0.5)])});
      final c = withKeyframes(clip('it_a', 0, 3), set);
      expect(keyframesOf(c), set);
      final t = withKeyframes(text('it_t', 0, 3), set);
      expect(keyframesOf(t), set);
      expect(keyframesOf(cue('it_c', 0, 3)).isEmpty, isTrue);
      expect(() => withKeyframes(cue('it_c', 0, 3), set), throwsArgumentError);
    });
  });
}

/// Splits [item] at item-local [at] and checks that, at every frame, the left half (frames
/// before the cut) and the right half (frames from the cut) evaluate like the original, for every
/// keyframable property.
void _expectPartitionMatches(MediaClip item, TimeUs at) {
  final p = KeyframeOps.partition(item.keyframes, at: at, duration: item.duration, rate: r30, itemStart: item.start);
  final left = item.copyWith(duration: at, keyframes: p.left);
  final right = item.copyWith(start: item.start + at, duration: item.duration - at, keyframes: p.right);
  final lastFrame = r30.frameIndexOf(item.duration - 1);
  for (final key in <PropertyKey<Object?>>[PropertyKeys.opacity, PropertyKeys.position, PropertyKeys.exposure]) {
    for (var k = 0; k <= lastFrame; k++) {
      final t = f(k);
      final original = evaluate<Object?>(item, key, t);
      if (t < at) {
        _expectEqualValues(evaluate<Object?>(left, key, t), original, '${key.id} left frame $k');
      } else {
        _expectEqualValues(evaluate<Object?>(right, key, t - at), original, '${key.id} right frame $k');
      }
    }
  }
  for (final track in [...p.left.byChannel.values, ...p.right.byChannel.values]) {
    for (var i = 1; i < track.keys.length; i++) {
      expect(track.keys[i].t, greaterThan(track.keys[i - 1].t), reason: 'sorted and unique after partition');
    }
  }
}

void _expectEqualValues(Object? actual, Object? expected, String reason) {
  if (expected is Vec2) {
    final a = actual! as Vec2;
    expect(a.x, closeTo(expected.x, 1e-9), reason: reason);
    expect(a.y, closeTo(expected.y, 1e-9), reason: reason);
  } else {
    expect(actual! as double, closeTo(expected! as double, 1e-9), reason: reason);
  }
}
