// OWNER: S3-W
//
// BUILD_PLAN v1.2 §1A, S3 gate "Wiring and legal": the S3 features (Documents: view and share-in)
// are reachable in the real app (DanaviewApp with the app router) behind DANAVIEW_FILES_HOME, and
// nothing changes without it:
//
// * flag off: no S3 override, no interceptor on the incoming-media bridge;
// * flag on, runtime: the viewers per platform (PDF on iOS, macOS and Android; Quick Look on iOS and
//   macOS; built-in viewers only on Windows and Linux), the linked-document scan, and on iOS only
//   the Share Extension inbox (App Group port, change events, staging under the support folder);
// * flag on, app: the Documents tab lists Danaview and linked-folder documents; a PDF opens in the
//   registered PDF viewer through the router and lands in Recents; an unknown type gets the file
//   card; audio plays in the player; a linked document opens read-only; the inbox host runs the
//   importer when the Home mounts; Open with routes a PDF to the import-and-view path and leaves a
//   video to the player;
// * the linked-document walk: documents only, hidden and "Open in" copies skipped, stable `lk:` ids;
// * no overflow on the Documents tab and the file card at 280-1280 px and text scale 0.85-1.35.

// The root package reaches the library through danaview_features in its fixtures.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:danaview/app.dart';
import 'package:danaview/router/app_router.dart';
import 'package:danaview/wiring/documents_wiring.dart';
import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/import/import_providers.dart' show importPageCounterProvider;
import 'package:danaview_features/src/library/filters/filter_providers.dart' show linkedDocumentsProvider;
import 'package:danaview_features/src/player/danaview_player_actions.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart' show PdfDocuments, PdfProbe;
import 'package:danaview_platform/danaview_platform.dart' show IncomingMediaBridge;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../filters/filters_support.dart';

const ValueKey<String> _fakePdf = ValueKey('s3-fake-pdf-viewer');

/// A PDF viewer stand-in registered like HOM-24's (the native view needs a device).
final DocumentViewerSetup _fakeViewers = DocumentViewerSetup(
  viewers: {ViewerKind.pdf: (context, viewer) => const ColoredBox(key: _fakePdf, color: DanaviewColors.background)},
);

/// An inbox that records runs (no batches).
final class _Inbox implements InboxPort {
  int runs = 0;
  int snapshots = 0;

  @override
  Future<bool> isAvailable() async {
    runs++;
    return true;
  }

  @override
  Future<List<InboxBatch>> listBatches() async => const [];

  @override
  Future<void> takeFile(String batchId, String relativePath, String destinationPath) async {}

  @override
  Future<void> deleteBatch(String batchId) async {}

  @override
  Future<int> deleteStaleBatches(Duration age) async => 0;

  @override
  Future<void> writeFolderSnapshot(List<int> json) async => snapshots++;
}

final DocumentItem _linked = DocumentItem(
  id: LinkedItemId.of('root1', 'Guides/Manual.pdf'),
  uri: '${Directory.systemTemp.path}/Guides/Manual.pdf',
  name: 'Manual.pdf',
  modifiedAt: DateTime.utc(2026, 9, 1),
  mimeType: 'application/pdf',
  sizeBytes: 2048,
  docKind: DocumentKind.pdf,
);

class _App {
  _App(this.tester, this.env, this.container, this.lib, this.entries);

  final WidgetTester tester;
  final LibraryTestEnv env;
  final ProviderContainer container;
  final FixtureLibrary lib;
  final Map<String, FileEntry> entries;

  Future<void> tab(HomeTab tab) async {
    await tester.ensureVisible(find.byKey(homeTabKey(tab)));
    await tester.pump();
    await tester.tap(find.byKey(homeTabKey(tab)));
    await pumpFrames(tester, count: 8);
    expect(tester.takeException(), isNull);
  }

  Future<void> dispose() async {
    DanaviewToast.dismiss();
    IncomingMediaBridge.interceptor = null;
    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester, count: 6);
    container.dispose();
    await lib.close(tester);
    await env.dispose();
  }
}

Future<Map<String, FileEntry>> _seed(FixtureLibrary lib, WidgetTester tester) async {
  final out = <String, FileEntry>{};
  for (final name in ['Report.pdf', 'Notes.docx', 'Archive.zip', 'Song.mp3']) {
    out[name] = await lib.add(tester, name);
    lib.now = lib.now.add(const Duration(minutes: 1));
  }
  return out;
}

