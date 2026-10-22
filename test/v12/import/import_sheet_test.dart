// OWNER: HOM-20
//
// BUILD_PLAN HOM-20 UI: the import sheet with its folder choice (default `Imported`) and progress
// rows. Without a library store (DANAVIEW_FILES_HOME off) it offers nothing; From Files imports
// copies and the rows end as Imported; "Already in Danaview: keep both or skip?" is answered on the
// row; a queued import is cancelled from its row; another folder is chosen in the folder sheet;
// the layout matrix 280–1280 px × text scale 0.85–1.35 holds every row state with long names,
// ≥ 44 px targets and semantics labels (ARCH §1.4).
//
// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/import/import_pickers.dart';
import 'package:danaview_features/src/library/import/import_providers.dart';
import 'package:danaview_features/src/library/import/import_sheet.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';

/// A picker returning prepared local files.
final class _FakePicker implements ImportPicker {
  _FakePicker(this.files, {this.photos = const []});

  List<String> files;
  final List<String> photos;
  int calls = 0;

  @override
  bool get canPickPhotos => true;

  @override
  Future<List<ImportSource>> pickFiles() async {
    calls++;
    return [for (final f in files) ImportSource.file(f)];
  }

  @override
  Future<List<ImportSource>> pickPhotos() async {
    calls++;
    return [for (final f in photos) ImportSource.file(f, sourceHint: SourceHint.photos)];
  }
}

/// A store, a service and a source directory in temp dirs, driven outside fake async.
class _Lib {
  _Lib._(this.root, this.src, this.store, this.service);

  final Directory root;
  final Directory src;
  final LibraryStore store;
  final ImportService service;

  static Future<_Lib> open(WidgetTester tester) async => (await tester.runAsync(() async {
        final root = Directory.systemTemp.createTempSync('hom20_ui_lib_');
        final src = Directory.systemTemp.createTempSync('hom20_ui_src_');
        final store = await LibraryStore.open(root: root.path, background: false);
        return _Lib._(root, src, store, ImportService(store: store));
      }))!;

  String file(String name, int size, {int seed = 1}) {
    final f = File('${src.path}/$name')..writeAsBytesSync(List<int>.generate(size, (i) => (i * seed) % 251));
    return f.path;
  }

  /// Lets the queue run (its isolate replies arrive in real time, its listeners in the test zone)
  /// until nothing is running or a duplicate question waits.
  Future<void> settle(WidgetTester tester) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (service.busy && !service.items.any((i) => i.state == ImportItemState.awaitingDuplicateDecision)) {
      if (DateTime.now().isAfter(end)) throw StateError('imports did not settle');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await pumpFrames(tester, count: 2);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await service.dispose();
      await store.close();
      root.deleteSync(recursive: true);
      src.deleteSync(recursive: true);
    });
  }
}

Widget _app(LibraryTestEnv env, Widget body, {_Lib? lib, ImportPicker? picker, double textScale = 1.0, List<Override> overrides = const []}) => libraryTestApp(
      env,
      Scaffold(
        backgroundColor: DanaviewColors.background,
        body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: body)),
      ),
      textScale: textScale,
      overrides: [
        if (lib != null) ...[
          libraryStoreProvider.overrideWithValue(lib.store),
          importServiceProvider.overrideWithValue(lib.service),
        ],
        if (picker != null) importPickerProvider.overrideWithValue(picker),
        ...overrides,
      ],
    );

