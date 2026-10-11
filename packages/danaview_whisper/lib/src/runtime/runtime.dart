// OWNER: AI-07
//
// Public runtime API of ai.md §4.7 (names declared by AI-02's skeleton). `WhisperRuntime.open()`
// decides support and opens the native library through `library_loader.dart` (never at import
// time):
//   1. desktop/web -> unsupported(platform) (skipped when tests inject [DvBindingsFactory]);
//   2. the native device profile, when the plugin answers: 32-bit (armeabi-v7a) -> unsupported(abi),
//      old OS -> unsupported(osVersion);
//   3. the library: missing -> unsupported(libraryUnavailable), `dv_abi_version()` differing from
//      [dvAbiVersion] -> unsupported(libraryUnavailable) with `loadModel` failing `abiMismatch`;
//   4. once per Dart program run (statics reset on hot restart) `dv_shutdown_all()` cancels and
//      joins jobs and frees models left behind by the previous run, off the UI isolate.
// `open()` never throws.

library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../danaview_whisper.dart' show dvAbiVersion;
import '../device/device.dart';
import '../ffi/library_loader.dart' show loadWhisperBindings;
import '../support.dart';
import 'native_runtime.dart';
import 'dv_bindings.dart';
import 'whisper_types.dart';

export 'dv_bindings.dart' show DvBindings, DvBindingsFactory, DvLibraryUnavailable;
export 'whisper_types.dart';

/// The whisper runtime (ai.md §4.7).
abstract interface class WhisperRuntime {
  /// Opens the runtime. Never throws; check [support]. [channel] defaults to the plugin's device
  /// channel and [bindings] to the platform library (tests pass fakes for both).
  static Future<WhisperRuntime> open({WhisperDeviceChannel? channel, DvBindingsFactory? bindings}) async {
    final device = channel ?? WhisperDeviceChannel();
    if (bindings == null) {
      final platform = WhisperSupport.evaluate();
      if (platform is WhisperUnsupported) return UnavailableWhisperRuntime(platform, device);
    }
    try {
      final profile = await device.deviceProfile();
      if (profile.os == 'ios' || profile.os == 'android') {
        final s = WhisperSupport.fromProfile(profile);
        if (s is WhisperUnsupported) return UnavailableWhisperRuntime(s, device);
      }
    } catch (_) {
      // The channel degrades by itself; an unexpected error must not make open() throw.
    }
    const unavailable = WhisperUnsupported(WhisperUnsupportedReason.libraryUnavailable);
    final DvBindings b;
    final int abi;
    try {
      b = await (bindings ?? loadWhisperBindings)();
      abi = b.abiVersion();
    } catch (_) {
      return UnavailableWhisperRuntime(unavailable, device);
    }
    if (abi != dvAbiVersion) {
      return UnavailableWhisperRuntime(
        unavailable,
        device,
        failure: WhisperException(WhisperErrorKind.abiMismatch, 'library ABI $abi, bindings ABI $dvAbiVersion'),
      );
    }
    await (_shutdownOnce ??= _shutdownAll(b));
    return NativeWhisperRuntime(bindings: b, device: device);
  }

  // Set on the first open() of this Dart program run; a hot restart resets it, so the next open()
  // reclaims the native jobs and models of the previous run.
  static Future<void>? _shutdownOnce;

  static Future<void> _shutdownAll(DvBindings b) async {
    try {
      await b.shutdownAll();
    } catch (_) {
      // Nothing to reclaim is the normal case; a failure here must not block the runtime.
    }
  }

  /// Forgets that `dv_shutdown_all()` already ran (tests simulate a hot restart).
  @visibleForTesting
  static void debugResetShutdownLatch() => _shutdownOnce = null;

  /// Support state.
  WhisperSupport get support;

  /// whisper.cpp version of the loaded library ("" when unavailable).
  String get engineVersion;

  /// Device profile and thermal/memory/lifecycle events (ai.md §4.8).
  WhisperDeviceChannel get device;

  /// Starts loading a model; completes when ready. Loading the same path with the same options
  /// again returns another lease on the same native model. [cancel] abandons the result (the
  /// native load finishes, then frees itself). Throws [WhisperException].
  Future<WhisperModel> loadModel(
    String modelPath, {
    WhisperModelOptions options = const WhisperModelOptions(),
    WhisperCancelToken? cancel,
  });

  /// Releases every model no lease or job holds now, instead of after the 60 s grace period
  /// (also done automatically on a memory warning).
  Future<void> releaseIdleModels();
}

/// A loaded model lease. At most one job runs on a model at a time.
abstract interface class WhisperModel {
  /// What the model reports.
  WhisperModelInfo get info;

  /// A job is running.
  bool get isBusy;

  /// Detects the spoken language.
  WhisperJob detectLanguage(WhisperDetectRequest request);

  /// Transcribes in chunks.
  WhisperJob transcribe(WhisperTranscribeRequest request);

  /// Drops this lease; the native model is released 60 s after nothing holds it (immediately on
  /// low memory). Idempotent.
  Future<void> release();
}

/// A native job polled every 250 ms.
abstract interface class WhisperJob {
  /// Broadcast updates; status is throttled to 4 Hz.
  Stream<WhisperJobUpdate> get updates;

  /// Completes with the result; throws [WhisperException] (`cancelled`, `inference`, `oom`, ...).
  Future<WhisperJobResult> get result;

  /// Cancels.
  void cancel();

  /// Pauses at the next chunk boundary, or aborts the running chunk (redone on resume) when
  /// [abortCurrentChunk] is true (iOS background).
  void pause({bool abortCurrentChunk = false});

  /// Resumes.
  void resume();

  /// Changes the thread count (clamped to 1..8), applied at the next chunk.
  set threads(int value);
}

/// The runtime when speech recognition cannot run here.
final class UnavailableWhisperRuntime implements WhisperRuntime {
  /// Creates the runtime; [failure] is what `loadModel` throws (default `libraryUnavailable`).
  const UnavailableWhisperRuntime(this.support, this.device, {WhisperException? failure}) : _failure = failure;

  @override
  final WhisperUnsupported support;

  @override
  final WhisperDeviceChannel device;

  final WhisperException? _failure;

  @override
  String get engineVersion => '';

  @override
  Future<WhisperModel> loadModel(
    String modelPath, {
    WhisperModelOptions options = const WhisperModelOptions(),
    WhisperCancelToken? cancel,
  }) =>
      Future<WhisperModel>.error(_failure ?? const WhisperException(WhisperErrorKind.libraryUnavailable));

  @override
  Future<void> releaseIdleModels() async {}
}
