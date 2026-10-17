<!-- Scaffold stub; owners: ENG-01 (Dart), ENG-07 (iOS), ENG-08 (Android), ENG-09 (example + CI). -->
# danaview_editor_engine

Flutter plugin (iOS + Android) implementing `danaview_editor_engine_api` (ARCH §4.4, §12–§15):
AVFoundation + Core Image/Metal on iOS, AndroidX Media3 on Android, hardware H.264/H.265, no
FFmpeg. Desktop is not declared; a later `danaview_editor_engine_desktop` implements the same API.

State (ENG-01): the Pigeon surface lives in `pigeons/engine_api.dart` (pigeon ^29.0.0, callback-style
`@asyncCallback` host methods); the generated Dart (`lib/src/pigeon/engine_api.g.dart`), Swift
(`ios/Classes/Pigeon/EngineApi.g.swift`) and Kotlin (`android/.../engine/pigeon/EngineApi.g.kt`) files are
committed, and `test/glue/pigeon_regeneration_test.dart` fails when they drift. Regenerate from this
directory with `dart run pigeon --input pigeons/engine_api.dart`.

`MobileEditorEngine` implements the engine root over the Pigeon host APIs; `EngineEventRouter`
demultiplexes the single event stream by session/job id with the ARCH §12.6 rate limits;
`error_mapper.dart` turns every channel error into an `EngineFailure`. The mobile_* services are D-33
placeholders until ENG-02 (preview), ENG-03 (jobs, recorder, platform services, media access) and
ENG-04 (export). The native plugin classes are minimal placeholders that register no host API, so every
call answers `channel-error` → `notSupportedOnDevice` and `capabilities()` reports
`engine_not_available` until ENG-07/ENG-08 install the glue; ENG-09 adds the example host and CI scripts;
ENG-06 freezes the surface after the IOS-01/AND-01 spikes (D-42).
