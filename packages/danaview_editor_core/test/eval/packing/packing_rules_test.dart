// OWNER: CORE-36
//
// packVisualLayers rules (ARCH §13.5) as properties on 1,000 seeded random layer sets, plus the
// named cases of the ticket: six sparse PiP lanes pack into ≤ 2 slots, an interleaving case
// refuses to share, transition A/B windows take a second slot only for the overlapping layers.

import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';

/// Random layers on a few lanes: per lane mostly sequential ranges with gaps, sometimes
/// overlapping neighbours (transition windows); some backdrops and some images.
List<PackInput> randomLayers(Random rnd) {
  final lanes = 1 + rnd.nextInt(8);
  final out = <PackInput>[];
  var n = 0;
  for (var lane = 0; lane < lanes; lane++) {
    final z = (lane < 3 ? 0 : 10000) + (lane + 1) * 10;
    var t = rnd.nextInt(5) * 1000;
    final count = rnd.nextInt(12);
    for (var i = 0; i < count; i++) {
      final len = 1000 + rnd.nextInt(20) * 1000;
      final overlapPrev = i > 0 && rnd.nextDouble() < 0.2;
      final t0 = overlapPrev ? max(0, t - 500 - rnd.nextInt(3) * 500) : t + rnd.nextInt(4) * 1000;
      final t1 = t0 + len;
      out.add(PackInput('L${n++}', z, t0, t1, decoderBacked: rnd.nextDouble() > 0.1));
      if (lane == 0 && rnd.nextDouble() < 0.2) out.add(PackInput('B${n++}', z - 5, t0, t1));
      t = t1;
    }
  }
  return out;
}

bool overlaps(PackInput a, PackInput b) => a.t0 < b.t1 && b.t0 < a.t1;

int bruteForcePeak(List<PackInput> layers) {
  var peak = 0;
  for (final l in layers.where((l) => l.decoderBacked)) {
    // Concurrency is maximal at some layer start.
    final at = l.t0;
    final c = layers.where((x) => x.decoderBacked && x.t0 <= at && at < x.t1).length;
    if (c > peak) peak = c;
  }
  return peak;
}

