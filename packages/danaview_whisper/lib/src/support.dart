// OWNER: AI-02
//
// Whether on-device speech recognition can run here (ai.md §4.7, ARCH §16.1, D-43(b)). Pure:
// opening the native library is AI-07's runtime; nothing here touches dart:ffi.

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:meta/meta.dart';

import 'device/device_profile.dart';

/// Why speech recognition is unavailable.
enum WhisperUnsupportedReason {
  /// Desktop or web (the editor is iOS/Android only in v1).
  platform,

  /// CPU ABI without a shim (Android armeabi-v7a, D-43(b)).
  abi,

  /// OS too old (below the editor gate).
  osVersion,

  /// The native library is missing or its ABI version does not match.
  libraryUnavailable,
}

/// Support state of the whisper runtime.
@immutable
sealed class WhisperSupport {
  const WhisperSupport();

  /// Lowest iOS major version (the deployment target, D-29).
  static const int minIosMajor = 15;

  /// Lowest Android API level (the editor gate, ARCH §3.2).
  static const int minAndroidApi = 29;

  /// Platform-level support, without loading the library: iOS >= [minIosMajor] and Android
  /// >= [minAndroidApi] on arm64-v8a or x86_64 are candidates; everything else is unsupported.
  /// [abi] is Android's primary ABI, [osMajor] the iOS major version and [apiLevel] the Android
  /// API level, each when known (unknown never rejects).
  static WhisperSupport evaluate({
    TargetPlatform? platform,
    bool isWeb = kIsWeb,
    String? abi,
    int? osMajor,
    int? apiLevel,
  }) {
    if (isWeb) return const WhisperUnsupported(WhisperUnsupportedReason.platform);
    switch (platform ?? defaultTargetPlatform) {
      case TargetPlatform.iOS:
        if (osMajor != null && osMajor < minIosMajor) return const WhisperUnsupported(WhisperUnsupportedReason.osVersion);
        return const WhisperSupported();
      case TargetPlatform.android:
        if (abi != null && abi != 'arm64-v8a' && abi != 'x86_64') {
          return const WhisperUnsupported(WhisperUnsupportedReason.abi);
        }
        if (apiLevel != null && apiLevel > 0 && apiLevel < minAndroidApi) {
          return const WhisperUnsupported(WhisperUnsupportedReason.osVersion);
        }
        return const WhisperSupported();
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return const WhisperUnsupported(WhisperUnsupportedReason.platform);
    }
  }

  /// Support from a native [WhisperDeviceProfile]: a 32-bit process is `abi`, an OS below the
  /// minimum is `osVersion`. A profile that does not name iOS or Android (plugin unavailable)
  /// falls back to [evaluate] with the host platform.
  static WhisperSupport fromProfile(WhisperDeviceProfile profile, {bool isWeb = kIsWeb}) {
    switch (profile.os) {
      case 'ios':
        return evaluate(
          platform: TargetPlatform.iOS,
          isWeb: isWeb,
          osMajor: int.tryParse(profile.osVersion.split('.').first),
        );
      case 'android':
        return evaluate(
          platform: TargetPlatform.android,
          isWeb: isWeb,
          abi: profile.is64Bit ? null : 'armeabi-v7a',
          apiLevel: profile.apiLevel,
        );
    }
    return evaluate(isWeb: isWeb);
  }
}

/// Speech recognition can run (subject to model tiers and RAM gating in danaview_transcription).
final class WhisperSupported extends WhisperSupport {
  /// Creates the state.
  const WhisperSupported();

  @override
  bool operator ==(Object other) => other is WhisperSupported;

  @override
  int get hashCode => (WhisperSupported).hashCode;
}

/// Speech recognition cannot run.
final class WhisperUnsupported extends WhisperSupport {
  /// Creates the state.
  const WhisperUnsupported(this.reason);

  /// Why.
  final WhisperUnsupportedReason reason;

  @override
  bool operator ==(Object other) => other is WhisperUnsupported && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;
}
