// OWNER: CORE-34
//
// Command line of the model fuzzer (the nightly job `scripts/ci/editor/nightly.d/core_fuzz.sh`
// and local reproduction). Run it from packages/vwish_editor_core:
//
//   dart run test/fuzz/fuzz_main.dart                          # seeds 0..9999, 500 steps each
//   dart run test/fuzz/fuzz_main.dart --first 50000 --seeds 2000 --jobs 4
//   dart run test/fuzz/fuzz_main.dart --seed 123 --trace       # one seed, print every action
//   dart run test/fuzz/fuzz_main.dart --seed 123 --strict --fixtures test/fuzz/regressions
//   dart run test/fuzz/fuzz_main.dart --replay test/fuzz/regressions/<name>.json --trace
//   dart run test/fuzz/fuzz_main.dart --replay <fixture>.json --strict --shrink --fixtures DIR
//
// Seeds run on --jobs worker isolates. Every failing seed is reported; up to
// --minimize-per-signature failures of each signature are minimized (fuzz_minimizer.dart) and
// written as regression fixtures to --fixtures (default <out>/fixtures). Copy a fixture into
// test/fuzz/regressions/ to keep it. <out>/report.json holds the counts, the failures, the open
// known defects that fired and the command coverage report.
//
// By default open defects of fuzz_known_defects.dart are tolerated (counted, not failed);
// --strict fails on them too. Exit status: 0 when every seed passed (and, with
// --require-coverage, every EditCommand subtype was exercised), 1 otherwise, 2 for usage errors.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:vwish_editor_core/ops.dart';

import 'fuzz_coverage.dart';
import 'fuzz_fixture.dart';
import 'fuzz_generator.dart';
import 'fuzz_minimizer.dart';
import 'fuzz_runner.dart';

const String _usage = '''
Usage: dart run test/fuzz/fuzz_main.dart [options]
  --first N                   first seed (default 0)
  --seeds N                   number of seeds (default 10000)
  --seed N                    run one seed (same as --first N --seeds 1)
  --steps N                   steps per seed (default 500)
  --jobs N                    worker isolates (default: half the processors)
  --out DIR                   report directory (default build/core_fuzz)
  --fixtures DIR              where minimized fixtures go (default <out>/fixtures)
  --strict                    fail on open known defects too
  --no-minimize               report failures without minimizing them
  --minimize-per-signature N  failures minimized per signature (default 2)
  --minimize-seconds N        time budget per minimization (default 300)
  --require-coverage          fail unless every EditCommand subtype ran
  --replay FILE               replay a regression fixture
  --shrink                    with --replay: minimize the replayed failure again and write it
                              to --fixtures (e.g. --strict to keep the first known defect)
  --trace                     print every action (with --seed or --replay)
  -h, --help                  this help''';

Future<void> main(List<String> args, [Object? message]) async {
  if (message is SendPort) {
    // A worker isolate (its own isolate group, so the workers do not share a heap).
    _worker(args, message);
    return;
  }
  final _Options o;
  try {
    o = _Options.parse(args);
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln(_usage);
    exitCode = 2;
    return;
  }
  if (o.help) {
    stdout.writeln(_usage);
    return;
  }
  exitCode = o.replay != null ? _replay(o) : await _fuzz(o);
}

final class _Options {
  int first = 0;
  int seeds = 10000;
  int steps = 500;
  int jobs = Platform.numberOfProcessors ~/ 2 < 1 ? 1 : Platform.numberOfProcessors ~/ 2;
  String out = 'build/core_fuzz';
  String? fixtures;
  bool strict = false;
  bool minimize = true;
  bool shrink = false;
  int minimizePerSignature = 2;
  int minimizeSeconds = 300;
  bool requireCoverage = false;
  String? replay;
  bool trace = false;
  bool help = false;

