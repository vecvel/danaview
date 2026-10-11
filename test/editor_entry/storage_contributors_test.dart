// OWNER: UX-04
//
// Settings › Storage contributors and the Settings "Video editor" row (ARCH §17.10, ux.md §4.8):
// `vwish_features` renders storage owned by other packages through `StorageContributor` without
// depending on them. Fake contributors stand in for the editor and speech ones.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_features/storage.dart';
import 'package:vwish_features/vwish_features.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../library_test_utils.dart';

/// Fixed app figures; records clean-ups instead of touching the disk.
class _FakeStorage extends StorageUsageService {
  _FakeStorage() : super(deviceDirectory: () async => null, cacheDirectories: () async => const []);

  final List<Set<String>> cleared = [];

  @override
  Future<StorageUsage> measure() async => const StorageUsage(
        deviceVideos: FolderUsage(files: 3, bytes: 3000000000),
        cache: FolderUsage(files: 10, bytes: 50000000),
      );

  @override
  Future<CacheClearResult> clearCache({Set<String> keep = const {}}) async {
    cleared.add(keep);
    return const CacheClearResult();
  }
}

class _FakeContributor extends StorageContributor {
  _FakeContributor({
    required this.id,
    required this.title,
    required this.usage,
    this.section = 'Video editor',
    this.subtitle = 'What it keeps.',
    this.icon = Icons.movie_edit,
    this.withClear = false,
    this.withOpen = false,
    this.clearResult = const StorageClearOutcome.done(freedBytes: 240000000),
    this.owned = const {},
    this.failMeasure = false,
  });

  @override
  final String id;
  @override
  final String section;
  @override
  final String title;
  @override
  final String subtitle;
  @override
  final IconData icon;

  StorageContributorUsage usage;
  final bool withClear;
  final bool withOpen;
  StorageClearOutcome clearResult;
  final Set<String> owned;
  final bool failMeasure;

  int measured = 0;
  int cleared = 0;
  final List<BuildContext> opened = [];

  @override
  Stream<StorageContributorUsage> watchUsage() async* {
    measured++;
    if (failMeasure) throw StateError('unreadable');
    yield usage;
  }

  @override
  StorageClearAction? get clearAction => withClear
      ? StorageClearAction(
          label: 'Clear $title',
          confirmTitle: 'Clear $title?',
          confirmMessage: 'Made again when needed. Your projects stay.',
          run: () async {
            cleared++;
            if (clearResult.done) usage = const StorageContributorUsage(bytes: 0);
            return clearResult;
          },
        )
      : null;

  @override
  StorageOpenAction? get openAction => withOpen ? StorageOpenAction(label: 'Opens Projects', onOpen: opened.add) : null;

  @override
  Set<String> get ownedPaths => owned;
}

_FakeContributor _projects() => _FakeContributor(
      id: 'editor.projects',
      title: 'Video editor projects',
      subtitle: 'Delete projects in Projects to free this space.',
      usage: const StorageContributorUsage(bytes: 1200000000, detail: '3 projects'),
      withOpen: true,
    );

_FakeContributor _cache({StorageContributorUsage usage = const StorageContributorUsage(bytes: 240000000)}) =>
    _FakeContributor(
      id: 'editor.cache',
      title: 'Editor cache',
      subtitle: 'Thumbnails and waveforms, made again when needed.',
      icon: Icons.auto_awesome_motion_rounded,
      usage: usage,
      withClear: true,
      owned: {'/cache/vwish/editor'},
    );

Future<(LibraryTestEnv, _FakeStorage)> _pumpStorage(
  WidgetTester tester,
  List<StorageContributor> contributors, {
  TestSurface? surface,
}) async {
  final s = surface ?? librarySurfaces[2];
  useSurface(tester, s);
  final env = await LibraryTestEnv.create();
  final storage = _FakeStorage();
  await tester.pumpWidget(libraryTestApp(
    env,
    VwishStorageScreen(onBack: () {}),
    textScale: s.textScale,
    overrides: [
      storageUsageServiceProvider.overrideWithValue(storage),
      storageContributorsProvider.overrideWithValue(contributors),
    ],
  ));
  await pumpFrames(tester);
  return (env, storage);
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.pump();
  await tester.tap(finder);
  await pumpFrames(tester);
}

Future<void> _finish(WidgetTester tester, LibraryTestEnv env) async {
  VwishToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await env.dispose();
}

Finder _row(String id) => find.byKey(ValueKey('storage-contributor-$id'));

Finder _clearRow(String id) => find.byKey(ValueKey('storage-contributor-$id-clear'));