void main() {
  testWidgets('without a store the sheet offers nothing', (tester) async {
    useSurface(tester, librarySurfaces[1]);
    final env = await LibraryTestEnv.create();
    await tester.pumpWidget(_app(env, const ImportSheet(), picker: _FakePicker(const [])));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('import-unavailable')), findsOneWidget);
    expect(find.byKey(const ValueKey('import-from-files')), findsNothing);
    await env.dispose();
  });

  testWidgets('From Files imports copies into Imported and the rows end as Imported', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    final a = lib.file('Quarterly Report.pdf', 4000);
    final b = lib.file('Holiday.mov', 9000, seed: 3);
    final picker = _FakePicker([a, b]);
    await tester.pumpWidget(_app(env, const ImportSheet(), lib: lib, picker: picker));
    await pumpFrames(tester);
    expect(find.text('Imported'), findsOneWidget, reason: 'the default folder');
    expect(find.bySemanticsLabel(RegExp('^Import from Files')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Import from Photos')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-from-files')));
    await pumpFrames(tester, count: 2);
    await lib.settle(tester);
    expect(tester.takeException(), isNull);
    expect(picker.calls, 1);
    expect(lib.service.items.map((i) => i.state), [ImportItemState.done, ImportItemState.done]);
    expect(find.bySemanticsLabel('Quarterly Report.pdf. Imported'), findsOneWidget);
    expect(find.bySemanticsLabel('Holiday.mov. Imported'), findsOneWidget);
    final imported = lib.store.reader.systemFolder(FolderSystemRole.imported)!.id;
    expect(lib.service.items.every((i) => i.entry!.folderId == imported), isTrue);
    expect(File(a).existsSync() && File(b).existsSync(), isTrue, reason: 'originals stay');

    await tester.tap(find.byKey(const ValueKey('import-clear-finished')));
    await pumpFrames(tester, count: 2);
    expect(lib.service.items, isEmpty);
    expect(find.text('Imports'), findsNothing);
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('the duplicate question is answered on the row', (tester) async {
    useSurface(tester, librarySurfaces[1]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    final original = lib.file('IMG_0001.HEIC', 70000);
    await tester.runAsync(() => lib.service.importAll([ImportSource.file(original)]));
    lib.service.clearFinished();
    final copy = lib.file('IMG_0001 copy.HEIC', 70000);
    final picker = _FakePicker([copy]);
    await tester.pumpWidget(_app(env, const ImportSheet(), lib: lib, picker: picker));
    await pumpFrames(tester);

    await tester.tap(find.byKey(const ValueKey('import-from-files')));
    await pumpFrames(tester, count: 2);
    await lib.settle(tester);
    final item = lib.service.items.single;
    expect(item.state, ImportItemState.awaitingDuplicateDecision);
    expect(find.text('Already in Danaview. Keep both or skip?'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Keep both copies of IMG_0001 copy\.HEIC')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('import-keep-both-${item.id}')));
    await pumpFrames(tester, count: 2);
    await lib.settle(tester);
    expect(lib.service.items.single.state, ImportItemState.done);
    expect(lib.store.reader.countEntries(const EntryQuery()), 2);

    // Again, and skip.
    await tester.tap(find.byKey(const ValueKey('import-from-files')));
    await pumpFrames(tester, count: 2);
    await lib.settle(tester);
    final second = lib.service.items.last;
    await tester.tap(find.byKey(ValueKey('import-skip-${second.id}')));
    await pumpFrames(tester, count: 2);
    await lib.settle(tester);
    expect(lib.service.items.last.state, ImportItemState.skipped);
    expect(find.text('Skipped: already in Danaview'), findsOneWidget);
    expect(lib.store.reader.countEntries(const EntryQuery()), 2);
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('a queued import is cancelled from its row', (tester) async {
    useSurface(tester, librarySurfaces[1]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    final first = lib.file('first.bin', 10);
    final second = lib.file('second.bin', 20);
    // Enqueue without letting the pump run, so the second item is still queued.
    final ids = lib.service.enqueueAll([ImportSource.file(first), ImportSource.file(second)]);
    await tester.pumpWidget(_app(env, const ImportSheet(), lib: lib, picker: _FakePicker(const [])));
    await pumpFrames(tester, count: 1);
    final cancel = find.byKey(ValueKey('import-cancel-${ids[1]}'));
    expect(cancel, findsOneWidget);
    expect(tester.getSize(cancel).height, greaterThanOrEqualTo(44));
    await tester.tap(cancel);
    await pumpFrames(tester, count: 2);
    await lib.settle(tester);
    expect(lib.service.items[1].state, ImportItemState.cancelled);
    expect(find.text('Cancelled'), findsOneWidget);
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('another folder is chosen in the folder sheet and used', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    final work = (await tester.runAsync(() => lib.store.write((w, now) => w.createFolder('Work', now: now))))!;
    await tester.runAsync(() => lib.store.write((w, now) => w.createFolder('Contracts', parent: work, now: now)));
    final picker = _FakePicker([lib.file('Offer.pdf', 500)]);
    await tester.pumpWidget(_app(
      env,
      Builder(builder: (context) => DanaviewButton(key: const ValueKey('open'), label: 'Open', onPressed: () => showImportSheet(context))),
      lib: lib,
      picker: picker,
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('import-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('import-target')));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('import-folder-chooser')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Save to Contracts')), findsOneWidget, reason: 'nested folders are listed');
    await tester.tap(find.byKey(ValueKey('import-folder-${work.value}')));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('import-folder-chooser')), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'^Save to Work\. Change folder')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('import-from-files')));
    await pumpFrames(tester, count: 2);
    await lib.settle(tester);
    expect(lib.service.items.single.entry!.folderId, work);
    expect(tester.takeException(), isNull);
    await lib.close(tester);
    await env.dispose();
  });

  testWidgets('the sheet opened on a folder imports there', (tester) async {
    useSurface(tester, librarySurfaces[1]);
    final env = await LibraryTestEnv.create();
    final lib = await _Lib.open(tester);
    final trip = (await tester.runAsync(() => lib.store.write((w, now) => w.createFolder('Trip', now: now))))!;
    final picker = _FakePicker(const [], photos: [lib.file('IMG_0005.JPG', 800)]);
    await tester.pumpWidget(_app(env, ImportSheet(initialFolder: trip), lib: lib, picker: picker));
    await pumpFrames(tester);
    expect(find.text('Trip'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('import-from-photos')));
    await pumpFrames(tester, count: 2);
    await lib.settle(tester);
    final entry = lib.service.items.single.entry!;
    expect(entry.folderId, trip);
    expect(entry.sourceHint, SourceHint.photos);
    await lib.close(tester);
    await env.dispose();
  });

  test('status lines and sizes', () {
    expect(formatImportBytes(999), '999 B');
    expect(formatImportBytes(1500), '1.5 KB');
    expect(formatImportBytes(2000000000), '2.0 GB');
    expect(formatImportBytes(250000000), '250 MB');
    const base = ImportItem(id: 'i', displayName: 'x', state: ImportItemState.copying, bytesDone: 1000000, bytesTotal: 4000000);
    expect(importItemStatus(base), '1.0 MB of 4.0 MB');
    expect(importItemStatus(base.copyWith(state: ImportItemState.failed, failure: ImportFailure.sourceUnreadable)), "Couldn't read the file");
    expect(importItemStatus(const ImportItem(id: 'i', displayName: 'x', state: ImportItemState.queued, resumed: true)), 'Waiting to continue');
  });

  group('layout matrix', () {
    const long = '$longTitle.mov';
    List<ImportItem> items() => [
          const ImportItem(id: 'q', displayName: long, state: ImportItemState.queued, resumed: true),
          const ImportItem(id: 'c', displayName: long, state: ImportItemState.copying, bytesDone: 1200000000, bytesTotal: 2147483648),
          const ImportItem(id: 'f', displayName: long, state: ImportItemState.finishing, bytesDone: 10, bytesTotal: 10),
          const ImportItem(id: 'a', displayName: long, state: ImportItemState.awaitingDuplicateDecision),
          const ImportItem(id: 'd', displayName: long, state: ImportItemState.done),
          const ImportItem(id: 's', displayName: long, state: ImportItemState.skipped),
          const ImportItem(id: 'x', displayName: long, state: ImportItemState.failed, failure: ImportFailure.sourceChanged),
          const ImportItem(id: 'k', displayName: long, state: ImportItemState.cancelled),
        ];
    for (final scale in [0.85, 1.0, 1.35]) {
      for (final size in const [Size(280, 653), Size(320, 568), Size(375, 667), Size(768, 1024), Size(874, 402), Size(1280, 800)]) {
        final surface = TestSurface(size, scale);
        testWidgets('fits at $surface', (tester) async {
          useSurface(tester, surface);
          final env = await LibraryTestEnv.create();
          final lib = await _Lib.open(tester);
          final folder = (await tester.runAsync(() => lib.store.write((w, now) => w.createFolder(longTitle, now: now))))!;
          await tester.pumpWidget(_app(
            env,
            ImportSheet(initialFolder: folder),
            lib: lib,
            picker: _FakePicker(const []),
            textScale: scale,
            overrides: [importItemsProvider.overrideWith((ref) => Stream.value(items()))],
          ));
          await pumpFrames(tester, count: 3);
          expect(tester.takeException(), isNull);
          for (final key in ['import-target', 'import-from-files', 'import-from-photos', 'import-clear-finished', 'import-cancel-q', 'import-cancel-c', 'import-keep-both-a', 'import-skip-a']) {
            final f = find.byKey(ValueKey(key));
            expect(f, findsOneWidget, reason: key);
            expect(tester.getSize(f).height, greaterThanOrEqualTo(44), reason: key);
          }
          expect(find.byKey(const ValueKey('import-cancel-d')), findsNothing, reason: 'finished rows have no cancel');
          expect(find.bySemanticsLabel(RegExp(r'^Cancel import of ')), findsNWidgets(4));
          expect(find.bySemanticsLabel(RegExp(r'\. 1\.2 GB of 2\.1 GB$')), findsOneWidget);
          expect(find.bySemanticsLabel(RegExp(r'^Save to .*\. Change folder')), findsOneWidget);
          await lib.close(tester);
          await env.dispose();
        });
      }
    }
  });
}
