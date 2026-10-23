// OWNER: HOM-04
//
// NativeThumbnails over a mock binary messenger (BUILD_PLAN HOM-04; ARCH v1.2 V2-28): every field
// of a request reaches the Pigeon message, the result maps back with the format actually written,
// platform errors map to LibraryNativeException codes (an unregistered host API is
// notSupportedOnDevice, as on Windows and Linux), out-of-range arguments are refused before the
// channel, and cancel / updateCaching are sent. toString never prints a path (rule 30).
// ignore_for_file: depend_on_referenced_packages

import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_library_native/src/pigeon/library_api.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _prefix = 'dev.flutter.pigeon.danaview_library_native.ThumbnailHostApi';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = ThumbnailHostApi.pigeonChannelCodec;

  void answer(String method, Object? Function(List<Object?> args) reply) {
    messenger.setMockMessageHandler('$_prefix.$method', (message) async {
      final args = (codec.decodeMessage(message) as List<Object?>?) ?? const [];
      final out = reply(args);
      if (out is PlatformException) return codec.encodeMessage(<Object?>[out.code, out.message, out.details]);
      return codec.encodeMessage(<Object?>[out]);
    });
  }

  tearDown(() {
    for (final m in ['mediaThumbnail', 'documentThumbnail', 'cancel', 'updateCaching']) {
      messenger.setMockMessageHandler('$_prefix.$m', null);
    }
  });

  test('mediaThumbnail sends every field and maps the result', () async {
    MediaThumbnailRequestMsg? sent;
    answer('mediaThumbnail', (args) {
      sent = args.single! as MediaThumbnailRequestMsg;
      return ThumbnailResultMsg(path: sent!.outputPath, widthPx: 384, heightPx: 288, format: ThumbnailFormatMsg.jpeg);
    });
    final r = await NativeThumbnails().mediaThumbnail(
      requestId: 'th-1',
      source: 'ph:ABC/L0/001',
      width: 384,
      height: 384,
      outputPath: '/cache/danaview/library/thumbs/m/a3/x/1.part',
      mode: NativeThumbnailMode.fit,
      format: NativeThumbnailFormat.heic,
      quality: 0.7,
    );
    expect(sent!.requestId, 'th-1');
    expect(sent!.source, 'ph:ABC/L0/001');
    expect([sent!.widthPx, sent!.heightPx], [384, 384]);
    expect(sent!.mode, ThumbnailModeMsg.fit);
    expect(sent!.format, ThumbnailFormatMsg.heic);
    expect(sent!.quality, 0.7);
    expect(sent!.outputPath, '/cache/danaview/library/thumbs/m/a3/x/1.part');
    expect(r.path, sent!.outputPath);
    expect([r.width, r.height], [384, 288]);
    expect(r.format, NativeThumbnailFormat.jpeg, reason: 'the platform reports what it wrote (HEIC before iOS 17 is JPEG)');
    expect(r.toString(), isNot(contains('/cache')));
  });

  test('documentThumbnail maps null and a result', () async {
    DocumentThumbnailRequestMsg? sent;
    answer('documentThumbnail', (args) {
      sent = args.single! as DocumentThumbnailRequestMsg;
      return sent!.path.endsWith('.pdf') ? ThumbnailResultMsg(path: sent!.outputPath, widthPx: 10, heightPx: 20, format: ThumbnailFormatMsg.webp) : null;
    });
    final t = NativeThumbnails();
    expect(await t.documentThumbnail(requestId: 'd', path: '/a.docx', width: 192, height: 192, outputPath: '/o'), isNull);
    final pdf = await t.documentThumbnail(requestId: 'd2', path: '/a.pdf', width: 192, height: 100, outputPath: '/o2', scale: 3, format: NativeThumbnailFormat.webp, quality: 0.5);
    expect(pdf!.format, NativeThumbnailFormat.webp);
    expect(sent!.scale, 3);
    expect(sent!.heightPx, 100);
    expect(sent!.quality, 0.5);
  });

  test('errors map to LibraryNativeException codes', () async {
    for (final code in ['cancelled', 'notFound', 'unavailableOffline', 'ioError', 'permissionDenied', 'busy', 'weird']) {
      answer('mediaThumbnail', (_) => PlatformException(code: code, message: 'x'));
      await expectLater(
        NativeThumbnails().mediaThumbnail(requestId: 'r', source: '/a.jpg', width: 10, height: 10, outputPath: '/o'),
        throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.fromCode(code))),
      );
    }
  });

  test('no native class (desktop) is notSupportedOnDevice', () async {
    await expectLater(
      NativeThumbnails().mediaThumbnail(requestId: 'r', source: '/a.jpg', width: 10, height: 10, outputPath: '/o'),
      throwsA(isA<LibraryNativeException>().having((e) => e.code, 'code', LibraryNativeErrorCode.notSupportedOnDevice)),
    );
    await expectLater(NativeThumbnails().cancel('r'), throwsA(isA<LibraryNativeException>()));
  });

  test('arguments are checked before the channel', () {
    final t = NativeThumbnails();
    expect(() => t.mediaThumbnail(requestId: 'r', source: '/a', width: 0, height: 10, outputPath: '/o'), throwsArgumentError);
    expect(() => t.mediaThumbnail(requestId: 'r', source: '/a', width: 10, height: 5000, outputPath: '/o'), throwsArgumentError);
    expect(() => t.mediaThumbnail(requestId: 'r', source: '/a', width: 10, height: 10, outputPath: '/o', quality: 2), throwsArgumentError);
    expect(() => t.mediaThumbnail(requestId: 'r', source: '', width: 10, height: 10, outputPath: '/o'), throwsArgumentError);
    expect(() => t.mediaThumbnail(requestId: 'r', source: '/a', width: 10, height: 10, outputPath: ''), throwsArgumentError);
    expect(() => t.documentThumbnail(requestId: 'r', path: '/a', width: 10, height: 10, outputPath: '/o', scale: 0), throwsArgumentError);
    expect(() => t.updateCaching(start: const [], stop: const [], width: 0, height: 1), throwsArgumentError);
  });

  test('cancel and updateCaching are sent', () async {
    String? cancelled;
    ThumbnailCachingMsg? window;
    answer('cancel', (args) {
      cancelled = args.single! as String;
      return null;
    });
    answer('updateCaching', (args) {
      window = args.single! as ThumbnailCachingMsg;
      return null;
    });
    final t = NativeThumbnails();
    await t.cancel('th-9');
    await t.updateCaching(start: const ['ph:A'], stop: const ['ph:B'], width: 192, height: 192, mode: NativeThumbnailMode.fill);
    expect(cancelled, 'th-9');
    expect(window!.startSources, ['ph:A']);
    expect(window!.stopSources, ['ph:B']);
    expect(window!.mode, ThumbnailModeMsg.fill);
    expect(window!.widthPx, 192);
  });

  test('formats carry their file extension and mirror the Pigeon enum', () {
    expect([for (final f in NativeThumbnailFormat.values) f.extension], ['jpg', 'heic', 'webp', 'png']);
    expect([for (final f in NativeThumbnailFormat.values) f.name], [for (final f in ThumbnailFormatMsg.values) f.name]);
    expect([for (final m in NativeThumbnailMode.values) m.name], [for (final m in ThumbnailModeMsg.values) m.name]);
  });
}
