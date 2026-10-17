// OWNER: ENG-03
//
// MobileMediaPicker, MobileFileHandoff, MobileBackgroundWorkGuard (lease lifecycle, progress
// forwarding, expiry) and MobileExternalDropTarget over mocked channels (ARCH §12.4, §15, D-18).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart' show MediaOrigin, PickedMedia;
import 'package:danaview_editor_engine/src/mobile_platform_services.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_channels.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support/services_harness.dart';

PickedMediaMsg _picked(String uri, {PickOriginMsg origin = PickOriginMsg.photos, bool temp = true, Uint8List? bookmark}) =>
    PickedMediaMsg(uri: uri, displayName: uri.split('/').last, origin: origin, isTemporaryCopy: temp, bookmark: bookmark, sizeBytes: 10);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServicesHarness h;
  setUp(() => h = ServicesHarness());
  tearDown(() => h.dispose());

  group('MediaPicker', () {
    test('sends source, kinds and multiple; maps picked items', () async {
      h.host.on(
          'PlatformHostApi',
          'pick',
          (_) => [
                _picked('file:///c/danaview/editor/work/picks/u1/a.mov'),
                _picked('file:///private/var/mobile/b.cube',
                    origin: PickOriginMsg.files, temp: false, bookmark: Uint8List.fromList([1, 2])),
              ]);
      final picked = await MobileMediaPicker(h.channels)
          .pick(const MediaPickRequest(source: MediaPickSource.files, kinds: {MediaPickKind.lut, MediaPickKind.video}, multiple: false));
      final sent = h.argsOf('PlatformHostApi', 'pick').single.single! as MediaPickRequestMsg;
      expect((sent.source, sent.multiple), (MediaPickSourceMsg.files, false));
      expect(sent.kinds, [MediaPickKindMsg.video, MediaPickKindMsg.lut]);
      expect(picked, hasLength(2));
      expect(
          picked[0],
          const PickedMedia(
              uri: 'file:///c/danaview/editor/work/picks/u1/a.mov',
              displayName: 'a.mov',
              origin: MediaOrigin.photos,
              isTemporaryCopy: true,
              sizeBytes: 10));
      expect(picked[1].origin, MediaOrigin.files);
      expect(picked[1].bookmark, [1, 2]);
      expect(picked[1].isTemporaryCopy, isFalse);
    });

    test('an empty list or a cancelled reply means cancelled; other failures are typed', () async {
      final picker = MobileMediaPicker(h.channels);
      const req = MediaPickRequest(source: MediaPickSource.photos, kinds: {MediaPickKind.video});
      h.host.on('PlatformHostApi', 'pick', (_) => <PickedMediaMsg>[]);
      expect(await picker.pick(req), isEmpty);
      h.host.fail('PlatformHostApi', 'pick', 'cancelled');
      expect(await picker.pick(req), isEmpty);
      h.host.fail('PlatformHostApi', 'pick', 'io', message: 'clonefile failed');
      await expectLater(picker.pick(req), throwsEngineError(EngineErrorCode.io));
    });
  });

  group('FileHandoff', () {
    test('saveToPhotos, saveToFiles and share map outcomes and saved URIs', () async {
      h.host
        ..on('PlatformHostApi', 'saveToPhotos', (_) => FileHandoffResultMsg(outcome: FileHandoffOutcomeMsg.done, savedUri: 'ph://1'))
        ..on('PlatformHostApi', 'saveToFiles', (_) => FileHandoffResultMsg(outcome: FileHandoffOutcomeMsg.cancelled))
        ..on('PlatformHostApi', 'share', (_) => FileHandoffResultMsg(outcome: FileHandoffOutcomeMsg.failed));
      final files = MobileFileHandoff(h.channels);
      final photos = await files.saveToPhotos('/c/danaview/editor/work/export-1.mp4');
      expect((photos.outcome, photos.savedUri), (FileHandoffOutcome.done, 'ph://1'));
      expect((await files.saveToFiles('/c/x.mp4', 'Trip.mp4')).outcome, FileHandoffOutcome.cancelled);
      expect(h.argsOf('PlatformHostApi', 'saveToFiles').single, ['/c/x.mp4', 'Trip.mp4']);
      expect((await files.share('/c/x.mp4')).outcome, FileHandoffOutcome.failed);
    });

    test('cancelled and permissionDenied replies map to outcomes; other failures are typed', () async {
      final files = MobileFileHandoff(h.channels);
      h.host.fail('PlatformHostApi', 'saveToPhotos', 'permissionDenied');
      expect((await files.saveToPhotos('/x')).outcome, FileHandoffOutcome.denied);
      h.host.fail('PlatformHostApi', 'saveToPhotos', 'cancelled');
      expect((await files.saveToPhotos('/x')).outcome, FileHandoffOutcome.cancelled);
      h.host.fail('PlatformHostApi', 'share', 'weird_native_code');
      await expectLater(files.share('/x'), throwsEngineError(EngineErrorCode.internal));
    });
  });

  group('BackgroundWorkGuard leases', () {
    late List<double> updates;
    late Completer<void>? updateGate;

    setUp(() {
      updates = [];
      updateGate = null;
      h.host
        ..on('PlatformHostApi', 'acquireBackground', (args) => 'lease1')
        ..on('PlatformHostApi', 'updateBackground', (args) {
          updates.add(args[1]! as double);
          return updateGate?.future;
        })
        ..on('PlatformHostApi', 'releaseBackground', (_) => null);
    });

    test('acquire → progress forwarded → release once; nothing is sent after release', () async {
      final progress = StreamController<double>();
      final lease = await MobileBackgroundWorkGuard(h.channels).acquire(title: 'Exporting Trip', progress: progress.stream);
      expect(lease, isNotNull);
      expect(lease!.id, 'lease1');
      expect(h.argsOf('PlatformHostApi', 'acquireBackground').single, ['Exporting Trip']);
      progress
        ..add(0.1)
        ..add(-3);
      await pumpEventQueue();
      progress.add(0.5);
      await pumpEventQueue();
      expect(updates, [0.1, 0.0, 0.5]);
      await Future.wait([lease.release(), lease.release()]);
      expect(h.argsOf('PlatformHostApi', 'releaseBackground'), [
        ['lease1']
      ]);
      expect(progress.hasListener, isFalse, reason: 'the progress subscription is cancelled');
      expect((lease as MobileBackgroundLease).isReleased, isTrue);
      await progress.close();
    });

    test('progress updates are coalesced: one call in flight, the latest value wins', () async {
      updateGate = Completer<void>();
      final progress = StreamController<double>();
      final lease = (await MobileBackgroundWorkGuard(h.channels).acquire(title: 't', progress: progress.stream))! as MobileBackgroundLease;
      progress.add(0.1);
      await pumpEventQueue();
      progress
        ..add(0.2)
        ..add(0.3)
        ..add(0.4);
      await pumpEventQueue();
      expect(updates, [0.1]);
      final gate = updateGate!;
      updateGate = null;
      gate.complete();
      await pumpEventQueue();
      expect(updates, [0.1, 0.4]);
      expect(lease.lastSentProgress, 0.4);
      await lease.release();
      await progress.close();
    });

    test('leaseExpiring events reach `expiring`; release closes it and drops late events', () async {
      final lease = (await MobileBackgroundWorkGuard(h.channels).acquire(title: 't', progress: const Stream.empty()))!;
      var expiries = 0;
      var closed = false;
      lease.expiring.listen((_) => expiries++, onDone: () => closed = true);
      await h.emit(EngineEventMsg(kind: EngineEventKindMsg.leaseExpiring, jobId: 'lease1'));
      await h.emit(EngineEventMsg(kind: EngineEventKindMsg.leaseExpiring, jobId: 'other'));
      expect(expiries, 1);
      await lease.release();
      await pumpEventQueue();
      expect(closed, isTrue);
      await h.emit(EngineEventMsg(kind: EngineEventKindMsg.leaseExpiring, jobId: 'lease1'));
      expect(expiries, 1);
    });

    test('an expiry that arrives before anyone listens to `expiring` is not lost to the router', () async {
      final lease = (await MobileBackgroundWorkGuard(h.channels).acquire(title: 't', progress: const Stream.empty()))!;
      await h.emit(EngineEventMsg(kind: EngineEventKindMsg.leaseExpiring, jobId: 'lease1'));
      expect(h.channels.router.unclaimedRouteCount, 0, reason: 'the lease listens from acquire on');
      await lease.release();
    });

    test('no lease available: null id or notSupportedOnDevice → null; other failures are typed', () async {
      final guard = MobileBackgroundWorkGuard(h.channels);
      h.host.on('PlatformHostApi', 'acquireBackground', (_) => null);
      expect(await guard.acquire(title: 't', progress: const Stream.empty()), isNull);
      h.host.fail('PlatformHostApi', 'acquireBackground', 'notSupportedOnDevice');
      expect(await guard.acquire(title: 't', progress: const Stream.empty()), isNull);
      h.host.fail('PlatformHostApi', 'acquireBackground', 'busy');
      await expectLater(guard.acquire(title: 't', progress: const Stream.empty()), throwsEngineError(EngineErrorCode.busy));

      final bare = EngineChannels(config: servicesConfig, messageChannelSuffix: 'no_native');
      addTearDown(bare.dispose);
      expect(await MobileBackgroundWorkGuard(bare).acquire(title: 't', progress: const Stream.empty()), isNull);
    });

    test('an update failure does not break forwarding; a release failure is typed', () async {
      final progress = StreamController<double>();
      h.host.on('PlatformHostApi', 'updateBackground', (args) {
        updates.add(args[1]! as double);
        if (updates.length == 1) throw PlatformException(code: 'io');
        return null;
      });
      final lease = (await MobileBackgroundWorkGuard(h.channels).acquire(title: 't', progress: progress.stream))!;
      progress.add(0.3);
      await pumpEventQueue();
      progress.add(0.6);
      await pumpEventQueue();
      expect(updates, [0.3, 0.6]);
      h.host.fail('PlatformHostApi', 'releaseBackground', 'internal');
      await expectLater(lease.release(), throwsEngineError(EngineErrorCode.internal));
      await progress.close();
    });
  });

  group('ExternalDropTarget', () {
    DropMsg drop(double x, double y) =>
        DropMsg(items: [_picked('file:///c/danaview/editor/work/drops/u/a.mp4', origin: PickOriginMsg.drop)], x: x, y: y);

    test('setEnabled reaches native; drops arrive with logical positions only while enabled', () async {
      h.host.on('PlatformHostApi', 'setDropTargetEnabled', (_) => null);
      final target = MobileExternalDropTarget(h.channels);
      final got = <ExternalDrop>[];
      target.drops.listen(got.add);
      await target.setEnabled(true);
      expect(target.isEnabled, isTrue);
      await h.emit(EngineEventMsg(kind: EngineEventKindMsg.drop, drop: drop(120.5, 64)));
      expect(got.single.position, const Offset(120.5, 64));
      expect(got.single.items.single.origin, MediaOrigin.drop);
      expect(got.single.items.single.isTemporaryCopy, isTrue);

      await target.setEnabled(false);
      await h.emit(EngineEventMsg(kind: EngineEventKindMsg.drop, drop: drop(1, 1)));
      expect(got, hasLength(1));
      expect(h.argsOf('PlatformHostApi', 'setDropTargetEnabled'), [
        [true],
        [false]
      ]);
    });

    test('disable wins over a slower earlier enable; a failed enable stays disabled', () async {
      final enableGate = Completer<void>();
      h.host.on('PlatformHostApi', 'setDropTargetEnabled', (args) => args.single == true ? enableGate.future : null);
      final target = MobileExternalDropTarget(h.channels);
      final enabling = target.setEnabled(true);
      await pumpEventQueue();
      await target.setEnabled(false);
      enableGate.complete();
      await enabling;
      expect(target.isEnabled, isFalse);

      h.host.fail('PlatformHostApi', 'setDropTargetEnabled', 'notSupportedOnDevice');
      await expectLater(target.setEnabled(true), throwsEngineError(EngineErrorCode.notSupportedOnDevice));
      expect(target.isEnabled, isFalse);
    });
  });
}