/// Boots the app with the flag on over an in-process fixture library, with the fake PDF viewer,
/// one linked document and an [inbox].
Future<_App> _pumpApp(WidgetTester tester, {double textScale = 1.0, _Inbox? inbox, List<Override> overrides = const []}) async {
  FeatureFlags.debugFilesHomeOverride = true;
  addTearDown(FeatureFlags.debugReset);
  final env = await LibraryTestEnv.create();
  final lib = await FixtureLibrary.open(tester);
  final entries = await _seed(lib, tester);
  final runtime = (await tester.runAsync(() => filesHomeOverrides(
        prefs: env.prefs,
        platform: TargetPlatform.android,
        directories: FilesHomeDirectories(support: Directory.systemTemp.path, cache: Directory.systemTemp.path),
        openStore: (_, __) async => lib.store,
        openThumbnails: (_) async => throw const FileSystemException('no thumbnails in tests'),
        observeLifecycle: false,
      )))!;
  final container = ProviderContainer(overrides: [
    ...env.overrides,
    ...runtime.overrides,
    documentViewerSetupProvider.overrideWithValue(_fakeViewers),
    linkedDocumentWalkerProvider.overrideWithValue((_) async => [_linked]),
    linkedDocumentsProvider.overrideWithValue([_linked]),
    if (inbox != null) ...[
      inboxPortProvider.overrideWithValue(inbox),
      inboxStagingDirectoryProvider.overrideWithValue('${Directory.systemTemp.path}/s3-inbox-staging-test'),
    ],
    ...overrides,
  ]);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DanaviewApp()));
  await pumpFrames(tester);
  return _App(tester, env, container, lib, entries);
}

Finder _row(String name) => find.text(name);

/// A PDF store whose probe answers [probe] (the page counter uses nothing else).
final class _ProbePdfs implements PdfDocuments {
  _ProbePdfs(this.probeResult);

  final PdfProbe probeResult;
  final List<String> probed = [];

