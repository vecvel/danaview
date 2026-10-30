// OWNER: HOM-08
//
// BUILD_PLAN HOM-08 (FILES_MEDIA_HOME_PLAN P-5, P-8; ARCH v1.2 V2-32, G-R2): linked folders behave
// exactly as in 1.1 with DANAVIEW_FILES_HOME off, in the `Home` tab with it on, and on the Folders
// screen with it on (the Home tab's Folders "See all"): the device storage root first, user-added
// folders, their menu (Open, Play all, Remove from library), the folder screen (natural sort,
// breadcrumbs, Play all, Shuffle, Add to queue, Play next), desktop drag-and-drop onto the player
// and `danaview://` links. Each script runs under every host and must produce the same transcript,
// and the 1.1 values themselves are pinned once.

import 'dart:io';

import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/library_widgets.dart' show DanaviewLibraryRow;
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../library_test_utils.dart';
import 'folders_support.dart';

const String _onlyFolders = 'Only Folders';

Future<void> _menu(WidgetTester tester, FoldersHost host, String row, String item) async {
  await scrollToFolders(tester, host, folderRowMenu(host, row));
  await tester.tap(folderRowMenu(host, row));
  await pumpFrames(tester);
  await tester.tap(find.text(item).last);
  await pumpFrames(tester);
}

List<Object?> _queue(QueueState q) => [q.items, q.currentIndex, q.isShuffled];

/// The Home's Folders section script for [host]; returns what reached the callbacks, the player,
/// the library and the disk.
Future<List<Object?>> _homeScript(WidgetTester tester, Directory tree, Directory device, FoldersHost host) async {
  final env = await createFoldersEnv(device: device);
  await seedFolderRoots(env, tree);
  final calls = FolderCalls();
  await pumpFoldersHome(tester, env, host: host, calls: calls);
  final log = <Object?>[];
  QueueState queue() => queueOf(tester, DanaviewHomeScreen);
  void record(String step) => log.add([step, calls.playerOpens, List.of(calls.folders), _queue(queue())]);

  await scrollToFolders(tester, host, foldersGroup(host, LibraryRepository.deviceFolderLabel));
  log.add(['rows', rowTitles(tester, foldersGroup(host, LibraryRepository.deviceFolderLabel))]);
  log.add([
    'device hint',
    find
        .descendant(of: foldersScope(host), matching: find.text('Files app › On My iPhone › Danaview'))
        .evaluate()
        .length,
  ]);
  log.add(['subtitles', find.descendant(of: foldersScope(host), matching: find.text(tree.path)).evaluate().length]);

  // P-5: the device storage root and a user folder open the folder screen.
  await tester.tap(folderRow(host, LibraryRepository.deviceFolderLabel));
  await pumpFrames(tester);
  record('tap device');
  await tester.tap(folderRow(host, mediaRootLabel));
  await pumpFrames(tester);
  record('tap media');
  // The device root has no menu: it can't be removed.
  log.add([
    'device menu',
    find
        .descendant(of: folderRow(host, LibraryRepository.deviceFolderLabel), matching: find.byTooltip('More'))
        .evaluate()
        .length
  ]);

  // P-5: the folder menu.
  await _menu(tester, host, mediaRootLabel, 'Open');
  record('menu open');
  await _menu(tester, host, mediaRootLabel, 'Play all');
  await settleDisk(tester);
  record('menu play all');
  await _menu(tester, host, _onlyFolders, 'Play all');
  await settleDisk(tester);
  record('play all without direct videos');
  log.add(
      ['toast', find.text('No videos directly in "$_onlyFolders". Open it to browse its folders.').evaluate().length]);
  DanaviewToast.dismiss();
  await pumpFrames(tester);

  await _menu(tester, host, _onlyFolders, 'Remove from library');
  log.add([
    'confirm',
    find.text('"$_onlyFolders" will be removed from Danaview. Your files stay on disk.').evaluate().length
  ]);
  await tester.tap(find.text('Cancel'));
  await pumpFrames(tester);
  log.add(['after cancel', env.library.getFolders().map((f) => f.label).toList()]);
  await _menu(tester, host, _onlyFolders, 'Remove from library');
  await tester.tap(find.widgetWithText(DanaviewButton, 'Remove').last);
  await settleDisk(tester);
  log.add(['after remove', env.library.getFolders().map((f) => f.label).toList()]);
  log.add([
    'on disk',
    Directory(joinPath([tree.path, _onlyFolders, 'Season 1'])).existsSync()
  ]);
  log.add(['rows after remove', rowTitles(tester, foldersGroup(host, LibraryRepository.deviceFolderLabel))]);

  expect(tester.takeException(), isNull);
  await finishHome(tester, env);
  return log;
}

