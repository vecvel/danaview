// OWNER: AI-08
//
// Typed Auto captions failures (ARCH §16.5, ai.md §8.7). Mapped to copy in danaview_editor's
// `captions_strings.dart` (UX-37). Messages never contain transcript text or paths.

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

import '../catalog/speech_model_catalog.dart';

/// Why a model download failed (ai.md §5.3).
enum ModelDownloadFailureKind {
  /// No connection.
  offline,

  /// Connect or idle timeout.
  timeout,

  /// HTTP 5xx / unexpected status.
  server,

  /// TLS handshake failed.
  secureConnection,

  /// Interrupted (app backgrounded, task expired).
  interrupted,

  /// Not enough free space.
  diskFull,

  /// SHA-256 mismatch (before download via `x-linked-etag`, or after).
  checksumMismatch,

  /// Size mismatch (`x-linked-size`).
  sizeMismatch,

  /// Cancelled by the user.
  cancelled,

  /// The consent does not match the catalog entry.
  consentMismatch,
}

/// A typed Auto captions failure.
@immutable
sealed class TranscriptionFailure implements Exception {
  const TranscriptionFailure();

  /// Whether retrying may help.
  bool get retryable => false;

  /// Stable code for copy lookup and diagnostics.
  String get code;
}

/// The device cannot run Auto captions ([reason]: platform, abi, osVersion, memory, library).
final class UnsupportedDeviceFailure extends TranscriptionFailure {
  /// Creates the failure.
  const UnsupportedDeviceFailure(this.reason);

  /// Reason code.
  final String reason;

  @override
  String get code => 'unsupportedDevice';
}

/// No model installed.
final class ModelMissingFailure extends TranscriptionFailure {
  /// Creates the failure.
  const ModelMissingFailure();

  @override
  String get code => 'modelMissing';
}

/// The model download failed.
final class ModelDownloadFailure extends TranscriptionFailure {
  /// Creates the failure.
  const ModelDownloadFailure(this.kind);

  /// Why.
  final ModelDownloadFailureKind kind;

  @override
  bool get retryable => kind != ModelDownloadFailureKind.consentMismatch && kind != ModelDownloadFailureKind.cancelled;

  @override
  String get code => 'modelDownload.${kind.name}';
}

/// The installed model failed to load ("The speech model is damaged").
final class ModelCorruptFailure extends TranscriptionFailure {
  /// Creates the failure.
  const ModelCorruptFailure();

  @override
  String get code => 'modelCorrupt';
}

/// Not enough memory for the tier; [suggestedTier] may fit.
final class InsufficientMemoryFailure extends TranscriptionFailure {
  /// Creates the failure.
  const InsufficientMemoryFailure({this.suggestedTier});

  /// A smaller tier that fits, if any.
  final SpeechModelTier? suggestedTier;

  @override
  bool get retryable => suggestedTier != null;

  @override
  String get code => 'insufficientMemory';
}

/// Not enough disk for audio extraction or the model.
final class DiskFullFailure extends TranscriptionFailure {
  /// Creates the failure.
  const DiskFullFailure();

  @override
  String get code => 'diskFull';
}

/// A clip's media is offline.
final class MediaOfflineFailure extends TranscriptionFailure {
  /// Creates the failure.
  const MediaOfflineFailure(this.media);

  /// Offline media.
  final MediaId media;

  @override
  String get code => 'mediaOffline';
}

/// Nothing audible in the scope.
final class NoAudioFailure extends TranscriptionFailure {
  /// Creates the failure.
  const NoAudioFailure();

  @override
  String get code => 'noAudio';
}

/// An audio codec the engine cannot decode.
final class UnsupportedAudioFailure extends TranscriptionFailure {
  /// Creates the failure.
  const UnsupportedAudioFailure(this.codec);

  /// Codec name.
  final String codec;

  @override
  String get code => 'unsupportedAudio';
}

/// Audio extraction failed.
final class AudioDecodeFailure extends TranscriptionFailure {
  /// Creates the failure.
  const AudioDecodeFailure();

  @override
  bool get retryable => true;

  @override
  String get code => 'audioDecode';
}

/// No speech was found.
final class NoSpeechFailure extends TranscriptionFailure {
  /// Creates the failure.
  const NoSpeechFailure();

  @override
  String get code => 'noSpeech';
}

/// Inference failed ([detail] has no transcript text).
final class InferenceFailure extends TranscriptionFailure {
  /// Creates the failure.
  const InferenceFailure([this.detail = '']);

  /// Diagnostic detail.
  final String detail;

  @override
  bool get retryable => true;

  @override
  String get code => 'inference';
}

/// Cancelled by the user (not shown as an error).
final class TranscriptionCancelled extends TranscriptionFailure {
  /// Creates the failure.
  const TranscriptionCancelled();

  @override
  String get code => 'cancelled';
}

/// Interrupted; a checkpoint allows "Resume" (7-day expiry).
final class TranscriptionInterrupted extends TranscriptionFailure {
  /// Creates the failure.
  const TranscriptionInterrupted();

  @override
  bool get retryable => true;

  @override
  String get code => 'interrupted';
}