  @override
  Future<PdfProbe> probe(String path) async {
    probed.add(path);
    return probeResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

void main() {
  tearDown(() {
    FeatureFlags.debugReset();
    IncomingMediaBridge.interceptor = null;
  });

  group('flag off', () {
    test('no S3 override and no Open with interceptor', () {
      FeatureFlags.debugFilesHomeOverride = false;
      expect(documentsWired, isFalse);
      for (final platform in TargetPlatform.values) {
        expect(documentsOverrides(platform: platform, support: '/s'), isEmpty, reason: platform.name);
      }
      for (final platform in [TargetPlatform.android, TargetPlatform.windows, TargetPlatform.linux]) {
        expect(installIncomingDocumentOpen(appNavigatorKey, openEntry: (_, __, ___) async {}, platform: platform), isFalse);
        expect(IncomingMediaBridge.interceptor, isNull, reason: platform.name);
      }
    });

    test('iOS and macOS: photos and documents opened with Danaview are claimed, not imported or played', () async {
      FeatureFlags.debugFilesHomeOverride = false;
      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        IncomingMediaBridge.interceptor = null;
        var opened = 0;
        expect(installIncomingDocumentOpen(appNavigatorKey, openEntry: (_, __, ___) async => opened++, platform: platform), isFalse);
        final claim = IncomingMediaBridge.interceptor!;
        for (final doc in ['/tmp/Guide.pdf', 'file:///tmp/Notes.docx', '/tmp/a.txt', '/tmp/IMG_1.jpg']) {
          expect(await claim(doc), isTrue, reason: '$doc on ${platform.name}');
        }
        for (final media in ['/tmp/clip.mp4', 'https://example.com/live.m3u8', 'danaview://open?url=https://e.com/a.mp4']) {
          expect(await claim(media), isFalse, reason: '$media keeps the 1.1 path on ${platform.name}');
        }
        expect(opened, 0);
      }
    });
  });

  group('flag on: the runtime', () {
    test('viewers per platform: PDF on Apple and Android, Quick Look on Apple, built-in elsewhere', () {
      Set<ViewerKind> kinds(TargetPlatform p) => documentViewerSetupFor(p).viewers.keys.toSet();
      expect(kinds(TargetPlatform.iOS), {ViewerKind.pdf, ViewerKind.quickLook});
      expect(kinds(TargetPlatform.macOS), {ViewerKind.pdf, ViewerKind.quickLook});
      expect(kinds(TargetPlatform.android), {ViewerKind.pdf});
      expect(kinds(TargetPlatform.windows), isEmpty);
      expect(kinds(TargetPlatform.linux), isEmpty);
    });

    test('the probes send a file the native viewer cannot open to the next candidate', () async {
      // No plugin in tests: the PDF probe says no, so a PDF on Android ends at the file card.
      final setup = documentViewerSetupFor(TargetPlatform.android);
      const file = ViewerFile(path: '/nowhere/a.pdf', displayName: 'a.pdf', kind: FileKind.document, docKind: DocumentKind.pdf);
      final viewer = await const ViewerRouter(ViewerPlatform.android)
          .resolve(file, registered: setup.viewers.keys.toSet(), probes: setup.probes);
      expect(viewer, ViewerKind.fileCard);
    });

    test('the iOS app installs the Share Extension inbox; other platforms do not', () {
      FeatureFlags.debugFilesHomeOverride = true;
      ProviderContainer containerFor(TargetPlatform p) => ProviderContainer(
            overrides: documentsOverrides(platform: p, support: '/support', excludeStagingFromBackup: false),
          );
      final ios = containerFor(TargetPlatform.iOS);
      addTearDown(ios.dispose);
      expect(ios.read(inboxPortProvider), isA<NativeInboxPort>());
      expect(ios.read(inboxChangesProvider), isNotNull);
      expect(ios.read(inboxStagingDirectoryProvider), inboxStagingIn('/support'));
      expect(inboxStagingIn('/support'), isNot(contains('Cache')));
      expect(ios.read(documentViewerSetupProvider).viewers.keys, containsAll([ViewerKind.pdf, ViewerKind.quickLook]));
      for (final p in [TargetPlatform.android, TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
        final c = containerFor(p);
        addTearDown(c.dispose);
        expect(c.read(inboxPortProvider), isNull, reason: p.name);
        expect(c.read(inboxStagingDirectoryProvider), isNull, reason: p.name);
      }
    });

    test('the import counts PDF pages where danaview_pdf runs (FIX-S3Q-4)', () async {
      FeatureFlags.debugFilesHomeOverride = true;
      ProviderContainer containerFor(TargetPlatform p, {PdfDocuments? pdf}) {
        final c = ProviderContainer(overrides: documentsOverrides(platform: p, support: '/support', pdf: pdf, excludeStagingFromBackup: false));
        addTearDown(c.dispose);
        return c;
      }

      for (final p in [TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.android]) {
        final pdfs = _ProbePdfs(const PdfProbe(canOpen: true, pageCount: 14));
        final count = containerFor(p, pdf: pdfs).read(importPageCounterProvider);
        expect(count, isNotNull, reason: p.name);
        expect(await count!('/lib/Report.pdf'), 14, reason: p.name);
        expect(pdfs.probed, ['/lib/Report.pdf']);
      }
      for (final p in [TargetPlatform.windows, TargetPlatform.linux]) {
        expect(containerFor(p).read(importPageCounterProvider), isNull, reason: p.name);
      }
      // A locked or unreadable PDF records no count.
      expect(await pdfPageCounter(_ProbePdfs(const PdfProbe(canOpen: true, encrypted: true)))('/a.pdf'), isNull);
      expect(await pdfPageCounter(_ProbePdfs(const PdfProbe(canOpen: false)))('/a.pdf'), isNull);
      // Flag off: nothing.
      FeatureFlags.debugFilesHomeOverride = false;
      expect(documentsOverrides(platform: TargetPlatform.iOS, support: '/s', pdf: _ProbePdfs(const PdfProbe(canOpen: true))), isEmpty);
    });

    test('library documents become viewer files with their type for Quick Look and sharing', () {
      final entry = FileEntry(
        id: EntryId.parse('fe_0123456789abcdef'),
        folderId: FolderId.parse('fd_0123456789abcdef'),
        displayName: 'Report.pdf',
        kind: FileKind.document,
        subKind: 'pdf',
        sizeBytes: 3,
        addedAt: DateTime.utc(2026),
        modifiedAt: DateTime.utc(2026),
        sourceHint: SourceHint.files,
      );
      final file = viewerFileOfEntry(entry, '/lib/Report.pdf');
      expect(file.mime, 'application/pdf');
      expect(file.uti, 'com.adobe.pdf');
      expect(file.entryId, entry.id, reason: 'Recents record Danaview folder entries');
      final linked = viewerFileOfLinked(_linked);
      expect(linked.entryId, isNull, reason: 'linked documents are never recorded');
      expect(linked.uti, 'com.adobe.pdf');
      expect(file.toString(), isNot(contains('Report')));
    });
  });

  group('the linked-document walk', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('s3-linked'));
    tearDown(() => root.deleteSync(recursive: true));

    void touch(String rel) => File('${root.path}/$rel')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');

    test('lists documents only, skips hidden files and Open in copies, with stable lk: ids', () async {
      for (final rel in ['Lease.pdf', 'Budget.xlsx', 'Clip.mp4', 'Photo.jpg', '.Secret.pdf', 'Sub/Notes.txt', 'Documents/Inbox/Copy.pdf', '.hidden/Deep.pdf']) {
        touch(rel);
      }
      // Off iOS a `Documents/Inbox` folder is the user's own (HOM-21): its files are listed.
      SystemOpenInCopyRoots.reset();
      addTearDown(SystemOpenInCopyRoots.reset);
      final desktop = await walkLinkedDocuments([root.path]);
      expect(desktop.map((d) => d.name).toSet(), {'Lease.pdf', 'Budget.xlsx', 'Notes.txt', 'Copy.pdf'});
      // On iOS the copies the system made for "Open in" (the app's own Documents/Inbox) are not.
      SystemOpenInCopyRoots.configure(
        SystemOpenInCopyRoots.ios(documentsDirectory: '${root.path}/Documents', temporaryDirectory: '${root.path}/tmp'),
        onIos: true,
      );
      final docs = await walkLinkedDocuments([root.path]);
      expect(docs.map((d) => d.name).toSet(), {'Lease.pdf', 'Budget.xlsx', 'Notes.txt'});
      final lease = docs.firstWhere((d) => d.name == 'Lease.pdf');
      expect(lease.docKind, DocumentKind.pdf);
      expect(lease.mimeType, 'application/pdf');
      final id = LinkedItemId.tryParse(lease.id.value);
      expect(id, isNotNull);
      expect(id!.relativePath, 'Lease.pdf');
      expect(id.rootId, linkedRootToken(root.path));
      expect(LinkedItemId.tryParse(docs.firstWhere((d) => d.name == 'Notes.txt').id.value)!.relativePath, 'Sub/Notes.txt');
      final again = await walkLinkedDocuments([root.path]);
      expect(again.map((d) => d.id).toSet(), docs.map((d) => d.id).toSet());
    });

    test('a missing root is passed over', () async {
      expect(await walkLinkedDocuments(['${root.path}/gone']), isEmpty);
    });
  });

