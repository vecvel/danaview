// OWNER: HOM-22
//
// BUILD_PLAN HOM-22, getting files out in Dart: the danaview_library_native wrappers (Save out,
// share, open in) over a mock binary messenger send every field and map results and errors (an
// unregistered host API is notSupportedOnDevice, as on Windows and Linux); NativeFileOut maps them
// to the library's FileOutPort; DesktopFileOut (Windows, Linux) saves create-new copies, never
// writes over a file and never moves the library file, and opens a temporary copy in the default
// app. Nothing prints a path (rule 30). Generated files in temp dirs only.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:danaview_features/src/library/file_actions/file_out_ports.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_library_native/src/pigeon/library_api.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _pre = 'dev.flutter.pigeon.danaview_library_native';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answer(String api, String method, MessageCodec<Object?> codec, Object? Function(List<Object?> args) reply) {
    messenger.setMockMessageHandler('$_pre.$api.$method', (message) async {
      final args = (codec.decodeMessage(message) as List<Object?>?) ?? const [];
      final out = reply(args);
      if (out is PlatformException) return codec.encodeMessage(<Object?>[out.code, out.message, out.details]);
      return codec.encodeMessage(<Object?>[out]);
    });
  }

  tearDown(() {
    for (final c in ['ExportOutHostApi.saveOut', 'ShareHostApi.share', 'OpenInHostApi.openIn']) {
      messenger.setMockMessageHandler('$_pre.$c', null);
    }
  });

  const file = NativeOutFile(path: '/lib/files/fe_1/Report.pdf', displayName: 'Report.pdf', mimeType: 'application/pdf', uti: 'com.adobe.pdf');

  group('native wrappers', () {
    test('saveOut sends every field and maps the result', () async {
      SaveOutRequestMsg? sent;
      answer('ExportOutHostApi', 'saveOut', ExportOutHostApi.pigeonChannelCodec, (args) {
        sent = args.single! as SaveOutRequestMsg;
        return SaveOutResultMsg(cancelled: false, savedUris: ['file:///x/Report.pdf'], failedCount: 1);
      });
      final r = await NativeExportOut().saveOut(
        [file],
        destination: NativeSaveDestination.downloads,
        anchor: const NativeAnchor(1, 2, 3, 4),
      );
      final item = sent!.items.single;
      expect([item.path, item.displayName, item.mimeType, item.uti], [file.path, 'Report.pdf', 'application/pdf', 'com.adobe.pdf']);
      expect(sent!.destination, SaveOutDestinationMsg.downloads);
      expect(sent!.subdirectory, 'Danaview', reason: 'Download/Danaview');
      expect([sent!.anchor!.x, sent!.anchor!.y, sent!.anchor!.width, sent!.anchor!.height], [1, 2, 3, 4]);
      expect(r.savedCount, 1);
      expect(r.failedCount, 1);
      expect(r.cancelled, isFalse);
      expect(r.toString(), isNot(contains('file://')));
      expect(file.toString(), isNot(contains('/lib')));

      await NativeExportOut().saveOut([file]);
      expect(sent!.destination, SaveOutDestinationMsg.files);
      expect(sent!.subdirectory, isNull);
      expect(sent!.anchor, isNull);
    });

    test('share and openIn send their items and map the results', () async {
      ShareRequestMsg? shared;
      OpenInRequestMsg? opened;
      answer('ShareHostApi', 'share', ShareHostApi.pigeonChannelCodec, (args) {
        shared = args.single! as ShareRequestMsg;
        return ShareResultMsg(completed: true, activityType: 'com.apple.UIKit.activity.Mail');
      });
      answer('OpenInHostApi', 'openIn', OpenInHostApi.pigeonChannelCodec, (args) {
        opened = args.single! as OpenInRequestMsg;
        return false;
      });
      final s = await NativeShare().share([file, file], subject: 'Files');
      expect(shared!.items, hasLength(2));
      expect(shared!.subject, 'Files');
      expect(s.completed, isTrue);
      expect(s.activityType, 'com.apple.UIKit.activity.Mail');
      expect(await NativeOpenIn().openIn(file, anchor: const NativeAnchor(0, 0, 10, 10)), isFalse);
      expect(opened!.item.displayName, 'Report.pdf');
      expect(opened!.anchor!.width, 10);
    });

    test('errors map to LibraryNativeException codes; no native class is notSupportedOnDevice', () async {
      for (final code in ['busy', 'notFound', 'permissionDenied', 'notSupportedOnDevice', 'weird']) {
        answer('ExportOutHostApi', 'saveOut', ExportOutHostApi.pigeonChannelCodec, (_) => PlatformException(code: code, message: 'x'));
        await expectLater(
          NativeExportOut().saveOut([file], destination: NativeSaveDestination.photos),
          throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.fromCode(code))),
        );
      }
      await expectLater(
        NativeShare().share([file]),
        throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.notSupportedOnDevice)),
      );
      await expectLater(NativeOpenIn().openIn(file), throwsA(isA<LibraryNativeException>()));
    });

    test('arguments are checked before the channel', () {
      expect(() => NativeExportOut().saveOut(const []), throwsArgumentError);
      expect(() => NativeShare().share(const [NativeOutFile(path: '', displayName: 'a')]), throwsArgumentError);
      expect(() => NativeOpenIn().openIn(const NativeOutFile(path: '/a', displayName: '')), throwsArgumentError);
    });

    test('the Dart destinations mirror the Pigeon enum', () {
      expect([for (final d in NativeSaveDestination.values) d.name], [for (final d in SaveOutDestinationMsg.values) d.name]);
      expect([for (final d in SaveOutTarget.values) d.name], [for (final d in NativeSaveDestination.values) d.name]);
    });
  });

  group('NativeFileOut', () {
    test('maps outcomes and errors to the library port', () async {
      answer('ExportOutHostApi', 'saveOut', ExportOutHostApi.pigeonChannelCodec, (args) {
        final r = args.single! as SaveOutRequestMsg;
        return r.destination == SaveOutDestinationMsg.photos
            ? PlatformException(code: 'permissionDenied')
            : SaveOutResultMsg(cancelled: r.items.length > 1, savedUris: const ['a'], failedCount: 0);
      });
      final port = NativeFileOut(FileOutPlatform.iOS);
      expect(port.capabilities.saveLabel, 'Save to Files');
      const out = OutFile(path: '/lib/a.pdf', displayName: 'a.pdf');
      final saved = await port.saveOut([out], SaveOutTarget.files);
      expect((saved.cancelled, saved.saved, saved.failed), (false, 1, 0));
      expect((await port.saveOut([out, out], SaveOutTarget.files)).cancelled, isTrue);
      await expectLater(
        port.saveOut([out], SaveOutTarget.photos),
        throwsA(isA<FileOutException>().having((e) => e.error, 'error', FileOutError.denied)),
      );
      await expectLater(
        port.share([out]),
        throwsA(isA<FileOutException>().having((e) => e.error, 'error', FileOutError.unsupported)),
      );
    });
  });

  group('DesktopFileOut', () {
    late Directory dir;
    late File library;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('hom22_desktop_');
      library = File('${dir.path}/DanaviewLibrary/files/fe_1/Report.pdf')
        ..createSync(recursive: true)
        ..writeAsStringSync('library bytes');
      library.setLastModifiedSync(DateTime.utc(2020, 1, 2));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    void expectLibraryUnchanged() {
      expect(library.existsSync(), isTrue, reason: 'never moves the library file');
      expect(library.readAsStringSync(), 'library bytes');
      expect(library.lastModifiedSync().toUtc(), DateTime.utc(2020, 1, 2));
    }

    DesktopFileOut port({String? saveAs, String? saveDir, List<String>? opened}) => DesktopFileOut(
          pickSaveFile: (suggested) async => saveAs,
          pickSaveDirectory: () async => saveDir,
          openWithDefaultApp: (path) async {
            opened?.add(path);
            return true;
          },
          platform: FileOutPlatform.linux,
          tempRoot: '${dir.path}/danaview-out',
        );

    OutFile out() => OutFile(path: library.path, displayName: 'Report.pdf');

    test('save writes a create-new copy, even over a name the dialog confirmed', () async {
      final target = File('${dir.path}/Desktop/Report.pdf')
        ..createSync(recursive: true)
        ..writeAsStringSync('theirs');
      final r = await port(saveAs: target.path).saveOut([out()], SaveOutTarget.files);
      expect((r.cancelled, r.saved, r.failed), (false, 1, 0));
      expect(target.readAsStringSync(), 'theirs', reason: 'never writes over a file it didn\'t create');
      expect(File('${dir.path}/Desktop/Report (2).pdf').readAsStringSync(), 'library bytes');
      expectLibraryUnchanged();
    });

    test('several files go into the chosen folder; duplicates get new names; cancel saves nothing', () async {
      Directory('${dir.path}/Out').createSync();
      final r = await port(saveDir: '${dir.path}/Out').saveOut([out(), out()], SaveOutTarget.files);
      expect(r.saved, 2);
      expect(File('${dir.path}/Out/Report.pdf').existsSync() && File('${dir.path}/Out/Report (2).pdf').existsSync(), isTrue);
      expect((await port().saveOut([out()], SaveOutTarget.files)).cancelled, isTrue);
      await expectLater(port().saveOut([out()], SaveOutTarget.photos), throwsA(isA<FileOutException>()));
      await expectLater(port().share([out()]), throwsA(isA<FileOutException>()));
      expect(port().capabilities.canShare, isFalse);
      expectLibraryUnchanged();
    });

    test('open in hands the default app a temporary copy, swept after a day', () async {
      final opened = <String>[];
      final p = port(opened: opened);
      expect(await p.openIn(out()), isTrue);
      expect(opened.single, isNot(library.path));
      expect(opened.single, startsWith('${dir.path}/danaview-out/'));
      expect(File(opened.single).readAsStringSync(), 'library bytes');
      expectLibraryUnchanged();
      p.sweep(age: Duration.zero);
      expect(File(opened.single).existsSync(), isFalse);
      await expectLater(p.openIn(OutFile(path: '${dir.path}/gone.pdf', displayName: 'gone.pdf')), throwsA(isA<FileOutException>()));
    });
  });
}