  static _Options parse(List<String> args) {
    final o = _Options();
    var i = 0;
    String value() {
      if (i + 1 >= args.length) throw FormatException('${args[i]} needs a value');
      return args[++i];
    }

    int number() {
      final v = int.tryParse(value());
      if (v == null || v < 0) throw FormatException('${args[i - 1]} needs a non-negative integer');
      return v;
    }

    for (; i < args.length; i++) {
      switch (args[i]) {
        case '--first':
          o.first = number();
        case '--seeds':
          o.seeds = number();
        case '--seed':
          o
            ..first = number()
            ..seeds = 1;
        case '--steps':
          o.steps = number();
        case '--jobs':
          o.jobs = number();
          if (o.jobs < 1) o.jobs = 1;
        case '--out':
          o.out = value();
        case '--fixtures':
          o.fixtures = value();
        case '--strict':
          o.strict = true;
        case '--shrink':
          o.shrink = true;
        case '--no-minimize':
          o.minimize = false;
        case '--minimize-per-signature':
          o.minimizePerSignature = number();
        case '--minimize-seconds':
          o.minimizeSeconds = number();
        case '--require-coverage':
          o.requireCoverage = true;
        case '--replay':
          o.replay = value();
        case '--trace':
          o.trace = true;
        case '-h' || '--help':
          o.help = true;
        default:
          throw FormatException('unknown option ${args[i]}');
      }
    }
    return o;
  }
}

void _traceAction(int step, FuzzAction action, EditSession session) => stdout.writeln('step $step: ${action.describe()}');

int _replay(_Options o) {
  final fixture = FuzzFixture.read(File(o.replay!));
  stdout.writeln('replaying ${fixture.name}: seed ${fixture.seed}, ${fixture.steps.length} steps'
      '${fixture.defect == null ? '' : ', open defect ${fixture.defect}'}');
  final r = FuzzRunner.run(fixture.toCase(),
      tolerateKnownDefects: !o.strict, trace: o.trace ? _traceAction : null);
  stdout.writeln(r.failure == null ? 'passed ${r.stats}' : 'FAILED ${r.failure}');
  if (o.shrink && r.failure != null) {
    final m = FuzzMinimizer(tolerateKnownDefects: !o.strict, timeBudget: Duration(seconds: o.minimizeSeconds))
        .minimize(fixture.toCase());
    final file = FuzzFixture.ofCase(fixtureNameFor(m.failure, fixture.seed), m.fuzzCase,
            failure: m.failure, note: 'Minimized by fuzz_main.dart from fixture ${fixture.name}: $m.')
        .write(Directory(o.fixtures ?? '${o.out}/fixtures'));
    stdout.writeln('$m -> ${file.path}');
  }
  return r.failure == null ? 0 : 1;
}

/// Runs seeds `first + worker + k * jobs` (args: first, count, worker, jobs, steps, strict) and
/// reports each seed to [port] as JSON-compatible maps: `{seed, failure?, known}` per seed, then
/// `{done: true, coverage}`.
void _worker(List<String> args, SendPort port) {
  final [first, count, worker, jobs, steps] = [for (final a in args.take(5)) int.parse(a)];
  final strict = args[5] == 'strict';
  final coverage = CommandCoverage();
  for (var k = worker; k < count; k += jobs) {
    final seed = first + k;
    final FuzzResult r;
    try {
      r = FuzzRunner.run(FuzzCase.forSeed(seed, steps: steps), tolerateKnownDefects: !strict);
    } on Object catch (e, st) {
      // The start project or the runner itself failed outside the guarded steps.
      final f = FuzzFailure(FuzzCheck.exception, -1, '$e\n$st', codes: ['${e.runtimeType}']);
      port.send({'seed': seed, 'failure': f.toJson(), 'known': <String, int>{}, 'stopped': false});
      continue;
    }
    coverage.addAll(r.coverage);
    port.send({
      'seed': seed,
      if (r.failure != null) 'failure': r.failure!.toJson(),
      'known': {for (final e in r.stats.entries) if (e.key.startsWith('known:')) e.key.substring(6): e.value},
      'stopped': r.stats.containsKey('stoppedAtStep'),
    });
  }
  port.send({'done': true, 'worker': worker, 'coverage': coverage.toJson()});
}