  group('flag on: the app', () {
    testWidgets('the Documents tab lists Danaview and linked documents; a PDF opens in the PDF viewer and lands in Recents',
        (tester) async {
      useSurface(tester, const TestSurface(Size(390, 1400), 1.0));
      final app = await _pumpApp(tester);
      expect(find.byKey(homeTabKey(HomeTab.documents)), findsOneWidget);
      await app.tab(HomeTab.documents);
      expect(_row('Report.pdf'), findsOneWidget);
      expect(_row('Notes.docx'), findsOneWidget);
      expect(_row('Song.mp3'), findsNothing, reason: 'audio is not a document');
      expect(find.byKey(ValueKey('linked-document-${_linked.id.value}')), findsOneWidget);

      await tester.tap(_row('Report.pdf'));
      await pumpFrames(tester, count: 8);
      expect(find.byType(DocumentViewer), findsOneWidget);
      expect(find.byKey(_fakePdf), findsOneWidget, reason: 'the router picked the registered PDF viewer');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await pumpFrames(tester);
      final report = app.lib.store.reader.entry(app.entries['Report.pdf']!.id);
      expect(report?.lastOpenedAt, isNotNull, reason: 'Recents (HOM-19) record the open');
      await app.dispose();
    });

    testWidgets('an unknown type gets the file card; audio plays in the player', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 1400), 1.0));
      final app = await _pumpApp(tester);
      await app.tab(HomeTab.all);
      await tester.tap(_row('Archive.zip'));
      await pumpFrames(tester, count: 8);
      expect(find.byKey(const ValueKey(ViewerKind.fileCard)), findsOneWidget);
      await tester.binding.handlePopRoute();
      await pumpFrames(tester, count: 8);
      expect(find.byType(DocumentViewer), findsNothing);