/// The folder screen script; returns the transcript of callbacks, listing order and queue.
Future<List<Object?>> _folderScript(WidgetTester tester, Directory tree, {required bool filesHome}) async {
  final env = await createFoldersEnv();
  await seedFolderRoots(env, tree);
  final screenLog = FolderScreenLog();
  await pumpFolderScreen(tester, env, filesHome: filesHome, path: tree.path, log: screenLog);
  final log = <Object?>[];
  QueueState queue() => queueOf(tester, DanaviewFolderScreen);
  void record(String step) => log.add([step, screenLog.playerOpens, List.of(screenLog.opened), _queue(queue())]);

  final titles = rowTitles(tester, find.byType(DanaviewFolderScreen));
  log.add(['listing', titles]);
  log.add(['title', find.text(mediaRootLabel).evaluate().length]);
  log.add(['summary', find.text('3 folders · 3 videos').evaluate().length]);
  log.add(['counts', find.text('3 videos').evaluate().length, find.text('1 video').evaluate().length]);
  log.add([
    'compact crumbs',
    find.byType(DanaviewButton).evaluate().map((e) => (e.widget as DanaviewButton).label).toList()
  ]);

  Finder more(String title) => find.descendant(
        of: find.ancestor(of: find.text(title), matching: find.byType(DanaviewLibraryRow)).first,
        matching: find.byTooltip('More'),
      );
  Future<void> menu(String title, String item) async {
    await tester.tap(more(title));
    await pumpFrames(tester);
    await tester.tap(find.text(item).last);
    await pumpFrames(tester);
  }

  // Add to queue / Play next with nothing queued just play (1.1).
  await menu('Clip 2.mkv', 'Add to queue');
  record('add to queue idle');
  await menu('Clip 10.mp4', 'Play next');
  record('play next');
  log.add(['toast next', find.text('Playing next').evaluate().length]);
  DanaviewToast.dismiss();
  await pumpFrames(tester);
  await menu('Clip 1.mp4', 'Add to queue');
  record('add to queue');
  log.add(['toast queue', find.text('Added to queue').evaluate().length]);
  DanaviewToast.dismiss();
  await pumpFrames(tester);

  await tester.tap(find.widgetWithText(DanaviewButton, 'Play all'));
  await pumpFrames(tester);
  record('play all');
  await tester.tap(find.widgetWithText(DanaviewButton, 'Shuffle'));
  await pumpFrames(tester);
  final shuffled = queue();
  log.add([
    'shuffle',
    screenLog.playerOpens,
    shuffled.isShuffled,
    shuffled.unShuffledItems,
    shuffled.items.map((m) => m.id).toSet(),
  ]);
  await tester.tap(find.text('Clip 2.mkv'));
  await pumpFrames(tester);
  record('tap row');
  await tester.tap(find.text('Disc 2'));
  await pumpFrames(tester);
  record('tap folder');
  await tester.tap(find.byTooltip('Back').first);
  log.add(['back', screenLog.backs]);

  expect(tester.takeException(), isNull);
  await finishHome(tester, env);
  return log;
}

