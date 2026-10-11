// OWNER: CORE-34
//
// Regression fixtures of the model fuzzer (`test/fuzz/regressions/*.json`).
//
// A fixture is a minimized failing run: the start project (as the CORE-22 body JSON, so it does
// not depend on the random project generator), the session config, the seed (it names the run's
// ids and foreign paste projects) and the recorded choices of every step. `FuzzRunner` replays it
// exactly.
//
// A fixture with a `defect` field documents an open defect of fuzz_known_defects.dart: the replay
// must still fail with that defect while the entry is listed. Every other fixture must replay
// without a failure. When the owner fixes a defect, they delete its entry and the fixture's
// `defect` field, and the fixture becomes an ordinary regression test.

import 'dart:convert';
import 'dart:io';

import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/model.dart';

import 'fuzz_runner.dart';

/// One regression fixture.
final class FuzzFixture {
  /// Creates a fixture.
  FuzzFixture({
    required this.name,
    required this.seed,
    required this.config,
    required this.project,
    required this.steps,
    this.defect,
    this.failure,
    this.note,
  });

  /// A fixture for [fuzzCase], which must replay recorded choices.
  factory FuzzFixture.ofCase(String name, FuzzCase fuzzCase, {FuzzFailure? failure, String? note}) => FuzzFixture(
        name: name,
        seed: fuzzCase.seed,
        config: fuzzCase.config,
        project: fuzzCase.project,
        steps: fuzzCase.recorded!,
        defect: failure?.defect,
        failure: failure,
        note: note,
      );

  /// The `format` value of every fixture.
  static const String format = 'danaview-core-fuzz-regression';

  /// The current fixture version.
  static const int version = 1;

  /// File name without `.json`.
  final String name;

  /// Seed of the run (ids, foreign projects).
  final int seed;

  /// Session settings.
  final FuzzConfig config;

  /// The start project.
  final EditProject project;

  /// Recorded choices per step.
  final List<List<int>> steps;

  /// The open defect the replay reproduces, or null when the replay must pass.
  final String? defect;

  /// The failure the fixture was minimized from (informational).
  final FuzzFailure? failure;

  /// A free-text note.
  final String? note;

  /// The case to replay.
  FuzzCase toCase() => FuzzCase(seed: seed, project: project, config: config, steps: steps.length, recorded: steps);

  /// The fixture as JSON text: the top level indented, one line per step, the project on one line.
  String encode() {
    final b = StringBuffer('{\n');
    void field(String key, Object? value, {bool last = false}) =>
        b.write('  ${jsonEncode(key)}: ${jsonEncode(value)}${last ? '\n' : ',\n'}');
    field('format', format);
    field('version', version);
    field('name', name);
    if (note != null) field('note', note);
    if (defect != null) field('defect', defect);
    field('seed', seed);
    if (failure != null) field('failure', failure!.toJson());
    field('config', config.toJson());
    field('project', ProjectJsonCodec().toJson(project));
    b.write('  "steps": [\n');
    for (var i = 0; i < steps.length; i++) {
      b.write('    ${jsonEncode(steps[i])}${i + 1 < steps.length ? ',' : ''}\n');
    }
    b.write('  ]\n}\n');
    return b.toString();
  }

  /// Reads [encode]'s output.
  factory FuzzFixture.decode(String text, {String? name}) {
    final j = jsonDecode(text) as Map<String, Object?>;
    if (j['format'] != format) throw FormatException('not a fuzz regression fixture (format ${j['format']})');
    final v = j['version'];
    if (v is! int || v > version) throw FormatException('unsupported fuzz fixture version $v');
    final decoded = ProjectJsonCodec().decode(jsonEncode(j['project']));
    if (decoded.warnings.isNotEmpty) throw FormatException('fixture project decodes with warnings ${decoded.warnings}');
    final failure = j['failure'];
    return FuzzFixture(
      name: name ?? j['name']! as String,
      seed: j['seed']! as int,
      config: FuzzConfig.fromJson(j['config']! as Map<String, Object?>),
      project: decoded.project,
      steps: [
        for (final s in j['steps']! as List<Object?>) [for (final d in s! as List<Object?>) d! as int],
      ],
      defect: j['defect'] as String?,
      failure: failure == null ? null : FuzzFailure.fromJson(failure as Map<String, Object?>),
      note: j['note'] as String?,
    );
  }

  /// Reads a fixture file (named after the file).
  static FuzzFixture read(File file) {
    final base = file.uri.pathSegments.last;
    return FuzzFixture.decode(file.readAsStringSync(), name: base.endsWith('.json') ? base.substring(0, base.length - 5) : base);
  }

  /// Writes the fixture as `<dir>/<name>.json` and returns the file.
  File write(Directory dir) {
    dir.createSync(recursive: true);
    return File('${dir.path}/$name.json')..writeAsStringSync(encode());
  }

  /// Every fixture in [dir], by name.
  static List<FuzzFixture> readAll(Directory dir) {
    if (!dir.existsSync()) return const [];
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [for (final f in files) read(f)];
  }
}

/// A file name for a failure: the signature in lower-case words plus the seed.
String fixtureNameFor(FuzzFailure failure, int seed) {
  final words = failure.signature.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_').replaceAll(RegExp('^_+|_+\$'), '');
  final short = words.length > 60 ? words.substring(0, 60) : words;
  return '${short}_seed$seed';
}
