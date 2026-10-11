// OWNER: INT-04
//
// Placeholder (D-33) created by UX-01. INT-04 replaces this file:
// SpeechAudioExtractor over engine.jobs.extractSpeechAudio (D-28).
// Until then it declares only the public names other files compile against.

import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

/// Extracts speech audio through the engine (D-28).
final class EngineSpeechAudioExtractor implements SpeechAudioExtractor {
  /// Creates the adapter.
  EngineSpeechAudioExtractor(this.engine);

  /// The engine.
  final EditorEngine engine;

  @override
  SpeechAudioExtraction extract(SpeechAudioRequest request) =>
      throw UnimplementedError('EngineSpeechAudioExtractor is implemented by INT-04');
}
