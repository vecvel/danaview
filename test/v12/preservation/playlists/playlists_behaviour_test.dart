// OWNER: HOM-07
//
// BUILD_PLAN HOM-07 (FILES_MEDIA_HOME_PLAN P-4, P-6; ARCH v1.2 V2-32): the 1.1 Playlists section,
// the playlist screen, the add-to-playlist sheet and the queue they feed behave exactly as in 1.1
// with DANAVIEW_FILES_HOME off, in the `Home` tab with it on and in the `Playlists` tab with it on.
// The transcript test replays one script of playlist actions in every host and requires the same
// result (same callbacks, same queue, same library), and pins the 1.1 values themselves.

import 'dart:io';

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_features/danaview_features.dart' show HomeMediaCard;
import 'package:danaview_features/src/library/library_widgets.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';

import '../../../library_test_utils.dart';
import '../../home_shell/home_shell_support.dart' show homeShellSurfaces;
import 'playlists_support.dart';

Future<void> _enterName(WidgetTester tester, String name, String confirm) async {
  await tester.enterText(find.byType(EditableText), name);
  await pumpFrames(tester);
  await tester.tap(find.widgetWithText(DanaviewButton, confirm));
  await pumpFrames(tester);
}

/// Everything a playlist action can change: callbacks, the queue and the stored playlists.
List<Object?> _snapshot(WidgetTester tester, LibraryTestEnv env, PlaylistCalls calls) {
  final queue = queueOf(tester);
  return [
    calls.playerOpens,
    List.of(calls.opened),
    // Shuffle order is random: compare the original order, the set and the current item's slot.
    queue.isShuffled ? List.of(queue.unShuffledItems) : List.of(queue.items),
    queue.items.toSet(),
    queue.isShuffled,
    queue.currentIndex,
    {for (final name in env.library.getSavedPlaylistNames()) name: env.library.getPlaylist(name)},
  ];
}

/// One script of Playlists-section actions; returns what each step left behind.
Future<List<Object?>> _runScript(WidgetTester tester, Directory tree, PlaylistsHost host) async {
  final calls = PlaylistCalls();
  final env = await pumpPlaylistsHome(tester, host: host, tree: tree, calls: calls);
  final log = <Object?>[];
  void record(String step) => log.add([step, ..._snapshot(tester, env, calls)]);

  // Tap a row: opens the playlist route.
  await scrollToInHost(tester, host, inHost(host, find.text('Road Trip')));
  await tester.tap(inHost(host, find.text('Road Trip')));
  await pumpFrames(tester);
  record('open row');

  // Row menu: Play and Shuffle.
  await playlistMenuAction(tester, host, 'Road Trip', 'Play');
  record('play');
  await playlistMenuAction(tester, host, 'Road Trip', 'Shuffle');
  record('shuffle');

  // New (header): create and open.
  await scrollToInHost(tester, host, playlistsHeader(host));
  await tester.tap(find.descendant(of: playlistsHeader(host), matching: find.text('New')));
  await pumpFrames(tester);
  await _enterName(tester, 'Favourites', 'Create');
  record('new');

  // Rename and Delete through the row menu.
  await waitOutToasts(tester);
  await playlistMenuAction(tester, host, 'Single', 'Rename');
  await _enterName(tester, 'Solo', 'Rename');
  record('rename');
  await waitOutToasts(tester);
  await playlistMenuAction(tester, host, 'Empty', 'Delete');
  await tester.tap(find.widgetWithText(DanaviewButton, 'Delete'));
  await pumpFrames(tester);
  record('delete');

  // The rows left, in order, with their subtitles.
  log.add(['rows', for (final (title, subtitle) in playlistItems(tester, host)) '$title · $subtitle']);

  expect(tester.takeException(), isNull);
  await finishHome(tester, env);
  return log;
}

