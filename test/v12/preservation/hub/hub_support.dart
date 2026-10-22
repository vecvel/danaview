// OWNER: HOM-06
//
// Shared fixtures of the hub preservation tests (BUILD_PLAN HOM-06; FILES_MEDIA_HOME_PLAN P-1,
// P-2, P-3, P-7): a library whose Continue watching rows exist on disk (so taps play, progress
// bars and episode badges show) with fixed file names, a pump helper for the Home with
// DANAVIEW_FILES_HOME off or on, the finders of the 1.1 hub sections in either layout, and a fake
// of the file_selector channel for Open file / Open folder.

import 'dart:io';

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../library_test_utils.dart';
import '../../home_shell/home_shell_support.dart';

export '../../home_shell/home_shell_support.dart' show finishHome, useFilesHome;

/// The stream the Now Playing card shows in the goldens and the return-to-player test.
final MediaRef hubStream = remoteRef('https://streaming.example.com/live/channel/master.m3u8');

/// Every network protocol of P-7 as the user would type it in the Open link dialog, plus a
/// `file://` link. Each must open with exactly the [MediaRef] 1.1 parses from it.
const List<String> hubProtocolLinks = [
  'http://media.example.com/movies/feature.mp4',
  'https://streaming.example.com/live/channel/master.m3u8',
  'rtsp://camera.example.com:554/stream1',
  'rtmp://live.example.com/app/stream-key',
  'srt://ingest.example.com:9000',
  'udp://239.0.0.1:1234',
  'rtp://239.0.0.2:5004',
  'mms://broadcast.example.com/live',
  'file:///Volumes/Media/Movies/clip.mp4',
];

/// A temp media tree with eight episodes under `Season 1` (fixed names, so no temp path is ever
/// drawn in the hub sections). Delete it with [Directory.deleteSync].
Directory createHubTree() {
  final root = Directory.systemTemp.createTempSync('danaview_hub_test_');
  final season = Directory(joinPath([root.path, 'Season 1']))..createSync();
  for (var i = 1; i <= 8; i++) {
    File(joinPath([season.path, 'Show.S01E0$i.$longTitle.mkv'])).writeAsStringSync('x');
  }
  return root;
}

/// The Continue watching history of [seedHub], most recent first.
List<MediaRef> hubHistory(Directory tree) => [
      for (var i = 1; i <= 8; i++) localRef(joinPath([tree.path, 'Season 1', 'Show.S01E0$i.$longTitle.mkv'])),
      hubStream,
      localRef('/Volumes/Gone/Missing Movie.mp4'),
    ];

/// History of ten (eight episodes on disk, a stream, a missing file), resume points on the first
/// four, and the playlists `Docs` and `Empty`.
Future<void> seedHub(LibraryTestEnv env, Directory tree) async {
  final history = hubHistory(tree);
  for (final media in history.reversed) {
    await env.library.recordPlayed(media);
  }
  for (var i = 0; i < 4; i++) {
    await env.session.saveResumePosition(history[i].id, Duration(minutes: 5 + i * 7), const Duration(minutes: 52));
  }
  for (final name in ['Docs', 'Empty']) {
    await env.library.createPlaylist(name);
  }
  await env.library.addToPlaylist('Docs', history.take(2).toList());
}

/// Counts what the Home hands to its required callbacks.
class HubCalls {
  int playerOpens = 0;
  final List<String> folders = [];
  final List<String> playlists = [];

  DanaviewHomeScreen home() => DanaviewHomeScreen(
        onOpenPlayer: () => playerOpens++,
        onOpenFolder: folders.add,
        onOpenPlaylist: playlists.add,
        onOpenSettings: () {},
        onOpenEditor: () {},
      );
}

/// Installs the Home with DANAVIEW_FILES_HOME = [filesHome] over a seeded library.
Future<LibraryTestEnv> pumpHub(
  WidgetTester tester, {
  required bool filesHome,
  required Directory tree,
  HubCalls? calls,
  TestSurface surface = const TestSurface(Size(402, 1600), 1.0, padding: EdgeInsets.only(top: 47, bottom: 34)),
  bool seed = true,
}) async {
  useFilesHome(filesHome);
  useSurface(tester, surface);
  final env = await LibraryTestEnv.create();
  if (seed) await seedHub(env, tree);
  await tester.pumpWidget(libraryTestApp(env, (calls ?? HubCalls()).home(), textScale: surface.textScale));
  await pumpFrames(tester);
  expect(tester.takeException(), isNull);
  return env;
}

ProviderContainer hubContainer(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DanaviewHomeScreen)));

/// The queue the player was handed last.
List<MediaRef> hubQueue(WidgetTester tester) => hubContainer(tester).read(queueControllerProvider).items;

/// Starts [media] in the player the way any 1.1 entry point does, so the Now Playing card shows.
Future<void> startPlaying(WidgetTester tester, MediaRef media) async {
  await hubContainer(tester).read(queueControllerProvider.notifier).playFrom([media]);
  await pumpFrames(tester);
}

/// The scroll view holding the hub sections: the only list with the flag off, the Home tab's
/// page with it on.
Finder hubScrollable({required bool filesHome}) => filesHome
    ? find.descendant(of: find.byKey(const ValueKey('home-tab-page-home')), matching: find.byType(Scrollable)).first
    : find.byType(Scrollable).first;

Finder _private(String type) => find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

/// P-1: the Now Playing card.
Finder get nowPlayingCard => _private('_NowPlayingCard');

/// P-3: the quick actions row.
Finder get quickActions => _private('_QuickActions');

/// P-2: the Continue watching header, rows and Show all button.
Finder get continueWatchingHeader =>
    find.ancestor(of: find.text('Continue watching'), matching: _private('DanaviewLibrarySectionHeader'));

Finder get continueWatchingRows => find
    .ancestor(of: find.textContaining('Show.S01E01'), matching: _private('DanaviewLibraryGroup'))
    .first;

/// The Show all N / Show less button.
Finder get showAllButton => find
    .ancestor(of: find.textContaining(RegExp(r'^Show (all \d+|less)$')), matching: find.byType(DanaviewButton))
    .first;

/// The `More` menu trigger of the Continue watching row [index].
Finder recentMenu(int index) =>
    find.descendant(of: continueWatchingRows, matching: find.byTooltip('More')).at(index);

/// Answers the file_selector method channel: `openFile` returns [files], `getDirectoryPath`
/// returns [directory]. Cleared at the end of the test.
void fakeFileSelector({List<String> files = const [], String? directory}) {
  const channel = MethodChannel('plugins.flutter.io/file_selector');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    return switch (call.method) {
      // MethodChannelFileSelector.openFiles sends `openFile` with multiple: true.
      'openFile' when (call.arguments as Map?)?['multiple'] == true => files,
      'openFile' => files.isEmpty ? null : files.first,
      'openFiles' => files,
      'getDirectoryPath' => directory,
      _ => null,
    };
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}
