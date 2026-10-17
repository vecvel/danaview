// OWNER: CORE-08
//
// The shared random project generator (test/support/random_project.dart) produces valid,
// deterministic projects covering every track kind and feature.

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../support/random_project.dart';

void main() {
  test('500 seeded random projects are valid', () {
    for (var seed = 0; seed < 500; seed++) {
      final p = randomProject(seed);
      final v = validate(p);
      expect(v, isEmpty, reason: 'seed $seed: ${v.take(5).join('\n')}');
    }
  });

  test('the same seed gives the same project', () {
    for (final seed in [1, 7, 42]) {
      expect(randomProject(seed), randomProject(seed));
    }
    expect(randomProject(1) == randomProject(2), isFalse);
  });

  test('generated projects cover every track kind and feature', () {
    final kinds = <TrackKind>{};
    var ramps = 0, reversed = 0, keys = 0, transitions = 0, links = 0, cues = 0, texts = 0, markers = 0, images = 0;
    final transitionKinds = <TransitionKind>{};
    final animKinds = <TextAnimKind>{};
    for (var seed = 0; seed < 100; seed++) {
      final p = randomProject(seed);
      markers += p.markers.length;
      for (final t in p.tracks) {
        kinds.add(t.kind);
        transitions += t.transitions.length;
        transitionKinds.addAll(t.transitions.map((x) => x.kind));
        for (final i in t.items) {
          if (i.link != null) links++;
          switch (i) {
            case MediaClip():
              if (i.speed is SpeedRamp) ramps++;
              if (i.reversed) reversed++;
              if (!i.keyframes.isEmpty) keys++;
              if (p.pool[i.media]!.kind == MediaKind.image) images++;
            case TextItem():
              texts++;
              animKinds.add(i.animation.inKind);
            case SubtitleCue():
              cues++;
          }
        }
      }
    }
    expect(kinds, TrackKind.values.toSet());
    expect(transitionKinds, TransitionKind.values.toSet());
    expect(animKinds, TextAnimKind.values.toSet());
    for (final n in [ramps, reversed, keys, transitions, links, cues, texts, markers, images]) {
      expect(n, greaterThan(0));
    }
  });

  test('a 2,000-item project can be generated', () {
    final p = randomProject(3, const RandomProjectSpec(items: 2000));
    expect(p.index.itemCount, inInclusiveRange(1500, 2600));
    expect(validate(p), isEmpty);
  });
}
