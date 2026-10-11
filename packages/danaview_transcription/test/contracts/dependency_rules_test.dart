// OWNER: AI-08
//
// ARCH §4.2 rule 6: danaview_transcription is pure Dart logic. It may depend on danaview_editor_core,
// danaview_whisper and danaview_data only, never on the engine packages, danaview_editor, danaview_features or
// widget libraries.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _allowedDanaview = {'danaview_editor_core', 'danaview_whisper', 'danaview_data'};
const _forbiddenFragments = ['danaview_editor_engine', 'danaview_engine', 'danaview_editor/', 'danaview_features', 'danaview_ui_kit', 'danaview_platform'];

void main() {
  final root = Directory.current.path.endsWith('danaview_transcription') ? Directory.current : Directory('packages/danaview_transcription');

  test('pubspec depends on no danaview package beyond core, whisper and data', () {
    final lines = File('${root.path}/pubspec.yaml').readAsLinesSync();
    final deps = <String>{};
    var inDeps = false;
    for (final l in lines) {
      if (RegExp(r'^\S').hasMatch(l)) inDeps = l.startsWith('dependencies:');
      final m = RegExp(r'^  (danaview_\w+):').firstMatch(l);
      if (inDeps && m != null) deps.add(m.group(1)!);
    }
    expect(deps, _allowedDanaview);
  });

  test('lib/ imports only allowed packages and no widget or UI library', () {
    final files = Directory('${root.path}/lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
    expect(files, isNotEmpty);
    final importRe = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);
    for (final f in files) {
      final isTesting = f.path.endsWith('lib/testing.dart');
      for (final m in importRe.allMatches(f.readAsStringSync())) {
        final uri = m.group(1)!;
        for (final bad in _forbiddenFragments) {
          expect(uri.contains(bad), isFalse, reason: '${f.path} imports $uri');
        }
        if (uri.startsWith('package:danaview_')) {
          final pkg = uri.substring('package:'.length).split('/').first;
          expect(_allowedDanaview.contains(pkg) || pkg == 'danaview_transcription', isTrue, reason: '${f.path} imports $uri');
        }
        expect(uri.startsWith('package:flutter/'), isFalse, reason: '${f.path} imports Flutter UI: $uri (${isTesting ? 'testing' : 'lib'})');
      }
    }
  });
}
