// OWNER: ENG-03
//
// MobileThumbnailSource over mocked channels (ARCH §12.3, §15): <= 8 tiles in flight, priority
// order of the queue, request ids, cancel of queued and dispatched requests (incl. the race with
// a late native reply), typed failures.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor_engine/src/mobile_jobs.dart';
import 'package:vwish_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:vwish_editor_engine/src/pigeon/engine_channels.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import 'support/services_harness.dart';

ThumbnailRequest _req(int tile, {bool proxy = false}) =>
    ThumbnailRequest(media: servicesMedia, intervalMs: 500, tileIndex: tile, heightPx: 48, proxy: proxy);

ThumbnailTileMsg _tile(int frames) => ThumbnailTileMsg(encoded: Uint8List.fromList([0xFF, 0xD8, frames]), frames: frames, frameWidthPx: 85);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServicesHarness h;
  late MobileThumbnailSource source;
  late Map<String, Completer<ThumbnailTileMsg>> pending;
  late List<String> order;

  setUp(() {
    h = ServicesHarness();
    source = MobileThumbnailSource(h.channels);
    pending = {};
    order = [];
    h.host
      ..on('JobsHostApi', 'thumbnailTile', (args) {
        final id = args[0]! as String;
        order.add('${(args[1]! as ThumbnailRequestMsg).tileIndex}');
        return (pending[id] = Completer<ThumbnailTileMsg>()).future;
      })
      ..on('JobsHostApi', 'cancelThumbnail', (args) => null);
  });
  tearDown(() => h.dispose());

  Future<void> answer(String requestId, {ThumbnailTileMsg? tile, PlatformException? error}) async {
    final c = pending.remove(requestId)!;
    if (error != null) {
      c.completeError(error);
    } else {
      c.complete(tile ?? _tile(8));
    }
    await pumpEventQueue();
  }

  test('a tile request sends the request fields and maps the tile', () async {
    final handle = source.request(_req(3, proxy: true), priority: ThumbPriority.visible) as MobileThumbnailHandle;
    await pumpEventQueue();
    final args = h.argsOf('JobsHostApi', 'thumbnailTile').single;
    expect(args[0], handle.requestId);
    final msg = args[1]! as ThumbnailRequestMsg;
    expect((msg.media.uri, msg.media.fingerprint, msg.intervalMs, msg.tileIndex, msg.heightPx, msg.framesPerTile, msg.proxy),
        ('file:///d/clip.mov', 'qh_1', 500, 3, 48, 8, true));
    expect(args[2], ThumbPriorityMsg.visible);
    await answer(handle.requestId, tile: _tile(8));
    final tile = await handle.result;
    expect((tile.frames, tile.frameWidthPx), (8, 85));
    expect(tile.encoded, [0xFF, 0xD8, 8]);
  });

  test('at most 8 tiles are in flight; the queue drains visible > prefetch > background, FIFO within a priority', () async {
    final handles = <MobileThumbnailHandle>[
      for (var i = 0; i < 8; i++) source.request(_req(i), priority: ThumbPriority.background) as MobileThumbnailHandle,
    ];
    final bg = source.request(_req(100), priority: ThumbPriority.background) as MobileThumbnailHandle;
    final pre = source.request(_req(200), priority: ThumbPriority.prefetch) as MobileThumbnailHandle;
    final vis1 = source.request(_req(300), priority: ThumbPriority.visible) as MobileThumbnailHandle;
    final vis2 = source.request(_req(301), priority: ThumbPriority.visible) as MobileThumbnailHandle;
    await pumpEventQueue();
    expect(h.host.count('JobsHostApi', 'thumbnailTile'), 8);
    expect(source.inFlight, 8);
    expect(source.queued, 4);
    expect([bg, pre, vis1, vis2].map((x) => x.dispatched), everyElement(isFalse));

    for (final x in handles) {
      await answer(x.requestId);
    }
    await pumpEventQueue();
    expect(order.skip(8), ['300', '301', '200', '100']);
    expect(source.inFlight, 4);
    for (final x in [vis1, vis2, pre, bg]) {
      await answer(x.requestId);
    }
    expect(source.inFlight, 0);
    for (final x in [...handles, bg, pre, vis1, vis2]) {
      expect((await x.result).frames, 8);
    }
  });

  test('every request gets a distinct id', () async {
    final ids = {
      for (var i = 0; i < 20; i++) (source.request(_req(i), priority: ThumbPriority.prefetch) as MobileThumbnailHandle).requestId
    };
    expect(ids, hasLength(20));
  });

  test('cancelling a queued request never reaches native and frees nothing', () async {
    for (var i = 0; i < 8; i++) {
      source.request(_req(i), priority: ThumbPriority.visible);
    }
    final queued = source.request(_req(9), priority: ThumbPriority.visible) as MobileThumbnailHandle;
    await pumpEventQueue();
    queued.cancel();
    await expectLater(queued.result, throwsEngineCancelled);
    expect(source.queued, 0);
    expect(h.host.count('JobsHostApi', 'cancelThumbnail'), 0);
    expect(queued.dispatched, isFalse);
    for (final id in pending.keys.toList()) {
      await answer(id);
    }
    expect(h.host.count('JobsHostApi', 'thumbnailTile'), 8, reason: 'the cancelled request is never dispatched');
  });

  test('cancelling a dispatched request sends cancelThumbnail, completes at once and ignores the late native reply', () async {
    final handle = source.request(_req(1), priority: ThumbPriority.visible) as MobileThumbnailHandle;
    await pumpEventQueue();
    handle.cancel();
    handle.cancel(); // idempotent
    await expectLater(handle.result, throwsEngineCancelled);
    await pumpEventQueue();
    expect(h.argsOf('JobsHostApi', 'cancelThumbnail'), [
      [handle.requestId]
    ]);
    expect(source.inFlight, 1, reason: 'the slot is held until native answers');
    await answer(handle.requestId, tile: _tile(8)); // the race: native finished anyway
    await expectLater(handle.result, throwsEngineCancelled);
    expect(source.inFlight, 0);
  });

  test('a native cancelled reply also frees the slot of a cancelled request and lets the queue advance', () async {
    for (var i = 0; i < 8; i++) {
      source.request(_req(i), priority: ThumbPriority.visible);
    }
    final next = source.request(_req(42), priority: ThumbPriority.visible) as MobileThumbnailHandle;
    await pumpEventQueue();
    final firstId = pending.keys.first;
    await answer(firstId, error: PlatformException(code: 'cancelled', message: 'cancelled'));
    expect(next.dispatched, isTrue);
    expect(order.last, '42');
  });

  test('cancel after the result is a no-op', () async {
    final handle = source.request(_req(1), priority: ThumbPriority.visible) as MobileThumbnailHandle;
    await pumpEventQueue();
    await answer(handle.requestId);
    expect((await handle.result).frames, 8);
    handle.cancel();
    await pumpEventQueue();
    expect((await handle.result).frames, 8);
    expect(h.host.count('JobsHostApi', 'cancelThumbnail'), 0);
  });

  test('native failures are typed and scrubbed; the slot is freed', () async {
    final handle = source.request(_req(1), priority: ThumbPriority.visible) as MobileThumbnailHandle;
    await pumpEventQueue();
    await answer(handle.requestId, error: PlatformException(code: 'decodeFailed', message: 'bad frame in /private/var/x.mov'));
    await expectLater(
      handle.result,
      throwsA(isA<EngineError>()
          .having((e) => e.code, 'code', EngineErrorCode.decodeFailed)
          .having((e) => e.debugDetail, 'detail', isNot(contains('/private')))),
    );
    expect(source.inFlight, 0);
  });

  test('without a native engine every request fails notSupportedOnDevice', () async {
    final bare = EngineChannels(config: servicesConfig, messageChannelSuffix: 'no_native');
    addTearDown(bare.dispose);
    final s = MobileThumbnailSource(bare);
    final handle = s.request(_req(0), priority: ThumbPriority.visible);
    await expectLater(handle.result, throwsEngineError(EngineErrorCode.notSupportedOnDevice));
    await pumpEventQueue();
    expect(s.inFlight, 0);
  });
}
