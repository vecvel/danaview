// OWNER: CORE-36
//
// The shared packing vectors `test/fixtures/vectors/packing.json` (inputs → seq, slotCount,
// peakConcurrentDecoders), read by the Dart test here and by IOS-08 / AND-08 so every platform
// agrees on `seq`. The cases are built deterministically by [buildCases]; regenerate the file with
//
//   DANAVIEW_REGEN_PACKING_VECTORS=1 dart test test/eval/packing/packing_vectors_test.dart
//
// Format: `{"version": 1, "rules": "...", "cases": [{"name", "inputs": [{"id", "z", "t0", "t1",
// "decoderBacked"}], "expected": {"seq": {id: n}, "slotCount", "peakConcurrentDecoders",
// "decoderSlotCount"}}]}`. Inputs are listed in draw order; implementations must not depend on
// the input order.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';

const String vectorsPath = 'test/fixtures/vectors/packing.json';
const int s = 1000000;

Map<String, Object?> caseOf(String name, List<PackInput> inputs) {
  final sorted = List.of(inputs)..sort(comparePackInputs);
  final r = packVisualLayers(sorted);
  return {
    'name': name,
    'inputs': [for (final i in sorted) i.toJson()],
    'expected': {
      'seq': {for (final i in sorted) i.id: r.seqOf(i.id)},
      'slotCount': r.slotCount,
      'peakConcurrentDecoders': r.peakConcurrentDecoders,
      'decoderSlotCount': r.decoderSlotCount,
    },
  };
}

List<PackInput> _random(int seed) {
  final rnd = Random(seed);
  final out = <PackInput>[];
  final lanes = 2 + rnd.nextInt(6);
  for (var lane = 0; lane < lanes; lane++) {
    final z = lane == 0 ? 10 : 10000 + lane * 10;
    // 30 fps grid times so native tests can reuse them as frame edges.
    var k = rnd.nextInt(30);
    for (var i = 0; i < 2 + rnd.nextInt(6); i++) {
      final overlap = i > 0 && rnd.nextDouble() < 0.25;
      final k0 = overlap ? k - 1 - rnd.nextInt(10) : k + rnd.nextInt(90);
      final k1 = k0 + 15 + rnd.nextInt(300);
      out.add(PackInput('r${seed}_l${lane}_$i#v', z, (k0 * s + 29) ~/ 30, (k1 * s + 29) ~/ 30, decoderBacked: rnd.nextDouble() > 0.15));
      k = k1;
    }
  }
  return out;
}

List<Map<String, Object?>> buildCases() => [
      caseOf('empty', const []),
      caseOf('single clip', const [PackInput('a#v', 10, 0, 3 * s)]),
      caseOf('sequential clips on the main lane share slot 0', const [
        PackInput('a#v', 10, 0, 2 * s),
        PackInput('b#v', 10, 2 * s, 5 * s),
        PackInput('c#v', 10, 5 * s, 6 * s),
      ]),
      caseOf('cross dissolve: only the A/B window takes a second slot', const [
        PackInput('a#v', 10, 0, 2200000),
        PackInput('b#v', 10, 1800000, 5 * s),
        PackInput('c#v', 10, 5 * s, 8 * s),
      ]),
      caseOf('six sparse PiP lanes over the main lane pack into 2 slots', [
        const PackInput('main#v', 10, 0, 60 * s),
        for (var lane = 0; lane < 6; lane++) PackInput('pip$lane#v', 10010 + lane * 10, (lane * 10 + 2) * s, (lane * 10 + 8) * s),
      ]),
      caseOf('interleaving lanes refuse to share', const [
        PackInput('a#v', 10010, 0, 10 * s),
        PackInput('b#v', 10020, 5 * s, 15 * s),
        PackInput('c#v', 10030, 12 * s, 20 * s),
      ]),
      caseOf('non-interleaving lanes share', const [
        PackInput('a#v', 10010, 0, 10 * s),
        PackInput('c#v', 10030, 12 * s, 20 * s),
      ]),
      caseOf('blurred backdrops sit below their main clips', const [
        PackInput('a#bd', 5, 0, 2 * s),
        PackInput('b#bd', 5, 2 * s, 4 * s),
        PackInput('a#v', 10, 0, 2 * s),
        PackInput('b#v', 10, 2 * s, 4 * s),
      ]),
      caseOf('touching ranges are not concurrent (half-open)', const [
        PackInput('a#v', 10, 0, 1000000),
        PackInput('b#v', 10010, 1000000, 2000000),
      ]),
      caseOf('equal z and start: ties break by id', const [
        PackInput('b#v', 10, 0, s),
        PackInput('a#v', 10, 0, s),
      ]),
      caseOf('non-decoder layers get slots but are not counted as decoders', const [
        PackInput('v#v', 10, 0, 4 * s),
        PackInput('img#v', 10010, s, 3 * s, decoderBacked: false),
        PackInput('pip#v', 10020, 2 * s, 5 * s),
      ]),
      caseOf('a gap in a higher slot lets a later layer drop down', const [
        PackInput('main#v', 10, 0, 10 * s),
        PackInput('o1#v', 10010, 0, 3 * s),
        PackInput('o2#v', 10020, 1 * s, 2 * s),
        PackInput('o3#v', 10030, 4 * s, 6 * s),
        PackInput('o4#v', 10040, 7 * s, 9 * s),
      ]),
      for (var seed = 1; seed <= 12; seed++) caseOf('seeded random $seed', _random(seed)),
    ];

