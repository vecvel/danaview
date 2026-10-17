import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'library_test_utils.dart';

/// The library surfaces plus the narrowest phone width.
final List<TestSurface> _surfaces = [
  ...librarySurfaces,
  for (final scale in [1.0, 1.35]) TestSurface(const Size(280, 653), scale, padding: const EdgeInsets.only(top: 20)),
];

TargetPlatform _platformFor(TestSurface surface) =>
    surface.size.width >= 1000 ? TargetPlatform.macOS : TargetPlatform.iOS;

/// Scrolls the page to the end, checking every step for layout errors.
Future<void> _scrollThrough(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 60; i++) {
    final position = tester.state<ScrollableState>(scrollable).position;
    if (position.pixels >= position.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  }
  await pumpFrames(tester);
  expect(tester.takeException(), isNull);
}

Future<void> _scrollToTop(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await pumpFrames(tester);
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await pumpFrames(tester);
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.pump();
  await tester.tap(finder);
  await pumpFrames(tester);
}

Future<void> _finish(WidgetTester tester, LibraryTestEnv env) async {
  DanaviewToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await env.dispose();
}

class _FakeInspector extends MediaInspector {
  _FakeInspector(this.handler);

  final Future<MediaFileInfo> Function(String path) handler;
  final List<String> inspected = [];

  @override
  Future<MediaFileInfo> inspect(String path) {
    inspected.add(path);
    return handler(path);
  }
}

const _longFileName = 'The.Extraordinarily.Long.Movie.Title.That.Never.Seems.To.End.2160p.UHD.BluRay.'
    'REMUX.HDR10.DV.HEVC.TrueHD.Atmos.7.1-SOMEVERYLONGRELEASEGROUPNAME.mkv';

final _richInfo = MediaFileInfo(
  path: '/Users/someone/Movies/Collections/A Folder With An Unreasonably Long Name/$_longFileName',
  fileName: _longFileName,
  sizeBytes: 58312876544,
  modified: DateTime(2026, 9, 14, 21, 7),
  container: MediaContainer.matroska,
  brand: 'matroska',
  duration: const Duration(hours: 2, minutes: 41, seconds: 7),
  title: 'The Extraordinarily Long Movie Title That Never Seems To End: Director\'s Extended Edition',
  encoder: 'mkvmerge v80.0 (\'Roundabout\') 64-bit built on a very long build host name',
  tracks: const [
    MediaTrackInfo(
      kind: MediaTrackKind.video,
      codec: 'H.265 (HEVC)',
      codecId: 'V_MPEGH/ISO/HEVC',
      profile: 'Main 10 (High tier), Level 5.1',
      width: 3840,
      height: 2160,
      frameRate: 23.976,
      bitDepth: 10,
      hdr: 'Dolby Vision',
      rotation: 90,
      bitrate: 58123456,
      language: 'eng',
      name: 'Main feature with a needlessly long track name for testing',
      encrypted: true,
    ),
    MediaTrackInfo(
      kind: MediaTrackKind.audio,
      codec: 'E-AC-3 (Dolby Digital Plus)',
      profile: 'Joint Object Coding',
      channels: 8,
      sampleRate: 48000,
      bitrate: 768000,
      language: 'eng',
      name: 'Dolby Atmos 7.1 Director Commentary Mixed With The Theatrical Soundtrack',
    ),
    MediaTrackInfo(
      kind: MediaTrackKind.audio,
      codec: 'AAC',
      profile: 'HE-AAC v2',
      channels: 2,
      sampleRate: 44100,
      language: 'pt-BR',
    ),
    MediaTrackInfo(kind: MediaTrackKind.audio, codec: 'Opus', channels: 1, sampleRate: 48000, language: 'jpn'),
    MediaTrackInfo(
      kind: MediaTrackKind.subtitle,
      codec: 'PGS (Blu-ray)',
      language: 'eng',
      name: 'Forced narrative signs and songs for the extended cut only',
      isDefault: true,
      isForced: true,
    ),
    MediaTrackInfo(kind: MediaTrackKind.subtitle, codec: 'SubRip (SRT)', language: 'spa'),
    MediaTrackInfo(kind: MediaTrackKind.subtitle, codec: 'Advanced SubStation (ASS)', language: 'zz-Unknown-Long-Tag'),
    MediaTrackInfo(kind: MediaTrackKind.subtitle, codec: 'WebVTT'),
  ],
  warnings: const [
    "Some track details couldn't be read. The file may be damaged.",
    'Only the first 16 MB were read, so some details may be missing.',
  ],
);

