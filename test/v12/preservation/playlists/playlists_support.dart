// OWNER: HOM-07
//
// Shared fixtures of the playlist preservation tests (BUILD_PLAN HOM-07; FILES_MEDIA_HOME_PLAN
// P-4, P-6): a media tree whose playlist entries exist on disk under fixed folder names (so no
// temp path is ever drawn), a library seeded with playlists and a short history (for the
// add-to-playlist sheet), and pump helpers for the three places the 1.1 Playlists section lives:
// the Home with DANAVIEW_FILES_HOME off, the `Home` tab with it on, and the `Playlists` tab with it
// on. The playlist screen itself is pumped by [pumpPlaylistScreen] under either flag value.

import 'dart:io';

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/library_widgets.dart' show DanaviewLibraryRow;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../library_test_utils.dart';
import '../../home_shell/home_shell_support.dart';

export '../../home_shell/home_shell_support.dart' show finishHome, useFilesHome;

/// Where the 1.1 Playlists section is shown.
enum PlaylistsHost {
  /// DANAVIEW_FILES_HOME off: the 1.1 Home list.
  flagOff('flag off'),

  /// DANAVIEW_FILES_HOME on: the `Home` tab (Overview).
  homeTab('flag on (Home tab)'),

  /// DANAVIEW_FILES_HOME on: the `Playlists` tab.
  playlistsTab('flag on (Playlists tab)');

  const PlaylistsHost(this.label);

  final String label;

  bool get filesHome => this != PlaylistsHost.flagOff;

  /// The tab whose page holds the section with the flag on.
  HomeTab? get tab => switch (this) {
        PlaylistsHost.flagOff => null,
        PlaylistsHost.homeTab => HomeTab.home,
        PlaylistsHost.playlistsTab => HomeTab.playlists,
      };
}

/// The name of the long-titled playlist used by the overflow and golden checks.
const String longPlaylistName = 'Weekend Anime Marathon With An Absurdly Long Playlist Name';

/// The videos of the `Road Trip` playlist, in playlist order.
const List<String> roadTripFiles = [
  'Day 1 - Leaving Town.mp4',
  'Day 2 - Mountain Pass.mkv',
  'Day 3 - Coast Road.mp4',
  'Day 4 - $longTitle.mkv',
];

/// A temp media tree with the `Road Trip` videos and a `Single` video, each in a folder with a
/// fixed name. Delete it with [Directory.deleteSync].
Directory createPlaylistTree() {
  final root = Directory.systemTemp.createTempSync('danaview_playlists_test_');
  final trip = Directory(joinPath([root.path, 'Trip Footage']))..createSync();
  for (final name in roadTripFiles) {
    File(joinPath([trip.path, name])).writeAsStringSync('x');
  }
  final misc = Directory(joinPath([root.path, 'Misc']))..createSync();
  File(joinPath([misc.path, 'Solo Clip.mp4'])).writeAsStringSync('x');
  return root;
}

/// The `Road Trip` playlist items, in order.
List<MediaRef> roadTripRefs(Directory tree) => [
      for (final name in roadTripFiles) localRef(joinPath([tree.path, 'Trip Footage', name])),
    ];

/// The one item of the `Single` playlist.
MediaRef soloRef(Directory tree) => localRef(joinPath([tree.path, 'Misc', 'Solo Clip.mp4']));

/// A playlist entry whose file is gone.
final MediaRef missingRef = localRef('/Volumes/Gone/Missing Movie.mp4');

/// Playlists, in creation order: `Road Trip` (four videos on disk), the long-named one (three
/// videos plus a missing one), `Single` (one video) and `Empty`; a history of two entries (the
/// solo clip, then the first Road Trip video) so the Home has a Continue watching section.
Future<void> seedPlaylists(LibraryTestEnv env, Directory tree) async {
  final trip = roadTripRefs(tree);
  for (final name in ['Road Trip', longPlaylistName, 'Single', 'Empty']) {
    await env.library.createPlaylist(name);
  }
  await env.library.addToPlaylist('Road Trip', trip);
  await env.library.addToPlaylist(longPlaylistName, [...trip.take(3), missingRef]);
  await env.library.addToPlaylist('Single', [soloRef(tree)]);
  await env.library.recordPlayed(soloRef(tree));
  await env.library.recordPlayed(trip.first);
}

/// Counts what the Home and the playlist screen hand to their callbacks.
class PlaylistCalls {
  int playerOpens = 0;
  int backs = 0;
  final List<String> opened = [];
  final List<String> renamed = [];

  DanaviewHomeScreen home() => DanaviewHomeScreen(
        onOpenPlayer: () => playerOpens++,
        onOpenFolder: (_) {},
        onOpenPlaylist: opened.add,
        onOpenSettings: () {},
        onOpenEditor: () {},
      );

  DanaviewPlaylistScreen screen(String name) => DanaviewPlaylistScreen(
        name: name,
        onBack: () => backs++,
        onOpenPlayer: () => playerOpens++,
        onRenamed: renamed.add,
      );
}

const TestSurface defaultPlaylistSurface =
    TestSurface(Size(402, 1600), 1.0, padding: EdgeInsets.only(top: 47, bottom: 34));

