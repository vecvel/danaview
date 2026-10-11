// OWNER: AI-02

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

void main() {
  test('platform support matrix', () {
    expect(WhisperSupport.evaluate(platform: TargetPlatform.iOS, isWeb: false), const WhisperSupported());
    expect(WhisperSupport.evaluate(platform: TargetPlatform.android, isWeb: false, abi: 'arm64-v8a'), const WhisperSupported());
    expect(WhisperSupport.evaluate(platform: TargetPlatform.android, isWeb: false, abi: 'armeabi-v7a'),
        const WhisperUnsupported(WhisperUnsupportedReason.abi));
    for (final p in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
      expect(WhisperSupport.evaluate(platform: p, isWeb: false), const WhisperUnsupported(WhisperUnsupportedReason.platform));
    }
  });

  test('OS minimums: iOS 15, Android API 29; unknown versions never reject', () {
    WhisperSupport ios(int? major) => WhisperSupport.evaluate(platform: TargetPlatform.iOS, isWeb: false, osMajor: major);
    WhisperSupport android(int? api, {String? abi}) =>
        WhisperSupport.evaluate(platform: TargetPlatform.android, isWeb: false, apiLevel: api, abi: abi);
    expect(ios(14), const WhisperUnsupported(WhisperUnsupportedReason.osVersion));
    expect(ios(15), const WhisperSupported());
    expect(ios(null), const WhisperSupported());
    expect(android(28), const WhisperUnsupported(WhisperUnsupportedReason.osVersion));
    expect(android(29), const WhisperSupported());
    expect(android(0), const WhisperSupported());
    expect(android(null), const WhisperSupported());
    expect(android(35, abi: 'x86_64'), const WhisperSupported());
    expect(android(35, abi: 'x86'), const WhisperUnsupported(WhisperUnsupportedReason.abi));
    expect(android(28, abi: 'armeabi-v7a'), const WhisperUnsupported(WhisperUnsupportedReason.abi), reason: 'ABI is reported first');
    expect(WhisperSupport.evaluate(isWeb: true), const WhisperUnsupported(WhisperUnsupportedReason.platform));
  });

  test('support from a native device profile', () {
    WhisperSupport from(Map<String, Object?> m) => WhisperSupport.fromProfile(WhisperDeviceProfile.fromMap(m), isWeb: false);
    expect(from({'os': 'ios', 'osVersion': '18.2'}), const WhisperSupported());
    expect(from({'os': 'ios', 'osVersion': '14.8'}), const WhisperUnsupported(WhisperUnsupportedReason.osVersion));
    expect(from({'os': 'ios', 'osVersion': 'weird'}), const WhisperSupported());
    expect(from({'os': 'android', 'apiLevel': 34, 'is64Bit': true}), const WhisperSupported());
    expect(from({'os': 'android', 'apiLevel': 34, 'is64Bit': false}), const WhisperUnsupported(WhisperUnsupportedReason.abi));
    expect(from({'os': 'android', 'apiLevel': 27, 'is64Bit': true}), const WhisperUnsupported(WhisperUnsupportedReason.osVersion));
    // No plugin answer: the host platform decides.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(from({}), const WhisperUnsupported(WhisperUnsupportedReason.platform));
  });

  test('WhisperRuntime.open() reports unsupported(platform) on macOS, Windows and Linux (AI-02 acceptance)', () async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final p in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = p;
      final rt = await WhisperRuntime.open();
      expect(rt.support, const WhisperUnsupported(WhisperUnsupportedReason.platform), reason: '$p');
      expect(rt.engineVersion, '');
      expect(await rt.device.deviceProfile(), WhisperDeviceProfile.unknown);
      expect(await rt.device.events.toList(), isEmpty);
    }
  });

  test('on iOS and Android the runtime reports libraryUnavailable until AI-07 loads the library', () async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final p in [TargetPlatform.iOS, TargetPlatform.android]) {
      debugDefaultTargetPlatformOverride = p;
      final rt = await WhisperRuntime.open(channel: WhisperDeviceChannel(enabled: false));
      expect(rt.support, const WhisperUnsupported(WhisperUnsupportedReason.libraryUnavailable), reason: '$p');
    }
  });

  test('runtime opens without a native library and never throws', () async {
    final rt = await WhisperRuntime.open();
    expect(rt.support, isA<WhisperUnsupported>());
  });

  test('C header and Dart agree on the ABI version', () {
    final header = File('src/dv_whisper.h').readAsStringSync();
    expect(RegExp(r'#define DV_ABI_VERSION (\d+)').firstMatch(header)!.group(1), '$dvAbiVersion');
  });
}
