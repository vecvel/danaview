// OWNER: INT-101
//
// The 1.2.0 build flags of danaview_editor (ARCH v1.2 V2-04, BUILD_PLAN §0.1 rule 5). Every flag is
// a compile-time `--dart-define`, default false and never flipped in code; AIS-41 passes them in
// release builds, development runs with all of them `=true`.
//
// * `DANAVIEW_PHOTO_EDITOR`: Still Photo Mode and its intents (VED-01). Off: the photo intents fall
//   back to "Add to new project" (v1.1 behaviour) and no photo tool, To video or batch edit shows.
// * `DANAVIEW_BEAUTY`: the beauty inspector tab, the Beauty tool of the photo tray and the beauty
//   passes (VED-26). Off: no beauty tab anywhere.
// * `DANAVIEW_FILES_HOME`: read for completeness (the editor's Home bridges, INT-105).
// * `DANAVIEW_AI_STUDIO`: AIS-01 reads it in editor_availability.dart ([aiStudioFlag]); this file
//   re-exposes that value instead of reading the define a second time.
//
// This and editor_availability.dart (DANAVIEW_EDITOR, DANAVIEW_AUTO_CAPTIONS, DANAVIEW_AI_STUDIO) are
// the only files of the package that read build flags (architecture rule F in
// test/architecture/dependency_rules_test.dart). Surfaces read the effective getters so tests can
// override a flag; the overrides are test-only.

import 'package:flutter/foundation.dart';

import 'editor_availability.dart' show EditorFlags, aiStudioFlag;

/// The 1.2.0 compile-time flags of the editor (ARCH v1.2 V2-04).
///
/// See ARCH v1.2 V2-04, §3.
abstract final class EditorFlagsV12 {
  /// `DANAVIEW_PHOTO_EDITOR`: Still Photo Mode. Default false.
  static const bool photoEditor = bool.fromEnvironment('DANAVIEW_PHOTO_EDITOR');

  /// `DANAVIEW_BEAUTY`: the Beauty & Retouching suite. Default false.
  static const bool beauty = bool.fromEnvironment('DANAVIEW_BEAUTY');

  /// `DANAVIEW_FILES_HOME`: the Files & Media Home bridges. Default false.
  static const bool filesHome = bool.fromEnvironment('DANAVIEW_FILES_HOME');

  /// `DANAVIEW_AI_STUDIO` ([aiStudioFlag], read by AIS-01).
  static const bool aiStudio = aiStudioFlag;

  /// Test-only override of [photoEditor]; null uses the compile-time value.
  @visibleForTesting
  static bool? debugPhotoEditorOverride;

  /// Test-only override of [beauty]; null uses the compile-time value.
  @visibleForTesting
  static bool? debugBeautyOverride;

  /// Test-only override of [filesHome]; null uses the compile-time value.
  @visibleForTesting
  static bool? debugFilesHomeOverride;

  /// The effective `DANAVIEW_PHOTO_EDITOR` value.
  static bool get photoEditorEnabled => debugPhotoEditorOverride ?? photoEditor;

  /// The effective `DANAVIEW_BEAUTY` value.
  static bool get beautyEnabled => debugBeautyOverride ?? beauty;

  /// The effective `DANAVIEW_FILES_HOME` value.
  static bool get filesHomeEnabled => debugFilesHomeOverride ?? filesHome;

  /// The effective `DANAVIEW_AI_STUDIO` value ([EditorFlags.aiStudioEnabled]).
  static bool get aiStudioEnabled => EditorFlags.aiStudioEnabled;

  /// Clears the overrides of this class (AI Studio's is [EditorFlags.debugAiStudioOverride]).
  @visibleForTesting
  static void debugReset() {
    debugPhotoEditorOverride = null;
    debugBeautyOverride = null;
    debugFilesHomeOverride = null;
  }
}
