// OWNER: CORE-35
//
// Core benchmarks (ARCH §18.2 core rows, BUILD_PLAN CORE-35). Usage, from the package root:
//
//   dart run benchmark/run.dart                    measure and print
//   dart run benchmark/run.dart --check            also fail (exit 1) on a budget miss or a
//                                                  > 25 % p90 regression against baseline.json
//   dart run benchmark/run.dart --update-baseline  measure and rewrite benchmark/baseline.json
//   dart run benchmark/run.dart --write-fixture    regenerate test/fixtures/projects/large_2000.json
//   options: --json <file> (write results), --quick (fewer samples), --jit (measure in this VM)
//
// Measurements run in AOT: started with `dart run`, this script compiles itself with
// `dart compile exe` into `.dart_tool/danaview_benchmark/` and runs the binary (the JIT would
// time compilation, which the release app never pays). `scripts/ci/editor/core.sh` runs
// `--check` in the dart-core job.
//
// Regression rule: a row fails when its p90 exceeds `baseline × f × 1.25` and the difference is more
// than [noiseFloorUs] (sub-millisecond rows jitter by tens of µs between runs). Budget rule: a gated
// row fails when its p90 exceeds `budget × f`. f is the host factor: this run's calibration p50
// over the baseline run's (src/calibration.dart), so the gate holds the baseline host's numbers and
// the ARCH §18.2 budgets as met on that host on a slower or faster CI host; on the baseline host
// f ≈ 1. A baseline without a calibration uses f = 1. A failing row is
// re-measured up to twice and the best run counts, so a single noisy run does not fail CI.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import 'src/calibration.dart';
import 'src/core_benchmarks.dart';
import 'src/harness.dart';
import 'src/large_project.dart';

/// Allowed p90 regression against the baseline.
const double regressionFactor = 1.25;

/// Regressions smaller than this (µs) are noise.
const int noiseFloorUs = 50;

const bool _aot = bool.fromEnvironment('dart.vm.product');

Future<void> main(List<String> args) async {
  final jit = args.contains('--jit');
  final root = _option(args, '--root') ?? _packageRoot();
  if (!_aot && !jit && !args.contains('--write-fixture')) {
    exitCode = await _runAot(root, args);
    return;
  }
  exitCode = await _run(root, args);
}

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

String _packageRoot() {
  final script = File.fromUri(Platform.script);
  if (script.path.endsWith('.dart')) return script.parent.parent.path;
  return Directory.current.path;
}

/// Compiles this script to a native executable and runs it with [args].
Future<int> _runAot(String root, List<String> args) async {
  final outDir = Directory('$root/.dart_tool/danaview_benchmark')..createSync(recursive: true);
  final exe = '${outDir.path}/core_bench${Platform.isWindows ? '.exe' : ''}';
  print('Compiling the benchmarks (AOT) …');
  final compile = await Process.run(
    Platform.resolvedExecutable,
    ['compile', 'exe', '--verbosity=error', '-o', exe, '$root/benchmark/run.dart'],
    workingDirectory: root,
  );
  if (compile.exitCode != 0) {
    stderr
      ..write(compile.stdout)
      ..write(compile.stderr);
    return compile.exitCode;
  }
  final p = await Process.start(exe, [...args, '--root', root], workingDirectory: root, mode: ProcessStartMode.inheritStdio);
  return p.exitCode;
}

