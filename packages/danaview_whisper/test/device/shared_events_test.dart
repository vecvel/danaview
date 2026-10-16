// OWNER: FIX-QA07
//
// QA-07 D1: every WhisperDeviceChannel over the same event channel shares one native
// subscription, so the governor keeps receiving lifecycle/thermal/memory events after the whisper
// runtime (which listens to the device events too) is opened.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const events = EventChannel(whisperDeviceEventChannel);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late int listens;
  late int cancels;
  late MockStreamHandlerEventSink? sink;

  setUp(() {
    listens = 0;
    cancels = 0;
    sink = null;
    WhisperDeviceChannel.debugResetSharedEvents();
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, s) {
          listens++;
          sink = s;
        },
        onCancel: (arguments) => cancels++,
      ),
    );
  });

  tearDown(() {
    messenger.setMockStreamHandler(events, null);
    WhisperDeviceChannel.debugResetSharedEvents();
  });

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 10));

  test('two channel instances share one native subscription and both see every event', () async {
    final governorSide = WhisperDeviceChannel(enabled: true);
    final runtimeSide = WhisperDeviceChannel(enabled: true);
    final a = <WhisperDeviceEvent>[];
    final b = <WhisperDeviceEvent>[];

    final subA = governorSide.events.listen(a.add);
    await pump();
    sink!.success({'type': 'thermal', 'value': 'serious'});
    await pump();

    // The second listener (the runtime's) must not steal the stream from the first.
    final subB = runtimeSide.events.listen(b.add);
    await pump();
    sink!.success({'type': 'memoryWarning'});
    await pump();

    expect(listens, 1, reason: 'the native stream is listened to once');
    expect(a, [const ThermalChanged(ThermalLevel.serious), const MemoryWarning()]);
    expect(b, [const MemoryWarning()]);

    await subB.cancel();
    await pump();
    expect(cancels, 0, reason: 'the governor still listens');
    sink!.success({'type': 'thermal', 'value': 'nominal'});
    await pump();
    expect(a.last, const ThermalChanged(ThermalLevel.nominal));

    await subA.cancel();
    await pump();
    expect(cancels, 1);
  });

  test('opening the whisper runtime with its own default channel keeps events flowing to an earlier listener', () async {
    final governorSide = WhisperDeviceChannel(enabled: true);
    final got = <WhisperDeviceEvent>[];
    final sub = governorSide.events.listen(got.add);
    await pump();

    // As TranscriptionServiceImpl's default openRuntime did: a fresh channel inside open().
    final runtime = await WhisperRuntime.open(
      channel: WhisperDeviceChannel(enabled: true),
      bindings: () async => throw const DvLibraryUnavailable('no library in unit tests'),
    );
    final runtimeEvents = <WhisperDeviceEvent>[];
    final runtimeSub = runtime.device.events.listen(runtimeEvents.add);
    await pump();

    sink!.success({'type': 'lifecycle', 'value': 'background'});
    await pump();

    expect(got, hasLength(1));
    expect(runtimeEvents, hasLength(1));
    expect(listens, 1);
    await runtimeSub.cancel();
    await sub.cancel();
  });
}
