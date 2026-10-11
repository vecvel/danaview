import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

const String _longTitle =
    'An Extraordinarily Long Episode Title That Keeps Going Well Past Any Reasonable Width '
    'S01E01 - The Beginning of Everything (Director\'s Cut, Remastered 4K HDR).mkv';

class _Surface {
  const _Surface(this.name, this.size, {this.padding = EdgeInsets.zero});

  final String name;
  final Size size;
  final EdgeInsets padding;
}

const List<_Surface> _touchSurfaces = [
  _Surface('280x560', Size(280, 560), padding: EdgeInsets.only(top: 20)),
  _Surface('320x568', Size(320, 568), padding: EdgeInsets.only(top: 20)),
  _Surface('375x667', Size(375, 667), padding: EdgeInsets.only(top: 20)),
  _Surface('402x874', Size(402, 874), padding: EdgeInsets.only(top: 62, bottom: 34)),
  _Surface('874x402 landscape', Size(874, 402), padding: EdgeInsets.fromLTRB(59, 0, 59, 21)),
  _Surface('1280x800', Size(1280, 800)),
];

const List<_Surface> _desktopSurfaces = [
  _Surface('desktop 1280x800', Size(1280, 800)),
  _Surface('desktop 600x400', Size(600, 400)),
  _Surface('desktop 480x320', Size(480, 320)),
];

class _Harness {
  _Harness(this.engine, this.libraryRepo, this.backCalls);

  final FakePlaybackEngine engine;
  final LibraryRepository libraryRepo;
  final List<int> backCalls;
}

Future<_Harness> _pumpPlayer(WidgetTester tester, _Surface surface, double textScale) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final libraryRepo = LibraryRepository(prefs);
  final engine = FakePlaybackEngine();
  await engine.initialize();
  final backCalls = <int>[];

  tester.view.physicalSize = surface.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        sessionRepositoryProvider.overrideWithValue(SessionRepository(prefs)),
        libraryRepositoryProvider.overrideWithValue(libraryRepo),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: DanaviewTheme.darkTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: surface.padding,
            viewPadding: surface.padding,
          ),
          child: child!,
        ),
        home: DanaviewPlayerScreen(onBack: () => backCalls.add(1)),
      ),
    ),
  );
  await _settle(tester);
  return _Harness(engine, libraryRepo, backCalls);
}

/// Advances time in small steps; never pumpAndSettle (the spinner animates forever).
Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(tester.takeException(), isNull);
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DanaviewPlayerScreen)));

Rect _safeRect(_Surface surface) => Rect.fromLTRB(
      surface.padding.left,
      surface.padding.top,
      surface.size.width - surface.padding.right,
      surface.size.height - surface.padding.bottom,
    );

void _expectWithin(WidgetTester tester, Finder finder, Rect bounds) {
  final rect = tester.getRect(finder);
  final inside = rect.left >= bounds.left - 0.5 &&
      rect.top >= bounds.top - 0.5 &&
      rect.right <= bounds.right + 0.5 &&
      rect.bottom <= bounds.bottom + 0.5;
  expect(inside, isTrue, reason: '$rect is not within $bounds');
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _settle(tester, frames: 3);
  await tester.tap(finder);
}

Finder _inPanel(Type panel, Finder matching) => find.descendant(of: find.byType(panel), matching: matching);

/// Product of every fade between [finder] and the root; 0 when an ancestor is offstage.
double _effectiveOpacity(WidgetTester tester, Finder finder) {
  var opacity = 1.0;
  tester.element(finder).visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is Opacity) opacity *= widget.opacity;
    if (widget is FadeTransition) opacity *= widget.opacity.value;
    if (widget is Offstage && widget.offstage) opacity = 0;
    if (widget is Visibility && !widget.visible) opacity = 0;
    return true;
  });
  return opacity;
}

