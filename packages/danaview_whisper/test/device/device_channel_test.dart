// OWNER: AI-06

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('test/whisper_device');
  const events = EventChannel('test/whisper_device/events');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  Object? Function(MethodCall call)? handler;

  setUp(() {
    calls = [];
    handler = null;
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      final h = handler;
      if (h == null) throw MissingPluginException();
      return h(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(events, null);
  });

  WhisperDeviceChannel channel() => WhisperDeviceChannel(method: method, events: events);

  test('channel names are the contract shared with the native plugins', () {
    expect(whisperDeviceMethodChannel, 'danaview_whisper/device');
    expect(whisperDeviceEventChannel, 'danaview_whisper/device/events');
  });

  test('deviceProfile parses the native map', () async {
    handler = (c) => {'os': 'android', 'osVersion': '14', 'physicalRam': 8589934592, 'perfCores': 4, 'totalCores': 8, 'thermal': 'serious'};
    final p = await channel().deviceProfile();
    expect(calls.single.method, 'deviceProfile');
    expect(p.os, 'android');
    expect(p.perfCores, 4);
    expect(p.thermal, ThermalLevel.serious);
  });

  test('every query degrades without the plugin', () async {
    final c = channel(); // handler == null -> MissingPluginException
    expect(await c.deviceProfile(), WhisperDeviceProfile.unknown);
    expect(await c.availableMemory(), isNull);
    expect(await c.freeDiskBytes('/x'), isNull);
    expect(await c.isNetworkMetered(), isFalse);
    expect(await c.excludeFromBackup('/x'), isFalse);
    expect(await c.beginBackgroundTask('dl'), isNull);
    await c.endBackgroundTask(3);
  });

  test('PlatformException and malformed replies degrade to the documented defaults', () async {
    handler = (c) => throw PlatformException(code: 'boom');
    var c = channel();
    expect(await c.deviceProfile(), WhisperDeviceProfile.unknown);
    expect(await c.availableMemory(), isNull);
    expect(await c.excludeFromBackup('/x'), isFalse);
    await c.endBackgroundTask(1);

    handler = (call) => 'garbage';
    c = channel();
    expect(await c.deviceProfile(), WhisperDeviceProfile.unknown);
    expect(await c.availableMemory(), isNull);
    expect(await c.freeDiskBytes('/x'), isNull);
    expect(await c.isNetworkMetered(), isFalse);
    expect(await c.excludeFromBackup('/x'), isFalse);
    expect(await c.beginBackgroundTask('x'), isNull);
  });

  test('numeric replies: positive ints kept, zero and negatives mean unknown', () async {
    final c = channel();
    handler = (call) => 123456789;
    expect(await c.availableMemory(), 123456789);
    expect(await c.freeDiskBytes('/x'), 123456789);
    handler = (call) => 0;
    expect(await c.availableMemory(), isNull);
    handler = (call) => -5;
    expect(await c.freeDiskBytes('/x'), isNull);
    handler = (call) => 9.0;
    expect(await c.availableMemory(), 9);
    handler = (call) => double.infinity;
    expect(await c.availableMemory(), isNull);
  });

  test('arguments are passed as documented', () async {
    handler = (call) => true;
    final c = channel();
    await c.freeDiskBytes('/data/x');
    await c.excludeFromBackup('/data/models');
    await c.beginBackgroundTask('Model download');
    await c.endBackgroundTask(7);
    expect(calls.map((x) => x.method), ['freeDiskBytes', 'excludeFromBackup', 'beginBackgroundTask', 'endBackgroundTask']);
    expect(calls.map((x) => x.arguments), ['/data/x', '/data/models', 'Model download', 7]);
    expect(await c.isNetworkMetered(), isTrue);
    expect(await c.excludeFromBackup('/data/models'), isTrue);
  });

  test('events: parsed, malformed dropped, stream errors swallowed, unsubscribes from native', () async {
    var listening = 0;
    var cancelled = 0;
    messenger.setMockStreamHandler(events, MockStreamHandler.inline(onListen: (arguments, sink) {
      listening++;
      sink.success({'type': 'thermal', 'value': 'critical'});
      sink.success({'type': 'thermal', 'value': 'molten'});
      sink.success('nope');
      sink.error(code: 'x', message: 'y');
      sink.success({'type': 'lowPower', 'value': false});
      sink.success({'type': 'memoryWarning'});
    }, onCancel: (arguments) => cancelled++));

    final got = <WhisperDeviceEvent>[];
    final sub = channel().events.listen(got.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(got, [const ThermalChanged(ThermalLevel.critical), const LowPowerChanged(false), const MemoryWarning()]);
    expect(listening, 1);
    expect(cancelled, 1);
  });

  test('a disabled channel (desktop) never touches the platform and reports defaults', () async {
    final c = WhisperDeviceChannel(enabled: false);
    expect(await c.deviceProfile(), WhisperDeviceProfile.unknown);
    expect(await c.isNetworkMetered(), isFalse);
    expect(await c.events.toList(), isEmpty);
  });

  test('WhisperRuntime.open exposes the device channel', () async {
    final c = WhisperDeviceChannel(enabled: false);
    final rt = await WhisperRuntime.open(channel: c);
    expect(rt.device, same(c));
    await expectLater(
      rt.loadModel('/nope.bin'),
      throwsA(isA<WhisperException>().having((e) => e.kind, 'kind', WhisperErrorKind.libraryUnavailable)),
    );
  });
}
