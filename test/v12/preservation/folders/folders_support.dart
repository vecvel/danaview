// OWNER: HOM-08
// EXTENDED: Home four tabs (with the flag on the Folders list is the Folders screen, pushed by the
// Home tab's Folders "See all", DESIGN_SYSTEM §10.4)
//
// Shared fixtures of the folder preservation tests (BUILD_PLAN HOM-08; FILES_MEDIA_HOME_PLAN
// P-5, P-8): a media tree on disk whose names only sort right naturally (`Clip 2` before
// `Clip 10`), a phone "device storage" folder, the places the 1.1 Folders section lives (the
// Home with DANAVIEW_FILES_HOME off, the `Home` tab and the Folders screen with it on), pump
// helpers for the Home, the folder screen and the whole app (for drag-and-drop and `danaview://`
// links), and a fake of the desktop_drop channel that delivers a drop the way the native side does.

import 'dart:io';

import 'package:danaview/app.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/library_widgets.dart' show DanaviewLibraryRow;
import 'package:danaview_features/src/library/tabs/folders_tab.dart' show FoldersTab;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../library_test_utils.dart';
import '../../home_shell/home_shell_support.dart';

export '../../home_shell/home_shell_support.dart' show finishHome, useFilesHome;

/// Where the 1.1 Folders section is shown.
enum FoldersHost {
  /// DANAVIEW_FILES_HOME off: the 1.1 Home list.
  flagOff('flag off'),

  /// DANAVIEW_FILES_HOME on: the `Home` tab (Overview).
  homeTab('flag on (Home tab)'),

  /// DANAVIEW_FILES_HOME on: the Folders screen with no body slot (the shell's 1.1 fallback).
  foldersScreen('flag on (Folders screen)'),

  /// DANAVIEW_FILES_HOME on: the Folders screen with HOM-18's [FoldersTab] in its slot, as the
  /// app wires it (`lib/wiring/files_home_wiring.dart`); the 1.1 rows sit under "Linked folders"
  /// (HOM plan §5.2).
  linkedFolders('flag on (Folders screen, Linked folders)');

  const FoldersHost(this.label);

  final String label;

  bool get filesHome => this != FoldersHost.flagOff;

  /// The tab whose page holds the section with the flag on (null: the 1.1 list or the screen).
  HomeTab? get tab => this == FoldersHost.homeTab ? HomeTab.home : null;

  /// Whether the section is on the Folders screen.
  bool get onScreen => this == FoldersHost.foldersScreen || this == FoldersHost.linkedFolders;

  /// The header title this host draws over the 1.1 rows.
  String get headerTitle => this == FoldersHost.linkedFolders ? 'Linked folders' : 'Folders';

  /// The tab bodies this host installs; [calls] receives what the real Folders tab hands out.
  HomeTabSlots slots(FolderCalls calls) => this == FoldersHost.linkedFolders
      ? HomeTabSlots(
          folders: (_) => FoldersTab(onOpenFolder: calls.folders.add, onOpenPlayer: () => calls.playerOpens++),
        )
      : HomeTabSlots.none;
}

/// The label the library root of [createFolderTree] is added under (never the temp path).
const String mediaRootLabel = 'Media';

/// The videos directly in the tree root, in natural order (`.txt` and hidden files skipped).
const List<String> rootVideos = ['Clip 1.mp4', 'Clip 2.mkv', 'Clip 10.mp4'];

/// The subfolders of the tree root, in natural order (the hidden folder skipped).
const List<String> rootFolders = ['Disc 2', 'Disc 10', 'Only Folders'];

/// The videos directly in `Disc 2`, in natural order.
const List<String> disc2Videos = ['Part 1.mp4', 'Part 2.mp4', 'Part 10.mp4'];

/// The videos of the phone's device storage folder, in natural order.
const List<String> deviceVideos = ['Phone 2.mov', 'Phone 10.mp4'];

