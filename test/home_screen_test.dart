import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'library_test_utils.dart';

const _longPlaylist = 'Weekend Anime Marathon With An Absurdly Long Playlist Name That Never Ends';

/// Scrolls the main list to the end, checking every step for layout errors.
Future<void> _scrollThrough(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 40; i++) {
    final position = tester.state<ScrollableState>(scrollable).position;
    if (position.pixels >= position.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  }
  await pumpFrames(tester, count: 10);
  expect(tester.takeException(), isNull);
}

Future<void> _tapShowAll(WidgetTester tester) async {
  final showAll = find.textContaining('Show all');
  await tester.scrollUntilVisible(showAll, 300, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(showAll);
  await tester.pump();
  await tester.tap(showAll);
  await pumpFrames(tester);
  expect(find.text('Show less'), findsOneWidget);
}

/// The [DanaviewGlyph] of [kind] inside the nearest [within] around [text]: by default the
/// [DanaviewPressable] of the library row showing it.
Finder _glyphIn(String text, DanaviewGlyphKind kind, {Type within = DanaviewPressable}) => find.descendant(
      of: find.ancestor(of: find.text(text), matching: find.byType(within)).first,
      matching: find.byWidgetPredicate((w) => w is DanaviewGlyph && w.kind == kind),
    );

Future<void> _finish(WidgetTester tester, LibraryTestEnv env) async {
  DanaviewToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await env.dispose();
}

void main() {
  late Directory tree;
  late String seasonPath;
  late DirectoryListing rootListing;
  late DirectoryListing seasonListing;

  setUpAll(() async {
    tree = createMediaTree();
    seasonPath = joinPath([tree.path, 'Season 1']);
    rootListing = await LibraryRepository.browseDirectory(tree.path);
    seasonListing = await LibraryRepository.browseDirectory(seasonPath);
  });

  tearDownAll(() => tree.deleteSync(recursive: true));

  List<Override> listingOverrides() => [
        folderListingProvider.overrideWith((ref, path) async => path == tree.path ? rootListing : seasonListing),
      ];

  group('no overflow', () {
    for (final surface in librarySurfaces) {
      testWidgets('Home at $surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        await seedLibrary(env, existingDir: tree.path);
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
          textScale: surface.textScale,
        ));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Open file'), findsOneWidget);
        expect(find.text('Continue watching'), findsOneWidget);

        await _tapShowAll(tester);
        await _scrollThrough(tester);
        expect(find.text('Folders'), findsOneWidget);
        await _finish(tester, env);
      });

      testWidgets('empty Home at $surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
          textScale: surface.textScale,
          platform: TargetPlatform.macOS,
        ));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('No playlists yet'), findsOneWidget);
        await _scrollThrough(tester);
        await _finish(tester, env);
      });

      testWidgets('Folder at $surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        await seedLibrary(env, existingDir: tree.path);
        for (final path in [tree.path, seasonPath]) {
          await tester.pumpWidget(libraryTestApp(
            env,
            DanaviewFolderScreen(
              key: ValueKey(path),
              path: path,
              onBack: () {},
              onOpenFolder: (_) {},
              onOpenPlayer: () {},
            ),
            textScale: surface.textScale,
            overrides: listingOverrides(),
          ));
          await pumpFrames(tester);
          expect(tester.takeException(), isNull);
          expect(find.text('Play all'), findsOneWidget);
          await _scrollThrough(tester);
        }
        await _finish(tester, env);
      });

      testWidgets('Playlist at $surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        await seedLibrary(env, existingDir: tree.path);
        for (var i = 0; i < 20; i++) {
          await env.library.addToPlaylist(_longPlaylist, [localRef(joinPath([tree.path, 'Movie $i - $longTitle.mp4']))]);
        }
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewPlaylistScreen(name: _longPlaylist, onBack: () {}, onOpenPlayer: () {}, onRenamed: (_) {}),
          textScale: surface.textScale,
        ));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Shuffle'), findsOneWidget);
        await _scrollThrough(tester);

        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewPlaylistScreen(name: 'Empty', onBack: () {}, onOpenPlayer: () {}, onRenamed: (_) {}),
          textScale: surface.textScale,
        ));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('This playlist is empty'), findsOneWidget);
        await _finish(tester, env);
      });
    }
  });

  group('Home', () {
    testWidgets('continue watching menu removes an entry and its resume point', (tester) async {
      useSurface(tester, librarySurfaces.first);
      final env = await LibraryTestEnv.create();
      await seedLibrary(env, existingDir: tree.path);
      final first = env.library.getRecentlyPlayed().first;
      expect(env.session.getResumeInfo(first.id), isNotNull);

      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
        textScale: 1.35,
      ));
      await pumpFrames(tester);
      await tester.tap(find.byTooltip('More').first);
      await pumpFrames(tester);
      expect(find.text('Add to playlist…'), findsOneWidget);
      await tester.tap(find.text('Remove from history'));
      await pumpFrames(tester);

      expect(tester.takeException(), isNull);
      expect(env.library.getRecentlyPlayed().map((m) => m.pathOrUri), isNot(contains(first.pathOrUri)));
      expect(env.session.getResumeInfo(first.id), isNull);
      await tester.scrollUntilVisible(find.text('Show all 10'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Show all 10'), findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('missing files are dimmed and labelled', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      await seedLibrary(env, existingDir: tree.path);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
      ));
      await pumpFrames(tester);
      await _tapShowAll(tester);
      await tester.scrollUntilVisible(find.text('File not found'), 300, scrollable: find.byType(Scrollable).first);
      final subtitle = find.text('File not found');
      expect(subtitle, findsOneWidget);
      double opacityOf(Finder finder) {
        var opacity = 1.0;
        tester.element(finder).visitAncestorElements((element) {
          final widget = element.widget;
          if (widget is Opacity) opacity *= widget.opacity;
          return true;
        });
        return opacity;
      }

      final row = find.ancestor(of: subtitle, matching: find.byType(Row)).last;
      final title = find.descendant(of: row, matching: find.textContaining('Missing Movie'));
      final leading = find.descendant(of: row, matching: find.byType(Icon)).first;
      expect(opacityOf(leading), lessThan(1));
      for (final text in [subtitle, title]) {
        expect(opacityOf(text), 1.0);
        final color = tester.widget<Text>(text).style!.color!;
        expect(DanaviewColors.contrastRatio(color, DanaviewColors.surface), greaterThanOrEqualTo(4.5));
      }
      await _finish(tester, env);
    });

    testWidgets('clips under a minute show their length in seconds', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      final clip = localRef(joinPath([seasonPath, 'Show.S01E01.$longTitle.mkv']));
      await env.library.recordPlayed(clip);
      await env.library.updateHistoryDuration(clip.pathOrUri, const Duration(seconds: 10));
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
      ));
      await pumpFrames(tester);
      expect(find.text('10s'), findsOneWidget);
      expect(find.text('1m'), findsNothing);
      await _finish(tester, env);
    });

    testWidgets('scrolled content slides under an opaque status-bar backdrop', (tester) async {
      final surface = librarySurfaces[2];
      useSurface(tester, surface);
      final env = await LibraryTestEnv.create();
      await seedLibrary(env, existingDir: tree.path);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
      ));
      await pumpFrames(tester);
      final statusBar = surface.padding.top;
      Finder backdrop(Color edge) => find.byWidgetPredicate((w) {
            if (w is! DecoratedBox || w.decoration is! BoxDecoration) return false;
            final decoration = w.decoration as BoxDecoration;
            final border = decoration.border;
            return decoration.color == DanaviewColors.background &&
                border is Border &&
                border.bottom.color == edge;
          });

      expect(tester.getRect(find.byType(Scrollable).first).top, moreOrLessEquals(statusBar));
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await pumpFrames(tester);
      final strip = backdrop(DanaviewColors.hairline);
      expect(strip, findsOneWidget);
      expect(tester.getRect(strip), Rect.fromLTWH(0, 0, surface.size.width, statusBar));
      await _finish(tester, env);
    });

    testWidgets('new playlist prompt validates live, creates, and opens the playlist', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      await env.library.createPlaylist('Movies');
      String? opened;
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (name) => opened = name),
      ));
      await pumpFrames(tester);
      await tester.tap(find.text('New'));
      await pumpFrames(tester);
      await tester.enterText(find.byType(EditableText), 'movies');
      await tester.tap(find.text('Create'));
      await pumpFrames(tester);
      expect(find.text('That name is already used by another playlist.'), findsOneWidget);

      await tester.enterText(find.byType(EditableText), 'Anime');
      await pumpFrames(tester);
      expect(find.textContaining('already used'), findsNothing);
      await tester.tap(find.text('Create'));
      await pumpFrames(tester);
      expect(opened, 'Anime');
      expect(env.library.getSavedPlaylistNames(), ['Movies', 'Anime']);
      expect(find.text('Anime'), findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('deleting a playlist asks first and keeps the videos', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      await env.library.createPlaylist('Movies');
      await env.library.addToPlaylist('Movies', [localRef(joinPath([tree.path, 'Movie 1 - $longTitle.mp4']))]);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
      ));
      await pumpFrames(tester);
      await tester.tap(find.byTooltip('More'));
      await pumpFrames(tester);
      await tester.tap(find.text('Delete'));
      await pumpFrames(tester);
      expect(find.text('"Movies" will be deleted. The videos stay on disk.'), findsOneWidget);
      await tester.tap(find.widgetWithText(DanaviewButton, 'Delete'));
      await pumpFrames(tester);
      expect(env.library.getSavedPlaylistNames(), isEmpty);
      expect(find.text('No playlists yet'), findsOneWidget);
      expect(File(joinPath([tree.path, 'Movie 1 - $longTitle.mp4'])).existsSync(), isTrue);
      await _finish(tester, env);
    });

    testWidgets('add to playlist sheet adds once and reports duplicates', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      await seedLibrary(env, existingDir: tree.path);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
      ));
      await pumpFrames(tester);
      final first = env.library.getRecentlyPlayed().first;

      Future<void> addFirstTo(String playlist) async {
        await tester.tap(find.byTooltip('More').first);
        await pumpFrames(tester);
        await tester.tap(find.text('Add to playlist…'));
        await pumpFrames(tester);
        await tester.tap(find.text(playlist).last);
        await pumpFrames(tester);
      }

      expect(env.library.getPlaylist('Empty'), isEmpty);
      await addFirstTo('Empty');
      expect(env.library.getPlaylist('Empty').map((m) => m.pathOrUri), [first.pathOrUri]);
      expect(find.text('Added to Empty'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));

      await addFirstTo('Empty');
      expect(env.library.getPlaylist('Empty'), hasLength(1));
      expect(find.text('Already in Empty'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('mobile shows the device folder first with a Files app hint', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final documents = Directory.systemTemp.createTempSync('danaview_documents_');
      addTearDown(() => documents.deleteSync(recursive: true));
      final env = await LibraryTestEnv.create(
        storage: LibraryStorage(isMobile: true, documentsDirectory: () async => documents),
      );
      await env.library.addFolder(tree.path);
      String? opened;
      await tester.runAsync(() async {
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (path) => opened = path, onOpenPlaylist: (_) {}),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await pumpFrames(tester);
      await _scrollThrough(tester);

      expect(find.text(LibraryRepository.deviceFolderLabel), findsOneWidget);
      expect(find.text('Files app › On My iPhone › Danaview'), findsOneWidget);
      final deviceTop = tester.getTopLeft(find.text(LibraryRepository.deviceFolderLabel)).dy;
      final userTop = tester.getTopLeft(find.text(tree.path)).dy;
      expect(deviceTop, lessThan(userTop));
      expect(_glyphIn(LibraryRepository.deviceFolderLabel, DanaviewGlyphKind.device), findsOneWidget);
      expect(_glyphIn(tree.path, DanaviewGlyphKind.folderVideo), findsOneWidget);

      await tester.tap(find.text(LibraryRepository.deviceFolderLabel));
      await tester.pump();
      expect(opened, documents.path);
      await _finish(tester, env);
    });
  });

  group('Home glyphs', () {
    testWidgets('quick actions and the empty Folders section draw the folder glyphs', (tester) async {
      useSurface(tester, librarySurfaces[4]);
      final env = await LibraryTestEnv.create();
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
        platform: TargetPlatform.macOS,
      ));
      await pumpFrames(tester);
      expect(
        find.descendant(
          of: find.ancestor(of: find.text('Open folder'), matching: find.byType(DanaviewPressable)).first,
          matching: find.byWidgetPredicate((w) => w is DanaviewGlyph && w.kind == DanaviewGlyphKind.folderOpen),
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(find.text('No folders yet'), 300, scrollable: find.byType(Scrollable).first);
      await pumpFrames(tester);
      expect(_glyphIn('No folders yet', DanaviewGlyphKind.folderVideo, within: DanaviewSurface), findsOneWidget);
      expect(_glyphIn('Add folder', DanaviewGlyphKind.folderAdd, within: DanaviewButton), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('the folder menu opens with the open-folder glyph and removes with its own icon', (tester) async {
      useSurface(tester, librarySurfaces[4]);
      final env = await LibraryTestEnv.create();
      await env.library.addFolder(tree.path);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
        platform: TargetPlatform.macOS,
      ));
      await pumpFrames(tester);
      final more = find.descendant(
        of: find.ancestor(of: find.text(tree.path), matching: find.byType(DanaviewPressable)).first,
        matching: find.byTooltip('More'),
      );
      await tester.scrollUntilVisible(more, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(more);
      await pumpFrames(tester);
      expect(find.byWidgetPredicate((w) => w is DanaviewGlyph && w.kind == DanaviewGlyphKind.folderOpen), findsWidgets);

      await tester.tap(find.text('Remove from library'));
      await pumpFrames(tester);
      // The confirm keeps the menu entry's metaphor; the slashed folder means "can't open".
      expect(find.descendant(of: find.byType(DanaviewDialog), matching: find.byIcon(Icons.remove_circle_outline_rounded)),
          findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is DanaviewGlyph && w.kind == DanaviewGlyphKind.folderOff), findsNothing);
      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester);
      expect(env.library.getFolders().map((f) => f.path), contains(tree.path));
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });
  });

  group('Folder', () {
    testWidgets('lists subfolders first, then videos, and plays from the tapped one', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      await env.library.addFolder(tree.path);
      var played = 0;
      String? openedFolder;
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewFolderScreen(
          path: tree.path,
          onBack: () {},
          onOpenFolder: (path) => openedFolder = path,
          onOpenPlayer: () => played++,
        ),
        overrides: listingOverrides(),
      ));
      await pumpFrames(tester);

      final folderTop = tester.getTopLeft(find.text('Season 1')).dy;
      final videoTop = tester.getTopLeft(find.text(rootListing.media.first.title)).dy;
      expect(folderTop, lessThan(videoTop));
      expect(find.text('9 videos'), findsOneWidget);
      expect(_glyphIn('Season 1', DanaviewGlyphKind.folder), findsOneWidget);

      await tester.tap(find.text('Season 1'));
      expect(openedFolder, seasonPath);

      await tester.tap(find.text(rootListing.media[1].title));
      await pumpFrames(tester);
      expect(played, 1);
      final container = ProviderScope.containerOf(tester.element(find.byType(DanaviewFolderScreen)));
      final queue = container.read(queueControllerProvider);
      expect(queue.items.length, rootListing.media.length);
      expect(queue.currentIndex, 1);
      await _finish(tester, env);
    });

    testWidgets('breadcrumb on wide screens jumps to an ancestor', (tester) async {
      useSurface(tester, librarySurfaces[4]);
      final env = await LibraryTestEnv.create();
      await env.library.addFolder(tree.path);
      String? jumped;
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewFolderScreen(
          path: seasonPath,
          onBack: () {},
          onOpenFolder: (_) {},
          onJumpToFolder: (path) => jumped = path,
          onOpenPlayer: () {},
        ),
        overrides: listingOverrides(),
        platform: TargetPlatform.macOS,
      ));
      await pumpFrames(tester);
      final rootLabel = env.library.getFolders().single.label;
      expect(_glyphIn(rootLabel, DanaviewGlyphKind.folderVideo, within: DanaviewButton), findsOneWidget);
      await tester.tap(find.widgetWithText(DanaviewButton, rootLabel));
      expect(jumped, tree.path);
      expect(find.text('S01E01'), findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('reads the disk and shows unreadable folders as an empty state', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      final missing = joinPath([tree.path, 'does-not-exist']);
      await tester.runAsync(() async {
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewFolderScreen(path: missing, onBack: () {}, onOpenFolder: (_) {}, onOpenPlayer: () {}),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await pumpFrames(tester);
      expect(find.text("Can't open this folder"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(_glyphIn("Can't open this folder", DanaviewGlyphKind.folderOff, within: DanaviewEmptyState), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.runAsync(() async {
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewFolderScreen(
            key: const ValueKey('season'),
            path: seasonPath,
            onBack: () {},
            onOpenFolder: (_) {},
            onOpenPlayer: () {},
          ),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await pumpFrames(tester);
      expect(find.text('Play all'), findsOneWidget);
      expect(find.text('S01E01'), findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('an empty device folder explains how to add videos', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final documents = Directory.systemTemp.createTempSync('danaview_documents_');
      addTearDown(() => documents.deleteSync(recursive: true));
      final env = await LibraryTestEnv.create(
        storage: LibraryStorage(isMobile: true, documentsDirectory: () async => documents),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewFolderScreen(path: documents.path, onBack: () {}, onOpenFolder: (_) {}, onOpenPlayer: () {}),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await pumpFrames(tester);
      expect(find.text(LibraryRepository.deviceFolderLabel), findsOneWidget);
      expect(find.text('No videos on this device yet'), findsOneWidget);
      expect(_glyphIn('No videos on this device yet', DanaviewGlyphKind.device, within: DanaviewEmptyState), findsOneWidget);
      expect(find.textContaining('On My iPhone › Danaview'), findsOneWidget);
      await _finish(tester, env);
    });
  });

  group('Playlist', () {
    Future<LibraryTestEnv> playlistEnv() async {
      final env = await LibraryTestEnv.create();
      await env.library.createPlaylist('Mix');
      await env.library.addToPlaylist('Mix', [
        for (var i = 1; i <= 4; i++) localRef(joinPath([tree.path, 'Movie $i - $longTitle.mp4'])),
      ]);
      return env;
    }

    List<String> titles(LibraryTestEnv env) => env.library.getPlaylist('Mix').map((m) => m.title).toList();

    testWidgets('drag handle reorders the playlist', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await playlistEnv();
      final before = titles(env);
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewPlaylistScreen(name: 'Mix', onBack: () {}, onOpenPlayer: () {}, onRenamed: (_) {}),
      ));
      await pumpFrames(tester);

      final handles = find.byIcon(Icons.drag_indicator_rounded);
      final rowHeight = tester.getCenter(handles.at(1)).dy - tester.getCenter(handles.at(0)).dy;
      final gesture = await tester.startGesture(tester.getCenter(handles.first));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(Offset(0, rowHeight * 0.2));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await pumpFrames(tester);

      expect(tester.takeException(), isNull);
      expect(titles(env), [before[1], before[2], before[0], before[3]]);
      await _finish(tester, env);
    });

    testWidgets('row menu removes an item; rename and delete go through the top bar menu', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await playlistEnv();
      String? renamedTo;
      var backs = 0;
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewPlaylistScreen(
          name: 'Mix',
          onBack: () => backs++,
          onOpenPlayer: () {},
          onRenamed: (name) => renamedTo = name,
        ),
      ));
      await pumpFrames(tester);

      await tester.tap(find.byTooltip('More').first);
      await pumpFrames(tester);
      await tester.tap(find.text('Remove from playlist'));
      await pumpFrames(tester);
      expect(env.library.getPlaylist('Mix'), hasLength(3));

      await tester.tap(find.byTooltip('Playlist options'));
      await pumpFrames(tester);
      await tester.tap(find.text('Rename'));
      await pumpFrames(tester);
      await tester.enterText(find.byType(EditableText), 'Late Night');
      await tester.tap(find.widgetWithText(DanaviewButton, 'Rename'));
      await pumpFrames(tester);
      expect(renamedTo, 'Late Night');
      expect(env.library.getPlaylist('Late Night'), hasLength(3));
      expect(find.text('Late Night'), findsOneWidget);

      await tester.tap(find.byTooltip('Playlist options'));
      await pumpFrames(tester);
      await tester.tap(find.text('Delete playlist'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(DanaviewButton, 'Delete'));
      await pumpFrames(tester);
      expect(backs, 1);
      expect(env.library.getSavedPlaylistNames(), isEmpty);
      expect(find.text('Playlist not found'), findsNothing);
      await _finish(tester, env);
    });

    testWidgets('add link validates and appends a stream', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await playlistEnv();
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewPlaylistScreen(name: 'Mix', onBack: () {}, onOpenPlayer: () {}, onRenamed: (_) {}),
      ));
      await pumpFrames(tester);
      await tester.tap(find.text('Add link'));
      await pumpFrames(tester);
      await tester.enterText(find.byType(EditableText), 'javascript:alert(1)');
      await tester.tap(find.widgetWithText(DanaviewButton, 'Add'));
      await pumpFrames(tester);
      expect(find.text(MediaUrl.validationError('javascript:alert(1)')!), findsOneWidget);

      await tester.enterText(find.byType(EditableText), 'https://cdn.example.com/live/master.m3u8');
      await tester.tap(find.widgetWithText(DanaviewButton, 'Add'));
      await pumpFrames(tester);
      final items = env.library.getPlaylist('Mix');
      expect(items, hasLength(5));
      expect(items.last.isRemote, isTrue);
      expect(find.text('Added to Mix'), findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('Now Playing card displays error state on failure and clear button dismisses card', (tester) async {
      final env = await LibraryTestEnv.create();
      final engine = FakePlaybackEngine();
      await engine.initialize();
      final item = remoteRef('https://example.com/stream.m3u8');

      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
        overrides: [
          playbackEngineProvider.overrideWithValue(engine),
        ],
      ));
      await pumpFrames(tester);

      final container = ProviderScope.containerOf(tester.element(find.byType(DanaviewHomeScreen)));
      await container.read(queueControllerProvider.notifier).playFrom([item]);
      await pumpFrames(tester);

      expect(find.text('NOW PLAYING'), findsOneWidget);
      expect(find.byTooltip('Clear'), findsOneWidget);

      // Simulate player error
      engine.emitMockError(const UnsupportedFormat('stream.m3u8', details: 'Unrecognized'));
      await pumpFrames(tester);

      expect(find.text('COULD NOT PLAY'), findsOneWidget);
      expect(find.byTooltip('Retry'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsWidgets);

      // Tap Clear to dismiss
      await tester.tap(find.byTooltip('Clear'));
      await pumpFrames(tester);

      expect(find.text('COULD NOT PLAY'), findsNothing);
      expect(find.text('NOW PLAYING'), findsNothing);

      await engine.dispose();
      await _finish(tester, env);
    });
  });
}
