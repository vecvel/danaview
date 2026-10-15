// OWNER: QA-00
//
// Run configuration of the shared on-device E2E suite (BUILD_PLAN QA-00, ARCH §21.2). Everything a
// run needs from the host comes in through `--dart-define`s, so the same files run on the iOS
// Simulator (QA-01) and the Android Emulator (QA-02):
//
//   DANAVIEW_EDITOR=true            the editor itself (D-31; without it the suite fails at boot)
//   DANAVIEW_AUTO_CAPTIONS=true     Auto captions (scenario 8)
//   DV_E2E_FIXTURES=<dir>           ENG-05 media (packages/danaview_editor_engine/test_fixtures/media).
//                                   iOS Simulator: the host path itself (the simulator shares the
//                                   Mac file system). Android: defaults to the app's external files
//                                   folder, where `tool/e2e_host.sh stage` pushes them.
//   DV_E2E_MODELS=<dir>             folder holding ggml-tiny-q5_1.bin and ggml-silero-v6.2.0.bin
//                                   (scenario 8; installed through ModelStore.installFromFile, no
//                                   network). Same defaults as the fixtures (`.../e2e_models`).
//   DV_E2E_PHASE=<name>             the phase of a multi-phase scenario (kill / relaunch).
//   DV_E2E_HOST=true                a host driver (`tool/e2e_host.sh`) serves the handshake; without
//                                   it the steps that need the host are skipped with a reason.
//
// Nothing in the suite downloads anything.

import 'dart:io';

/// The suite's run configuration (see the file header).
abstract final class E2eConfig {
  /// The app id on both platforms.
  static const String appId = 'com.vecvel.danaview';

  static const String _fixtures = String.fromEnvironment('DV_E2E_FIXTURES');
  static const String _models = String.fromEnvironment('DV_E2E_MODELS');

  /// The phase of a multi-phase scenario ('' for a single-phase one).
  static const String phase = String.fromEnvironment('DV_E2E_PHASE');

  /// Whether a host driver serves the file handshake.
  static const bool hostDriver = bool.fromEnvironment('DV_E2E_HOST');

  /// Whether the build has the editor flag on.
  static const bool editorFlag = bool.fromEnvironment('DANAVIEW_EDITOR');

  /// Whether the build has Auto captions on.
  static const bool autoCaptionsFlag = bool.fromEnvironment('DANAVIEW_AUTO_CAPTIONS');

  /// A folder the app owns and the host can reach without root: the external files folder on
  /// Android (`adb push` / `adb pull`), the data container's `Documents` on iOS (`xcrun simctl
  /// get_app_container <udid> com.vecvel.danaview data`).
  static String get hostSharedDir {
    if (Platform.isAndroid) return '/storage/emulated/0/Android/data/$appId/files';
    // iOS: Directory.systemTemp is <container>/tmp.
    return '${Directory.systemTemp.parent.path}/Documents';
  }

  /// Where the ENG-05 fixtures are read from.
  static String get fixturesDir => _fixtures.isNotEmpty ? _fixtures : '$hostSharedDir/e2e_fixtures';

  /// Where the speech model files are read from.
  static String get modelsDir => _models.isNotEmpty ? _models : '$hostSharedDir/e2e_models';

  /// The handshake folder (see `e2e_handshake.dart`).
  static String get handshakeDir => '$hostSharedDir/e2e_handshake';

  /// Where scenarios keep state across phases and copies of exported files for the host to collect.
  static String get outDir => '$hostSharedDir/e2e_out';
}