/// Breadcrumbs on a wide screen at `Disc 2/Bonus`.
Future<List<Object?>> _crumbScript(WidgetTester tester, Directory tree, {required bool filesHome}) async {
  final env = await createFoldersEnv();
  await seedFolderRoots(env, tree);
  final screenLog = FolderScreenLog();
  await pumpFolderScreen(
    tester,
    env,
    filesHome: filesHome,
    path: joinPath([tree.path, 'Disc 2', 'Bonus']),
    log: screenLog,
    surface: const TestSurface(Size(1280, 800), 1.0),
    platform: TargetPlatform.macOS,
  );
  final log = <Object?>[];
  log.add(['videos', rowTitles(tester, find.byType(DanaviewFolderScreen))]);
  log.add(['current crumb', find.text('Bonus').evaluate().length]);
  await tester.tap(find.widgetWithText(DanaviewButton, mediaRootLabel));
  await tester.tap(find.widgetWithText(DanaviewButton, 'Disc 2'));
  await pumpFrames(tester);
  log.add(['jumped', List.of(screenLog.jumped), List.of(screenLog.opened)]);
  expect(tester.takeException(), isNull);
  await finishHome(tester, env);
  return log;
}

/// The device storage root's folder screen, empty and with videos.
Future<List<Object?>> _deviceScript(WidgetTester tester, Directory device, {required bool filesHome}) async {
  final log = <Object?>[];
  final empty = Directory.systemTemp.createTempSync('danaview_device_empty_');
  addTearDown(() => empty.deleteSync(recursive: true));
  for (final dir in [empty, device]) {
    final env = await createFoldersEnv(device: dir);
    final screenLog = FolderScreenLog();
    await pumpFolderScreen(tester, env, filesHome: filesHome, path: dir.path, log: screenLog);
    log.add([
      'title',
      find.text(LibraryRepository.deviceFolderLabel).evaluate().length,
      find.text('No videos on this device yet').evaluate().length,
      find.textContaining('On My iPhone › Danaview').evaluate().length,
    ]);
    if (dir == device) {
      log.add(['videos', rowTitles(tester, find.byType(DanaviewFolderScreen))]);
      await tester.tap(find.widgetWithText(DanaviewButton, 'Play all'));
      await pumpFrames(tester);
      log.add(['play all', screenLog.playerOpens, queueOf(tester, DanaviewFolderScreen).items]);
    }
    expect(tester.takeException(), isNull);
    await finishHome(tester, env);
  }
  return log;
}

/// P-8 through the whole app: `danaview://` links (cold and warm), then drops onto the player.
Future<List<Object?>> _appScript(WidgetTester tester, Directory tree, {required bool filesHome}) async {
  const coldUrl = 'https://example.com/deep/cold.mp4';
  IncomingMediaBridge.mockInitialMedia = 'danaview://open?url=$coldUrl';
  addTearDown(() => IncomingMediaBridge.mockInitialMedia = null);
  final (engine, library) = await pumpFoldersApp(tester, filesHome: filesHome);
  final log = <Object?>[];
  log.add(['cold', playerMedia(tester), engine.currentSnapshot.status]);

  for (final link in [
    'danaview://open?url=https://example.com/live/master.m3u8',
    'danaview://https://example.com/stripped.mp4',
    'danaview:///Volumes/Media/Movies/Linked Clip.mp4',
    'file:///Volumes/Media/Movies/File%20Url.mp4',
  ]) {
    IncomingMediaBridge.emitMockMedia(link);
    await pumpFrames(tester, count: 10);
    log.add(['link $link', playerMedia(tester), find.byType(DanaviewPlayerScreen).evaluate().length]);
  }

  // Desktop drop onto the player: a folder plays its direct videos naturally sorted; files play
  // in drop order.
  await dropPaths(tester, [
    joinPath([tree.path, 'Disc 2'])
  ]);
  log.add(['drop folder', queueOf(tester, DanaviewPlayerScreen).items, playerMedia(tester)]);
  await dropPaths(tester, [
    joinPath([tree.path, 'Clip 10.mp4']),
    joinPath([tree.path, 'Clip 1.mp4'])
  ]);
  log.add(['drop files', queueOf(tester, DanaviewPlayerScreen).items, playerMedia(tester)]);
  log.add(['library folders', library.getFolders()]);

  expect(tester.takeException(), isNull);
  await finishApp(tester, engine);
  return log;
}

