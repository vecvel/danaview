// Criterion 4: dependency weight. Size numbers come from tool/aot_size.sh and
// are recorded in the report; these tests pin the facts that can be checked
// without compiling.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

Map<String, Object?> _config() =>
    jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
        as Map<String, Object?>;

void main() {
  test('Flutter-free: no package resolves to the Flutter SDK', () {
    final pkgs = (_config()['packages'] as List).cast<Map<String, Object?>>();
    final names = pkgs.map((p) => p['name']).toSet();
    expect(names, isNot(contains('flutter')));
    expect(names, isNot(contains('sky_engine')));
  });

  test('the Genkit plugins pull in two vendor SDKs (D-47 conflict)', () {
    final pkgs = (_config()['packages'] as List).cast<Map<String, Object?>>();
    final names = pkgs.map((p) => p['name']).toSet();
    expect(names, containsAll(['openai_dart', 'anthropic_sdk_dart']));
  });

  test('every Genkit construction pins isDevEnv: false and promptDir: null',
      () {
    // With isDevEnv left null, AOT keeps the reflection server and the
    // GENKIT_ENV lookup (tool/aot_size.sh, default.aot); with a literal false
    // at every call site the compiler drops them.
    final src = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.readAsStringSync())
        .join('\n');
    final calls = RegExp(r'\bGenkit\(').allMatches(src).map((m) {
      final end = src.indexOf(';', m.end);
      return src.substring(m.end, end);
    }).toList();
    expect(calls, isNotEmpty);
    for (final args in calls) {
      expect(args, contains('isDevEnv: false'));
      expect(args, contains('promptDir: null'));
    }
  });
}