/// One failing seed.
final class _Failed {
  _Failed(this.seed, this.failure);
  final int seed;
  final FuzzFailure failure;
}

/// The URI of this script, for the worker isolates.
Uri get _self {
  final s = Platform.script;
  if (s.path.endsWith('.dart')) return s;
  return Directory.current.uri.resolve('test/fuzz/fuzz_main.dart');
}

Future<int> _fuzz(_Options o) async {
  final sw = Stopwatch()..start();
  final outDir = Directory(o.out)..createSync(recursive: true);
  final fixturesDir = Directory(o.fixtures ?? '${o.out}/fixtures');
  final jobs = o.jobs > o.seeds ? (o.seeds < 1 ? 1 : o.seeds) : o.jobs;
  stdout.writeln('core fuzz: seeds ${o.first}..${o.first + o.seeds - 1}, ${o.steps} steps, $jobs jobs'
      '${o.strict ? ', strict' : ''}');

  final coverage = CommandCoverage();
  final known = <String, int>{};
  final failures = <_Failed>[];
  var done = 0, stopped = 0;
  if (o.trace && o.seeds == 1) {
    // Tracing runs in this isolate so the actions print in order.
    final r = FuzzRunner.run(FuzzCase.forSeed(o.first, steps: o.steps), tolerateKnownDefects: !o.strict, trace: _traceAction);
    coverage.addAll(r.coverage);
    r.stats.forEach((k, v) {
      if (k.startsWith('known:')) known[k.substring(6)] = (known[k.substring(6)] ?? 0) + v;
    });
    if (r.stats.containsKey('stoppedAtStep')) stopped++;
    if (r.failure != null) failures.add(_Failed(o.first, r.failure!));
    stdout.writeln(r.failure == null ? 'seed ${o.first} passed ${r.stats}' : 'FAILED seed ${o.first}: ${_firstLine('${r.failure}')}');
    done = 1;
  } else {
    final port = ReceivePort();
    final finished = Completer<void>();
    final reported = <int>{};
    var running = jobs;
    port.listen((Object? m) {
      final msg = m! as Map<Object?, Object?>;
      if (msg['done'] == true) {
        if (!reported.add(msg['worker']! as int)) return;
        coverage.addAll(CommandCoverage.fromJson((msg['coverage']! as Map<Object?, Object?>).cast<String, Object?>()));
        if (--running == 0) finished.complete();
        return;
      }
      done++;
      final seed = msg['seed']! as int;
      (msg['known']! as Map<Object?, Object?>).forEach((k, v) => known[k! as String] = (known[k] ?? 0) + (v! as int));
      if (msg['stopped'] == true) stopped++;
      final f = msg['failure'] as Map<Object?, Object?>?;
      if (f != null) {
        final failure = FuzzFailure.fromJson(f.cast<String, Object?>());
        failures.add(_Failed(seed, failure));
        stdout.writeln('FAILED seed $seed: ${_firstLine('$failure')}');
      }
      if (done % 250 == 0 || done == o.seeds) {
        stdout.writeln('  $done/${o.seeds} seeds, ${failures.length} failed, ${sw.elapsed.inSeconds} s');
      }
    });
    // A worker that dies without reporting `done` fails the run instead of hanging it.
    final exits = ReceivePort();
    var crashed = 0;
    exits.listen((Object? w) {
      // The worker's last report may still be queued: look again a moment later.
      Timer(const Duration(seconds: 1), () {
        if (!finished.isCompleted && w is int && !reported.contains(w)) {
          crashed++;
          reported.add(w);
          stdout.writeln('FAILED: worker $w exited before finishing its seeds');
          if (--running == 0) finished.complete();
        }
      });
    });
    for (var w = 0; w < jobs; w++) {
      final args = ['${o.first}', '${o.seeds}', '$w', '$jobs', '${o.steps}', if (o.strict) 'strict' else 'tolerant'];
      final isolate = await Isolate.spawnUri(_self, args, port.sendPort, paused: true);
      isolate
        ..addOnExitListener(exits.sendPort, response: w)
        ..resume(isolate.pauseCapability!);
    }
    await finished.future;
    port.close();
    exits.close();
    if (crashed > 0) failures.add(_Failed(-1, FuzzFailure(FuzzCheck.exception, -1, '$crashed worker isolate(s) crashed')));
  }
  failures.sort((a, b) => a.seed.compareTo(b.seed));

  // Minimize up to N failures per signature, in parallel.
  final written = <String>[];
  if (o.minimize && failures.isNotEmpty) {
    final perSignature = <String, int>{};
    final todo = <_Failed>[];
    for (final f in failures) {
      final sig = f.failure.signature;
      if ((perSignature[sig] = (perSignature[sig] ?? 0) + 1) <= o.minimizePerSignature) todo.add(f);
    }
    stdout.writeln('minimizing ${todo.length} failure(s)...');
    for (var i = 0; i < todo.length; i += jobs) {
      final batch = todo.sublist(i, i + jobs > todo.length ? todo.length : i + jobs);
      final results = await Future.wait([
        for (final f in batch) _minimizeInIsolate(f.seed, o.steps, o.strict, Duration(seconds: o.minimizeSeconds)),
      ]);
      for (var k = 0; k < batch.length; k++) {
        final res = results[k];
        if (res is String) {
          stdout.writeln('  seed ${batch[k].seed}: could not minimize: $res');
          continue;
        }
        final m = res! as MinimizeResult;
        final fixture = FuzzFixture.ofCase(fixtureNameFor(m.failure, batch[k].seed), m.fuzzCase,
            failure: m.failure, note: 'Minimized by fuzz_main.dart from seed ${batch[k].seed} (${o.steps} steps): $m.');
        final file = fixture.write(fixturesDir);
        written.add(file.path);
        stdout.writeln('  seed ${batch[k].seed}: $m -> ${file.path}');
      }
    }
  }

  final missing = coverage.unexercised;
  final report = {
    'first': o.first,
    'seeds': o.seeds,
    'steps': o.steps,
    'strict': o.strict,
    'passed': o.seeds - failures.length,
    'failed': failures.length,
    'stoppedByKnownDefect': stopped,
    'knownDefects': known,
    'failures': [for (final f in failures) {'seed': f.seed, ...f.failure.toJson()}],
    'fixtures': written,
    'elapsedSeconds': sw.elapsed.inSeconds,
    'coverage': coverage.toJson(),
  };
  File('${outDir.path}/report.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout
    ..writeln()
    ..writeln(coverage.table())
    ..writeln()
    ..writeln('core fuzz: ${o.seeds - failures.length}/${o.seeds} seeds passed in ${sw.elapsed.inSeconds} s; '
        'open known defects fired: ${known.isEmpty ? 'none' : known}; report ${outDir.path}/report.json');
  if (failures.isNotEmpty) {
    stdout.writeln('${failures.length} seed(s) failed. Reproduce one with: dart run test/fuzz/fuzz_main.dart --seed '
        '${failures.first.seed} --steps ${o.steps}${o.strict ? ' --strict' : ''} --trace');
    if (written.isNotEmpty) stdout.writeln('Minimized fixtures: copy them into test/fuzz/regressions/ (see fuzz_fixture.dart).');
    return 1;
  }
  if (o.requireCoverage && missing.isNotEmpty) {
    stdout.writeln('EditCommand subtypes not exercised: ${missing.join(', ')}');
    return 1;
  }
  return 0;
}

/// Minimizes [seed]'s failure on another isolate: a [MinimizeResult], or an error message.
Future<Object?> _minimizeInIsolate(int seed, int steps, bool strict, Duration budget) => Isolate.run(() {
      try {
        return FuzzMinimizer(tolerateKnownDefects: !strict, timeBudget: budget).minimize(FuzzCase.forSeed(seed, steps: steps));
      } on Object catch (e) {
        return '$e';
      }
    });

String _firstLine(String s) {
  final i = s.indexOf('\n');
  final line = i < 0 ? s : s.substring(0, i);
  return line.length > 400 ? '${line.substring(0, 400)}...' : line;
}
