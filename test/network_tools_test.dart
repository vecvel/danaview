import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'library_test_utils.dart';

/// The library surfaces plus the narrowest phone width.
final List<TestSurface> _surfaces = [
  ...librarySurfaces,
  for (final scale in [1.0, 1.35]) TestSurface(const Size(280, 653), scale, padding: const EdgeInsets.only(top: 20)),
];

TargetPlatform _platformFor(TestSurface surface) =>
    surface.size.width >= 1000 ? TargetPlatform.macOS : TargetPlatform.iOS;

/// Hands out a stream the test drives update by update.
class _FakeSpeedTest extends SpeedTestService {
  StreamController<SpeedTestUpdate>? controller;
  int runs = 0;
  bool cancelled = false;

  @override
  Stream<SpeedTestUpdate> run({NetworkCancelToken? cancel}) {
    runs++;
    cancelled = false;
    final controller = this.controller = StreamController<SpeedTestUpdate>(onCancel: () => cancelled = true);
    return controller.stream;
  }
}

class _FakeProbe extends StreamProbe {
  _FakeProbe(this.results);

  final Map<String, StreamProbeResult> results;
  final List<Uri> checked = [];

  /// When set, checks wait for it instead of answering at once.
  Completer<StreamProbeResult>? pending;

  @override
  Future<StreamProbeResult> check(Uri url, {NetworkCancelToken? cancel}) async {
    checked.add(url);
    final pending = this.pending;
    if (pending != null) return pending.future;
    return results[url.toString()] ?? (throw const StreamProbeException('No fake result'));
  }
}

const _fastResult = SpeedTestResult(
  downloadMbps: 312.46,
  uploadMbps: 41.2,
  latencyMs: 18.4,
  jitterMs: 2.1,
  bytesDownloaded: 104857600,
  bytesUploaded: 41943040,
  duration: Duration(seconds: 19),
  colo: 'FRA',
  city: 'Frankfurt am Main',
);

const _slowResult = SpeedTestResult(
  downloadMbps: 2.4,
  uploadMbps: 0.52,
  latencyMs: 240,
  jitterMs: 46,
  bytesDownloaded: 2400000,
  bytesUploaded: 520000,
  duration: Duration(seconds: 18),
);

/// Latency, download and upload updates that lead up to [result].
List<SpeedTestUpdate> _updates(SpeedTestResult result) => [
      const SpeedTestUpdate(phase: SpeedTestPhase.latency, progress: 0, phaseProgress: 0, elapsed: Duration.zero),
      SpeedTestUpdate(
        phase: SpeedTestPhase.latency,
        progress: 0.06,
        phaseProgress: 0.6,
        elapsed: const Duration(milliseconds: 400),
        latencyMs: result.latencyMs,
        jitterMs: result.jitterMs,
        colo: result.colo,
        city: result.city,
      ),
      for (final share in [0.2, 0.7, 1.0])
        SpeedTestUpdate(
          phase: SpeedTestPhase.download,
          progress: 0.1 + 0.45 * share,
          phaseProgress: share,
          elapsed: Duration(milliseconds: 1000 + (8000 * share).round()),
          currentMbps: result.downloadMbps * share * 1.1,
          latencyMs: result.latencyMs,
          jitterMs: result.jitterMs,
          downloadMbps: share == 1.0 ? result.downloadMbps : null,
          colo: result.colo,
          city: result.city,
        ),
      for (final share in [0.3, 1.0])
        SpeedTestUpdate(
          phase: SpeedTestPhase.upload,
          progress: 0.55 + 0.45 * share,
          phaseProgress: share,
          elapsed: Duration(milliseconds: 10000 + (8000 * share).round()),
          currentMbps: result.uploadMbps * share,
          latencyMs: result.latencyMs,
          jitterMs: result.jitterMs,
          downloadMbps: result.downloadMbps,
          uploadMbps: share == 1.0 ? result.uploadMbps : null,
          colo: result.colo,
          city: result.city,
        ),
      SpeedTestUpdate(
        phase: SpeedTestPhase.done,
        progress: 1,
        phaseProgress: 1,
        elapsed: result.duration,
        latencyMs: result.latencyMs,
        jitterMs: result.jitterMs,
        downloadMbps: result.downloadMbps,
        uploadMbps: result.uploadMbps,
        result: result,
      ),
    ];

