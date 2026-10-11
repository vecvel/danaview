// OWNER: CORE-34
// Temporary debugging harness (deleted before hand-off).
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:test/test.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';

import 'fuzz_runner.dart';

void main() {
  final seed = int.parse(Platform.environment['FZ_SEED'] ?? '1');
  final at = int.parse(Platform.environment['FZ_AT'] ?? '128');
  final steps = int.parse(Platform.environment['FZ_STEPS'] ?? '200');
  test('debug', () {
    final r = FuzzRunner.run(FuzzCase.forSeed(seed, steps: steps), trace: (step, a, s) {
      if (step < at - 3 || step > at) return;
      print('step $step action: ${a.describe()}');
      print('  committed valid: ${validate(s.committedProject)} tx ${s.transaction}');
      final p = s.committedProject;
      for (final t in p.tracks) {
        final linked = [for (final i in t.items) if (i.link != null) '${i.id}:${i.link}'];
        if (linked.isNotEmpty) print('  lane ${t.id} ${t.kind.name} links $linked');
      }
    });
    print(r.failure);
  }, timeout: Timeout.none);
}