/// What the controls sit on at global [y] when the video frame behind them is pure white.
Color _backdropOverWhite(WidgetTester tester, double y) {
  final scrim = find.descendant(
    of: find.byType(DanaviewControlsOverlay),
    matching: find.byWidgetPredicate(
      (w) => w is DecoratedBox && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).gradient != null,
    ),
  );
  final rect = tester.getRect(scrim.first);
  final gradient = (tester.widget<DecoratedBox>(scrim.first).decoration as BoxDecoration).gradient! as LinearGradient;
  final t = ((y - rect.top) / rect.height).clamp(0.0, 1.0);
  final stops = gradient.stops!;
  var color = gradient.colors.last;
  for (var i = 0; i < stops.length - 1; i++) {
    if (t >= stops[i] && t <= stops[i + 1]) {
      final span = stops[i + 1] - stops[i];
      color = Color.lerp(gradient.colors[i], gradient.colors[i + 1], span == 0 ? 0 : (t - stops[i]) / span)!;
      break;
    }
  }
  return Color.alphaBlend(color, Colors.white);
}

double _worstContrast(WidgetTester tester, Color foreground, Rect rect) => [rect.top, rect.center.dy, rect.bottom]
    .map((y) => DanaviewColors.contrastRatio(foreground, _backdropOverWhite(tester, y)))
    .reduce((a, b) => a < b ? a : b);

PlayerSnapshot _endedSnapshot(Duration position) => PlayerSnapshot(
      status: PlaybackStatus.ended,
      position: position,
      duration: const Duration(minutes: 10),
    );

List<MediaRef> _queueItems(int count) => [
      for (var i = 0; i < count; i++)
        MediaRef(id: '/videos/$i.mkv', title: '${i + 1}. $_longTitle', pathOrUri: '/videos/$i.mkv'),
    ];

/// Many long tracks, hours-long duration, boosted volume and an off-list speed.
PlayerSnapshot _stressSnapshot() => const PlayerSnapshot(
      status: PlaybackStatus.paused,
      position: Duration(hours: 1, minutes: 2, seconds: 3),
      duration: Duration(hours: 2, minutes: 15),
      cacheEnd: Duration(hours: 1, minutes: 10),
      speed: 1.1,
      volume: 250,
      tracks: TrackSelection(
        audioTracks: [
          MediaTrack(id: '1', type: TrackType.audio, title: 'English 5.1 Dolby Digital Plus Atmos Commentary Track'),
          MediaTrack(id: '2', type: TrackType.audio, title: 'Japanese 2.0 Original Theatrical Mix'),
          MediaTrack(id: '3', type: TrackType.audio, language: 'fre'),
        ],
        subtitleTracks: [
          MediaTrack(id: '1', type: TrackType.subtitle, title: 'English SDH (Signs and Songs, Full Dialogue)'),
          MediaTrack(id: '2', type: TrackType.subtitle, title: 'Español Latinoamericano Forzados'),
        ],
        selectedAudioTrackId: '1',
        selectedSubtitleTrackId: '2',
      ),
      chapters: [
        Chapter(id: 1, title: 'Opening', start: Duration.zero, end: Duration(minutes: 30)),
        Chapter(id: 2, title: 'Middle', start: Duration(minutes: 30), end: Duration(hours: 2, minutes: 15)),
      ],
      abLoop: AbLoop(a: Duration(minutes: 10), b: Duration(minutes: 20)),
    );

Future<void> _openSettingsCategories(WidgetTester tester, _Surface surface) async {
  const categories = ['Video', 'Color', 'Audio & Equalizer', 'Subtitles', 'Playback', 'Keyboard Shortcuts'];
  for (final category in categories) {
    final tile = _inPanel(DanaviewSettingsPanel, find.text(category));
    await tester.ensureVisible(tile);
    await _settle(tester, frames: 2);
    await tester.tap(tile);
    await _settle(tester, frames: 4);
    _expectWithin(tester, find.byType(DanaviewSettingsPanel), _safeRect(surface));
    await tester.tap(_inPanel(DanaviewSettingsPanel, find.byIcon(Icons.arrow_back_ios_new_rounded)));
    await _settle(tester, frames: 4);
  }
}