void main() {
  late Directory tree;
  late List<MediaRef> trip;

  setUpAll(() {
    tree = createPlaylistTree();
    trip = roadTripRefs(tree);
  });
  tearDownAll(() => tree.deleteSync(recursive: true));

  testWidgets('one script of playlist actions gives the 1.1 result in every host', (tester) async {
    final off = await _runScript(tester, tree, PlaylistsHost.flagOff);
    final homeTab = await _runScript(tester, tree, PlaylistsHost.homeTab);
    final playlistsTab = await _runScript(tester, tree, PlaylistsHost.playlistsTab);
    expect(homeTab, off, reason: 'Home tab differs from flag off');
    expect(playlistsTab, off, reason: 'Playlists tab differs from flag off');

    // And the 1.1 values themselves.
    List<Object?> step(String name) => off.cast<List<Object?>>().firstWhere((e) => e.first == name);
    expect(step('open row').sublist(1, 3), [0, ['Road Trip']]);
    expect(step('play').sublist(1, 7), [1, ['Road Trip'], trip, trip.toSet(), false, 0]);
    expect(step('shuffle').sublist(1, 7), [2, ['Road Trip'], trip, trip.toSet(), true, 0]);
    expect(step('new')[2], ['Road Trip', 'Favourites']);
    final library = step('delete')[7]! as Map<String, List<MediaRef>>;
    expect(library.keys, ['Road Trip', longPlaylistName, 'Solo', 'Favourites']);
    expect(library['Solo'], [soloRef(tree)]);
    expect(library['Favourites'], isEmpty);
    expect(step('rows'), [
      'rows',
      'Road Trip · 4 videos',
      '$longPlaylistName · 4 videos',
      'Solo · 1 video',
      'Favourites · No videos yet',
    ]);
  });

  group('overflow matrix 280-1280 px x 0.85-1.35', () {
    for (final surface in homeShellSurfaces) {
      testWidgets('Playlists tab and playlist screen at $surface', (tester) async {
        var env = await pumpPlaylistsHome(tester, host: PlaylistsHost.playlistsTab, tree: tree, surface: surface);
        await scrollToInHost(tester, PlaylistsHost.playlistsTab, inHost(PlaylistsHost.playlistsTab, find.text('Empty')));
        expect(tester.takeException(), isNull);
        await finishHome(tester, env);
        env = await pumpPlaylistScreen(tester, filesHome: true, tree: tree, surface: surface, name: longPlaylistName);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
        await pumpFrames(tester, count: 2);
        expect(tester.takeException(), isNull);
        await finishHome(tester, env);
      });
    }
  });

  for (final host in PlaylistsHost.values) {
    group(host.label, () {
      testWidgets('P-4: rows in creation order with counts; empty and single disable Play/Shuffle', (tester) async {
        final calls = PlaylistCalls();
        final env = await pumpPlaylistsHome(tester, host: host, tree: tree, calls: calls);
        final rows = playlistItems(tester, host);
        expect([for (final r in rows) r.$1], ['Road Trip', longPlaylistName, 'Single', 'Empty']);
        expect([for (final r in rows) r.$2], ['4 videos', '4 videos', '1 video', 'No videos yet']);

        // Empty: Play and Shuffle are disabled; Single: Shuffle is disabled.
        await playlistMenuAction(tester, host, 'Empty', 'Play');
        await tester.tapAt(Offset.zero);
        await pumpFrames(tester);
        await playlistMenuAction(tester, host, 'Single', 'Shuffle');
        await tester.tapAt(Offset.zero);
        await pumpFrames(tester);
        expect(calls.playerOpens, 0);
        expect(queueOf(tester).items, isEmpty);
        expect(tester.takeException(), isNull);
        await finishHome(tester, env);
      });

      testWidgets('P-4: New validates live, creates and opens the playlist', (tester) async {
        final calls = PlaylistCalls();
        final env = await pumpPlaylistsHome(tester, host: host, tree: tree, calls: calls);
        await scrollToInHost(tester, host, playlistsHeader(host));
        await tester.tap(find.descendant(of: playlistsHeader(host), matching: find.text('New')));
        await pumpFrames(tester);
        expect(find.text('New playlist'), findsOneWidget);
        await tester.enterText(find.byType(EditableText), 'road trip');
        await pumpFrames(tester);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Create'));
        await pumpFrames(tester);
        expect(find.text('That name is already used by another playlist.'), findsOneWidget);
        await _enterName(tester, 'Anime', 'Create');
        expect(calls.opened, ['Anime']);
        expect(env.library.getSavedPlaylistNames().last, 'Anime');
        expect(inHost(host, find.text('Anime')), findsOneWidget);
        await finishHome(tester, env);
      });

      testWidgets('P-4: with no playlists the empty state creates the first one', (tester) async {
        final calls = PlaylistCalls();
        final env = await pumpPlaylistsHome(tester, host: host, tree: tree, calls: calls, seed: false);
        if (host == PlaylistsHost.playlistsTab) {
          await scrollToInHost(tester, host, playlistsEmpty(host));
          expect(
              find.descendant(of: playlistsEmpty(host), matching: find.text('Collect videos and links to play them in order.')),
              findsOneWidget);
          expect(find.descendant(of: playlistsHeader(host), matching: find.text('New')), findsNothing);
          await tester.tap(find.descendant(of: playlistsEmpty(host), matching: find.text('New playlist')));
        } else {
          // The Home hides an empty Playlists section (DESIGN_SYSTEM §10.3); New playlist is in
          // the top bar's Import (+) menu.
          expect(inHost(host, find.text('No playlists yet')), findsNothing);
          expect(inHost(host, find.text('Playlists')), findsNothing);
          await tester.tap(find.byTooltip('Import'));
          await pumpFrames(tester);
          await tester.tap(find.text('New playlist').last);
        }
        await pumpFrames(tester);
        await _enterName(tester, 'First', 'Create');
        expect(calls.opened, ['First']);
        expect(env.library.getSavedPlaylistNames(), ['First']);
        expect(inHost(host, find.text('No playlists yet')), findsNothing);
        expect(inHost(host, find.text('First')), findsOneWidget);
        await finishHome(tester, env);
      });

      testWidgets('P-4: Rename keeps the videos and reports the new name', (tester) async {
        final env = await pumpPlaylistsHome(tester, host: host, tree: tree);
        await playlistMenuAction(tester, host, 'Road Trip', 'Rename');
        expect(find.text('Rename playlist'), findsOneWidget);
        expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, 'Road Trip');
        await _enterName(tester, 'Coast Trip', 'Rename');
        expect(find.text('Renamed to "Coast Trip"'), findsOneWidget);
        expect(env.library.getSavedPlaylistNames().first, 'Coast Trip');
        expect(env.library.getPlaylist('Coast Trip'), trip);
        expect(inHost(host, find.text('Road Trip')), findsNothing);
        await finishHome(tester, env);
      });

      testWidgets('P-4: Delete asks first, Cancel keeps it, and the videos stay on disk', (tester) async {
        final env = await pumpPlaylistsHome(tester, host: host, tree: tree);
        await playlistMenuAction(tester, host, 'Road Trip', 'Delete');
        expect(find.text('"Road Trip" will be deleted. The videos stay on disk.'), findsOneWidget);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Cancel'));
        await pumpFrames(tester);
        expect(env.library.getSavedPlaylistNames(), contains('Road Trip'));
        await playlistMenuAction(tester, host, 'Road Trip', 'Delete');
        await tester.tap(find.widgetWithText(DanaviewButton, 'Delete'));
        await pumpFrames(tester);
        expect(find.text('Deleted "Road Trip"'), findsOneWidget);
        expect(env.library.getSavedPlaylistNames(), isNot(contains('Road Trip')));
        for (final media in trip) {
          expect(File(media.pathOrUri).existsSync(), isTrue, reason: media.pathOrUri);
        }
        await finishHome(tester, env);
      });

      testWidgets('P-4/P-6: Play queues the playlist in order; Shuffle keeps the order to restore', (tester) async {
        final calls = PlaylistCalls();
        final env = await pumpPlaylistsHome(tester, host: host, tree: tree, calls: calls);
        await playlistMenuAction(tester, host, 'Road Trip', 'Play');
        expect(calls.playerOpens, 1);
        expect(queueOf(tester).items, trip);
        expect(queueOf(tester).currentItem, trip.first);

        await playlistMenuAction(tester, host, 'Road Trip', 'Shuffle');
        final shuffled = queueOf(tester);
        expect(calls.playerOpens, 2);
        expect(shuffled.isShuffled, isTrue);
        expect(shuffled.currentIndex, 0);
        expect(shuffled.items.toSet(), trip.toSet());
        expect(shuffled.unShuffledItems, trip);
        final current = shuffled.currentItem!;
        queueControllerOf(tester).setShuffle(false);
        await pumpFrames(tester);
        expect(queueOf(tester).items, trip);
        expect(queueOf(tester).currentItem, current);
        await finishHome(tester, env);
      });
    });
  }

  // The add-to-playlist sheet is reached from the Continue watching card menu, which lives in the
  // Home and, with the flag on, in the Home tab.
  for (final host in [PlaylistsHost.flagOff, PlaylistsHost.homeTab]) {
    group(host.label, () {
      Future<void> openSheet(WidgetTester tester) async {
        final menu = inHost(
          host,
          find.descendant(
            of: find.ancestor(of: find.text('Day 1 - Leaving Town.mp4'), matching: find.byType(HomeMediaCard)).first,
            matching: find.byTooltip('More'),
          ),
        );
        await tester.ensureVisible(menu);
        await tester.pump();
        await tester.tap(menu);
        await pumpFrames(tester);
        await tester.tap(find.text('Add to playlist…'));
        await pumpFrames(tester);
      }

      testWidgets('P-4: the add-to-playlist sheet lists every playlist, adds once, reports duplicates', (tester) async {
        final env = await pumpPlaylistsHome(tester, host: host, tree: tree);
        await openSheet(tester);
        expect(find.text('Add to playlist'), findsOneWidget);
        expect(find.text('New playlist…'), findsOneWidget);
        for (final name in ['Road Trip', longPlaylistName, 'Single', 'Empty']) {
          expect(find.text(name), findsWidgets, reason: name);
        }
        await tester.tap(find.text('Empty').last);
        await pumpFrames(tester);
        expect(env.library.getPlaylist('Empty'), [trip.first]);
        expect(find.text('Added to Empty'), findsOneWidget);
        expect(find.text('New playlist…'), findsNothing);
        await waitOutToasts(tester);

        await openSheet(tester);
        await tester.tap(find.text('Road Trip').last);
        await pumpFrames(tester);
        expect(env.library.getPlaylist('Road Trip'), trip);
        expect(find.text('Already in Road Trip'), findsOneWidget);
        await finishHome(tester, env);
      });

      testWidgets('P-4: New playlist… in the sheet creates the playlist and adds the video', (tester) async {
        final calls = PlaylistCalls();
        final env = await pumpPlaylistsHome(tester, host: host, tree: tree, calls: calls);
        await openSheet(tester);
        await tester.tap(find.text('New playlist…'));
        await pumpFrames(tester);
        await _enterName(tester, 'Later', 'Create');
        expect(env.library.getPlaylist('Later'), [trip.first]);
        expect(find.text('Added to Later'), findsOneWidget);
        // The sheet adds and closes; it never navigates to the new playlist.
        expect(calls.opened, isEmpty);
        expect(find.text('New playlist…'), findsNothing);
        await finishHome(tester, env);
      });
    });
  }

  for (final on in [false, true]) {
    group('playlist screen, ${on ? 'flag on' : 'flag off'}', () {
      List<String> titles(WidgetTester tester) => [
            for (final row in tester.widgetList<DanaviewLibraryRow>(find.byType(DanaviewLibraryRow))) row.title,
          ];

      testWidgets('P-4: Play and Shuffle queue the playlist; Play from here starts at the row', (tester) async {
        final calls = PlaylistCalls();
        final env = await pumpPlaylistScreen(tester, filesHome: on, tree: tree, calls: calls);
        expect(find.text('Playlist · 4 videos'), findsOneWidget);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Play'));
        await pumpFrames(tester);
        expect(calls.playerOpens, 1);
        expect(queueOf(tester).items, trip);
        expect(queueOf(tester).currentIndex, 0);

        await tester.tap(find.widgetWithText(DanaviewButton, 'Shuffle'));
        await pumpFrames(tester);
        expect(calls.playerOpens, 2);
        expect(queueOf(tester).isShuffled, isTrue);
        expect(queueOf(tester).items.toSet(), trip.toSet());
        expect(queueOf(tester).unShuffledItems, trip);

        await tester.tap(find.byTooltip('More').at(2));
        await pumpFrames(tester);
        await tester.tap(find.text('Play from here'));
        await pumpFrames(tester);
        expect(calls.playerOpens, 3);
        expect(queueOf(tester).items, trip);
        expect(queueOf(tester).currentItem, trip[2]);
        expect(queueOf(tester).isShuffled, isFalse);
        await finishHome(tester, env);
      });

      testWidgets('P-4: missing entries are skipped by Play and refused with a toast', (tester) async {
        final calls = PlaylistCalls();
        final env = await pumpPlaylistScreen(tester, filesHome: on, tree: tree, calls: calls, name: longPlaylistName);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Play'));
        await pumpFrames(tester);
        expect(queueOf(tester).items, trip.take(3).toList());
        await tester.scrollUntilVisible(find.text('Missing Movie.mp4'), 200, scrollable: find.byType(Scrollable).first);
        await tester.tap(find.text('Missing Movie.mp4'));
        await pumpFrames(tester);
        expect(find.textContaining("isn't available anymore"), findsOneWidget);
        expect(calls.playerOpens, 1);
        await finishHome(tester, env);
      });

      testWidgets('P-4: drag the handle to reorder; the order is stored', (tester) async {
        final env = await pumpPlaylistScreen(tester, filesHome: on, tree: tree);
        expect(titles(tester), [for (final m in trip) m.title]);
        final handle = find.byIcon(Icons.drag_indicator_rounded).first;
        final rowHeight = tester.getSize(find.byType(DanaviewLibraryRow).first).height;
        final gesture = await tester.startGesture(tester.getCenter(handle));
        await tester.pump(const Duration(milliseconds: 50));
        for (var i = 0; i < 10; i++) {
          await gesture.moveBy(Offset(0, rowHeight * 0.25));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        await pumpFrames(tester, count: 8);
        final moved = [trip[1], trip[2], trip[0], trip[3]];
        expect(env.library.getPlaylist('Road Trip'), moved);
        expect(titles(tester), [for (final m in moved) m.title]);
        expect(tester.takeException(), isNull);
        await finishHome(tester, env);
      });

      testWidgets('P-4: Remove from playlist, rename and delete from the options menu', (tester) async {
        final calls = PlaylistCalls();
        final env = await pumpPlaylistScreen(tester, filesHome: on, tree: tree, calls: calls);
        await tester.tap(find.byTooltip('More').at(1));
        await pumpFrames(tester);
        await tester.tap(find.text('Remove from playlist'));
        await pumpFrames(tester);
        expect(env.library.getPlaylist('Road Trip'), [trip[0], trip[2], trip[3]]);
        expect(find.text('Playlist · 3 videos'), findsOneWidget);

        await tester.tap(find.byTooltip('Playlist options'));
        await pumpFrames(tester);
        await tester.tap(find.text('Rename'));
        await pumpFrames(tester);
        await _enterName(tester, 'Coast', 'Rename');
        expect(calls.renamed, ['Coast']);
        expect(find.text('Coast'), findsOneWidget);
        expect(env.library.getPlaylist('Coast'), [trip[0], trip[2], trip[3]]);

        await tester.tap(find.byTooltip('Playlist options'));
        await pumpFrames(tester);
        await tester.tap(find.text('Delete playlist'));
        await pumpFrames(tester);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Delete'));
        await pumpFrames(tester);
        expect(calls.backs, 1);
        expect(env.library.getSavedPlaylistNames(), isNot(contains('Coast')));
        expect(find.text('Deleted "Coast"'), findsOneWidget);
        await finishHome(tester, env);
      });

      testWidgets('P-4: an empty playlist offers Add videos and Add link; a link is added', (tester) async {
        final env = await pumpPlaylistScreen(tester, filesHome: on, tree: tree, name: 'Empty');
        expect(find.text('This playlist is empty'), findsOneWidget);
        expect(find.widgetWithText(DanaviewButton, 'Add videos'), findsOneWidget);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Add link'));
        await pumpFrames(tester);
        const link = 'https://streaming.example.com/live/channel/master.m3u8';
        await tester.enterText(find.byType(EditableText), link);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Add'));
        await pumpFrames(tester);
        expect(env.library.getPlaylist('Empty'), [MediaUrl.tryParse(link)!]);
        expect(find.text('Playlist · 1 video'), findsOneWidget);
        await finishHome(tester, env);
      });

      testWidgets('P-6: auto-advance and repeat Off / All / One over a played playlist', (tester) async {
        final env = await pumpPlaylistScreen(tester, filesHome: on, tree: tree);
        final queue = queueControllerOf(tester);
        // The current file plays to its end (a playing snapshot, then ended, as mpv reports it).
        Future<void> end() async {
          env.engine.emitMockSnapshot(const PlayerSnapshot(
            status: PlaybackStatus.playing,
            position: Duration(minutes: 9),
            duration: Duration(minutes: 10),
          ));
          await pumpFrames(tester, count: 1);
          env.engine.emitMockSnapshot(const PlayerSnapshot(
            status: PlaybackStatus.ended,
            position: Duration(minutes: 10),
            duration: Duration(minutes: 10),
          ));
          await pumpFrames(tester, count: 2);
        }

        await tester.tap(find.byTooltip('More').at(2));
        await pumpFrames(tester);
        await tester.tap(find.text('Play from here'));
        await pumpFrames(tester);
        expect(queueOf(tester).currentItem, trip[2]);
        expect(queueOf(tester).repeatMode, RepeatMode.off);

        // Off: next-up auto-advance, then stop at the end.
        await end();
        expect(queueOf(tester).currentItem, trip[3]);
        expect(queueOf(tester).hasNext, isFalse);
        await end();
        expect(queueOf(tester).currentItem, trip[3]);

        // The repeat button cycles Off → All → One → Off.
        queue.cycleRepeatMode();
        expect(queueOf(tester).repeatMode, RepeatMode.all);
        await end();
        expect(queueOf(tester).currentItem, trip[0]);

        queue.cycleRepeatMode();
        expect(queueOf(tester).repeatMode, RepeatMode.one);
        await end();
        expect(queueOf(tester).currentItem, trip[0]);
        expect(env.engine.currentSnapshot.status, PlaybackStatus.playing);
        expect(env.engine.currentSnapshot.position, Duration.zero);
        // A user Next still moves on under repeat one.
        await queue.next();
        await pumpFrames(tester, count: 2);
        expect(queueOf(tester).currentItem, trip[1]);

        queue.cycleRepeatMode();
        expect(queueOf(tester).repeatMode, RepeatMode.off);
        await finishHome(tester, env);
      });

      testWidgets('P-6: queue reorder and Play next keep the current item; shuffle off restores', (tester) async {
        final env = await pumpPlaylistScreen(tester, filesHome: on, tree: tree);
        final queue = queueControllerOf(tester);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Play'));
        await pumpFrames(tester);
        await queue.move(3, 0);
        expect(queueOf(tester).items, [trip[3], trip[0], trip[1], trip[2]]);
        expect(queueOf(tester).currentItem, trip[0]);
        await queue.playNext(soloRef(tree));
        expect(queueOf(tester).nextItem, soloRef(tree));

        queue.setShuffle(true);
        expect(queueOf(tester).currentItem, trip[0]);
        expect(queueOf(tester).currentIndex, 0);
        await queue.addToQueue([missingRef]);
        queue.setShuffle(false);
        expect(queueOf(tester).items, [trip[3], trip[0], soloRef(tree), trip[1], trip[2], missingRef]);
        expect(queueOf(tester).currentItem, trip[0]);
        await finishHome(tester, env);
      });
    });
  }
}
