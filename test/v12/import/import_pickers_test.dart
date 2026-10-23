// OWNER: HOM-20
//
// The import sheet's pickers and the native copier (BUILD_PLAN HOM-20, ARCH v1.2 §5.6): picker
// results become import sources (only files inside the staging directory are staged copies, so a
// user's original is never deleted), a cancelled pick is empty, an unsupported picker is reported,
// the desktop picker wraps file_selector paths, and a platform URI is imported end to end through
// the plugin's streamed copy (resumable offset, progress, error mapping, grant release).
//
// The root package reaches danaview_library and danaview_library_native through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:danaview_features/src/library/import/import_pickers.dart';
import 'package:danaview_library/danaview_library.dart';
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

  void answer(String method, Object? Function(List<Object?> args) reply) {
    messenger.setMockMessageHandler('$_prefix.$method', (message) async {
      final args = (codec.decodeMessage(message) as List<Object?>?) ?? const [];
      final out = reply(args);
      if (out is PlatformException) return codec.encodeMessage(<Object?>[out.code, out.message, out.details]);
      return codec.encodeMessage(<Object?>[out]);
    });
  }

  tearDown(() {
    for (final m in ['pickPhotos', 'pickDocuments', 'copyToFile', 'cancelCopy', 'release']) {
      messenger.setMockMessageHandler('$_prefix.$m', null);
    }
  });

  NativePickers pickers() => NativePickers(events: LibraryEventHub.over(() => const Stream.empty()));

  group('importSourcesOf', () {
    test('staged photo picks are staged copies; open-panel files and URIs are not', () {
      final staging = Directory.systemTemp.createTempSync('hom20_staging_');
      addTearDown(() => staging.deleteSync(recursive: true));
      final sources = importSourcesOf([
        PickedItem(uri: 'file://${staging.path}/IMG.heic', path: '${staging.path}/IMG.heic', displayName: 'IMG.heic', uti: 'public.heic', source: PickedItemSource.photoLibrary, needsCopy: false, sizeBytes: 3),
        const PickedItem(uri: 'file:///Users/me/Report.pdf', path: '/Users/me/Report.pdf', displayName: 'Report.pdf', source: PickedItemSource.files, needsCopy: false),
        const PickedItem(uri: 'content://docs/9', displayName: 'Scan.pdf', mimeType: 'application/pdf', source: PickedItemSource.files, needsCopy: true),
        PickedItem(uri: 'file://${staging.path}x/evil', path: '${staging.path}x/evil.jpg', displayName: 'evil.jpg', source: PickedItemSource.files, needsCopy: false),
      ], stagingDirectory: staging.path);
      expect(sources[0].kind, ImportSourceKind.file);
      expect(sources[0].stagedCopy, isTrue);
      expect(sources[0].sourceHint, SourceHint.photos);
      expect(sources[0].uti, 'public.heic');
      expect(sources[0].sizeBytes, 3);
      expect(sources[1].stagedCopy, isFalse, reason: "the user's own file is never deleted");
      expect(sources[1].sourceHint, SourceHint.files);
      expect(sources[2].kind, ImportSourceKind.nativeUri);
      expect(sources[2].location, 'content://docs/9');
      expect(sources[2].releaseUri, 'content://docs/9');
      expect(sources[2].mime, 'application/pdf');
      expect(sources[3].stagedCopy, isFalse, reason: 'a sibling directory with the same prefix is not the staging directory');
    });
  });

  test('NativeImportPicker: cancelled is empty, unsupported is reported', () async {
    final picker = NativeImportPicker(stagingDirectory: '/staging', pickers: pickers());
    await expectLater(picker.pickPhotos(), throwsA(isA<ImportPickException>().having((e) => e.unsupported, 'unsupported', isTrue)));
    answer('pickPhotos', (_) => PlatformException(code: 'cancelled'));
    expect(await picker.pickPhotos(), isEmpty);
    answer('pickDocuments', (args) {
      expect((args.single! as DocumentPickRequestMsg).destinationDirectory, '/staging');
      return [PickedItemMsg(uri: 'file:///staging/a.pdf', path: '/staging/a.pdf', displayName: 'a.pdf', source: PickedSourceMsg.files, needsCopy: false)];
    });
    final files = await picker.pickFiles();
    expect(files.single.displayName, 'a.pdf');
    expect(files.single.stagedCopy, isTrue);
    answer('pickDocuments', (_) => PlatformException(code: 'ioError'));
    await expectLater(picker.pickFiles(), throwsA(isA<ImportPickException>().having((e) => e.unsupported, 'unsupported', isFalse)));
  });

  test('CallbackImportPicker wraps desktop paths and has no photo picker', () async {
    final picker = CallbackImportPicker(() async => ['/home/me/Notes.txt', r'C:\Users\me\Deck.pptx']);
    expect(picker.canPickPhotos, isFalse);
    expect(await picker.pickPhotos(), isEmpty);
    final files = await picker.pickFiles();
    expect(files.map((s) => s.displayName), ['Notes.txt', 'Deck.pptx']);
    expect(files.every((s) => s.kind == ImportSourceKind.file && !s.stagedCopy), isTrue);
    final failing = CallbackImportPicker(() async => throw StateError('dialog failed'));
    await expectLater(failing.pickFiles(), throwsA(isA<ImportPickException>()));
  });

  test('a platform URI imports end to end through the native copy', () async {
    final root = Directory.systemTemp.createTempSync('hom20_native_lib_');
    addTearDown(() => root.deleteSync(recursive: true));
    final bytes = List<int>.generate(70000, (i) => i * 7 % 256);
    final requests = <CopyRequestMsg>[];
    answer('copyToFile', (args) {
      final r = args.single! as CopyRequestMsg;
      requests.add(r);
      // The native side writes only the requested part file.
      File(r.destinationPath).writeAsBytesSync(bytes.sublist(r.resumeFromOffset), mode: r.resumeFromOffset > 0 ? FileMode.append : FileMode.write);
      return CopyResultMsg(bytesCopied: bytes.length, totalBytes: bytes.length);
    });
    final released = <String>[];
    answer('release', (args) {
      released.add(args.single! as String);
      return null;
    });
    final store = await LibraryStore.open(root: root.path, background: false);
    addTearDown(store.close);
    final copier = NativeImportCopier(pickers: pickers());
    final service = ImportService(store: store, copiers: [const FileImportCopier(), copier], release: copier.release);
    const source = ImportSource(
      kind: ImportSourceKind.nativeUri,
      location: 'content://docs/42',
      displayName: 'Scan.pdf',
      mime: 'application/pdf',
      sizeBytes: 70000,
      sourceHint: SourceHint.files,
      releaseUri: 'content://docs/42',
    );
    final item = (await service.importAll([source])).single;
    expect(item.state, ImportItemState.done);
    expect(item.entry!.kind, FileKind.document);
    expect(item.entry!.sizeBytes, 70000);
    expect(File(store.paths.entryFile(item.entry!.id, item.entry!.displayName)).readAsBytesSync(), bytes);
    expect(requests.single.sourceUri, 'content://docs/42');
    expect(requests.single.resumeFromOffset, 0);
    expect(requests.single.destinationPath, startsWith(store.paths.importsDir));
    expect(released, ['content://docs/42']);
  });

  test('native copy failures map to import failures', () async {
    final root = Directory.systemTemp.createTempSync('hom20_native_err_');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = await LibraryStore.open(root: root.path, background: false);
    addTearDown(store.close);
    final service = ImportService(store: store, copiers: [NativeImportCopier(pickers: pickers())]);
    const source = ImportSource(kind: ImportSourceKind.nativeUri, location: 'content://gone', displayName: 'x.jpg');
    for (final (code, failure) in [
      ('notFound', ImportFailure.sourceUnreadable),
      ('permissionDenied', ImportFailure.sourceUnreadable),
      ('cancelled', ImportFailure.cancelled),
      ('ioError', ImportFailure.ioError),
    ]) {
      answer('copyToFile', (_) => PlatformException(code: code));
      final item = (await service.importAll([source])).single;
      expect(item.failure, failure, reason: code);
    }
    expect(store.reader.importJobs(), isEmpty);
  });
}
