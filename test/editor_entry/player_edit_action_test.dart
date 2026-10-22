// OWNER: UX-41
//
// The player's Edit action (ARCH §17.1, ux.md §4.4, §4.6): visibility (callback, local vs stream,
// failed playback, locked controls), the E shortcut (ignored while locked), the "E – Edit video"
// cheat-sheet line only with the callback, the exact position handed over, the Playback sheet row,
// no overflow at 280 px and 1.35x, and PlayerController.suspendForEditor / resumeAfterEditor in
// both handoff modes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

const _local = MediaRef(id: '/videos/holiday.mp4', title: 'Holiday at the lake', pathOrUri: '/videos/holiday.mp4');
const _remote = MediaRef(
  id: 'https://example.com/live.m3u8',
  title: 'Live stream',
  pathOrUri: 'https://example.com/live.m3u8',
  isRemote: true,
);

const _editKey = ValueKey('player-edit-video');
const _sheetRowKey = ValueKey('player-sheet-edit-video');

class _Player {
  _Player(this.engine, this.requests, this.container);

  final FakePlaybackEngine engine;
  final List<PlayerEditRequest> requests;
  final ProviderContainer container;

  PlayerController get controller => container.read(playerControllerProvider.notifier);
  PlayerState get state => container.read(playerControllerProvider);
}

Future<_Player> _pump(
  WidgetTester tester, {
  bool withEdit = true,
  Size size = const Size(402, 874),
  double textScale = 1.0,
  MediaRef? media = _local,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final engine = FakePlaybackEngine();
  await engine.initialize();
  final requests = <PlayerEditRequest>[];
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  const padding = EdgeInsets.only(top: 20);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        sessionRepositoryProvider.overrideWithValue(SessionRepository(prefs)),
        libraryRepositoryProvider.overrideWithValue(LibraryRepository(prefs)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: DanaviewTheme.darkTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: padding,
            viewPadding: padding,
          ),
          child: child!,
        ),
        home: DanaviewPlayerScreen(onBack: () {}, onEditVideo: withEdit ? requests.add : null),
      ),
    ),
  );
  final container = ProviderScope.containerOf(tester.element(find.byType(DanaviewPlayerScreen)));
  final player = _Player(engine, requests, container);
  // Phones have no desktop title bar; fullscreen hides it on the macOS test host as well.
  player.controller.toggleFullscreen().ignore();
  if (media != null) {
    container.read(queueControllerProvider.notifier).playFrom([media]).ignore();
  }
  await _settle(tester);
  return player;
}

/// Advances time in small steps; never pumpAndSettle (the spinner animates forever).
Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(tester.takeException(), isNull);
}

Future<void> _finish(WidgetTester tester, _Player player) async {
  DanaviewToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await player.engine.dispose();
}

Future<void> _pausedAt(WidgetTester tester, _Player player, Duration position) async {
  player.engine.emitMockSnapshot(PlayerSnapshot(
    status: PlaybackStatus.paused,
    position: position,
    duration: const Duration(minutes: 10),
  ));
  await _settle(tester, frames: 2);
}

Future<void> _openMoreSheet(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_horiz_rounded));
  await _settle(tester);
}

Future<void> _openShortcuts(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.comma);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await _settle(tester);
  final tile = find.descendant(of: find.byType(DanaviewSettingsPanel), matching: find.text('Keyboard Shortcuts'));
  await tester.ensureVisible(tile);
  await _settle(tester, frames: 2);
  await tester.tap(tile);
  await _settle(tester);
}