Future<void> _runFullFlow(WidgetTester tester, _Surface surface, double textScale, {required bool touch}) async {
  final harness = await _pumpPlayer(tester, surface, textScale);
  final engine = harness.engine;

  expect(find.text('No Media Loaded'), findsOneWidget);
  expect(find.text('Open file'), findsOneWidget);
  // The same icon as Home's Open file action; the open-folder glyph is kept for folders.
  expect(find.widgetWithIcon(DanaviewButton, Icons.video_file_rounded), findsOneWidget);
  expect(find.byType(DanaviewSeekBar), findsNothing);

  final container = _container(tester);
  final playerCtrl = container.read(playerControllerProvider.notifier);
  if (touch) {
    // Phones have no desktop title bar; fullscreen hides it on the macOS test host as well.
    playerCtrl.toggleFullscreen();
  }
  container.read(queueControllerProvider.notifier).playFrom(_queueItems(30));
  await _settle(tester);
  expect(find.text('No Media Loaded'), findsNothing);
  expect(find.byType(DanaviewSeekBar), findsOneWidget);
  expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  if (touch) expect(find.text('1. $_longTitle'), findsOneWidget);

  engine.emitMockSnapshot(_stressSnapshot());
  await _settle(tester);
  expect(find.byType(DanaviewControlsOverlay), findsOneWidget);
  expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);

  final more = find.byIcon(Icons.more_horiz_rounded);
  if (more.evaluate().isNotEmpty) {
    await tester.tap(more);
    await _settle(tester);
    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('Volume'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').last);
    await _settle(tester);
    expect(find.text('Volume'), findsNothing);
  } else {
    expect(find.byType(DanaviewVolumeSlider), findsOneWidget);
  }

  final settingsButton = find.byIcon(Icons.settings_rounded);
  if (settingsButton.evaluate().isNotEmpty) {
    await tester.tap(settingsButton);
  } else {
    await tester.tap(more);
    await _settle(tester);
    await _tapVisible(tester, find.text('Settings'));
  }
  await _settle(tester);
  expect(find.byType(DanaviewSettingsPanel), findsOneWidget);
  _expectWithin(tester, find.byType(DanaviewSettingsPanel), _safeRect(surface));
  await _openSettingsCategories(tester, surface);
  await tester.tap(_inPanel(DanaviewSettingsPanel, find.byTooltip('Close')));
  await _settle(tester);
  expect(find.byType(DanaviewSettingsPanel), findsNothing);

  final queueButton = find.byIcon(Icons.playlist_play_rounded);
  if (queueButton.evaluate().isNotEmpty) {
    await tester.tap(queueButton);
  } else {
    await tester.tap(more);
    await _settle(tester);
    await _tapVisible(tester, find.text('Queue'));
  }
  await _settle(tester);
  expect(find.byType(DanaviewQueueSheet), findsOneWidget);
  _expectWithin(tester, find.byType(DanaviewQueueSheet), _safeRect(surface));
  await tester.drag(_inPanel(DanaviewQueueSheet, find.byType(Scrollable)).first, const Offset(0, -400));
  await _settle(tester);
  await tester.tap(_inPanel(DanaviewQueueSheet, find.byTooltip('Close')));
  await _settle(tester);

  await tester.tap(find.byIcon(Icons.info_outline_rounded));
  await _settle(tester);
  expect(find.text('Stats for Nerds'), findsOneWidget);
  _expectWithin(tester, find.byType(DanaviewSurface).last, _safeRect(surface));
  await tester.tap(_inPanel(DanaviewDiagnosticsOverlay, find.byIcon(Icons.close_rounded)));
  await _settle(tester);
  expect(find.text('Stats for Nerds'), findsNothing);

  await tester.tap(find.byIcon(Icons.lock_open_rounded));
  await _settle(tester);
  expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
  expect(find.byType(DanaviewSeekBar), findsNothing);
  expect(find.descendant(of: find.byType(DanaviewControlsOverlay), matching: find.byType(Text)), findsNothing);
  expect(find.bySemanticsLabel('Unlock controls'), findsOneWidget);
  _expectWithin(tester, find.byIcon(Icons.lock_rounded), _safeRect(surface));
  await tester.tap(find.byIcon(Icons.lock_rounded));
  await _settle(tester);
  expect(find.byType(DanaviewSeekBar), findsOneWidget);

  playerCtrl.play();
  await _settle(tester, frames: 2);
  expect(container.read(playerControllerProvider).isPlaying, isTrue);
  await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
  await _settle(tester, frames: 2);
  expect(harness.backCalls, hasLength(1));
  expect(container.read(playerControllerProvider).status, PlaybackStatus.paused);

  await engine.dispose();
}

