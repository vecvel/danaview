// OWNER: HOM-18
//
// BUILD_PLAN HOM-18, filters half (ARCH v1.2 V2-114; HOM plan §5.2, §8.1):
// * each filter shows exactly the classifier's kinds over a fixture library (every kind, every
//   Documents sub-filter, and a kind of a newer build that shows only under All);
// * the Documents filter and its tab are hidden in slice S2 behind HOM-18's switch (BUILD_PLAN
//   §1A), and appear when the switch is on;
// * linked-folder documents are read-only: Open only, no Rename / Move / Delete;
// * the Videos tab keeps the player hub (Continue watching, playlists, video folders) and grids
//   the library's videos with HOM-13's badges (duration, resolution, frame rate, HDR);
// * a write re-reads the lists in the next frame;
// * the matrix 280–1280 px × text scale 0.85–1.35 with no overflow, ≥ 44 px targets, semantics
//   labels (ARCH §1.4).

// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/badges/media_badges.dart';
import 'package:danaview_features/src/library/filters/entry_widgets.dart';
import 'package:danaview_features/src/library/filters/filter_providers.dart';
import 'package:danaview_features/src/library/filters/library_filters.dart';
import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/tabs/all_tab.dart';
import 'package:danaview_features/src/library/tabs/documents_tab.dart';
import 'package:danaview_features/src/library/tabs/videos_tab.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../home_shell/home_shell_support.dart' show finishHome, useFilesHome;
import 'filters_support.dart';

/// The names the classifier puts under [filter] (and [sub]) among [entries].
Set<String> _expected(Map<String, FileEntry> entries, LibraryFilter filter, {DocumentKind? sub}) => {
      for (final e in entries.values)
        if (filter.matchesEntry(e, subFilter: sub)) e.displayName,
    };

Set<String> _shownRows(WidgetTester tester, Map<String, FileEntry> entries) => {
      for (final e in entries.values)
        if (find.byKey(ValueKey('library-entry-${e.id.value}')).evaluate().isNotEmpty) e.displayName,
    };