/// A temp media tree:
///
/// ```
/// Clip 10.mp4  Clip 2.mkv  Clip 1.mp4  notes.txt  .secret.mp4  .hidden/
/// Disc 10/Extra.mp4
/// Disc 2/Part 10.mp4  Part 2.mp4  Part 1.mp4  Bonus/Making Of.mkv
/// Only Folders/Season 1/Show.S01E01.mkv
/// ```
///
/// Files are created in a scrambled order so a passing order proves the sort. Delete it with
/// [Directory.deleteSync].
Directory createFolderTree() {
  final root = Directory.systemTemp.createTempSync('danaview_folders_test_');
  void file(List<String> parts) {
    final f = File(joinPath([root.path, ...parts]));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('x');
  }

  for (final name in ['Clip 10.mp4', 'notes.txt', 'Clip 2.mkv', '.secret.mp4', 'Clip 1.mp4']) {
    file([name]);
  }
  Directory(joinPath([root.path, '.hidden'])).createSync();
  file(['Disc 10', 'Extra.mp4']);
  for (final name in ['Part 10.mp4', 'Part 2.mp4', 'Part 1.mp4']) {
    file(['Disc 2', name]);
  }
  file(['Disc 2', 'Bonus', 'Making Of.mkv']);
  file(['Only Folders', 'Season 1', 'Show.S01E01.mkv']);
  return root;
}

/// A temp "Documents" folder standing in for the phone's device storage, with [deviceVideos].
Directory createDeviceFolder() {
  final dir = Directory.systemTemp.createTempSync('danaview_device_test_');
  for (final name in deviceVideos.reversed) {
    File(joinPath([dir.path, name])).writeAsStringSync('x');
  }
  return dir;
}

/// [names] under [parts] of [root] as the refs 1.1 builds for them.
List<MediaRef> refsIn(Directory root, List<String> parts, List<String> names) => [
      for (final name in names) localRef(joinPath([root.path, ...parts, name])),
    ];

/// A library with mobile storage over [device] (so the device root shows first) when [device] is
/// set, desktop storage otherwise.
Future<LibraryTestEnv> createFoldersEnv({Directory? device}) => LibraryTestEnv.create(
      storage: device == null ? null : LibraryStorage(isMobile: true, documentsDirectory: () async => device),
    );

/// Adds the tree root as [mediaRootLabel] and its `Only Folders` subfolder as a second root.
Future<void> seedFolderRoots(LibraryTestEnv env, Directory tree) async {
  await env.library.addFolder(tree.path, label: mediaRootLabel);
  await env.library.addFolder(joinPath([tree.path, 'Only Folders']));
}

/// Fixed-path roots for the goldens (no temp path is ever drawn in a golden).
Future<void> seedGoldenRoots(LibraryTestEnv env) async {
  await env.library.addFolder('/Volumes/Media/Movies');
  await env.library.addFolder('/Volumes/Media Drive With A Long Name/Collections/$longTitle');
}

/// Counts what the Home hands to its required callbacks.
class FolderCalls {
  int playerOpens = 0;
  final List<String> folders = [];

  DanaviewHomeScreen home({HomeTabSlots tabSlots = HomeTabSlots.none}) => DanaviewHomeScreen(
        onOpenPlayer: () => playerOpens++,
        onOpenFolder: folders.add,
        onOpenPlaylist: (_) {},
        onOpenSettings: () {},
        onOpenEditor: () {},
        tabSlots: tabSlots,
      );
}

/// Real-time wait so disk reads started by the widgets finish.
/// Real disk I/O completes outside the fake clock, one step at a time, so this alternates real
/// waits with frames until each chained read has finished.
Future<void> settleDisk(WidgetTester tester, {int ms = 150}) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms ~/ 10 + 1)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await pumpFrames(tester);
}

