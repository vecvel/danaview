// OWNER: HOM-21
//
// The app side of HOM-21 (ARCH v1.2 §5.6, P-7): a PDF or photo opened with Danaview is imported
// into Imported and handed to the viewer callback, a video opened from another app still goes to
// the player at once, "Save to Danaview folder" copies the playing file once (sourceHint player),
// and the inbox runs on start, on return to the foreground and on the extension's change event.
// With no library (DANAVIEW_FILES_HOME off) nothing is claimed or offered.
//
// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart' show MediaUrl;
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/import/import_providers.dart';
import 'package:danaview_features/src/player/danaview_player_actions.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';

class _Lib {
  _Lib(this.root, this.src, this.store, this.service);

  final Directory root;
  final Directory src;
  final LibraryStore store;
  final ImportService service;

  static Future<_Lib> open() async {
    final root = Directory.systemTemp.createTempSync('hom21_app_lib_');
    final src = Directory.systemTemp.createTempSync('hom21_app_src_');
    final store = await LibraryStore.open(root: root.path, background: false);
    return _Lib(root, src, store, ImportService(store: store));
  }

  String file(String name, int size, {int seed = 1}) {
    final f = File('${src.path}/$name')..writeAsBytesSync(List<int>.generate(size, (i) => (i * seed + 7) % 251));
    return f.path;
  }

  Future<void> close() async {
    await service.dispose();
    await store.close();
    root.deleteSync(recursive: true);
    src.deleteSync(recursive: true);
  }
}

/// An inbox port over a map; complete batches of local files.
final class _Inbox implements InboxPort {
  _Inbox(this.dir);

  final Directory dir;
  final Map<String, List<InboxFile>> batches = {};
  int runs = 0;

