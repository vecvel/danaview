// OWNER: AI-02
//
// The C ABI header, the committed ffigen bindings and the Dart API agree. `ffigen` itself cannot
// run in the unit-test environment (it needs libclang); CI regenerates and diffs
// (`dart run ffigen --config ffigen.yaml && git diff --exit-code lib/src/ffi/dv_whisper_bindings.g.dart`).
// These checks catch a header edit without regeneration.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

void main() {
  final header = File('src/dv_whisper.h').readAsStringSync();
  final bindings = File('lib/src/ffi/dv_whisper_bindings.g.dart').readAsStringSync();

  test('ABI version is 1 in the header, the bindings comment and Dart', () {
    expect(RegExp(r'#define DV_ABI_VERSION (\d+)').firstMatch(header)!.group(1), '1');
    expect(dvAbiVersion, 1);
    expect(bindings, contains('C ABI version 1'));
  });

  test('every DV_API function of the header has a generated binding with the same symbol', () {
    final functions = RegExp(r'DV_API\s+[^;(]*?\b(dv_\w+)\s*\(').allMatches(header).map((m) => m.group(1)!).toList();
    expect(functions, isNotEmpty);
    expect(functions.toSet().length, functions.length, reason: 'duplicate declarations');
    for (final f in functions) {
      expect(bindings, contains("'$f'"), reason: 'binding for $f is missing; run ffigen');
    }
    // The headline entry points of ai.md §4.5.
    expect(functions, containsAll(<String>[
      'dv_abi_version', 'dv_engine_version', 'dv_shutdown_all', 'dv_model_load', 'dv_model_info_get', 'dv_model_release',
      'dv_job_start', 'dv_job_status_get', 'dv_job_take_segments_json', 'dv_job_cancel', 'dv_job_pause', 'dv_job_resume',
      'dv_job_set_threads', 'dv_job_free', 'dv_free',
    ]));
  });

  test('every binding symbol exists in the header (no stale generated code)', () {
    final symbols = RegExp(r"_lookup<[^>]*>+\(\s*'(dv_\w+)'\s*\)").allMatches(bindings).map((m) => m.group(1)!).toSet();
    final declared = RegExp(r'\b(dv_\w+)\s*\(').allMatches(header).map((m) => m.group(1)!).toSet();
    expect(symbols, isNotEmpty);
    for (final s in symbols) {
      expect(declared, contains(s), reason: '$s is in the bindings but not in the header');
    }
  });

  test('every public struct starts with struct_size and has a generated class', () {
    for (final name in ['dv_model_params', 'dv_model_info', 'dv_job_params', 'dv_job_status']) {
      final body = RegExp(r'typedef struct \{\s*int32_t struct_size;[\s\S]*?\} ' + name + r';').hasMatch(header);
      expect(body, isTrue, reason: '$name must begin with int32_t struct_size');
      expect(bindings, contains('final class $name extends ffi.Struct'));
    }
    expect(bindings, contains('final class dv_model extends ffi.Opaque'));
    expect(bindings, contains('final class dv_job extends ffi.Opaque'));
  });

  test('status, state and phase enums keep their ABI values', () {
    int value(String name) => int.parse(RegExp('$name = (\\d+)').firstMatch(header)!.group(1)!);
    expect(value('DV_OK'), 0);
    expect(value('DV_ERR_INVALID_ARG'), 1);
    expect(value('DV_ERR_BUSY'), 8);
    expect(value('DV_ERR_NO_SPEECH'), 10);
    expect(value('DV_ERR_INTERNAL'), 99);
    expect(value('DV_JOB_RUNNING'), 1);
    expect(value('DV_JOB_CANCELLED'), 5);
    expect(value('DV_MODE_DETECT_LANGUAGE'), 1);
    expect(value('DV_PHASE_DECODING'), 3);
    // Dart enums mirror the native ones by order.
    expect(WhisperJobState.values.map((s) => s.name), ['running', 'paused', 'succeeded', 'failed', 'cancelled']);
    expect(WhisperPhase.values.map((s) => s.name), ['preparing', 'vad', 'encoding', 'decoding']);
  });

  test('DTW presets map to whisper_alignment_heads_preset values', () {
    // third_party/whisper.cpp/include/whisper.h: NONE=0 N_TOP_MOST=1 CUSTOM=2 TINY_EN=3 TINY=4 BASE_EN=5 BASE=6 SMALL_EN=7 SMALL=8
    expect({for (final p in WhisperDtwPreset.values) p.name: p.nativeValue}, {'none': 0, 'tiny': 4, 'base': 6, 'small': 8});
    final whisperH = File('third_party/whisper.cpp/include/whisper.h');
    if (whisperH.existsSync()) {
      final names = RegExp(r'WHISPER_AHEADS_(\w+),').allMatches(whisperH.readAsStringSync()).map((m) => m.group(1)!).toList();
      expect(names[WhisperDtwPreset.tiny.nativeValue], 'TINY');
      expect(names[WhisperDtwPreset.base.nativeValue], 'BASE');
      expect(names[WhisperDtwPreset.small.nativeValue], 'SMALL');
      expect(names[WhisperDtwPreset.none.nativeValue], 'NONE');
    }
  });

  test('no DynamicLibrary is opened outside the loader and the generated bindings (nothing at import time)', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final p = f.path.replaceAll('\\', '/');
      if (p.endsWith('lib/src/ffi/dv_whisper_bindings.g.dart') || p.endsWith('lib/src/ffi/library_loader.dart')) continue;
      final src = f.readAsStringSync();
      if (RegExp(r'DynamicLibrary\s*\.\s*(open|process|executable)').hasMatch(src)) offenders.add(p);
      if (RegExp(r"^import\s+'dart:ffi'", multiLine: true).hasMatch(src) && !p.contains('/ffi/')) offenders.add('$p (dart:ffi outside lib/src/ffi)');
    }
    expect(offenders, isEmpty);
    final loader = File('lib/src/ffi/library_loader.dart').readAsStringSync();
    // The placeholder holds no top-level code that could open a library on import.
    expect(RegExp(r'^(final|var|const)\s.*DynamicLibrary', multiLine: true).hasMatch(loader), isFalse);
  });

  test('the public barrel exports the ai.md §4.7 API names', () {
    // Compile-time references: renaming or dropping one breaks this file.
    final names = <Type>[
      WhisperRuntime, WhisperModel, WhisperJob, WhisperModelOptions, WhisperModelInfo, WhisperTranscribeRequest,
      WhisperDetectRequest, WhisperVadOptions, WhisperDecodeOptions, WhisperCancelToken, WhisperJobUpdate,
      WhisperJobStatus, WhisperSegmentsAdded, WhisperLanguageResult, WhisperJobResult, RawSegment, RawWord,
      WhisperErrorKind, WhisperException, WhisperSupport, WhisperSupported, WhisperUnsupported,
      WhisperUnsupportedReason, WhisperDeviceChannel, WhisperDeviceProfile, ThermalLevel,
    ];
    expect(names.toSet(), hasLength(names.length));
  });

  test('request defaults are the ai.md values', () {
    const r = WhisperTranscribeRequest(wavPath: 'x.wav', language: 'en', threads: 2);
    expect(r.chunkTarget, const Duration(seconds: 180));
    expect(r.chunkSearch, const Duration(seconds: 15));
    expect(r.carryPromptWords, 24);
    expect(r.rangeStart, Duration.zero);
    expect(r.rangeEnd, isNull);
    expect(r.decode.noSpeechThreshold, 0.6);
    expect(r.decode.entropyThreshold, 2.4);
    expect(r.decode.logprobThreshold, -1.0);
    expect(r.decode.temperatureInc, 0.2);
    expect(r.decode.suppressNonSpeech, isTrue);
    expect(r.decode.tokenTimestamps, isTrue);
    const v = WhisperVadOptions(modelPath: 'vad.bin');
    expect(v.threshold, 0.5);
    expect(v.minSpeech, const Duration(milliseconds: 250));
    expect(v.minSilence, const Duration(milliseconds: 300));
    expect(v.speechPad, const Duration(milliseconds: 100));
    const o = WhisperModelOptions();
    expect(o.preferGpu, isTrue);
    expect(o.flashAttention, isTrue);
    expect(o.dtwPreset, isNull);
  });

  test('WhisperException carries kind and detail', () {
    expect(const WhisperException(WhisperErrorKind.busy).toString(), 'WhisperException(busy)');
    expect(const WhisperException(WhisperErrorKind.io, 'x').toString(), 'WhisperException(io: x)');
    expect(WhisperErrorKind.values.map((k) => k.name), [
      'libraryUnavailable', 'abiMismatch', 'modelLoadFailed', 'outOfMemory', 'invalidAudio', 'io', 'inference', 'cancelled', 'busy',
      'vadModelMissing', 'noSpeech', 'internal',
    ]);
  });

  test('cancel token', () {
    final t = WhisperCancelToken();
    expect(t.isCancelled, isFalse);
    t.cancel();
    expect(t.isCancelled, isTrue);
  });
}