const _hlsUrl =
    'https://streaming.example-video-host-with-a-very-long-domain-name.com/live/channel/extra/long/path/master.m3u8';
const _mp4Url = 'https://media.example.com/files/A Movie With A Very Long Title Indeed 2160p.mp4';
const _pageUrl = 'https://www.example.com/watch?v=abcdefghijk&list=PL1234567890&index=7';

final Map<String, StreamProbeResult> _probeResults = {
  Uri.parse(_hlsUrl).toString(): StreamProbeResult(
    requestedUrl: Uri.parse(_hlsUrl),
    finalUrl: Uri.parse('$_hlsUrl?token=0123456789abcdef0123456789abcdef0123456789abcdef&expires=1999999999'),
    redirects: [
      StreamRedirect(302, Uri.parse(_hlsUrl), Uri.parse('https://edge-cache-07.cdn.example.net/redirect/$_hlsUrl')),
      StreamRedirect(
        307,
        Uri.parse('https://edge-cache-07.cdn.example.net/redirect/$_hlsUrl'),
        Uri.parse('$_hlsUrl?token=0123456789abcdef0123456789abcdef0123456789abcdef&expires=1999999999'),
      ),
    ],
    statusCode: 200,
    reasonPhrase: 'OK',
    contentType: 'application/vnd.apple.mpegurl; charset=utf-8',
    contentLength: 2311,
    timeToFirstByte: const Duration(milliseconds: 4280),
    kind: StreamKind.hls,
    server: 'Some-Very-Long-Server-Software-Name/1.2.3 (Unix) mod_extremely_long_module_name/4.5.6',
    manifest: StreamManifestInfo(
      isMaster: true,
      variants: [
        for (final (h, w, bw) in [(360, 640, 800000), (2160, 3840, 25000000), (720, 1280, 2800000), (1080, 1920, 6000000)])
          StreamVariant(
            bandwidth: bw,
            width: w,
            height: h,
            codecs: 'avc1.640028,mp4a.40.2,ec-3,hvc1.2.4.L153.B0',
            frameRate: 29.97,
            uri: 'v$h/index.m3u8',
          ),
        const StreamVariant(bandwidth: 128000, codecs: 'mp4a.40.2'),
      ],
      isLive: true,
      duration: const Duration(seconds: 24),
      segmentCount: 6,
      audioTracks: 3,
      subtitleTracks: 12,
      encryption: 'AES-128',
    ),
    issues: const [
      StreamIssue(StreamIssueLevel.info, 'Segments are encrypted with AES-128, which Danaview supports.'),
      StreamIssue(StreamIssueLevel.info, 'Redirects from a secure https:// link to plain http://.'),
    ],
  ),
  Uri.parse(_mp4Url).toString(): StreamProbeResult(
    requestedUrl: Uri.parse(_mp4Url),
    finalUrl: Uri.parse(_mp4Url),
    statusCode: 200,
    reasonPhrase: 'OK',
    contentType: 'video/mp4',
    contentLength: 48318382080,
    seekable: false,
    timeToFirstByte: const Duration(milliseconds: 230),
    kind: StreamKind.video,
    container: 'MP4',
    issues: const [
      StreamIssue(StreamIssueLevel.warning, 'Server does not support seeking. You may not be able to skip ahead.'),
    ],
  ),
  Uri.parse(_pageUrl).toString(): StreamProbeResult(
    requestedUrl: Uri.parse(_pageUrl),
    finalUrl: Uri.parse(_pageUrl),
    statusCode: 200,
    reasonPhrase: 'OK',
    contentType: 'text/html; charset=utf-8',
    timeToFirstByte: const Duration(milliseconds: 90),
    kind: StreamKind.webPage,
    issues: const [
      StreamIssue(
        StreamIssueLevel.error,
        'This is a web page, not a video. Open it in a browser and copy the direct video link.',
      ),
    ],
  ),
};

Future<void> _scrollThrough(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 40; i++) {
    final position = tester.state<ScrollableState>(scrollable).position;
    if (position.pixels >= position.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  }
  await pumpFrames(tester, count: 3);
  expect(tester.takeException(), isNull);
}

