// OWNER: API-03
//
// Exported from `lib/testing.dart`: the Dart CPU reference renderer and the reference audio mixer
// (ARCH §11.6), the oracle for QA-03 and QA-11, with their content sources. The vector and golden
// builders under `fixtures/` are used by `tool/regen_goldens.dart` and the package tests.

library;

export 'audio_mix.dart';
export 'reference_renderer.dart';
export 'reference_sources.dart';
export 'synthetic_sources.dart';
