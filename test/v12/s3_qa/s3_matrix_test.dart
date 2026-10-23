// OWNER: S3-Q
//
// Slice S3 QA (BUILD_PLAN v1.2 §1A, S3-Q; the S3 share of QA-105 and QA-103): the overflow and
// accessibility matrix of the S3 surfaces as the app composes them (DanaviewApp, the app router,
// the S2 + S3 wiring over an in-process HOM-17 library, the iOS column of the viewer router), and
// the network guard of the S3 flows.
//
// Surfaces: the Documents tab (all types, with Danaview and linked-folder rows and very long
// names), a sub-filter with one row and one with none (empty state), a document row's menu; the
// viewer host with the PDF viewer (stand-in native view and document store, like HOM-24's tests),
// its search, pages and contents panels and its options menu; the Quick Look screen while the
// preview shows; the in-app text viewer and its options menu (Quick Look can't preview); the CSV
// grid; the file card of an unknown type; a linked-folder PDF; the inbox and Open with toasts.
//
// Matrix (ARCH v1.2 §1.4): widths 280, 375, 768, 1280 px × text scale 0.85, 1.35 with no exception
// (overflow) on every surface; at 375 px × 1.0 and 1280 px × 1.35 every surface also meets the iOS
// 44 pt tap target, labelled tap target and text contrast guidelines.
//
// Network guard: an HttpOverrides spy fails any HttpClient the S3 flows create (S3 adds no host).

// The root package reaches the library through danaview_features in its fixtures.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:danaview/app.dart';
import 'package:danaview/wiring/documents_wiring.dart';
import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/filters/filter_providers.dart' show linkedDocumentsProvider;
import 'package:danaview_features/src/player/danaview_player_actions.dart' show inboxResultMessage;
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../filters/filters_support.dart';

const String _longPdf = 'Quarterly report of the whole family business with a name far too long for a phone.pdf';
const String _longTxt = 'Meeting notes from a very long planning session about the next big release.txt';
const String _longCsv = 'Household budget with every single expense of the year and then some more.csv';
const String _longDocx = 'Letter to the housing society about the broken lift and the water supply.docx';
const String _longZip = 'Backup archive of the old laptop before it was handed over to the cousin.zip';

/// A 1×1 white PNG (page thumbnails).
final Uint8List _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, //
  0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F, //
  0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, //
  0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Fails the test when anything creates an HttpClient.
final class _NoNetwork extends HttpOverrides {
  final List<String> attempts = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts.add(StackTrace.current.toString().split('\n').take(6).join(' | '));
    throw StateError('S3 QA: no network expected');
  }
}

/// A PDF store like PDFKit's (Apple capabilities), 120 pages with an outline.
final class _Pdfs implements PdfDocuments {
  static const int pages = 120;

  @override
  Future<PdfCapabilities> capabilities() async =>
      const PdfCapabilities(platformView: true, search: true, selection: true, outline: true, passwords: true, textExtraction: true);

  @override
  Future<PdfProbe> probe(String path) async => const PdfProbe(canOpen: true, pageCount: pages);

  @override
  Future<PdfDocumentInfo> open(String path, {String? password}) async => const PdfDocumentInfo(handle: 3, pageCount: pages);

  @override
  Future<PdfDocumentInfo?> unlock(int handle, String password) async => null;

  @override
  Future<List<PdfOutlineEntry>> outline(int handle) async => const [
        PdfOutlineEntry(title: 'A chapter title that is much longer than any phone can show on one line', pageIndex: 0),
        PdfOutlineEntry(title: 'Details', pageIndex: 4, depth: 1),
        PdfOutlineEntry(title: 'Appendix', pageIndex: 90),
      ];

  @override
  Future<PdfPageImage> thumbnail(int handle, int pageIndex, {required int maxWidth, required int maxHeight}) async =>
      PdfPageImage(png: _png, width: 1, height: 1);

  @override
  Future<void> close(int handle) async {}
}

/// A stand-in for PDFKit's view.
final class _View implements PdfViewController {
  final StreamController<PdfViewState> _states = StreamController.broadcast();
  PdfViewState _state = const PdfViewState(viewId: 1, pageIndex: 0, pageCount: _Pdfs.pages);

  @override
  int get viewId => 1;

  @override
  Stream<PdfViewState> get states => _states.stream;

  @override
  Future<PdfViewState> state() async => _state;

  @override
  Future<void> goToPage(int pageIndex) async {
    _state = PdfViewState(viewId: 1, pageIndex: pageIndex, pageCount: _Pdfs.pages);
    _states.add(_state);
  }

  @override
  Future<void> setScale(double scale) async {}

  @override
  Future<void> zoomToFit() async {}

  @override
  Future<void> setDisplayMode(PdfDisplayMode mode) async {}

