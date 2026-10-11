import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_features/danaview_features.dart';

import 'library_test_utils.dart';

MediaRef _ref(String path, {bool remote = false}) => MediaRef(
      id: path,
      title: path.split('/').last,
      pathOrUri: path,
      isRemote: remote,
    );

void main() {
  late Directory media;
  late String existing;
  late SharedPreferences prefs;
  late LibraryRepository repo;
  late SessionRepository session;

  setUpAll(() {
    media = Directory.systemTemp.createTempSync('danaview_controller_test_');
    existing = joinPath([media.path, 'Show.S01E01.mkv']);
    File(existing).writeAsStringSync('x');
  });

  tearDownAll(() => media.deleteSync(recursive: true));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    repo = LibraryRepository(prefs, storage: LibraryStorage(isMobile: false));
    session = SessionRepository(prefs);
  });

  Future<LibraryController> loaded() async {
    final controller = LibraryController(repo, session);
    addTearDown(controller.dispose);
    await controller.refresh();
    return controller;
  }

  test('loads history with resume points and missing-file flags, playlists and folders', () async {
    final local = _ref(existing);
    final missing = _ref('/nowhere/gone.mp4');
    final remote = _ref('https://example.com/live.m3u8', remote: true);
    for (final item in [missing, remote, local]) {
      await repo.recordPlayed(item);
    }
    await session.saveResumePosition(local.id, const Duration(minutes: 10), const Duration(minutes: 40));
    await repo.createPlaylist('Mix');
    await repo.addToPlaylist('Mix', [local, remote]);
    await repo.addFolder(media.path);

    final controller = LibraryController(repo, session);
    addTearDown(controller.dispose);
    expect(controller.state.isLoading, isTrue);
    expect(controller.state.hasLoaded, isFalse);
    await controller.refresh();

    final state = controller.state;
    expect(state.hasLoaded, isTrue);
    expect(state.isLoading, isFalse);
    expect(state.error, isNull);
    expect(state.recent.map((r) => r.media.pathOrUri), [local.pathOrUri, remote.pathOrUri, missing.pathOrUri]);
    expect(state.recent[0].progress, closeTo(0.25, 1e-9));
    expect(state.recent[0].exists, isTrue);
    expect(state.recent[1].exists, isTrue, reason: 'links are always playable');
    expect(state.recent[2].exists, isFalse);
    expect(state.recent[2].resume, isNull);
    expect(state.playlists, [const PlaylistSummary(name: 'Mix', itemCount: 2)]);
    expect(state.roots.single.path, media.path);
    expect(state.deviceFolder, isNull);
    expect(state.userFolders.single.path, media.path);
  });

  test('removeFromHistory also forgets the resume point; clearHistory forgets all of them', () async {
    final a = _ref('/a.mkv');
    final b = _ref('/b.mkv');
    await repo.recordPlayed(a);
    await repo.recordPlayed(b);
    await session.saveResumePosition(a.id, const Duration(minutes: 1), const Duration(minutes: 9));
    await session.saveResumePosition(b.id, const Duration(minutes: 2), const Duration(minutes: 9));
    final controller = await loaded();

    await controller.removeFromHistory(b);
    expect(controller.state.recent.map((r) => r.media), [a]);
    expect(session.getResumeInfo(b.id), isNull);
    expect(session.getResumeInfo(a.id), isNotNull);

    await controller.clearHistory();
    expect(controller.state.recent, isEmpty);
    expect(repo.getRecentlyPlayed(), isEmpty);
    expect(session.getResumeInfo(a.id), isNull);
  });

  test('playlist actions update summaries and bump the revision', () async {
    final controller = await loaded();
    final start = controller.state.playlistRevision;

    expect(await controller.createPlaylist('  Weekend  '), 'Weekend');
    expect(controller.state.playlists, [const PlaylistSummary(name: 'Weekend', itemCount: 0)]);
    expect(controller.state.playlistRevision, greaterThan(start));

    expect(await controller.addToPlaylist('Weekend', [_ref('/1.mkv'), _ref('/2.mkv'), _ref('/3.mkv')]), 3);
    expect(await controller.addToPlaylist('Weekend', [_ref('/1.mkv')]), 0);
    expect(controller.state.playlists.single.itemCount, 3);

    await controller.movePlaylistItem('Weekend', 0, 2);
    expect(controller.playlistItems('Weekend').map((m) => m.pathOrUri), ['/2.mkv', '/3.mkv', '/1.mkv']);

    await controller.removeFromPlaylist('Weekend', 1);
    expect(controller.playlistItems('Weekend').map((m) => m.pathOrUri), ['/2.mkv', '/1.mkv']);

    expect(await controller.renamePlaylist('Weekend', 'Late Night'), 'Late Night');
    expect(controller.hasPlaylist('Weekend'), isFalse);
    expect(controller.state.playlists, [const PlaylistSummary(name: 'Late Night', itemCount: 2)]);

    await controller.deletePlaylist('Late Night');
    expect(controller.state.playlists, isEmpty);
  });

  test('invalid playlist names surface PlaylistException messages', () async {
    final controller = await loaded();
    await controller.createPlaylist('Movies');
    expect(controller.validatePlaylistName('movies'), contains('already used'));
    expect(controller.validatePlaylistName('MOVIES', renaming: 'Movies'), isNull);
    await expectLater(controller.createPlaylist('MOVIES'), throwsA(isA<PlaylistException>()));
    await expectLater(controller.addToPlaylist('Missing', [_ref('/a.mkv')]), throwsA(isA<PlaylistException>()));
    expect(controller.state.playlists, hasLength(1));
  });

  test('folders are added once and removed from the library only', () async {
    final controller = await loaded();
    final folder = await controller.addFolder(media.path);
    await controller.addFolder(media.path);
    expect(controller.state.roots, [folder]);

    await controller.removeFolder(media.path);
    expect(controller.state.roots, isEmpty);
    expect(File(existing).existsSync(), isTrue);
  });

  test('on mobile the device folder is the first, non-removable root', () async {
    final documents = Directory.systemTemp.createTempSync('danaview_documents_');
    addTearDown(() => documents.deleteSync(recursive: true));
    repo = LibraryRepository(prefs, storage: LibraryStorage(isMobile: true, documentsDirectory: () async => documents));
    await repo.addFolder(media.path);
    final controller = await loaded();

    expect(controller.state.roots.map((r) => r.path), [documents.path, media.path]);
    expect(controller.state.deviceFolder?.label, LibraryRepository.deviceFolderLabel);
    expect(controller.state.userFolders.map((r) => r.path), [media.path]);
  });

  test('a later refresh reflects changes made outside the controller', () async {
    final controller = await loaded();
    expect(controller.state.recent, isEmpty);
    await repo.recordPlayed(_ref(existing));
    await controller.refresh();
    expect(controller.state.recent.single.media.pathOrUri, existing);
  });

  group('providers', () {
    ProviderContainer container() {
      final c = ProviderContainer(overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        sessionRepositoryProvider.overrideWithValue(session),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('playlistItemsProvider follows the playlist and is null when it does not exist', () async {
      await repo.createPlaylist('Mix');
      await repo.addToPlaylist('Mix', [_ref('/a.mkv'), _ref('/b.mkv')]);
      final c = container();
      final sub = c.listen(playlistItemsProvider('Mix'), (_, __) {});
      addTearDown(sub.close);

      expect(sub.read()!.map((m) => m.pathOrUri), ['/a.mkv', '/b.mkv']);
      expect(c.read(playlistItemsProvider('Nope')), isNull);

      await c.read(libraryControllerProvider.notifier).movePlaylistItem('Mix', 1, 0);
      expect(sub.read()!.map((m) => m.pathOrUri), ['/b.mkv', '/a.mkv']);

      await c.read(libraryControllerProvider.notifier).deletePlaylist('Mix');
      expect(sub.read(), isNull);
    });

    test('folderListingProvider reads one level of the disk', () async {
      Directory(joinPath([media.path, 'Extras'])).createSync(recursive: true);
      final c = container();
      final listing = await c.read(folderListingProvider(media.path).future);
      expect(listing.hasError, isFalse);
      expect(listing.folders.map((f) => f.name), ['Extras']);
      expect(listing.media.single.episodeNumber, 1);
    });
  });
}
