// OWNER: AI-07
//
// Opens the native whisper shim and adapts its C ABI (src/dv_whisper.h) to the pointer-free
// [DvBindings] the runtime uses (ai.md §4.7). This and the generated bindings are the only runtime
// files that touch dart:ffi. Nothing is opened at import time: [loadWhisperBindings] runs when
// `WhisperRuntime.open()` asks for it.
//
// Library selection:
//  * iOS: the pod is a dynamic framework under `use_frameworks!` (`danaview_whisper.framework`), and
//    falls back to the process image when the pod is linked statically (AI-05).
//  * Android: `libdanaview_whisper.so` is opened first; its `dv_cpu_features()` returns the raw
//    getauxval(AT_HWCAP). With FPHP + ASIMDHP + ASIMDDP the armv8.2 build
//    `libdanaview_whisper_v82.so` is opened instead (falling back to the baseline if it is missing).
//    x86_64 has only the baseline (its `dv_cpu_features()` is 0). armeabi-v7a has no library.
//  * Anything else, or a library without `dv_abi_version`: [DvLibraryUnavailable].
//
// Cost split (see dv_bindings.dart): status reads, flag stores and the JSON copies are leaf calls
// on the calling isolate; `dv_model_release`, `dv_job_start`, `dv_job_free` and `dv_shutdown_all`
// may block (free a context, probe a WAV header, join a thread) and run on a helper isolate that
// re-opens the same library by name.

import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:meta/meta.dart';

import '../runtime/codec.dart' show decodeNativeUtf8;
import '../runtime/dv_bindings.dart';
import 'dv_whisper_bindings.g.dart' as c;

/// iOS framework binary inside the app bundle (use_frameworks!).
const String iosFrameworkLibrary = 'danaview_whisper.framework/danaview_whisper';

/// Android baseline build (armv8-a on arm64-v8a; the only build on x86_64).
const String androidBaselineLibrary = 'libdanaview_whisper.so';

/// Android armv8.2-a+fp16+dotprod build (arm64-v8a only).
const String androidV82Library = 'libdanaview_whisper_v82.so';

/// `HWCAP_FPHP` (arm64 getauxval(AT_HWCAP)).
const int hwcapFphp = 1 << 9;

/// `HWCAP_ASIMDHP`.
const int hwcapAsimdhp = 1 << 10;

/// `HWCAP_ASIMDDP`.
const int hwcapAsimddp = 1 << 20;

/// Whether a HWCAP mask allows the armv8.2 build (fp16 scalar + vector, and dot product).
bool hwcapSupportsV82(int hwcap) {
  const need = hwcapFphp | hwcapAsimdhp | hwcapAsimddp;
  return hwcap & need == need;
}

/// Android variant selection, generic over the library type so tests can drive it with fakes:
/// opens [androidBaselineLibrary] (its failure propagates), reads the HWCAP mask through it and
/// returns the armv8.2 library when supported and openable, else the baseline. [chosen] receives
/// the selected name.
T selectAndroidLibrary<T>({
  required T Function(String name) open,
  required int Function(T library) cpuFeatures,
  void Function(String name)? chosen,
}) {
  final baseline = open(androidBaselineLibrary);
  var hwcap = 0;
  try {
    hwcap = cpuFeatures(baseline);
  } catch (_) {
    hwcap = 0;
  }
  if (hwcapSupportsV82(hwcap)) {
    try {
      final v82 = open(androidV82Library);
      chosen?.call(androidV82Library);
      return v82;
    } catch (_) {
      // Fall through to the baseline.
    }
  }
  chosen?.call(androidBaselineLibrary);
  return baseline;
}

/// How a helper isolate re-opens the selected library.
@immutable
final class DvLibrarySpec {
  /// The process image (statically linked iOS pod).
  const DvLibrarySpec.process() : path = null;

  /// A library opened by name or path.
  const DvLibrarySpec.path(String this.path);

  /// Library name or path; null = the process image.
  final String? path;

  /// Opens the library.
  ffi.DynamicLibrary open() => path == null ? ffi.DynamicLibrary.process() : ffi.DynamicLibrary.open(path!);

