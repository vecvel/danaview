// OWNER: INT-101
//
// The package contract of danaview_pdf (BUILD_PLAN INT-101; ARCH v1.2 §4.2 rule 21, §4.3): the planned
// dependencies, strict analysis, D-33 OWNER headers and barrels that reach every lib/src file. The
// repo-wide dependency rules are in test/architecture/dependency_rules_test.dart at the repo root.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<String> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .map((f) => f.path.replaceAll(r'\', '/'))
    .toList()
  ..sort();

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

/// Every file reachable from [entry] through relative `export` directives.
Set<String> _reachable(String entry) {
  final out = <String>{};
  void walk(String path) {
    if (!out.add(path)) return;
    final file = File(path);
    if (!file.existsSync()) return;
    for (final m in RegExp(r"^export '([^':]+)'", multiLine: true).allMatches(file.readAsStringSync())) {
      walk(Uri.file(path).resolve(m[1]!).toFilePath().replaceAll(r'\', '/').replaceFirst(RegExp('^.*?(?=lib/)'), ''));
    }
  }

  walk(entry);
  return out;
}

void main() {
  test('dependencies are the planned set (rule 21)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(_section(pubspec, 'dependencies'), {
      'flutter',
    });
    expect(_section(pubspec, 'dev_dependencies'), {'flutter_test', 'flutter_lints', 'pigeon'});
    expect(_section(pubspec, 'dependency_overrides'), isEmpty);
  });

  test('analysis is strict', () {
    final options = File('analysis_options.yaml').readAsStringSync();
    for (final flag in ['strict-casts', 'strict-inference', 'strict-raw-types']) {
      expect(options, matches(RegExp('$flag:\\s*true')));
    }
    expect(options, contains('public_member_api_docs'));
  });

  test('every lib/ file carries an OWNER header (D-33)', () {
    final missing = [
      for (final f in _dartFiles('lib'))
        if (!f.contains('/src/pigeon/') && !RegExp(r'^// OWNER: [A-Z]+-\d+A?\n').hasMatch(File(f).readAsStringSync())) f,
    ];
    expect(missing, isEmpty);
  });

  test('the barrels reach every lib/src file (pigeon output stays private) and only existing files', () {
    final reached = <String>{for (final b in ['lib/danaview_pdf.dart']) ..._reachable(b)};
    final missing = reached.where((f) => !File(f).existsSync()).toList();
    expect(missing, isEmpty, reason: 'barrels export missing files');
    final src = _dartFiles('lib/src').where((f) => !f.startsWith('lib/src/pigeon/')).toSet();
    expect(src.difference(reached), isEmpty, reason: 'lib/src files no barrel reaches');
    expect(reached.where((f) => f.startsWith('lib/src/pigeon/')), isEmpty);
  });

  test('the manifest declares the plugin on android, ios, macos (DanaviewPdfPlugin)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final plugin = pubspec.substring(pubspec.indexOf('\nflutter:\n'));
    for (final platform in ['android', 'ios', 'macos']) {
      expect(plugin, contains('      $platform:\n'), reason: platform);
    }
    expect(RegExp('pluginClass: DanaviewPdfPlugin\n').allMatches(plugin), hasLength(3));
  });
}