void main() {
  group('rule properties on 1,000 seeded random layer sets', () {
    final sets = [for (var seed = 0; seed < 1000; seed++) randomLayers(Random(seed))];

    test('layers in one slot never overlap in time', () {
      for (final layers in sets) {
        final r = packVisualLayers(layers);
        for (var i = 0; i < layers.length; i++) {
          for (var j = i + 1; j < layers.length; j++) {
            if (r.seqOf(layers[i].id) == r.seqOf(layers[j].id)) {
              expect(overlaps(layers[i], layers[j]), isFalse, reason: '${layers[i]} ${layers[j]}');
            }
          }
        }
      }
    });

    test('z order is preserved against every overlapping slot (stacking = draw order)', () {
      for (final layers in sets) {
        final r = packVisualLayers(layers);
        for (final a in layers) {
          for (final b in layers) {
            if (identical(a, b) || !overlaps(a, b)) continue;
            final sa = r.seqOf(a.id);
            final sb = r.seqOf(b.id);
            expect(sa == sb, isFalse);
            // a draws below b ⇔ a's slot is below b's slot.
            expect(comparePackInputs(a, b) < 0, sa < sb, reason: '$a $b');
          }
        }
      }
    });

    test('greedy first fit: each layer sits right above the highest overlapping earlier layer', () {
      for (final layers in sets) {
        final r = packVisualLayers(layers);
        final sorted = List.of(layers)..sort(comparePackInputs);
        for (var i = 0; i < sorted.length; i++) {
          var expected = 0;
          for (var j = 0; j < i; j++) {
            if (overlaps(sorted[i], sorted[j])) expected = max(expected, r.seqOf(sorted[j].id) + 1);
          }
          expect(r.seqOf(sorted[i].id), expected);
        }
        expect(r.slotCount, layers.isEmpty ? 0 : r.seqById.values.reduce(max) + 1);
      }
    });

    test('deterministic: input order does not matter', () {
      for (var s = 0; s < sets.length; s += 7) {
        final layers = sets[s];
        final a = packVisualLayers(layers);
        final shuffled = List.of(layers)..shuffle(Random(s));
        final b = packVisualLayers(shuffled);
        expect(b, a);
        expect(b.seqById, a.seqById);
        expect(packVisualLayers(layers), a);
      }
    });

    test('peak concurrent decoders equals a brute-force count; images do not count', () {
      for (final layers in sets) {
        final r = packVisualLayers(layers);
        expect(r.peakConcurrentDecoders, bruteForcePeak(layers));
        expect(r.decoderSlotCount, lessThanOrEqualTo(r.slotCount));
      }
    });
  });

  group('named cases', () {
    const s = 1000000;

    test('six short non-overlapping PiP lanes over a main clip pack into ≤ 2 slots', () {
      final layers = [
        const PackInput('main#v', 10, 0, 60 * s),
        for (var lane = 0; lane < 6; lane++) PackInput('pip$lane#v', 10000 + (lane + 1) * 10, (lane * 10 + 2) * s, (lane * 10 + 8) * s),
      ];
      final r = packVisualLayers(layers);
      expect(r.slotCount, lessThanOrEqualTo(2));
      expect(r.slotCount, 2);
      expect(r.peakConcurrentDecoders, 2);
      expect(r.seqOf('main#v'), 0);
      for (var lane = 0; lane < 6; lane++) {
        expect(r.seqOf('pip$lane#v'), 1);
      }
      expect(r.withinCaps(maxConcurrentVideoLayers: 2, maxVisualSequences: 2), isTrue);
      expect(r.withinCaps(maxConcurrentVideoLayers: 2, maxVisualSequences: 1), isFalse);
    });

    test('an interleaving case refuses to share a slot', () {
      // A and C never overlap, but B lies between them in z while overlapping both.
      const a = PackInput('A', 10010, 0, 10 * s);
      const b = PackInput('B', 10020, 5 * s, 15 * s);
      const c = PackInput('C', 10030, 12 * s, 20 * s);
      final r = packVisualLayers([a, b, c]);
      expect(r.seqOf('A'), 0);
      expect(r.seqOf('B'), 1);
      expect(r.seqOf('C'), 2);
      expect(r.slotCount, 3);
      expect(r.peakConcurrentDecoders, 2);
      // Without B in between, A and C share.
      final r2 = packVisualLayers([a, c]);
      expect(r2.seqOf('C'), 0);
      expect(r2.slotCount, 1);
    });

    test('a transition A/B window takes a second slot only for the overlapping layers', () {
      final r = packVisualLayers(const [
        PackInput('c1', 10, 0, 22 * s ~/ 10),
        PackInput('c2', 10, 18 * s ~/ 10, 5 * s),
        PackInput('c3', 10, 5 * s, 8 * s),
        PackInput('c4', 10, 8 * s, 10 * s),
      ]);
      expect([for (final id in ['c1', 'c2', 'c3', 'c4']) r.seqOf(id)], [0, 1, 0, 0]);
      expect(r.slotCount, 2);
    });

    test('touching ranges are not concurrent (half-open)', () {
      final r = packVisualLayers(const [PackInput('a', 10, 0, 100), PackInput('b', 20, 100, 200)]);
      expect(r.seqOf('b'), 0);
      expect(r.peakConcurrentDecoders, 1);
    });

    test('backdrops sit below their clip', () {
      final r = packVisualLayers(const [PackInput('x#v', 10, 0, 100), PackInput('x#bd', 5, 0, 100)]);
      expect(r.seqOf('x#bd'), 0);
      expect(r.seqOf('x#v'), 1);
    });

    test('empty input and duplicate ids', () {
      expect(packVisualLayers(const []), PackResult.empty);
      expect(PackResult.empty.slotCount, 0);
      expect(() => packVisualLayers(const [PackInput('a', 10, 0, 1), PackInput('a', 20, 0, 1)]), throwsArgumentError);
      expect(() => PackResult.empty.seqOf('x'), throwsArgumentError);
      expect(PackResult.empty.trySeqOf('x'), isNull);
    });

    test('non-decoder layers get slots but do not count as decoders', () {
      final r = packVisualLayers(const [
        PackInput('v', 10, 0, 100),
        PackInput('img', 20, 0, 100, decoderBacked: false),
      ]);
      expect(r.slotCount, 2);
      expect(r.decoderSlotCount, 1);
      expect(r.peakConcurrentDecoders, 1);
    });
  });
}