/// Installs the Home for [host] over [env] and opens the host's tab. [tabSlots] overrides the
/// host's own slots ([FoldersHost.slots]) when set.
Future<void> pumpFoldersHome(
  WidgetTester tester,
  LibraryTestEnv env, {
  required FoldersHost host,
  FolderCalls? calls,
  TestSurface surface = const TestSurface(Size(402, 1600), 1.0, padding: EdgeInsets.only(top: 47, bottom: 34)),
  TargetPlatform platform = TargetPlatform.iOS,
  HomeTabSlots? tabSlots,
}) async {
  final recorder = calls ?? FolderCalls();
  useFilesHome(host.filesHome);
  useSurface(tester, surface);
  await tester.runAsync(() async {
    await tester.pumpWidget(libraryTestApp(
      env,
      recorder.home(tabSlots: tabSlots ?? host.slots(recorder)),
      textScale: surface.textScale,
      platform: platform,
    ));
  });
  await settleDisk(tester);
  if (host.onScreen) await openFoldersScreen(tester);
  expect(tester.takeException(), isNull);
}

/// The Folders screen.
final Finder foldersScreen = find.byKey(homeDestinationScreenKey(HomeDestination.folders));

/// Opens the Folders screen the way a user does: the Home tab's Folders "See all". Without
/// folders the section is hidden, so the screen is requested the same way See all does.
Future<void> openFoldersScreen(WidgetTester tester) async {
  final seeAll = find.byKey(const ValueKey('home-folders-see-all'));
  if (seeAll.evaluate().isNotEmpty) {
    await tester.ensureVisible(seeAll);
    await tester.pump();
    await tester.tap(seeAll);
  } else {
    const HomeDestinationRequestNotification(HomeDestination.folders)
        .dispatch(tester.element(find.byKey(const ValueKey('home-tab-strip'))));
  }
  await pumpFrames(tester, count: 8);
  await settleDisk(tester);
  expect(foldersScreen, findsOneWidget);
  await repaintGlyphs(tester);
}

/// The part of the tree that holds the host's Folders section.
Finder foldersScope(FoldersHost host) => switch (host) {
      FoldersHost.flagOff => find.byType(DanaviewHomeScreen),
      FoldersHost.homeTab => find.byKey(const ValueKey('home-tab-page-home')),
      FoldersHost.foldersScreen || FoldersHost.linkedFolders => foldersScreen,
    };

Finder _private(String type) => find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

/// The scroll view holding the Folders section.
Finder foldersScrollable(FoldersHost host) =>
    find.descendant(of: foldersScope(host), matching: find.byType(Scrollable)).first;

/// The section header of the host's Folders section: `Folders` (1.1) or `Linked folders` (the
/// Folders tab once HOM-18 supplies it).
Finder foldersHeader(FoldersHost host) => find
    .ancestor(
      of: find.descendant(of: foldersScope(host), matching: find.textContaining(RegExp(r'^(Linked folders|Folders)$'))),
      matching: _private('DanaviewLibrarySectionHeader'),
    )
    .first;

/// The group of folder rows, found by one of its row titles.
Finder foldersGroup(FoldersHost host, String rowTitle) => find
    .ancestor(
      of: find.descendant(of: foldersScope(host), matching: find.text(rowTitle)),
      matching: _private('DanaviewLibraryCardGrid'),
    )
    .first;

/// The row titled [title] in the host's section.
Finder folderRow(FoldersHost host, String title) => find
    .ancestor(
      of: find.descendant(of: foldersScope(host), matching: find.text(title)),
      matching: find.byType(DanaviewLibraryRow),
    )
    .first;

/// The `More` trigger of the row titled [title].
Finder folderRowMenu(FoldersHost host, String title) =>
    find.descendant(of: folderRow(host, title), matching: find.byTooltip('More'));

/// Row titles of the group holding [anyTitle], top to bottom.
List<String> rowTitles(WidgetTester tester, Finder group) => [
      for (final row in find.descendant(of: group, matching: find.byType(DanaviewLibraryRow)).evaluate())
        (row.widget as DanaviewLibraryRow).title,
    ];

