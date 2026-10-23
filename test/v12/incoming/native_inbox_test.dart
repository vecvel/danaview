// OWNER: HOM-21
//
// NativeInbox over a mock binary messenger (BUILD_PLAN HOM-21, ARCH v1.2 §5.6, rule 26): batches
// and files map from the Pigeon messages, takeFile / deleteBatch / deleteStaleBatches /
// writeFolderSnapshot send their arguments, an unregistered host API (macOS, Android, desktop)
// means "no inbox" rather than an error, the extension's inboxChanged event reaches `changes`,
// argument checks run before the call, and toString never prints names (rule 30). NativeInboxPort
// adapts it for the library's InboxImporter.
//
// The root package reaches danaview_library_native and danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:danaview_features/src/player/danaview_player_actions.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_library_native/src/pigeon/library_api.g.dart';
import 'package:danaview_library_native/src/pigeon/library_channels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _prefix = 'dev.flutter.pigeon.danaview_library_native.InboxHostApi';
const _methods = ['isAvailable', 'listBatches', 'takeFile', 'deleteBatch', 'deleteStaleBatches', 'writeFolderSnapshot'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = InboxHostApi.pigeonChannelCodec;
  final calls = <String, List<Object?>>{};

  void answer(String method, Object? Function(List<Object?> args) reply) {
    messenger.setMockMessageHandler('$_prefix.$method', (message) async {
      final args = (codec.decodeMessage(message) as List<Object?>?) ?? const [];
      calls[method] = args;
      final out = reply(args);
      if (out is PlatformException) return codec.encodeMessage(<Object?>[out.code, out.message, out.details]);
      return codec.encodeMessage(<Object?>[out]);
    });
  }

  tearDown(() {
    calls.clear();
    for (final m in _methods) {
      messenger.setMockMessageHandler('$_prefix.$m', null);
    }
  });

  final batch = InboxBatchMsg(
    batchId: '1790000000000-abc',
    createdAtMs: 1790000000000,
    complete: true,
    targetFolderId: 'fd_AAAAAAAAAAAAAAAAAAAAAA',
    files: [
      InboxFileMsg(relativePath: 'items/0/Lease.pdf', displayName: 'Lease.pdf', uti: 'com.adobe.pdf', sizeBytes: 1200),
      InboxFileMsg(relativePath: 'items/1/IMG_1.HEIC', displayName: 'IMG_1.HEIC', sizeBytes: 900),
    ],
  );

  test('batches and files map from the messages', () async {
    answer('listBatches', (_) => [batch, InboxBatchMsg(batchId: 'partial', createdAtMs: 5, complete: false, targetFolderId: '', files: [])]);
    final list = await NativeInbox().listBatches();
    expect(list, hasLength(2));
    final b = list.first;
    expect(b.batchId, '1790000000000-abc');
    expect(b.createdAt, DateTime.fromMillisecondsSinceEpoch(1790000000000, isUtc: true));
    expect(b.complete, isTrue);
    expect(b.targetFolderId, 'fd_AAAAAAAAAAAAAAAAAAAAAA');
    expect(b.files.map((f) => f.displayName), ['Lease.pdf', 'IMG_1.HEIC']);
    expect(b.files.first.uti, 'com.adobe.pdf');
    expect(b.files.last.sizeBytes, 900);
    expect(list.last.complete, isFalse);
    expect(list.last.targetFolderId, isNull, reason: 'an empty folder id means Imported');
    expect('$b ${b.files.first}', isNot(contains('Lease')));
  });

  test('calls send their arguments', () async {
    answer('takeFile', (_) => null);
    answer('deleteBatch', (_) => null);
    answer('deleteStaleBatches', (_) => 3);
    answer('writeFolderSnapshot', (_) => null);
    final inbox = NativeInbox();
    await inbox.takeFile('b', 'items/0/a.pdf', '/app/staging/a.pdf');
    expect(calls['takeFile'], ['b', 'items/0/a.pdf', '/app/staging/a.pdf']);
    await inbox.deleteBatch('b');
    expect(calls['deleteBatch'], ['b']);
    expect(await inbox.deleteStaleBatches(const Duration(hours: 24)), 3);
    expect(calls['deleteStaleBatches'], [24 * 3600 * 1000]);
    await inbox.writeFolderSnapshot([1, 2, 3]);
    expect(calls['writeFolderSnapshot'], [Uint8List.fromList([1, 2, 3])]);
  });

  test('arguments are checked before the call', () {
    final inbox = NativeInbox();
    expect(() => inbox.takeFile('', 'a', '/b'), throwsArgumentError);
    expect(() => inbox.takeFile('b', '', '/b'), throwsArgumentError);
    expect(() => inbox.takeFile('b', 'a', ''), throwsArgumentError);
    expect(() => inbox.deleteBatch(''), throwsArgumentError);
    expect(() => inbox.deleteStaleBatches(const Duration(seconds: -1)), throwsArgumentError);
    expect(calls, isEmpty);
  });

  test('no host API (macOS, Android, desktop) or notSupportedOnDevice means no inbox', () async {
    expect(await NativeInbox().isAvailable(), isFalse, reason: 'unregistered channel');
    answer('isAvailable', (_) => PlatformException(code: 'notSupportedOnDevice', message: 'iOS only'));
    expect(await NativeInbox().isAvailable(), isFalse);
    answer('isAvailable', (_) => true);
    expect(await NativeInbox().isAvailable(), isTrue);
    answer('deleteBatch', (_) => PlatformException(code: 'ioError', message: 'delete failed (4)'));
    await expectLater(NativeInbox().deleteBatch('b'), throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.ioError)));
  });

  test("the extension's inboxChanged event reaches changes", () async {
    final events = StreamController<LibraryEventMsg>();
    final inbox = NativeInbox(events: LibraryEventHub.over(() => events.stream));
    final got = <void>[];
    final sub = inbox.changes.listen(got.add);
    events
      ..add(LibraryEventMsg(kind: LibraryEventKindMsg.photoLibraryChanged))
      ..add(LibraryEventMsg(kind: LibraryEventKindMsg.inboxChanged));
    await Future<void>.delayed(Duration.zero);
    expect(got, hasLength(1));
    await sub.cancel();
    await events.close();
  });

  test('NativeInboxPort adapts batches for the library importer', () async {
    answer('isAvailable', (_) => true);
    answer('listBatches', (_) => [batch, InboxBatchMsg(batchId: 'x', createdAtMs: 1, complete: true, targetFolderId: 'not-a-folder-id', files: [])]);
    answer('deleteStaleBatches', (_) => 0);
    final port = NativeInboxPort();
    expect(await port.isAvailable(), isTrue);
    final batches = await port.listBatches();
    expect(batches.first.targetFolder, FolderId.parse('fd_AAAAAAAAAAAAAAAAAAAAAA'));
    expect(batches.first.files.first, const InboxFile(relativePath: 'items/0/Lease.pdf', displayName: 'Lease.pdf', sizeBytes: 1200, uti: 'com.adobe.pdf'));
    expect(batches.last.targetFolder, isNull, reason: 'a malformed folder id falls back to Imported');
    expect(await port.deleteStaleBatches(const Duration(hours: 24)), 0);
  });
}
