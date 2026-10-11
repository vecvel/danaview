// OWNER: AI-06
//
// Keeps the channel names, method names and event types of the Dart side, the Swift plugin and the
// Kotlin plugin in sync (they are plain strings in three languages).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

void main() {
  final swift = File('ios/Classes/DanaviewWhisperPlugin.swift').readAsStringSync();
  final kotlin = File('android/src/main/kotlin/com/vecvel/danaview/whisper/DanaviewWhisperPlugin.kt').readAsStringSync();
  final kotlinMath = File('android/src/main/kotlin/com/vecvel/danaview/whisper/DeviceMath.kt').readAsStringSync();

  const methods = [
    WhisperDeviceMethods.deviceProfile,
    WhisperDeviceMethods.availableMemory,
    WhisperDeviceMethods.freeDiskBytes,
    WhisperDeviceMethods.isNetworkMetered,
    WhisperDeviceMethods.excludeFromBackup,
    WhisperDeviceMethods.beginBackgroundTask,
    WhisperDeviceMethods.endBackgroundTask,
  ];

  test('both native plugins use the Dart channel names', () {
    expect(swift, contains('"$whisperDeviceMethodChannel"'));
    expect(swift, contains('"$whisperDeviceEventChannel"'));
    expect(kotlin, contains('"$whisperDeviceMethodChannel"'));
    expect(kotlin, contains('"$whisperDeviceEventChannel"'));
  });

  test('both native plugins handle every Dart method', () {
    for (final m in methods) {
      expect(swift, contains('case "$m"'), reason: 'Swift is missing $m');
      expect(kotlin, contains('"$m" ->'), reason: 'Kotlin is missing $m');
    }
  });

  test('the event types the Dart side parses are the ones the native side emits', () {
    // Dart parses these types (device_events.dart); iOS emits all five, Android the four that exist there.
    const iosTypes = ['thermal', 'lowPower', 'memoryWarning', 'lifecycle', 'backgroundTaskExpiring'];
    for (final t in iosTypes) {
      expect(swift, contains('"$t"'), reason: 'Swift never emits $t');
    }
    for (final t in ['thermal', 'lowPower', 'memoryWarning', 'lifecycle']) {
      expect(kotlinMath, contains('"$t"'), reason: 'Kotlin never emits $t');
    }
    for (final t in iosTypes) {
      final event = switch (t) {
        'thermal' => {'type': t, 'value': 'nominal'},
        'lowPower' => {'type': t, 'value': true},
        'lifecycle' => {'type': t, 'value': 'background'},
        'backgroundTaskExpiring' => {'type': t, 'value': 1},
        _ => {'type': t},
      };
      expect(WhisperDeviceEvent.tryParse(event), isNotNull, reason: 'Dart cannot parse $t');
    }
  });

  test('profile keys the native sides produce are the ones Dart reads', () {
    const keys = [
      'os', 'osVersion', 'model', 'physicalRam', 'isLowRam', 'perfCores', 'efficiencyCores', 'totalCores', 'is64Bit',
      'cpuFeatures', 'gpuFamily', 'isSimulator', 'lowPowerMode', 'thermal',
    ];
    final profiler = File('ios/Classes/DeviceProfiler.swift').readAsStringSync();
    final androidProfiler = File('android/src/main/kotlin/com/vecvel/danaview/whisper/DeviceProfiler.kt').readAsStringSync();
    final dart = File('lib/src/device/device_profile.dart').readAsStringSync();
    for (final k in keys) {
      expect(profiler, contains('"$k"'), reason: 'iOS profile lacks $k');
      expect(androidProfiler, contains('"$k"'), reason: 'Android profile lacks $k');
      expect(dart, contains("raw['$k']"), reason: 'Dart does not read $k');
    }
  });

  test('thermal names emitted natively are the Dart enum names', () {
    final names = ThermalLevel.values.map((l) => l.name).toSet();
    for (final n in names) {
      expect(swift + File('ios/Classes/DeviceProfiler.swift').readAsStringSync(), contains('"$n"'));
      expect(kotlinMath, contains('"$n"'));
    }
  });
}
