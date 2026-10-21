// OWNER: HOM-19
//
// BUILD_PLAN HOM-19 search UI: as-you-type name search across Danaview folders and linked folders
// from the Home search field; hits open; trashed items never appear and library writes show up in
// the hits on screen; the SearchBackend hook (AIS-51 swaps the engine; a failing engine falls back
// to the name search); the layout matrix 280–1280 px × text scale 0.85–1.35 with 44 px rows and
// semantics labels (ARCH §1.4).

import 'dart:io';

import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/organise/organise_providers.dart';
import 'package:danaview_features/src/library/search/library_search_field.dart';
import 'package:danaview_features/src/library/search/name_search_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../library_test_utils.dart';

class _Lib {
  _Lib._(this.root, this.store);

  final Directory root;
  final LibraryStore store;

  static Future<_Lib> open(WidgetTester tester) async {
    final root = Directory.systemTemp.createTempSync('hom19_search_');
    final store = (await tester.runAsync(() => LibraryStore.open(root: root.path, background: false)))!;
    return _Lib._(root, store);
  }

  Future<T> run<T>(WidgetTester tester, Future<T> Function(LibraryStore s) op) async => (await tester.runAsync(() => op(store))) as T;

  Future<FileEntry> add(WidgetTester tester, String name, {FolderId? folder}) => run(tester, (s) => s.write((w, now) {
        final job = w.beginImport(target: folder, now: now);
        (w.fs.openPart(job.id)..writeFromSync(const [1])).closeSync();
        return w.commitImport(job.id, ImportedFileInfo(displayName: name, kind: name.endsWith('.pdf') ? FileKind.document : FileKind.photo, subKind: name.endsWith('.pdf') ? 'pdf' : null), now: now);
      }));

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await store.close();
      root.deleteSync(recursive: true);
    });
  }
}

/// A backend standing in for the AIS-51 index.
class _IndexBackend implements SearchBackend {
  _IndexBackend({this.fail = false});

  final bool fail;
  final List<String> queries = [];

  @override
  String get id => 'index';

  @override
  Future<SearchResults> search(SearchQuery query) async {
    queries.add(query.text);
    if (fail) throw StateError('index not built');
    return SearchResults(
      query: query,
      hits: const [SearchHit(SearchItem(id: ItemId.opaque('/doc/text-hit'), name: 'Inside text.pdf', origin: SearchOrigin.danaview, kind: FileKind.document), SearchMatch.name)],
      total: 1,
      backend: id,
    );
  }
}

Widget _app(LibraryTestEnv env, {LibraryStore? store, ValueChanged<SearchHit>? onOpen, double textScale = 1.0, List<Override> overrides = const []}) => libraryTestApp(
      env,
      ColoredBox(
        color: DanaviewColors.background,
        child: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [LibrarySearchField(onOpen: onOpen ?? (_) {}, debounce: Duration.zero)]),
        ),
      ),
      textScale: textScale,
      overrides: [if (store != null) libraryStoreProvider.overrideWithValue(store), ...overrides],
    );

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('library-search-field')), text);
  await pumpFrames(tester, count: 2);
}