Future<int> _run(String root, List<String> args) async {
  final check = args.contains('--check');
  final sizes = BenchSizes(quick: args.contains('--quick'));
  final fixture = File('$root/test/fixtures/projects/large_2000.json');
  final baselineFile = File('$root/benchmark/baseline.json');

  if (args.contains('--write-fixture')) {
    final project = buildLargeProject();
    final problems = fixtureProblems(project);
    if (problems.isNotEmpty) {
      stderr.writeln('The generated project does not have the fixture shape:\n  ${problems.join('\n  ')}');
      return 1;
    }
    fixture.writeAsStringSync('${ProjectJsonCodec().encode(project)}\n');
    print('Wrote ${fixture.path} (${shapeOf(project)}).');
    return 0;
  }

  if (!fixture.existsSync()) {
    stderr.writeln('Missing ${fixture.path}; run `dart run benchmark/run.dart --write-fixture`.');
    return 1;
  }
  final body = _bodyOf(fixture.readAsBytesSync());
  final large = openDocument(documentOf(body));
  final failures = <String>[...fixtureProblems(large).map((p) => 'fixture: $p')];
  if (ProjectJsonCodec().encode(large) != utf8.decode(body)) {
    print('note: the fixture does not re-encode to the same bytes (the codec changed); regenerate it with --write-fixture.');
  }
  if (ProjectJsonCodec().encode(buildLargeProject()) != utf8.decode(body)) {
    print('note: the fixture differs from the generator output; regenerate it with --write-fixture.');
  }

  final host = _host();
  print('Core benchmarks on ${host['os']} (${host['cpus']} CPUs), Dart ${host['dart']}, ${_aot ? 'AOT' : 'JIT'}');
  print('Fixture: ${shapeOf(large)}');
  final calibration = calibrationUs(quick: args.contains('--quick'));

  final lane = buildOneLaneProject();
  List<MetricResult> runAll() => [
        ...commandBenchmarks(lane, sizes),
        ...planBenchmarks(large, sizes),
        openBenchmark(body, sizes),
      ];
  List<MetricResult> rerun(String id) => switch (id) {
        'apply_1000' || 'dry_run_1000' => commandBenchmarks(lane, sizes),
        'open_2000' => [openBenchmark(body, sizes)],
        _ => planBenchmarks(large, sizes),
      };

  final results = {for (final r in runAll()) r.id: r};
  final baseline = _readBaseline(baselineFile);
  // The lower of two calibrations (before and after the rows): noise only ever slows a pass down.
  final calibrationNow = [calibration, calibrationUs(quick: args.contains('--quick'))].reduce((a, b) => a < b ? a : b);
  final baseCalibration = _readBaselineCalibration(baselineFile);
  final f = baseCalibration == null || baseCalibration <= 0 ? 1.0 : calibrationNow / baseCalibration;
  final baselineHost = _readBaselineHost(baselineFile);
  print('Host factor ${f.toStringAsFixed(2)} (calibration p50 $calibrationNow µs; baseline '
      '${baseCalibration == null ? 'has no calibration, factor 1' : '$baseCalibration µs on $baselineHost'})');

  if (check) {
    for (var attempt = 0; attempt < 2; attempt++) {
      final failing = results.values.where((r) => _failure(r, baseline[r.id], f) != null).map((r) => r.id).toList();
      if (failing.isEmpty) break;
      print('Re-measuring ${failing.join(', ')} (attempt ${attempt + 2} of 3)');
      for (final id in failing) {
        for (final r in rerun(id).where((r) => r.id == id)) {
          if (r.p90 < results[id]!.p90) results[id] = r;
        }
      }
    }
  }

  print('');
  for (final r in results.values) {
    final base = baseline[r.id];
    final delta = base == null
        ? ''
        : '  (baseline p90 ${(base / 1000).toStringAsFixed(3)} ms × f = ${(base * f / 1000).toStringAsFixed(3)} ms, '
            '${(100 * (r.p90 - base * f) / (base * f)).toStringAsFixed(0)}%; budget × f ${(r.budgetUs * f / 1000).toStringAsFixed(3)} ms)';
    print('${r.describe(hostFactor: f)}$delta');
  }

  final jsonOut = _option(args, '--json');
  final report = {
    'host': host,
    'mode': _aot ? 'aot' : 'jit',
    'calibrationUs': calibrationNow,
    'metrics': {for (final r in results.values) r.id: r.toJson()},
  };
  if (jsonOut != null) File(jsonOut).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');

  if (args.contains('--update-baseline')) {
    if (!_aot) {
      stderr.writeln('Refusing to write a baseline measured in the JIT; run without --jit.');
      return 1;
    }
    baselineFile.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    print('\nWrote ${baselineFile.path}.');
  }

  if (!check) return 0;
  for (final r in results.values) {
    final why = _failure(r, baseline[r.id], f);
    if (why != null) failures.add(why);
  }
  if (baseline.isEmpty) failures.add('no baseline: run --update-baseline on the dev Mac');
  for (final id in baseline.keys) {
    if (!results.containsKey(id)) failures.add('$id is in the baseline but was not measured');
  }
  if (failures.isEmpty) {
    print('\nAll core budgets met; no regression over ${((regressionFactor - 1) * 100).round()}%.');
    return 0;
  }
  stderr.writeln('\nCore benchmark check failed:\n  ${failures.join('\n  ')}');
  return 1;
}

