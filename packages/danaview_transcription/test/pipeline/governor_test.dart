// OWNER: AI-13
//
// ResourceGovernor policy (ARCH §16.5, ai.md §6): threads = clamp(perf, 2, 4), halved at
// serious (+2 s cooldown), paused at critical until <= serious for 10 s, low power -1; export
// and iOS background pause reasons; memory and disk preflight.

import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pipeline_fakes.dart';

void main() {
  test('thread policy table', () {
    int t(int perf, {ThermalLevel th = ThermalLevel.nominal, bool lp = false}) =>
        ResourceGovernor.threadsFor(perfCores: perf, thermal: th, lowPower: lp);
    expect([t(1), t(2), t(3), t(4), t(6), t(8)], [2, 2, 3, 4, 4, 4]);
    expect([t(4, th: ThermalLevel.fair), t(4, th: ThermalLevel.serious), t(4, th: ThermalLevel.critical), t(2, th: ThermalLevel.serious)], [4, 2, 2, 2]);
    expect([t(4, lp: true), t(3, lp: true), t(2, lp: true), t(4, th: ThermalLevel.serious, lp: true)], [3, 2, 2, 2]);
  });

  group('signals', () {
    late FakeDevice device;
    late FakeExports exports;
    late ManualTimers timers;
    late ResourceGovernor g;
    late int changes;

    Future<void> make(WhisperDeviceProfile profile, {SpeechPlatform? platform}) async {
      device = FakeDevice(profile: profile);
      exports = FakeExports();
      timers = ManualTimers();
      g = ResourceGovernor(device: device, exports: exports, platform: platform, timer: timers.start);
      await g.start();
      changes = 0;
      g.changes.listen((_) => changes++);
    }

    tearDown(() async => g.dispose());

    test('profile drives platform and base threads (unknown perf -> half the cores)', () async {
      await make(iosProfile(perf: 2));
      expect(g.platform, SpeechPlatform.ios);
      expect(g.threads, 2);
      await make(androidProfile(perf: 0));
      expect(g.platform, SpeechPlatform.android);
      expect(g.threads, 4);
      await make(const WhisperDeviceProfile());
      expect(g.platform, SpeechPlatform.other);
      expect(g.threads, 2);
    });

    test('a hot device at start is respected', () async {
      await make(const WhisperDeviceProfile(os: 'android', perfCores: 4, thermal: ThermalLevel.critical, lowPowerMode: true));
      expect(g.pauseReason, PauseReason.thermal);
      expect(g.lowPower, isTrue);
    });

    test('serious: half threads, 2 s cooldown; back to nominal restores', () async {
      await make(androidProfile());
      device.emit(const ThermalChanged(ThermalLevel.serious));
      expect(g.threads, 2);
      expect(g.chunkCooldown, const Duration(seconds: 2));
      expect(g.pauseReason, isNull);
      device.emit(const ThermalChanged(ThermalLevel.nominal));
      expect(g.threads, 4);
      expect(g.chunkCooldown, Duration.zero);
      expect(changes, 2);
    });

    test('critical pauses; recovery needs 10 s at serious or cooler, restarted by a relapse', () async {
      await make(androidProfile());
      device.emit(const ThermalChanged(ThermalLevel.critical));
      expect(g.pauseReason, PauseReason.thermal);
      device.emit(const ThermalChanged(ThermalLevel.serious));
      expect(g.pauseReason, PauseReason.thermal);
      device.emit(const ThermalChanged(ThermalLevel.critical));
      timers.fireAll(); // the cancelled timer does nothing
      expect(g.pauseReason, PauseReason.thermal);
      device.emit(const ThermalChanged(ThermalLevel.fair));
      expect(timers.pending.single.$1, const Duration(seconds: 10));
      timers.fireAll();
      expect(g.pauseReason, isNull);
    });

    test('export and lifecycle reasons; iOS background wins; Android ignores background', () async {
      await make(iosProfile());
      exports.set(true);
      expect(g.pauseReason, PauseReason.exportRunning);
      device.emit(const AppStateChanged(WhisperAppState.background));
      expect(g.pauseReason, PauseReason.background);
      device.emit(const AppStateChanged(WhisperAppState.foreground));
      exports.set(false);
      expect(g.pauseReason, isNull);

      await make(androidProfile());
      device.emit(const AppStateChanged(WhisperAppState.background));
      expect(g.inBackground, isTrue);
      expect(g.pauseReason, isNull);
    });

    test('memory warnings are forwarded; repeated identical events do not notify', () async {
      await make(androidProfile());
      var warnings = 0;
      g.memoryWarnings.listen((_) => warnings++);
      device
        ..emit(const MemoryWarning())
        ..emit(const LowPowerChanged(false))
        ..emit(const ThermalChanged(ThermalLevel.nominal));
      expect(warnings, 1);
      expect(changes, 0);
    });
  });

  group('preflight checks', () {
    test('memory: 1.3 x peak budget; suggests the largest smaller tier that fits', () async {
      final device = FakeDevice(memory: 500 * mib);
      final g = ResourceGovernor(device: device);
      await g.start();
      addTearDown(g.dispose);
      expect(ResourceGovernor.requiredMemory(SpeechModelCatalog.balanced), (300 * mib * 1.3).ceil());
      expect(await g.checkMemory(SpeechModelCatalog.balanced, available: SpeechModelTier.values), isNull);
      final f = await g.checkMemory(SpeechModelCatalog.accurate, available: SpeechModelTier.values);
      expect(f!.suggestedTier, SpeechModelTier.balanced);
      device.memory = 300 * mib;
      expect((await g.checkMemory(SpeechModelCatalog.accurate, available: SpeechModelTier.values))!.suggestedTier, SpeechModelTier.fast);
      device.memory = 100 * mib;
      final none = await g.checkMemory(SpeechModelCatalog.balanced, available: SpeechModelTier.values);
      expect(none!.suggestedTier, isNull);
      expect(none.retryable, isFalse);
      device.memory = null;
      expect(await g.checkMemory(SpeechModelCatalog.accurate, available: SpeechModelTier.values), isNull, reason: 'unknown passes');
    });

    test('disk: unknown passes, known compares', () async {
      final device = FakeDevice();
      final g = ResourceGovernor(device: device);
      expect(await g.hasDisk('/x', 10), isTrue);
      device.freeDisk = 5;
      expect(await g.hasDisk('/x', 10), isFalse);
      device.freeDisk = 10;
      expect(await g.hasDisk('/x', 10), isTrue);
    });
  });
}