/// Installs the Home for [host] over a seeded library and, with the flag on, selects its tab by
/// tapping it the way a user does.
Future<LibraryTestEnv> pumpPlaylistsHome(
  WidgetTester tester, {
  required PlaylistsHost host,
  required Directory tree,
  PlaylistCalls? calls,
  TestSurface surface = defaultPlaylistSurface,
  bool seed = true,
}) async {
  useFilesHome(host.filesHome);
  useSurface(tester, surface);
  final env = await LibraryTestEnv.create();
  if (seed) await seedPlaylists(env, tree);
  await tester.pumpWidget(libraryTestApp(env, (calls ?? PlaylistCalls()).home(), textScale: surface.textScale));
  await pumpFrames(tester);
  if (host == PlaylistsHost.playlistsTab) await tapHomeTab(tester, HomeTab.playlists);
  expect(tester.takeException(), isNull);
  return env;
}

/// Installs the playlist screen of [name] with DANAVIEW_FILES_HOME = [filesHome].
Future<LibraryTestEnv> pumpPlaylistScreen(
  WidgetTester tester, {
  required bool filesHome,
  required Directory tree,
  String name = 'Road Trip',
  PlaylistCalls? calls,
  TestSurface surface = defaultPlaylistSurface,
}) async {
  useFilesHome(filesHome);
  useSurface(tester, surface);
  final env = await LibraryTestEnv.create();
  await seedPlaylists(env, tree);
  await tester.pumpWidget(libraryTestApp(env, (calls ?? PlaylistCalls()).screen(name), textScale: surface.textScale));
  await pumpFrames(tester);
  expect(tester.takeException(), isNull);
  return env;
}

Future<void> tapHomeTab(WidgetTester tester, HomeTab tab) async {
  final finder = find.byKey(homeTabKey(tab));
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder);
  await pumpFrames(tester, count: 4);
}

ProviderContainer playlistsContainer(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byWidgetPredicate((w) => w is DanaviewHomeScreen || w is DanaviewPlaylistScreen)),
    );

/// The player queue.
QueueState queueOf(WidgetTester tester) => playlistsContainer(tester).read(queueControllerProvider);

QueueController queueControllerOf(WidgetTester tester) =>
    playlistsContainer(tester).read(queueControllerProvider.notifier);

/// The scroll view holding the Playlists section for [host].
Finder playlistsScrollable(PlaylistsHost host) => switch (host.tab) {
      null => find.byType(Scrollable).first,
      final tab =>
        find.descendant(of: find.byKey(ValueKey('home-tab-page-${tab.name}')), matching: find.byType(Scrollable)).first,
    };

/// Restricts [finder] to the page of [host] (with the flag on, other tab pages stay mounted).
Finder inHost(PlaylistsHost host, Finder finder) => switch (host.tab) {
      null => finder,
      final tab => find.descendant(of: find.byKey(ValueKey('home-tab-page-${tab.name}')), matching: finder),
    };

Finder _private(String type) => find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

/// P-4: the Playlists section header (title and New button).
Finder playlistsHeader(PlaylistsHost host) => inHost(
      host,
      find.ancestor(of: find.text('Playlists'), matching: _private('DanaviewLibrarySectionHeader')),
    ).first;

/// P-4: the group of playlist rows: the grouped list on the Home, the card grid on the Playlists
/// tab (DESIGN_SYSTEM §10.4: a grid of playlist cards).
Finder playlistsGroup(PlaylistsHost host) => host == PlaylistsHost.playlistsTab
    ? inHost(host, find.byKey(const ValueKey('home-playlists-grid'))).first
    : inHost(
        host,
        find.ancestor(of: find.text('Road Trip'), matching: _private('DanaviewLibraryCardGrid')),
      ).first;

/// The widget type of one playlist in [host]: a grouped-list row, or a card on the Playlists tab.
Type playlistItemType(PlaylistsHost host) =>
    host == PlaylistsHost.playlistsTab ? HomePlaylistCard : DanaviewLibraryRow;

/// The playlists shown in [host], in order, as (title, subtitle).
List<(String, String?)> playlistItems(WidgetTester tester, PlaylistsHost host) => [
      for (final w in tester.widgetList(find.descendant(of: playlistsGroup(host), matching: find.byType(playlistItemType(host)))))
        switch (w) {
          HomePlaylistCard(:final name, :final subtitle) => (name, subtitle),
          DanaviewLibraryRow(:final title, :final subtitle) => (title, subtitle),
          _ => throw StateError('unexpected $w'),
        },
    ];

/// P-4: the empty state shown when there are no playlists.
Finder playlistsEmpty(PlaylistsHost host) => inHost(
      host,
      find.ancestor(of: find.text('No playlists yet'), matching: _private('DanaviewInlineEmpty')),
    ).first;

/// The `More` menu of the playlist row titled [name].
Finder playlistMenu(PlaylistsHost host, String name) => inHost(
      host,
      find.descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(playlistItemType(host))).first,
        matching: find.byTooltip('More'),
      ),
    );

/// Scrolls [finder] into view inside [host].
Future<void> scrollToInHost(WidgetTester tester, PlaylistsHost host, Finder finder) async {
  await tester.scrollUntilVisible(finder, 300, scrollable: playlistsScrollable(host));
  await tester.pump();
}

/// Opens the row menu of playlist [name] and taps [item].
Future<void> playlistMenuAction(WidgetTester tester, PlaylistsHost host, String name, String item) async {
  final menu = playlistMenu(host, name);
  await scrollToInHost(tester, host, menu);
  await tester.tap(menu);
  await pumpFrames(tester);
  await tester.tap(find.text(item).last);
  await pumpFrames(tester);
}

/// Lets toasts time out so the next one is the only one on screen.
Future<void> waitOutToasts(WidgetTester tester) => tester.pump(const Duration(seconds: 4));
