// OWNER: CORE-01
//
// ARCH §4.2 rule 2: danaview_editor_core depends on no Flutter or danaview_* package, and uses dart:io /
// dart:isolate only under lib/src/store/. Also guards the package contract of CORE-01: exact
// dependencies, strict analysis, barrels that export every source file, and the D-33 OWNER header.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Violations in one source file (path relative to the package root, `/`-separated).
List<String> purityViolations(String relPath, String source) {
  final out = <String>[];
  final directive = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);
  final inStore = relPath.startsWith('lib/src/store/') || relPath == 'lib/store.dart';
  for (final m in directive.allMatches(source)) {
    final uri = m[1]!;
    if (uri.startsWith('package:flutter')) out.add('$relPath imports $uri');
    if (uri.startsWith('package:danaview_') && !uri.startsWith('package:danaview_editor_core/')) {
      out.add('$relPath imports $uri');
    }
    if ((uri == 'dart:io' || uri == 'dart:isolate') && !inStore) {
      out.add('$relPath imports $uri outside lib/src/store/');
    }
  }
  return out;
}

Iterable<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _rel(File f) => f.path.replaceAll(r'\', '/');

void main() {
  test('lib/ is pure', () {
    final violations = <String>[];
    for (final f in _dartFiles('lib')) {
      violations.addAll(purityViolations(_rel(f), f.readAsStringSync()));
    }
    expect(violations, isEmpty);
  });

  group('scanner catches the negative fixtures in test/fixtures/purity/', () {
    String fixture(String name) => File('test/fixtures/purity/$name.dart.fixture').readAsStringSync();

    test('flutter import', () => expect(purityViolations('lib/src/model/x.dart', fixture('flutter_import')), hasLength(1)));
    test('flutter_test import', () => expect(purityViolations('lib/src/model/x.dart', fixture('flutter_test_import')), hasLength(1)));
    test('danaview_* import', () => expect(purityViolations('lib/src/ops/x.dart', fixture('danaview_package_import')), hasLength(1)));
    test('dart:io outside store', () => expect(purityViolations('lib/src/plan/x.dart', fixture('dart_io_import')), hasLength(1)));
    test('dart:isolate export outside store', () => expect(purityViolations('lib/src/eval/x.dart', fixture('dart_isolate_export')), hasLength(1)));
    test('dart:io inside store is allowed', () => expect(purityViolations('lib/src/store/x.dart', fixture('dart_io_import')), isEmpty));
    test('dart:io in the store barrel is allowed', () => expect(purityViolations('lib/store.dart', fixture('dart_io_import')), isEmpty));
    test('clean file passes (self import allowed)', () => expect(purityViolations('lib/src/model/x.dart', fixture('clean')), isEmpty));
  });

  group('package contract (CORE-01)', () {
    test('runtime dependencies are exactly meta, collection, crypto, path, characters', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final deps = _section(pubspec, 'dependencies');
      expect(deps.toSet(), {'meta', 'collection', 'crypto', 'path', 'characters'});
      final dev = _section(pubspec, 'dev_dependencies');
      expect(dev, containsAll(['test', 'checks', 'json_schema']));
      expect(pubspec, isNot(contains('flutter:')));
      expect(pubspec, isNot(contains('sdk: flutter')));
    });

    test('analysis is strict', () {
      final options = File('analysis_options.yaml').readAsStringSync();
      for (final flag in ['strict-casts', 'strict-inference', 'strict-raw-types']) {
        expect(options, matches(RegExp('$flag:\\s*true')));
      }
    });

    test('the seven barrels exist and no other barrel is public', () {
      final barrels = Directory('lib')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('.dart'))
          .toSet();
      // `testing.dart` is the CORE-25 in-memory fake barrel (ARCH §4.6 `FakeProjectRepository`).
      expect(barrels, containsAll(['model.dart', 'ops.dart', 'eval.dart', 'formats.dart', 'plan.dart', 'codec.dart', 'store.dart']));
      expect(barrels.difference({'model.dart', 'ops.dart', 'eval.dart', 'formats.dart', 'plan.dart', 'codec.dart', 'store.dart', 'testing.dart'}), isEmpty);
    });

    test('every file under lib/src is reachable from a barrel (export or part)', () {
      final exported = <String>{};
      void walk(String path) {
        final source = File(path).readAsStringSync();
        for (final m in RegExp(r'''^(?:export|part)\s+'([^']+)'(?:\s+(?:show|hide)\s+[^;]+)?;''', multiLine: true).allMatches(source)) {
          final target = m[1]!;
          if (target.startsWith('package:') || target.startsWith('dart:')) continue;
          final rel = p.posix.normalize(p.posix.join(p.posix.dirname(path), target));
          if (exported.add(rel)) walk(rel);
        }
      }

      for (final b in ['model', 'ops', 'eval', 'formats', 'plan', 'codec', 'store']) {
        walk('lib/$b.dart');
      }
      final all = _dartFiles('lib/src').map(_rel).toSet();
      expect(all.difference(exported), isEmpty, reason: 'files not reachable from a barrel');
      expect(exported.difference(all), isEmpty, reason: 'barrels export missing files');
    });

    test('every lib file carries an OWNER header (D-33)', () {
      final missing = [
        for (final f in _dartFiles('lib'))
          if (!f.readAsStringSync().startsWith('// OWNER: ')) _rel(f),
      ];
      expect(missing, isEmpty);
    });
  });
}

/// Names under a top-level `<section>:` key of a pubspec (two-space indented `name:` lines).
List<String> _section(String pubspec, String section) {
  final lines = pubspec.split('\n');
  final start = lines.indexWhere((l) => l == '$section:');
  expect(start, greaterThanOrEqualTo(0), reason: 'pubspec has no $section');
  final names = <String>[];
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) break;
    final m = RegExp(r'^  (\w+):').firstMatch(line);
    if (m != null) names.add(m[1]!);
  }
  return names;
}
