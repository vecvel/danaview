// OWNER: ENG-01
//
// Error mapping (ARCH §12.5, §12.6, §19): every EngineErrorCode survives the Pigeon round trip as a
// typed EngineFailure, unknown codes become `internal`, `channel-error` (no native host API)
// becomes `notSupportedOnDevice`, and no PlatformException ever leaves the plugin.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine/src/error_mapper.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support/mock_engine_host.dart';

const _config = EditorEngineConfig(cacheRoot: '/c/danaview/editor', supportRoot: '/s/danaview/editor');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mapEngineError', () {
    test('every EngineErrorCode maps from a PlatformException with its details', () {
      for (final c in EngineErrorCode.values) {
        final f = mapEngineError(
          PlatformException(code: c.name, message: 'm', details: {'itemId': 'it_x', 'mediaFingerprint': 'fp', 'retryable': true}),
        );
        expect(f.code, c);
        expect(f.itemId, 'it_x');
        expect(f, c == EngineErrorCode.cancelled ? isA<EngineCancelled>() : isA<EngineError>());
        if (c != EngineErrorCode.cancelled) {
          expect(f.mediaFingerprint, 'fp');
          expect(f.retryable, isTrue);
        }
      }
    });

    test('unknown codes map to internal, keep the raw code and scrub paths', () {
      final f =
          mapEngineError(PlatformException(code: 'weird', message: 'failed to open /var/mobile/Containers/a/b.mp4 and file:///x/y.mov'));
      expect(f.code, EngineErrorCode.internal);
      expect(f.debugDetail, startsWith('weird: '));
      expect(f.debugDetail, isNot(contains('/var/mobile')));
      expect(f.debugDetail, isNot(contains('file://')));
      expect(mapEngineError(PlatformException(code: 'internal', message: 'x')).debugDetail, 'x');
    });

    test('content URIs are scrubbed too', () {
      final f = mapEngineError(PlatformException(code: 'io', message: 'cannot read content://media/external/video/42'));
      expect(f.code, EngineErrorCode.io);
      expect(f.debugDetail, 'cannot read <path>');
    });

    test('Pigeon channel-error (no native handler) is notSupportedOnDevice; null-error is internal', () {
      expect(mapEngineError(PlatformException(code: pigeonChannelErrorCode, message: 'Unable to establish connection')).code,
          EngineErrorCode.notSupportedOnDevice);
      expect(mapEngineError(PlatformException(code: pigeonNullErrorCode)).code, EngineErrorCode.internal);
    });

    test('a missing plugin is notSupportedOnDevice; other errors are internal', () {
      expect(mapEngineError(MissingPluginException()).code, EngineErrorCode.notSupportedOnDevice);
      expect(mapEngineError(StateError('boom')).code, EngineErrorCode.internal);
      expect(mapEngineError(const FormatException('bad')).code, EngineErrorCode.internal);
    });

    test('malformed details are ignored', () {
      final f = mapEngineError(PlatformException(code: 'decodeFailed', details: {'itemId': 3, 'retryable': 'yes'}));
      expect(f.code, EngineErrorCode.decodeFailed);
      expect(f.itemId, isNull);
      expect(f.retryable, isFalse);
      expect(mapEngineError(PlatformException(code: 'io', details: 'not a map')).code, EngineErrorCode.io);
    });

    test('EngineFailures pass through unchanged', () {
      const f = EngineError(EngineErrorCode.busy);
      expect(identical(mapEngineError(f), f), isTrue);
    });
  });

  test('failureFromMsg maps every code (cancelled → EngineCancelled) and scrubs paths', () {
    for (final c in EngineErrorCode.values) {
      final f = failureFromMsg(FailureMsg(code: c.name, message: 'at /tmp/a/b.mp4', itemId: 'it', mediaFingerprint: 'fp', retryable: true));
      expect(f.code, c);
      expect(f, c == EngineErrorCode.cancelled ? isA<EngineCancelled>() : isA<EngineError>());
      expect(f.debugDetail, isNot(contains('/tmp/a')));
    }
    expect(failureFromMsg(FailureMsg(code: 'nope', message: '', retryable: false)).code, EngineErrorCode.internal);
  });

  test('guardEngineCall rethrows typed failures', () async {
    await expectLater(guardEngineCall<void>(() async => throw PlatformException(code: 'diskFull')),
        throwsA(isA<EngineError>().having((f) => f.code, 'code', EngineErrorCode.diskFull)));
  });

  group('through the Pigeon channels', () {
    late MockEngineHost host;

    setUp(() => host = MockEngineHost()..acceptInitialize());
    tearDown(() => host.dispose());

    test('every EngineErrorCode sent as a native FlutterError arrives as that EngineFailure', () async {
      for (final c in EngineErrorCode.values) {
        host.fail('EngineHostApi', 'freeBytes', c.name, message: 'no space at /private/var/x', details: {'retryable': true});
        final engine = MobileEditorEngine(config: _config, events: () => const Stream.empty());
        Object? caught;
        try {
          await engine.freeBytes('/c/danaview/editor');
        } on Object catch (e) {
          caught = e;
        }
        expect(caught, isA<EngineFailure>().having((f) => f.code, 'code', c), reason: c.name);
        expect(caught, isNot(isA<PlatformException>()));
        expect((caught! as EngineFailure).debugDetail, isNot(contains('/private/var')));
      }
    });

    test('an unknown native code arrives as internal', () async {
      host.fail('EngineHostApi', 'probe', 'AVFoundationErrorDomain-11800');
      final engine = MobileEditorEngine(config: _config, events: () => const Stream.empty());
      await expectLater(
        engine.probe(const EngineMedia(uri: 'file:///m.mp4', fingerprint: 'fp')),
        throwsA(isA<EngineError>()
            .having((f) => f.code, 'code', EngineErrorCode.internal)
            .having((f) => f.debugDetail, 'debugDetail', contains('AVFoundationErrorDomain'))),
      );
    });

    test('a host API the native plugin did not register fails with notSupportedOnDevice', () async {
      final engine = MobileEditorEngine(config: _config, events: () => const Stream.empty());
      await expectLater(
          engine.freeBytes('/c'), throwsA(isA<EngineError>().having((f) => f.code, 'code', EngineErrorCode.notSupportedOnDevice)));
    });
  });
}
