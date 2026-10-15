// OWNER: INT-04
//
// ARCH §20.3: the privacy policy names the speech-model download host (`SpeechModelSpec.host`,
// huggingface.co) and its CDN host (hf.co), and the app opens no network connection before the
// user consents. The second test drives the REAL TranscriptionServiceImpl (built by main.dart's
// createAutoCaptions over a temp support folder, with a supported whisper runtime injected)
// through the app: player Edit -> editor -> Captions -> Auto captions -> Create captions -> the
// consent view, under an `HttpOverrides` spy that records every HttpClient. Nothing may be created
// or requested before "Download" (the only `UserConsent.accepted(` call site); the first request
// afterwards targets huggingface.co.

// The policy text model is not exported by danaview_features (UX-42's own test reads it the same way).
// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview/main.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/more/legal_texts.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

import 'editor_wiring_test.dart' as wiring;
import 'library_test_utils.dart';

Iterable<String> _allText(LegalDocumentText doc) sync* {
  yield doc.summary;
  for (final section in doc.sections) {
    yield section.heading;
    for (final block in section.blocks) {
      if (block.text != null) yield block.text!;
      for (final bullet in block.bullets ?? const <LegalBullet>[]) {
        if (bullet.lead != null) yield bullet.lead!;
        yield bullet.text;
      }
    }
  }
}

// -------------------------------------------------------------------------------------------------
// HttpOverrides spy
// -------------------------------------------------------------------------------------------------

/// Records every HttpClient the code under test creates and every request it opens. Requests fail
/// at once with a SocketException (nothing leaves the test).
final class _NetworkSpy extends HttpOverrides {
  int clients = 0;
  final List<Uri> requests = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    return _SpyClient(this);
  }
}

final class _SpyClient implements HttpClient {
  _SpyClient(this.spy);

  final _NetworkSpy spy;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final args = invocation.positionalArguments;
    if (args.isNotEmpty && args.last is Uri && !invocation.isSetter) {
      spy.requests.add(args.last as Uri);
      return Future<HttpClientRequest>.error(const SocketException('offline (test spy)'));
    }
    if (invocation.isMethod && args.length >= 3 && args[args.length - 2] is int) {
      // open(method, host, port, path) / get(host, port, path) and friends.
      spy.requests.add(Uri(scheme: 'https', host: '${args[args.length - 3]}', path: '${args.last}'));
      return Future<HttpClientRequest>.error(const SocketException('offline (test spy)'));
    }
    return null;
  }
}

// -------------------------------------------------------------------------------------------------
// A supported whisper runtime (the host has no native library); no model is ever loaded here.
// -------------------------------------------------------------------------------------------------

final class _SupportedRuntime implements WhisperRuntime {
  @override
  WhisperSupport get support => const WhisperSupported();

  @override
  String get engineVersion => '1.9.4';

  @override
  WhisperDeviceChannel get device => WhisperDeviceChannel(enabled: false);

  @override
  Future<WhisperModel> loadModel(String modelPath, {WhisperModelOptions options = const WhisperModelOptions(), WhisperCancelToken? cancel}) =>
      Future<WhisperModel>.error(const WhisperException(WhisperErrorKind.libraryUnavailable));

  @override
  Future<void> releaseIdleModels() async {}
}

