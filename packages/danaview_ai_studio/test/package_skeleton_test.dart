// OWNER: AIS-01
//
// The package contract of danaview_ai_studio (AI_STUDIO_PLAN §3.1 rule 10, §5.1, AIS-01): the
// planned dependencies, strict analysis, the AI Studio off state, D-33 OWNER headers and barrels
// that export every lib/src file. The repo-wide rules are in
// test/architecture/dependency_rules_test.dart at the repo root.

import 'dart:io';

import 'package:danaview_ai_studio/danaview_ai_studio.dart';
import 'package:danaview_ai_studio/testing.dart' as testing;
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

void main() {
  test('AiStudioOff is the AiStudioService while AI Studio is off', () {
    const AiStudioService off = AiStudioOff();
    expect(off, const AiStudioOff());
    expect(off.hashCode, const AiStudioOff().hashCode);
    expect(off.toString(), 'AiStudioOff()');
    expect(const testing.AiStudioOff(), off);
  });

  test('dependencies are the planned set (rule 10)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(_section(pubspec, 'dependencies'), {
      'flutter',
      'characters',
      'collection',
      'meta',
      'path',
      'danaview_ai_providers',
      'danaview_editor_core',
      'danaview_transcription',
    });
    expect(_section(pubspec, 'dev_dependencies'), {'flutter_test', 'flutter_lints'});
  });

  test('analysis is strict', () {
    final options = File('analysis_options.yaml').readAsStringSync();
    for (final flag in ['strict-casts', 'strict-inference', 'strict-raw-types']) {
      expect(options, matches(RegExp('$flag:\\s*true')));
    }
  });

  test('every lib/ file carries an OWNER header (D-33)', () {
    final missing = [
      for (final f in _dartFiles('lib'))
        if (!File(f).readAsStringSync().startsWith('// OWNER: AIS-')) f,
    ];
    expect(missing, isEmpty);
  });

  test('the barrel exports every lib/src file and nothing else', () {
    final exported = {
      for (final m in RegExp(r"^export '(src/[^']+)';", multiLine: true)
          .allMatches(File('lib/danaview_ai_studio.dart').readAsStringSync()))
        'lib/${m[1]}',
    };
    expect(exported, _dartFiles('lib/src').toSet());
  });
}
