// OWNER: HOM-06
//
// BUILD_PLAN HOM-06 (FILES_MEDIA_HOME_PLAN P-1, P-2, P-3, P-7; ARCH v1.2 V2-32): the Now Playing
// card, Continue watching and the quick actions behave exactly as in 1.1 with DANAVIEW_FILES_HOME
// off and in the `Home` tab with it on. Each behaviour runs under both flag values; the callback
// test replays one script of hub actions under both and requires the same transcript (every
// callback receives the same MediaRef as in 1.1).

import 'dart:io';

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_features/src/library/library_format.dart';
import 'package:danaview_features/src/library/library_widgets.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../library_test_utils.dart';
import 'hub_support.dart';

String _flag(bool on) => on ? 'flag on (Home tab)' : 'flag off';

Future<void> _scrollTo(WidgetTester tester, Finder finder, {required bool filesHome}) async {
  await tester.scrollUntilVisible(finder, 300, scrollable: hubScrollable(filesHome: filesHome));
  await tester.pump();
}

Future<void> _menu(WidgetTester tester, int row, String item) async {
  await tester.tap(recentMenu(row));
  await pumpFrames(tester);
  await tester.tap(find.text(item));
  await pumpFrames(tester);
}

Future<void> _openLink(WidgetTester tester, String link) async {
  await tester.tap(find.text('Open link'));
  await pumpFrames(tester);
  await tester.enterText(find.byType(EditableText), link);
  await tester.tap(find.widgetWithText(DanaviewButton, 'Play'));
  await pumpFrames(tester);
}

/// One script of hub actions; returns what reached the callbacks, the player and the library.
Future<List<Object?>> _runScript(WidgetTester tester, Directory tree, {required bool filesHome}) async {
  final calls = HubCalls();
  final env = await pumpHub(tester, filesHome: filesHome, tree: tree, calls: calls);
  final log = <Object?>[];
  void record(String step) => log.add([step, calls.playerOpens, List.of(hubQueue(tester)), List.of(calls.folders)]);

  // P-2: tap a row, then the row menu's Play.
  await tester.tap(find.textContaining('Show.S01E02'));
  await pumpFrames(tester);
  record('tap row');
  await _menu(tester, 2, 'Play');
  record('menu play');

  // P-1: the card returns to the player.
  await tester.tap(nowPlayingCard);
  await pumpFrames(tester);
  record('now playing');

  // P-2: Add to playlist… and Remove from history.
  await _menu(tester, 3, 'Add to playlist…');
  await tester.tap(find.text('Empty').last);
  await pumpFrames(tester);
  await tester.pump(const Duration(seconds: 3));
  log.add(['playlist Empty', env.library.getPlaylist('Empty')]);
  await _menu(tester, 4, 'Remove from history');
  log.add(['history', env.library.getRecentlyPlayed()]);

  // P-3 / P-7: every protocol of the link dialog.
  for (final link in hubProtocolLinks) {
    await _openLink(tester, link);
    record('link $link');
  }

  // P-3: Open file and Open folder (host is desktop: the folder picker is shown).
  final picked = joinPath([tree.path, 'Season 1', 'Show.S01E08.$longTitle.mkv']);
  fakeFileSelector(files: [picked], directory: joinPath([tree.path, 'Season 1']));
  await tester.tap(find.text('Open file'));
  await pumpFrames(tester);
  record('open file');
  await tester.tap(find.text('Open folder'));
  await pumpFrames(tester);
  record('open folder');
  log.add(['folders', env.library.getFolders().map((f) => f.path).toList()]);

  // P-2: Clear history.
  await _scrollTo(tester, find.text('Clear'), filesHome: filesHome);
  await tester.tap(find.widgetWithText(DanaviewButton, 'Clear'));
  await pumpFrames(tester);
  await tester.tap(find.widgetWithText(DanaviewButton, 'Clear').last);
  await pumpFrames(tester);
  log.add(['cleared', env.library.getRecentlyPlayed(), find.text('Continue watching').evaluate().length]);

  expect(tester.takeException(), isNull);
  await finishHome(tester, env);
  return log;
}