/// Why [r] fails the gate on a host [f] times as slow as the baseline host, or null.
String? _failure(MetricResult r, int? baselineP90, double f) {
  if (r.budgetGated && r.p90 > r.budgetUs * f) {
    return '${r.id}: p90 ${r.p90} µs is over the ARCH §18.2 budget of ${r.budgetUs} µs × host factor ${f.toStringAsFixed(2)}';
  }
  if (baselineP90 != null && r.p90 > baselineP90 * f * regressionFactor && r.p90 - baselineP90 * f > noiseFloorUs) {
    return '${r.id}: p90 ${r.p90} µs regressed more than ${((regressionFactor - 1) * 100).round()}% over the baseline '
        '$baselineP90 µs × host factor ${f.toStringAsFixed(2)}';
  }
  return null;
}

/// The baseline run's calibration p50 (µs), or null.
int? _readBaselineCalibration(File f) {
  if (!f.existsSync()) return null;
  final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  return (j['calibrationUs'] as num?)?.toInt();
}

/// The baseline host's description.
String _readBaselineHost(File f) {
  if (!f.existsSync()) return '(none)';
  final host = (jsonDecode(f.readAsStringSync()) as Map<String, Object?>)['host'] as Map<String, Object?>?;
  return host == null ? '(unknown host)' : '${host['os']} (${host['cpus']} CPUs)';
}

/// Baseline p90s by metric id (empty when there is no baseline file).
Map<String, int> _readBaseline(File f) {
  if (!f.existsSync()) return const {};
  final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  final metrics = (j['metrics'] as Map<String, Object?>?) ?? const {};
  return {for (final e in metrics.entries) e.key: ((e.value! as Map<String, Object?>)['p90Us']! as num).toInt()};
}

/// The fixture body line (without the trailing newline).
Uint8List _bodyOf(Uint8List bytes) {
  var end = bytes.length;
  while (end > 0 && (bytes[end - 1] == 0x0A || bytes[end - 1] == 0x0D)) {
    end--;
  }
  return Uint8List.sublistView(bytes, 0, end);
}

/// Differences of [p] from the ARCH §18.2 design target, plus validity and D-14 limits.
List<String> fixtureProblems(EditProject p) {
  final s = shapeOf(p);
  final limits = LayerLimits().countsOf(p).exceeded(const EditPolicy());
  return [
    if (s.items != LargeShape.items) 'items ${s.items} != ${LargeShape.items}',
    if (s.cues != LargeShape.cues) 'cues ${s.cues} != ${LargeShape.cues}',
    if (s.lanes != LargeShape.lanes) 'lanes ${s.lanes} != ${LargeShape.lanes}',
    if (s.media != LargeShape.media) 'media ${s.media} != ${LargeShape.media}',
    if (s.duration != LargeShape.duration) 'duration ${s.duration} µs != ${LargeShape.duration} µs',
    for (final v in validate(p).take(5)) 'invalid: $v',
    for (final l in limits) 'limit exceeded: $l',
  ];
}

Map<String, Object?> _host() => {
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'cpus': Platform.numberOfProcessors,
      'dart': Platform.version.split(' ').first,
    };