  /// Cache key.
  String toKey() => path ?? '<process>';

  @override
  String toString() => path == null ? 'process' : path!.split('/').last;
}

/// Opens the shim for this platform and returns its bindings. [libraryPath] overrides the
/// platform choice (host tests point it at a locally linked shim). Throws [DvLibraryUnavailable].
DvBindings loadWhisperBindings({TargetPlatform? platform, String? libraryPath}) {
  if (libraryPath != null) return FfiDvBindings.open(DvLibrarySpec.path(libraryPath));
  if (kIsWeb) throw const DvLibraryUnavailable('web');
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.iOS:
      try {
        return FfiDvBindings.open(const DvLibrarySpec.path(iosFrameworkLibrary));
      } on DvLibraryUnavailable {
        return FfiDvBindings.open(const DvLibrarySpec.process());
      }
    case TargetPlatform.android:
      return selectAndroidLibrary<FfiDvBindings>(
        open: (name) => FfiDvBindings.open(DvLibrarySpec.path(name)),
        cpuFeatures: (b) => b.cpuFeatures(),
      );
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      throw const DvLibraryUnavailable('platform');
  }
}

typedef _I32V = ffi.Int32 Function();
typedef _I32VD = int Function();
typedef _StrV = ffi.Pointer<ffi.Char> Function();
typedef _U64V = ffi.Uint64 Function();
typedef _VI32 = ffi.Void Function(ffi.Int32);
typedef _VI32D = void Function(int);
typedef _VPtr = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _VPtrD = void Function(ffi.Pointer<ffi.Void>);
typedef _ModelLoad = ffi.Pointer<c.dv_model> Function(ffi.Pointer<ffi.Char>, ffi.Pointer<c.dv_model_params>);
typedef _ModelState = ffi.Int32 Function(ffi.Pointer<c.dv_model>);
typedef _ModelStateD = int Function(ffi.Pointer<c.dv_model>);
typedef _ModelError = ffi.Int32 Function(ffi.Pointer<c.dv_model>, ffi.Pointer<ffi.Char>, ffi.Int32);
typedef _ModelErrorD = int Function(ffi.Pointer<c.dv_model>, ffi.Pointer<ffi.Char>, int);
typedef _ModelInfo = ffi.Int32 Function(ffi.Pointer<c.dv_model>, ffi.Pointer<c.dv_model_info>);
typedef _ModelInfoD = int Function(ffi.Pointer<c.dv_model>, ffi.Pointer<c.dv_model_info>);
typedef _ModelVoid = ffi.Void Function(ffi.Pointer<c.dv_model>);
typedef _ModelVoidD = void Function(ffi.Pointer<c.dv_model>);
typedef _JobStart = ffi.Pointer<c.dv_job> Function(
    ffi.Pointer<c.dv_model>, ffi.Pointer<c.dv_job_params>, ffi.Pointer<ffi.Int32>);
typedef _JobStatus = ffi.Void Function(ffi.Pointer<c.dv_job>, ffi.Pointer<c.dv_job_status>);
typedef _JobStatusD = void Function(ffi.Pointer<c.dv_job>, ffi.Pointer<c.dv_job_status>);
typedef _JobTake = ffi.Pointer<ffi.Char> Function(ffi.Pointer<c.dv_job>, ffi.Int32, ffi.Int32);
typedef _JobTakeD = ffi.Pointer<ffi.Char> Function(ffi.Pointer<c.dv_job>, int, int);
typedef _JobLang = ffi.Pointer<ffi.Char> Function(ffi.Pointer<c.dv_job>, ffi.Int32);
typedef _JobLangD = ffi.Pointer<ffi.Char> Function(ffi.Pointer<c.dv_job>, int);
typedef _JobVoid = ffi.Void Function(ffi.Pointer<c.dv_job>);
typedef _JobVoidD = void Function(ffi.Pointer<c.dv_job>);
typedef _JobI32 = ffi.Void Function(ffi.Pointer<c.dv_job>, ffi.Int32);
typedef _JobI32D = void Function(ffi.Pointer<c.dv_job>, int);