void main() {
  late Directory tree;
  late List<MediaRef> history;

  setUpAll(() {
    tree = createHubTree();
    history = hubHistory(tree);
  });
  tearDownAll(() => tree.deleteSync(recursive: true));

  testWidgets('every callback receives the same MediaRef as in 1.1 (flag off vs Home tab)', (tester) async {
    final off = await _runScript(tester, tree, filesHome: false);
    final on = await _runScript(tester, tree, filesHome: true);
    expect(on, off);

    // And the 1.1 values themselves.
    List<Object?> step(String name) => off.cast<List<Object?>>().firstWhere((e) => e.first == name);
    expect(step('tap row'), ['tap row', 1, [history[1]], <String>[]]);
    expect(step('menu play'), ['menu play', 2, [history[2]], <String>[]]);
    expect(step('now playing'), ['now playing', 3, [history[2]], <String>[]]);
    for (final link in hubProtocolLinks) {
      expect(step('link $link')[2], [MediaUrl.tryParse(link)!], reason: link);
    }
    expect(step('open file')[2], [history[7]]);
    expect(step('open folder')[3], [joinPath([tree.path, 'Season 1'])]);
    expect(step('playlist Empty')[1], [history[3]]);
    expect(step('history')[1], isNot(contains(history[4])));
    expect(step('history')[1], hasLength(9));
    expect(step('folders')[1], [joinPath([tree.path, 'Season 1'])]);
    expect(step('cleared'), ['cleared', <MediaRef>[], 0]);
  });

  for (final on in [false, true]) {
    group(_flag(on), () {
      testWidgets('P-1: Now Playing shows the current media and a tap returns to the player', (tester) async {
        final calls = HubCalls();
        final env = await pumpHub(tester, filesHome: on, tree: tree, calls: calls, seed: false);
        expect(find.text('NOW PLAYING'), findsNothing);
        await startPlaying(tester, hubStream);
        expect(find.text('NOW PLAYING'), findsOneWidget);
        expect(find.descendant(of: nowPlayingCard, matching: find.text(hubStream.title)), findsOneWidget);
        final semantics = tester.ensureSemantics();
        expect(find.bySemanticsLabel(RegExp('^${RegExp.escape('Now playing: ${hubStream.title}. Open player')}')), findsOneWidget);
        semantics.dispose();
        await tester.tap(nowPlayingCard);
        await pumpFrames(tester);
        expect(calls.playerOpens, 1);
        expect(hubQueue(tester), [hubStream]);
        await finishHome(tester, env);
      });

      testWidgets('P-2: progress bars, resume points and episode badges', (tester) async {
        final env = await pumpHub(tester, filesHome: on, tree: tree);
        final rows = tester.widgetList<DanaviewLibraryRow>(
          find.descendant(of: continueWatchingRows, matching: find.byType(DanaviewLibraryRow)),
        ).toList();
        expect(rows, hasLength(6));
        expect([for (final r in rows) r.badge], ['S01E01', 'S01E02', 'S01E03', 'S01E04', 'S01E05', 'S01E06']);
        for (var i = 0; i < 4; i++) {
          final position = Duration(minutes: 5 + i * 7);
          expect(rows[i].progress, closeTo(position.inSeconds / (52 * 60), 1e-9), reason: 'row $i');
          expect(rows[i].subtitle, '${formatShortDuration(const Duration(minutes: 52) - position)} left');
        }
        expect(rows[4].progress ?? 0, 0);
        await finishHome(tester, env);
      });

      testWidgets('P-2: Show all N expands to every entry and Show less collapses', (tester) async {
        final env = await pumpHub(tester, filesHome: on, tree: tree);
        Iterable<Element> rows() =>
            find.descendant(of: continueWatchingRows, matching: find.byType(DanaviewLibraryRow)).evaluate();
        expect(find.text('Show all 10'), findsOneWidget);
        expect(rows(), hasLength(6));
        await _scrollTo(tester, find.text('Show all 10'), filesHome: on);
        await tester.tap(find.text('Show all 10'));
        await pumpFrames(tester);
        expect(rows(), hasLength(10));
        expect(find.text('File not found'), findsOneWidget);
        await _scrollTo(tester, find.text('Show less'), filesHome: on);
        await tester.tap(find.text('Show less'));
        await pumpFrames(tester);
        expect(rows(), hasLength(6));
        await finishHome(tester, env);
      });

      testWidgets('P-2: the item menu lists Play, Add to playlist…, Remove from history', (tester) async {
        final env = await pumpHub(tester, filesHome: on, tree: tree);
        await tester.tap(recentMenu(0));
        await pumpFrames(tester);
        for (final item in ['Play', 'Add to playlist…', 'Remove from history']) {
          expect(find.text(item), findsOneWidget, reason: item);
        }
        await tester.tap(find.text('Remove from history'));
        await pumpFrames(tester);
        expect(env.library.getRecentlyPlayed(), isNot(contains(history[0])));
        expect(env.session.getResumeInfo(history[0].id), isNull);
        expect(find.text('Show all 9'), findsOneWidget);
        await finishHome(tester, env);
      });

      testWidgets('P-2: Clear asks first; Cancel keeps the history, Clear empties it', (tester) async {
        final env = await pumpHub(tester, filesHome: on, tree: tree);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Clear'));
        await pumpFrames(tester);
        expect(find.text('Clear Continue watching'), findsOneWidget);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Cancel'));
        await pumpFrames(tester);
        expect(env.library.getRecentlyPlayed(), hasLength(10));
        await tester.tap(find.widgetWithText(DanaviewButton, 'Clear'));
        await pumpFrames(tester);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Clear').last);
        await pumpFrames(tester);
        expect(env.library.getRecentlyPlayed(), isEmpty);
        expect(env.session.getResumeInfo(history[0].id), isNull);
        expect(find.text('Continue watching'), findsNothing);
        await finishHome(tester, env);
      });

      testWidgets('P-2: a missing file shows a toast instead of playing', (tester) async {
        final calls = HubCalls();
        final env = await pumpHub(tester, filesHome: on, tree: tree, calls: calls);
        await tester.tap(find.text('Show all 10'));
        await pumpFrames(tester);
        await _scrollTo(tester, find.textContaining('Missing Movie'), filesHome: on);
        await tester.tap(find.textContaining('Missing Movie'));
        await pumpFrames(tester);
        expect(find.textContaining("isn't available anymore"), findsOneWidget);
        expect(calls.playerOpens, 0);
        expect(hubQueue(tester), isEmpty);
        await finishHome(tester, env);
      });

      testWidgets('P-3: the three quick actions stay in place in 1.1 order', (tester) async {
        final env = await pumpHub(tester, filesHome: on, tree: tree);
        for (final label in ['Open file', 'Open folder', 'Open link']) {
          expect(find.descendant(of: quickActions, matching: find.text(label)), findsOneWidget, reason: label);
        }
        // Quick actions sit right under the (hidden) Now Playing card, above Continue watching.
        expect(tester.getTopLeft(quickActions).dy, lessThan(tester.getTopLeft(continueWatchingHeader).dy));
        await finishHome(tester, env);
      });

      testWidgets('P-3: a cancelled Open file or Open folder does nothing', (tester) async {
        final calls = HubCalls();
        final env = await pumpHub(tester, filesHome: on, tree: tree, calls: calls);
        fakeFileSelector();
        await tester.tap(find.text('Open file'));
        await pumpFrames(tester);
        await tester.tap(find.text('Open folder'));
        await pumpFrames(tester);
        expect(calls.playerOpens, 0);
        expect(calls.folders, isEmpty);
        expect(hubQueue(tester), isEmpty);
        await finishHome(tester, env);
      });

      testWidgets('P-7: the link dialog opens every protocol and rejects unsupported ones', (tester) async {
        final calls = HubCalls();
        final env = await pumpHub(tester, filesHome: on, tree: tree, calls: calls);
        for (final link in hubProtocolLinks) {
          await _openLink(tester, link);
          expect(hubQueue(tester), [MediaUrl.tryParse(link)!], reason: link);
        }
        expect(calls.playerOpens, hubProtocolLinks.length);

        await tester.tap(find.text('Open link'));
        await pumpFrames(tester);
        await tester.enterText(find.byType(EditableText), 'ftp://files.example.com/movie.mp4');
        await tester.tap(find.widgetWithText(DanaviewButton, 'Play'));
        await pumpFrames(tester);
        expect(find.text(MediaUrl.validationError('ftp://files.example.com/movie.mp4')!), findsOneWidget);
        expect(calls.playerOpens, hubProtocolLinks.length);
        await finishHome(tester, env);
      });
    });
  }
}
