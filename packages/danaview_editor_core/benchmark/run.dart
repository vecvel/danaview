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
// Regression rule (always on): a row fails when its p90 exceeds `baseline × f × 1.25` and the
// difference is more than [noiseFloorUs] (sub-millisecond rows jitter by tens of µs between runs).
// f is the row's host factor: this run's calibration p50 of the row's kind ([rowKinds]) over the
// baseline run's (src/calibration.dart), so the gate holds the baseline host's numbers on a slower
// or faster CI host; on the baseline host f ≈ 1. A kind missing from the baseline uses f = 1.
// Rows in [medianGatedRows] compare p50 instead of p90 (and p90 as well with DV_PERF_STRICT=1):
// their p90 is set by old-generation GC pauses, whose share differs between hosts (ubuntu x64 vs
// the arm64 dev Mac) in a way no p50 calibration tracks.
// Probe rule (always on): a probe kind's factor may not exceed the codec factor × [probeDriftLimit]
// (a probe runs the row's own encoder, so this catches an encoder slowdown the probe would hide).
// Budget rule (only with DV_PERF_STRICT=1, the dev-Mac / device check): a gated row fails when its
// p90 exceeds its ARCH §18.2 budget, unscaled; these are device budgets, which a slower CI host
// misses without any regression, so in CI a budget miss is reported but does not fail. A failing
// row is re-measured up to twice and the best run counts, so a single noisy run does not fail CI.

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

/// How far a probe kind's host factor may exceed the codec factor (see the probe rule above).
const double probeDriftLimit = 1.6;

/// Rows whose regression gate uses p50 off the baseline host. The autosave row allocates a
/// multi-MB String and byte buffer per sample, so its p90 is old-generation GC: p90/p50 is ≈ 1.16
/// on the dev Mac but ≈ 1.3-1.4 on ubuntu runners, which put its p90 14-31 % over baseline × f
/// on every CI run while its p50 stayed within the probe factor (0.93-1.15×). The probe is a p50,
/// so the row is gated on its p50; DV_PERF_STRICT=1 (the baseline host) gates its p90 too.
const Set<String> medianGatedRows = {'autosave_block_2000'};

/// DV_PERF_STRICT=1 also fails on absolute ARCH §18.2 budget misses (dev Mac / devices).
final bool perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';

const bool _aot = bool.fromEnvironment('dart.vm.product');