/// A drop on the Home (no player on screen) does nothing, as in 1.1.
Future<List<Object?>> _homeDropScript(WidgetTester tester, Directory tree, {required bool filesHome}) async {
  IncomingMediaBridge.mockInitialMedia = null;
  final (engine, library) = await pumpFoldersApp(tester, filesHome: filesHome);
  await dropPaths(tester, [
    joinPath([tree.path, 'Clip 1.mp4']),
    joinPath([tree.path, 'Disc 2'])
  ]);
  final log = <Object?>[
    find.byType(DanaviewHomeScreen).evaluate().length,
    find.byType(DanaviewPlayerScreen).evaluate().length,
    queueOf(tester, DanaviewHomeScreen).items,
    library.getFolders(),
  ];
  expect(tester.takeException(), isNull);
  await finishApp(tester, engine);
  return log;
}

void main() {
  late Directory tree;
  late Directory device;

  setUpAll(() {
    tree = createFolderTree();
    device = createDeviceFolder();
  });
  tearDownAll(() {
    tree.deleteSync(recursive: true);
    device.deleteSync(recursive: true);
  });

  testWidgets('Home folders: device root, user folders and the folder menu match 1.1 in every host', (tester) async {
    final off = await _homeScript(tester, tree, device, FoldersHost.flagOff);
    for (final host in [FoldersHost.homeTab, FoldersHost.foldersScreen, FoldersHost.linkedFolders]) {
      expect(await _homeScript(tester, tree, device, host), off, reason: host.label);
    }

    // The 1.1 values themselves.
    List<Object?> step(String name) => off.cast<List<Object?>>().firstWhere((e) => e.first == name);
    expect(step('rows'), [
      'rows',
      [LibraryRepository.deviceFolderLabel, mediaRootLabel, _onlyFolders]
    ]);
    expect(step('device hint'), ['device hint', 1]);
    expect(step('subtitles'), ['subtitles', 1]);
    expect(step('tap device'), [
      'tap device',
      0,
      [device.path],
      _queue(QueueState.empty)
    ]);
    expect(step('tap media'), [
      'tap media',
      0,
      [device.path, tree.path],
      _queue(QueueState.empty)
    ]);
    expect(step('device menu'), ['device menu', 0]);
    expect(step('menu open')[2], [device.path, tree.path, tree.path]);
    final rootRefs = refsIn(tree, const [], rootVideos);
    expect(step('menu play all'), [
      'menu play all',
      1,
      [device.path, tree.path, tree.path],
      [rootRefs, 0, false],
    ]);
    expect(step('play all without direct videos')[1], 1);
    expect(step('play all without direct videos')[3], [rootRefs, 0, false]);
    expect(step('toast'), ['toast', 1]);
    expect(step('confirm'), ['confirm', 1]);
    expect(step('after cancel'), [
      'after cancel',
      [mediaRootLabel, _onlyFolders]
    ]);
    expect(step('after remove'), [
      'after remove',
      [mediaRootLabel]
    ]);
    expect(step('on disk'), ['on disk', true]);
    expect(step('rows after remove'), [
      'rows after remove',
      [LibraryRepository.deviceFolderLabel, mediaRootLabel]
    ]);
  });

  testWidgets('folder screen: natural sort, Play all, Shuffle, Add to queue, Play next (flag off vs on)',
      (tester) async {
    final off = await _folderScript(tester, tree, filesHome: false);
    final on = await _folderScript(tester, tree, filesHome: true);
    expect(on, off);

    List<Object?> step(String name) => off.cast<List<Object?>>().firstWhere((e) => e.first == name);
    final root = refsIn(tree, const [], rootVideos);
    MediaRef clip(String name) => localRef(joinPath([tree.path, name]));
    expect(step('listing'), [
      'listing',
      [...rootFolders, ...rootVideos]
    ]);
    expect(step('title'), ['title', 1]);
    expect(step('summary'), ['summary', 1]);
    expect(step('counts'), ['counts', 1, 1]);
    // Compact width: no breadcrumb buttons, only Play all and Shuffle.
    expect(step('compact crumbs'), [
      'compact crumbs',
      ['Play all', 'Shuffle']
    ]);
    expect(step('add to queue idle'), [
      'add to queue idle',
      1,
      <String>[],
      [
        [clip('Clip 2.mkv')],
        0,
        false
      ]
    ]);
    expect(step('play next'), [
      'play next',
      1,
      <String>[],
      [
        [clip('Clip 2.mkv'), clip('Clip 10.mp4')],
        0,
        false
      ],
    ]);
    expect(step('toast next'), ['toast next', 1]);
    expect(step('add to queue'), [
      'add to queue',
      1,
      <String>[],
      [
        [clip('Clip 2.mkv'), clip('Clip 10.mp4'), clip('Clip 1.mp4')],
        0,
        false
      ],
    ]);
    expect(step('toast queue'), ['toast queue', 1]);
    expect(step('play all'), [
      'play all',
      2,
      <String>[],
      [root, 0, false]
    ]);
    expect(step('shuffle'), ['shuffle', 3, true, root, root.map((m) => m.id).toSet()]);
    expect(step('tap row'), [
      'tap row',
      4,
      <String>[],
      [root, 1, false]
    ]);
    expect(step('tap folder')[2], [
      joinPath([tree.path, 'Disc 2'])
    ]);
    expect(step('back'), ['back', 1]);
  });

  testWidgets('folder screen: breadcrumbs jump to the root and ancestors on wide screens (flag off vs on)',
      (tester) async {
    final off = await _crumbScript(tester, tree, filesHome: false);
    final on = await _crumbScript(tester, tree, filesHome: true);
    expect(on, off);
    expect(off, [
      [
        'videos',
        ['Making Of.mkv']
      ],
      ['current crumb', 2], // the top bar title and the last crumb
      [
        'jumped',
        [
          tree.path,
          joinPath([tree.path, 'Disc 2'])
        ],
        <String>[]
      ],
    ]);
  });

  testWidgets('device storage root: empty hint and its videos (flag off vs on)', (tester) async {
    final off = await _deviceScript(tester, device, filesHome: false);
    final on = await _deviceScript(tester, device, filesHome: true);
    expect(on, off);
    final refs = refsIn(device, const [], deviceVideos);
    expect(off, [
      ['title', 1, 1, 1],
      ['title', 1, 0, 0],
      ['videos', deviceVideos],
      ['play all', 1, refs],
    ]);
  });

  testWidgets('danaview:// links and desktop drops onto the player match 1.1 (flag off vs on)', (tester) async {
    final off = await _appScript(tester, tree, filesHome: false);
    final on = await _appScript(tester, tree, filesHome: true);
    expect(on, off);

    List<Object?> step(String name) => off.cast<List<Object?>>().firstWhere((e) => e.first == name);
    expect(step('cold'), ['cold', remoteRef('https://example.com/deep/cold.mp4'), PlaybackStatus.playing]);
    expect(step('link danaview://open?url=https://example.com/live/master.m3u8').sublist(1),
        [remoteRef('https://example.com/live/master.m3u8'), 1]);
    expect(step('link danaview://https://example.com/stripped.mp4').sublist(1),
        [remoteRef('https://example.com/stripped.mp4'), 1]);
    expect(step('link danaview:///Volumes/Media/Movies/Linked Clip.mp4').sublist(1),
        [localRef('/Volumes/Media/Movies/Linked Clip.mp4'), 1]);
    expect(step('link file:///Volumes/Media/Movies/File%20Url.mp4').sublist(1),
        [localRef('/Volumes/Media/Movies/File Url.mp4'), 1]);
    final disc2 = refsIn(tree, const ['Disc 2'], disc2Videos);
    expect(step('drop folder'), ['drop folder', disc2, disc2.first]);
    final dropped = refsIn(tree, const [], const ['Clip 10.mp4', 'Clip 1.mp4']);
    expect(step('drop files'), ['drop files', dropped, dropped.first]);
    expect(step('library folders'), ['library folders', <LibraryFolder>[]]);
  });

  testWidgets('a desktop drop on the Home does nothing, as in 1.1 (flag off vs on)', (tester) async {
    final off = await _homeDropScript(tester, tree, filesHome: false);
    final on = await _homeDropScript(tester, tree, filesHome: true);
    expect(on, off);
    expect(off, [1, 0, <MediaRef>[], <LibraryFolder>[]]);
  });
}
