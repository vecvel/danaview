// OWNER: HOM-20
//
// NativePickers over a mock binary messenger (BUILD_PLAN HOM-20, ARCH v1.2 §5.6): the photo and
// document pick requests carry their fields, every PickedItemMsg field reaches PickedItem, the
// streamed copy reports only its own progress events, errors map to LibraryNativeException (an
// unregistered host API is notSupportedOnDevice, e.g. Windows and Linux), arguments are checked
// before the call, and toString never prints a name or URI (rule 30).
//
// The root package has no direct dependency on danaview_library_native (it arrives through
// danaview_features), so this test imports it transitively.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_library_native/src/pigeon/library_api.g.dart';
import 'package:danaview_library_native/src/pigeon/library_channels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _prefix = 'dev.flutter.pigeon.danaview_library_native.PickerHostApi';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = PickerHostApi.pigeonChannelCodec;

  void answer(String method, FutureOr<Object?> Function(List<Object?> args) reply) {
    messenger.setMockMessageHandler('$_prefix.$method', (message) async {
      final args = (codec.decodeMessage(message) as List<Object?>?) ?? const [];
      final out = await reply(args);
      if (out is PlatformException) return codec.encodeMessage(<Object?>[out.code, out.message, out.details]);
      return codec.encodeMessage(<Object?>[out]);
    });
  }

  tearDown(() {
    for (final m in ['pickPhotos', 'pickDocuments', 'copyToFile', 'cancelCopy', 'release']) {
      messenger.setMockMessageHandler('$_prefix.$m', null);
    }
  });

  PickedItemMsg msg({bool photo = true, bool needsCopy = false}) => PickedItemMsg(
        uri: photo ? 'file:///staging/IMG_0001.heic' : 'content://docs/42',
        path: needsCopy ? null : '/staging/IMG_0001.heic',
        displayName: photo ? 'IMG_0001.heic' : 'Quarterly Report.pdf',
        uti: photo ? 'public.heic' : 'com.adobe.pdf',
        mimeType: photo ? 'image/heic' : 'application/pdf',
        sizeBytes: 1234,
        modifiedTimeMs: 1700000000000,
        assetIdentifier: photo ? 'A/L0/001' : null,
        source: photo ? PickedSourceMsg.photoLibrary : PickedSourceMsg.files,
        needsCopy: needsCopy,
      );

  test('pickPhotos sends the request and maps every field', () async {
    PhotoPickRequestMsg? sent;
    answer('pickPhotos', (args) {
      sent = args.single! as PhotoPickRequestMsg;
      return [msg()];
    });
    final pickers = NativePickers(events: LibraryEventHub.over(() => const Stream.empty()));
    final items = await pickers.pickPhotos(stagingDirectory: '/staging', limit: 5, filter: PhotoPickFilter.videos);
    expect(sent!.selectionLimit, 5);
    expect(sent!.filter, PhotoMediaFilterMsg.videos);
    expect(sent!.destinationDirectory, '/staging');
    final item = items.single;
    expect(item.uri, 'file:///staging/IMG_0001.heic');
    expect(item.path, '/staging/IMG_0001.heic');
    expect(item.displayName, 'IMG_0001.heic');
    expect(item.uti, 'public.heic');
    expect(item.mimeType, 'image/heic');
    expect(item.sizeBytes, 1234);
    expect(item.modifiedAt, DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));
    expect(item.assetIdentifier, 'A/L0/001');
    expect(item.source, PickedItemSource.photoLibrary);
    expect(item.needsCopy, isFalse);
    expect(item.toString(), isNot(contains('IMG')));
    expect(item.toString(), isNot(contains('staging')));
  });

  test('pickDocuments sends the types and an optional staging directory', () async {
    DocumentPickRequestMsg? sent;
    answer('pickDocuments', (args) {
      sent = args.single! as DocumentPickRequestMsg;
      return [msg(photo: false, needsCopy: true)];
    });
    final pickers = NativePickers(events: LibraryEventHub.over(() => const Stream.empty()));
    final items = await pickers.pickDocuments(allowMultiple: false, utis: ['com.adobe.pdf'], mimeTypes: ['application/pdf']);
    expect(sent!.allowMultiple, isFalse);
    expect(sent!.utis, ['com.adobe.pdf']);
    expect(sent!.mimeTypes, ['application/pdf']);
    expect(sent!.destinationDirectory, isNull);
    expect(items.single.source, PickedItemSource.files);
    expect(items.single.needsCopy, isTrue);
    expect(items.single.path, isNull);
    await pickers.pickDocuments(stagingDirectory: '/staging');
    expect(sent!.destinationDirectory, '/staging');
    expect(sent!.allowMultiple, isTrue);
  });

  test('an empty pick (cancelled) is an empty list', () async {
    answer('pickPhotos', (_) => <PickedItemMsg>[]);
    final pickers = NativePickers(events: LibraryEventHub.over(() => const Stream.empty()));
    expect(await pickers.pickPhotos(stagingDirectory: '/s'), isEmpty);
  });

  test('copyToFile sends the request and reports only its own progress', () async {
    final events = StreamController<LibraryEventMsg>.broadcast();
    addTearDown(events.close);
    CopyRequestMsg? sent;
    answer('copyToFile', (args) async {
      sent = args.single! as CopyRequestMsg;
      events.add(LibraryEventMsg(kind: LibraryEventKindMsg.copyProgress, copyProgress: CopyProgressMsg(requestId: 'other', bytesDone: 99)));
      events.add(LibraryEventMsg(kind: LibraryEventKindMsg.copyProgress, copyProgress: CopyProgressMsg(requestId: sent!.requestId, bytesDone: 10, bytesTotal: 20)));
      events.add(LibraryEventMsg(kind: LibraryEventKindMsg.inboxChanged));
      events.add(LibraryEventMsg(kind: LibraryEventKindMsg.copyProgress, copyProgress: CopyProgressMsg(requestId: sent!.requestId, bytesDone: 20, bytesTotal: 20)));
      await Future<void>.delayed(Duration.zero);
      return CopyResultMsg(bytesCopied: 20, totalBytes: 20);
    });
    final pickers = NativePickers(events: LibraryEventHub.over(() => events.stream));
    final progress = <(int, int?)>[];
    final r = await pickers.copyToFile(
      sourceUri: 'content://docs/42',
      destinationPath: '/lib/imports/j.part',
      resumeFromOffset: 7,
      requestId: 'req-1',
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(sent!.requestId, 'req-1');
    expect(sent!.sourceUri, 'content://docs/42');
    expect(sent!.destinationPath, '/lib/imports/j.part');
    expect(sent!.resumeFromOffset, 7);
    expect(r.bytesCopied, 20);
    expect(r.totalBytes, 20);
    expect(progress, [(10, 20), (20, 20)]);
    expect(() => pickers.copyToFile(sourceUri: 'x', destinationPath: 'y', resumeFromOffset: -1), throwsArgumentError);
  });

  test('errors map to LibraryNativeException; an unregistered API is notSupportedOnDevice', () async {
    final pickers = NativePickers(events: LibraryEventHub.over(() => const Stream.empty()));
    await expectLater(
      pickers.pickPhotos(stagingDirectory: '/s'),
      throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.notSupportedOnDevice)),
    );
    answer('copyToFile', (_) => PlatformException(code: 'cancelled', message: 'copy cancelled'));
    await expectLater(
      pickers.copyToFile(sourceUri: 'content://a', destinationPath: '/p'),
      throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.cancelled)),
    );
    String? cancelled;
    answer('cancelCopy', (args) {
      cancelled = args.single! as String;
      return null;
    });
    await pickers.cancelCopy('req-9');
    expect(cancelled, 'req-9');
    String? released;
    answer('release', (args) {
      released = args.single! as String;
      return null;
    });
    await pickers.release('file:///scoped');
    expect(released, 'file:///scoped');
  });

  test('arguments are checked before the call', () {
    final pickers = NativePickers(events: LibraryEventHub.over(() => const Stream.empty()));
    expect(() => pickers.pickPhotos(stagingDirectory: '/s', limit: -1), throwsArgumentError);
    expect(() => pickers.pickPhotos(stagingDirectory: ''), throwsArgumentError);
  });
}