/// Pumps frames while real I/O (the service's files) completes outside the fake clock.
Future<void> _settleIo(WidgetTester tester, {required bool Function() until, int rounds = 60}) async {
  for (var i = 0; i < rounds && !until(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('privacy policy (ARCH §20.3)', () {
    final policy = _allText(privacyPolicyText).join('\n');

    test('names the speech-model host of every catalog entry and its CDN host', () {
      final hosts = {for (final m in [...SpeechModelCatalog.models, SpeechModelCatalog.vad]) m.host};
      expect(hosts, {'huggingface.co'});
      for (final host in hosts) {
        expect(policy, contains(host));
      }
      expect(SpeechModelCatalog.cdnHost, 'hf.co');
      expect(policy, contains(SpeechModelCatalog.cdnHost));
    });

    test('the consent disclosure shows the same hosts the policy names', () {
      for (final spec in SpeechModelCatalog.models) {
        final d = ConsentDisclosure.of(spec, includesVad: true);
        expect(policy, contains(d.host));
        expect(policy, contains(d.cdnHost));
      }
    });
  });

  group('no network before consent (ARCH §20.3)', () {
    testWidgets('the real service through the Auto captions flow opens no HttpClient before Download; then huggingface.co',
        (tester) async {
      // Real time runs while the service does file I/O, so platform streams the player opens would
      // reach the (absent) plugins; answer the orientation stream here.
      tester.binding.defaultBinaryMessenger.setMockStreamHandler(
        const EventChannel('danaview/device_orientation'),
        MockStreamHandler.inline(onListen: (_, __) {}),
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockStreamHandler(const EventChannel('danaview/device_orientation'), null));
      final spy = _NetworkSpy();
      final previous = HttpOverrides.current;
      HttpOverrides.global = spy;
      final support = (await tester.runAsync(() => Directory.systemTemp.createTemp('dv_privacy_')))!;
      final engine = wiring.wiredEngine();
      final captions = createAutoCaptions(
        engine: engine,
        supportDirectory: support.path,
        channel: WhisperDeviceChannel(enabled: false),
        createService: ({required store, required extractor, required governor, required leases}) => TranscriptionServiceImpl(
          supportDirectory: support.path,
          store: store,
          extractor: extractor,
          governor: governor,
          leases: leases,
          openRuntime: () async => _SupportedRuntime(),
        ),
        downloaderConfig: ModelDownloaderConfig(appVersion: danaviewAppVersion, retryBackoff: const [], delay: (_) async {}),
      );
      wiring.WiredApp? app;
      try {
        await tester.runAsync(captions.service.initialize);
        app = await wiring.pumpWiredApp(tester, platform: TargetPlatform.iOS, engine: engine, transcription: captions.service);

        // Player -> Edit -> editor.
        await app.playVideo();
        await tester.tap(find.byKey(const ValueKey('player-edit-video')));
        await pumpFrames(tester, count: 20);
        expect(find.byType(EditorScreen), findsOneWidget);

        // Captions tool -> Auto captions -> Create captions.
        final tool = find.byKey(const ValueKey('tile.tool.captions'), skipOffstage: false);
        await tester.ensureVisible(tool);
        await tester.tap(tool);
        await pumpFrames(tester, count: 10);
        final open = find.text('Auto captions').last;
        await tester.ensureVisible(open);
        await tester.tap(open);
        await _settleIo(tester, until: () => find.byKey(const ValueKey('captions-create')).evaluate().isNotEmpty);
        final create = find.byKey(const ValueKey('captions-create'));
        expect(create, findsOneWidget);
        await tester.ensureVisible(create);
        await tester.pump();
        await tester.tap(create);
        await _settleIo(tester, until: () => find.byKey(const ValueKey('captions-consent')).evaluate().isNotEmpty);
        expect(find.byKey(const ValueKey('captions-consent')), findsOneWidget, reason: 'the flow reached the consent view');

        // Up to here: no HttpClient, no request.
        expect(spy.clients, 0, reason: 'an HttpClient was created before consent');
        expect(spy.requests, isEmpty, reason: 'a request was opened before consent: ${spy.requests}');

        // Download (the consent view builds UserConsent.accepted): the first request is the model on
        // huggingface.co.
        final accept = find.byKey(const ValueKey('captions-consent-accept'));
        await tester.ensureVisible(accept);
        await tester.pump();
        await tester.tap(accept);
        await _settleIo(tester, until: () => spy.requests.isNotEmpty);
        expect(spy.clients, greaterThan(0));
        expect(spy.requests, isNotEmpty);
        expect(spy.requests.first.host, SpeechModelCatalog.balanced.host);
        expect(spy.requests.first.host, 'huggingface.co');
        expect(spy.requests.first.scheme, 'https');
        expect(spy.requests.first.query, isEmpty, reason: 'no identifiers in the request');
        await _settleIo(tester, until: () => false, rounds: 10);
      } finally {
        await captions.service.cancelDownload();
        await app?.dispose();
        await tester.runAsync(() async {
          await captions.dispose();
          await support.delete(recursive: true);
        });
        HttpOverrides.global = previous;
      }
    });
  });
}