/// [DvBindings] over the real library.
final class FfiDvBindings implements DvBindings {
  FfiDvBindings._(this.spec, ffi.DynamicLibrary lib)
      : _abiVersion = lib.lookupFunction<_I32V, _I32VD>('dv_abi_version', isLeaf: true),
        _engineVersion = lib.lookupFunction<_StrV, _StrV>('dv_engine_version', isLeaf: true),
        _cpuFeatures = lib.lookupFunction<_U64V, _I32VD>('dv_cpu_features', isLeaf: true),
        _setLogLevel = lib.lookupFunction<_VI32, _VI32D>('dv_set_log_level', isLeaf: true),
        _free = lib.lookupFunction<_VPtr, _VPtrD>('dv_free', isLeaf: true),
        _modelLoad = lib.lookupFunction<_ModelLoad, _ModelLoad>('dv_model_load', isLeaf: true),
        _modelState = lib.lookupFunction<_ModelState, _ModelStateD>('dv_model_get_state', isLeaf: true),
        _modelError = lib.lookupFunction<_ModelError, _ModelErrorD>('dv_model_error', isLeaf: true),
        _modelInfo = lib.lookupFunction<_ModelInfo, _ModelInfoD>('dv_model_info_get', isLeaf: true),
        _jobStatus = lib.lookupFunction<_JobStatus, _JobStatusD>('dv_job_status_get', isLeaf: true),
        _jobTake = lib.lookupFunction<_JobTake, _JobTakeD>('dv_job_take_segments_json', isLeaf: true),
        _jobLang = lib.lookupFunction<_JobLang, _JobLangD>('dv_job_language_probs_json', isLeaf: true),
        _jobCancel = lib.lookupFunction<_JobVoid, _JobVoidD>('dv_job_cancel', isLeaf: true),
        _jobPause = lib.lookupFunction<_JobI32, _JobI32D>('dv_job_pause', isLeaf: true),
        _jobResume = lib.lookupFunction<_JobVoid, _JobVoidD>('dv_job_resume', isLeaf: true),
        _jobThreads = lib.lookupFunction<_JobI32, _JobI32D>('dv_job_set_threads', isLeaf: true),
        _status = calloc<c.dv_job_status>();

  /// Opens [spec] and resolves every entry point. Throws [DvLibraryUnavailable] when the library
  /// or any `dv_*` symbol is missing.
  factory FfiDvBindings.open(DvLibrarySpec spec) => _opened[spec.toKey()] ??= _open(spec);

  // One instance per library (each owns a status buffer for its lifetime).
  static final Map<String, FfiDvBindings> _opened = {};

  static FfiDvBindings _open(DvLibrarySpec spec) {
    final ffi.DynamicLibrary lib;
    try {
      lib = spec.open();
    } catch (_) {
      throw DvLibraryUnavailable('cannot open $spec');
    }
    if (!lib.providesSymbol('dv_abi_version')) throw DvLibraryUnavailable('$spec has no dv_abi_version');
    try {
      return FfiDvBindings._(spec, lib);
    } on ArgumentError {
      throw DvLibraryUnavailable('$spec lacks a dv_* entry point');
    }
  }

  /// Which library these bindings use.
  final DvLibrarySpec spec;

  final _I32VD _abiVersion;
  final _StrV _engineVersion;
  final _I32VD _cpuFeatures;
  final _VI32D _setLogLevel;
  final _VPtrD _free;
  final _ModelLoad _modelLoad;
  final _ModelStateD _modelState;
  final _ModelErrorD _modelError;
  final _ModelInfoD _modelInfo;
  final _JobStatusD _jobStatus;
  final _JobTakeD _jobTake;
  final _JobLangD _jobLang;
  final _JobVoidD _jobCancel;
  final _JobI32D _jobPause;
  final _JobVoidD _jobResume;
  final _JobI32D _jobThreads;

  // One status buffer for the life of the bindings: polls run on one isolate and never overlap.
  final ffi.Pointer<c.dv_job_status> _status;