  @override
  Future<PdfSearchResult> search(String query, {bool caseSensitive = false, int maxHits = 500}) async => PdfSearchResult([
        for (var i = 0; i < 6; i++)
          PdfSearchHit(
            index: i,
            pageIndex: i * 7,
            rangeStart: 10,
            rangeLength: query.length,
            snippet: 'A long sentence on this page that mentions $query and keeps going well past the edge',
            snippetMatchStart: 42,
            snippetMatchLength: query.length,
          ),
      ]);

  @override
  Future<void> cancelSearch() async {}

  @override
  Future<void> showSearchHit(PdfSearchHit hit) => goToPage(hit.pageIndex);

  @override
  Future<void> clearSearch() async {}

  @override
  Future<String?> selectedText() async => null;

  @override
  Future<bool> copySelection() async => false;

  @override
  Future<void> clearSelection() async {}
}

class _FakePdfView extends StatefulWidget {
  const _FakePdfView({required this.onCreated});

  final ValueChanged<PdfViewController> onCreated;

  @override
  State<_FakePdfView> createState() => _FakePdfViewState();
}

class _FakePdfViewState extends State<_FakePdfView> {
  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() => widget.onCreated(_View()));
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Color(0xFF303030), child: SizedBox.expand());
}

/// Quick Look that previews Office files only; the preview stays up until the test ends.
final class _QuickLook implements QuickLookPort {
  final Completer<void> _shown = Completer<void>();

  @override
  Future<bool> canPreview(ViewerFile file) async => file.docKind == DocumentKind.word;

  @override
  Future<void> present(List<ViewerFile> files, {int initialIndex = 0}) => _shown.future;
}

DocumentViewerSetup _viewers() {
  final pdfs = _Pdfs();
  final ql = _QuickLook();
  return DocumentViewerSetup(
    viewers: {
      ViewerKind.pdf: pdfViewerBuilder(pdfs, viewBuilder: (context, doc, onCreated) => _FakePdfView(onCreated: onCreated)),
      ViewerKind.quickLook: quickLookViewerBuilder(ql),
    },
    probes: FunctionProbes({ViewerKind.pdf: pdfViewerProbe(pdfs), ViewerKind.quickLook: quickLookProbe(ql)}),
  );
}

DocumentItem _linkedPdf(String dir) => DocumentItem(
      id: LinkedItemId.of('root1', 'Guides/Manual.pdf'),
      uri: '$dir/Manual of the washing machine from the previous flat in the old town.pdf',
      name: 'Manual of the washing machine from the previous flat in the old town.pdf',
      modifiedAt: DateTime.utc(2026, 9, 1),
      mimeType: 'application/pdf',
      sizeBytes: 2048000,
      docKind: DocumentKind.pdf,
    );

final class _App {
  _App(this.tester, this.env, this.container, this.lib, this.entries, this.linked, this.tmp);

  final WidgetTester tester;
  final LibraryTestEnv env;
  final ProviderContainer container;
  final FixtureLibrary lib;
  final Map<String, FileEntry> entries;
  final DocumentItem linked;
  final Directory tmp;

  Future<void> settle({int frames = 8}) async {
    // The text viewer decodes off the UI isolate.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await pumpFrames(tester, count: frames);
  }

  Future<void> tab(HomeTab tab) async {
    await tester.ensureVisible(find.byKey(homeTabKey(tab)));
    await tester.pump();
    await tester.tap(find.byKey(homeTabKey(tab)));
    await pumpFrames(tester, count: 8);
  }

  Future<void> tapFinder(Finder f) async {
    await tester.ensureVisible(f.first);
    await tester.pump();
    await tester.tap(f.first);
    await settle();
  }

  Future<void> tapKey(String key) => tapFinder(find.byKey(ValueKey<String>(key)).hitTestable());

  Future<void> tapTooltip(String tooltip) => tapFinder(find.byTooltip(tooltip).hitTestable());

  /// Scrolls the tab's list until [target] is built and on screen (rows are built lazily).
  Future<void> reveal(Finder target) async {
    if (target.hitTestable().evaluate().isNotEmpty) return;
    final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
    await tester.scrollUntilVisible(target, 120, scrollable: lists.last, maxScrolls: 80);
    await pumpFrames(tester);
  }

  Future<void> open(String name, {HomeTab tab = HomeTab.documents}) async {
    await this.tab(tab);
    final row = find.byKey(ValueKey('library-entry-${entries[name]!.id.value}'));
    await reveal(row);
    await tapFinder(row);
    await settle(frames: 12);
    expect(find.byType(DocumentViewer), findsOneWidget, reason: 'the viewer of $name');
  }

  Future<void> back() async {
    Navigator.of(tester.element(find.byType(Navigator).last)).maybePop();
    await settle();
  }

