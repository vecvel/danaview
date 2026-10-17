// OWNER: CORE-05
//
// evaluate<T>(item, key, t): linear, held outside the first/last key, rotation in plain degrees,
// Vec2 channels, out-of-range keys ignored, static fallback.

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../model/core/model_fixtures.dart';

KeyframeTrack _track(List<(TimeUs, double)> keys) => KeyframeTrack([for (final (t, v) in keys) Keyframe(t, v)]);

MediaClip _clip({int frames = 90, Map<String, KeyframeTrack> keys = const {}, VisualProps? visual}) => MediaClip(
      id: const ItemId('it_k'),
      start: f(10),
      duration: f(frames),
      media: const MediaId('md_a'),
      visual: visual ?? VisualProps.neutral,
      keyframes: KeyframeSet(keys),
    );

void main() {
  group('scalar interpolation', () {
    final item = _clip(keys: {
      'transform.opacity': _track([(f(0), 0.0), (f(30), 1.0), (f(60), 0.25)]),
    });
    double at(TimeUs t) => evaluate(item, PropertyKeys.opacity, t);

    test('is exact at keys', () {
      expect(at(f(0)), 0);
      expect(at(f(30)), 1);
      expect(at(f(60)), 0.25);
    });

    test('is linear between keys', () {
      expect(at(f(15)), closeTo(0.5, 1e-12));
      expect(at(f(45)), closeTo(0.625, 1e-12));
      expect(at(f(30) - 1), closeTo(1 - 1 / f(30), 1e-9));
      for (var k = 0; k <= 30; k++) {
        expect(at(f(k)), closeTo((f(k)) / f(30), 1e-12), reason: 'frame $k of the first segment');
      }
      for (var k = 30; k <= 60; k++) {
        expect(at(f(k)), closeTo(1 + (0.25 - 1) * (f(k) - f(30)) / (f(60) - f(30)), 1e-12));
      }
    });

    test('holds before the first and after the last key', () {
      final held = _clip(keys: {
        'transform.opacity': _track([(f(20), 0.2), (f(40), 0.8)]),
      });
      expect(evaluate(held, PropertyKeys.opacity, 0), 0.2);
      expect(evaluate(held, PropertyKeys.opacity, f(19)), 0.2);
      expect(evaluate(held, PropertyKeys.opacity, f(40)), 0.8);
      expect(evaluate(held, PropertyKeys.opacity, f(89)), 0.8);
      expect(evaluate(held, PropertyKeys.opacity, f(500)), 0.8, reason: 'beyond the item still holds');
      expect(evaluate(held, PropertyKeys.opacity, -f(5)), 0.2);
    });

    test('a single key makes the property constant at that value', () {
      final one = _clip(keys: {
        'transform.scale': _track([(f(50), 3.0)]),
      });
      expect(evaluate(one, PropertyKeys.scale, 0), 3);
      expect(evaluate(one, PropertyKeys.scale, f(89)), 3);
    });

    test('is monotone for monotone keys (binary search finds the right segment)', () {
      final many = _clip(frames: 900, keys: {
        'transform.opacity': _track([for (var i = 0; i < 100; i++) (f(i * 9), i / 99)]),
      });
      var prev = -1.0;
      for (var k = 0; k < 900; k++) {
        final v = evaluate(many, PropertyKeys.opacity, f(k));
        expect(v, greaterThanOrEqualTo(prev));
        expect(v, closeTo(k >= 891 ? 1.0 : k / 891, 1e-4) /* linear overall, held after the last key */, reason: 'frame $k');
        prev = v;
      }
    });
  });

  group('rotation is plain degrees', () {
    test('no shortest-path wrapping', () {
      final item = _clip(keys: {
        'transform.rotation': _track([(0, 350.0), (f(30), -350.0)]),
      });
      expect(evaluate(item, PropertyKeys.rotation, f(15)), closeTo(0, 1e-9), reason: 'goes the long way through 0');
      expect(evaluate(item, PropertyKeys.rotation, f(30)), -350);
      expect(evaluate(item, PropertyKeys.rotation, f(7)), closeTo(350 - 700 * f(7) / f(30), 1e-9));
    });
  });

  group('Vec2 channels', () {
    test('both channels evaluate independently', () {
      final item = _clip(keys: {
        'transform.position.x': _track([(0, -1.0), (f(30), 1.0)]),
        'transform.position.y': _track([(0, 0.5), (f(60), -0.5)]),
      });
      final p = evaluate(item, PropertyKeys.position, f(30));
      expect(p.x, closeTo(1.0, 1e-12));
      expect(p.y, closeTo(0.0, 1e-12));
      final q = evaluate(item, PropertyKeys.position, f(15));
      expect(q.x, closeTo(0.0, 1e-12));
      expect(q.y, closeTo(0.25, 1e-12));
    });

    test('a missing channel keeps the static component', () {
      final item = MediaClip(
        id: const ItemId('it_k'),
        start: 0,
        duration: f(90),
        media: const MediaId('md_a'),
        visual: const VisualProps(transform: Transform2D(position: Vec2(0.3, -0.4))),
        keyframes: KeyframeSet({
          'transform.position.x': _track([(0, 1.0), (f(30), 2.0)]),
        }),
      );
      final p = evaluate(item, PropertyKeys.position, f(15));
      expect(p.x, closeTo(1.5, 1e-12));
      expect(p.y, -0.4);
    });

    test('mask vectors use their own channels', () {
      final item = _clip(keys: {
        'mask.size.x': _track([(0, 0.2), (f(30), 0.6)]),
        'mask.size.y': _track([(0, 0.2), (f(30), 1.0)]),
      });
      final s = evaluate(item, PropertyKeys.maskSize, f(15));
      expect(s.x, closeTo(0.4, 1e-12));
      expect(s.y, closeTo(0.6, 1e-12));
      expect(evaluate(item, PropertyKeys.maskCenter, f(15)), const Vec2(0.5, 0.5), reason: 'no keys: static value');
    });
  });

  group('out-of-range keys are kept and ignored', () {
    final dur = f(60);
    test('keys before 0 and at/after the duration do not affect evaluation', () {
      final inner = _clip(frames: 60, keys: {
        'transform.opacity': _track([(f(10), 0.2), (f(40), 0.8)]),
      });
      final withOutside = _clip(frames: 60, keys: {
        'transform.opacity': _track([(-f(20), 5.0), (f(10), 0.2), (f(40), 0.8), (dur, -9.0), (dur + f(30), 7.0)]),
      });
      for (var k = 0; k < 60; k++) {
        expect(evaluate(withOutside, PropertyKeys.opacity, f(k)), evaluate(inner, PropertyKeys.opacity, f(k)), reason: 'frame $k');
      }
      expect(withOutside.keyframes['transform.opacity']!.keys, hasLength(5), reason: 'kept in the model');
    });

    test('a key exactly at the duration is out of range; one at 0 is in range', () {
      final a = _clip(frames: 60, keys: {'transform.opacity': _track([(0, 0.1), (dur, 0.9)])});
      expect(evaluate(a, PropertyKeys.opacity, f(30)), 0.1, reason: 'only the key at 0 counts, so the value is held');
    });

    test('a channel whose keys are all outside the range yields the static value', () {
      final item = _clip(frames: 60, keys: {'transform.opacity': _track([(-f(5), 0.1), (dur + 1, 0.9)])});
      expect(evaluate(item, PropertyKeys.opacity, f(10)), 1.0);
      expect(isAnimated(item, PropertyKeys.opacity), isTrue, reason: 'keys exist, they are just out of range');
    });

    test('evaluateTrack returns null without in-range keys', () {
      expect(evaluateTrack(_track([(-5, 1.0)]), 0, duration: 100), isNull);
      expect(evaluateTrack(_track([(100, 1.0)]), 0, duration: 100), isNull);
      expect(evaluateTrack(_track([(99, 1.0)]), 0, duration: 100), 1.0);
    });
  });

  group('static fallbacks', () {
    test('no keyframes: the static value', () {
      final item = _clip(visual: const VisualProps(transform: Transform2D(opacity: 0.4)));
      expect(evaluate(item, PropertyKeys.opacity, f(10)), 0.4);
      expect(isAnimated(item, PropertyKeys.opacity), isFalse);
    });

    test('non-keyframable keys ignore any stray channel entries', () {
      final item = _clip(keys: {'chroma.spill': _track([(0, 0.9)])});
      expect(evaluate(item, PropertyKeys.chromaSpill, f(5)), 0.3);
      expect(evaluate(item, PropertyKeys.flipH, f(5)), false);
    });

    test('throws for a key that does not apply', () {
      final audioOnly = MediaClip(id: const ItemId('it_a'), start: 0, duration: 10, media: const MediaId('md_a'));
      expect(() => evaluate(audioOnly, PropertyKeys.opacity, 0), throwsArgumentError);
      expect(() => evaluate(cue('it_c', 0, 3), PropertyKeys.opacity, 0), throwsArgumentError);
    });
  });

  group('audio and text items', () {
    test('volume keyframes up to 2.0', () {
      final item = MediaClip(
        id: const ItemId('it_a'),
        start: 0,
        duration: f(90),
        media: const MediaId('md_a'),
        keyframes: KeyframeSet({'audio.volume': _track([(0, 1.0), (f(30), 2.0), (f(60), 0.0)])}),
      );
      expect(evaluate(item, PropertyKeys.volume, f(15)), closeTo(1.5, 1e-12));
      expect(evaluate(item, PropertyKeys.volume, f(30)), 2.0);
      expect(evaluate(item, PropertyKeys.volume, f(45)), closeTo(1.0, 1e-12));
      expect(evaluate(item, PropertyKeys.volume, f(80)), 0.0);
    });

    test('text items animate position, scale, rotation, opacity', () {
      final item = TextItem(
        id: const ItemId('it_t'),
        start: 0,
        duration: f(90),
        text: 'x',
        keyframes: KeyframeSet({
          'transform.scale': _track([(0, 1.0), (f(30), 2.0)]),
          'transform.position.y': _track([(0, 0.0), (f(30), 0.5)]),
        }),
      );
      expect(evaluate(item, PropertyKeys.scale, f(15)), closeTo(1.5, 1e-12));
      expect(evaluate(item, PropertyKeys.position, f(15)).y, closeTo(0.25, 1e-12));
      expect(evaluate(item, PropertyKeys.fontSize, f(15)), 48, reason: 'text style is static');
    });
  });
}
