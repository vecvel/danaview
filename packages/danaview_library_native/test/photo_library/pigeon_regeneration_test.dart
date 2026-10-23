// OWNER: HOM-02
//
// "Pigeon regeneration produces no diff" (BUILD_PLAN HOM-02: generated files committed): runs the pinned Pigeon generator on
// a copy of pigeons/ in a temporary directory and compares its Dart, Swift and Kotlin output with
// the committed files byte for byte. Fix a failure by regenerating from the package root:
//
//   dart run pigeon --input pigeons/library_api.dart

@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _outputs = [
  'lib/src/pigeon/library_api.g.dart',
  'darwin/Classes/Glue/LibraryApi.g.swift',
  'android/src/main/kotlin/com/vecvel/danaview/library/pigeon/LibraryApi.g.kt',
];

/// The `dart` executable of the Flutter SDK running this test, else the one on PATH.
String _dartExecutable() {
  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] case final root?) '$root/bin/dart',
  ];
  // flutter_tester lives in <flutter>/bin/cache/artifacts/engine/<platform>/.
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    candidates.add('${dir.path}/bin/dart');
    dir = dir.parent;
  }
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return 'dart';
}

/// `bin/pigeon.dart` of the pigeon package resolved for this package.
String _pigeonEntryPoint(File packageConfig) {
  final config = jsonDecode(packageConfig.readAsStringSync()) as Map<String, Object?>;
  final packages = (config['packages']! as List<Object?>).cast<Map<String, Object?>>();
  final pigeon = packages.firstWhere((p) => p['name'] == 'pigeon');
  final rootUri = pigeon['rootUri']! as String;
  final root = packageConfig.uri.resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/');
  return File.fromUri(root.resolve('bin/pigeon.dart')).path;
}

void main() {
  test('committed Pigeon output equals a fresh regeneration', () async {
    final pkg = Directory.current;
    final packageConfig = File('${pkg.path}/.dart_tool/package_config.json');
    expect(packageConfig.existsSync(), isTrue, reason: 'run `flutter pub get` first');

    final tmp = Directory.systemTemp.createTempSync('danaview_pigeon_regen_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Directory('${tmp.path}/pigeons').createSync();
    for (final f in Directory('${pkg.path}/pigeons').listSync().whereType<File>()) {
      f.copySync('${tmp.path}/pigeons/${f.uri.pathSegments.last}');
    }

    final result = await Process.run(
      _dartExecutable(),
      ['--packages=${packageConfig.path}', _pigeonEntryPoint(packageConfig), '--input', 'pigeons/library_api.dart'],
      workingDirectory: tmp.path,
    );
    expect(result.exitCode, 0, reason: 'pigeon failed:\n${result.stdout}\n${result.stderr}');

    for (final path in _outputs) {
      final fresh = File('${tmp.path}/$path');
      final committed = File('${pkg.path}/$path');
      expect(fresh.existsSync(), isTrue, reason: '$path was not generated');
      expect(committed.existsSync(), isTrue, reason: '$path is not committed');
      expect(
        committed.readAsStringSync() == fresh.readAsStringSync(),
        isTrue,
        reason: '$path differs from a fresh Pigeon run: regenerate with `dart run pigeon --input pigeons/library_api.dart`',
      );
    }
  });
}
