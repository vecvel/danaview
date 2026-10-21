// OWNER: AIS-28
//
// Placeholder (D-33) created by AIS-01. AIS-28 replaces this file:
// the AI Studio service contract (AI_STUDIO_PLAN §3.6): status, plan, run, suggestions, usage,
// glossary. Keep the names `AiStudioService` and `AiStudioOff`: the editor's root provider
// `aiStudioServiceProvider` (AIS-01) defaults to `const AiStudioOff()` and EditorBootstrap (AIS-37)
// overrides it.
// Until then it declares only the public names other files compile against.

import 'package:meta/meta.dart';

/// The AI Studio service of the editor (AI_STUDIO_PLAN §3.6). Members land with AIS-28.
abstract interface class AiStudioService {}

/// The service while AI Studio is off: the build flag `DANAVIEW_AI_STUDIO` is false or the master
/// switch is off (AI_STUDIO_PLAN D-45, D-65). It builds no provider and sends nothing.
@immutable
final class AiStudioOff implements AiStudioService {
  /// Creates the off service.
  const AiStudioOff();

  @override
  bool operator ==(Object other) => other is AiStudioOff;

  @override
  int get hashCode => (AiStudioOff).hashCode;

  @override
  String toString() => 'AiStudioOff()';
}