void main() {
  group('Storage screen contributors', () {
    testWidgets('each contributor shows its size under its section and the total includes it', (tester) async {
      final projects = _projects();
      final cache = _cache();
      final (env, _) = await _pumpStorage(tester, [projects, cache]);

      expect(find.text('Video editor'), findsWidgets);
      await tester.scrollUntilVisible(_row('editor.projects'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Video editor projects'), findsOneWidget);
      expect(find.text('3 projects · 1.2 GB'), findsOneWidget);
      expect(find.text('Editor cache'), findsOneWidget);
      expect(find.text('240 MB'), findsOneWidget);
      final footnote =
          find.text('Delete projects in Projects to free this space. Thumbnails and waveforms, made again when needed.');
      await tester.scrollUntilVisible(footnote, 200, scrollable: find.byType(Scrollable).first);
      expect(footnote, findsOneWidget);
      // 3 GB videos + 50 MB cache + 1.2 GB projects + 240 MB editor cache.
      tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
      await pumpFrames(tester);
      expect(find.text('4.49 GB'), findsOneWidget);
      expect(find.textContaining('Video editor is included.'), findsOneWidget);
      expect(projects.measured, 1);
      expect(cache.measured, 1);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('a contributor with an open action opens its screen; one without a clear action has no clean-up row',
        (tester) async {
      final projects = _projects();
      final (env, _) = await _pumpStorage(tester, [projects, _cache()]);

      expect(_clearRow('editor.projects'), findsNothing);
      expect(find.text('Clear Video editor projects'), findsNothing);
      expect(find.descendant(of: _row('editor.projects'), matching: find.byIcon(Icons.chevron_right_rounded)), findsOneWidget);
      expect(find.descendant(of: _row('editor.cache'), matching: find.byIcon(Icons.chevron_right_rounded)), findsNothing);
      await _tapVisible(tester, _row('editor.projects'));
      expect(projects.opened, hasLength(1));
      expect(find.bySemanticsLabel(RegExp('Video editor projects.*Opens Projects')), findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('clearing asks with the contributor copy, runs only after Clear and measures again', (tester) async {
      final cache = _cache();
      final (env, storage) = await _pumpStorage(tester, [_projects(), cache]);

      await _tapVisible(tester, find.text('Clear Editor cache'));
      expect(find.text('Clear Editor cache?'), findsOneWidget);
      expect(find.text('Made again when needed. Your projects stay.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester);
      expect(cache.cleared, 0);

      await _tapVisible(tester, find.text('Clear Editor cache'));
      await tester.tap(find.text('Clear'));
      await pumpFrames(tester);
      expect(cache.cleared, 1);
      expect(cache.measured, 2);
      expect(find.text('Freed 240 MB'), findsOneWidget);
      expect(find.text('Nothing to clear'), findsOneWidget);
      // The app's own cache was never cleared by a contributor's clean-up.
      expect(storage.cleared, isEmpty);
      await _finish(tester, env);
    });

    testWidgets('a clean-up that is blocked is disabled and shows why', (tester) async {
      final cache = _cache(
        usage: const StorageContributorUsage(bytes: 240000000, clearBlockedReason: 'Close the video editor to clear its cache.'),
      );
      final (env, _) = await _pumpStorage(tester, [cache]);

      await tester.scrollUntilVisible(_clearRow('editor.cache'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.descendant(of: _clearRow('editor.cache'), matching: find.text('Close the video editor to clear its cache.')),
          findsOneWidget);
      await tester.tap(_clearRow('editor.cache'), warnIfMissed: false);
      await pumpFrames(tester);
      expect(find.text('Clear Editor cache?'), findsNothing);
      expect(cache.cleared, 0);
      await _finish(tester, env);
    });

    testWidgets('a clean-up that reports blocked at run time deletes nothing and tells why', (tester) async {
      final cache = _cache()..clearResult = const StorageClearOutcome.blocked('An export is running. Clear the cache when it finishes.');
      final (env, _) = await _pumpStorage(tester, [cache]);

      await _tapVisible(tester, find.text('Clear Editor cache'));
      await tester.tap(find.text('Clear'));
      await pumpFrames(tester);
      expect(cache.cleared, 1);
      expect(find.text('An export is running. Clear the cache when it finishes.'), findsOneWidget);
      expect(find.text('Frees about 240 MB'), findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('a contributor that cannot be measured says so', (tester) async {
      final broken = _FakeContributor(
        id: 'speech.model',
        section: 'Auto captions',
        title: 'Speech model',
        usage: const StorageContributorUsage(bytes: 0),
        failMeasure: true,
        withClear: true,
      );
      final (env, _) = await _pumpStorage(tester, [broken]);
      await tester.scrollUntilVisible(_row('speech.model'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text("Couldn't be measured"), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    for (final surface in librarySurfaces) {
      testWidgets('contributors without overflow at $surface', (tester) async {
        final long = _FakeContributor(
          id: 'long',
          section: 'A section header that is much longer than any real one would be',
          title: 'A contributor title that keeps going far beyond the width of a phone',
          subtitle: 'An explanation long enough to wrap over several lines on the narrowest phones in the matrix.',
          usage: const StorageContributorUsage(
            bytes: 987654321098,
            detail: '12,345 projects with very long names',
            complete: false,
            clearBlockedReason: 'Close the video editor to clear its cache before trying again later today.',
          ),
          withClear: true,
          withOpen: true,
        );
        final (env, _) = await _pumpStorage(tester, [_projects(), _cache(), long], surface: surface);
        expect(tester.takeException(), isNull);
        final scrollable = find.byType(Scrollable).first;
        for (var i = 0; i < 40; i++) {
          final position = tester.state<ScrollableState>(scrollable).position;
          if (position.pixels >= position.maxScrollExtent) break;
          await tester.drag(scrollable, const Offset(0, -400));
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
        }
        await _finish(tester, env);
      });
    }
  });

  group('StorageUsageService and contributor-owned folders', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('vwish_storage_contributors_'));
    tearDown(() => root.deleteSync(recursive: true));

    File write(String rel, int bytes) {
      final file = File(joinPath([root.path, ...rel.split('/')]));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(List.filled(bytes, 1));
      return file;
    }

    test("owned folders are left out of the cache figure and survive the app's Clear cache", () async {
      final cache = Directory(joinPath([root.path, 'cache']))..createSync();
      final appTemp = write('cache/picked/movie.mp4', 1000);
      final thumb = write('cache/vwish/editor/thumbs/a.jpg', 300);
      final work = write('cache/vwish/editor/work/picks/x/clip.mov', 500);
      final sibling = write('cache/vwish/other.bin', 70);
      final service = StorageUsageService(
        deviceDirectory: () async => null,
        cacheDirectories: () async => [cache],
        excludedPaths: {joinPath([cache.path, 'vwish', 'editor'])},
      );

      final usage = await service.measure();
      expect(usage.cache, const FolderUsage(files: 2, bytes: 1070));

      final result = await service.clearCache();
      expect(result.bytes, 1070);
      expect(appTemp.existsSync(), isFalse);
      expect(sibling.existsSync(), isFalse);
      expect(thumb.existsSync(), isTrue);
      expect(work.existsSync(), isTrue);
    });

    test('an owned folder that does not exist yet changes nothing', () async {
      final cache = Directory(joinPath([root.path, 'cache']))..createSync();
      write('cache/a.bin', 10);
      final service = StorageUsageService(
        deviceDirectory: () async => null,
        cacheDirectories: () async => [cache],
        excludedPaths: {joinPath([cache.path, 'vwish', 'editor'])},
      );
      expect((await service.measure()).cache, const FolderUsage(files: 1, bytes: 10));
    });

    test('the provider passes every contributor-owned folder to the service', () async {
      final env = await LibraryTestEnv.create();
      final container = ProviderContainer(overrides: [
        ...env.overrides,
        storageContributorsProvider.overrideWithValue([_projects(), _cache()]),
      ]);
      addTearDown(container.dispose);
      addTearDown(env.dispose);
      expect(container.read(storageUsageServiceProvider).excludedPaths, {'/cache/vwish/editor'});
    });
  });

  group('Settings "Video editor" row', () {
    Future<LibraryTestEnv> pumpSettings(WidgetTester tester, {VoidCallback? onOpenEditorSettings, TestSurface? surface}) async {
      final s = surface ?? librarySurfaces[2];
      useSurface(tester, s);
      final env = await LibraryTestEnv.create();
      await tester.pumpWidget(libraryTestApp(
        env,
        VwishSettingsScreen(onBack: () {}, onNavigate: (_) {}, onOpenEditorSettings: onOpenEditorSettings),
        textScale: s.textScale,
      ));
      await pumpFrames(tester);
      return env;
    }

    testWidgets('is hidden when the callback is null', (tester) async {
      final env = await pumpSettings(tester);
      expect(find.byKey(const ValueKey('settings-video-editor')), findsNothing);
      expect(find.text('Video editor'), findsNothing);
      expect(find.byIcon(Icons.movie_edit), findsNothing);
      await _finish(tester, env);
    });

    testWidgets('is shown in Tools and opens the editor settings', (tester) async {
      var opened = 0;
      final env = await pumpSettings(tester, onOpenEditorSettings: () => opened++);
      final row = find.byKey(const ValueKey('settings-video-editor'));
      await _tapVisible(tester, row);
      expect(opened, 1);
      expect(find.text('Video editor'), findsOneWidget);
      expect(find.text('Proxy media, preview quality and new projects'), findsOneWidget);
      // Listed right after Storage & history.
      expect(tester.getTopLeft(row).dy, greaterThan(tester.getTopLeft(find.text('Storage & history')).dy));
      await _finish(tester, env);
    });

    for (final surface in librarySurfaces) {
      testWidgets('without overflow at $surface', (tester) async {
        final env = await pumpSettings(tester, onOpenEditorSettings: () {}, surface: surface);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('settings-video-editor')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        await _finish(tester, env);
      });
    }
  });
}