const _mp4Info = MediaFileInfo(
  path: '/tmp/clip.mp4',
  fileName: 'clip.mp4',
  sizeBytes: 9000000,
  container: MediaContainer.mp4,
  duration: Duration(minutes: 1),
  fastStart: false,
  tracks: [
    MediaTrackInfo(kind: MediaTrackKind.video, codec: 'H.264 (AVC)', width: 1920, height: 1080, frameRate: 29.97),
    MediaTrackInfo(kind: MediaTrackKind.audio, codec: 'AAC', profile: 'LC', channels: 2, sampleRate: 48000),
  ],
);

/// Reports fixed figures and records clean-ups instead of touching the disk.
class _FakeStorage extends StorageUsageService {
  _FakeStorage(this.usage) : super(deviceDirectory: () async => null, cacheDirectories: () async => const []);

  StorageUsage usage;
  int measured = 0;
  final List<Set<String>> cleared = [];

  @override
  Future<StorageUsage> measure() async {
    measured++;
    return usage;
  }

  @override
  Future<CacheClearResult> clearCache({Set<String> keep = const {}}) async {
    cleared.add(keep);
    final freed = usage.cache ?? const FolderUsage();
    usage = StorageUsage(deviceVideos: usage.deviceVideos, cache: const FolderUsage());
    return CacheClearResult(files: freed.files, bytes: freed.bytes, kept: keep.length);
  }
}

const _mobileUsage = StorageUsage(
  deviceVideos: FolderUsage(files: 1234, bytes: 987654321012),
  cache: FolderUsage(files: 37, bytes: 120000000, complete: false),
);

const _desktopUsage = StorageUsage(cache: FolderUsage(files: 3, bytes: 4096));