void main() {
  testWidgets('typing finds Danaview files by name, folder and type; hits open; trashed never appear', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    final trip = await lib.run(tester, (s) => s.write((w, now) => w.createFolder('Summer trip', now: now)));
    final beach = await lib.add(tester, 'beach.jpg', folder: trip);
    final report = await lib.add(tester, 'Report.pdf');
    final opened = <ItemId>[];
    await tester.pumpWidget(_app(env, store: lib.store, onOpen: (h) => opened.add(h.item.id)));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('library-search-count')), findsNothing);

    await _type(tester, 'bea');
    expect(find.text('beach.jpg'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Photo beach\.jpg, in Summer trip')), findsOneWidget);
    await _type(tester, 'summer');
    expect(find.text('Summer trip'), findsOneWidget);
    expect(find.text('beach.jpg'), findsOneWidget);
    expect(find.text('2 matches'), findsOneWidget);
    await _type(tester, 'pdf');
    expect(find.text('Report.pdf'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('library-search-hit-${report.id.value}')));
    expect(opened, [report.id]);

    // A write while the query is on screen updates the hits: trash it, then restore it.
    await lib.run(tester, (s) => s.write((w, now) => w.trashEntries([report.id], now: now)));
    await pumpFrames(tester);
    expect(find.text('Report.pdf'), findsNothing);
    expect(find.text(LibrarySearchField.noMatches), findsOneWidget);
    await lib.run(tester, (s) => s.write((w, now) => w.restore(report.id, now: now)));
    await pumpFrames(tester);
    expect(find.text('Report.pdf'), findsOneWidget);

    // A trashed folder takes its files with it.
    await lib.run(tester, (s) => s.write((w, now) => w.trashFolder(trip, now: now)));
    await _type(tester, 'beach');
    expect(find.byKey(ValueKey('library-search-hit-${beach.id.value}')), findsNothing);
    expect(find.text(LibrarySearchField.noMatches), findsOneWidget);

    // Clearing the field hides the hits.
    await _type(tester, '');
    expect(find.text(LibrarySearchField.noMatches), findsNothing);
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('linked folders are searched by folder and file names', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final root = Directory.systemTemp.createTempSync('hom19_linked_');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory('${root.path}/Holiday clips/Day 2').createSync(recursive: true);
    File('${root.path}/Holiday clips/Day 2/sunset.mp4').writeAsBytesSync(const [0]);
    File('${root.path}/Holiday clips/notes.txt').writeAsBytesSync(const [0]);
    await tester.runAsync(() => env.library.addFolder(root.path, label: 'Linked root'));
    await tester.pumpWidget(_app(env));
    // The roots load and the walk run on real IO: let them finish.
    final container = ProviderScope.containerOf(tester.element(find.byType(LibrarySearchField)));
    for (var i = 0; i < 100 && container.read(nameSearchIndexProvider).length == 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(container.read(nameSearchIndexProvider).sourceIds, contains(linkedSearchSourceId));
    await _type(tester, 'sunset');
    expect(find.text('sunset.mp4'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Video sunset\.mp4, in Day 2 \(linked\)')), findsOneWidget);
    await _type(tester, 'holiday');
    expect(find.text('Holiday clips'), findsOneWidget);
    await _type(tester, 'notes');
    // The 1.1 browser lists videos only, so only they are indexed.
    expect(find.text('notes.txt'), findsNothing);
    await env.dispose();
  });

  testWidgets('the SearchBackend hook answers queries; a failing engine falls back to the name search', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    await lib.add(tester, 'Report.pdf');
    final index = _IndexBackend();
    await tester.pumpWidget(_app(env, store: lib.store, overrides: [searchBackendProvider.overrideWithValue(index)]));
    await pumpFrames(tester);
    await _type(tester, 'invoice total');
    expect(index.queries, ['invoice total']);
    expect(find.text('Inside text.pdf'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final broken = _IndexBackend(fail: true);
    await tester.pumpWidget(_app(env, store: lib.store, overrides: [searchBackendProvider.overrideWithValue(broken)]));
    await pumpFrames(tester);
    await _type(tester, 'rep');
    expect(broken.queries, ['rep']);
    expect(find.text('Report.pdf'), findsOneWidget);
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('without a store (flag off) the field searches linked folders only, without errors', (tester) async {
    useSurface(tester, librarySurfaces[0]);
    final env = await LibraryTestEnv.create();
    await tester.pumpWidget(_app(env));
    await pumpFrames(tester);
    await _type(tester, 'anything');
    expect(tester.takeException(), isNull);
    expect(find.text(LibrarySearchField.noMatches), findsOneWidget);
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
          final folder = await lib.run(tester, (s) => s.write((w, now) => w.createFolder('$longTitle folder', now: now)));
          final first = await lib.add(tester, '$longTitle.pdf', folder: folder);
          for (var i = 0; i < 4; i++) {
            await lib.add(tester, '$longTitle $i.jpg', folder: folder);
          }
          await tester.pumpWidget(_app(env, store: lib.store, textScale: scale));
          await pumpFrames(tester);
          await _type(tester, 'extraordinarily');
          expect(tester.takeException(), isNull);
          expect(find.text('6 matches'), findsOneWidget);
          final row = find.byKey(ValueKey('library-search-hit-${first.id.value}'));
          expect(tester.getSize(row).height, greaterThanOrEqualTo(44));
          expect(tester.getSize(find.byKey(const ValueKey('library-search-field'))).height, greaterThanOrEqualTo(44));
          expect(find.bySemanticsLabel(RegExp(r'^Document An Extraordinarily')), findsOneWidget);
          await lib.close(tester);
          await env.dispose();
        });
      }
    }
  });
}