/// Scrolls the host's page until [finder] is visible.
Future<void> scrollToFolders(WidgetTester tester, FoldersHost host, Finder finder) async {
  await tester.scrollUntilVisible(finder, 300, scrollable: foldersScrollable(host));
  await tester.pump();
}

/// The queue the player was handed last, read through any widget under the app's scope.
QueueState queueOf(WidgetTester tester, Type under) =>
    ProviderScope.containerOf(tester.element(find.byType(under, skipOffstage: false).first))
        .read(queueControllerProvider);

/// Installs [DanaviewFolderScreen] on [path] with DANAVIEW_FILES_HOME = [filesHome]; records
/// opened and jumped-to folders and player opens in [log].
Future<void> pumpFolderScreen(
  WidgetTester tester,
  LibraryTestEnv env, {
  required bool filesHome,
  required String path,
  required FolderScreenLog log,
  TestSurface surface = const TestSurface(Size(402, 874), 1.0, padding: EdgeInsets.only(top: 47, bottom: 34)),
  TargetPlatform platform = TargetPlatform.iOS,
}) async {
  useFilesHome(filesHome);
  useSurface(tester, surface);
  await tester.runAsync(() async {
    await tester.pumpWidget(libraryTestApp(
      env,
      DanaviewFolderScreen(
        key: ValueKey(path),
        path: path,
        onBack: () => log.backs++,
        onOpenFolder: log.opened.add,
        onJumpToFolder: log.jumped.add,
        onOpenPlayer: () => log.playerOpens++,
      ),
      textScale: surface.textScale,
      platform: platform,
    ));
  });
  await settleDisk(tester);
  expect(tester.takeException(), isNull);
}

/// What the folder screen handed to its callbacks.
class FolderScreenLog {
  int backs = 0;
  int playerOpens = 0;
  final List<String> opened = [];
  final List<String> jumped = [];
}

// ---- The whole app (P-8) ----

/// The app with a fake engine over a fresh library, DANAVIEW_FILES_HOME = [filesHome].
Future<(FakePlaybackEngine, LibraryRepository)> pumpFoldersApp(WidgetTester tester, {required bool filesHome}) async {
  useFilesHome(filesHome);
  useSurface(tester, const TestSurface(Size(1280, 800), 1.0));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final engine = FakePlaybackEngine();
  await engine.initialize();
  final library = LibraryRepository(prefs, storage: LibraryStorage(isMobile: false));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      playbackEngineProvider.overrideWithValue(engine),
      sessionRepositoryProvider.overrideWithValue(SessionRepository(prefs)),
      libraryRepositoryProvider.overrideWithValue(library),
    ],
    child: const DanaviewApp(),
  ));
  await pumpFrames(tester, count: 10);
  return (engine, library);
}

/// Unmounts the app and disposes [engine].
Future<void> finishApp(WidgetTester tester, FakePlaybackEngine engine) async {
  DanaviewToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await engine.dispose();
}

/// The media the player has loaded, or null when the player is not on screen.
MediaRef? playerMedia(WidgetTester tester) {
  final player = find.byType(DanaviewPlayerScreen);
  if (player.evaluate().isEmpty) return null;
  return ProviderScope.containerOf(tester.element(player)).read(playerControllerProvider).currentMediaRef;
}

/// Delivers a drag of [paths] entering at [at] and dropping there, exactly as the desktop_drop
/// native side sends it (`entered`, then `performOperation`), then lets the disk reads finish.
Future<void> dropPaths(WidgetTester tester, List<String> paths, {Offset at = const Offset(640, 400)}) async {
  const codec = StandardMethodCodec();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> send(String method, Object arguments) =>
      messenger.handlePlatformMessage('desktop_drop', codec.encodeMethodCall(MethodCall(method, arguments)), (_) {});
  await send('entered', [at.dx, at.dy]);
  await tester.pump();
  await send('performOperation', paths);
  await settleDisk(tester, ms: 250);
}