  void add(String id, String name, int size) {
    final f = File('${dir.path}/$id/$name')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(size, 3));
    batches[id] = [InboxFile(relativePath: name, displayName: name, sizeBytes: f.lengthSync())];
  }

  @override
  Future<bool> isAvailable() async {
    runs++;
    return true;
  }

  @override
  Future<List<InboxBatch>> listBatches() async => [
        for (final e in batches.entries) InboxBatch(batchId: e.key, createdAt: DateTime.utc(2026), complete: true, files: e.value),
      ];

  @override
  Future<void> takeFile(String batchId, String relativePath, String destinationPath) async {
    File(destinationPath).parent.createSync(recursive: true);
    File('${dir.path}/$batchId/$relativePath').renameSync(destinationPath);
  }

  @override
  Future<void> deleteBatch(String batchId) async => batches.remove(batchId);

  @override
  Future<int> deleteStaleBatches(Duration age) async => 0;

  @override
  Future<void> writeFolderSnapshot(List<int> json) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Open with Danaview', () {
    test('a PDF is imported into Imported and opened; a video goes to the player', () async {
      final lib = await _Lib.open();
      addTearDown(lib.close);
      final opened = <FileEntry>[];
      final intercept = incomingDocumentInterceptor(imports: () => lib.service, openEntry: opened.add);

      final pdf = lib.file('Lease.pdf', 3000);
      expect(await intercept(Uri.file(pdf).toString()), isTrue);
      expect(opened.single.displayName, 'Lease.pdf');
      expect(opened.single.sourceHint, SourceHint.openWith);
      expect(opened.single.folderId, lib.store.reader.systemFolder(FolderSystemRole.imported)!.id);
      expect(File(pdf).existsSync(), isTrue, reason: "the user's file is only read");

      expect(await intercept(lib.file('Holiday.mov', 3000)), isFalse, reason: 'videos play at once (P-7)');
      expect(await intercept('https://example.com/live.m3u8'), isFalse);
      expect(await intercept('danaview://open?url=https://example.com/a.mp4'), isFalse);
      expect(lib.store.reader.allEntries(), hasLength(1));

      // The same PDF again opens the entry already there.
      expect(await intercept(pdf), isTrue);
      expect(opened.map((e) => e.id).toSet(), hasLength(1));
    });

    test('without a library nothing is claimed; a failed import reports and is still claimed', () async {
      final none = incomingDocumentInterceptor(imports: () => null, openEntry: (_) => fail('no open'));
      expect(await none('/x/Report.pdf'), isFalse);

      final lib = await _Lib.open();
      addTearDown(lib.close);
      var failed = 0;
      final intercept = incomingDocumentInterceptor(imports: () => lib.service, openEntry: (_) => fail('no open'), onFailed: () => failed++);
      expect(await intercept('${lib.src.path}/missing.pdf'), isTrue);
      expect(failed, 1);
    });

    test('only copies under the app container on iOS are app-owned; never a user Inbox folder', () {
      addTearDown(SystemOpenInCopyRoots.reset);
      const app = '/var/mobile/Containers/Data/Application/X';
      final ios = SystemOpenInCopyRoots.ios(documentsDirectory: '$app/Documents', temporaryDirectory: '$app/tmp', bundleId: 'com.vecvel.danaview');
      expect(ios.contains('$app/Documents/Inbox/a.pdf'), isTrue);
      expect(ios.contains('/private$app/tmp/com.vecvel.danaview-Inbox/a.pdf'), isTrue);
      expect(ios.contains('$app/tmp/other-Inbox/a.pdf'), isFalse);
      expect(ios.contains('$app/Documents/Inbox/../Lease.pdf'), isFalse);
      expect(ios.contains('$app/Documents/a.pdf'), isFalse);
      expect(ios.contains('/var/mobile/Containers/Data/Application/Y/Documents/Inbox/a.pdf'), isFalse, reason: 'another container');
      expect(ios.contains('/Users/me/Documents/Inbox/a.pdf'), isFalse);

      // Off iOS nothing is app-owned, whatever the wiring passes.
      SystemOpenInCopyRoots.configure(ios, onIos: false);
      expect(isSystemOpenInCopy('$app/Documents/Inbox/a.pdf'), isFalse);
      expect(isSystemOpenInCopy('/Users/me/Documents/Inbox/report.pdf'), isFalse);
      expect(isSystemOpenInCopy(r'C:\Users\x\Documents\Inbox\a.jpg'), isFalse);
      expect(isSystemOpenInCopy('C:/Users/x/Documents/Inbox/a.jpg'), isFalse);
      expect(isSystemOpenInCopy('/tmp/com.vecvel.danaview-Inbox/a.pdf'), isFalse);
      SystemOpenInCopyRoots.reset();
      if (!Platform.isIOS) expect(isSystemOpenInCopy('/Users/me/Documents/Inbox/report.pdf'), isFalse);
    });

    test("a file in the user's own Documents/Inbox folder is imported and kept", () async {
      addTearDown(SystemOpenInCopyRoots.reset);
      final lib = await _Lib.open();
      addTearDown(lib.close);
      final inbox = Directory('${lib.src.path}/Documents/Inbox')..createSync(recursive: true);
      final pdf = File('${inbox.path}/report.pdf')..writeAsBytesSync(List<int>.generate(4000, (i) => (i * 3 + 1) % 251));
      final jpg = File('${inbox.path}/a.jpg')..writeAsBytesSync(List<int>.generate(4000, (i) => (i * 5 + 2) % 251));
      final opened = <FileEntry>[];
      expect(await openIncomingForViewing(pdf.path, imports: lib.service, openEntry: opened.add), isTrue);
      expect(await openIncomingForViewing(Uri.file(jpg.path).toString(), imports: lib.service, openEntry: opened.add), isTrue);
      expect(opened, hasLength(2));
      expect(pdf.existsSync(), isTrue, reason: "the user's file is only read (rule 27)");
      expect(jpg.existsSync(), isTrue);
      // A duplicate skip keeps it too.
      expect(await openIncomingForViewing(pdf.path, imports: lib.service, openEntry: opened.add), isTrue);
      expect(pdf.existsSync(), isTrue);
    });

    test('an iOS open-in copy under the configured app container is removed after its import', () async {
      addTearDown(SystemOpenInCopyRoots.reset);
      final lib = await _Lib.open();
      addTearDown(lib.close);
      final docs = Directory('${lib.src.path}/Documents');
      final tmp = Directory('${lib.src.path}/tmp');
      final copyDir = Directory('${docs.path}/Inbox')..createSync(recursive: true);
      tmp.createSync();
      SystemOpenInCopyRoots.configure(
        SystemOpenInCopyRoots.ios(documentsDirectory: docs.path, temporaryDirectory: tmp.path, bundleId: 'com.vecvel.danaview'),
        onIos: true,
      );
      final copy = File('${copyDir.path}/Lease.pdf')..writeAsBytesSync(List<int>.generate(4000, (i) => (i * 7 + 3) % 251));
      final own = File('${docs.path}/Mine.pdf')..writeAsBytesSync(List<int>.generate(4000, (i) => (i * 11 + 5) % 251));
      final opened = <FileEntry>[];
      expect(await openIncomingForViewing(copy.path, imports: lib.service, openEntry: opened.add), isTrue);
      expect(await openIncomingForViewing(own.path, imports: lib.service, openEntry: opened.add), isTrue);
      expect(opened, hasLength(2));
      expect(copy.existsSync(), isFalse, reason: 'the system copy is app-owned');
      expect(own.existsSync(), isTrue);
    });
  });

  group('Save to Danaview folder', () {
    testWidgets('copies the playing local file once and tells the user', (tester) async {
      useSurface(tester, librarySurfaces[1]);
      final env = await LibraryTestEnv.create();
      final lib = (await tester.runAsync(_Lib.open))!;
      final video = lib.file('Holiday.mov', 6000);
      late WidgetRef ref;
      late BuildContext ctx;
      await tester.pumpWidget(libraryTestApp(
        env,
        Consumer(builder: (context, r, _) {
          ref = r;
          ctx = context;
          return const SizedBox.expand();
        }),
        overrides: [libraryStoreProvider.overrideWithValue(lib.store), importServiceProvider.overrideWithValue(lib.service)],
      ));
      await pumpFrames(tester);
      expect(canSaveToDanaviewFolder(ref), isFalse, reason: 'nothing playing');

      await tester.runAsync(() => ref.read(queueControllerProvider.notifier).playFrom([LibraryRepository.mediaRefForFile(video)]));
      await pumpFrames(tester);
      expect(canSaveToDanaviewFolder(ref), isTrue);

      final first = (await tester.runAsync(() => saveToDanaviewFolder(ctx, ref)))!;
      await pumpFrames(tester);
      expect(first.sourceHint, SourceHint.player);
      expect(find.text('Saved to Danaview folders'), findsOneWidget);

      final item = saveToDanaviewFolderMenuItem(ctx, ref)!;
      expect(item.label, 'Save to Danaview folder');

      final again = (await tester.runAsync(() => saveToDanaviewFolder(ctx, ref)))!;
      await pumpFrames(tester);
      expect(again.id, first.id);
      expect(find.text('Already in Danaview folders'), findsOneWidget);
      expect(lib.store.reader.allEntries(), hasLength(1));
      expect(File(video).existsSync(), isTrue);

      DanaviewToast.dismiss();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(lib.close);
      await env.dispose();
    });

    testWidgets('the menu entry is hidden without a library and imports the playing file when tapped', (tester) async {
      useSurface(tester, librarySurfaces[1]);
      final env = await LibraryTestEnv.create();
      final lib = (await tester.runAsync(_Lib.open))!;
      final video = lib.file('Trip.mov', 5000);
      late WidgetRef ref;
      late BuildContext ctx;
      Widget host() => Consumer(builder: (context, r, _) {
            ref = r;
            ctx = context;
            return const SizedBox.expand();
          });
      await tester.pumpWidget(libraryTestApp(env, host()));
      await pumpFrames(tester);
      await tester.runAsync(() => ref.read(queueControllerProvider.notifier).playFrom([LibraryRepository.mediaRefForFile(video)]));
      await pumpFrames(tester);
      expect(saveToDanaviewFolderMenuItem(ctx, ref), isNull, reason: 'flag off: no library');
      await tester.pumpWidget(const SizedBox());

      await tester.pumpWidget(libraryTestApp(
        env,
        host(),
        overrides: [libraryStoreProvider.overrideWithValue(lib.store), importServiceProvider.overrideWithValue(lib.service)],
      ));
      await pumpFrames(tester);
      await tester.runAsync(() => ref.read(queueControllerProvider.notifier).playFrom([LibraryRepository.mediaRefForFile(video)]));
      await pumpFrames(tester);
      var closed = false;
      final item = saveToDanaviewFolderMenuItem(ctx, ref, beforeSave: () => closed = true)!;
      await tester.runAsync(() async {
        item.onTap!();
        for (var i = 0; i < 50 && lib.store.reader.allEntries().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await pumpFrames(tester);
      expect(closed, isTrue);
      expect(lib.store.reader.allEntries().single.sourceHint, SourceHint.player);
      expect(File(video).existsSync(), isTrue);

      DanaviewToast.dismiss();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(lib.close);
      await env.dispose();
    });

    testWidgets('streams and a closed library offer nothing', (tester) async {
      final env = await LibraryTestEnv.create();
      late WidgetRef ref;
      await tester.pumpWidget(libraryTestApp(env, Consumer(builder: (context, r, _) {
        ref = r;
        return const SizedBox.expand();
      })));
      await pumpFrames(tester);
      await tester.runAsync(() => ref.read(queueControllerProvider.notifier).playFrom([MediaUrl.tryParse('https://example.com/a.mp4')!]));
      await pumpFrames(tester);
      expect(saveableCurrentMedia(ref), isNull);
      expect(canSaveToDanaviewFolder(ref), isFalse);
      expect(saveToDanaviewFolderMenuItem(tester.element(find.byType(Consumer).first), ref), isNull, reason: 'a stream');
      await tester.pumpWidget(const SizedBox());
      await env.dispose();
    });
  });

  group('Share Extension inbox', () {
    test('runs on start, on return to the foreground and on change events', () async {
      final binding = TestWidgetsFlutterBinding.instance;
      final lib = await _Lib.open();
      final group = Directory.systemTemp.createTempSync('hom21_app_group_');
      final staging = Directory.systemTemp.createTempSync('hom21_app_stage_');
      final inbox = _Inbox(group)..add('b1', 'Lease.pdf', 1000);
      final changes = StreamController<void>.broadcast();
      final container = ProviderContainer(overrides: [
        libraryStoreProvider.overrideWithValue(lib.store),
        importServiceProvider.overrideWithValue(lib.service),
        inboxPortProvider.overrideWithValue(inbox),
        inboxStagingDirectoryProvider.overrideWithValue(staging.path),
        inboxChangesProvider.overrideWithValue(changes.stream),
      ]);
      final auto = container.read(inboxAutoImportProvider)!;
      final results = <InboxRunResult>[];
      final sub = auto.results.listen(results.add);

      Future<void> settle() async {
        for (var i = 0; i < 200 && (lib.service.busy || inbox.batches.isNotEmpty); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      await settle();
      expect(lib.store.reader.allEntries().map((e) => e.sourceHint), [SourceHint.shareExtension]);
      expect(inbox.batches, isEmpty);

      inbox.add('b2', 'IMG_2.jpg', 500);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle();
      expect(lib.store.reader.allEntries(), hasLength(2));

      inbox.add('b3', 'Notes.txt', 200);
      changes.add(null);
      await settle();
      expect(lib.store.reader.allEntries(), hasLength(3));
      expect(results.map((r) => r.imported.length), [1, 1, 1]);
      expect(inboxResultMessage(results.first), '1 shared item saved');

      await sub.cancel();
      container.dispose();
      await changes.close();
      await lib.close();
      group.deleteSync(recursive: true);
      staging.deleteSync(recursive: true);
    });

    test('no inbox without a port, a staging directory or a library', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(inboxImporterProvider), isNull);
      expect(container.read(inboxAutoImportProvider), isNull);
    });

    test('result messages', () {
      expect(inboxResultMessage(const InboxRunResult()), isNull);
      expect(inboxResultMessage(const InboxRunResult(failed: 2)), "2 items couldn't be saved");
    });
  });
}