void main() {
  for (final textScale in const [1.0, 1.35]) {
    for (final surface in _touchSurfaces) {
      testWidgets('touch ${surface.name} @${textScale}x: every player surface fits', (tester) async {
        await _runFullFlow(tester, surface, textScale, touch: true);
      });
    }
    for (final surface in _desktopSurfaces) {
      testWidgets('${surface.name} @${textScale}x: every player surface fits', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          await _runFullFlow(tester, surface, textScale, touch: false);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  testWidgets('wide layout keeps the volume slider, fullscreen and every control inline', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final harness = await _pumpPlayer(tester, const _Surface('wide', Size(1280, 800)), 1.0);
      _container(tester).read(queueControllerProvider.notifier).playFrom(_queueItems(3));
      await _settle(tester);
      expect(find.byType(DanaviewVolumeSlider), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
      expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
      expect(find.byIcon(Icons.screen_rotation_rounded), findsNothing);
      await harness.engine.dispose();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('queue empty state offers Add videos', (tester) async {
    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.35);
    final container = _container(tester);
    harness.engine.open(MediaSource.file('/videos/a.mkv', title: 'a.mkv'));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await _settle(tester);
    await _tapVisible(tester, find.text('Queue'));
    await _settle(tester);
    expect(container.read(queueControllerProvider).items, isEmpty);
    expect(find.text('Queue is empty'), findsOneWidget);
    expect(find.text('Add videos'), findsOneWidget);
    await harness.engine.dispose();
  });

  testWidgets('a playback error shows one toast with a readable message', (tester) async {
    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.0);
    const message = "Couldn't find this video. It may have been moved or deleted.";
    harness.engine.emitMockError(const FileNotFound('/videos/missing.mkv'));
    await _settle(tester);
    expect(find.text(message), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);
    expect(find.text(message), findsNothing);

    _container(tester).read(playerControllerProvider.notifier).setVolume(40);
    await _settle(tester);
    expect(find.text(message), findsNothing);
    await harness.engine.dispose();
  });

  testWidgets('disposing the player screen pauses playback', (tester) async {
    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.0);
    final container = _container(tester);
    harness.engine.open(MediaSource.file('/videos/a.mkv', title: 'a.mkv'));
    await _settle(tester);
    expect(container.read(playerControllerProvider).isPlaying, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester, frames: 2);
    expect(harness.engine.currentSnapshot.status, PlaybackStatus.paused);
    await harness.engine.dispose();
  });

  testWidgets('a missing audio device shows one calm notice per session, never a playback error', (tester) async {
    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.0);
    final container = _container(tester);
    container.read(queueControllerProvider.notifier).playFrom(_queueItems(2));
    await _settle(tester);
    const notice = 'No audio output available';
    const failure = "Couldn't play this video.";
    final noAudio = classifyMpvError('Could not open/initialize audio device -> no sound.');

    harness.engine.emitMockError(noAudio);
    await _settle(tester);
    expect(find.text(notice), findsOneWidget);
    expect(find.text(failure), findsNothing);
    final toast = find.ancestor(of: find.text(notice), matching: find.byType(DanaviewSurface)).first;
    expect(find.descendant(of: toast, matching: find.byIcon(Icons.info_rounded)), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);

    harness.engine.emitMockError(noAudio);
    harness.engine.emitMockError(classifyMpvError('Error while decoding frame!'));
    await _settle(tester);
    container.read(queueControllerProvider.notifier).next();
    await _settle(tester);
    harness.engine.emitMockError(noAudio);
    await _settle(tester);
    expect(find.text(notice), findsNothing);
    expect(find.text(failure), findsNothing);
    await harness.engine.dispose();
  });

  for (final surface in [_touchSurfaces[3], _touchSurfaces[4]]) {
    for (final textScale in const [1.0, 1.35]) {
      testWidgets('${surface.name} @${textScale}x: player toasts sit above the control bar', (tester) async {
        final harness = await _pumpPlayer(tester, surface, textScale);
        harness.engine.open(MediaSource.file('/videos/a.mkv', title: 'a.mkv'));
        await _settle(tester);
        const message = "Couldn't find this video. It may have been moved or deleted.";
        harness.engine.emitMockError(const FileNotFound('/videos/missing.mkv'));
        await _settle(tester);
        final toast = find.ancestor(of: find.text(message), matching: find.byType(DanaviewSurface)).first;
        final controlsTop = tester.getRect(find.byType(DanaviewSeekBar)).top;
        expect(tester.getRect(toast).bottom, lessThanOrEqualTo(controlsTop));
        DanaviewToast.dismiss();
        await harness.engine.dispose();
      });
    }
  }

  testWidgets('an unclassified error mid-playback is not shown as a playback failure', (tester) async {
    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.0);
    const failure = "Couldn't play this video.";
    harness.engine.emitMockError(const GenericPlayerError('Failed to open the file'));
    await _settle(tester);
    expect(find.text(failure), findsOneWidget);
    DanaviewToast.dismiss();
    await _settle(tester);

    harness.engine.open(MediaSource.file('/videos/a.mkv', title: 'a.mkv'));
    await _settle(tester);
    harness.engine.emitMockError(const GenericPlayerError('Failed to initialize a decoder for codec eac3'));
    await _settle(tester);
    expect(find.text(failure), findsNothing);
    await harness.engine.dispose();
  });

  for (final textScale in const [1.0, 1.35]) {
    testWidgets('landscape @${textScale}x: a toast never covers the centre play button', (tester) async {
      final harness = await _pumpPlayer(tester, _touchSurfaces[4], textScale);
      harness.engine.open(MediaSource.file('/videos/a.mkv', title: 'a.mkv'));
      await _settle(tester);
      await harness.engine.pause();
      await _settle(tester);
      const message = "Couldn't find this video. It may have been moved or deleted.";
      harness.engine.emitMockError(const FileNotFound('/videos/missing.mkv'));
      await _settle(tester);
      final toast = tester.getRect(find.ancestor(of: find.text(message), matching: find.byType(DanaviewSurface)).first);
      final centre = tester.getRect(find.byWidgetPredicate((w) => w is DanaviewIconButton && w.size == 64));
      expect(toast.overlaps(centre), isFalse, reason: 'toast $toast vs centre button $centre');
      DanaviewToast.dismiss();
      await harness.engine.dispose();
    });
  }

  testWidgets('rotate toggles on every tap and leaving the player returns to portrait', (tester) async {
    final calls = <List<String>>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        calls.add(List<String>.from(call.arguments as List));
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    const landscape = ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'];
    const portrait = ['DeviceOrientation.portraitUp'];

    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.0);
    harness.engine.open(MediaSource.file('/videos/a.mkv', title: 'a.mkv'));
    await _settle(tester);
    expect(calls, [isEmpty]);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('Rotate screen'));
      await _settle(tester, frames: 2);
    }
    expect(calls.skip(1), [landscape, portrait, landscape]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(calls.last, portrait);
    await harness.engine.dispose();
  });

  testWidgets('Back turns the phone upright at once instead of when the route is disposed', (tester) async {
    final calls = <List<String>>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') calls.add(List<String>.from(call.arguments as List));
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    const portrait = ['DeviceOrientation.portraitUp'];

    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.0);
    harness.engine.open(MediaSource.file('/videos/a.mkv', title: 'a.mkv'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Rotate screen'));
    await _settle(tester, frames: 2);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    expect(harness.backCalls, [1]);
    expect(calls.last, portrait);
    final count = calls.length;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(calls, hasLength(count), reason: 'the disposed player was already released');
    await harness.engine.dispose();
  });

  testWidgets('the unlock button fades away after locking and any tap brings it back', (tester) async {
    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.0);
    harness.engine.open(MediaSource.file('/videos/a.mkv', title: 'a.mkv'));
    await _settle(tester);
    final lockedIcon = find.byIcon(Icons.lock_rounded);

    await tester.tap(find.byTooltip('Lock controls'));
    await tester.pump();
    expect(_effectiveOpacity(tester, lockedIcon), 1.0);
    await tester.pump(const Duration(seconds: 2));
    expect(_effectiveOpacity(tester, lockedIcon), 1.0);
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    expect(_effectiveOpacity(tester, lockedIcon), 0.0);

    // A tap where the hidden button sits only reveals it; it never unlocks by accident.
    await tester.tapAt(tester.getCenter(lockedIcon));
    await _settle(tester);
    expect(lockedIcon, findsOneWidget);
    expect(_effectiveOpacity(tester, lockedIcon), 1.0);
    // Taps elsewhere reveal it too, and it fades again on its own.
    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);
    expect(_effectiveOpacity(tester, lockedIcon), 0.0);
    await tester.tapAt(const Offset(60, 300));
    await _settle(tester);
    expect(_effectiveOpacity(tester, lockedIcon), 1.0);

    await tester.tap(lockedIcon);
    await _settle(tester);
    expect(lockedIcon, findsNothing);

    // Let the auto-hide start, then lock while the controls are fading out.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 100));
    final lockButton = find.widgetWithIcon(DanaviewIconButton, Icons.lock_open_rounded);
    expect(_effectiveOpacity(tester, lockButton), inExclusiveRange(0.0, 1.0));
    tester.widget<DanaviewIconButton>(lockButton).onPressed!();
    await tester.pump();
    expect(_effectiveOpacity(tester, lockedIcon), 1.0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_effectiveOpacity(tester, lockedIcon), 1.0);
    await harness.engine.dispose();
  });

  testWidgets('double-tapping the left or right of the video seeks by the chosen step', (tester) async {
    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.0);
    final engine = harness.engine;
    engine.open(MediaSource.file('/videos/a.mkv', title: 'a.mkv'));
    await _settle(tester);
    await engine.pause();
    await engine.seek(const Duration(minutes: 1));
    await _settle(tester);
    const left = Offset(402 * 0.15, 874 * 0.45);
    const right = Offset(402 * 0.85, 874 * 0.45);
    Duration position() => engine.currentSnapshot.position;

    Future<void> doubleTapAt(Offset at) async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at);
      await tester.pump();
    }

    await doubleTapAt(right);
    expect(position(), const Duration(minutes: 1, seconds: 10));
    expect(find.text('10s'), findsOneWidget);

    // Further taps on the same side keep seeking while the bubble is up, and add up.
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 400));
    expect(position(), const Duration(minutes: 1, seconds: 20));
    expect(find.text('20s'), findsOneWidget);
    await _settle(tester, frames: 12);
    expect(_effectiveOpacity(tester, find.text('20s')), 0.0);

    await doubleTapAt(left);
    expect(position(), const Duration(minutes: 1, seconds: 10));
    await _settle(tester, frames: 12);

    _container(tester).read(doubleTapSeekProvider.notifier).set(30);
    await doubleTapAt(right);
    expect(position(), const Duration(minutes: 1, seconds: 40));
    expect(find.text('30s'), findsOneWidget);
    await _settle(tester, frames: 12);

    // The middle still toggles playback.
    expect(engine.currentSnapshot.status, PlaybackStatus.paused);
    await doubleTapAt(const Offset(201, 874 * 0.3));
    await _settle(tester);
    expect(engine.currentSnapshot.status, PlaybackStatus.playing);
    await engine.dispose();
  });

  testWidgets('the double-tap seek step is chosen in Playback settings and remembered', (tester) async {
    // At 1.0x the phone bar has room for the settings button (larger text moves it into More).
    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.0);
    harness.engine.open(MediaSource.file('/videos/a.mkv', title: 'a.mkv'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Settings'));
    await _settle(tester);
    await tester.tap(_inPanel(DanaviewSettingsPanel, find.text('Playback')));
    await _settle(tester);
    expect(_inPanel(DanaviewSettingsPanel, find.text('Double-tap to seek')), findsOneWidget);
    await tester.tap(_inPanel(DanaviewSettingsPanel, find.text('15s')));
    await _settle(tester);
    final container = _container(tester);
    expect(container.read(doubleTapSeekProvider), 15);
    expect(container.read(sessionRepositoryProvider).getDoubleTapSeekSeconds(), 15);
    await harness.engine.dispose();
  });

  testWidgets('on iPhone the player follows how the phone is held, one orientation at a time', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final calls = <List<String>>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') calls.add(List<String>.from(call.arguments as List));
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    MockStreamHandlerEventSink? device;
    var listening = false;
    const channel = EventChannel('danaview/device_orientation');
    messenger.setMockStreamHandler(
      channel,
      MockStreamHandler.inline(
        onListen: (_, sink) {
          device = sink;
          listening = true;
        },
        onCancel: (_) => listening = false,
      ),
    );
    addTearDown(() => messenger.setMockStreamHandler(channel, null));
    Future<void> hold(String orientation) async {
      device!.success(orientation);
      await tester.pump();
    }

    final player = Object();
    await PlayerOrientation.enter(player);
    await tester.pump();
    // Opening never hands iOS several orientations at once, so nothing flashes.
    expect(calls, isEmpty);
    expect(listening, isTrue);

    await hold('portraitUp');
    await hold('landscapeRight');
    await hold('portraitDown');
    expect(calls, [
      ['DeviceOrientation.portraitUp'],
      ['DeviceOrientation.landscapeRight'],
    ]);

    // The rotate button pins its choice until the phone is turned to match.
    await hold('portraitUp');
    await PlayerOrientation.toggle(Orientation.portrait);
    expect(calls.last, ['DeviceOrientation.landscapeLeft']);
    final pinned = calls.length;
    await hold('portraitUp');
    expect(calls, hasLength(pinned));
    await hold('landscapeLeft');
    await hold('portraitUp');
    expect(calls.skip(pinned), [
      ['DeviceOrientation.landscapeLeft'],
      ['DeviceOrientation.portraitUp'],
    ]);

    await PlayerOrientation.release(player);
    await tester.pump();
    expect(calls.last, ['DeviceOrientation.portraitUp']);
    expect(listening, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a closing player never undoes the orientation of the next one', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final calls = <List<String>>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') calls.add(List<String>.from(call.arguments as List));
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    const landscape = ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'];
    const portrait = ['DeviceOrientation.portraitUp'];
    final first = Object();
    final second = Object();

    await PlayerOrientation.enter(first);
    await PlayerOrientation.toggle(Orientation.portrait);
    await PlayerOrientation.release(first);
    await PlayerOrientation.enter(second);
    // The first player's route is disposed late, after the second one opened.
    await PlayerOrientation.release(first);
    expect(calls, [<String>[], landscape, portrait, <String>[]]);
    await PlayerOrientation.release(second);
    expect(calls.last, portrait);
  });

  testWidgets('the end of the last item shows replay, which restarts from the beginning', (tester) async {
    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.0);
    final container = _container(tester);
    container.read(queueControllerProvider.notifier).playFrom(_queueItems(1));
    await _settle(tester);
    harness.engine.emitMockSnapshot(_endedSnapshot(const Duration(minutes: 10)));
    await _settle(tester);
    expect(container.read(playerControllerProvider).status, PlaybackStatus.ended);

    await tester.tap(find.byTooltip('Replay'));
    await _settle(tester, frames: 2);
    expect(container.read(playerControllerProvider).isPlaying, isTrue);
    expect(container.read(playerControllerProvider).position, lessThan(const Duration(seconds: 1)));
    await harness.engine.dispose();
  });

  testWidgets('position updates after EOF advance the queue only once', (tester) async {
    final harness = await _pumpPlayer(tester, _touchSurfaces[3], 1.0);
    final container = _container(tester);
    container.read(queueControllerProvider.notifier).playFrom(_queueItems(4));
    await _settle(tester);
    expect(container.read(queueControllerProvider).currentIndex, 0);
    for (var i = 0; i < 3; i++) {
      harness.engine.emitMockSnapshot(_endedSnapshot(Duration(minutes: 10, milliseconds: i)));
    }
    await _settle(tester);
    expect(container.read(queueControllerProvider).currentIndex, 1);
    await harness.engine.dispose();
  });

  for (final surface in [_touchSurfaces[3], _touchSurfaces[4]]) {
    testWidgets('${surface.name}: control text and icons stay legible over a white frame', (tester) async {
      final harness = await _pumpPlayer(tester, surface, 1.35);
      _container(tester).read(queueControllerProvider.notifier).playFrom(_queueItems(2));
      await _settle(tester);
      await _container(tester).read(playerControllerProvider.notifier).pause();
      await _settle(tester);
      final overlay = find.byType(DanaviewControlsOverlay);
      final height = surface.size.height;
      bool inBars(Rect r) => r.center.dy < height * 0.3 || r.center.dy > height * 0.7;

      final time = find.descendant(of: overlay, matching: find.textContaining(' / '));
      expect(tester.widget<Text>(time).style!.color, DanaviewColors.textPrimary);
      var checked = 0;
      for (final element in find.descendant(of: overlay, matching: find.byType(Text)).evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        if (!inBars(rect)) continue;
        final color = (element.widget as Text).style?.color ?? DanaviewColors.textPrimary;
        expect(_worstContrast(tester, color, rect), greaterThanOrEqualTo(4.5), reason: '${element.widget}');
        checked++;
      }
      for (final element in find.descendant(of: overlay, matching: find.byType(Icon)).evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        if (!inBars(rect)) continue;
        final color = (element.widget as Icon).color ?? DanaviewColors.textPrimary;
        expect(_worstContrast(tester, color, rect), greaterThanOrEqualTo(3), reason: '${element.widget}');
        checked++;
      }
      expect(checked, greaterThan(4));
      await harness.engine.dispose();
    });
  }

  testWidgets('desktop lock hides the window title and pin, leaving only the unlock icon', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final harness = await _pumpPlayer(tester, _desktopSurfaces.first, 1.0);
      final items = _queueItems(1);
      _container(tester).read(queueControllerProvider.notifier).playFrom(items);
      await _settle(tester);
      final titleBar = find.byType(DanaviewTitleBar);
      expect(find.descendant(of: titleBar, matching: find.text(items.single.title)), findsOneWidget);
      expect(find.descendant(of: titleBar, matching: find.byTooltip('Pin window on top (T)')), findsOneWidget);

      await tester.tap(find.byTooltip('Lock controls'));
      await _settle(tester);
      expect(find.descendant(of: titleBar, matching: find.byType(Text)), findsNothing);
      expect(find.descendant(of: titleBar, matching: find.byIcon(Icons.push_pin_outlined)), findsNothing);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      await harness.engine.dispose();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  group('PlayerController', () {
    test('records the media duration in history once it is known', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final libraryRepo = LibraryRepository(prefs);
      final engine = FakePlaybackEngine();
      await engine.initialize();
      final container = ProviderContainer(overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        sessionRepositoryProvider.overrideWithValue(SessionRepository(prefs)),
        libraryRepositoryProvider.overrideWithValue(libraryRepo),
      ]);
      addTearDown(container.dispose);

      const media = MediaRef(id: '/missing/movie.mkv', title: 'movie.mkv', pathOrUri: '/missing/movie.mkv');
      await container.read(playerControllerProvider.notifier).openMedia(media);
      await Future<void>.delayed(Duration.zero);

      expect(libraryRepo.getRecentlyPlayed().single.duration, const Duration(minutes: 10));
      await engine.dispose();
    });
  });
}
