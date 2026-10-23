// OWNER: HOM-26
//
// NativeQuickLook (danaview_library_native) and NativeQuickLookPort over a mock binary messenger
// (BUILD_PLAN HOM-26): every field of a file reaches the Pigeon message, canPreview's answer comes
// back, present completes when the platform replies (the preview was dismissed), platform errors
// map to LibraryNativeException codes (no registered host API, as on Android, Windows and Linux,
// is notSupportedOnDevice and the probe says "can not"), and bad arguments are refused before the
// channel. Nothing prints a name or a path (rule 30).

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
// ignore: implementation_imports
import 'package:danaview_library_native/src/pigeon/library_api.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _prefix = 'dev.flutter.pigeon.danaview_library_native.QuickLookHostApi';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = QuickLookHostApi.pigeonChannelCodec;

  void answer(String method, Object? Function(List<Object?> args) reply) {
    messenger.setMockMessageHandler('$_prefix.$method', (message) async {
      final args = (codec.decodeMessage(message) as List<Object?>?) ?? const [];
      final out = reply(args);
      if (out is PlatformException) return codec.encodeMessage(<Object?>[out.code, out.message, out.details]);
      return codec.encodeMessage(<Object?>[out]);
    });
  }

  tearDown(() {
    for (final m in ['canPreview', 'present']) {
      messenger.setMockMessageHandler('$_prefix.$m', null);
    }
  });

  const docx = NativeOutFile(
    path: '/lib/files/fe_x/blob',
    displayName: 'Report.docx',
    mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    uti: 'org.openxmlformats.wordprocessingml.document',
  );

  test('canPreview sends every field and returns the answer', () async {
    FileItemMsg? sent;
    answer('canPreview', (args) {
      sent = args.single! as FileItemMsg;
      return true;
    });
    expect(await NativeQuickLook().canPreview(docx), isTrue);
    expect(sent!.path, docx.path);
    expect(sent!.displayName, 'Report.docx');
    expect(sent!.mimeType, docx.mimeType);
    expect(sent!.uti, docx.uti);
    answer('canPreview', (_) => false);
    expect(await NativeQuickLook().canPreview(docx), isFalse);
  });

  test('present sends the items and index and completes when the platform replies', () async {
    QuickLookRequestMsg? sent;
    answer('present', (args) {
      sent = args.single! as QuickLookRequestMsg;
      return null;
    });
    const txt = NativeOutFile(path: '/lib/files/fe_y/blob', displayName: 'notes.txt');
    await NativeQuickLook().present([docx, txt], initialIndex: 1);
    expect(sent!.items.map((i) => i.displayName), ['Report.docx', 'notes.txt']);
    expect(sent!.initialIndex, 1);
  });

  test('platform errors become LibraryNativeException codes', () async {
    answer('present', (_) => PlatformException(code: 'busy', message: 'a preview is open'));
    await expectLater(
      NativeQuickLook().present([docx]),
      throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.busy)),
    );
    answer('canPreview', (_) => PlatformException(code: 'notFound', message: 'no such file'));
    await expectLater(
      NativeQuickLook().canPreview(docx),
      throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.notFound)),
    );
  });

  test('without a host API (Android, Windows, Linux) it is notSupportedOnDevice and the probe says no', () async {
    await expectLater(
      NativeQuickLook().canPreview(docx),
      throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.notSupportedOnDevice)),
    );
    final file = ViewerFile(path: docx.path, displayName: docx.displayName, kind: FileKind.document);
    expect(await quickLookProbe(NativeQuickLookPort())(file), isFalse);
  });

  test('the port maps viewer files and passes the answer through', () async {
    FileItemMsg? sent;
    answer('canPreview', (args) {
      sent = args.single! as FileItemMsg;
      return true;
    });
    answer('present', (_) => null);
    final file = ViewerFile(path: docx.path, displayName: 'Report.docx', kind: FileKind.document, mime: docx.mimeType, uti: docx.uti);
    final port = NativeQuickLookPort();
    expect(await quickLookProbe(port)(file), isTrue);
    expect([sent!.path, sent!.displayName, sent!.mimeType, sent!.uti], [docx.path, 'Report.docx', docx.mimeType, docx.uti]);
    await port.present([file]);
  });

  test('bad arguments are refused before the channel; nothing prints a path', () {
    final ql = NativeQuickLook();
    expect(() => ql.present(const []), throwsArgumentError);
    expect(() => ql.present([docx], initialIndex: 1), throwsRangeError);
    expect(() => ql.present([docx], initialIndex: -1), throwsRangeError);
    expect(() => ql.canPreview(const NativeOutFile(path: '', displayName: 'a.txt')), throwsArgumentError);
    expect(() => ql.canPreview(const NativeOutFile(path: '/a', displayName: '')), throwsArgumentError);
    expect(docx.toString(), isNot(contains('/lib')));
    expect(docx.toString(), isNot(contains('Report')));
  });
}