void main() {
  group('the S2 switch', () {
    test('Documents is hidden by default and shown when the switch is on', () {
      expect(documentsFilterShown, isFalse);
      expect(visibleLibraryFilters(), [LibraryFilter.all, LibraryFilter.videos, LibraryFilter.photos]);
      expect(visibleLibraryFilters(showDocuments: true), LibraryFilter.values);

      Widget body(BuildContext _) => const SizedBox();
      final hidden = libraryFilterTabSlots(all: body, videos: body, documents: body, folders: body);
      expect(hidden.showDocuments, isFalse);
      expect(hidden.documents, isNull);
      expect(hidden.bodyOf(HomeTab.all), isNotNull);
      expect(hidden.bodyOf(HomeTab.folders), isNotNull);
      expect(visibleHomeTabs(platform: TargetPlatform.iOS, projectsAvailable: false, showDocuments: hidden.showDocuments),
          isNot(contains(HomeTab.documents)));

      final shown = libraryFilterTabSlots(documents: body, showDocuments: true);
      expect(shown.showDocuments, isTrue);
      expect(shown.documents, isNotNull);
    });

    test('the slots keep the base photos tab, Overview slots and selection bar', () {
      Widget a(BuildContext _) => const SizedBox();
      Widget b(BuildContext _) => const SizedBox();
      final base = HomeTabSlots(photos: a, recentPhotos: a, favourites: a, selectionBar: a, projects: a);
      final slots = libraryFilterTabSlots(base: base, all: b);
      expect(slots.photos, same(a));
      expect(slots.recentPhotos, same(a));
      expect(slots.favourites, same(a));
      expect(slots.selectionBar, same(a));
      expect(slots.projects, same(a));
      expect(slots.all, same(b));
    });

    testWidgets('the Home strip has no Documents tab with the S2 slots', (tester) async {
      useFilesHome(true);
      useSurface(tester, const TestSurface(Size(1280, 800), 1.0));
      final env = await LibraryTestEnv.create();
      Widget body(BuildContext _) => const SizedBox();
      Future<void> pumpHome(HomeTabSlots slots) async {
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}, tabSlots: slots),
        ));
        await pumpFrames(tester);
      }

      await pumpHome(libraryFilterTabSlots(all: body, videos: body, documents: body, folders: body));
      expect(find.byKey(homeTabKey(HomeTab.all)), findsOneWidget);
      expect(find.byKey(homeTabKey(HomeTab.videos)), findsOneWidget);
      expect(find.byKey(homeTabKey(HomeTab.folders)), findsOneWidget);
      expect(find.byKey(homeTabKey(HomeTab.documents)), findsNothing);

      await pumpHome(libraryFilterTabSlots(documents: body, showDocuments: true));
      expect(find.byKey(homeTabKey(HomeTab.documents)), findsOneWidget);
      await finishHome(tester, env);
    });
  });

  group('filters over a fixture library', () {
    test('LibraryFilter.matches follows the kinds', () {
      for (final kind in FileKind.values) {
        expect(LibraryFilter.all.matches(kind), isTrue);
        expect(LibraryFilter.videos.matches(kind), kind == FileKind.video);
        expect(LibraryFilter.photos.matches(kind), kind == FileKind.photo);
        expect(LibraryFilter.documents.matches(kind), kind == FileKind.document);
      }
      expect(documentSubFilters.first, isNull);
      expect([for (final s in documentSubFilters.skip(1)) documentSubFilterLabel(s)],
          ['PDF', 'Word', 'Excel', 'PowerPoint', 'Text/CSV', 'Other']);
    });

    testWidgets('each filter list holds exactly the classifier kinds', (tester) async {
      final lib = await FixtureLibrary.open(tester);
      final entries = await lib.seedFixture(tester);
      final container = ProviderContainer(overrides: [libraryStoreProvider.overrideWithValue(lib.store)]);

      Set<String> names(LibraryFilter f, [DocumentKind? sub]) =>
          {for (final e in container.read(libraryFilterEntriesProvider((filter: f, subFilter: sub))).toList()) e.displayName};

      expect(names(LibraryFilter.all), {...fixtureFileNames, 'Wifi code.dvcode'});
      expect(names(LibraryFilter.videos), {'Holiday.mp4', 'Interview.mov'});
      expect(names(LibraryFilter.photos), {'Beach.jpg', 'Portrait.heic'});
      expect(names(LibraryFilter.documents), {'Report.pdf', 'Letter.docx', 'Budget.xlsx', 'Pitch.pptx', 'Notes.txt', 'Data.csv', 'Archive.zip'});
      for (final filter in LibraryFilter.values) {
        expect(names(filter), _expected(entries, filter), reason: filter.name);
      }
      expect(names(LibraryFilter.documents, DocumentKind.pdf), {'Report.pdf'});
      expect(names(LibraryFilter.documents, DocumentKind.word), {'Letter.docx'});
      expect(names(LibraryFilter.documents, DocumentKind.excel), {'Budget.xlsx'});
      expect(names(LibraryFilter.documents, DocumentKind.powerpoint), {'Pitch.pptx'});
      expect(names(LibraryFilter.documents, DocumentKind.text), {'Notes.txt', 'Data.csv'});
      expect(names(LibraryFilter.documents, DocumentKind.other), {'Archive.zip'});
      for (final sub in DocumentKind.values) {
        expect(names(LibraryFilter.documents, sub), _expected(entries, LibraryFilter.documents, sub: sub), reason: sub.name);
      }
      // The All timeline is newest first.
      final all = container.read(libraryFilterEntriesProvider((filter: LibraryFilter.all, subFilter: null))).toList();
      for (var i = 1; i < all.length; i++) {
        expect(all[i - 1].addedAt.isBefore(all[i].addedAt), isFalse);
      }
      container.dispose();
      await tester.pump();
      await lib.close(tester);
    });

    testWidgets('trashed entries leave every filter', (tester) async {
      final lib = await FixtureLibrary.open(tester);
      final entries = await lib.seedFixture(tester);
      await lib.run(tester, (s) => s.write((w, now) => w.trashEntries([entries['Holiday.mp4']!.id, entries['Report.pdf']!.id], now: now)));
      final container = ProviderContainer(overrides: [libraryStoreProvider.overrideWithValue(lib.store)]);
      final all = {for (final e in container.read(libraryFilterEntriesProvider((filter: LibraryFilter.all, subFilter: null))).toList()) e.displayName};
      expect(all, isNot(contains('Holiday.mp4')));
      expect(all, isNot(contains('Report.pdf')));
      expect(container.read(libraryFilterEntriesProvider((filter: LibraryFilter.documents, subFilter: DocumentKind.pdf))).length, 0);
      container.dispose();
      await tester.pump();
      await lib.close(tester);
    });

    testWidgets('the All, Videos and Documents tabs show exactly their kinds', (tester) async {
      useSurface(tester, const TestSurface(Size(1280, 3000), 1.0));
      final env = await LibraryTestEnv.create();
      final lib = await FixtureLibrary.open(tester);
      final entries = await lib.seedFixture(tester);

      await tester.pumpWidget(filtersApp(env, const AllTab(), lib: lib));
      await pumpFrames(tester);
      expect(_shownRows(tester, entries), _expected(entries, LibraryFilter.all));
      expect(find.text('October 2026'), findsOneWidget);

      await tester.pumpWidget(filtersApp(env, VideosTab(onOpenPlayer: () {}), lib: lib));
      await pumpFrames(tester);
      final videos = {
        for (final e in entries.values)
          if (find.byKey(ValueKey('library-video-${e.id.value}')).evaluate().isNotEmpty) e.displayName,
      };
      expect(videos, _expected(entries, LibraryFilter.videos));
      expect(_shownRows(tester, entries), isEmpty);

      await tester.pumpWidget(filtersApp(env, const DocumentsTab(), lib: lib));
      await pumpFrames(tester);
      expect(_shownRows(tester, entries), _expected(entries, LibraryFilter.documents));
      for (final sub in DocumentKind.values) {
        await tester.tap(find.byKey(ValueKey('documents-sub-${sub.code}')));
        await pumpFrames(tester);
        expect(_shownRows(tester, entries), _expected(entries, LibraryFilter.documents, sub: sub), reason: sub.name);
      }
      await tester.tap(find.byKey(const ValueKey('documents-sub-all')));
      await pumpFrames(tester);
      expect(_shownRows(tester, entries), _expected(entries, LibraryFilter.documents));
      // The PDF row shows its size, date and page count.
      expect(find.textContaining('12 pages'), findsOneWidget);

      await lib.close(tester);
      await env.dispose();
    });

    testWidgets('a library write shows in the next frame', (tester) async {
      useSurface(tester, const TestSurface(Size(1280, 1600), 1.0));
      final env = await LibraryTestEnv.create();
      final lib = await FixtureLibrary.open(tester);
      await tester.pumpWidget(filtersApp(env, const AllTab(), lib: lib));
      await pumpFrames(tester);
      expect(find.text('Nothing here yet'), findsOneWidget);
      final added = await lib.add(tester, 'Late.pdf');
      await tester.pump();
      expect(find.byKey(ValueKey('library-entry-${added.id.value}')), findsOneWidget);
      await lib.run(tester, (s) => s.write((w, now) => w.trashEntries([added.id], now: now)));
      await tester.pump();
      expect(find.byKey(ValueKey('library-entry-${added.id.value}')), findsNothing);
      await lib.close(tester);
      await env.dispose();
    });

    testWidgets('without a store the tabs show their empty panes', (tester) async {
      useSurface(tester, const TestSurface(Size(402, 874), 1.0));
      final env = await LibraryTestEnv.create();
      for (final tab in [const AllTab(), const DocumentsTab()]) {
        await tester.pumpWidget(filtersApp(env, tab));
        await pumpFrames(tester);
        expect(find.text('Nothing here yet'), findsOneWidget);
      }
      await tester.pumpWidget(filtersApp(env, VideosTab(onOpenPlayer: () {})));
      await pumpFrames(tester);
      expect(find.text('Danaview videos'), findsOneWidget);
      await finishHome(tester, env);
    });
  });

  group('linked-folder documents', () {
    testWidgets('open only: no rename, move or delete; Danaview documents have them', (tester) async {
      useSurface(tester, const TestSurface(Size(1280, 1600), 1.0));
      final env = await LibraryTestEnv.create();
      final lib = await FixtureLibrary.open(tester);
      final mine = await lib.add(tester, 'Mine.pdf');
      final linked = DocumentItem(
        id: LinkedItemId.of('root1', 'Guides/Manual.pdf'),
        uri: 'file:///Volumes/Guides/Manual.pdf',
        name: 'Manual.pdf',
        modifiedAt: DateTime.utc(2026, 9, 1),
        mimeType: 'application/pdf',
        sizeBytes: 2048,
        docKind: DocumentKind.pdf,
        pageCount: 3,
      );
      final opened = <String>[];
      await tester.pumpWidget(filtersApp(
        env,
        DocumentsTab(
          onOpenEntry: (e) => opened.add(e.displayName),
          onOpenLinked: (d) => opened.add(d.name),
          actions: LibraryEntryActions(onRename: (_) {}, onMove: (_) {}, onDelete: (_) {}),
        ),
        lib: lib,
        overrides: [linkedDocumentsProvider.overrideWithValue([linked])],
      ));
      await pumpFrames(tester);
      final linkedRow = find.byKey(ValueKey('linked-document-${linked.id.value}'));
      expect(linkedRow, findsOneWidget);
      expect(find.text('In linked folders'), findsOneWidget);
      expect(find.textContaining('3 pages'), findsOneWidget);

      await tester.tap(find.descendant(of: linkedRow, matching: find.byTooltip('More')));
      await pumpFrames(tester);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Rename…'), findsNothing);
      expect(find.text('Move to…'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      await tester.tap(find.text('Open'));
      await pumpFrames(tester);
      expect(opened, ['Manual.pdf']);

      final mineRow = find.byKey(ValueKey('library-entry-${mine.id.value}'));
      await tester.tap(find.descendant(of: mineRow, matching: find.byTooltip('More')));
      await pumpFrames(tester);
      expect(find.text('Rename…'), findsOneWidget);
      expect(find.text('Move to…'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await pumpFrames(tester);

      // A linked document follows the sub-filters too.
      await tester.tap(find.byKey(const ValueKey('documents-sub-word')));
      await pumpFrames(tester);
      expect(linkedRow, findsNothing);
      await lib.close(tester);
      await env.dispose();
    });
  });

  group('Videos tab', () {
    testWidgets('keeps the hub sections and labels each video', (tester) async {
      useSurface(tester, const TestSurface(Size(1280, 2000), 1.0));
      final env = await LibraryTestEnv.create();
      final media = createMediaTree();
      addTearDown(() => media.deleteSync(recursive: true));
      await env.library.addFolder(media.path);
      await env.library.createPlaylist('Road trip');
      final lib = await FixtureLibrary.open(tester);
      final clip = await lib.add(
        tester,
        'Drone.mp4',
        meta: const EntryMeta(width: 3840, height: 2160, duration: Duration(minutes: 3, seconds: 5), fps: 59.94),
      );
      final opened = <String>[];
      final folders = <String>[];
      final playlists = <String>[];
      await tester.pumpWidget(filtersApp(
        env,
        VideosTab(
          onOpenPlayer: () {},
          onOpenEntry: (e) => opened.add(e.displayName),
          onOpenFolder: folders.add,
          onOpenPlaylist: playlists.add,
        ),
        lib: lib,
      ));
      await pumpFrames(tester);
      expect(find.text('Playlists'), findsOneWidget);
      expect(find.text('Video folders'), findsOneWidget);
      expect(find.text('Danaview videos'), findsOneWidget);
      final tile = find.byKey(ValueKey('library-video-${clip.id.value}'));
      expect(tile, findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text('4K')), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text('60 fps')), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text('3:05')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Video Drone.mp4, 4K, 60 frames per second, 3:05')), findsOneWidget);

      await tester.tap(tile);
      await tester.tap(find.text('Road trip'));
      await tester.tap(find.text(media.path.split(Platform.pathSeparator).last));
      await pumpFrames(tester);
      expect(opened, ['Drone.mp4']);
      expect(playlists, ['Road trip']);
      expect(folders, [media.path]);
      await lib.close(tester);
      await env.dispose();
    });

    test('video tile badges follow HOM-13 (V2-110)', () {
      List<String> labels(EntryMeta meta) => [for (final l in MediaBadges.ofMeta(FileKind.video, meta).labels) l.label];
      expect(labels(const EntryMeta(width: 3840, height: 2160)), ['4K']);
      expect(labels(const EntryMeta(width: 2160, height: 3840)), ['4K']);
      expect(labels(const EntryMeta(width: 1920, height: 1080)), ['1080p']);
      expect(labels(const EntryMeta(width: 1920, height: 800)), ['1080p']);
      expect(labels(const EntryMeta(width: 1280, height: 720)), isEmpty);
      expect(labels(const EntryMeta(width: 640, height: 480, fps: 30)), isEmpty);
      expect(labels(const EntryMeta(height: 1080)), isEmpty);
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(1536), '1.5 KB');
      expect(formatFileSize(12 * 1024 * 1024), '12 MB');
    });
  });

  group('layout matrix', () {
    for (final (width, scale) in filtersMatrix) {
      testWidgets('All, Videos and Documents at ${width.toInt()} px × $scale', (tester) async {
        useSurface(tester, TestSurface(Size(width, 900), scale));
        final env = await LibraryTestEnv.create();
        final lib = await FixtureLibrary.open(tester);
        await lib.seedFixture(tester);
        await lib.add(tester, 'An Extraordinarily Long Video File Name That Never Ends Anywhere.mp4',
            meta: const EntryMeta(width: 1920, height: 1080, duration: Duration(hours: 2, minutes: 3), fps: 120));
        for (final tab in <Widget>[const AllTab(), VideosTab(onOpenPlayer: () {}), const DocumentsTab()]) {
          await tester.pumpWidget(filtersApp(env, tab, lib: lib, textScale: scale));
          await pumpFrames(tester);
          expect(tester.takeException(), isNull, reason: '${tab.runtimeType}');
          await expectLater(tester, meetsGuideline(iOSTapTargetGuideline), reason: '${tab.runtimeType}');
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline), reason: '${tab.runtimeType}');
        }
        await lib.close(tester);
        await env.dispose();
      });
    }
  });
}
