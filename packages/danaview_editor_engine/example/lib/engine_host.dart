// OWNER: ENG-09
//
// Engine bootstrap of the example host: builds a MobileEditorEngine over throwaway roots and asks it
// for its capabilities, which is what the smoke integration test and the example screen show. While
// the native plugin classes are ENG-01's placeholders every call answers `channel-error`, so the
// report says `engine_not_available`; once ENG-07/ENG-08 install the glue it reports the native
// placeholder (supported false) and later the real capabilities.

import 'dart:io';

import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

/// Creates the engine over directories inside the system temp directory (the example has no
/// persistent state; the app root uses the real cache and support roots, ARCH §8.1).
MobileEditorEngine createExampleEngine({Directory? base}) {
  final root = base ?? Directory('${Directory.systemTemp.path}/danaview_engine_example');
  final cache = Directory('${root.path}/cache/danaview/editor')..createSync(recursive: true);
  final support = Directory('${root.path}/support/danaview/editor')..createSync(recursive: true);
  return MobileEditorEngine(config: EditorEngineConfig(cacheRoot: cache.path, supportRoot: support.path));
}

/// What the example screen and the smoke test read back from the engine.
final class EngineReport {
  /// Creates a report.
  const EngineReport({required this.capabilities, this.error});

  /// The loaded capabilities (null when loading failed).
  final EditorCapabilities? capabilities;

  /// The engine failure code when loading failed.
  final String? error;

  /// One line for the screen and the logs (no paths, no user content).
  String get summary {
    final caps = capabilities;
    if (caps == null) return 'engine error: ${error ?? 'unknown'}';
    if (!caps.supported) return 'engine unsupported: ${caps.unsupportedReason ?? 'unknown'}';
    return 'engine supported: tier ${caps.tier.name}, plan versions ${caps.planVersions.join(',')}';
  }
}

/// Loads the capabilities of [engine]; an [EngineFailure] becomes a report with its code.
Future<EngineReport> probeEngine(EditorEngine engine) async {
  try {
    return EngineReport(capabilities: await engine.capabilities());
  } on EngineFailure catch (f) {
    return EngineReport(capabilities: null, error: f.code.name);
  }
}
