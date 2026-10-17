// OWNER: CORE-13
//
// Before/after golden tests for property and keyframe commands (the dump shows keyframes per
// channel in frames). Every applied result validates fully and the dry run agrees with the apply
// (`runCase`). Regenerate with `UPDATE_GOLDENS=1 dart test test/ops/property` and review the diff.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';
import 'property_fixtures.dart';

typedef Case = (String, EditProject Function(), EditCommand, EditPolicy?);

KeyframeRef r(String item, PropertyKey<Object?> key, int frame, {int start = 0}) =>
    KeyframeRef(id(item), key.id, f(start + frame) - f(start));

final List<Case> cases = [
  (
    'set property on a keyed channel writes a key',
    props,
    SetProperty([id('it_v')], PropertyKeys.scale, 5.0, at: f(10)),
    null
  ),
  (
    'set property replaces the key at that frame',
    props,
    SetProperty([id('it_v')], PropertyKeys.scale, 4.0, at: f(30)),
    null
  ),
  (
    'set position keys both channels',
    props,
    SetProperty([id('it_v')], PropertyKeys.position, const Vec2(0.5, -0.25), at: f(20)),
    null
  ),
  (
    'set property on a mix of keyed and static items is one outcome',
    props,
    SetProperty([id('it_v'), id('it_p'), id('it_t')], PropertyKeys.scale, 2.0, at: f(40)),
    null
  ),
  ('set property outside a keyed item', props, SetProperty([id('it_v')], PropertyKeys.scale, 2.0, at: f(95)), null),
  ('set property without a time on a keyed item', props, SetProperty([id('it_v')], PropertyKeys.scale, 2.0), null),
  (
    'set volume on every audio clip',
    props,
    SetProperty([id('it_a'), id('it_a2'), id('it_v')], PropertyKeys.volume, 0.5, at: f(10)),
    null
  ),
  ('set a fade', props, SetProperty([id('it_a2')], PropertyKeys.fadeIn, 1000000), null),
  ('set an out-of-range value', props, SetProperty([id('it_p')], PropertyKeys.opacity, 1.5), null),
  ('set a visual property on an audio clip', props, SetProperty([id('it_a2')], PropertyKeys.opacity, 0.5), null),
  ('set on a locked lane', props, SetProperty([id('it_l')], PropertyKeys.opacity, 0.5), null),
  (
    'reset transform clears the transform keys and keeps the others',
    props,
    ResetTransform([id('it_v'), id('it_t')]),
    null
  ),
  ('add keyframe with the current value', props, AddKeyframe(r('it_v', PropertyKeys.scale, 15)), null),
  ('add keyframe on a static property', props, AddKeyframe(r('it_p', PropertyKeys.opacity, 20)), null),
  ('add keyframe at an existing key', props, AddKeyframe(r('it_v', PropertyKeys.scale, 30)), null),
  ('add keyframe on a non-keyframable property', props, AddKeyframe(r('it_p', PropertyKeys.crop, 10)), null),
  ('remove keyframe', props, RemoveKeyframe(r('it_v', PropertyKeys.scale, 30)), null),
  (
    'remove the last keyframe leaves the value static',
    () => ok(props(), RemoveKeyframe(r('it_t', PropertyKeys.scale, 0))).project,
    RemoveKeyframe(r('it_t', PropertyKeys.scale, 30)),
    null
  ),
  ('move keyframe', props, MoveKeyframe(r('it_v', PropertyKeys.position, 60), f(20) - f(0)), null),
  ('move keyframe onto another key', props, MoveKeyframe(r('it_v', PropertyKeys.scale, 30), f(60) - f(0)), null),
  ('set keyframe value', props, SetKeyframeValue(r('it_v', PropertyKeys.scale, 30), 5.0), null),
  ('clear keyframes of one property', props, ClearKeyframes([id('it_v')], property: PropertyKeys.scale.id), null),
  ('clear all keyframes of two items', props, ClearKeyframes([id('it_v'), id('it_a')]), null),
];

void main() {
  final golden = GoldenFile('test/ops/property/goldens/property.golden');
  tearDownAll(golden.save);
  for (final c in cases) {
    test(c.$1, () => golden.check(c.$1, runCase(c.$1, c.$2(), c.$3, policy: c.$4 ?? const EditPolicy())));
  }
}
