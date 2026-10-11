// OWNER: AI-07
//
// WhisperRuntime.open() and the library loader: variant selection from HWCAP masks, support
// decisions (desktop, armeabi-v7a, old OS, missing library, ABI mismatch) and the once-per-run
// dv_shutdown_all (hot restart hygiene).

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_whisper/src/ffi/library_loader.dart';
import 'package:danaview_whisper/src/runtime/native_runtime.dart';
import 'package:danaview_whisper/src/runtime/dv_bindings.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

import 'fake_dv_bindings.dart';

WhisperDeviceChannel _channelWithProfile(Map<String, Object?> profile) {
  const method = MethodChannel('test/whisper/open');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    method,
    (call) async => call.method == 'deviceProfile' ? profile : null,
  );
  return WhisperDeviceChannel(method: method, events: const EventChannel('test/whisper/open/events'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(WhisperRuntime.debugResetShutdownLatch);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('Android variant selection', () {
    const all = hwcapFphp | hwcapAsimdhp | hwcapAsimddp;

    test('HWCAP masks', () {
      expect(hwcapSupportsV82(all), isTrue);
      expect(hwcapSupportsV82(all | 0xff), isTrue);
      expect(hwcapSupportsV82(hwcapFphp | hwcapAsimdhp), isFalse, reason: 'no dot product');
      expect(hwcapSupportsV82(hwcapAsimddp), isFalse, reason: 'no fp16');
      expect(hwcapSupportsV82(hwcapFphp | hwcapAsimddp), isFalse, reason: 'no vector fp16');
      expect(hwcapSupportsV82(0), isFalse);
    });

    String select(int hwcap, {Set<String> present = const {androidBaselineLibrary, androidV82Library}}) {
      final opened = <String>[];
      String? chosen;
      final lib = selectAndroidLibrary<String>(
        open: (name) {
          opened.add(name);
          if (!present.contains(name)) throw ArgumentError('missing $name');
          return name;
        },
        cpuFeatures: (lib) => lib == androidBaselineLibrary ? hwcap : -1,
        chosen: (n) => chosen = n,
      );
      expect(chosen, lib);
      expect(opened.first, androidBaselineLibrary, reason: 'the baseline reads HWCAP');
      return lib;
    }

    test('armv8.2 with fp16 + dotprod picks libdanaview_whisper_v82.so', () {
      expect(select(all), androidV82Library);
    });

    test('older cores and x86_64 (HWCAP 0) keep the baseline', () {
      expect(select(hwcapFphp | hwcapAsimdhp), androidBaselineLibrary);
      expect(select(0), androidBaselineLibrary);
    });

    test('a missing v82 library falls back to the baseline', () {
      expect(select(all, present: {androidBaselineLibrary}), androidBaselineLibrary);
    });

    test('a missing baseline (armeabi-v7a, broken APK) fails', () {
      expect(() => select(all, present: const {}), throwsArgumentError);
    });

    test('a throwing cpu probe keeps the baseline', () {
      final lib = selectAndroidLibrary<String>(open: (n) => n, cpuFeatures: (_) => throw StateError('x'));
      expect(lib, androidBaselineLibrary);
    });
  });

  group('loadWhisperBindings on the host', () {
    test('desktop platforms have no library', () {
      for (final p in [TargetPlatform.macOS, TargetPlatform.linux, TargetPlatform.windows]) {
        expect(() => loadWhisperBindings(platform: p), throwsA(isA<DvLibraryUnavailable>()));
      }
    });

    test('iOS without the framework falls back to the process image, which lacks dv_*', () {
      expect(() => loadWhisperBindings(platform: TargetPlatform.iOS), throwsA(isA<DvLibraryUnavailable>()));
    });

    test('Android without libdanaview_whisper.so is unavailable', () {
      expect(() => loadWhisperBindings(platform: TargetPlatform.android), throwsA(isA<DvLibraryUnavailable>()));
    });

    test('a path without the shim is unavailable, never a crash', () {
      expect(() => loadWhisperBindings(libraryPath: '/nonexistent/libdanaview_whisper.dylib'),
          throwsA(isA<DvLibraryUnavailable>()));
    });
  });

  group('WhisperRuntime.open', () {
    test('desktop reports unsupported(platform) without touching the library', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final rt = await WhisperRuntime.open(channel: WhisperDeviceChannel(enabled: false));
      expect(rt.support, const WhisperUnsupported(WhisperUnsupportedReason.platform));
    });

    test('fake bindings: supported, engine version, shutdown_all on the first open only', () async {
      final fake = FakeDvBindings();
      final rt = await WhisperRuntime.open(channel: WhisperDeviceChannel(enabled: false), bindings: () => fake);
      expect(rt.support, const WhisperSupported());
      expect(rt.engineVersion, '1.9.4');
      expect(rt, isA<NativeWhisperRuntime>());
      expect(fake.shutdownCalls, 1);
      await WhisperRuntime.open(channel: WhisperDeviceChannel(enabled: false), bindings: () => fake);
      expect(fake.shutdownCalls, 1, reason: 'a second runtime in the same run must not kill the first one\'s jobs');

      // Hot restart: Dart statics reset, so the next open reclaims the previous run's native work.
      fake.jobs[1] = FakeJob(0, const DvJobParams(mode: 0, wavPath: 'w'));
      WhisperRuntime.debugResetShutdownLatch();
      await WhisperRuntime.open(channel: WhisperDeviceChannel(enabled: false), bindings: () => fake);
      expect(fake.shutdownCalls, 2);
      expect(fake.jobs[1]!.state, DvJobState.cancelled, reason: 'orphan job cancelled and joined');
    });

    test('a library that cannot be opened reports libraryUnavailable', () async {
      final rt = await WhisperRuntime.open(
        channel: WhisperDeviceChannel(enabled: false),
        bindings: () => throw const DvLibraryUnavailable('cannot open libdanaview_whisper.so'),
      );
      expect(rt.support, const WhisperUnsupported(WhisperUnsupportedReason.libraryUnavailable));
      await expectLater(rt.loadModel('/m.bin'),
          throwsA(isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.libraryUnavailable)));
    });

    test('an ABI mismatch reports libraryUnavailable and loadModel fails with abiMismatch', () async {
      final fake = FakeDvBindings()..abi = 2;
      final rt = await WhisperRuntime.open(channel: WhisperDeviceChannel(enabled: false), bindings: () => fake);
      expect(rt.support, const WhisperUnsupported(WhisperUnsupportedReason.libraryUnavailable));
      expect(rt.engineVersion, '');
      await expectLater(rt.loadModel('/m.bin'),
          throwsA(isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.abiMismatch)));
      expect(fake.shutdownCalls, 0, reason: 'never call into a mismatched library');
      expect(fake.models, isEmpty);
    });

    test('armeabi-v7a and old OS versions are rejected from the device profile', () async {
      final fake = FakeDvBindings();
      final v7 = await WhisperRuntime.open(
        channel: _channelWithProfile({'os': 'android', 'apiLevel': 33, 'is64Bit': false}),
        bindings: () => fake,
      );
      expect(v7.support, const WhisperUnsupported(WhisperUnsupportedReason.abi));
      final oldAndroid = await WhisperRuntime.open(
        channel: _channelWithProfile({'os': 'android', 'apiLevel': 28, 'is64Bit': true}),
        bindings: () => fake,
      );
      expect(oldAndroid.support, const WhisperUnsupported(WhisperUnsupportedReason.osVersion));
      final oldIos = await WhisperRuntime.open(
        channel: _channelWithProfile({'os': 'ios', 'osVersion': '14.8'}),
        bindings: () => fake,
      );
      expect(oldIos.support, const WhisperUnsupported(WhisperUnsupportedReason.osVersion));
      expect(fake.shutdownCalls, 0);
      final ok = await WhisperRuntime.open(
        channel: _channelWithProfile({'os': 'android', 'apiLevel': 35, 'is64Bit': true}),
        bindings: () => fake,
      );
      expect(ok.support, const WhisperSupported());
    });

    test('async factories and a throwing abi probe are handled', () async {
      final rt = await WhisperRuntime.open(
        channel: WhisperDeviceChannel(enabled: false),
        bindings: () async => _ThrowingAbi(),
      );
      expect(rt.support, const WhisperUnsupported(WhisperUnsupportedReason.libraryUnavailable));
    });
  });
}

final class _ThrowingAbi extends FakeDvBindings {
  @override
  int abiVersion() => throw ArgumentError('symbol');
}
