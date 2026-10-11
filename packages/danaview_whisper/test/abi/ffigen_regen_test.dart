// OWNER: AI-02
//
// "ffigen output committed and regenerated without diff": regenerates the bindings from
// src/dv_whisper.h into a temp file with the committed ffigen.yaml settings and compares. Skipped
// where libclang is unavailable (the CI job `flutter-packages` runs it on macOS and Linux).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('regenerating the FFI bindings from dv_whisper.h produces no diff', () async {
    // Inside the package (under .dart_tool) so the formatter sees the package's language version.
    final tmp = Directory('.dart_tool/ffigen_check')..createSync(recursive: true);
    addTearDown(() => tmp.deleteSync(recursive: true));
    final out = File('${tmp.absolute.path}/bindings.g.dart');
    final header = File('src/dv_whisper.h').absolute.path;
    final config = File('ffigen.yaml')
        .readAsStringSync()
        .replaceFirst(RegExp(r"output: '[^']*'"), "output: '${out.path}'")
        .replaceFirst("entry-points:\n    - 'src/dv_whisper.h'", "entry-points:\n    - '$header'")
        .replaceFirst("include-directives:\n    - 'src/dv_whisper.h'", "include-directives:\n    - '**dv_whisper.h'");
    final cfg = File('${tmp.absolute.path}/ffigen.yaml')..writeAsStringSync(config);

    final ProcessResult run;
    try {
      run = await Process.run('dart', ['run', 'ffigen', '--config', cfg.path]);
    } on ProcessException catch (e) {
      markTestSkipped('dart is not on PATH: ${e.message}');
      return;
    }
    if (!out.existsSync()) {
      markTestSkipped('ffigen could not run here (libclang missing?): ${run.stderr}${run.stdout}'.split('\n').first);
      return;
    }
    expect(out.readAsStringSync(), File('lib/src/ffi/dv_whisper_bindings.g.dart').readAsStringSync(),
        reason: 'run: dart run ffigen --config ffigen.yaml');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