String encodeVectors(List<Map<String, Object?>> cases) =>
    '${const JsonEncoder.withIndent('  ').convert({
          'version': 1,
          'rules': 'ARCH §13.5: seq = 1 + max seq of the layers placed before (ascending z, then t0, then id) '
              'that overlap in time, 0 when none; ranges are half-open µs; peakConcurrentDecoders counts '
              'decoderBacked layers active at one instant.',
          'cases': cases,
        })}\n';

void main() {
  test('packing.json is up to date with the generator', () {
    final expected = encodeVectors(buildCases());
    final file = File(vectorsPath);
    if (Platform.environment['DANAVIEW_REGEN_PACKING_VECTORS'] == '1') file.writeAsStringSync(expected);
    expect(file.readAsStringSync(), expected, reason: 'regenerate with DANAVIEW_REGEN_PACKING_VECTORS=1');
  });

  test('packVisualLayers reproduces every vector, in any input order', () {
    final json = jsonDecode(File(vectorsPath).readAsStringSync()) as Map<String, Object?>;
    expect(json['version'], 1);
    final cases = (json['cases']! as List).cast<Map<String, Object?>>();
    expect(cases.length, greaterThanOrEqualTo(20));
    for (final c in cases) {
      final inputs = [for (final i in (c['inputs']! as List).cast<Map<String, Object?>>()) PackInput.fromJson(i)];
      final expected = c['expected']! as Map<String, Object?>;
      for (final order in [inputs, inputs.reversed.toList()]) {
        final r = packVisualLayers(order);
        expect(r.seqById, (expected['seq']! as Map).cast<String, int>(), reason: '${c['name']}');
        expect(r.slotCount, expected['slotCount'], reason: '${c['name']}');
        expect(r.peakConcurrentDecoders, expected['peakConcurrentDecoders'], reason: '${c['name']}');
        expect(r.decoderSlotCount, expected['decoderSlotCount'], reason: '${c['name']}');
      }
    }
  });

  test('the named vectors encode the ticket cases', () {
    final byName = {for (final c in buildCases()) c['name']: c['expected']! as Map<String, Object?>};
    expect(byName['six sparse PiP lanes over the main lane pack into 2 slots']!['slotCount'], 2);
    expect(byName['interleaving lanes refuse to share']!['slotCount'], 3);
    expect(byName['non-interleaving lanes share']!['slotCount'], 1);
    expect((byName['cross dissolve: only the A/B window takes a second slot']!['seq']! as Map)['c#v'], 0);
    expect((byName['a gap in a higher slot lets a later layer drop down']!['seq']! as Map)['o3#v'], 1);
  });
}
