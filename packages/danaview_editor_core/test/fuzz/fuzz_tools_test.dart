// OWNER: CORE-34
//
// The fuzzer's own machinery: the choice stream, the id generator, determinism, the coverage
// report, fixtures and the command line (the nightly job's entry point).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import 'fuzz_choices.dart';
import 'fuzz_coverage.dart';
import 'fuzz_fixture.dart';
import 'fuzz_runner.dart';

void main() {
  group('Choices', () {
    test('a random stream records what it returns', () {
      final c = Choices.random(Random(4));
      final got = [c.below(10), c.below(1), c.below(0), c.weighted(const [1, 2, 3]), c.below(1 << 40)];
      expect(got[1], 0);
      expect(got[2], 0);
      expect(c.drawn, hasLength(3), reason: 'bounds of 1 or less do not draw');
      expect(c.drawn[0], got[0]);
      expect(c.drawn[2], got[4]);
      expect(c.isReplay, isFalse);
    });

    test('a replay reduces draws modulo the bound and returns 0 when exhausted', () {
      final c = Choices.replay([13, -7, 5]);
      expect(c.below(10), 3);
      expect(c.below(4), 3);
      expect(c.below(5), 0);
      expect(c.below(100), 0, reason: 'exhausted');
      expect(c.drawn, [3, 3, 0, 0]);
      expect(c.isReplay, isTrue);
    });

    test('zero draws mean the simplest choice', () {
      final c = Choices.replay(const []);
      expect(c.weighted(const [5, 1, 1]), 0);
      expect(c.chance(1, 3), isFalse);
      expect(c.flip(), isFalse);
      expect(c.pick(const ['a', 'b']), 'a');
      expect(c.unit(), 0);
      expect(c.between(2, 3), 2);
    });

    test('weighted buckets follow the weights', () {
      final c = Choices.replay([0, 4, 5, 9]);
      expect([for (var i = 0; i < 4; i++) c.weighted(const [5, 5])], [0, 0, 1, 1]);
    });
  });

  test('FuzzIds are deterministic and rewind', () {
    final ids = FuzzIds(61);
    final a = ids.next(IdKind.item);
    final b = ids.next(IdKind.track);
    expect(a.length, b.length);
    expect(a, startsWith('it_Fz'));
    expect(a.length, 'it_'.length + 12);
    ids.position = 0;
    expect(ids.next(IdKind.item), a);
    expect(FuzzIds(62).next(IdKind.item), isNot(a));
    expect(base62(61, 2), '0z');
    expect(base62(62, 2), '10');
    expect(base62(62 * 62, 2), '00', reason: 'keeps the last width characters');
  });

  test('a seed always runs the same way', () {
    final a = FuzzRunner.run(FuzzCase.forSeed(11, steps: 80));
    final b = FuzzRunner.run(FuzzCase.forSeed(11, steps: 80));
    expect(a.failure, isNull);
    expect(b.choices, a.choices);
    bool notTiming(String k) => !k.startsWith('us:');
    expect({for (final e in b.stats.entries) if (notTiming(e.key)) e.key: e.value},
        {for (final e in a.stats.entries) if (notTiming(e.key)) e.key: e.value});
    expect(b.coverage.toJson(), a.coverage.toJson());
    // Replaying the recorded choices runs the same steps.
    final replay = FuzzRunner.run(FuzzCase.forSeed(11, steps: 80).replaying(a.choices));
    expect(replay.failure, isNull);
    expect(replay.choices, a.choices);
  });

  group('CommandCoverage', () {
    test('lists every subtype once', () {
      expect(allCommandNames.toSet(), hasLength(allCommandNames.length));
    });

    test('counts runs and reads its JSON back', () {
      final cov = CommandCoverage()
        ..record(AddMarker(0), CommandResult.applied)
        ..record(DeleteMarker(const MarkerId('mk_x')), CommandResult.rejected, rejectionCode: 'notFound')
        ..recordName('AddMarker', CommandResult.noop, times: 2);
      expect(cov.count('AddMarker', CommandResult.applied), 1);
      expect(cov.count('AddMarker', CommandResult.noop), 2);
      expect(cov.total('DeleteMarker'), 1);
      expect(cov.unexercised, isNot(contains('AddMarker')));
      expect(cov.neverApplied, contains('DeleteMarker'));
      final back = CommandCoverage.fromJson(jsonDecode(jsonEncode(cov.toJson())) as Map<String, Object?>);
      expect(back.toJson(), cov.toJson());
      final sum = CommandCoverage()
        ..addAll(cov)
        ..addAll(back);
      expect(sum.count('AddMarker', CommandResult.noop), 4);
      expect(cov.table(), contains('NOT exercised'));
    });

    test('refuses a subtype missing from allCommandNames', () {
      expect(() => CommandCoverage().recordName('NoSuchCommand', CommandResult.applied), throwsStateError);
    });
  });

  test('FuzzConfig, FuzzFailure and fixtures round-trip through JSON', () {
    const config = FuzzConfig(
      history: HistoryPolicy(maxEntries: 7, maxApproxBytes: 9000),
      policy: EditPolicy(overlap: OverlapPolicy.reject, maxItems: 120),
    );
    final back = FuzzConfig.fromJson(jsonDecode(jsonEncode(config.toJson())) as Map<String, Object?>);
    expect(back.toJson(), config.toJson());

    const failure = FuzzFailure(FuzzCheck.validator, 3, 'details', action: 'apply X', codes: ['itemsOverlap'], defect: 'FIX-X-1');
    expect(failure.signature, 'validator:FIX-X-1:itemsOverlap');
    final f2 = FuzzFailure.fromJson(jsonDecode(jsonEncode(failure.toJson())) as Map<String, Object?>);
    expect(f2.toJson(), failure.toJson());

    final c = FuzzCase.forSeed(17, steps: 2);
    final run = FuzzRunner.run(c);
    final fixture = FuzzFixture.ofCase('round_trip', c.replaying(run.choices), failure: failure, note: 'a note');
    final text = fixture.encode();
    final read = FuzzFixture.decode(text);
    expect(read.name, 'round_trip');
    expect(read.seed, 17);
    expect(read.defect, 'FIX-X-1');
    expect(read.note, 'a note');
    expect(read.project, c.project);
    expect(read.steps, run.choices);
    expect(read.config.toJson(), c.config.toJson());
    expect(read.encode(), text);
    expect(() => FuzzFixture.decode('{"format": "other"}'), throwsFormatException);
    expect(fixtureNameFor(failure, 9), 'validator_fix_x_1_itemsoverlap_seed9');
  });

  test('the command line fuzzes seeds, writes its report and replays fixtures', () async {
    final out = Directory.systemTemp.createTempSync('core_fuzz_cli');
    addTearDown(() => out.deleteSync(recursive: true));
    final run = await Process.run(Platform.resolvedExecutable, [
      'run',
      'test/fuzz/fuzz_main.dart',
      '--first',
      '40',
      '--seeds',
      '3',
      '--steps',
      '30',
      '--jobs',
      '2',
      '--out',
      out.path,
    ]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    final report = jsonDecode(File('${out.path}/report.json').readAsStringSync()) as Map<String, Object?>;
    expect(report['passed'], 3);
    expect(report['failed'], 0);
    expect((report['coverage']! as Map<String, Object?>)['commands'], isA<Map<String, Object?>>());

    final fixture = Directory('test/fuzz/regressions').listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.json'));
    final replay = await Process.run(Platform.resolvedExecutable, ['run', 'test/fuzz/fuzz_main.dart', '--replay', fixture.path]);
    expect(replay.exitCode, 0, reason: '${replay.stdout}\n${replay.stderr}');

    final usage = await Process.run(Platform.resolvedExecutable, ['run', 'test/fuzz/fuzz_main.dart', '--bogus']);
    expect(usage.exitCode, 2);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