      await tester.tap(_row('Song.mp3'));
      await pumpFrames(tester, count: 10);
      expect(app.container.read(queueControllerProvider).currentItem, isNotNull);
      expect(find.byType(DanaviewPlayerScreen), findsOneWidget);
      await app.dispose();
    });

    testWidgets('a linked document opens read-only in the viewer', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 1400), 1.0));
      final app = await _pumpApp(tester);
      await app.tab(HomeTab.documents);
      await tester.tap(find.byKey(ValueKey('linked-document-${_linked.id.value}')));
      await pumpFrames(tester, count: 8);
      expect(find.byKey(_fakePdf), findsOneWidget);
      await app.dispose();
    });

    testWidgets('the Home runs the Share Extension inbox when it mounts', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 844), 1.0));
      final inbox = _Inbox();
      final app = await _pumpApp(tester, inbox: inbox);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await pumpFrames(tester);
      expect(inbox.runs, greaterThan(0));
      expect(inbox.snapshots, greaterThan(0), reason: "the extension's folder picker gets a snapshot");
      await app.dispose();
      final staging = Directory('${Directory.systemTemp.path}/s3-inbox-staging-test');
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    });

    testWidgets('Open with: a PDF is claimed for import-and-view, a video stays with the player', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 844), 1.0));
      final app = await _pumpApp(tester);
      final opened = <FileEntry>[];
      expect(
        installIncomingDocumentOpen(appNavigatorKey, openEntry: (context, read, entry) async => opened.add(entry)),
        isTrue,
      );
      final claim = IncomingMediaBridge.interceptor!;
      expect(await tester.runAsync(() => claim('https://example.invalid/movie.mp4')), isFalse);
      expect(await tester.runAsync(() => claim('/somewhere/Clip.mov')), isFalse);
      final src = Directory.systemTemp.createTempSync('s3-open-with');
      addTearDown(() => src.deleteSync(recursive: true));
      final pdf = File('${src.path}/Lease.pdf')..writeAsBytesSync(List<int>.filled(64, 1));
      final claimed = await tester.runAsync(() async {
        final r = await claim(Uri.file(pdf.path).toString());
        // Let the import commit before reading the result.
        for (var i = 0; i < 50 && opened.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return r;
      });
      expect(claimed, isTrue);
      expect(opened.single.displayName, 'Lease.pdf');
      expect(pdf.existsSync(), isTrue, reason: 'the source is only read (rule 27)');
      await app.dispose();
    });
  });

  group('flag on: review fixes', () {
    testWidgets('the viewer route gives every text the kit style (no fallback underline, FIX-S3Q-2)', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 1400), 1.0));
      final app = await _pumpApp(tester);
      await app.tab(HomeTab.all);
      await tester.tap(_row('Archive.zip'));
      await pumpFrames(tester, count: 8);
      expect(find.byKey(const ValueKey(ViewerKind.fileCard)), findsOneWidget);
      final texts = find.descendant(of: find.byType(DocumentViewer), matching: find.byType(RichText)).evaluate().toList();
      expect(texts, isNotEmpty);
      for (final e in texts) {
        final style = (e.widget as RichText).text.style;
        expect(style?.decoration == TextDecoration.underline && style?.decorationStyle == TextDecorationStyle.double, isFalse,
            reason: 'a viewer text has the fallback debug style');
      }
      expect(find.ancestor(of: find.byType(DocumentViewer), matching: find.byType(Material)), findsWidgets);
      final resolved = DefaultTextStyle.of(tester.element(find.byType(DocumentViewer))).style;
      expect(resolved.fontFamily, contains('Figtree'), reason: 'the kit text style');
      expect(resolved.fontSize, DanaviewTextStyles.body.fontSize);
      expect(resolved.decoration, TextDecoration.none);
      await app.dispose();
    });

    testWidgets("Open with: a failed import shows \"Couldn't open this file.\" from the root navigator", (tester) async {
      useSurface(tester, const TestSurface(Size(390, 844), 1.0));
      final app = await _pumpApp(tester);
      final opened = <FileEntry>[];
      expect(installIncomingDocumentOpen(appNavigatorKey, openEntry: (context, read, entry) async => opened.add(entry)), isTrue);
      final claim = IncomingMediaBridge.interceptor!;
      final src = Directory.systemTemp.createTempSync('s3-open-with-fail');
      addTearDown(() => src.deleteSync(recursive: true));
      // A PDF that is gone by the time the import reads it: the import fails.
      final missing = '${src.path}/Gone.pdf';
      final claimed = await tester.runAsync(() => claim(Uri.file(missing).toString()));
      for (var i = 0; i < 50 && find.text(incomingOpenFailedMessage).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(claimed, isTrue);
      expect(opened, isEmpty);
      expect(find.text(incomingOpenFailedMessage), findsOneWidget);
      await app.dispose();
    });

    testWidgets("a document entry reaches HOM-22's Share and File info through the file menu (FIX-S3Q-1)", (tester) async {
      useSurface(tester, const TestSurface(Size(390, 1400), 1.0));
      final app = await _pumpApp(tester);
      await app.tab(HomeTab.documents);
      final ref = tester.element(find.byType(InboxImportHost)) as WidgetRef;
      final context = tester.element(_row('Notes.docx'));
      unawaited(showLibraryEntryFileMenu(context, ref, app.entries['Notes.docx']!));
      await pumpFrames(tester, count: 8);
      expect(find.byKey(const ValueKey('file-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('file-favourite')), findsOneWidget);
      expect(find.byKey(const ValueKey('file-copy-to')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('file-info')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('file-info')));
      await pumpFrames(tester, count: 8);
      expect(find.text('Notes.docx'), findsWidgets);
      expect(tester.takeException(), isNull);
      await app.dispose();
    });
  });

  group('flag on: file actions for documents (FIX-S3Q-1)', () {
    testWidgets('the row menu offers Open and "More actions…", which opens the file menu', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 1400), 1.0));
      final app = await _pumpApp(tester);
      await app.tab(HomeTab.documents);
      final row = find.byKey(ValueKey('library-entry-${app.entries['Notes.docx']!.id.value}'));
      await tester.tap(find.descendant(of: row, matching: find.byTooltip('More')));
      await pumpFrames(tester, count: 6);
      expect(find.text('Open'), findsOneWidget);
      await tester.tap(find.text('More actions…'));
      await pumpFrames(tester, count: 8);
      for (final id in ['file-share', 'file-favourite', 'file-copy-to', 'file-info']) {
        expect(find.byKey(ValueKey(id)), findsOneWidget, reason: id);
      }
      expect(tester.takeException(), isNull);
      await app.dispose();
    });

    testWidgets("the viewer's top bar opens Share, Save out and File info", (tester) async {
      useSurface(tester, const TestSurface(Size(390, 1400), 1.0));
      final app = await _pumpApp(tester);
      await app.tab(HomeTab.all);
      await tester.tap(_row('Archive.zip'));
      await pumpFrames(tester, count: 8);
      expect(find.byKey(const ValueKey(ViewerKind.fileCard)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('viewer-file-menu')));
      await pumpFrames(tester, count: 8);
      expect(find.byKey(const ValueKey('file-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('file-info')), findsOneWidget);
      expect(find.byKey(const ValueKey('file-delete')), findsNothing, reason: 'Delete stays in the row menu');
      expect(find.byKey(const ValueKey('file-move-to')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('file-info')));
      await pumpFrames(tester, count: 8);
      expect(find.text('Archive.zip'), findsWidgets);
      expect(tester.takeException(), isNull);
      await app.dispose();
    });
  });

  group('flag on: no overflow', () {
    for (final width in [280.0, 375.0, 1280.0]) {
      for (final scale in [0.85, 1.35]) {
        testWidgets('Documents tab and file card at ${width.toInt()} px @${scale}x', (tester) async {
          useSurface(tester, TestSurface(Size(width, width > 1000 ? 800 : 640), scale));
          final app = await _pumpApp(tester, textScale: scale);
          await app.tab(HomeTab.documents);
          expect(tester.takeException(), isNull);
          await tester.tap(_row('Notes.docx'));
          await pumpFrames(tester, count: 8);
          expect(find.byKey(const ValueKey(ViewerKind.fileCard)), findsOneWidget, reason: 'Android: Office files get the card');
          expect(tester.takeException(), isNull);
          await app.dispose();
        });
      }
    }
  });
}