void main() {
  late Directory media;

  setUpAll(() => media = createMediaTree());
  tearDownAll(() => media.deleteSync(recursive: true));

  group('Media info', () {
    for (final surface in _surfaces) {
      testWidgets('shows every section without overflow at $surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        final pending = Completer<MediaFileInfo>();
        final inspector = _FakeInspector((_) => pending.future);
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewMediaInfoScreen(onBack: () {}),
          textScale: surface.textScale,
          platform: _platformFor(surface),
          overrides: [
            mediaInspectorProvider.overrideWithValue(inspector),
            mediaInfoPickerProvider.overrideWithValue(() async => _richInfo.path),
          ],
        ));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Choose a video'), findsOneWidget);
        // No local video in the player yet, so there is no shortcut.
        expect(find.text('Now in the player'), findsNothing);

        await tester.tap(find.text('Choose a video'));
        await pumpFrames(tester);
        expect(find.text('Reading the file…'), findsOneWidget);
        expect(tester.takeException(), isNull);

        pending.complete(_richInfo);
        await pumpFrames(tester);
        expect(inspector.inspected, [_richInfo.path]);
        expect(find.text('Copy details'), findsOneWidget);
        await _scrollTo(tester, find.text('Audio 3'));
        await _scrollThrough(tester);
        expect(find.text('Unknown language'), findsOneWidget);
        await _finish(tester, env);
      });
    }

    testWidgets('inspects the local video in the player, copies a summary and recovers from errors', (tester) async {
      useSurface(tester, librarySurfaces[1]);
      final env = await LibraryTestEnv.create();
      var fail = true;
      final inspector = _FakeInspector((path) async {
        if (fail) throw const MediaInspectorException("This file isn't available. It may have been moved or deleted.");
        return _mp4Info;
      });
      final videoPath = joinPath([media.path, 'Movie 1 - $longTitle.mp4']);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewMediaInfoScreen(onBack: () {}),
        overrides: [mediaInspectorProvider.overrideWithValue(inspector)],
      ));
      final container = ProviderScope.containerOf(tester.element(find.byType(DanaviewMediaInfoScreen)));
      await container.read(playerControllerProvider.notifier).openMedia(localRef(videoPath));
      await pumpFrames(tester);
      expect(find.text('Now in the player'), findsOneWidget);

      await tester.tap(find.text('Now in the player'));
      await pumpFrames(tester);
      expect(inspector.inspected, [videoPath]);
      expect(find.text("Couldn't read this file"), findsOneWidget);
      expect(tester.takeException(), isNull);

      fail = false;
      await tester.tap(find.text('Try again'));
      await pumpFrames(tester);
      expect(find.text("Couldn't read this file"), findsNothing);

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.tap(find.text('Copy details'));
      await pumpFrames(tester);
      expect(copied, contains('File: clip.mp4'));
      expect(copied, contains('Video: H.264 (AVC) · 1920 × 1080 (1080p) · 29.97 fps'));
      expect(copied, contains('Streaming: Not optimized'));
      expect(find.text('Details copied'), findsOneWidget);
      await _scrollTo(tester, find.text('Not optimized: the index is at the end'));
      expect(tester.takeException(), isNull);

      // Remote streams are not files, so they get no shortcut.
      await container.read(playerControllerProvider.notifier).openMedia(remoteRef('https://example.com/live.m3u8'));
      await pumpFrames(tester);
      expect(find.text('Now in the player'), findsNothing);
      await _finish(tester, env);
    });

    testWidgets('the copied summary describes every track plainly', (tester) async {
      useSurface(tester, librarySurfaces[4]);
      final env = await LibraryTestEnv.create();
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewMediaInfoScreen(onBack: () {}),
        platform: TargetPlatform.macOS,
        overrides: [
          mediaInspectorProvider.overrideWithValue(_FakeInspector((_) async => _richInfo)),
          mediaInfoPickerProvider.overrideWithValue(() async => _richInfo.path),
        ],
      ));
      await tester.tap(find.text('Choose a video'));
      await pumpFrames(tester);
      String? summary;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') summary = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.tap(find.text('Copy details'));
      await pumpFrames(tester);
      expect(summary, contains('File: $_longFileName'));
      expect(summary, contains('Size: 58.3 GB (58,312,876,544 bytes)'));
      expect(summary, isNot(contains('\u00A0')), reason: 'the clipboard gets plain spaces');
      expect(summary, contains('Duration: 2:41:07'));
      expect(summary, contains('Audio 1: E-AC-3 (Dolby Digital Plus)'));
      expect(summary, contains('7.1 (8 channels)'));
      expect(summary, contains('Subtitles 2: SubRip (SRT) · Spanish'));
      expect(summary, contains('Note: Only the first 16 MB'));
      expect(summary, contains('Dolby Vision'));
      expect(summary, contains('Portuguese (pt-BR)'));
      await _finish(tester, env);
    });
  });

  group('Data usage', () {
    test('estimates data and watch time in decimal units', () {
      expect(DataUsageMath.bytesFor(5, const Duration(hours: 1)), 2.25e9);
      expect(DataUsageMath.bytesFor(5, const Duration(hours: 2, minutes: 30)), closeTo(5.625e9, 1));
      expect(DataUsageMath.bytesFor(0, const Duration(hours: 1)), 0);
      expect(DataUsageMath.bytesFor(5, Duration.zero), 0);
      expect(DataUsageMath.bytesPerHour(StreamQuality.sd480.megabitsPerSecond), 675e6);
      expect(DataUsageMath.bytesPerHour(StreamQuality.uhd4k.megabitsPerSecond), 7.2e9);
      expect(DataUsageMath.watchTimeFor(5, 5e9), const Duration(hours: 2, minutes: 13, seconds: 20));
      expect(DataUsageMath.watchTimeFor(0, 5e9), Duration.zero);
      expect(DataUsageMath.watchTimeFor(16, 1e9), const Duration(minutes: 8, seconds: 20));

      expect(
        [for (final q in StreamQuality.values) q.megabitsPerSecond],
        [1.5, 3, 5, 9, 16],
        reason: '480p, 720p, 1080p, 1440p and 4K presets',
      );
    });

    for (final surface in _surfaces) {
      testWidgets('calculates both ways without overflow at $surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewDataUsageScreen(onBack: () {}),
          textScale: surface.textScale,
          platform: _platformFor(surface),
        ));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        // 2 hours of 1080p at 5 Mbps.
        expect(find.text('4.5\u00A0GB'), findsOneWidget);

        await _scrollTo(tester, find.text('Hours'));
        await tester.tap(find.byTooltip('More').first);
        await pumpFrames(tester);
        await _scrollToTop(tester);
        expect(find.text('6.75\u00A0GB'), findsOneWidget);

        await _tapVisible(tester, find.text('4K'));
        await _scrollThrough(tester);
        await _scrollToTop(tester);
        expect(find.text('21.6\u00A0GB'), findsOneWidget);

        await tester.tap(find.text('Watch time'));
        await pumpFrames(tester);
        // 5 GB at 16 Mbps lasts 41 min 40 s.
        expect(find.text('41\u00A0min'), findsOneWidget);

        await _tapVisible(tester, find.text('Custom bitrate'));
        expect(find.text('Bitrate'), findsOneWidget);
        await _scrollThrough(tester);
        await _finish(tester, env);
      });
    }
  });

  group('Storage & history', () {
    for (final surface in _surfaces) {
      for (final (name, usage) in [('phone', _mobileUsage), ('computer', _desktopUsage)]) {
        testWidgets('$name storage without overflow at $surface', (tester) async {
          useSurface(tester, surface);
          final env = await LibraryTestEnv.create();
          await seedLibrary(env, existingDir: media.path);
          await tester.pumpWidget(libraryTestApp(
            env,
            DanaviewStorageScreen(onBack: () {}),
            textScale: surface.textScale,
            platform: _platformFor(surface),
            overrides: [storageUsageServiceProvider.overrideWithValue(_FakeStorage(usage))],
          ));
          await pumpFrames(tester);
          expect(tester.takeException(), isNull);
          if (usage.deviceVideos != null) {
            expect(find.text('1,234 videos · 988\u00A0GB'), findsOneWidget);
            await _scrollTo(
              tester,
              find.textContaining(
                _platformFor(surface) == TargetPlatform.iOS ? 'On My iPhone › Danaview' : 'never deletes videos',
              ),
            );
          } else {
            expect(find.text('Nothing is copied'), findsOneWidget);
          }
          await _scrollTo(tester, find.text('11 videos'));
          await _scrollThrough(tester);
          await _finish(tester, env);
        });
      }
    }

    testWidgets('clearing history asks first and also clears its resume points', (tester) async {
      useSurface(tester, librarySurfaces[1]);
      final env = await LibraryTestEnv.create();
      await seedLibrary(env, existingDir: media.path);
      final history = env.library.getRecentlyPlayed();
      final playlists = env.library.getSavedPlaylistNames();
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewStorageScreen(onBack: () {}),
        overrides: [storageUsageServiceProvider.overrideWithValue(_FakeStorage(_mobileUsage))],
      ));
      await pumpFrames(tester);
      await _scrollTo(tester, find.text('6 saved positions'));

      await _tapVisible(tester, find.text('Clear watch history'));
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester);
      expect(env.library.getRecentlyPlayed(), hasLength(history.length));

      await _tapVisible(tester, find.text('Clear watch history'));
      await tester.tap(find.text('Clear'));
      await pumpFrames(tester);
      expect(env.library.getRecentlyPlayed(), isEmpty);
      for (final media in history) {
        expect(env.session.getResumeInfo(media.id), isNull);
      }
      expect(env.library.getSavedPlaylistNames(), playlists);
      expect(find.text('Watch history cleared'), findsOneWidget);
      expect(find.text('History is empty'), findsOneWidget);
      expect(find.text('No saved positions'), findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('clearing resume points keeps the history', (tester) async {
      useSurface(tester, librarySurfaces[0]);
      final env = await LibraryTestEnv.create();
      await seedLibrary(env, existingDir: media.path);
      final history = env.library.getRecentlyPlayed();
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewStorageScreen(onBack: () {}),
        textScale: 1.35,
        overrides: [storageUsageServiceProvider.overrideWithValue(_FakeStorage(_desktopUsage))],
      ));
      await pumpFrames(tester);

      await _tapVisible(tester, find.text('Clear resume points'));
      expect(find.textContaining('6 videos will start from the beginning'), findsOneWidget);
      await tester.tap(find.text('Clear'));
      await pumpFrames(tester);
      expect(env.library.getRecentlyPlayed(), hasLength(history.length));
      for (final media in history) {
        expect(env.session.getResumeInfo(media.id), isNull);
      }
      expect(find.text('Resume points cleared'), findsOneWidget);
      expect(find.text('No saved positions'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('clearing the cache asks first, keeps the playing video and re-measures', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      final storage = _FakeStorage(_mobileUsage);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewStorageScreen(onBack: () {}),
        overrides: [storageUsageServiceProvider.overrideWithValue(storage)],
      ));
      final container = ProviderScope.containerOf(tester.element(find.byType(DanaviewStorageScreen)));
      final playing = joinPath([media.path, 'Movie 2 - $longTitle.mp4']);
      await container.read(playerControllerProvider.notifier).openMedia(localRef(playing));
      await pumpFrames(tester);
      expect(storage.measured, 1);
      await _scrollTo(tester, find.text('Frees at least 120\u00A0MB of temporary files'));

      await _tapVisible(tester, find.text('Clear cache'));
      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester);
      expect(storage.cleared, isEmpty);

      await _tapVisible(tester, find.text('Clear cache'));
      await tester.tap(find.text('Clear'));
      await pumpFrames(tester);
      expect(storage.cleared, [
        {playing},
      ]);
      expect(storage.measured, 2);
      expect(find.text('Freed 120\u00A0MB. Files in use were kept.'), findsOneWidget);
      expect(find.text('The cache is empty'), findsOneWidget);
      // Imported videos are never part of a clean-up.
      await _scrollToTop(tester);
      expect(find.text('1,234 videos · 988\u00A0GB'), findsOneWidget);
      await _finish(tester, env);
    });
  });

  group('StorageUsageService', () {
    late Directory root;
    late Directory documents;
    late Directory cache;

    setUp(() {
      root = Directory.systemTemp.createTempSync('danaview_storage_test_');
      documents = Directory(joinPath([root.path, 'Documents']))..createSync();
      cache = Directory(joinPath([root.path, 'tmp']))..createSync();
    });
    tearDown(() => root.deleteSync(recursive: true));

    File write(List<String> parts, int bytes) =>
        File(joinPath(parts))..createSync(recursive: true)..writeAsBytesSync(List.filled(bytes, 1));

    test('measures videos on the device and the whole cache', () async {
      write([documents.path, 'Imported', 'a.mkv'], 1000);
      write([documents.path, 'Imported', 'Season 1', 'b.MP4'], 500);
      write([documents.path, 'notes.txt'], 9000);
      write([documents.path, '.Trash', 'deleted.mkv'], 7000);
      write([cache.path, 'picker', 'copy.mov'], 300);
      write([cache.path, '.hidden-cache'], 20);

      final usage = await StorageUsageService(
        deviceDirectory: () async => documents,
        cacheDirectories: () async => [cache],
      ).measure();
      expect(usage.deviceVideos, const FolderUsage(files: 2, bytes: 1500));
      expect(usage.cache, const FolderUsage(files: 2, bytes: 320));
      expect(usage.totalBytes, 1820);

      final desktop = await StorageUsageService(
        deviceDirectory: () async => null,
        cacheDirectories: () async => throw const FileSystemException('no cache'),
      ).measure();
      expect(desktop.deviceVideos, isNull);
      expect(desktop.cache, isNull);
    });

    test('clears only the cache, keeps files in use and never follows links', () async {
      final video = write([documents.path, 'Imported', 'a.mkv'], 1000);
      final outside = write([root.path, 'User Movies', 'keep me.mkv'], 400);
      write([cache.path, 'picker', 'copy.mov'], 300);
      final inUse = write([cache.path, 'picker', 'playing.mkv'], 50);
      write([cache.path, 'loose.bin'], 10);
      Link(joinPath([cache.path, 'movies-link'])).createSync(outside.parent.path);

      final service = StorageUsageService(
        deviceDirectory: () async => documents,
        cacheDirectories: () async => [cache],
      );
      final result = await service.clearCache(keep: {inUse.path});
      expect(result.files, 2);
      expect(result.bytes, 310);
      expect(result.kept, 1);
      expect(inUse.existsSync(), isTrue);
      expect(File(joinPath([cache.path, 'picker', 'copy.mov'])).existsSync(), isFalse);
      expect(Link(joinPath([cache.path, 'movies-link'])).existsSync(), isFalse);
      expect(outside.existsSync(), isTrue);
      expect(video.existsSync(), isTrue);
      expect(cache.existsSync(), isTrue);
    });

    test('counts and clears every cache folder, including where iOS copies picked files', () async {
      // iOS: Library/Caches from path_provider, and tmp, where the document picker puts its copies.
      final caches = Directory(joinPath([root.path, 'Library', 'Caches']))..createSync(recursive: true);
      write([caches.path, 'thumbs', 'a.jpg'], 100);
      final picked = write([cache.path, 'com.example.danaview-Inbox', 'Holiday.mov'], 5000);
      final inUse = write([cache.path, 'com.example.danaview-Inbox', 'Playing.mp4'], 70);
      final missing = Directory(joinPath([root.path, 'gone']));
      // Listed twice and through a nested folder: still counted once.
      final service = StorageUsageService(
        deviceDirectory: () async => documents,
        cacheDirectories: () async => [caches, cache, cache, picked.parent, missing],
      );

      final usage = await service.measure();
      expect(usage.cache, const FolderUsage(files: 3, bytes: 5170));

      final result = await service.clearCache(keep: {inUse.path});
      expect(result.files, 2);
      expect(result.bytes, 5100);
      expect(result.kept, 1);
      expect(picked.existsSync(), isFalse);
      expect(inUse.existsSync(), isTrue);
      expect((await service.measure()).cache, const FolderUsage(files: 1, bytes: 70));

      final none = await StorageUsageService(
        deviceDirectory: () async => documents,
        cacheDirectories: () async => [missing],
      ).measure();
      expect(none.cache, isNull, reason: 'no cache folder exists');
    });

    test('refuses a cache folder that holds the documents folder', () async {
      final video = write([documents.path, 'a.mkv'], 10);
      final service = StorageUsageService(deviceDirectory: () async => documents, cacheDirectories: () async => [root]);
      final result = await service.clearCache();
      expect(result.files, 0);
      expect(video.existsSync(), isTrue);
    });
  });
}
