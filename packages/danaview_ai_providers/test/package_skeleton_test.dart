// OWNER: AIS-01
//
// The package contract of danaview_ai_providers (AI_STUDIO_PLAN §3.1 rule 9, §5.1, AIS-01): exact
// runtime dependencies, strict analysis, both barrels load, every lib/ file carries a D-33 OWNER
// header, and every file under lib/src/ is exported by exactly the barrel it belongs to
// (`testing.dart` for lib/src/fake/, `danaview_ai_providers.dart` for the rest). The repo-wide
// rules 9, 14 and 15 are in test/architecture/dependency_rules_test.dart at the repo root.

@TestOn('vm')
library;

import 'dart:io';

// Compiling this test proves both barrels and every file they export resolve. The placeholders
// declare no names yet, so the imports are otherwise unused until AIS-08 lands.
// ignore: unused_import
import 'package:danaview_ai_providers/danaview_ai_providers.dart';
// ignore: unused_import
import 'package:danaview_ai_providers/testing.dart';
import 'package:test/test.dart';

List<String> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .map((f) => f.path.replaceAll(r'\', '/'))
    .toList()
  ..sort();

/// The `name:` keys directly under the top-level [section] of a pubspec.
Set<String> _section(String pubspec, String section) {
  final lines = pubspec.split('\n');
  final start = lines.indexOf('$section:');
  if (start < 0) return const {};
  final out = <String>{};
  for (final line in lines.skip(start + 1)) {
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) break;
    final m = RegExp(r'^  (\w+):').firstMatch(line);
    if (m != null) out.add(m[1]!);
  }
  return out;
}

/// Relative export targets of the barrel at [path], as `lib/src/...` paths.
Set<String> _exports(String path) => {
      for (final m in RegExp(r"^export '(src/[^']+)';", multiLine: true).allMatches(File(path).readAsStringSync()))
        'lib/${m[1]}',
    };

void main() {
  test('runtime dependencies are exactly meta, collection, crypto (rule 9)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(_section(pubspec, 'dependencies'), {'meta', 'collection', 'crypto'});
    expect(_section(pubspec, 'dev_dependencies'), {'test', 'lints'});
    expect(pubspec, isNot(contains('sdk: flutter')));
  });

  test('analysis is strict', () {
    final options = File('analysis_options.yaml').readAsStringSync();
    for (final flag in ['strict-casts', 'strict-inference', 'strict-raw-types']) {
      expect(options, matches(RegExp('$flag:\\s*true')));
    }
  });

  test('every lib/ and tool/ file carries an OWNER header (D-33)', () {
    final missing = [
      for (final f in [..._dartFiles('lib'), ..._dartFiles('tool')])
        if (!File(f).readAsStringSync().startsWith('// OWNER: AIS-')) f,
    ];
    expect(missing, isEmpty);
  });

  test('every lib/src file is exported by its barrel, and barrels export only existing files', () {
    final all = _dartFiles('lib/src').toSet();
    final fakes = all.where((f) => f.startsWith('lib/src/fake/')).toSet();
    final public = _exports('lib/danaview_ai_providers.dart');
    final test = _exports('lib/testing.dart');
    expect(public, all.difference(fakes));
    expect(test, fakes);
  });
}
