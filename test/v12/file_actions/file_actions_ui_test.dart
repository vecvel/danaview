// OWNER: HOM-22
//
// BUILD_PLAN HOM-22, UI half: the multi-select file group (after HOM-12's media group) and the
// single-file menu over a real in-process library store and a recording FileOutPort. Every action
// updates library.db and the UI (Move to…, Copy to…, Rename, Favourite, Delete); Save out and
// Share hand the platform the library files and never change them; Delete warns "Used in 2
// projects" for a referenced entry and goes to Recently deleted; linked-folder files get only the
// out actions; Merge into PDF reaches HOM-28's handler in selection order; File info shows the
// database facts. ARCH §1.4: no overflow at 280–1280 px × text scale 0.85–1.35, targets ≥ 44 px,
// semantics labels, computed contrast.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/file_actions/file_action_providers.dart';
import 'package:danaview_features/src/library/file_actions/file_action_runner.dart';
import 'package:danaview_features/src/library/file_actions/file_action_sheets.dart';
import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/selection/file_actions.dart';
import 'package:danaview_features/src/library/selection/selection_bar.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../home_shell/home_shell_support.dart';

/// Records every call; answers as configured.
final class _Port implements FileOutPort {
  _Port([FileOutPlatform platform = FileOutPlatform.iOS]) : capabilities = FileOutCapabilities.of(platform);

  @override
  final FileOutCapabilities capabilities;

  final List<(String, List<OutFile>, SaveOutTarget?)> calls = [];
  SaveOutOutcome saveAnswer = const SaveOutOutcome(cancelled: false, saved: 2, failed: 0);
  FileOutException? fail;

  @override
  Future<SaveOutOutcome> saveOut(List<OutFile> files, SaveOutTarget target, {OutAnchor? anchor}) async {
    calls.add(('save', files, target));
    if (fail case final f?) throw f;
    return saveAnswer;
  }

  @override
  Future<ShareOutcome> share(List<OutFile> files, {String? subject, OutAnchor? anchor}) async {
    calls.add(('share', files, null));
    return const ShareOutcome(completed: true);
  }

  @override
  Future<bool> openIn(OutFile file, {OutAnchor? anchor}) async {
    calls.add(('open', [file], null));
    return true;
  }
}

/// An in-process store in a temp dir.
class _Lib {
  _Lib._(this.root, this.store);

  final Directory root;
  final LibraryStore store;

  static Future<_Lib> open(WidgetTester tester) async {
    final root = Directory.systemTemp.createTempSync('hom22_ui_');
    final store = (await tester.runAsync(() => LibraryStore.open(root: root.path, background: false)))!;
    return _Lib._(root, store);
  }

  Future<T> run<T>(WidgetTester tester, Future<T> Function(LibraryStore s) op) async => (await tester.runAsync(() => op(store))) as T;

  Future<FileEntry> add(WidgetTester tester, String name, {FolderId? folder}) => run(tester, (s) => s.write((w, now) {
        final c = classify(fileName: name);
        final job = w.beginImport(target: folder, now: now);
        (w.fs.openPart(job.id)..writeFromSync(name.codeUnits)).closeSync();
        return w.commitImport(job.id, ImportedFileInfo(displayName: name, kind: c.kind, subKind: c.subKind), now: now);
      }));

  Future<FolderId> folder(WidgetTester tester, String name) => run(tester, (s) => s.write((w, now) => w.createFolder(name, now: now)));

  String pathOf(FileEntry e) => store.paths.entryFile(e.id, e.displayName);

  FileEntry entry(FileEntry e) => store.reader.entry(e.id)!;

  Future<void> close(WidgetTester tester) async {
    DanaviewToast.dismiss();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await store.close();
      root.deleteSync(recursive: true);
    });
  }
}

final DateTime _t = DateTime.utc(2026, 10, 20);