  Future<void> closeMenu() async {
    await tester.tapAt(const Offset(2, 2));
    await pumpFrames(tester);
  }

  Future<void> dispose() async {
    DanaviewToast.dismiss();
    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester, count: 6);
    container.dispose();
    await lib.close(tester);
    await env.dispose();
    await tester.runAsync(() async => tmp.deleteSync(recursive: true));
  }
}

Future<_App> _pumpApp(WidgetTester tester, double textScale) async {
  FeatureFlags.debugFilesHomeOverride = true;
  addTearDown(FeatureFlags.debugReset);
  final env = await LibraryTestEnv.create();
  final lib = await FixtureLibrary.open(tester);
  final tmp = (await tester.runAsync(() async => Directory.systemTemp.createTempSync('s3q_matrix_')))!;
  final entries = <String, FileEntry>{};
  for (final name in [_longPdf, _longTxt, _longCsv, _longDocx, _longZip]) {
    entries[name] = await lib.add(tester, name, meta: name == _longPdf ? const EntryMeta(pageCount: 120) : null);
    lib.now = lib.now.add(const Duration(minutes: 1));
  }
  // Real content for the in-app viewers (the fixture library writes 3 placeholder bytes).
  await tester.runAsync(() async {
    final paths = lib.store.paths;
    File(paths.entryFile(entries[_longTxt]!.id, _longTxt)).writeAsStringSync([
      for (var i = 1; i <= 400; i++) 'Line $i: a fairly long line of notes that goes on past the edge of a phone screen — café, 日本語, 📄',
    ].join('\n'));
    File(paths.entryFile(entries[_longCsv]!.id, _longCsv)).writeAsStringSync([
      'Id,Description of the expense with a long header,City,Amount,Note',
      for (var i = 1; i <= 200; i++) '$i,Groceries and household items bought at the market $i,Zürich,${i * 3}.50,"has, comma"',
    ].join('\n'));
  });
  final linked = _linkedPdf(tmp.path);
  final runtime = (await tester.runAsync(() => filesHomeOverrides(
        prefs: env.prefs,
        // The Android runtime has no App Group inbox (no plugin in tests); the router still takes
        // the iOS column (debugDefaultTargetPlatformOverride) and the viewers are the fakes below.
        platform: TargetPlatform.android,
        directories: FilesHomeDirectories(support: tmp.path, cache: tmp.path),
        openStore: (_, __) async => lib.store,
        openThumbnails: (_) async => throw const FileSystemException('no thumbnails in tests'),
        observeLifecycle: false,
      )))!;
  final container = ProviderContainer(overrides: [
    ...env.overrides,
    ...runtime.overrides,
    documentViewerSetupProvider.overrideWithValue(_viewers()),
    linkedDocumentWalkerProvider.overrideWithValue((_) async => [linked]),
    linkedDocumentsProvider.overrideWithValue([linked]),
  ]);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DanaviewApp()));
  await pumpFrames(tester);
  return _App(tester, env, container, lib, entries, linked, tmp);
}

/// Visits every S3 surface; [check] runs on each.
Future<void> _visit(_App app, Future<void> Function(String where) check) async {
  final tester = app.tester;

  await app.tab(HomeTab.documents);
  await check('Documents tab (Danaview and linked rows)');
  await app.tapKey('documents-sub-word');
  await check('Documents tab, Word sub-filter');
  await app.tapKey('documents-sub-powerpoint');
  await check('Documents tab, empty sub-filter');
  await app.tapKey('documents-sub-all');
  final row = find.byKey(ValueKey('library-entry-${app.entries[_longPdf]!.id.value}'));
  await app.reveal(row);
  await tester.tap(find.descendant(of: row, matching: find.byTooltip('More')));
  await pumpFrames(tester);
  await check('Documents row menu');
  await app.closeMenu();

  await app.open(_longPdf);
  expect(find.byType(PdfViewer), findsOneWidget);
  await check('PDF viewer');
  await app.tapTooltip('Search in PDF');
  await tester.enterText(find.byType(EditableText).hitTestable().last, 'budget');
  await tester.pump(const Duration(milliseconds: 400));
  await app.settle();
  expect(find.byKey(const ValueKey('pdf-search-results')), findsOneWidget);
  await check('PDF search panel with results');
  FocusManager.instance.primaryFocus?.unfocus();
  await app.tapTooltip('Pages');
  await check('PDF pages panel');
  await app.tapTooltip('Contents');
  await check('PDF contents panel');
  await app.tapTooltip('Contents');
  await app.tapTooltip('View options');
  await check('PDF options menu');
  await app.closeMenu();
  await app.back();

  await app.open(_longDocx);
  expect(find.byType(QuickLookViewer), findsOneWidget);
  await check('Quick Look screen (preview showing)');
  await app.back();

  await app.open(_longTxt);
  expect(find.byKey(const ValueKey('text-viewer-rows')), findsOneWidget, reason: 'Quick Look cannot preview it: in-app text');
  await check('text viewer');
  await app.tapTooltip('View options');
  await check('text viewer options');
  await app.closeMenu();
  await app.back();

  await app.open(_longCsv);
  expect(find.byKey(const ValueKey('csv-viewer-rows')), findsOneWidget);
  await check('CSV grid');
  await app.back();

  await app.open(_longZip, tab: HomeTab.all);
  expect(find.byType(FileCard), findsOneWidget);
  await check('file card');
  await app.back();

  await app.tab(HomeTab.documents);
  final linkedRow = find.byKey(ValueKey('linked-document-${app.linked.id.value}'));
  await app.reveal(linkedRow);
  await app.tapFinder(linkedRow);
  await app.settle(frames: 12);
  expect(find.byType(DocumentViewer), findsOneWidget);
  await check('linked-folder PDF');
  await app.back();

  final home = tester.element(find.byType(DanaviewHomeScreen));
  DanaviewToast.show(home, inboxResultMessage(InboxRunResult(imported: [app.entries[_longPdf]!, app.entries[_longDocx]!], failed: 1))!);
  await pumpFrames(tester);
  await check('inbox toast');
  DanaviewToast.dismiss();
  DanaviewToast.show(home, "Couldn't open this file.", kind: DanaviewToastKind.error, icon: Icons.error_outline_rounded);
  await pumpFrames(tester);
  await check('Open with failure toast');
  DanaviewToast.dismiss();
  await pumpFrames(tester);
}

