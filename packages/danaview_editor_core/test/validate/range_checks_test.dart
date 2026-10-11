// OWNER: CORE-08
//
// The validator's direct static-range check (`outOfRangeProperties`) agrees with the generic
// PropertyKey check (`key.accepts(key.read(item))` over `rangeCheckedKeysOf(item)`).

import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../support/random_project.dart';

List<String> generic(TimelineItem item) => [
      for (final k in rangeCheckedKeysOf(item))
        if (!k.accepts(k.read(item))) k.id,
    ];

Object _wild(PropertyKey<Object?> key, Random rnd) {
  double w() => switch (rnd.nextInt(5)) {
        0 => key.min - 1 - rnd.nextDouble(),
        1 => key.max + 1 + rnd.nextDouble(),
        2 => double.nan,
        3 => key.min,
        _ => key.max,
      };
  return switch (key.valueKind) {
    PropertyValueKind.vec2 => Vec2(w(), rnd.nextBool() ? w() : (key.min + key.max) / 2),
    PropertyValueKind.rect => CropRect(left: rnd.nextDouble(), top: -rnd.nextDouble(), right: rnd.nextDouble() * 1.5, bottom: 1),
    _ => w(),
  };
}

void main() {
  test('the ranged keys cover every number, vector and rectangle property of each item kind', () {
    final ids = {
      for (final i in [
        MediaClip(id: const ItemId('it_v'), start: 0, duration: 1, media: const MediaId('md_x'), visual: VisualProps.neutral),
        const MediaClip(id: ItemId('it_a'), start: 0, duration: 1, media: MediaId('md_x')),
        const TextItem(id: ItemId('it_t'), start: 0, duration: 1, text: 'x'),
      ])
        ...rangeCheckedKeysOf(i).map((k) => k.id),
    };
    expect(ids, containsAll(['transform.scale', 'visual.crop', 'adjust.tint', 'mask.size', 'audio.volume', 'text.shadow.angle']));
    expect(ids, isNot(contains('audio.fadeIn')));
  });

  test('direct and generic range checks agree on 300 random projects with wild values', () {
    var flagged = 0;
    for (var seed = 0; seed < 300; seed++) {
      final rnd = Random(seed);
      final p = randomProject(seed, const RandomProjectSpec(items: 20));
      for (final t in p.tracks) {
        for (var item in t.items) {
          final keys = rangeCheckedKeysOf(item);
          for (var i = 0; i < 3 && keys.isNotEmpty; i++) {
            final key = keys[rnd.nextInt(keys.length)];
            if (key == PropertyKeys.lookIntensity && (item as MediaClip).visual?.look == null) continue;
            if (rnd.nextBool()) item = key.write(item, _wild(key, rnd));
          }
          final g = generic(item);
          if (g.isNotEmpty) flagged++;
          expect(outOfRangeProperties(item), g, reason: 'seed $seed ${item.id}');
        }
      }
    }
    expect(flagged, greaterThan(500));
  });
}