MediaItem _itemOf(FileEntry e) => switch (e.kind) {
      FileKind.photo => PhotoMediaItem(id: e.id, uri: '/x/${e.displayName}', name: e.displayName, modifiedAt: _t, mimeType: 'image/jpeg', width: 4, height: 3),
      FileKind.video => VideoMediaItem(id: e.id, uri: '/x/${e.displayName}', name: e.displayName, modifiedAt: _t, mimeType: 'video/mp4', duration: const Duration(seconds: 3)),
      _ => DocumentItem(
          id: e.id,
          uri: '/x/${e.displayName}',
          name: e.displayName,
          modifiedAt: _t,
          mimeType: e.displayName.endsWith('.pdf') ? 'application/pdf' : 'application/octet-stream',
          docKind: e.displayName.endsWith('.pdf') ? DocumentKind.pdf : DocumentKind.other,
        ),
    };

Widget _harness(
  LibraryTestEnv env,
  _Lib lib,
  _Port port, {
  MediaItem? menuItem,
  TargetPlatform platform = TargetPlatform.iOS,
  double textScale = 1,
  List<SelectionGroupBuilder> groups = const [mediaSelectionGroup, fileSelectionGroup],
  List<Override> overrides = const [],
}) =>
    libraryTestApp(
      env,
      Scaffold(
        backgroundColor: DanaviewColors.background,
        body: Stack(children: [
          if (menuItem != null)
            Positioned(
              left: 16,
              top: 80,
              child: Consumer(
                builder: (context, ref, _) => DanaviewButton(
                  key: const ValueKey('open-menu'),
                  label: 'More',
                  onPressed: () => showFileActionsMenu(context, ref, menuItem),
                ),
              ),
            ),
          const Positioned(left: 0, right: 0, bottom: 0, child: HomeSelectionBar()),
        ]),
      ),
      platform: platform,
      textScale: textScale,
      overrides: [
        libraryStoreProvider.overrideWithValue(lib.store),
        fileOutPortProvider.overrideWithValue(port),
        selectionActionGroupsProvider.overrideWithValue(groups),
        ...overrides,
      ],
    );

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));

Future<void> _select(WidgetTester tester, List<MediaItem> items) async {
  final c = _container(tester).read(homeSelectionProvider.notifier);
  c.clear();
  for (final i in items) {
    c.select(i);
  }
  await tester.pump();
}

