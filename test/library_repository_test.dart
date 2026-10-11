import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';

String join(String a, String b, [String? c]) => [a, b, if (c != null) c].join(Platform.pathSeparator);

String basename(String path) => path.split(RegExp(r'[/\\]')).last;

MediaRef _ref(String path, {Duration duration = Duration.zero, bool remote = false}) =>
    MediaRef(id: path, title: basename(path), pathOrUri: path, duration: duration, isRemote: remote);

Future<LibraryRepository> _repo([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  return LibraryRepository(prefs, storage: LibraryStorage(isMobile: false));
}

void main() {
  group('Playlists', () {
    test('create validates trimmed, non-empty, case-insensitively unique names', () async {
      final repo = await _repo();
      expect(await repo.createPlaylist('  Weekend  '), 'Weekend');
      expect(repo.getSavedPlaylistNames(), ['Weekend']);
      expect(repo.getPlaylist('Weekend'), isEmpty);

      expect(() => repo.createPlaylist('   '), throwsA(isA<PlaylistException>()));
      expect(
        () => repo.createPlaylist('weekend'),
        throwsA(isA<PlaylistException>().having((e) => e.message, 'message', contains('already used'))),
      );
      expect(() => repo.createPlaylist('x' * 101), throwsA(isA<PlaylistException>()));
      expect(repo.validatePlaylistName('Movies'), isNull);
      expect(repo.validatePlaylistName('WEEKEND'), isNotNull);
    });

    test('add dedupes by pathOrUri and reports how many were added', () async {
      final repo = await _repo();
      await repo.createPlaylist('Mix');
      expect(await repo.addToPlaylist('Mix', [_ref('/a.mkv'), _ref('/b.mkv'), _ref('/a.mkv')]), 2);
      expect(await repo.addToPlaylist('Mix', [_ref('/b.mkv'), _ref('https://x.com/c.mp4', remote: true)]), 1);
      final items = repo.getPlaylist('Mix');
      expect(items.map((m) => m.pathOrUri), ['/a.mkv', '/b.mkv', 'https://x.com/c.mp4']);
      expect(items.last.isRemote, isTrue);
      expect(() => repo.addToPlaylist('Missing', [_ref('/a.mkv')]), throwsA(isA<PlaylistException>()));
    });

    test('rename keeps items and position in the list, and allows a case-only change', () async {
      final repo = await _repo();
      await repo.createPlaylist('One');
      await repo.createPlaylist('Two');
      await repo.createPlaylist('Three');
      await repo.addToPlaylist('Two', [_ref('/a.mkv'), _ref('/b.mkv')]);

      expect(await repo.renamePlaylist('Two', '  Second '), 'Second');
      expect(repo.getSavedPlaylistNames(), ['One', 'Second', 'Three']);
      expect(repo.getPlaylist('Second').map((m) => m.pathOrUri), ['/a.mkv', '/b.mkv']);
      expect(repo.getPlaylist('Two'), isEmpty);

      expect(await repo.renamePlaylist('Second', 'SECOND'), 'SECOND');
      expect(repo.getSavedPlaylistNames(), ['One', 'SECOND', 'Three']);

      expect(() => repo.renamePlaylist('SECOND', 'one'), throwsA(isA<PlaylistException>()));
      expect(() => repo.renamePlaylist('Nope', 'Other'), throwsA(isA<PlaylistException>()));
    });

    test('remove and move items, ignoring out-of-range indexes', () async {
      final repo = await _repo();
      await repo.createPlaylist('Queue');
      await repo.addToPlaylist('Queue', [_ref('/1.mkv'), _ref('/2.mkv'), _ref('/3.mkv'), _ref('/4.mkv')]);

      await repo.movePlaylistItem('Queue', 0, 2);
      expect(repo.getPlaylist('Queue').map((m) => m.pathOrUri), ['/2.mkv', '/3.mkv', '/1.mkv', '/4.mkv']);
      await repo.movePlaylistItem('Queue', 3, 0);
      expect(repo.getPlaylist('Queue').map((m) => m.pathOrUri), ['/4.mkv', '/2.mkv', '/3.mkv', '/1.mkv']);

      await repo.removeFromPlaylist('Queue', 1);
      expect(repo.getPlaylist('Queue').map((m) => m.pathOrUri), ['/4.mkv', '/3.mkv', '/1.mkv']);

      await repo.removeFromPlaylist('Queue', 9);
      await repo.movePlaylistItem('Queue', -1, 0);
      expect(repo.getPlaylist('Queue'), hasLength(3));
    });

    test('summaries and delete', () async {
      final repo = await _repo();
      await repo.createPlaylist('A');
      await repo.createPlaylist('B');
      await repo.addToPlaylist('B', [_ref('/x.mkv')]);
      expect(repo.getPlaylistSummaries(), const [
        PlaylistSummary(name: 'A', itemCount: 0),
        PlaylistSummary(name: 'B', itemCount: 1),
      ]);

      await repo.deletePlaylist('A');
      expect(repo.getPlaylistSummaries(), const [PlaylistSummary(name: 'B', itemCount: 1)]);
    });

    test('skips corrupted entries and drops them on the next write', () async {
      final repo = await _repo({
        'saved_playlists': ['Old', '', 'Old'],
        'playlist_Old': [
          'not json',
          jsonEncode({'title': 'no path'}),
          jsonEncode([1, 2]),
          jsonEncode({'pathOrUri': '/kept.mkv', 'durationMs': 1500.0}),
          jsonEncode({'id': '/b.mkv', 'title': 'B', 'pathOrUri': '/b.mkv', 'durationMs': 42, 'isRemote': false}),
        ],
      });
      expect(repo.getSavedPlaylistNames(), ['Old']);
      final items = repo.getPlaylist('Old');
      expect(items.map((m) => m.pathOrUri), ['/kept.mkv', '/b.mkv']);
      expect(items.first.id, '/kept.mkv');
      expect(items.first.title, 'kept.mkv');
      expect(items.first.duration, const Duration(milliseconds: 1500));
      expect(repo.getPlaylistSummaries().single.itemCount, 2);

      await repo.removeFromPlaylist('Old', 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('playlist_Old'), hasLength(1));
    });

    test('a non-list value under a playlist key does not throw', () async {
      final repo = await _repo({'saved_playlists': 'oops', 'recent_history': 7});
      expect(repo.getSavedPlaylistNames(), isEmpty);
      expect(repo.getRecentlyPlayed(), isEmpty);
    });
  });

  group('Library folders', () {
    test('add normalizes, dedupes and labels; remove is DB-only', () async {
      final tmp = await Directory.systemTemp.createTemp('danaview_folders_');
      addTearDown(() => tmp.delete(recursive: true));
      final repo = await _repo();

      final added = await repo.addFolder('${tmp.path}/Movies/../Movies/');
      expect(added.path, join(tmp.path, 'Movies'));
      expect(added.label, 'Movies');
      expect(added.isDevice, isFalse);
      expect(added.addedAt, isNotNull);

      final again = await repo.addFolder(join(tmp.path, 'Movies'), label: 'Other');
      expect(again, added);
      await repo.addFolder(join(tmp.path, 'Shows'), label: '  TV  ');
      expect(repo.getFolders().map((f) => f.label), ['Movies', 'TV']);
      expect(() => repo.addFolder('  '), throwsArgumentError);

      final keepMe = Directory(join(tmp.path, 'Movies'))..createSync();
      await repo.removeFolder(join(tmp.path, 'Movies'));
      expect(repo.getFolders().map((f) => f.label), ['TV']);
      expect(keepMe.existsSync(), isTrue);
    });

    test('survives corrupted folder entries', () async {
      final repo = await _repo({
        'library_folders': ['{bad', jsonEncode({'path': ''}), jsonEncode({'path': '/media/films'})],
      });
      expect(repo.getFolders().single.path, '/media/films');
      expect(repo.getFolders().single.label, 'films');
    });

    test('device folder is only present on mobile and is listed first', () async {
      final desktop = await _repo();
      expect(await desktop.getDeviceFolder(), isNull);

      final tmp = await Directory.systemTemp.createTemp('danaview_device_');
      addTearDown(() => tmp.delete(recursive: true));
      final docs = Directory(join(tmp.path, 'Documents'));
      final prefs = await SharedPreferences.getInstance();
      final mobile = LibraryRepository(
        prefs,
        storage: LibraryStorage(isMobile: true, documentsDirectory: () async => docs),
      );
      await mobile.addFolder('/media/films');

      final device = (await mobile.getDeviceFolder())!;
      expect(device.isDevice, isTrue);
      expect(device.path, docs.path);
      expect(device.label, LibraryRepository.deviceFolderLabel);
      expect(docs.existsSync(), isTrue);

      final roots = await mobile.getLibraryRoots();
      expect(roots.map((f) => f.isDevice), [true, false]);
      await mobile.removeFolder(docs.path);
      expect((await mobile.getLibraryRoots()).first.isDevice, isTrue);
    });
  });

  group('History', () {
    test('record keeps known durations, remove and clear', () async {
      final repo = await _repo();
      await repo.recordPlayed(_ref('/a.mkv', duration: const Duration(minutes: 42)));
      await repo.recordPlayed(_ref('/b.mkv'));
      await repo.recordPlayed(_ref('/a.mkv'));

      var history = repo.getRecentlyPlayed();
      expect(history.map((m) => m.pathOrUri), ['/a.mkv', '/b.mkv']);
      expect(history.first.duration, const Duration(minutes: 42));

      await repo.recordPlayed(_ref('/a.mkv', duration: const Duration(minutes: 43)));
      expect(repo.getRecentlyPlayed().first.duration, const Duration(minutes: 43));

      await repo.updateHistoryDuration('/b.mkv', const Duration(minutes: 5));
      history = repo.getRecentlyPlayed();
      expect(history.map((m) => m.pathOrUri), ['/a.mkv', '/b.mkv']);
      expect(history.last.duration, const Duration(minutes: 5));

      await repo.removeFromHistory('/a.mkv');
      expect(repo.getRecentlyPlayed().map((m) => m.pathOrUri), ['/b.mkv']);

      await repo.clearHistory();
      expect(repo.getRecentlyPlayed(), isEmpty);
    });

    test('caps history at 50 entries', () async {
      final repo = await _repo();
      for (var i = 0; i < 55; i++) {
        await repo.recordPlayed(_ref('/v$i.mkv'));
      }
      final history = repo.getRecentlyPlayed();
      expect(history, hasLength(50));
      expect(history.first.pathOrUri, '/v54.mkv');
    });

    test('mediaExists greys out only missing local files', () async {
      final tmp = await Directory.systemTemp.createTemp('danaview_exists_');
      addTearDown(() => tmp.delete(recursive: true));
      final file = File(join(tmp.path, 'here.mkv'))..writeAsStringSync('x');
      expect(LibraryRepository.mediaExists(_ref(file.path)), isTrue);
      expect(LibraryRepository.mediaExists(_ref(join(tmp.path, 'gone.mkv'))), isFalse);
      expect(LibraryRepository.mediaExists(_ref('https://x.com/a.mp4', remote: true)), isTrue);
    });
  });

  group('SessionRepository resume info', () {
    test('stores duration alongside the position and clears both when finished', () async {
      SharedPreferences.setMockInitialValues({'danaview_resume_/old.mkv': 30000});
      final session = SessionRepository(await SharedPreferences.getInstance());

      expect(session.getResumeInfo('/old.mkv'), const ResumeInfo(position: Duration(seconds: 30)));
      expect(session.getResumeInfo('/none.mkv'), isNull);

      await session.saveResumePosition('/a.mkv', const Duration(minutes: 10), const Duration(minutes: 40));
      final info = session.getResumeInfo('/a.mkv')!;
      expect(info.position, const Duration(minutes: 10));
      expect(info.duration, const Duration(minutes: 40));
      expect(info.progress, closeTo(0.25, 1e-9));
      expect(info.remaining, const Duration(minutes: 30));
      expect(session.getResumePosition('/a.mkv', Duration.zero), const Duration(minutes: 10));

      await session.saveResumePosition('/a.mkv', const Duration(minutes: 39, seconds: 55), const Duration(minutes: 40));
      expect(session.getResumeInfo('/a.mkv'), isNull);
    });
  });

  group('browseDirectory', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('danaview_browse_');
      for (final dir in ['Season 10', 'Season 2', 'Season 1', '.hidden', r'$RECYCLE.BIN', '@eaDir']) {
        Directory(join(root.path, dir)).createSync();
      }
      for (final file in [
        'Show S01E10.mkv',
        'Show S01E2.mkv',
        'Show S01E1.MP4',
        'clip.m4v',
        'phone.3gp',
        '.hidden.mkv',
        '._Show S01E1.MP4',
        'notes.txt',
        'Show S01E1.srt',
      ]) {
        File(join(root.path, file)).writeAsStringSync('x');
      }
      File(join(root.path, 'Season 2', 'a.mkv')).writeAsStringSync('x');
      File(join(root.path, 'Season 2', 'b.mp4')).writeAsStringSync('x');
      File(join(root.path, 'Season 2', 'readme.txt')).writeAsStringSync('x');
      File(join(root.path, 'Season 2', '.c.mkv')).writeAsStringSync('x');
    });

    tearDown(() => root.delete(recursive: true));

    test('lists one level with natural sort, skipping hidden and system entries', () async {
      final listing = await LibraryRepository.browseDirectory(root.path);
      expect(listing.hasError, isFalse);
      expect(listing.name, basename(root.path));
      expect(listing.folders.map((f) => f.name), ['Season 1', 'Season 2', 'Season 10']);
      expect(listing.folders.map((f) => f.mediaCount), [0, 2, 0]);
      expect(
        listing.media.map((m) => m.title),
        ['clip.m4v', 'phone.3gp', 'Show S01E1.MP4', 'Show S01E2.mkv', 'Show S01E10.mkv'],
      );
      final episode = listing.media.last;
      expect(episode.seasonNumber, 1);
      expect(episode.episodeNumber, 10);
      expect(episode.isRemote, isFalse);
      expect(episode.id, join(root.path, 'Show S01E10.mkv'));
    });

    test('scanDirectory returns the same media', () async {
      final media = await LibraryRepository.scanDirectory(root.path);
      expect(media.map((m) => m.title).first, 'clip.m4v');
      expect(media, hasLength(5));
    });

    test('missing folders return an error listing instead of throwing', () async {
      final listing = await LibraryRepository.browseDirectory(join(root.path, 'nope'));
      expect(listing.hasError, isTrue);
      expect(listing.isEmpty, isTrue);
      expect(listing.error, contains("isn't available"));
    });

    test('unreadable folders return an error listing', () async {
      if (Platform.isWindows) return;
      final locked = Directory(join(root.path, 'Season 1'));
      await Process.run('chmod', ['000', locked.path]);
      try {
        final listing = await LibraryRepository.browseDirectory(locked.path);
        expect(listing.hasError, isTrue);
        expect(listing.error, contains('permission'));
      } finally {
        await Process.run('chmod', ['755', locked.path]);
      }
    });
  });
}