  @override
  int abiVersion() => _abiVersion();

  @override
  String engineVersion() => _string(_engineVersion()) ?? '';

  @override
  int cpuFeatures() => _cpuFeatures();

  @override
  void setLogLevel(int level) => _setLogLevel(level);

  @override
  Future<void> shutdownAll() => Isolate.run(_ShutdownAll(spec).call, debugName: 'dv_shutdown_all');

  @override
  int modelLoad(String path, DvModelParams params) => using((arena) {
        final p = arena<c.dv_model_params>();
        p.ref
          ..struct_size = ffi.sizeOf<c.dv_model_params>()
          ..use_gpu = params.useGpu ? 1 : 0
          ..flash_attn = params.flashAttn ? 1 : 0
          ..dtw_preset = params.dtwPreset;
        return _modelLoad(path.toNativeUtf8(allocator: arena).cast(), p).address;
      });

  @override
  int modelState(int model) => _modelState(ffi.Pointer.fromAddress(model));

  @override
  DvModelErrorData modelError(int model) => using((arena) {
        const len = 256;
        final buf = arena<ffi.Char>(len);
        final status = _modelError(ffi.Pointer.fromAddress(model), buf, len);
        return DvModelErrorData(status, _string(buf) ?? '');
      });

  @override
  DvModelInfoData? modelInfo(int model) => using((arena) {
        final info = arena<c.dv_model_info>();
        info.ref.struct_size = ffi.sizeOf<c.dv_model_info>();
        if (_modelInfo(ffi.Pointer.fromAddress(model), info) != DvStatus.ok) return null;
        final r = info.ref;
        return DvModelInfoData(
          multilingual: r.multilingual != 0,
          nVocab: r.n_vocab,
          modelType: r.model_type,
          ftype: r.ftype,
          gpuUsed: r.gpu_used != 0,
          gpuFallback: r.gpu_fallback != 0,
        );
      });

  @override
  Future<void> modelRelease(int model) =>
      Isolate.run(_ModelRelease(spec, model).call, debugName: 'dv_model_release');

  @override
  Future<DvJobStartResult> jobStart(int model, DvJobParams params) =>
      Isolate.run(_JobStartCall(spec, model, params).call, debugName: 'dv_job_start');

  @override
  DvJobStatusData jobStatus(int job) {
    final s = _status;
    s.ref.struct_size = ffi.sizeOf<c.dv_job_status>();
    _jobStatus(ffi.Pointer.fromAddress(job), s);
    final r = s.ref;
    return DvJobStatusData(
      state: r.state,
      error: r.error,
      phase: r.phase,
      progressPermille: r.progress_permille,
      chunkIndex: r.chunk_index,
      chunkCount: r.chunk_count,
      chunksCompleted: r.chunks_completed,
      segmentsReady: r.segments_ready,
      processedMs: r.processed_ms,
      computeMs: r.compute_ms,
      threads: r.threads,
      language: _language(r.language),
      languageP: r.language_p,
    );
  }

  @override
  String? jobTakeSegmentsJson(int job, int from, int max) => _take(_jobTake(ffi.Pointer.fromAddress(job), from, max));

  @override
  String? jobLanguageJson(int job, int topN) => _take(_jobLang(ffi.Pointer.fromAddress(job), topN));

  @override
  void jobCancel(int job) => _jobCancel(ffi.Pointer.fromAddress(job));

  @override
  void jobPause(int job, {required bool abortCurrentChunk}) =>
      _jobPause(ffi.Pointer.fromAddress(job), abortCurrentChunk ? 1 : 0);

  @override
  void jobResume(int job) => _jobResume(ffi.Pointer.fromAddress(job));

  @override
  void jobSetThreads(int job, int threads) => _jobThreads(ffi.Pointer.fromAddress(job), threads);

  @override
  Future<void> jobFree(int job) => Isolate.run(_JobFree(spec, job).call, debugName: 'dv_job_free');

