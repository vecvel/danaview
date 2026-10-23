// OWNER: HOM-19
//
// BUILD_PLAN HOM-19 UI: the favourite star on files and folders, the Favourites row of the
// Overview and the Favourites filter toggle, Recents with its one Clear button (trashed files
// never shown), the sort button remembering per folder and per list; without a store
// (DANAVIEW_FILES_HOME off) the row and section render nothing; the layout matrix 280–1280 px ×
// text scale 0.85–1.35 with ≥ 44 px targets and semantics labels (ARCH §1.4).

import 'dart:io';

import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/organise/organise_providers.dart';
import 'package:danaview_features/src/library/organise/organise_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../library_test_utils.dart';

/// An in-process store in a temp dir, with helpers that run its writes outside fake async.
class _Lib {
  _Lib._(this.root, this.store);

  final Directory root;
  final LibraryStore store;

  static Future<_Lib> open(WidgetTester tester) async {
    final root = Directory.systemTemp.createTempSync('hom19_ui_');
    final store = (await tester.runAsync(() => LibraryStore.open(root: root.path, background: false)))!;
    return _Lib._(root, store);
  }

  Future<T> run<T>(WidgetTester tester, Future<T> Function(LibraryStore s) op) async => (await tester.runAsync(() => op(store))) as T;

  Future<FileEntry> add(WidgetTester tester, String name, {FolderId? folder}) => run(tester, (s) => s.write((w, now) {
        final job = w.beginImport(target: folder, now: now);
        (w.fs.openPart(job.id)..writeFromSync(const [1, 2, 3])).closeSync();
        return w.commitImport(job.id, ImportedFileInfo(displayName: name, kind: name.endsWith('.pdf') ? FileKind.document : FileKind.photo), now: now);
      }));

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await store.close();
      root.deleteSync(recursive: true);
    });
  }
}

Widget _app(LibraryTestEnv env, Widget body, {LibraryStore? store, double textScale = 1.0, List<Override> overrides = const []}) => libraryTestApp(
      env,
      ColoredBox(
        color: DanaviewColors.background,
        child: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [body])),
      ),
      textScale: textScale,
      overrides: [if (store != null) libraryStoreProvider.overrideWithValue(store), ...overrides],
    );

