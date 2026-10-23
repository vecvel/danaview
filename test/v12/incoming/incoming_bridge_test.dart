// OWNER: HOM-21
//
// IncomingMediaBridge.interceptor (BUILD_PLAN HOM-21, ARCH v1.2 §5.6, P-7): without an interceptor
// the bridge is unchanged; with one, a value it claims (a photo or document opened with Danaview)
// never reaches the player stream or getInitialMedia, while videos and links still do; a throwing
// interceptor passes the value on.

import 'package:danaview_platform/danaview_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('danaview/media_intent');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    IncomingMediaBridge.interceptor = null;
    IncomingMediaBridge.mockInitialMedia = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> nativeOpens(String media) async {
    final call = const StandardMethodCodec().encodeMethodCall(MethodCall('onOpenMedia', media));
    await messenger.handlePlatformMessage('danaview/media_intent', call, (_) {});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('without an interceptor everything reaches the player as before', () async {
    final events = <String>[];
    final sub = IncomingMediaBridge.onMediaOpened.listen(events.add);
    await nativeOpens('/x/Report.pdf');
    await nativeOpens('/x/Movie.mp4');
    expect(events, ['/x/Report.pdf', '/x/Movie.mp4']);
    IncomingMediaBridge.mockInitialMedia = '/x/Lease.pdf';
    expect(await IncomingMediaBridge.getInitialMedia(), '/x/Lease.pdf');
    await sub.cancel();
  });

  test('claimed values never reach the player; the rest still do', () async {
    final seen = <String>[];
    IncomingMediaBridge.interceptor = (media) async {
      seen.add(media);
      return media.endsWith('.pdf');
    };
    final events = <String>[];
    final sub = IncomingMediaBridge.onMediaOpened.listen(events.add);
    await nativeOpens('/x/Report.pdf');
    await nativeOpens('/x/Movie.mp4');
    IncomingMediaBridge.emitMockMedia('/x/Scan.pdf');
    IncomingMediaBridge.emitMockMedia('danaview://open?url=https://e.com/v.m3u8');
    await Future<void>.delayed(Duration.zero);
    expect(events, ['/x/Movie.mp4', 'danaview://open?url=https://e.com/v.m3u8']);
    expect(seen, ['/x/Report.pdf', '/x/Movie.mp4', '/x/Scan.pdf', 'danaview://open?url=https://e.com/v.m3u8']);

    IncomingMediaBridge.mockInitialMedia = '/x/Lease.pdf';
    expect(await IncomingMediaBridge.getInitialMedia(), isNull, reason: 'a cold-start document is claimed');
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'getInitialMedia' ? '/x/clip.mov' : null);
    expect(await IncomingMediaBridge.getInitialMedia(), '/x/clip.mov', reason: 'a cold-start video still plays at once');
    await sub.cancel();
  });

  test('a throwing interceptor passes the value to the player', () async {
    IncomingMediaBridge.interceptor = (_) async => throw StateError('boom');
    final events = <String>[];
    final sub = IncomingMediaBridge.onMediaOpened.listen(events.add);
    await nativeOpens('/x/Report.pdf');
    expect(events, ['/x/Report.pdf']);
    await sub.cancel();
  });
}