/// The calibration each row is normalized by.
///
/// The compile rows build thousands of plan layers per sample, so like the plan encoder they are
/// allocation- and GC-bound, which the compute probe (a few thousand small objects, young
/// generation only) is not. Across 21 ubuntu-latest gate runs (2026-10-28..30) their p50 and p90
/// over baseline ran 0.97-1.40× the compute factor (incremental p50 excess over compute tracked the
/// planEncode/compute ratio with slope ≈ 1.0) but 0.83-1.19× the planEncode factor, so they are
/// normalized by [CalibrationKind.planEncode]. That probe times only the plan encoder on a
/// pre-compiled plan, so a compile slowdown does not move it and still fails the row.
const Map<String, CalibrationKind> rowKinds = {
  'apply_1000': CalibrationKind.compute,
  'dry_run_1000': CalibrationKind.compute,
  'incremental_compile_2000': CalibrationKind.planEncode,
  'full_compile_2000': CalibrationKind.planEncode,
  'plan_encode_2000': CalibrationKind.planEncode,
  'autosave_block_2000': CalibrationKind.autosave,
  'open_2000': CalibrationKind.codec,
};

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
  final probes = encodeProbes();
  final calibration = calibrationUs(quick: args.contains('--quick'), probes: probes);

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
  final again = calibrationUs(quick: args.contains('--quick'), probes: probes);
  final calibrationNow = {for (final k in CalibrationKind.values) k: calibration[k]! < again[k]! ? calibration[k]! : again[k]!};
  final baseCalibration = _readBaselineCalibration(baselineFile);
  final factors = {
    for (final k in CalibrationKind.values)
      k: (baseCalibration[k] ?? 0) <= 0 ? 1.0 : calibrationNow[k]! / baseCalibration[k]!,
  };
  double factorOf(String id) => factors[rowKinds[id] ?? CalibrationKind.compute]!;
  print('Host factors against the baseline host (${_readBaselineHost(baselineFile)}): '
      '${[for (final k in CalibrationKind.values) '${k.name} ${factors[k]!.toStringAsFixed(2)} (${calibrationNow[k]} µs vs ${baseCalibration[k] ?? 'none'})'].join(', ')}');
  print(perfStrict
      ? 'DV_PERF_STRICT=1: absolute ARCH §18.2 budgets are gated.'
      : 'Absolute ARCH §18.2 budgets are reported, not gated (set DV_PERF_STRICT=1 on the dev Mac / devices).');

  if (check) {
    for (var attempt = 0; attempt < 2; attempt++) {
      final failing = results.values.where((r) => _failure(r, baseline[r.id], factorOf(r.id)) != null).map((r) => r.id).toList();
      if (failing.isEmpty) break;
      print('Re-measuring ${failing.join(', ')} (attempt ${attempt + 2} of 3)');
      for (final id in failing) {
        for (final r in rerun(id).where((r) => r.id == id)) {
          if (_gateStat(r) < _gateStat(results[id]!)) results[id] = r;
        }
      }
    }
  }

  print('');
  for (final r in results.values) {
    final base = baseline[r.id];
    final f = factorOf(r.id);
    final median = medianGatedRows.contains(r.id);
    final stat = median ? 'p50' : 'p90';
    final b = base == null ? null : (median ? base.p50 : base.p90);
    final delta = b == null
        ? ''
        : '  (baseline $stat ${(b / 1000).toStringAsFixed(3)} ms × f = ${(b * f / 1000).toStringAsFixed(3)} ms, '
            '${(100 * (_gateStat(r) - b * f) / (b * f)).toStringAsFixed(0)}%)';
    print('${r.describe(gated: perfStrict)}$delta');
  }

  final jsonOut = _option(args, '--json');
  final report = {
    'host': host,
    'mode': _aot ? 'aot' : 'jit',
    'calibrationUs': {for (final k in CalibrationKind.values) k.name: calibrationNow[k]},
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
    final why = _failure(r, baseline[r.id], factorOf(r.id));
    if (why != null) failures.add(why);
  }
  for (final k in CalibrationKind.values.where((k) => k.isProbe)) {
    if (!baseCalibration.containsKey(k) || !baseCalibration.containsKey(CalibrationKind.codec)) continue;
    if (factors[k]! > factors[CalibrationKind.codec]! * probeDriftLimit) {
      failures.add('probe ${k.name}: host factor ${factors[k]!.toStringAsFixed(2)} is over the codec factor '
          '${factors[CalibrationKind.codec]!.toStringAsFixed(2)} × $probeDriftLimit; the encoder itself slowed down');
    }
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

/// The statistic [r] is regression-gated on off the baseline host (see [medianGatedRows]).
int _gateStat(MetricResult r) => medianGatedRows.contains(r.id) ? r.p50 : r.p90;

/// Why [r] fails the gate on a host [f] times as slow as the baseline host, or null.
String? _failure(MetricResult r, ({int p50, int p90})? base, double f) {
  if (perfStrict && r.budgetGated && r.p90 > r.budgetUs) {
    return '${r.id}: p90 ${r.p90} µs is over the ARCH §18.2 budget of ${r.budgetUs} µs (DV_PERF_STRICT=1)';
  }
  if (base == null) return null;
  String? regressed(String stat, int now, int was) {
    if (now <= was * f * regressionFactor || now - was * f <= noiseFloorUs) return null;
    return '${r.id}: $stat $now µs regressed more than ${((regressionFactor - 1) * 100).round()}% over the baseline '
        '$was µs × host factor ${f.toStringAsFixed(2)}';
  }

  final median = medianGatedRows.contains(r.id);
  return (median ? regressed('p50', r.p50, base.p50) : null) ??
      (!median || perfStrict ? regressed('p90', r.p90, base.p90) : null);
}

/// The baseline run's calibration p50s (µs) by kind (empty without a calibration).
Map<CalibrationKind, int> _readBaselineCalibration(File f) {
  if (!f.existsSync()) return const {};
  final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  final c = j['calibrationUs'];
  if (c is! Map<String, Object?>) return const {};
  return {
    for (final k in CalibrationKind.values)
      if (c[k.name] is num) k: (c[k.name]! as num).toInt(),
  };
}

/// The baseline host's description.
String _readBaselineHost(File f) {
  if (!f.existsSync()) return '(none)';
  final host = (jsonDecode(f.readAsStringSync()) as Map<String, Object?>)['host'] as Map<String, Object?>?;
  return host == null ? '(unknown host)' : '${host['os']} (${host['cpus']} CPUs)';
}

/// Baseline p50s and p90s by metric id (empty when there is no baseline file).
Map<String, ({int p50, int p90})> _readBaseline(File f) {
  if (!f.existsSync()) return const {};
  final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  final metrics = (j['metrics'] as Map<String, Object?>?) ?? const {};
  return {
    for (final e in metrics.entries)
      e.key: (
        p50: ((e.value! as Map<String, Object?>)['p50Us']! as num).toInt(),
        p90: ((e.value! as Map<String, Object?>)['p90Us']! as num).toInt(),
      ),
  };
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