void main() {
  testWidgets('without a store the Favourites row and Recents render nothing; the star is disabled', (tester) async {
    useSurface(tester, librarySurfaces[1]);
    final env = await LibraryTestEnv.create();
    await tester.pumpWidget(_app(
      env,
      Column(children: [
        FavouritesRow(onOpen: (_) {}),
        RecentFilesSection(onOpen: (_) {}),
        FavouriteToggleButton(id: EntryId.parse('fe_abc'), name: 'x'),
      ]),
    ));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('favourites-row')), findsNothing);
    expect(find.byKey(const ValueKey('recents-section')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('favourite-toggle-fe_abc')));
    await pumpFrames(tester, count: 2);
    expect(tester.takeException(), isNull);
    await env.dispose();
  });

  testWidgets('the star adds files and folders to the Favourites row, which opens them', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    final trip = await lib.run(tester, (s) => s.write((w, now) => w.createFolder('Trip', now: now)));
    final photo = await lib.add(tester, 'beach.jpg');
    final opened = <ItemId>[];
    await tester.pumpWidget(_app(
      env,
      Column(children: [
        FavouritesRow(onOpen: (item) => opened.add(item.id)),
        FavouriteToggleButton(id: photo.id, name: photo.displayName),
        FavouriteToggleButton(id: trip, name: 'Trip'),
      ]),
      store: lib.store,
    ));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('favourites-row')), findsNothing);
    expect(find.bySemanticsLabel('Add beach.jpg to favourites'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('favourite-toggle-${photo.id.value}')));
    await pumpFrames(tester);
    await tester.tap(find.byKey(ValueKey('favourite-toggle-${trip.value}')));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('favourites-row')), findsOneWidget);
    expect(find.bySemanticsLabel('Remove beach.jpg from favourites'), findsOneWidget);
    expect(find.bySemanticsLabel('Folder Trip, favourite'), findsOneWidget);
    expect(find.bySemanticsLabel('Photo beach.jpg, favourite'), findsOneWidget);
    // Folders come first.
    expect(tester.getTopLeft(find.byKey(ValueKey('favourite-${trip.value}'))).dx,
        lessThan(tester.getTopLeft(find.byKey(ValueKey('favourite-${photo.id.value}'))).dx));

    await tester.tap(find.byKey(ValueKey('favourite-${photo.id.value}')));
    expect(opened, [photo.id]);

    // Deleting the folder takes it off the row (trashed items never appear).
    await lib.run(tester, (s) => s.write((w, now) => w.trashFolder(trip, now: now)));
    await pumpFrames(tester);
    expect(find.byKey(ValueKey('favourite-${trip.value}')), findsNothing);
    expect(find.byKey(ValueKey('favourite-${photo.id.value}')), findsOneWidget);
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('the Favourites filter toggle reports its state', (tester) async {
    useSurface(tester, librarySurfaces[1]);
    final env = await LibraryTestEnv.create();
    var on = false;
    await tester.pumpWidget(_app(env, StatefulBuilder(builder: (context, setState) => FavouritesFilterToggle(selected: on, onChanged: (v) => setState(() => on = v)))));
    await pumpFrames(tester, count: 1);
    expect(find.bySemanticsLabel('Favourites filter, off'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('favourites-filter')));
    await pumpFrames(tester, count: 2);
    expect(on, isTrue);
    expect(find.bySemanticsLabel('Favourites filter, on'), findsOneWidget);
    await env.dispose();
  });

  testWidgets('Recents lists opened files newest first, hides trashed ones, and Clear empties it', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    final a = await lib.add(tester, 'a.pdf');
    final b = await lib.add(tester, 'b.jpg');
    final container = ProviderContainer(overrides: [libraryStoreProvider.overrideWithValue(lib.store)]);
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await container.read(recordLibraryOpenProvider)(a.id);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await container.read(recordLibraryOpenProvider)(b.id);
    });
    final opened = <EntryId>[];
    await tester.pumpWidget(_app(env, RecentFilesSection(onOpen: (e) => opened.add(e.id)), store: lib.store));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('recents-section')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(ValueKey('recent-${b.id.value}'))).dy, lessThan(tester.getTopLeft(find.byKey(ValueKey('recent-${a.id.value}'))).dy));
    await tester.tap(find.byKey(ValueKey('recent-${a.id.value}')));
    expect(opened, [a.id]);

    await lib.run(tester, (s) => s.write((w, now) => w.trashEntries([b.id], now: now)));
    await pumpFrames(tester);
    expect(find.byKey(ValueKey('recent-${b.id.value}')), findsNothing);

    expect(find.bySemanticsLabel(RegExp('^Clear recents')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recents-clear')));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('recents-section')), findsNothing);
    // Recording a file that is gone is ignored.
    await tester.runAsync(() => container.read(recordLibraryOpenProvider)(b.id));
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('the sort button remembers per Danaview folder and per named list', (tester) async {
    useSurface(tester, librarySurfaces[4]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    final a = await lib.run(tester, (s) => s.write((w, now) => w.createFolder('A', now: now)));
    final b = await lib.run(tester, (s) => s.write((w, now) => w.createFolder('B', now: now)));
    final prefs = InMemorySortPreferenceStore();
    var scope = SortScope.folder(a);
    late StateSetter rebuild;
    await tester.pumpWidget(_app(
      env,
      StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return Align(alignment: Alignment.centerLeft, child: LibrarySortButton(scope: scope));
      }),
      store: lib.store,
      overrides: [sortPreferenceStoreProvider.overrideWithValue(prefs)],
    ));
    await pumpFrames(tester, count: 2);
    expect(find.bySemanticsLabel('Sort by Name, A to Z'), findsOneWidget);

    Future<void> pick(String label) async {
      await tester.tap(find.byKey(const ValueKey('library-sort')));
      await pumpFrames(tester, count: 3);
      await tester.tap(find.text(label).last);
      await pumpFrames(tester, count: 4);
    }

    await pick('Size');
    expect(find.bySemanticsLabel('Sort by Size, Largest first'), findsOneWidget);
    await pick('Smallest first');
    expect(find.bySemanticsLabel('Sort by Size, Smallest first'), findsOneWidget);
    expect(lib.store.reader.folder(a)!.sortMode, 'size');
    expect(lib.store.reader.folder(a)!.sortDescending, isFalse);

    rebuild(() => scope = SortScope.folder(b));
    await pumpFrames(tester, count: 2);
    expect(find.bySemanticsLabel('Sort by Name, A to Z'), findsOneWidget);

    rebuild(() => scope = NamedSortScope.allTab);
    await pumpFrames(tester, count: 2);
    expect(find.bySemanticsLabel('Sort by Date added, Newest first'), findsOneWidget);
    await pick('Type');
    expect(prefs.values[NamedSortScope.allTab.preferenceKey], 'type:asc');
    expect(find.bySemanticsLabel('Sort by Type, A to Z'), findsOneWidget);

    rebuild(() => scope = SortScope.folder(a));
    await pumpFrames(tester, count: 2);
    expect(find.bySemanticsLabel('Sort by Size, Smallest first'), findsOneWidget);
    await lib.close(tester);
    await env.dispose();
  });

  group('layout matrix', () {
    for (final scale in [0.85, 1.0, 1.35]) {
      for (final size in const [Size(280, 653), Size(320, 568), Size(375, 667), Size(768, 1024), Size(874, 402), Size(1280, 800)]) {
        final surface = TestSurface(size, scale);
        testWidgets('fits at $surface', (tester) async {
          useSurface(tester, surface);
          final env = await LibraryTestEnv.create();
          final lib = await _Lib.open(tester);
          final folder = await lib.run(tester, (s) => s.write((w, now) => w.createFolder(longTitle, now: now)));
          final entries = <FileEntry>[];
          for (var i = 0; i < 6; i++) {
            entries.add(await lib.add(tester, '$longTitle $i.pdf'));
          }
          await lib.run(tester, (s) => s.write((w, now) {
                w.setFolderFavourite(folder, true);
                for (final e in entries) {
                  w.setEntryFavourite(e.id, true);
                  w.markOpened(e.id, now: now);
                }
              }));
          await tester.pumpWidget(_app(
            env,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Align(alignment: Alignment.centerLeft, child: FavouritesFilterToggle(selected: true, onChanged: (_) {}))),
                LibrarySortButton(scope: SortScope.folder(folder)),
                FavouriteToggleButton(id: folder, name: longTitle),
              ]),
              FavouritesRow(onOpen: (_) {}),
              RecentFilesSection(onOpen: (_) {}),
            ]),
            store: lib.store,
            textScale: scale,
          ));
          await pumpFrames(tester, count: 3);
          expect(tester.takeException(), isNull);
          for (final key in ['library-sort', 'favourite-toggle-${folder.value}', 'favourites-filter', 'recents-clear', 'recent-${entries.first.id.value}', 'favourite-${folder.value}']) {
            final box = tester.getSize(find.byKey(ValueKey(key)));
            expect(box.height, greaterThanOrEqualTo(key == 'favourites-filter' ? 32 : 44), reason: key);
          }
          // The filter toggle's hit area is padded to 44.
          expect(tester.getSize(find.ancestor(of: find.byKey(const ValueKey('favourites-filter')), matching: find.byType(ConstrainedBox)).first).height, greaterThanOrEqualTo(44));
          expect(find.bySemanticsLabel(RegExp(r'^Document .*, opened recently')), findsWidgets);
          await lib.close(tester);
          await env.dispose();
        });
      }
    }
  });
}
