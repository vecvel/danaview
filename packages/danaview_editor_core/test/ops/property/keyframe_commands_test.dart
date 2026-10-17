// OWNER: CORE-13
//
// Tests of AddKeyframe, RemoveKeyframe, MoveKeyframe, SetKeyframeValue and ClearKeyframes
// (BUILD_PLAN CORE-13): Vec2 properties on both channels, the grid, every rejection, and the
// static value left behind when the last key goes.

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';
import 'property_fixtures.dart';

KeyframeRef ref(String item, PropertyKey<Object?> key, int frame, {int start = 0}) =>
    KeyframeRef(id(item), key.id, f(start + frame) - f(start));

void main() {
  group('AddKeyframe', () {
    test('adds a key with the current value on a static property (the diamond button)', () {
      final p = props();
      final out = ok(p, AddKeyframe(ref('it_p', PropertyKeys.opacity, 20)));
      final c = clip(out.project, 'it_p');
      expect(keysOf(c, 'transform.opacity'), [(20, 1.0)]);
      expect(c.visual, clip(p, 'it_p').visual, reason: 'the static value stays');
      expect(out.affected, {id('it_p')});
    });

    test('adds a key with the value the keys give at that time on an animated property', () {
      final out = ok(props(), AddKeyframe(ref('it_v', PropertyKeys.scale, 15)));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale'), [(0, 1.0), (15, 1.5), (30, 2.0), (60, 3.0)]);
    });

    test('adds a key with an explicit value; ints are accepted for numbers', () {
      final out = ok(props(), AddKeyframe(ref('it_v', PropertyKeys.scale, 45), value: 7));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale').last, (60, 3.0));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale')[2], (45, 7.0));
    });

    test('Vec2 properties write both channels at the same time (by property or channel id)', () {
      final p = props();
      for (final property in ['transform.position', 'transform.position.x', 'transform.position.y']) {
        final out = ok(p, AddKeyframe(KeyframeRef(id('it_v'), property, f(30) - f(0)), value: const Vec2(0.25, -0.75)));
        final c = clip(out.project, 'it_v');
        expect(keysOf(c, 'transform.position.x'), [(0, 0.0), (30, 0.25), (60, 1.0)], reason: property);
        expect(keysOf(c, 'transform.position.y'), [(0, 0.0), (30, -0.75), (60, -1.0)], reason: property);
      }
      final out = ok(p, AddKeyframe(ref('it_p', PropertyKeys.maskSize, 10)));
      expect(keysOf(clip(out.project, 'it_p'), 'mask.size.x'), [(10, 0.6)]);
      expect(keysOf(clip(out.project, 'it_p'), 'mask.size.y'), [(10, 0.6)]);
    });

    test('the key time is put on the grid (nearest frame); a second add at the same frame exists', () {
      final p = props();
      final mid = KeyframeRef(id('it_p'), PropertyKeys.scale.id, f(10) - f(0) + 9000);
      final out = ok(p, AddKeyframe(mid));
      expect(keysOf(clip(out.project, 'it_p'), 'transform.scale'), [(10, 1.0)]);
      final jitter = KeyframeRef(id('it_p'), PropertyKeys.scale.id, f(10) - f(0) - 1);
      expect(rejection(out.project, AddKeyframe(jitter)), KeyframeExists(f(10) - f(0)));
    });

    test('keys of items that start later use item-local times', () {
      final out = ok(props(), AddKeyframe(ref('it_t2', PropertyKeys.rotation, 10, start: 60), value: 30.0));
      final t = textOf(out.project, 'it_t2');
      expect(keysOf(t, 'transform.rotation'), [(10, 30.0)]);
      expect(t.keyframes['transform.rotation']!.keys.single.t, f(70) - f(60));
    });

    test('works for volume on clips with sound and for text', () {
      final p = props();
      expect(ok(p, AddKeyframe(ref('it_a2', PropertyKeys.volume, 5, start: 90), value: 0.3)).rejection, isNull);
      expect(ok(p, AddKeyframe(ref('it_v', PropertyKeys.volume, 20))).rejection, isNull);
      expect(ok(p, AddKeyframe(ref('it_t', PropertyKeys.opacity, 10), value: 0.5)).rejection, isNull);
    });

    test('rejections: existing key, time outside the item', () {
      final p = props();
      expect(rejection(p, AddKeyframe(ref('it_v', PropertyKeys.scale, 30))), KeyframeExists(f(30) - f(0)));
      expect(rejection(p, AddKeyframe(ref('it_v', PropertyKeys.position, 60))), isA<KeyframeExists>());
      expect(rejection(p, AddKeyframe(KeyframeRef(id('it_v'), PropertyKeys.scale.id, -f(5)))), const InvalidValue('t'));
      expect(rejection(p, AddKeyframe(ref('it_v', PropertyKeys.scale, 90))), const InvalidValue('t'),
          reason: 'the end is outside');
      expect(rejection(p, AddKeyframe(ref('it_v', PropertyKeys.scale, 500))), const InvalidValue('t'));
      expect(ok(p, AddKeyframe(ref('it_v', PropertyKeys.scale, 89))).rejection, isNull);
    });

    test('rejections: properties, kinds, values, items', () {
      final p = props();
      for (final key in [
        PropertyKeys.crop,
        PropertyKeys.fit,
        PropertyKeys.flipH,
        PropertyKeys.lookIntensity,
        PropertyKeys.chromaSimilarity,
        PropertyKeys.muted,
        PropertyKeys.fadeIn,
      ]) {
        expect(rejection(p, AddKeyframe(ref('it_p', key, 10))), const UnsupportedForKind('notKeyframable'),
            reason: key.id);
      }
      expect(rejection(p, AddKeyframe(ref('it_t', PropertyKeys.fontSize, 10))),
          const UnsupportedForKind('notKeyframable'));
      expect(rejection(p, AddKeyframe(KeyframeRef(id('it_p'), 'nope.nothing', 0))), const InvalidValue('property'));
      expect(rejection(p, AddKeyframe(ref('it_a2', PropertyKeys.scale, 10, start: 90))),
          const UnsupportedForKind('audioClip'));
      expect(rejection(p, AddKeyframe(ref('it_c', PropertyKeys.scale, 10))), const UnsupportedForKind('subtitle'));
      expect(rejection(p, AddKeyframe(ref('it_t2', PropertyKeys.exposure, 10, start: 60))),
          const UnsupportedForKind('text'));
      expect(rejection(p, AddKeyframe(ref('it_p', PropertyKeys.volume, 10))), const UnsupportedForKind('noAudio'));
      expect(rejection(p, AddKeyframe(ref('it_s', PropertyKeys.volume, 10, start: 90))),
          const UnsupportedForKind('noAudio'));
      expect(rejection(p, AddKeyframe(ref('it_p', PropertyKeys.scale, 10), value: 9.0)),
          const InvalidValue('transform.scale'));
      expect(rejection(p, AddKeyframe(ref('it_p', PropertyKeys.scale, 10), value: double.nan)),
          const InvalidValue('transform.scale'));
      expect(rejection(p, AddKeyframe(ref('it_p', PropertyKeys.scale, 10), value: const Vec2(1, 1))),
          const InvalidValue('transform.scale'));
      expect(rejection(p, AddKeyframe(ref('it_p', PropertyKeys.position, 10), value: 1.0)),
          const InvalidValue('transform.position'));
      expect(rejection(p, AddKeyframe(ref('it_p', PropertyKeys.position, 10), value: const Vec2(3, 0))),
          const InvalidValue('transform.position'));
      expect(rejection(p, AddKeyframe(ref('it_l', PropertyKeys.scale, 10))), const TrackLocked(TrackId('tr_ovl')));
      expect(rejection(p, AddKeyframe(ref('it_nope', PropertyKeys.scale, 10))), const ItemNotFound('it_nope'));
    });

    test('evaluation after the add matches the key', () {
      final out = ok(props(), AddKeyframe(ref('it_p', PropertyKeys.rotation, 12), value: 45.0));
      expect(evaluate(clip(out.project, 'it_p'), PropertyKeys.rotation, f(12)), 45.0);
    });
  });

  group('RemoveKeyframe', () {
    test('removes one key and keeps the others', () {
      final out = ok(props(), RemoveKeyframe(ref('it_v', PropertyKeys.scale, 30)));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale'), [(0, 1.0), (60, 3.0)]);
    });

    test('Vec2: both channels lose the key', () {
      final out = ok(props(), RemoveKeyframe(ref('it_v', PropertyKeys.position, 60)));
      final c = clip(out.project, 'it_v');
      expect(keysOf(c, 'transform.position.x'), [(0, 0.0)]);
      expect(keysOf(c, 'transform.position.y'), [(0, 0.0)]);
    });

    test('removing the last key leaves the property static at the value that key held', () {
      var p = props();
      p = ok(p, RemoveKeyframe(ref('it_t', PropertyKeys.scale, 0))).project;
      expect(keysOf(textOf(p, 'it_t'), 'transform.scale'), [(30, 2.0)]);
      final out = ok(p, RemoveKeyframe(ref('it_t', PropertyKeys.scale, 30)));
      final t = textOf(out.project, 'it_t');
      expect(t.keyframes.byChannel.containsKey('transform.scale'), isFalse, reason: 'the property is static again');
      expect(t.transform.scale, 2.0, reason: 'at the value the last key held: no jump');
      expect(evaluate(t, PropertyKeys.scale, f(5)), 2.0);
    });

    test('removing the last key of a Vec2 property bakes both components', () {
      var p = props();
      p = ok(p, RemoveKeyframe(ref('it_v', PropertyKeys.position, 0))).project;
      final out = ok(p, RemoveKeyframe(ref('it_v', PropertyKeys.position, 60)));
      final c = clip(out.project, 'it_v');
      expect(c.visual!.transform.position, const Vec2(1, -1));
      expect(c.keyframes.byChannel.keys.where((k) => k.startsWith('transform.position')), isEmpty);
    });

    test('rejections: missing key, kinds, locks', () {
      final p = props();
      expect(rejection(p, RemoveKeyframe(ref('it_v', PropertyKeys.scale, 31))), isA<NothingAtTime>());
      expect(rejection(p, RemoveKeyframe(ref('it_p', PropertyKeys.scale, 10))), isA<NothingAtTime>());
      expect(
          rejection(p, RemoveKeyframe(ref('it_v', PropertyKeys.crop, 0))), const UnsupportedForKind('notKeyframable'));
      expect(rejection(p, RemoveKeyframe(KeyframeRef(id('it_v'), 'zzz', 0))), const InvalidValue('property'));
      expect(rejection(p, RemoveKeyframe(ref('it_l', PropertyKeys.scale, 0))), const TrackLocked(TrackId('tr_ovl')));
      expect(rejection(p, RemoveKeyframe(ref('it_nope', PropertyKeys.scale, 0))), const ItemNotFound('it_nope'));
    });

    test('the time is put on the grid', () {
      final out = ok(props(), RemoveKeyframe(KeyframeRef(id('it_v'), PropertyKeys.scale.id, f(30) - f(0) + 4000)));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale').map((k) => k.$1), [0, 60]);
    });
  });

  group('MoveKeyframe', () {
    test('moves a key (both Vec2 channels) and keeps the order', () {
      final p = props();
      var out = ok(p, MoveKeyframe(ref('it_v', PropertyKeys.scale, 30), f(40) - f(0)));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale'), [(0, 1.0), (40, 2.0), (60, 3.0)]);
      out = ok(p, MoveKeyframe(ref('it_v', PropertyKeys.position, 60), f(20) - f(0)));
      final c = clip(out.project, 'it_v');
      expect(keysOf(c, 'transform.position.x'), [(0, 0.0), (20, 1.0)]);
      expect(keysOf(c, 'transform.position.y'), [(0, 0.0), (20, -1.0)]);
    });

    test('a key may cross its neighbours; the track stays sorted', () {
      final out = ok(props(), MoveKeyframe(ref('it_v', PropertyKeys.scale, 0), f(45) - f(0)));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale'), [(30, 2.0), (45, 1.0), (60, 3.0)]);
    });

    test('the target time is put on the grid', () {
      final out = ok(props(), MoveKeyframe(ref('it_v', PropertyKeys.scale, 30), f(40) - f(0) + 6000));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale').map((k) => k.$1), [0, 40, 60]);
    });

    test('rejections', () {
      final p = props();
      expect(
          rejection(p, MoveKeyframe(ref('it_v', PropertyKeys.scale, 30), f(60) - f(0))), KeyframeExists(f(60) - f(0)));
      expect(rejection(p, MoveKeyframe(ref('it_v', PropertyKeys.scale, 30), -f(5))), const InvalidValue('t'));
      expect(rejection(p, MoveKeyframe(ref('it_v', PropertyKeys.scale, 30), f(90) - f(0))), const InvalidValue('t'));
      expect(rejection(p, MoveKeyframe(ref('it_v', PropertyKeys.scale, 31), f(40) - f(0))), isA<NothingAtTime>());
      expect(rejection(p, MoveKeyframe(ref('it_v', PropertyKeys.flipH, 31), f(40) - f(0))),
          const UnsupportedForKind('notKeyframable'));
      expect(
          rejection(p, MoveKeyframe(ref('it_l', PropertyKeys.scale, 0), f(4))), const TrackLocked(TrackId('tr_ovl')));
    });

    test('moving to the same frame is a no-op', () {
      final out = applyCommand(props(), MoveKeyframe(ref('it_v', PropertyKeys.scale, 30), f(30) - f(0) + 1000), ctx());
      expect(out.noop, isTrue);
    });
  });

  group('SetKeyframeValue', () {
    test('changes the value of a key; Vec2 writes both channels', () {
      final p = props();
      var out = ok(p, SetKeyframeValue(ref('it_v', PropertyKeys.scale, 30), 5.0));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale'), [(0, 1.0), (30, 5.0), (60, 3.0)]);
      out = ok(p, SetKeyframeValue(ref('it_v', PropertyKeys.position, 60), const Vec2(0.5, 0.5)));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.position.x'), [(0, 0.0), (60, 0.5)]);
      expect(keysOf(clip(out.project, 'it_v'), 'transform.position.y'), [(0, 0.0), (60, 0.5)]);
    });

    test('rejections', () {
      final p = props();
      expect(rejection(p, SetKeyframeValue(ref('it_v', PropertyKeys.scale, 31), 2.0)), isA<NothingAtTime>());
      expect(rejection(p, SetKeyframeValue(ref('it_v', PropertyKeys.scale, 30), 8.1)),
          const InvalidValue('transform.scale'));
      expect(rejection(p, SetKeyframeValue(ref('it_v', PropertyKeys.scale, 30), double.infinity)),
          const InvalidValue('transform.scale'));
      expect(rejection(p, SetKeyframeValue(ref('it_v', PropertyKeys.scale, 30), const Vec2(1, 1))),
          const InvalidValue('transform.scale'));
      expect(rejection(p, SetKeyframeValue(ref('it_v', PropertyKeys.position, 60), 1.0)),
          const InvalidValue('transform.position'));
      expect(rejection(p, SetKeyframeValue(ref('it_v', PropertyKeys.crop, 30), 1.0)),
          const UnsupportedForKind('notKeyframable'));
      expect(rejection(p, SetKeyframeValue(ref('it_l', PropertyKeys.scale, 30), 1.0)),
          const TrackLocked(TrackId('tr_ovl')));
      expect(
          rejection(p, SetKeyframeValue(ref('it_nope', PropertyKeys.scale, 30), 1.0)), const ItemNotFound('it_nope'));
    });

    test('the same value is a no-op', () {
      final out = applyCommand(props(), SetKeyframeValue(ref('it_v', PropertyKeys.scale, 30), 2.0), ctx());
      expect(out.noop, isTrue);
    });
  });

  group('ClearKeyframes', () {
    test('clears one property of several items; items without keys are left alone', () {
      final p = props();
      final out = ok(p, ClearKeyframes([id('it_v'), id('it_p'), id('it_t')], property: PropertyKeys.scale.id));
      expect(clip(out.project, 'it_v').keyframes.byChannel.containsKey('transform.scale'), isFalse);
      expect(clip(out.project, 'it_v').keyframes.byChannel.keys,
          unorderedEquals(['transform.position.x', 'transform.position.y', 'audio.volume']));
      expect(textOf(out.project, 'it_t').keyframes.isEmpty, isTrue);
      expect(out.affected, {id('it_v'), id('it_t')}, reason: 'it_p had nothing to clear');
      expect(clip(out.project, 'it_v').visual, clip(p, 'it_v').visual, reason: 'static values stay without an `at`');
    });

    test('clears every property when none is named', () {
      final out = ok(props(), ClearKeyframes([id('it_v'), id('it_a')]));
      expect(clip(out.project, 'it_v').keyframes.isEmpty, isTrue);
      expect(clip(out.project, 'it_a').keyframes.isEmpty, isTrue);
    });

    test('with a time the cleared properties become static at their value there', () {
      final p = props();
      final out = ok(p, ClearKeyframes([id('it_v')], at: f(15)));
      final c = clip(out.project, 'it_v');
      expect(c.keyframes.isEmpty, isTrue);
      expect(c.visual!.transform.scale, closeTo(1.5, 1e-9));
      expect(c.visual!.transform.position.x, closeTo(0.25, 1e-9));
      expect(c.visual!.transform.position.y, closeTo(-0.25, 1e-9));
      expect(c.audio.volume, closeTo(0.875, 1e-9));
      // The property named, with a time.
      final one = ok(p, ClearKeyframes([id('it_v')], property: PropertyKeys.scale.id, at: f(45)));
      expect(clip(one.project, 'it_v').visual!.transform.scale, closeTo(2.5, 1e-9));
      expect(clip(one.project, 'it_v').keyframes.byChannel.containsKey('transform.position.x'), isTrue);
    });

    test('nothing to clear is a no-op', () {
      final out = applyCommand(props(), ClearKeyframes([id('it_p'), id('it_s')]), ctx());
      expect(out.noop, isTrue);
    });

    test('rejections', () {
      final p = props();
      expect(rejection(p, ClearKeyframes([id('it_v')], property: PropertyKeys.crop.id)),
          const UnsupportedForKind('notKeyframable'));
      expect(rejection(p, ClearKeyframes([id('it_v')], property: 'zzz')), const InvalidValue('property'));
      expect(rejection(p, ClearKeyframes([id('it_c')])), const UnsupportedForKind('subtitle'));
      expect(rejection(p, ClearKeyframes([id('it_a2')], property: PropertyKeys.scale.id)),
          const UnsupportedForKind('audioClip'));
      expect(rejection(p, ClearKeyframes([id('it_l')])), const TrackLocked(TrackId('tr_ovl')));
      expect(rejection(p, ClearKeyframes([id('it_nope')])), const ItemNotFound('it_nope'));
      expect(rejection(p, ClearKeyframes(const <ItemId>[])), const InvalidValue('items'));
    });
  });

  group('keyframe commands and the rest of the model', () {
    test('keys written by commands survive a head trim and a split like any other key', () {
      final p = ok(props(), AddKeyframe(ref('it_p', PropertyKeys.scale, 10), value: 2.0)).project;
      final split = ok(p, SplitItems({id('it_p')}, f(30)));
      final left = clip(split.project, 'it_p');
      expect(left.keyframes['transform.scale'], isNotNull);
      final trimmed = ok(p, TrimItem(id('it_p'), TrimEdge.start, f(5)));
      expect(keysOf(clip(trimmed.project, 'it_p'), 'transform.scale').single.$1, 5,
          reason: 'the key is still at the same content: 10f - 5f');
    });

    test('keyframe commands never throw: a fuzz of refs, values and times', () {
      final p = props();
      final keys = PropertyKeys.all;
      final items = ['it_v', 'it_s', 'it_p', 'it_t', 'it_t2', 'it_a', 'it_a2', 'it_c', 'it_l', 'it_nope'];
      var n = 0;
      for (final item in items) {
        for (final key in keys) {
          for (final t in [-5, 0, f(10) - f(0), f(30) - f(0) + 5000, f(500)]) {
            final r = KeyframeRef(id(item), key.id, t);
            for (final c in <EditCommand>[
              AddKeyframe(r),
              RemoveKeyframe(r),
              MoveKeyframe(r, f(20) - f(0)),
              SetKeyframeValue(r, 0.5),
              ClearKeyframes([id(item)], property: key.id, at: t)
            ]) {
              final out = applyCommand(p, c, ctx());
              expect(out.rejection, isNot(isA<InternalInconsistency>()), reason: '$c -> ${out.rejection}');
              if (out.rejection == null && !out.noop) expectValid(out.project, '$c');
              n++;
            }
          }
        }
      }
      expect(n, greaterThan(1000));
    });
  });
}
