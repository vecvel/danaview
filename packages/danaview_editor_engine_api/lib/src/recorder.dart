// OWNER: API-01
//
// Voice recording (ARCH §12.4, §15, D-25): WAV PCM s16 48 kHz mono in the project bundle.

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

/// Microphone permission state.
///
/// See ARCH §12.4, §15.
enum MicPermission {
  /// Not asked yet.
  undetermined,

  /// Granted.
  granted,

  /// Denied (can ask again on Android).
  denied,

  /// Denied permanently; only system settings can change it.
  permanentlyDenied,
}

/// Why a recording stopped by itself (the file is kept).
///
/// See ARCH §12.4, §15.
enum RecordingInterruption {
  /// Audio session interruption (call, Siri, focus loss).
  interrupted,

  /// Audio route changed (headset unplugged).
  routeChanged,

  /// Input device removed.
  deviceRemoved,
}

/// A finished recording.
///
/// See ARCH §12.4, §15.
@immutable
final class RecordedAsset {
  /// Creates the result.
  const RecordedAsset({required this.path, required this.durationUs, required this.startLatencyUs});

  /// WAV path (under `projects/<id>/assets/recordings/`).
  final String path;

  /// Duration.
  final TimeUs durationUs;

  /// Measured input latency; the clip is placed at playhead + latency.
  final TimeUs startLatencyUs;
}

/// A recording in progress.
///
/// See ARCH §12.4, §15.
abstract interface class RecordingSession {
  /// Input level 0..1 at 20 Hz.
  Stream<double> get levels;

  /// Interruptions (the session stops and keeps the file).
  Stream<RecordingInterruption> get interruptions;

  /// Stops and finalizes the WAV.
  Future<RecordedAsset> stop();

  /// Stops and deletes the partial file.
  Future<void> cancel();
}

/// Microphone recorder (`EditorEngine.voiceRecorder` is null when unsupported).
///
/// See ARCH §12.4, §15.
abstract interface class VoiceRecorder {
  /// Current permission.
  Future<MicPermission> permission();

  /// Asks the user.
  Future<MicPermission> requestPermission();

  /// Opens the app's system settings page.
  Future<void> openSystemSettings();

  /// Starts recording into [outputPath].
  Future<RecordingSession> start({required String outputPath});
}