Future<void> _scrollToTop(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
}

/// Scrolls the page until [finder] is on screen.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.pump();
}

Future<void> _finish(WidgetTester tester, LibraryTestEnv env) async {
  DanaviewToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await env.dispose();
}

Future<void> _runScript(WidgetTester tester, _FakeSpeedTest fake, List<SpeedTestUpdate> updates) async {
  for (final update in updates) {
    fake.controller!.add(update);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);
  }
  await fake.controller!.close();
  await pumpFrames(tester);
}

Future<void> _checkLink(WidgetTester tester, String url) async {
  await _scrollToTop(tester);
  await tester.enterText(find.byType(TextField), url);
  await tester.pump();
  await tester.tap(find.text('Check link'));
  await pumpFrames(tester, count: 3);
  expect(tester.takeException(), isNull);
}

void main() {
  group('speed test', () {
    for (final surface in _surfaces) {
      testWidgets('runs and explains a result without overflow at $surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        final fake = _FakeSpeedTest();
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewSpeedTestScreen(onBack: () {}),
          textScale: surface.textScale,
          platform: _platformFor(surface),
          overrides: [speedTestServiceProvider.overrideWithValue(fake)],
        ));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Start test'), findsOneWidget);
        expect(find.textContaining('of data'), findsOneWidget);
        await _scrollThrough(tester);

        await _scrollToTop(tester);
        await tester.ensureVisible(find.text('Start test'));
        await tester.pump();
        await tester.tap(find.text('Start test'));
        await tester.pump();
        expect(fake.runs, 1);
        expect(find.text('Stop'), findsOneWidget);
        await _runScript(tester, fake, _updates(_fastResult));

        expect(find.text('Test again'), findsOneWidget);
        expect(find.textContaining('Frankfurt am Main (FRA)'), findsOneWidget);
        await _reveal(tester, find.text('Great for 4K streaming'));
        expect(find.text('4K Ultra HD'), findsOneWidget);
        await _scrollThrough(tester);
        expect(find.text('Uploading videos'), findsOneWidget);
        await _finish(tester, env);
      });
    }

    testWidgets('a slow connection gets an honest verdict', (tester) async {
      useSurface(tester, const TestSurface(Size(320, 568), 1.35, padding: EdgeInsets.only(top: 20)));
      final env = await LibraryTestEnv.create();
      final fake = _FakeSpeedTest();
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewSpeedTestScreen(onBack: () {}),
        textScale: 1.35,
        overrides: [speedTestServiceProvider.overrideWithValue(fake)],
      ));
      await tester.tap(find.text('Start test'));
      await tester.pump();
      await _runScript(tester, fake, _updates(_slowResult));
      await _reveal(tester, find.text('Too slow for smooth streaming'));
      await _scrollThrough(tester);
      expect(find.textContaining('Unsteady connection'), findsOneWidget);
      expect(find.textContaining('Your video may look blurry'), findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('a failed test explains why and can be retried', (tester) async {
      useSurface(tester, _surfaces.first);
      final env = await LibraryTestEnv.create();
      final fake = _FakeSpeedTest();
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewSpeedTestScreen(onBack: () {}),
        overrides: [speedTestServiceProvider.overrideWithValue(fake)],
      ));
      await tester.tap(find.text('Start test'));
      await tester.pump();
      fake.controller!
        ..add(_updates(_fastResult)[1])
        ..addError(const SpeedTestException(
          SpeedTestErrorKind.offline,
          "Couldn't reach the test server. Check that you're connected to the internet.",
        ));
      await pumpFrames(tester);
      expect(tester.takeException(), isNull);
      expect(find.text("The test didn't finish"), findsOneWidget);
      expect(find.textContaining("Couldn't reach the test server"), findsOneWidget);
      await _scrollThrough(tester);

      await _scrollToTop(tester);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(fake.runs, 2);
      expect(find.text("The test didn't finish"), findsNothing);
      await _finish(tester, env);
    });

    testWidgets('Stop and leaving the page both cancel the running test', (tester) async {
      useSurface(tester, _surfaces[2]);
      final env = await LibraryTestEnv.create();
      final fake = _FakeSpeedTest();
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewSpeedTestScreen(onBack: () {}),
        overrides: [speedTestServiceProvider.overrideWithValue(fake)],
      ));
      await tester.tap(find.text('Start test'));
      await tester.pump();
      fake.controller!.add(_updates(_fastResult)[3]);
      await pumpFrames(tester);
      await tester.tap(find.text('Stop'));
      await pumpFrames(tester);
      expect(fake.cancelled, isTrue);
      expect(find.text('Test again'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Test again'));
      await tester.pump();
      expect(fake.cancelled, isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(fake.cancelled, isTrue);
      await env.dispose();
    });
  });

  group('stream link check', () {
    for (final surface in _surfaces) {
      testWidgets('shows each verdict without overflow at $surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        final probe = _FakeProbe(_probeResults);
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewStreamCheckScreen(onBack: () {}, onOpenPlayer: () {}),
          textScale: surface.textScale,
          platform: _platformFor(surface),
          overrides: [streamProbeProvider.overrideWithValue(probe)],
        ));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Check before you play'), findsOneWidget);

        await _checkLink(tester, _hlsUrl);
        expect(find.text('Playable'), findsOneWidget);
        expect(find.text('Play in Danaview'), findsOneWidget);
        await _reveal(tester, find.text('Quality levels (5)'));
        expect(find.text('2160p · 3840×2160'), findsOneWidget);
        await _scrollThrough(tester);
        expect(find.text('Redirects (2)'), findsOneWidget);

        await _checkLink(tester, _mp4Url);
        expect(find.text('Might not play'), findsOneWidget);
        expect(find.text('Play anyway'), findsOneWidget);
        await _scrollThrough(tester);
        expect(find.text('Not supported'), findsOneWidget);

        await _checkLink(tester, _pageUrl);
        expect(find.text('Not playable'), findsOneWidget);
        // A page's last path segment ("watch") means nothing, so the host names it.
        expect(find.text('www.example.com'), findsOneWidget);
        expect(find.text('Play in Danaview'), findsNothing);
        await _scrollThrough(tester);
        expect(find.textContaining('This is a web page, not a video'), findsOneWidget);
        // Seeking means nothing for a web page.
        expect(find.text('Seeking'), findsNothing);
        expect(probe.checked, hasLength(3));
        await _finish(tester, env);
      });
    }

    testWidgets('Play in Danaview queues the link and opens the player', (tester) async {
      useSurface(tester, _surfaces[2]);
      final env = await LibraryTestEnv.create();
      var opened = 0;
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewStreamCheckScreen(onBack: () {}, onOpenPlayer: () => opened++),
        overrides: [streamProbeProvider.overrideWithValue(_FakeProbe(_probeResults))],
      ));
      await tester.enterText(find.byType(TextField), _hlsUrl);
      // Submitting from the keyboard checks too.
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await pumpFrames(tester, count: 3);
      expect(find.text('Playable'), findsOneWidget);
      expect(find.text('master.m3u8'), findsOneWidget);
      // Full width on a phone, not capped a little short of the card's edge.
      final card = find.ancestor(of: find.text('Playable'), matching: find.byType(DanaviewSurface)).first;
      expect(
        tester.getSize(find.widgetWithText(DanaviewButton, 'Play in Danaview')).width,
        tester.getSize(card).width - 2 * DanaviewSpacing.lg,
      );
      await tester.tap(find.text('Play in Danaview'));
      await pumpFrames(tester);
      expect(opened, 1);
      final container = ProviderScope.containerOf(tester.element(find.byType(DanaviewStreamCheckScreen)));
      expect(container.read(queueControllerProvider).currentItem?.pathOrUri, Uri.parse(_hlsUrl).toString());
      await _finish(tester, env);
    });

    testWidgets('invalid links are explained without a request', (tester) async {
      useSurface(tester, _surfaces.first);
      final env = await LibraryTestEnv.create();
      final probe = _FakeProbe(_probeResults);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewStreamCheckScreen(onBack: () {}, onOpenPlayer: () {}),
        overrides: [streamProbeProvider.overrideWithValue(probe)],
      ));
      await tester.tap(find.text('Check link'));
      await tester.pump();
      expect(find.text('Paste or type a video link.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'rtsp://camera.local:554/stream1');
      await tester.pump();
      await tester.tap(find.text('Check link'));
      await pumpFrames(tester);
      expect(find.text("This kind of link can't be checked"), findsOneWidget);
      expect(find.text('Play in Danaview'), findsOneWidget);
      expect(probe.checked, isEmpty);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('an invalid link clears the previous result', (tester) async {
      useSurface(tester, _surfaces[2]);
      final env = await LibraryTestEnv.create();
      final probe = _FakeProbe(_probeResults);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewStreamCheckScreen(onBack: () {}, onOpenPlayer: () {}),
        overrides: [streamProbeProvider.overrideWithValue(probe)],
      ));
      await _checkLink(tester, _mp4Url);
      expect(find.text('Might not play'), findsOneWidget);

      await _checkLink(tester, 'not a link');
      expect(find.text('Might not play'), findsNothing);
      expect(find.text('Play anyway'), findsNothing);
      expect(find.text('Details'), findsNothing);
      expect(find.text('Check before you play'), findsOneWidget);
      expect(probe.checked, hasLength(1));
      await _finish(tester, env);
    });

    testWidgets('a server error shows its status without a seeking verdict', (tester) async {
      useSurface(tester, _surfaces.first);
      final env = await LibraryTestEnv.create();
      const url = 'https://media.example.com/missing.mp4';
      final probe = _FakeProbe({
        Uri.parse(url).toString(): StreamProbeResult(
          requestedUrl: Uri.parse(url),
          finalUrl: Uri.parse(url),
          statusCode: 404,
          reasonPhrase: 'Not Found',
          contentType: 'text/html',
          timeToFirstByte: const Duration(milliseconds: 1500),
          issues: const [StreamIssue(StreamIssueLevel.error, "The file wasn't found (HTTP 404).")],
        ),
      });
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewStreamCheckScreen(onBack: () {}, onOpenPlayer: () {}),
        textScale: 1.35,
        overrides: [streamProbeProvider.overrideWithValue(probe)],
      ));
      await _checkLink(tester, url);
      expect(find.text('Not playable'), findsOneWidget);
      expect(find.text('missing.mp4'), findsOneWidget);
      await _scrollThrough(tester);
      expect(find.text('404 Not Found'), findsOneWidget);
      expect(find.text('1.5\u00A0s'), findsOneWidget);
      expect(find.text('Seeking'), findsNothing);
      await _finish(tester, env);
    });

    testWidgets('shows progress while checking, and Cancel stops it', (tester) async {
      useSurface(tester, _surfaces.first);
      final env = await LibraryTestEnv.create();
      final probe = _FakeProbe(_probeResults)..pending = Completer<StreamProbeResult>();
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewStreamCheckScreen(onBack: () {}, onOpenPlayer: () {}),
        textScale: 1.35,
        overrides: [streamProbeProvider.overrideWithValue(probe)],
      ));
      await tester.enterText(find.byType(TextField), _mp4Url);
      await tester.tap(find.text('Check link'));
      await pumpFrames(tester, count: 2);
      expect(find.text('Checking…'), findsOneWidget);
      expect(find.byType(DanaviewSpinner), findsOneWidget);
      // The host gets a line of its own so it never breaks mid-word.
      expect(find.text('Contacting the server…'), findsOneWidget);
      expect(tester.widget<Text>(find.text('media.example.com')).maxLines, 1);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester, count: 2);
      expect(find.text('Check link'), findsOneWidget);
      expect(find.text('Check before you play'), findsOneWidget);
      probe.pending!.complete(_probeResults.values.first);
      await pumpFrames(tester, count: 2);
      expect(find.text('Playable'), findsNothing);
      await _finish(tester, env);
    });

    testWidgets('Paste fills the field from the clipboard', (tester) async {
      useSurface(tester, _surfaces.first);
      final env = await LibraryTestEnv.create();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': '  $_mp4Url  '};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewStreamCheckScreen(onBack: () {}, onOpenPlayer: () {}),
        overrides: [streamProbeProvider.overrideWithValue(_FakeProbe(_probeResults))],
      ));
      await tester.tap(find.text('Paste'));
      await pumpFrames(tester, count: 2);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, _mp4Url);
      await _finish(tester, env);
    });
  });
}

