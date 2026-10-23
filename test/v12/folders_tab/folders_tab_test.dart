// OWNER: HOM-18
//
// BUILD_PLAN HOM-18, Folders tab half (ARCH v1.2 V2-115, §5.4; HOM plan §5.2, §8.1, D-98b):
// * Danaview folders: create, rename, move, nest and browse (breadcrumbs), file rename / move /
//   delete; every operation goes through the HOM-17 store and shows in the next frame;
// * Recently deleted: rows show the right days left with a fake clock; Restore; Empty now;
// * Linked folders: the 1.1 rows unchanged (they open the 1.1 browser); linked-folder files offer
//   no rename, move or delete;
// * without a store only the linked group shows;
// * the matrix 280–1280 px × text scale 0.85–1.35 with no overflow, ≥ 44 px targets and labels.

// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'package:danaview_features/src/library/folders/folder_actions.dart';
import 'package:danaview_features/src/library/folders/folder_widgets.dart';
import 'package:danaview_features/src/library/tabs/folders_tab.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../filters/filters_support.dart';

Finder _folderRow(FolderId id) => find.byKey(ValueKey('danaview-folder-${id.value}'));

Future<void> _menu(WidgetTester tester, Finder row, String item) async {
  await tester.tap(find.descendant(of: row, matching: find.byTooltip('More')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String text, String confirm) async {
  await tester.enterText(find.byType(EditableText), text);
  await tester.pump();
  await tester.tap(find.text(confirm).last);
  await tester.pumpAndSettle();
}

Future<(LibraryTestEnv, FixtureLibrary, List<String>)> _pump(WidgetTester tester, {Size size = const Size(1280, 1600), double scale = 1.0}) async {
  useSurface(tester, TestSurface(size, scale));
  final env = await LibraryTestEnv.create();
  final lib = await FixtureLibrary.open(tester);
  final opened = <String>[];
  await tester.pumpWidget(filtersApp(env, FoldersTab(onOpenFolder: opened.add), lib: lib, textScale: scale));
  await pumpFrames(tester);
  return (env, lib, opened);
}

Future<void> _done(WidgetTester tester, LibraryTestEnv env, FixtureLibrary lib) async {
  await lib.close(tester);
  await env.dispose();
}

void main() {
  testWidgets('create, rename and nest folders; breadcrumbs browse back', (tester) async {
    final (env, lib, _) = await _pump(tester);
    final reader = lib.store.reader;
    expect(find.text('Danaview folders'), findsOneWidget);
    expect(find.text('Linked folders'), findsOneWidget);
    // `Imported` is a system folder: Open only.
    final imported = reader.systemFolder(FolderSystemRole.imported)!;
    await tester.tap(find.descendant(of: _folderRow(imported.id), matching: find.byTooltip('More')));
    await tester.pumpAndSettle();
    expect(find.text('Rename…'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('folders-new-root')));
    await tester.pumpAndSettle();
    await _type(tester, 'Trips', 'Create');
    final trips = reader.childFolders(null).singleWhere((f) => f.name == 'Trips');
    expect(_folderRow(trips.id), findsOneWidget);

    await _menu(tester, _folderRow(trips.id), 'Rename…');
    await _type(tester, 'Travel', 'Rename');
    expect(reader.folder(trips.id)!.name, 'Travel');
    expect(find.descendant(of: _folderRow(trips.id), matching: find.text('Travel')), findsOneWidget);

    await tester.tap(_folderRow(trips.id));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('folder-breadcrumbs')), findsOneWidget);
    expect(find.text('This folder is empty'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('folders-new-here')));
    await tester.pumpAndSettle();
    await _type(tester, 'Japan', 'Create');
    final japan = reader.childFolders(trips.id).single;
    expect(japan.name, 'Japan');
    await tester.tap(_folderRow(japan.id));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('folders-new-here')));
    await tester.pumpAndSettle();
    await _type(tester, 'Kyoto', 'Create');
    expect(reader.pathOf(reader.childFolders(japan.id).single.id).map((f) => f.name), ['Travel', 'Japan', 'Kyoto']);

    // Breadcrumbs: Folders › Travel › Japan.
    final crumbs = find.byKey(const ValueKey('folder-breadcrumbs'));
    expect(find.descendant(of: crumbs, matching: find.text('Japan')), findsOneWidget);
    await tester.tap(find.descendant(of: crumbs, matching: find.text('Travel')));
    await tester.pumpAndSettle();
    expect(_folderRow(japan.id), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('folders-up')));
    await tester.pumpAndSettle();
    expect(find.text('Linked folders'), findsOneWidget);
    expect(await lib.store.checkInvariants(), isEmpty);
    await _done(tester, env, lib);
  });

  testWidgets('a store write shows in the next frame', (tester) async {
    final (env, lib, _) = await _pump(tester);
    final id = await lib.folder(tester, 'Scans');
    await tester.pump();
    expect(_folderRow(id), findsOneWidget);
    await lib.run(tester, (s) => s.write((w, now) => w.renameFolder(id, 'Receipts', now: now)));
    await tester.pump();
    expect(find.descendant(of: _folderRow(id), matching: find.text('Receipts')), findsOneWidget);
    await lib.run(tester, (s) => s.write((w, now) => w.trashFolder(id, now: now)));
    await tester.pump();
    expect(_folderRow(id), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('recently-deleted-row')), matching: find.textContaining('1 item')), findsOneWidget);
    await _done(tester, env, lib);
  });

  testWidgets('move a folder into another; its own subtree is not offered', (tester) async {
    final (env, lib, _) = await _pump(tester);
    final a = await lib.folder(tester, 'Alpha');
    final b = await lib.folder(tester, 'Beta');
    final child = await lib.folder(tester, 'Beta child', parent: b);
    await tester.pump();

    await _menu(tester, _folderRow(b), 'Move to…');
    expect(find.byKey(ValueKey('folder-pick-${a.value}')), findsOneWidget);
    expect(find.byKey(ValueKey('folder-pick-${b.value}')), findsNothing);
    expect(find.byKey(ValueKey('folder-pick-${child.value}')), findsNothing);
    expect(find.byKey(const ValueKey('folder-pick-top')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('folder-pick-${a.value}')));
    await tester.pumpAndSettle();
    expect(lib.store.reader.folder(b)!.parentId, a);
    expect(_folderRow(b), findsNothing);

    // And back to the top level.
    await tester.tap(_folderRow(a));
    await tester.pumpAndSettle();
    await _menu(tester, _folderRow(b), 'Move to…');
    await tester.tap(find.byKey(const ValueKey('folder-pick-top')));
    await tester.pumpAndSettle();
    expect(lib.store.reader.folder(b)!.parentId, isNull);
    expect(lib.store.reader.folder(child)!.parentId, b);
    expect(await lib.store.checkInvariants(), isEmpty);
    await _done(tester, env, lib);
  });

  testWidgets('files in a folder rename, move and delete through the store', (tester) async {
    final (env, lib, _) = await _pump(tester);
    final docs = await lib.folder(tester, 'Docs');
    final other = await lib.folder(tester, 'Other');
    final file = await lib.add(tester, 'Plan.pdf', folder: docs);
    final photo = await lib.add(tester, 'Shot.jpg', folder: docs);
    await tester.pump();
    await tester.tap(_folderRow(docs));
    await tester.pumpAndSettle();
    expect(find.text('2 files'), findsOneWidget);
    final row = find.byKey(ValueKey('library-entry-${file.id.value}'));

    await _menu(tester, row, 'Rename…');
    await _type(tester, 'Roadmap.pdf', 'Rename');
    expect(lib.store.reader.entry(file.id)!.displayName, 'Roadmap.pdf');
    expect(find.descendant(of: row, matching: find.text('Roadmap.pdf')), findsOneWidget);

    await _menu(tester, row, 'Move to…');
    expect(find.byKey(const ValueKey('folder-pick-top')), findsNothing);
    await tester.tap(find.byKey(ValueKey('folder-pick-${other.value}')));
    await tester.pumpAndSettle();
    expect(lib.store.reader.entry(file.id)!.folderId, other);
    expect(row, findsNothing);

    final photoRow = find.byKey(ValueKey('library-entry-${photo.id.value}'));
    await _menu(tester, photoRow, 'Delete');
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(lib.store.reader.entry(photo.id)!.isTrashed, isTrue);
    expect(photoRow, findsNothing);
    expect(find.text('This folder is empty'), findsOneWidget);
    await _done(tester, env, lib);
  });

  testWidgets('Recently deleted: days left with a fake clock, Restore, Empty now', (tester) async {
    final start = DateTime.utc(2026, 10, 1, 12);
    useSurface(tester, const TestSurface(Size(1280, 1600), 1.0));
    final env = await LibraryTestEnv.create();
    final lib = await FixtureLibrary.open(tester, start: start);
    final trips = await lib.folder(tester, 'Trips');
    final inTrips = await lib.add(tester, 'Map.pdf', folder: trips, bytes: 2048);
    final loose = await lib.add(tester, 'Receipt.jpg');
    final old = await lib.add(tester, 'Old.txt');
    await lib.run(tester, (s) => s.write((w, now) => w.trashEntries([old.id], now: now)));
    lib.now = start.add(const Duration(days: 10, hours: 1));
    await lib.run(tester, (s) => s.write((w, now) => w.trashFolder(trips, now: now)));
    lib.now = start.add(const Duration(days: 20));
    await lib.run(tester, (s) => s.write((w, now) => w.trashEntries([loose.id], now: now)));
    lib.now = start.add(const Duration(days: 29, hours: 12));

    await tester.pumpWidget(filtersApp(env, FoldersTab(onOpenFolder: (_) {}), lib: lib));
    await pumpFrames(tester);
    expect(find.descendant(of: find.byKey(const ValueKey('recently-deleted-row')), matching: find.textContaining('3 items')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recently-deleted-row')));
    await tester.pumpAndSettle();

    Finder trashed(ItemId id) => find.byKey(ValueKey('trashed-${id.value}'));
    // Deleted at day 0: half a day left → 1. Day 10 + 1 h: 10 d 13 h → 11. Day 20: 20 d 12 h → 21.
    expect(find.descendant(of: trashed(old.id), matching: find.textContaining('1 day left')), findsOneWidget);
    expect(find.descendant(of: trashed(trips), matching: find.textContaining('11 days left')), findsOneWidget);
    expect(find.descendant(of: trashed(trips), matching: find.textContaining('1 file')), findsOneWidget);
    expect(find.descendant(of: trashed(loose.id), matching: find.textContaining('21 days left')), findsOneWidget);
    expect(trashed(inTrips.id), findsNothing, reason: 'trashed with its folder: one row');
    expect(daysLeftLabel(30), '30 days left');
    expect(daysLeftLabel(0), 'Removed today');

    // Restore the folder: it and its file come back.
    await tester.tap(find.descendant(of: trashed(trips), matching: find.text('Restore')));
    await tester.pumpAndSettle();
    expect(lib.store.reader.folder(trips)!.isTrashed, isFalse);
    expect(lib.store.reader.entry(inTrips.id)!.isTrashed, isFalse);
    expect(trashed(trips), findsNothing);

    // Empty now asks, then removes the rest for good.
    await tester.tap(find.byKey(const ValueKey('recently-deleted-empty-now')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Empty now').last);
    await tester.pumpAndSettle();
    expect(lib.store.reader.recentlyDeleted(), isEmpty);
    expect(lib.store.reader.entry(old.id), isNull);
    expect(lib.store.reader.entry(loose.id), isNull);
    expect(find.text('Recently deleted is empty'), findsOneWidget);
    expect(find.byKey(const ValueKey('recently-deleted-empty-now')), findsNothing);
    await _done(tester, env, lib);
  });

  testWidgets('a fresh delete shows 30 days left', (tester) async {
    final (env, lib, _) = await _pump(tester);
    final id = await lib.folder(tester, 'Gone');
    await tester.pump();
    await _menu(tester, _folderRow(id), 'Delete');
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(lib.store.reader.folder(id)!.isTrashed, isTrue);
    await tester.tap(find.byKey(const ValueKey('recently-deleted-row')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(ValueKey('trashed-${id.value}')), matching: find.textContaining('30 days left')), findsOneWidget);
    await _done(tester, env, lib);
  });

  testWidgets('an open folder deleted elsewhere drops back to the root', (tester) async {
    final (env, lib, _) = await _pump(tester);
    final id = await lib.folder(tester, 'Temp');
    await tester.pump();
    await tester.tap(_folderRow(id));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('folder-breadcrumbs')), findsOneWidget);
    await lib.run(tester, (s) => s.write((w, now) => w.trashFolder(id, now: now)));
    await tester.pump();
    expect(find.byKey(const ValueKey('folder-breadcrumbs')), findsNothing);
    expect(find.text('Danaview folders'), findsOneWidget);
    await _done(tester, env, lib);
  });

  testWidgets('linked folders: the 1.1 rows, opening the 1.1 browser, no file-changing actions', (tester) async {
    useSurface(tester, const TestSurface(Size(1280, 1600), 1.0));
    final env = await LibraryTestEnv.create();
    final media = createMediaTree();
    addTearDown(() => media.deleteSync(recursive: true));
    await env.library.addFolder(media.path);
    final lib = await FixtureLibrary.open(tester);
    final opened = <String>[];
    await tester.pumpWidget(filtersApp(env, FoldersTab(onOpenFolder: opened.add), lib: lib));
    await pumpFrames(tester);
    final group = find.byKey(const ValueKey('linked-folders-group'));
    final path = find.descendant(of: group, matching: find.text(media.path));
    expect(path, findsOneWidget);
    await tester.tap(path);
    await pumpFrames(tester);
    expect(opened, [media.path]);

    await tester.tap(find.descendant(of: group, matching: find.byTooltip('More')).first);
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Play all'), findsOneWidget);
    expect(find.text('Remove from library'), findsOneWidget);
    expect(find.text('Rename…'), findsNothing);
    expect(find.text('Move to…'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await _done(tester, env, lib);
  });

  testWidgets('without a store only the linked group shows', (tester) async {
    useSurface(tester, const TestSurface(Size(402, 874), 1.0));
    final env = await LibraryTestEnv.create();
    await tester.pumpWidget(filtersApp(env, FoldersTab(onOpenFolder: (_) {})));
    await pumpFrames(tester);
    expect(find.text('Danaview folders'), findsNothing);
    expect(find.text('Linked folders'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await env.dispose();
  });

  test('name checks', () {
    expect(validateLibraryName(''), isNotNull);
    expect(validateLibraryName('  '), isNotNull);
    expect(validateLibraryName('a/b'), isNotNull);
    expect(validateLibraryName('..'), isNotNull);
    expect(validateLibraryName('x' * 256), isNotNull);
    expect(validateLibraryName('Trips 2026'), isNull);
    for (final e in LibraryWriteError.values) {
      expect(libraryWriteErrorMessage(e), isNotEmpty);
    }
  });

  group('layout matrix', () {
    for (final (width, scale) in filtersMatrix) {
      testWidgets('Folders tab at ${width.toInt()} px × $scale', (tester) async {
        useSurface(tester, TestSurface(Size(width, 900), scale));
        final env = await LibraryTestEnv.create();
        final media = createMediaTree();
        addTearDown(() => media.deleteSync(recursive: true));
        await env.library.addFolder(media.path);
        final lib = await FixtureLibrary.open(tester);
        final deep = await lib.folder(tester, 'A Folder Name That Is Far Too Long To Fit On Any Phone Screen At All');
        final inner = await lib.folder(tester, 'Another Extremely Long Nested Folder Name For Breadcrumbs', parent: deep);
        await lib.seedFixture(tester, folder: inner);
        await lib.run(tester, (s) => s.write((w, now) => w.trashEntries([s.reader.entriesPage(const EntryQuery()).first.id], now: now)));
        await tester.pumpWidget(filtersApp(env, FoldersTab(onOpenFolder: (_) {}), lib: lib, textScale: scale));
        await pumpFrames(tester);
        Future<void> check(String where) async {
          expect(tester.takeException(), isNull, reason: where);
          await expectLater(tester, meetsGuideline(iOSTapTargetGuideline), reason: where);
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline), reason: where);
        }

        await check('root');
        await tester.tap(_folderRow(deep));
        await pumpFrames(tester);
        await tester.tap(_folderRow(inner));
        await pumpFrames(tester);
        await check('nested');
        await tester.tap(find.byKey(const ValueKey('folders-up')));
        await pumpFrames(tester);
        await tester.tap(find.byKey(const ValueKey('folders-up')));
        await pumpFrames(tester);
        await tester.scrollUntilVisible(find.byKey(const ValueKey('recently-deleted-row')), 100);
        await tester.tap(find.byKey(const ValueKey('recently-deleted-row')));
        await pumpFrames(tester);
        await check('recently deleted');
        await _done(tester, env, lib);
      });
    }
  });
}
