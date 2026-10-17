// OWNER: AI-06

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

void main() {
  group('WhisperDeviceProfile.fromMap', () {
    test('parses a complete iOS map', () {
      final p = WhisperDeviceProfile.fromMap({
        'os': 'ios',
        'osVersion': '18.2',
        'model': 'iPhone15,2',
        'physicalRam': 6 * 1024 * 1024 * 1024,
        'isLowRam': false,
        'perfCores': 2,
        'efficiencyCores': 4,
        'totalCores': 6,
        'is64Bit': true,
        'cpuFeatures': ['dotprod', 'fp16', 'i8mm'],
        'gpuFamily': 8,
        'isSimulator': false,
        'lowPowerMode': true,
        'thermal': 'fair',
      });
      expect(p.os, 'ios');
      expect(p.physicalRamBytes, 6 * 1024 * 1024 * 1024);
      expect(p.perfCores, 2);
      expect(p.efficiencyCores, 4);
      expect(p.cpuFeatures, {CpuFeature.dotprod, CpuFeature.fp16, CpuFeature.i8mm});
      expect(p.supportsV82, isTrue);
      expect(p.gpuFamily, 8);
      expect(p.lowPowerMode, isTrue);
      expect(p.thermal, ThermalLevel.fair);
      expect(p.metalAllowed, isTrue);
      expect(p, WhisperDeviceProfile.fromMap({
        'os': 'ios',
        'osVersion': '18.2',
        'model': 'iPhone15,2',
        'physicalRam': 6 * 1024 * 1024 * 1024,
        'perfCores': 2,
        'efficiencyCores': 4,
        'totalCores': 6,
        'cpuFeatures': ['i8mm', 'fp16', 'dotprod'],
        'gpuFamily': 8,
        'lowPowerMode': true,
        'thermal': 'fair',
      }));
    });

    test('Metal policy: iOS >= 16.4, Apple GPU family >= 6, not the simulator', () {
      WhisperDeviceProfile ios(String v, int gpu, {bool sim = false}) =>
          WhisperDeviceProfile.fromMap({'os': 'ios', 'osVersion': v, 'gpuFamily': gpu, 'isSimulator': sim});
      expect(ios('16.4', 6).metalAllowed, isTrue);
      expect(ios('16.3.1', 6).metalAllowed, isFalse);
      expect(ios('15.8', 7).metalAllowed, isFalse);
      expect(ios('17.0', 5).metalAllowed, isFalse);
      expect(ios('26.0', 9, sim: true).metalAllowed, isFalse);
      expect(const WhisperDeviceProfile(os: 'android', osVersion: '17', gpuFamily: 9).metalAllowed, isFalse);
    });

    test('derives efficiency cores and falls back to half the cores for the thread policy', () {
      final p = WhisperDeviceProfile.fromMap({'perfCores': 4, 'totalCores': 8});
      expect(p.efficiencyCores, 4);
      expect(WhisperDeviceProfile.fromMap({'totalCores': 8}).effectivePerfCores, 4);
      expect(WhisperDeviceProfile.fromMap({'totalCores': 1}).effectivePerfCores, 1);
      expect(WhisperDeviceProfile.unknown.effectivePerfCores, 1);
      expect(WhisperDeviceProfile.fromMap({'perfCores': 3, 'totalCores': 8}).effectivePerfCores, 3);
    });

    test('malformed input never throws and falls back to conservative defaults', () {
      for (final bad in <Object?>[null, 7, 'x', <Object?>[], true, const <Object?, Object?>{}]) {
        expect(WhisperDeviceProfile.fromMap(bad), WhisperDeviceProfile.unknown, reason: '$bad');
      }
      final p = WhisperDeviceProfile.fromMap({
        'os': 3,
        'osVersion': <Object?>[],
        'model': null,
        'physicalRam': 'lots',
        'isLowRam': 'yes',
        'perfCores': -2,
        'totalCores': double.nan,
        'efficiencyCores': 1.9,
        'is64Bit': 'maybe',
        'cpuFeatures': 'dotprod',
        'gpuFamily': {'a': 1},
        'isSimulator': 1,
        'lowPowerMode': 'true',
        'thermal': 'scorching',
        'apiLevel': 29.0,
      });
      expect(p.os, 'unknown');
      expect(p.osVersion, '');
      expect(p.model, '');
      expect(p.physicalRamBytes, 0);
      expect(p.isLowRam, isFalse);
      expect(p.perfCores, 0);
      expect(p.totalCores, 0);
      expect(p.efficiencyCores, 1);
      expect(p.is64Bit, isTrue);
      expect(p.cpuFeatures, isEmpty);
      expect(p.gpuFamily, 0);
      expect(p.isSimulator, isFalse);
      expect(p.lowPowerMode, isFalse);
      expect(p.thermal, ThermalLevel.nominal);
      expect(p.apiLevel, 29);
    });

    test('unknown or non-string feature entries are skipped, known ones kept', () {
      final p = WhisperDeviceProfile.fromMap({
        'cpuFeatures': ['dotprod', 7, null, 'sve2', 'bf16', 'dotprod'],
      });
      expect(p.cpuFeatures, {CpuFeature.dotprod, CpuFeature.bf16});
      expect(p.supportsV82, isFalse);
      expect(() => p.cpuFeatures.add(CpuFeature.fp16), throwsUnsupportedError);
    });

    test('keys of any map type are accepted (platform channels deliver Map<Object?, Object?>)', () {
      final Map<Object?, Object?> m = {'os': 'android', 'osVersion': '14', 'physicalRam': 4096};
      expect(WhisperDeviceProfile.fromMap(m).os, 'android');
    });
  });

  group('ThermalLevel', () {
    test('parses only the four native names', () {
      expect(ThermalLevel.tryParse('nominal'), ThermalLevel.nominal);
      expect(ThermalLevel.tryParse('critical'), ThermalLevel.critical);
      expect(ThermalLevel.tryParse('Critical'), isNull);
      expect(ThermalLevel.tryParse(2), isNull);
      expect(ThermalLevel.tryParse(null), isNull);
    });

    test('isHot from serious up', () {
      expect(ThermalLevel.values.where((l) => l.isHot), [ThermalLevel.serious, ThermalLevel.critical]);
    });
  });

  group('WhisperDeviceEvent.tryParse', () {
    test('parses every documented event', () {
      expect(WhisperDeviceEvent.tryParse({'type': 'thermal', 'value': 'serious'}), const ThermalChanged(ThermalLevel.serious));
      expect(WhisperDeviceEvent.tryParse({'type': 'memoryWarning'}), const MemoryWarning());
      expect(WhisperDeviceEvent.tryParse({'type': 'lowPower', 'value': true}), const LowPowerChanged(true));
      expect(WhisperDeviceEvent.tryParse({'type': 'lifecycle', 'value': 'background'}), const AppStateChanged(WhisperAppState.background));
      expect(WhisperDeviceEvent.tryParse({'type': 'lifecycle', 'value': 'foreground'}), const AppStateChanged(WhisperAppState.foreground));
      expect(WhisperDeviceEvent.tryParse({'type': 'backgroundTaskExpiring', 'value': 12}), const BackgroundTaskExpiring(12));
    });

    test('drops malformed or unknown events', () {
      final bad = <Object?>[
        null,
        'thermal',
        42,
        <Object?>[],
        <Object?, Object?>{},
        {'type': 7},
        {'type': 'thermal'},
        {'type': 'thermal', 'value': 'lava'},
        {'type': 'thermal', 'value': 3},
        {'type': 'lowPower', 'value': 'true'},
        {'type': 'lowPower'},
        {'type': 'lifecycle', 'value': 'inactive'},
        {'type': 'backgroundTaskExpiring', 'value': 0},
        {'type': 'backgroundTaskExpiring', 'value': -4},
        {'type': 'backgroundTaskExpiring', 'value': '3'},
        {'type': 'newFutureEvent', 'value': 1},
      ];
      for (final b in bad) {
        expect(WhisperDeviceEvent.tryParse(b), isNull, reason: '$b');
      }
    });
  });
}
