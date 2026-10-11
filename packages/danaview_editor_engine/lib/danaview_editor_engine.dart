// OWNER: ENG-01
//
// iOS + Android implementation of the editor engine contract (ARCH §4.4, §12). Only the app root
// constructs [MobileEditorEngine] (ARCH §4.1); everything else talks to `EditorEngine` from
// danaview_editor_engine_api.

library;

export 'src/error_mapper.dart' show guardEngineCall, mapEngineError;
export 'src/mobile_editor_engine.dart';
