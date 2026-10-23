// OWNER: HOM-21A
//
// NativeIncoming over a mock binary messenger (BUILD_PLAN HOM-21A): Pigeon batches map to the Dart
// types, takePending and the `incoming` event deliver each batch once (a cold-start batch taken
// after a warm event of the same id is not repeated), acknowledge passes the id, an unregistered
// host API is notSupportedOnDevice, and toString never prints a URI or a name (rule 30).

import 'dart:async';

import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_library_native/src/pigeon/library_api.g.dart';
import 'package:danaview_library_native/src/pigeon/library_channels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _prefix = 'dev.flutter.pigeon.danaview_library_native';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = IncomingHostApi.pigeonChannelCodec;

  void answer(String method, Object? Function(List<Object?> args) reply) {
    messenger.setMockMessageHandler('$_prefix.IncomingHostApi.$method', (message) async {
      final args = (codec.decodeMessage(message) as List<Object?>?) ?? const [];
      final out = reply(args);
      if (out is PlatformException) return codec.encodeMessage(<Object?>[out.code, out.message, out.details]);
      return codec.encodeMessage(<Object?>[out]);
    });
  }

  tearDown(() {
    for (final m in ['takePending', 'acknowledge']) {
      messenger.setMockMessageHandler('$_prefix.IncomingHostApi.$m', null);
    }
  });

  IncomingBatchMsg batch(String id, {IncomingActionMsg action = IncomingActionMsg.sendMultiple}) => IncomingBatchMsg(
        batchId: id,
        action: action,
        items: [
          IncomingItemMsg(uri: 'content://p/doc/1', displayName: 'Report.pdf', mimeType: 'application/pdf', sizeBytes: 1234),
          IncomingItemMsg(uri: 'content://p/img/2', displayName: 'IMG_1.jpg', mimeType: 'image/jpeg'),
          IncomingItemMsg(uri: 'file:///cache/danaview-incoming/x/Shared text.txt'),
        ],
      );

  test('takePending maps every field and each action', () async {
    answer('takePending', (_) => [batch('b1'), batch('b2', action: IncomingActionMsg.view), batch('b3', action: IncomingActionMsg.send)]);
    final incoming = NativeIncoming(events: LibraryEventHub.over(() => const Stream.empty()));
    final got = await incoming.takePending();
    expect(got.map((b) => b.batchId), ['b1', 'b2', 'b3']);
    expect(got.map((b) => b.action), [IncomingAction.sendMultiple, IncomingAction.view, IncomingAction.send]);
    final items = got.first.items;
    expect(items[0].uri, 'content://p/doc/1');
    expect(items[0].displayName, 'Report.pdf');
    expect(items[0].mimeType, 'application/pdf');
    expect(items[0].sizeBytes, 1234);
    expect(items[1].sizeBytes, isNull);
    expect(items[2].displayName, isNull);
    expect(items[2].mimeType, isNull);
    expect(() => items.add(items.first), throwsUnsupportedError);
  });

  test('warm events and pending batches reach batches once each', () async {
    final source = StreamController<LibraryEventMsg>.broadcast();
    addTearDown(source.close);
    final incoming = NativeIncoming(events: LibraryEventHub.over(() => source.stream));
    final seen = <String>[];
    final sub = incoming.batches.listen((b) => seen.add(b.batchId));
    addTearDown(sub.cancel);

    // A warm intent announced by the event; the platform still holds it as pending.
    source.add(LibraryEventMsg(kind: LibraryEventKindMsg.incoming, incoming: batch('warm')));
    // Unrelated events and an empty payload are ignored.
    source.add(LibraryEventMsg(kind: LibraryEventKindMsg.inboxChanged));
    source.add(LibraryEventMsg(kind: LibraryEventKindMsg.incoming));
    await pumpEventQueue();
    expect(seen, ['warm']);

    answer('takePending', (_) => [batch('cold'), batch('warm')]);
    final taken = await incoming.takePending();
    expect(taken.map((b) => b.batchId), ['cold'], reason: 'the warm batch was delivered already');
    await pumpEventQueue();
    expect(seen, ['warm', 'cold']);

    // The same event again (e.g. a replayed stream) is dropped.
    source.add(LibraryEventMsg(kind: LibraryEventKindMsg.incoming, incoming: batch('cold')));
    await pumpEventQueue();
    expect(seen, ['warm', 'cold']);
  });

  test('acknowledge sends the batch id', () async {
    String? acked;
    answer('acknowledge', (args) {
      acked = args.single! as String;
      return null;
    });
    await NativeIncoming(events: LibraryEventHub.over(() => const Stream.empty())).acknowledge('b9');
    expect(acked, 'b9');
  });

  test('errors map to LibraryNativeException; a missing host API is notSupportedOnDevice', () async {
    final incoming = NativeIncoming(events: LibraryEventHub.over(() => const Stream.empty()));
    await expectLater(
      incoming.takePending(),
      throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.notSupportedOnDevice)),
    );
    answer('acknowledge', (_) => PlatformException(code: 'internal', message: 'x'));
    await expectLater(
      incoming.acknowledge('b'),
      throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.internal)),
    );
  });

  test('toString prints no URI or name (rule 30)', () {
    final b = incomingBatchFromMessage(batch('b1'));
    final text = '$b ${b.items.join(' ')}';
    expect(text, isNot(contains('content://')));
    expect(text, isNot(contains('Report')));
    expect(text, isNot(contains('file://')));
    expect(b.toString(), 'IncomingBatch(sendMultiple, 3 item(s))');
  });
}
