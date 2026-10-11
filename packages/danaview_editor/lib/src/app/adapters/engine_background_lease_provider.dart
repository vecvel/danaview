// OWNER: INT-04
//
// Placeholder (D-33) created by UX-01. INT-04 replaces this file:
// BackgroundLeaseProvider over engine.background (D-28).
// Until then it declares only the public names other files compile against.

import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

/// Background leases for transcription through the engine (D-28).
final class EngineBackgroundLeaseProvider implements BackgroundLeaseProvider {
  /// Creates the adapter.
  EngineBackgroundLeaseProvider(this.engine);

  /// The engine.
  final EditorEngine engine;

  @override
  Future<SpeechBackgroundLease?> acquire({required String title, required Stream<double> progress}) =>
      throw UnimplementedError('EngineBackgroundLeaseProvider is implemented by INT-04');
}
