// OWNER: INT-04
//
// `SpeechAudioExtractor` (danaview_transcription port, D-28) over the engine's
// `jobs.extractSpeechAudio` (ai.md §7.1, ARCH §16.4 step 4). The request and result map field by
// field (`EngineMedia` is core `ResolvedMedia`, so the media passes through unchanged). Engine
// failures become typed `SpeechAudioFailure`s, never a raw `EngineFailure` or PlatformException:
//
//   mediaOffline -> mediaOffline          permissionDenied -> permissionDenied
//   unsupportedMedia "no audio track" -> noAudioTrack (the engines' detail for a missing stream)
//   unsupportedMedia / decoderInitFailed / notSupportedOnDevice -> unsupportedCodec
//   diskFull -> diskFull                  EngineCancelled -> cancelled
//   anything else (decodeFailed, io, interrupted, internal, ...) -> decodeFailed

import 'dart:async';

import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

/// Extracts speech audio through the engine (D-28).
final class EngineSpeechAudioExtractor implements SpeechAudioExtractor {
  /// Creates the adapter.
  EngineSpeechAudioExtractor(this.engine);

  /// The engine.
  final EditorEngine engine;

  @override
  SpeechAudioExtraction extract(SpeechAudioRequest request) {
    final MediaJob<ExtractedSpeechAudio> job;
    try {
      job = engine.jobs.extractSpeechAudio(SpeechAudioJobRequest(
        media: request.media,
        range: request.range,
        outputPath: request.outputPath,
        audioStream: request.audioStream,
      ));
    } on Object catch (e) {
      return _FailedExtraction(failureOf(e));
    }
    return _EngineExtraction(job);
  }

  /// The typed failure for an engine error (see the file header).
  static SpeechAudioFailure failureOf(Object error) {
    if (error is SpeechAudioFailure) return error;
    if (error is! EngineFailure) return const SpeechAudioFailure(SpeechAudioFailureKind.decodeFailed);
    if (error is EngineCancelled) return const SpeechAudioFailure(SpeechAudioFailureKind.cancelled);
    final kind = switch (error.code) {
      EngineErrorCode.mediaOffline => SpeechAudioFailureKind.mediaOffline,
      EngineErrorCode.permissionDenied => SpeechAudioFailureKind.permissionDenied,
      EngineErrorCode.unsupportedMedia when _mentionsNoAudio(error.debugDetail) => SpeechAudioFailureKind.noAudioTrack,
      EngineErrorCode.unsupportedMedia || EngineErrorCode.decoderInitFailed || EngineErrorCode.notSupportedOnDevice =>
        SpeechAudioFailureKind.unsupportedCodec,
      EngineErrorCode.diskFull => SpeechAudioFailureKind.diskFull,
      EngineErrorCode.cancelled => SpeechAudioFailureKind.cancelled,
      _ => SpeechAudioFailureKind.decodeFailed,
    };
    return SpeechAudioFailure(kind);
  }

  static bool _mentionsNoAudio(String detail) {
    final d = detail.toLowerCase();
    return d.contains('no audio track') || d.contains('noaudiotrack') || d.contains('no audio stream');
  }
}

/// A running engine job seen as a [SpeechAudioExtraction].
final class _EngineExtraction implements SpeechAudioExtraction {
  _EngineExtraction(this._job) {
    result = _job.result.then(_resultOf, onError: (Object e, StackTrace st) => Error.throwWithStackTrace(EngineSpeechAudioExtractor.failureOf(e), st));
    // The pipeline may cancel without awaiting; never leak an unhandled error.
    result.ignore();
  }

  final MediaJob<ExtractedSpeechAudio> _job;

  @override
  late final Future<SpeechAudioResult> result;

  @override
  Stream<double> get progress => _job.progress;

  @override
  void cancel() => _job.cancel();

  static SpeechAudioResult _resultOf(ExtractedSpeechAudio a) => SpeechAudioResult(
        path: a.path,
        frames: a.frames,
        duration: a.duration,
        sourceChannels: a.sourceChannels,
        sourceSampleRate: a.sourceSampleRate,
        codec: a.codec,
      );
}

/// An extraction the engine refused synchronously.
final class _FailedExtraction implements SpeechAudioExtraction {
  _FailedExtraction(SpeechAudioFailure failure) : result = Future<SpeechAudioResult>.error(failure) {
    result.ignore();
  }

  @override
  final Future<SpeechAudioResult> result;

  @override
  Stream<double> get progress => const Stream<double>.empty();

  @override
  void cancel() {}
}
