// OWNER: AI-08
//
// Ports implemented outside this package (D-28): danaview_editor adapts them to
// `EditorEngine.jobs.extractSpeechAudio` and `EditorEngine.background` (INT-04 adapters). Named
// differently from the engine API's own types so the adapters import both without clashes.

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

/// A request for 16 kHz s16 mono WAV of one source range (ai.md §7.1).
@immutable
final class SpeechAudioRequest {
  /// Creates a request.
  const SpeechAudioRequest({required this.media, required this.range, required this.outputPath, this.audioStream});

  /// The original media, resolved (proxy audio only when the original is offline).
  final ResolvedMedia media;

  /// Source range (µs); sample 0 corresponds exactly to `range.start`.
  final TimeRange range;

  /// Output under `<support>/danaview/speech/work/<job>/`.
  final String outputPath;

  /// Audio stream, null = first.
  final int? audioStream;
}

/// The extracted WAV.
@immutable
final class SpeechAudioResult {
  /// Creates a result.
  const SpeechAudioResult({required this.path, required this.frames, required this.duration, required this.sourceChannels, required this.sourceSampleRate, required this.codec});

  /// WAV path.
  final String path;

  /// Sample frames.
  final int frames;

  /// Duration.
  final TimeUs duration;

  /// Source channels.
  final int sourceChannels;

  /// Source sample rate.
  final int sourceSampleRate;

  /// Source codec.
  final String codec;
}

/// Why extraction failed.
enum SpeechAudioFailureKind {
  /// Media missing.
  mediaOffline,

  /// Access denied.
  permissionDenied,

  /// No audio track.
  noAudioTrack,

  /// Codec not decodable.
  unsupportedCodec,

  /// Decoding failed.
  decodeFailed,

  /// No space.
  diskFull,

  /// Cancelled.
  cancelled,
}

/// Typed extraction failure (never a raw PlatformException).
@immutable
final class SpeechAudioFailure implements Exception {
  /// Creates a failure.
  const SpeechAudioFailure(this.kind);

  /// Kind.
  final SpeechAudioFailureKind kind;
}

/// A running extraction.
abstract interface class SpeechAudioExtraction {
  /// 0..1, ≤ 10 Hz.
  Stream<double> get progress;

  /// The WAV (throws [SpeechAudioFailure]).
  Future<SpeechAudioResult> get result;

  /// Cancels and deletes the partial output.
  void cancel();
}

/// Decodes source audio to speech WAV (implemented by the engine adapter).
abstract interface class SpeechAudioExtractor {
  /// Starts an extraction.
  SpeechAudioExtraction extract(SpeechAudioRequest request);
}

/// A background-work lease held while transcribing (Android FGS lease; iOS background task).
abstract interface class SpeechBackgroundLease {
  /// Fires when the OS is about to expire the lease (iOS pauses at a chunk boundary).
  Stream<void> get expiring;

  /// Releases the lease.
  Future<void> release();
}

/// Provides background leases (implemented by the engine adapter).
abstract interface class BackgroundLeaseProvider {
  /// Acquires a lease showing [title] and [progress]; null when unavailable.
  Future<SpeechBackgroundLease?> acquire({required String title, required Stream<double> progress});
}
