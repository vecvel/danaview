// OWNER: INT-101
//
// The 1.2.0 build flags of danaview_features (ARCH v1.2 V2-04, BUILD_PLAN §0.1 rule 5). This is the
// only file of the package that reads them (architecture rule F in
// test/architecture/dependency_rules_test.dart). Every flag is a compile-time `--dart-define`,
// default false and never flipped in code; AIS-41 passes them in release builds, development runs
// with all of them `=true`.
//
// * `DANAVIEW_FILES_HOME`: every Pillar 1 surface (Home tabs, photo grid and viewer, documents,
//   Danaview folders, import, file actions). Off = the 1.1 Home, byte for byte (ARCH v1.2 §1.5).
// * `DANAVIEW_PHOTO_EDITOR`: the Home entry points into Still Photo Mode (Edit photo, Batch edit).
// * `DANAVIEW_BEAUTY`: Home copy that names beauty tools (the beauty UI itself is the editor's).
// * `DANAVIEW_AI_STUDIO`: the "Search with AI" entry and any other AI entry point in the Home.
//
// Surfaces read the effective getters ([FeatureFlags.filesHomeEnabled], …) so widget tests can
// override a flag without a rebuild; the overrides are test-only.

import 'package:flutter/foundation.dart';

/// The 1.2.0 compile-time flags as danaview_features sees them (ARCH v1.2 V2-04).
///
/// See ARCH v1.2 V2-04, §1.5.
abstract final class FeatureFlags {
  /// `DANAVIEW_FILES_HOME`: Files & Media Home (Pillar 1). Default false.
  static const bool filesHome = bool.fromEnvironment('DANAVIEW_FILES_HOME');

  /// `DANAVIEW_PHOTO_EDITOR`: Still Photo Mode entry points. Default false.
  static const bool photoEditor = bool.fromEnvironment('DANAVIEW_PHOTO_EDITOR');

  /// `DANAVIEW_BEAUTY`: the Beauty & Retouching suite. Default false.
  static const bool beauty = bool.fromEnvironment('DANAVIEW_BEAUTY');

  /// `DANAVIEW_AI_STUDIO`: AI Studio and AI search entry points. Default false.
  static const bool aiStudio = bool.fromEnvironment('DANAVIEW_AI_STUDIO');

  /// Test-only override of [filesHome]; null uses the compile-time value.
  @visibleForTesting
  static bool? debugFilesHomeOverride;

  /// Test-only override of [photoEditor]; null uses the compile-time value.
  @visibleForTesting
  static bool? debugPhotoEditorOverride;

  /// Test-only override of [beauty]; null uses the compile-time value.
  @visibleForTesting
  static bool? debugBeautyOverride;

  /// Test-only override of [aiStudio]; null uses the compile-time value.
  @visibleForTesting
  static bool? debugAiStudioOverride;

  /// The effective `DANAVIEW_FILES_HOME` value.
  static bool get filesHomeEnabled => debugFilesHomeOverride ?? filesHome;

  /// The effective `DANAVIEW_PHOTO_EDITOR` value.
  static bool get photoEditorEnabled => debugPhotoEditorOverride ?? photoEditor;

  /// The effective `DANAVIEW_BEAUTY` value.
  static bool get beautyEnabled => debugBeautyOverride ?? beauty;

  /// The effective `DANAVIEW_AI_STUDIO` value.
  static bool get aiStudioEnabled => debugAiStudioOverride ?? aiStudio;

  /// Clears every test override.
  @visibleForTesting
  static void debugReset() {
    debugFilesHomeOverride = null;
    debugPhotoEditorOverride = null;
    debugBeautyOverride = null;
    debugAiStudioOverride = null;
  }
}