  /// Copies a `dv_free`-owned string and frees it.
  String? _take(ffi.Pointer<ffi.Char> p) {
    if (p == ffi.nullptr) return null;
    try {
      return _string(p);
    } finally {
      _free(p.cast());
    }
  }

  static String _language(ffi.Array<ffi.Char> a) {
    final codes = <int>[];
    for (var k = 0; k < 8; k++) {
      final ch = a[k];
      if (ch == 0) break;
      codes.add(ch & 0xff);
    }
    return String.fromCharCodes(codes);
  }
}

String? _string(ffi.Pointer<ffi.Char> p) {
  if (p == ffi.nullptr) return null;
  final u = p.cast<Utf8>();
  final n = u.length;
  return decodeNativeUtf8(Uint8List.fromList(p.cast<ffi.Uint8>().asTypedList(n)));
}

// Helper-isolate calls. Each is a small sendable object (a spec plus integers or plain Dart
// values), so Isolate.run copies no closure context from the runtime.

final class _ShutdownAll {
  const _ShutdownAll(this.spec);
  final DvLibrarySpec spec;
  void call() => spec.open().lookupFunction<ffi.Void Function(), void Function()>('dv_shutdown_all')();
}

final class _ModelRelease {
  const _ModelRelease(this.spec, this.model);
  final DvLibrarySpec spec;
  final int model;
  void call() => spec.open().lookupFunction<_ModelVoid, _ModelVoidD>('dv_model_release')(ffi.Pointer.fromAddress(model));
}

final class _JobFree {
  const _JobFree(this.spec, this.job);
  final DvLibrarySpec spec;
  final int job;
  void call() => spec.open().lookupFunction<_JobVoid, _JobVoidD>('dv_job_free')(ffi.Pointer.fromAddress(job));
}

final class _JobStartCall {
  const _JobStartCall(this.spec, this.model, this.params);
  final DvLibrarySpec spec;
  final int model;
  final DvJobParams params;

  DvJobStartResult call() {
    final start = spec.open().lookupFunction<_JobStart, _JobStart>('dv_job_start');
    return using((arena) {
      ffi.Pointer<ffi.Char> str(String? s) => s == null ? ffi.nullptr : s.toNativeUtf8(allocator: arena).cast();
      final p = arena<c.dv_job_params>();
      final q = params;
      p.ref
        ..struct_size = ffi.sizeOf<c.dv_job_params>()
        ..mode = q.mode
        ..wav_path = str(q.wavPath)
        ..range_start_ms = q.rangeStartMs
        ..range_end_ms = q.rangeEndMs
        ..language = str(q.language)
        ..n_threads = q.nThreads
        ..chunk_target_ms = q.chunkTargetMs
        ..chunk_search_ms = q.chunkSearchMs
        ..chunk_min_ms = q.chunkMinMs
        ..vad_enabled = q.vadEnabled ? 1 : 0
        ..vad_model_path = str(q.vadModelPath)
        ..vad_threshold = q.vadThreshold
        ..vad_min_speech_ms = q.vadMinSpeechMs
        ..vad_min_silence_ms = q.vadMinSilenceMs
        ..vad_speech_pad_ms = q.vadSpeechPadMs
        ..vad_samples_overlap_s = q.vadSamplesOverlapS
        ..token_timestamps = q.tokenTimestamps ? 1 : 0
        ..no_speech_thold = q.noSpeechThold
        ..entropy_thold = q.entropyThold
        ..logprob_thold = q.logprobThold
        ..temperature_inc = q.temperatureInc
        ..beam_size = q.beamSize
        ..best_of = q.bestOf
        ..suppress_nst = q.suppressNst ? 1 : 0
        ..carry_prompt_words = q.carryPromptWords
        ..initial_prompt = str(q.initialPrompt)
        ..detect_max_speech_ms = q.detectMaxSpeechMs
        ..detect_search_ms = q.detectSearchMs;
      final status = arena<ffi.Int32>()..value = DvStatus.internal;
      final job = start(ffi.Pointer.fromAddress(model), p, status);
      return DvJobStartResult(job.address, status.value);
    });
  }
}