void main() {
  group('visibility', () {
    testWidgets('local media with the callback: Edit is the first trailing top-bar button', (tester) async {
      final player = await _pump(tester);
      expect(find.byKey(_editKey), findsOneWidget);
      final button = tester.widget<DanaviewIconButton>(find.byKey(_editKey));
      expect(button.icon, Icons.movie_edit);
      expect(button.iconSize, 20);
      expect(button.tooltip, 'Edit video (E)');
      expect(button.semanticLabel, 'Edit this video');
      final edit = tester.getRect(find.byKey(_editKey));
      final lock = tester.getRect(find.byTooltip('Lock controls'));
      final info = tester.getRect(find.byTooltip('Stats for nerds (I)'));
      expect(edit.right, lessThanOrEqualTo(lock.left));
      expect(lock.right, lessThanOrEqualTo(info.left));
      expect(edit.center.dy, closeTo(lock.center.dy, 0.01));
      await _finish(tester, player);
    });

    testWidgets('no callback (unsupported platform or flag off): no button, no sheet row, E does nothing', (tester) async {
      final player = await _pump(tester, withEdit: false);
      expect(find.byIcon(Icons.movie_edit), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await _settle(tester, frames: 2);
      expect(player.requests, isEmpty);
      await _openMoreSheet(tester);
      expect(find.text('Edit video'), findsNothing);
      await _finish(tester, player);
    });

    testWidgets('remote streams hide the action everywhere and ignore E', (tester) async {
      final player = await _pump(tester, media: _remote);
      expect(player.state.currentMediaRef, _remote);
      expect(find.byKey(_editKey), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await _settle(tester, frames: 2);
      expect(player.requests, isEmpty);
      await _openMoreSheet(tester);
      expect(find.byKey(_sheetRowKey), findsNothing);
      await _finish(tester, player);
    });

    testWidgets('nothing open: no Edit button', (tester) async {
      final player = await _pump(tester, media: null);
      expect(find.byKey(_editKey), findsNothing);
      await _finish(tester, player);
    });

    testWidgets('failed playback hides the action', (tester) async {
      final player = await _pump(tester);
      expect(find.byKey(_editKey), findsOneWidget);
      player.engine.emitMockError(const FileNotFound('/videos/holiday.mp4'));
      await _settle(tester);
      expect(player.state.status, PlaybackStatus.error);
      expect(find.byKey(_editKey), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await _settle(tester, frames: 2);
      expect(player.requests, isEmpty);
      await _finish(tester, player);
    });

    testWidgets('locked controls hide Edit and ignore E; unlocking brings it back', (tester) async {
      final player = await _pump(tester);
      await tester.tap(find.byTooltip('Lock controls'));
      await _settle(tester);
      expect(find.byKey(_editKey), findsNothing);
      expect(find.byIcon(Icons.movie_edit), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await _settle(tester, frames: 2);
      expect(player.requests, isEmpty);
      await tester.tap(find.bySemanticsLabel('Unlock controls'));
      await _settle(tester);
      expect(find.byKey(_editKey), findsOneWidget);
      await _finish(tester, player);
    });

    test('playerCanEditVideo: local, opened and not failed', () {
      final source = MediaSource.file('/videos/holiday.mp4', title: 'holiday.mp4');
      expect(playerCanEditVideo(const PlayerState()), isFalse);
      expect(playerCanEditVideo(PlayerState(currentMediaRef: _local, currentSource: source, status: PlaybackStatus.paused)), isTrue);
      expect(
        playerCanEditVideo(PlayerState(currentMediaRef: _remote, currentSource: source, status: PlaybackStatus.paused)),
        isFalse,
      );
      expect(playerCanEditVideo(PlayerState(currentMediaRef: _local, currentSource: source, status: PlaybackStatus.error)), isFalse);
    });
  });

  group('request', () {
    testWidgets('the button hands over the media and the exact paused position', (tester) async {
      final player = await _pump(tester);
      await _pausedAt(tester, player, const Duration(minutes: 1, seconds: 2, milliseconds: 345));
      await tester.tap(find.byKey(_editKey));
      await _settle(tester, frames: 2);
      expect(player.requests, [
        const PlayerEditRequest(media: _local, position: Duration(minutes: 1, seconds: 2, milliseconds: 345), wasPlaying: false),
      ]);
      await _finish(tester, player);
    });

    testWidgets('E opens the editor while playing and reports wasPlaying', (tester) async {
      final player = await _pump(tester);
      expect(player.state.isPlaying, isTrue);
      final at = player.state.position;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await _settle(tester, frames: 1);
      expect(player.requests, hasLength(1));
      expect(player.requests.single.media, _local);
      expect(player.requests.single.wasPlaying, isTrue);
      expect(player.requests.single.position, greaterThanOrEqualTo(at));
      await _finish(tester, player);
    });

    // FIX M-23 (QA-02 s02 on the 2 GB AVD after `pm clear`): the test read the player at
    // 5,333,333 us, then the engine reported 0 while paused before the Edit tap, and the editor
    // opened at frame 0.
    testWidgets('FIX M-23: a reset to 0 after a landed seek while paused does not reach the handoff', (tester) async {
      final player = await _pump(tester);
      await player.controller.pause();
      await player.controller.seek(const Duration(microseconds: 5333334), mode: SeekMode.exact);
      await _settle(tester, frames: 2);
      expect(player.state.position, const Duration(microseconds: 5333334));
      // The late reset (e.g. media_kit's open restarting the file at `playlist-pos`).
      player.engine.emitMockSnapshot(const PlayerSnapshot(status: PlaybackStatus.buffering, position: Duration.zero, duration: Duration(minutes: 10)));
      player.engine.emitMockSnapshot(const PlayerSnapshot(status: PlaybackStatus.paused, position: Duration.zero, duration: Duration(minutes: 10)));
      await _settle(tester, frames: 2);
      expect(player.state.position, Duration.zero, reason: 'the raw snapshot did drop to 0');
      expect(player.controller.currentPosition, const Duration(microseconds: 5333334));
      await tester.tap(find.byKey(_editKey));
      await _settle(tester, frames: 2);
      expect(player.requests.single.position, const Duration(microseconds: 5333334));
      final token = await player.controller.suspendForEditor(PlayerHandoffMode.pause);
      expect(token!.position, const Duration(microseconds: 5333334));
      await _finish(tester, player);
    });

    testWidgets('FIX M-23: the held position ends with the next real report, a seek or play', (tester) async {
      final player = await _pump(tester);
      await player.controller.pause();
      await player.controller.seek(const Duration(seconds: 20), mode: SeekMode.exact);
      await _settle(tester, frames: 1);
      player.engine.emitMockSnapshot(const PlayerSnapshot(status: PlaybackStatus.paused, position: Duration.zero, duration: Duration(minutes: 10)));
      await _settle(tester, frames: 1);
      expect(player.controller.currentPosition, const Duration(seconds: 20));
      // A real report replaces it.
      player.engine.emitMockSnapshot(const PlayerSnapshot(status: PlaybackStatus.paused, position: Duration(seconds: 21), duration: Duration(minutes: 10)));
      await _settle(tester, frames: 1);
      expect(player.controller.currentPosition, const Duration(seconds: 21));
      // A relative seek uses the held position as its base.
      player.engine.emitMockSnapshot(const PlayerSnapshot(status: PlaybackStatus.paused, position: Duration.zero, duration: Duration(minutes: 10)));
      await _settle(tester, frames: 1);
      expect(player.controller.currentPosition, const Duration(seconds: 21));
      await player.controller.seekBy(const Duration(seconds: 5));
      await _settle(tester, frames: 1);
      expect(player.state.position, const Duration(seconds: 26));
      // Playing from there: a reset is real playback, not held.
      await player.controller.play();
      player.engine.emitMockSnapshot(const PlayerSnapshot(status: PlaybackStatus.playing, position: Duration.zero, duration: Duration(minutes: 10)));
      await _settle(tester, frames: 1);
      expect(player.controller.currentPosition, Duration.zero);
      await _finish(tester, player);
    });

    testWidgets('FIX M-23: a seek to the start while paused hands over 0', (tester) async {
      final player = await _pump(tester);
      await player.controller.pause();
      await player.controller.seek(const Duration(seconds: 9), mode: SeekMode.exact);
      await _settle(tester, frames: 1);
      await player.controller.seek(Duration.zero, mode: SeekMode.exact);
      await _settle(tester, frames: 2);
      expect(player.controller.currentPosition, Duration.zero);
      await tester.tap(find.byKey(_editKey));
      await _settle(tester, frames: 2);
      expect(player.requests.single.position, Duration.zero);
      await _finish(tester, player);
    });

    testWidgets('the Playback sheet row sits above Queue and closes the sheet first', (tester) async {
      final player = await _pump(tester, size: const Size(280, 560), textScale: 1.35);
      await _pausedAt(tester, player, const Duration(seconds: 42));
      await _openMoreSheet(tester);
      final row = find.byKey(_sheetRowKey);
      await tester.ensureVisible(row);
      await _settle(tester, frames: 2);
      expect(find.text('Edit video'), findsOneWidget);
      expect(find.text('Trim, add text, captions and more'), findsOneWidget);
      expect(tester.getRect(row).bottom, lessThanOrEqualTo(tester.getRect(find.text('Queue')).top));
      await tester.tap(row);
      await _settle(tester);
      expect(find.text('Volume'), findsNothing, reason: 'the sheet closed');
      expect(player.requests.single.position, const Duration(seconds: 42));
      await _finish(tester, player);
    });
  });

  group('cheat sheet', () {
    testWidgets('lists "E – Edit video" with the callback', (tester) async {
      final player = await _pump(tester, size: const Size(1280, 800));
      await _openShortcuts(tester);
      final panel = find.byType(DanaviewSettingsPanel);
      expect(find.descendant(of: panel, matching: find.text('Edit video')), findsOneWidget);
      expect(find.descendant(of: panel, matching: find.widgetWithText(DanaviewBadge, 'E')), findsOneWidget);
      await _finish(tester, player);
    });

    testWidgets('has no Edit line without the callback', (tester) async {
      final player = await _pump(tester, size: const Size(1280, 800), withEdit: false);
      await _openShortcuts(tester);
      final panel = find.byType(DanaviewSettingsPanel);
      expect(find.descendant(of: panel, matching: find.text('Open files')), findsOneWidget);
      expect(find.descendant(of: panel, matching: find.text('Edit video')), findsNothing);
      await _finish(tester, player);
    });
  });

  group('no overflow at 280 px and 1.35x', () {
    for (final size in const [Size(280, 560), Size(560, 280)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}: top bar and the Playback sheet row', (tester) async {
        final player = await _pump(tester, size: size, textScale: 1.35);
        expect(find.byKey(_editKey), findsOneWidget);
        final bar = tester.getRect(find.byKey(_editKey));
        expect(bar.left, greaterThanOrEqualTo(0));
        expect(bar.right, lessThanOrEqualTo(size.width));
        final title = find.text(_local.title);
        expect(tester.getSize(title).width, greaterThan(40), reason: 'the ellipsized title keeps room');
        await _openMoreSheet(tester);
        final row = find.byKey(_sheetRowKey);
        await tester.ensureVisible(row);
        await _settle(tester, frames: 2);
        final rect = tester.getRect(row);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(tester.takeException(), isNull);
        await _finish(tester, player);
      });
    }
  });

  group('PlayerController editor handoff', () {
    testWidgets('pause mode: paused, then restored paused at the original position', (tester) async {
      final player = await _pump(tester);
      await _pausedAt(tester, player, const Duration(seconds: 30));
      await player.controller.play();
      await _settle(tester, frames: 1);
      final token = await player.controller.suspendForEditor(PlayerHandoffMode.pause, position: const Duration(seconds: 30));
      await _settle(tester, frames: 1);
      expect(token, isNotNull);
      expect(token!.released, isFalse);
      expect(token.wasPlaying, isTrue);
      expect(token.media, _local);
      expect(player.state.status, PlaybackStatus.paused);
      // The editor ran a while; the player engine drifted (e.g. a late snapshot).
      player.engine.emitMockSnapshot(const PlayerSnapshot(status: PlaybackStatus.paused, position: Duration(seconds: 31), duration: Duration(minutes: 10)));
      await _settle(tester, frames: 1);
      await player.controller.resumeAfterEditor(token);
      await _settle(tester, frames: 1);
      expect(player.state.status, PlaybackStatus.paused);
      expect(player.state.position, const Duration(seconds: 30));
      expect(player.state.currentMediaRef, _local);
      await _finish(tester, player);
    });

    testWidgets('release mode: the engine stops, the item stays, and it reopens paused at the position', (tester) async {
      final player = await _pump(tester);
      await _pausedAt(tester, player, const Duration(minutes: 3));
      final token = await player.controller.suspendForEditor(PlayerHandoffMode.release);
      await _settle(tester, frames: 1);
      expect(token!.released, isTrue);
      expect(token.position, const Duration(minutes: 3));
      expect(player.engine.currentSnapshot.status, PlaybackStatus.idle);
      expect(player.state.currentMediaRef, _local, reason: 'Home keeps showing the item');
      expect(player.container.read(queueControllerProvider).items, [_local]);
      await player.controller.resumeAfterEditor(token);
      await _settle(tester, frames: 1);
      expect(player.state.status, PlaybackStatus.paused);
      expect(player.state.position, const Duration(minutes: 3));
      expect(player.state.currentMediaRef, _local);
      await _finish(tester, player);
    });

    testWidgets('nothing open: no token', (tester) async {
      final player = await _pump(tester, media: null);
      expect(await player.controller.suspendForEditor(PlayerHandoffMode.pause), isNull);
      await _finish(tester, player);
    });
  });
}
