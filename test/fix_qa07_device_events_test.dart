// OWNER: FIX-QA07
//
// QA-07 D1: the governor built by `createAutoCaptions` keeps receiving the plugin's lifecycle and
// thermal events after the whisper runtime has been opened and listens to the device events too.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview/main.dart';
import 'package:danaview_editor_engine_api/testing.dart' show FakeEditorEngine;
import 'package:danaview_transcription/danaview_transcription.dart' show TranscriptionServiceImpl;
import 'package:danaview_whisper/danaview_whisper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const events = EventChannel(whisperDeviceEventChannel);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  MockStreamHandlerEventSink? sink;
  var listens = 0;

  setUp(() {
    listens = 0;
    sink = null;
    WhisperDeviceChannel.debugResetSharedEvents();
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (arguments, s) {
        listens++;
        sink = s;
      }),
    );
  });

  tearDown(() {
    messenger.setMockStreamHandler(events, null);
    WhisperDeviceChannel.debugResetSharedEvents();
  });

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 10));

  test('the governor still sees background/foreground after the runtime listens to device events', () async {
    final captions = createAutoCaptions(
      engine: FakeEditorEngine(),
      supportDirectory: '/nonexistent/support',
      channel: WhisperDeviceChannel(enabled: true),
    );
    expect(captions.service, isA<TranscriptionServiceImpl>());
    await captions.governor.start();
    await pump();
    expect(listens, 1);

    // What NativeWhisperRuntime does once a job opens it: listen to device events through a channel
    // of its own (WhisperRuntime.open's default) — the second listener of QA-07 D1.
    final runtimeChannel = WhisperDeviceChannel(enabled: true);
    final runtimeSeen = <WhisperDeviceEvent>[];
    final runtimeSub = runtimeChannel.events.listen(runtimeSeen.add);
    await pump();
    expect(listens, 1, reason: 'one native subscription for every listener');

    sink!.success({'type': 'lifecycle', 'value': 'background'});
    await pump();
    expect(captions.governor.inBackground, isTrue);
    expect(runtimeSeen, hasLength(1));

    sink!.success({'type': 'lifecycle', 'value': 'foreground'});
    await pump();
    expect(captions.governor.inBackground, isFalse);

    await runtimeSub.cancel();
    await captions.dispose();
  });

  test('the production service factory opens the runtime over the shared channel', () async {
    final device = WhisperDeviceChannel(enabled: false);
    final captions = createAutoCaptions(engine: FakeEditorEngine(), supportDirectory: '/nonexistent/support', channel: device);
    // On the host the runtime is unavailable (desktop); support() opens it without throwing.
    final support = await captions.service.support();
    expect(support, isNotNull);
    await captions.dispose();
  });
}