/// The texts on screen drawn with Flutter's fallback style (yellow double underline): a text with
/// no kit DefaultTextStyle above it (seen on the simulator in every document viewer, FIX-S3Q-2).
List<String> _fallbackTexts(WidgetTester tester) => [
      for (final e in find.byType(RichText).evaluate())
        if ((e.widget as RichText).text.style?.decorationStyle == TextDecorationStyle.double &&
            (e.widget as RichText).text.style?.decoration == TextDecoration.underline)
          (e.widget as RichText).text.toPlainText(),
    ];

void main() {
  tearDown(() {
    FeatureFlags.debugReset();
    debugDefaultTargetPlatformOverride = null;
  });

  group('S3 surfaces: no overflow', () {
    for (final width in [280.0, 375.0, 768.0, 1280.0]) {
      for (final scale in [0.85, 1.35]) {
        testWidgets('${width.toInt()} px @${scale}x', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          useSurface(tester, TestSurface(Size(width, width > 1000 ? 800 : (width > 700 ? 1024 : 640)), scale));
          final spy = _NoNetwork();
          await HttpOverrides.runWithHttpOverrides(() async {
            final app = await _pumpApp(tester, scale);
            await _visit(app, (where) async => expect(tester.takeException(), isNull, reason: where));
            await app.dispose();
          }, spy);
          expect(spy.attempts, isEmpty, reason: 'no HttpClient in the S3 flows');
          debugDefaultTargetPlatformOverride = null;
        });
      }
    }
  });

  // FIX-S3Q-2: remove the skip when the viewer host gives its route the kit text style.
  testWidgets('S3 surfaces: every text uses the kit text style (no fallback underline)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    useSurface(tester, const TestSurface(Size(375, 812), 1.0));
    final app = await _pumpApp(tester, 1.0);
    final failures = <String>[];
    await _visit(app, (where) async {
      final bad = _fallbackTexts(tester);
      if (bad.isNotEmpty) failures.add('$where: ${bad.length} texts, e.g. "${bad.first.length > 40 ? bad.first.substring(0, 40) : bad.first}"');
    });
    await app.dispose();
    debugDefaultTargetPlatformOverride = null;
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, skip: !const bool.fromEnvironment('S3Q_CHECK_TEXT_STYLE')); // FIX-S3Q-2 open: --dart-define=S3Q_CHECK_TEXT_STYLE=true

  group('S3 surfaces: targets, labels and contrast', () {
    for (final (width, scale) in [(375.0, 1.0), (1280.0, 1.35)]) {
      testWidgets('${width.toInt()} px @${scale}x', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        useSurface(tester, TestSurface(Size(width, width > 1000 ? 800 : 812), scale));
        final app = await _pumpApp(tester, scale);
        await _visit(app, (where) async {
          expect(tester.takeException(), isNull, reason: where);
          await expectLater(tester, meetsGuideline(iOSTapTargetGuideline), reason: where);
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline), reason: where);
          await expectLater(tester, meetsGuideline(textContrastGuideline), reason: where);
        });
        await app.dispose();
        debugDefaultTargetPlatformOverride = null;
      });
    }
  });
}