Future<void> _tapAction(WidgetTester tester, String id) async {
  final finder = find.byKey(ValueKey('selection-action-$id'));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

List<String> _actions(WidgetTester tester) => [
      for (final e in find.byWidgetPredicate((w) => w is DanaviewButton && w.key is ValueKey<String>).evaluate())
        if ((e.widget.key! as ValueKey<String>).value.startsWith('selection-action-'))
          (e.widget.key! as ValueKey<String>).value.replaceFirst('selection-action-', ''),
    ];

Finder _inDialog(String text) => find.descendant(of: find.byType(DanaviewDialog), matching: find.text(text));

void main() {
  late LibraryTestEnv env;

  setUp(() async => env = await LibraryTestEnv.create());
  tearDown(() => env.dispose());

  testWidgets('the file group follows the media group; read-only items get only the out actions; Android names Downloads', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final lib = await _Lib.open(tester);
    final photo = await lib.add(tester, 'Beach.jpg');
    final video = await lib.add(tester, 'Clip.mp4');
    await tester.pumpWidget(_harness(env, lib, _Port()));

    await _select(tester, [_itemOf(photo), _itemOf(video)]);
    expect(_actions(tester), [
      'play',
      'add-to-playlist',
      'file-share',
      'file-move-to',
      'file-copy-to',
      'file-favourite',
      'file-save-out',
      'file-save-photos',
      'file-delete',
    ]);
    expect(find.text('Save to Files'), findsOneWidget);

    final linked = DocumentItem(id: ItemId.parse('lk:root1/a.txt'), uri: '/Users/me/a.txt', name: 'a.txt', modifiedAt: _t, mimeType: 'text/plain', docKind: DocumentKind.text);
    await _select(tester, [_itemOf(photo), linked]);
    expect(_actions(tester), ['file-share', 'file-save-out'], reason: 'linked-folder files offer no rename, move or delete');

    await tester.pumpWidget(_harness(env, lib, _Port(FileOutPlatform.android), platform: TargetPlatform.android));
    await _select(tester, [_itemOf(photo)]);
    expect(find.text('Save to Downloads'), findsOneWidget);
    await lib.close(tester);
  });

  testWidgets('Save out and Share hand over the library files unchanged and leave selection mode', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final lib = await _Lib.open(tester);
    final a = await lib.add(tester, 'Report.pdf');
    final b = await lib.add(tester, 'Scan.jpg');
    final port = _Port();
    await tester.pumpWidget(_harness(env, lib, port));

    await _select(tester, [_itemOf(b), _itemOf(a)]);
    await _tapAction(tester, 'file-save-out');
    final (kind, files, target) = port.calls.single;
    expect(kind, 'save');
    expect(target, SaveOutTarget.files);
    expect([for (final f in files) f.path], [lib.pathOf(b), lib.pathOf(a)], reason: 'selection order');
    expect([for (final f in files) f.displayName], ['Scan.jpg', 'Report.pdf']);
    expect(find.text('Saved 2 copies'), findsOneWidget);
    expect(_container(tester).read(homeSelectionProvider).isEmpty, isTrue);
    expect(File(lib.pathOf(a)).readAsStringSync(), 'Report.pdf', reason: 'the library file is untouched');
    expect(lib.entry(a).folderId, a.folderId);

    await _select(tester, [_itemOf(a)]);
    await _tapAction(tester, 'file-share');
    expect(port.calls.last.$1, 'share');
    expect(port.calls.last.$2.single.path, lib.pathOf(a));

    port.fail = const FileOutException(FileOutError.denied);
    await _select(tester, [_itemOf(b)]);
    await _tapAction(tester, 'file-save-photos');
    expect(port.calls.last.$3, SaveOutTarget.photos);
    expect(find.text('Danaview isn’t allowed to add to Photos'), findsOneWidget);
    expect(_container(tester).read(homeSelectionProvider).length, 1, reason: 'a failure keeps the selection');
    await lib.close(tester);
  });

  testWidgets('Move to… and Copy to… pick a Danaview folder and update the database in one frame', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final lib = await _Lib.open(tester);
    final trips = await lib.folder(tester, 'Trips');
    final a = await lib.add(tester, 'A.jpg');
    final b = await lib.add(tester, 'B.jpg');
    await tester.pumpWidget(_harness(env, lib, _Port()));

    await _select(tester, [_itemOf(a), _itemOf(b)]);
    await _tapAction(tester, 'file-move-to');
    expect(find.byKey(const ValueKey('file-folder-picker')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('file-folder-${trips.value}')));
    await tester.pumpAndSettle();
    expect(lib.entry(a).folderId, trips);
    expect(lib.entry(b).folderId, trips);
    expect(find.text('Moved 2 files to Trips'), findsOneWidget);
    expect(_container(tester).read(homeSelectionProvider).isEmpty, isTrue);

    await _select(tester, [_itemOf(a)]);
    await _tapAction(tester, 'file-copy-to');
    final imported = lib.store.reader.systemFolder(FolderSystemRole.imported)!;
    await tester.tap(find.byKey(ValueKey('file-folder-${imported.id.value}')));
    await tester.pumpAndSettle();
    final copies = lib.store.reader.allEntries().where((e) => e.displayName == 'A.jpg').toList();
    expect(copies, hasLength(2));
    expect(copies.map((e) => e.folderId), containsAll([trips, imported.id]));
    await lib.close(tester);
  });

  testWidgets('Delete warns "Used in 2 projects" and moves to Recently deleted; Favourite toggles', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final lib = await _Lib.open(tester);
    final a = await lib.add(tester, 'Clip.mp4');
    final b = await lib.add(tester, 'Still.jpg');
    await lib.run(tester, (s) => s.write((w, _) {
          w.addRef(a.id, RefHolder.project('p1'));
          w.addRef(b.id, RefHolder.project('p2'));
        }));
    await tester.pumpWidget(_harness(env, lib, _Port()));

    await _select(tester, [_itemOf(a), _itemOf(b)]);
    await _tapAction(tester, 'file-favourite');
    expect(lib.entry(a).isFavourite && lib.entry(b).isFavourite, isTrue);
    expect(find.text('Added to favourites'), findsOneWidget);
    expect(_container(tester).read(homeSelectionProvider).length, 2, reason: 'favourite keeps the selection');

    await _tapAction(tester, 'file-delete');
    expect(find.text('Delete 2 files?'), findsOneWidget);
    expect(find.textContaining('Used in 2 projects'), findsOneWidget);
    await tester.tap(_inDialog('Cancel'));
    await tester.pumpAndSettle();
    expect(lib.entry(a).isTrashed, isFalse);

    await _tapAction(tester, 'file-delete');
    await tester.tap(_inDialog('Delete'));
    await tester.pumpAndSettle();
    expect(lib.entry(a).isTrashed && lib.entry(b).isTrashed, isTrue);
    expect(File(lib.pathOf(a)).existsSync(), isTrue, reason: 'files stay until the purge');
    expect(lib.store.reader.recentlyDeleted(), hasLength(2));
    expect(_container(tester).read(homeSelectionProvider).isEmpty, isTrue);
    expect(find.text('Moved 2 files to Recently deleted'), findsOneWidget);
    await lib.close(tester);
  });

  testWidgets('an unreferenced delete has no warning', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final lib = await _Lib.open(tester);
    final a = await lib.add(tester, 'Notes.pdf');
    await tester.pumpWidget(_harness(env, lib, _Port()));
    await _select(tester, [_itemOf(a)]);
    await _tapAction(tester, 'file-delete');
    expect(find.text('Delete this file?'), findsOneWidget);
    expect(find.textContaining('Used in'), findsNothing);
    expect(find.textContaining('Recently deleted for 30 days'), findsOneWidget);
    await tester.tap(_inDialog('Cancel'));
    await tester.pumpAndSettle();
    await lib.close(tester);
  });

  testWidgets('the single-file menu: rename, favourite, File info, open in', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final lib = await _Lib.open(tester);
    final trips = await lib.folder(tester, 'Trips');
    final a = await lib.add(tester, 'IMG_0001.jpg', folder: trips);
    final port = _Port();
    await tester.pumpWidget(_harness(env, lib, port, menuItem: _itemOf(a)));

    await tester.tap(find.byKey(const ValueKey('open-menu')));
    await tester.pumpAndSettle();
    for (final id in ['file-share', 'file-copy-to', 'file-move-to', 'file-rename', 'file-info', 'file-open-in', 'file-favourite', 'file-save-out', 'file-save-photos', 'file-delete']) {
      expect(find.byKey(ValueKey(id)), findsOneWidget, reason: id);
    }
    await tester.tap(find.byKey(const ValueKey('file-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'Sunset');
    await tester.tap(_inDialog('Rename'));
    await tester.pumpAndSettle();
    expect(lib.entry(a).displayName, 'Sunset.jpg', reason: 'the extension is kept');
    expect(File(lib.pathOf(lib.entry(a))).existsSync(), isTrue);

    await tester.tap(find.byKey(const ValueKey('open-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('file-info')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('file-info-sheet')), findsOneWidget);
    expect(find.text('JPG photo'), findsOneWidget);
    expect(find.text('Trips'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget, reason: 'where it came from');
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Add to favourites'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('file-favourite')));
    await tester.pumpAndSettle();
    expect(lib.entry(a).isFavourite, isTrue);

    await tester.tap(find.byKey(const ValueKey('open-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Remove from favourites'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('file-open-in')));
    await tester.pumpAndSettle();
    expect(port.calls.last.$1, 'open');
    expect(port.calls.last.$2.single.path, lib.pathOf(lib.entry(a)));
    await lib.close(tester);
  });

  testWidgets('Merge into PDF reaches the handler in selection order, only for PDFs and photos', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final lib = await _Lib.open(tester);
    final pdf = await lib.add(tester, 'A.pdf');
    final photo = await lib.add(tester, 'B.jpg');
    final video = await lib.add(tester, 'C.mp4');
    final merged = <List<String>>[];
    await tester.pumpWidget(_harness(
      env,
      lib,
      _Port(),
      groups: [mediaSelectionGroup, fileSelectionGroupWith(canMerge: true)],
      overrides: [
        mergeIntoPdfHandlerProvider.overrideWithValue((context, items) async => merged.add([for (final i in items) i.name])),
      ],
    ));
    await _select(tester, [_itemOf(photo), _itemOf(pdf)]);
    await _tapAction(tester, 'file-merge-pdf');
    expect(merged, [
      ['B.jpg', 'A.pdf'],
    ]);
    await _select(tester, [_itemOf(pdf), _itemOf(video)]);
    expect(_actions(tester), isNot(contains('file-merge-pdf')));
    await lib.close(tester);
  });

  testWidgets('no overflow at 280–1280 px × 0.85–1.35; targets ≥ 44 px; semantics labels', (tester) async {
    final handle = tester.ensureSemantics();
    final lib = await _Lib.open(tester);
    final folder = await lib.folder(tester, 'A folder with a rather long name for a narrow phone');
    final a = await lib.add(tester, 'A very long file name that would overflow a narrow screen if it were not handled.jpg', folder: folder);
    final b = await lib.add(tester, 'Short.pdf');
    for (final surface in homeShellSurfaces) {
      useSurface(tester, surface);
      await tester.pumpWidget(_harness(env, lib, _Port(), menuItem: _itemOf(a), textScale: surface.textScale));
      await _select(tester, [_itemOf(a), _itemOf(b)]);
      expect(tester.takeException(), isNull, reason: 'bar $surface');
      final bar = tester.getRect(find.byKey(const ValueKey('home-selection-bar')));
      expect(bar.left >= 0 && bar.right <= surface.size.width, isTrue, reason: '$surface');
      for (final id in ['file-share', 'file-delete']) {
        final size = tester.getSize(find.byKey(ValueKey('selection-action-$id')));
        expect(size.height >= 44 && size.width >= 44, isTrue, reason: '$id $size $surface');
      }

      await tester.tap(find.byKey(const ValueKey('open-menu')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'menu $surface');
      final tile = tester.getSize(find.byKey(const ValueKey('file-rename')));
      expect(tile.height, greaterThanOrEqualTo(44), reason: 'menu row $surface');
      await tester.tap(find.byKey(const ValueKey('file-info')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'info $surface');
      Navigator.of(tester.element(find.byKey(const ValueKey('file-info-sheet')))).pop();
      await tester.pumpAndSettle();

      await _select(tester, [_itemOf(a)]);
      await _tapAction(tester, 'file-move-to');
      expect(tester.takeException(), isNull, reason: 'picker $surface');
      final row = tester.getSize(find.byKey(ValueKey('file-folder-${folder.value}')));
      expect(row.height, greaterThanOrEqualTo(44), reason: 'picker row $surface');
      Navigator.of(tester.element(find.byKey(const ValueKey('file-folder-picker')))).pop();
      await tester.pumpAndSettle();

      await _tapAction(tester, 'file-delete');
      expect(tester.takeException(), isNull, reason: 'delete dialog $surface');
      await tester.tap(_inDialog('Cancel'));
      await tester.pumpAndSettle();
    }
    await _select(tester, [_itemOf(a), _itemOf(b)]);
    expect(find.bySemanticsLabel('File actions'), findsOneWidget);
    expect(find.bySemanticsLabel('Share 2 items'), findsOneWidget);
    expect(find.bySemanticsLabel('Delete 2 items'), findsOneWidget);
    expect(find.bySemanticsLabel('Move 2 items to a folder'), findsOneWidget);
    handle.dispose();
    await lib.close(tester);
  });

  test('computed contrast of the sheets, labels and messages', () {
    const sheet = DanaviewColors.surfaceElevated;
    expect(DanaviewColors.contrastRatio(DanaviewColors.textSecondary, sheet), greaterThanOrEqualTo(4.5));
    expect(DanaviewColors.contrastRatio(DanaviewColors.textPrimary, sheet), greaterThanOrEqualTo(4.5));
    expect(DanaviewColors.contrastRatio(DanaviewColors.foregroundOn(sheet), sheet), greaterThanOrEqualTo(4.5));
    expect(deleteMessage(const RefUsage(projects: 2, photos: 0)), startsWith('Used in 2 projects.'));
    expect(saveOutMessage(SaveOutOutcome.userCancelled, photos: false), isNull);
    expect(saveOutMessage(const SaveOutOutcome(cancelled: false, saved: 1, failed: 1), photos: true), 'Saved a copy to Photos; 1 couldn’t be saved');
    expect(fileOutPlatformOf(TargetPlatform.fuchsia), FileOutPlatform.linux);
    expect(fileActionLabel(FileAction.saveOut, capabilities: FileOutCapabilities.of(FileOutPlatform.macOS)), 'Save…');
  });
}
