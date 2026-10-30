// OWNER: S4-Q
//
// Slice S4 QA (BUILD_PLAN v1.2 §1A, S4-Q; the S4 share of QA-105 and QA-103): the overflow and
// accessibility matrix of every S4 surface as the app composes it (DanaviewApp, the app router,
// the S2 + S3 + S4 wiring over an in-process HOM-17 library, the iOS column of the viewer router),
// and the network guard of the S4 flows.
//
// Surfaces: a PDF's file menu (Organise pages, Merge with…, Compress…, Sign…); the selection bar
// with Merge into PDF; the PDF viewer's top bar (Organise pages, Annotate, Sign) and menu (Merge
// with…, Compress…; Sign… under 360 pt); the organiser (grid, a selection, the split sheet in both
// modes, the save choice, the progress sheet, the discard prompt); the merge picker and the merge
// screen; the compress sheet (presets with estimates, progress, done, not smaller, error); annotate
// (each tool, a text selection, the text prompt, a selected mark, the discard prompt); sign (the
// New signature sheet in Draw, Type and Import, the toolbar with saved signatures, a selected
// signature, the saved-signatures sheet, the discard prompt); Settings › Privacy's saved
// signatures. The native parts are stand-ins (PDF store, page tools, annotate and compress
// engines, the PDFKit view); the signature store is the real file store in a temp folder.
//
// Matrix (ARCH v1.2 §1.4): widths 280, 375, 768, 1280 px × text scale 0.85, 1.35 with no exception
// (overflow) on every surface, with a PDF that has a table of contents (as most real reports do); at 375 px × 1.0 and 1280 px × 1.35 every surface also meets the iOS
// 44 pt tap target, labelled tap target and text contrast guidelines; at 375 px × 1.0 no text is
// drawn with Flutter's fallback style (S3-Q's check, FIX-S3Q-2). These two run on a PDF without
// a table of contents, so FIX-S4Q-1's top-bar overflow doesn't hide their own results. With
// `--dart-define=S4Q_SKIP_TEXT_STYLE=true` the last check is skipped.
//
// Network guard: an HttpOverrides spy fails any HttpClient the S4 flows create (S4 adds no host).

// The root package reaches the library through danaview_features in its fixtures.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:danaview/app.dart';
import 'package:danaview/router/app_router.dart' show appNavigatorKey;
import 'package:danaview/wiring/documents_wiring.dart';
import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview/wiring/pdf_tools_wiring.dart';
import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/selection/selection_model.dart' show homeSelectionProvider;
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../library_test_utils.dart';
import '../filters/filters_support.dart';

const bool _skipTextStyle = bool.fromEnvironment('S4Q_SKIP_TEXT_STYLE');

const String _longPdf = 'Signed lease agreement for the flat in the old town with every annex and schedule.pdf';
const String _otherPdf = 'Electricity bills of the whole year scanned at the office in one long file.pdf';
const String _photo = 'Receipt photographed on the kitchen table after the very long trip.jpg';
const int _pages = 12;

/// A 2×2 PNG (thumbnails and saved signatures).
final Uint8List _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, //
  0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F, //
  0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, //
  0x44, 0xAE, 0x42, 0x60, 0x82,
]);

const Set<PdfTool> _allTools = {
  PdfTool.merge, PdfTool.split, PdfTool.reorder, PdfTool.rotate, PdfTool.deletePages, //
  PdfTool.annotate, PdfTool.sign, PdfTool.compress,
};

/// Fails the test when anything creates an HttpClient.
final class _NoNetwork extends HttpOverrides {
  final List<String> attempts = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts.add(StackTrace.current.toString().split('\n').take(6).join(' | '));
    throw StateError('S4 QA: no network expected');
  }
}

final class _Pdfs implements PdfDocuments {
  _Pdfs({required this.withOutline});

  /// The document has a table of contents (the viewer then shows "Contents" in its top bar).
  final bool withOutline;

  @override
  Future<PdfCapabilities> capabilities() async => const PdfCapabilities(
      platformView: true, search: true, selection: true, outline: true, passwords: true, textExtraction: true, tools: _allTools);

  @override
  Future<PdfProbe> probe(String path) async => const PdfProbe(canOpen: true, pageCount: _pages);

  @override
  Future<PdfDocumentInfo> open(String path, {String? password}) async =>
      PdfDocumentInfo(handle: 3, pageCount: _pages, pageSizes: List.filled(_pages, const PdfPageSize(595, 842)));

  @override
  Future<PdfDocumentInfo?> unlock(int handle, String password) async => null;

  @override
  Future<List<PdfOutlineEntry>> outline(int handle) async => withOutline
      ? const [
          PdfOutlineEntry(title: 'Schedule A: inventory of the furniture', pageIndex: 0),
          PdfOutlineEntry(title: 'Signatures', pageIndex: 11),
        ]
      : const [];

  @override
  Future<PdfPageImage> thumbnail(int handle, int pageIndex, {required int maxWidth, required int maxHeight}) async =>
      PdfPageImage(png: _png, width: 1, height: 1);

  @override
  Future<void> close(int handle) async {}
}

/// Page tools whose jobs stay open (the progress sheet) until cancelled.
final class _Tools implements PdfPageTools {
  final List<Completer<PdfToolResult>> open = [];

  PdfToolJob _pending() {
    final done = Completer<PdfToolResult>();
    open.add(done);
    final progress = StreamController<PdfToolProgress>();
    scheduleMicrotask(() => progress.add(const PdfToolProgress(fraction: 0.4, pagesDone: 5, pagesTotal: _pages)));
    return PdfToolJobHandle(
      id: 'job-${open.length}',
      run: done.future,
      progress: progress.stream,
      onCancel: () async {
        if (!done.isCompleted) done.completeError(const PdfException(PdfErrorCode.cancelled, 'cancelled'));
      },
    );
  }

  @override
  Future<Set<PdfTool>> supported() async => _allTools;

  @override
  PdfToolJob merge(List<PdfToolInput> inputs, {required String outPath}) => _pending();

  @override
  PdfToolJob split(PdfToolInput input, List<PdfPageRange> ranges, {required List<String> outPaths}) => _pending();

  @override
  PdfToolJob organise(PdfToolInput input, List<PdfPagePlan> plan, {required String outPath}) => _pending();

  @override
  dynamic noSuchMethod(Invocation invocation) => _pending();
}

final class _Annotate implements PdfAnnotateEngine {
  final StreamController<PdfAnnotateEvent> events_ = StreamController<PdfAnnotateEvent>.broadcast();

  @override
  Future<void> setMode(int viewId, PdfAnnotateMode? mode) async {}

  @override
  Future<void> show(int viewId, List<PdfAnnotateItem> items, {String? selectedId}) async => shown = items;

  List<PdfAnnotateItem> shown = const [];

  @override
  Future<List<PdfPageRects>> selectionLines(int viewId) async => const [PdfPageRects(0, [PdfRect(40, 100, 200, 14)])];

  @override
  Stream<PdfAnnotateEvent> events(int viewId) => events_.stream;

  @override
  PdfToolJob save(PdfToolInput input, {required List<PdfAnnotation> annotations, List<PdfStamp> stamps = const [], bool burnIn = false, required String outPath}) =>
      PdfToolJobHandle(id: 'save', run: Completer<PdfToolResult>().future, onCancel: () async {});
}

/// Compress: estimates; [gate] holds a run open (progress); [result] decides done / not smaller /
/// error.
final class _Compress implements PdfCompressEngine {
  Completer<void>? gate;
  String result = 'done';

  @override
  Future<PdfCompressEstimate?> estimate(String path, {String? password}) async => const PdfCompressEstimate(
      sourceBytes: 200000, bytes: {PdfCompressPreset.high: 150000, PdfCompressPreset.medium: 90000, PdfCompressPreset.small: 40000});

  @override
  Future<PdfCompressOutput> compress({
    required String jobId,
    required String path,
    required PdfCompressPreset preset,
    required String outPath,
    String? password,
    void Function(double fraction)? onProgress,
  }) async {
    onProgress?.call(0.4);
    final g = gate;
    if (g != null) await g.future;
    if (result == 'error') throw const PdfException(PdfErrorCode.damaged, 'fake');
    final size = result == 'larger' ? 400000 : 50000;
    File(outPath).writeAsBytesSync(Uint8List(size));
    onProgress?.call(1);
    return PdfCompressOutput(path: outPath, sizeBytes: size, pageCount: _pages);
  }

  @override
  Future<void> cancel(String jobId) async {
    final g = gate;
    if (g != null && !g.isCompleted) g.complete();
  }
}

/// A stand-in for PDFKit's view; [selected] reports a text selection.
final class _View implements PdfViewController {
  _View(this.selected);

  final bool selected;
  final StreamController<PdfViewState> _states = StreamController.broadcast();

  PdfViewState get _state => PdfViewState(viewId: 1, pageIndex: 0, pageCount: _pages, hasSelection: selected);

  @override
  int get viewId => 1;

  @override
  Stream<PdfViewState> get states => _states.stream;

  @override
  Future<PdfViewState> state() async => _state;

  @override
  Future<void> goToPage(int pageIndex) async {}

  @override
  Future<void> setScale(double scale) async {}

  @override
  Future<void> zoomToFit() async {}

  @override
  Future<void> setDisplayMode(PdfDisplayMode mode) async {}

  @override
  Future<PdfSearchResult> search(String query, {bool caseSensitive = false, int maxHits = 500}) async => const PdfSearchResult([]);

  @override
  Future<void> cancelSearch() async {}

  @override
  Future<void> showSearchHit(PdfSearchHit hit) async {}

  @override
  Future<void> clearSearch() async {}

  @override
  Future<String?> selectedText() async => selected ? 'text' : null;

  @override
  Future<bool> copySelection() async => selected;

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
    scheduleMicrotask(() => widget.onCreated(_View(true)));
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Color(0xFF303030), child: SizedBox.expand());
}

final class _App {
  _App(this.tester, this.env, this.container, this.lib, this.entries, this.tmp, this.annotate, this.compress, this.tools);

  final WidgetTester tester;
  final LibraryTestEnv env;
  final ProviderContainer container;
  final FixtureLibrary lib;
  final Map<String, FileEntry> entries;
  final Directory tmp;
  final _Annotate annotate;
  final _Compress compress;
  final _Tools tools;

  Future<void> settle({int frames = 8}) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
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

  Future<void> tapKey(String key) async {
    final f = find.byKey(ValueKey<String>(key));
    await waitFor(f);
    await tester.ensureVisible(f.first);
    await pumpFrames(tester);
    await tester.tap(f.hitTestable().first);
    await settle();
  }

  /// Lets real I/O (the file signature store, imports) finish until [f] is built.
  Future<void> waitFor(Finder f) async {
    for (var i = 0; i < 20 && f.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await pumpFrames(tester, count: 4);
    }
  }

  Future<void> tapTooltip(String tooltip) => tapFinder(find.byTooltip(tooltip).hitTestable().last);

  Future<void> tapText(String text) => tapFinder(find.text(text).hitTestable().last);

  Future<void> reveal(Finder target) async {
    if (target.hitTestable().evaluate().isNotEmpty) return;
    final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
    await tester.scrollUntilVisible(target, 120, scrollable: lists.last, maxScrolls: 80);
    await pumpFrames(tester);
  }

  Future<void> popTop() async {
    Navigator.of(tester.element(find.byType(Navigator).last)).maybePop();
    await settle();
  }

  Future<void> closeMenu() async {
    await tester.tapAt(const Offset(2, 2));
    await pumpFrames(tester);
  }

  Future<void> dispose() async {
    DanaviewToast.dismiss();
    for (final c in tools.open) {
      if (!c.isCompleted) c.completeError(const PdfException(PdfErrorCode.cancelled, 'end'));
    }
    final g = compress.gate;
    if (g != null && !g.isCompleted) g.complete();
    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester, count: 6);
    container.dispose();
    await lib.close(tester);
    await env.dispose();
    await tester.runAsync(() async => tmp.deleteSync(recursive: true));
  }
}

Future<_App> _pumpApp(WidgetTester tester, double textScale, {bool outline = true}) async {
  FeatureFlags.debugFilesHomeOverride = true;
  addTearDown(FeatureFlags.debugReset);
  final env = await LibraryTestEnv.create();
  final lib = await FixtureLibrary.open(tester);
  final tmp = (await tester.runAsync(() async => Directory.systemTemp.createTempSync('s4q_matrix_')))!;
  final entries = <String, FileEntry>{};
  entries[_longPdf] = await lib.add(tester, _longPdf, meta: const EntryMeta(pageCount: _pages), bytes: 200000);
  lib.now = lib.now.add(const Duration(minutes: 1));
  entries[_otherPdf] = await lib.add(tester, _otherPdf, meta: const EntryMeta(pageCount: _pages), bytes: 200000);
  lib.now = lib.now.add(const Duration(minutes: 1));
  entries[_photo] = await lib.add(tester, _photo, bytes: 3000);
  final store = FileSignatureStore(Directory('${tmp.path}/signatures'));
  final annotate = _Annotate();
  final compress = _Compress();
  final tools = _Tools();
  final pdfs = _Pdfs(withOutline: outline);
  final runtime = (await tester.runAsync(() => filesHomeOverrides(
        prefs: env.prefs,
        // The Android runtime has no App Group inbox (no plugin in tests); the router takes the iOS
        // column (debugDefaultTargetPlatformOverride) and the native leaves are the fakes below.
        platform: TargetPlatform.android,
        directories: FilesHomeDirectories(support: tmp.path, cache: tmp.path),
        openStore: (_, __) async => lib.store,
        openThumbnails: (_) async => throw const FileSystemException('no thumbnails in tests'),
        observeLifecycle: false,
      )))!;
  final container = ProviderContainer(overrides: [
    ...env.overrides,
    ...runtime.overrides,
    pdfToolsEngineProvider.overrideWithValue(PdfToolsEngine(documents: pdfs, tools: tools, annotate: annotate)),
    signatureStoreProvider.overrideWithValue(store),
    signaturePhotoPickerProvider.overrideWithValue((_) async => _png),
    pdfCapabilitiesProvider.overrideWith((ref) async => pdfs.capabilities()),
    pdfCompressEngineProvider.overrideWithValue(compress),
    documentViewerSetupProvider.overrideWith((ref) => DocumentViewerSetup(
          viewers: {
            ViewerKind.pdf: pdfViewerBuilder(pdfs,
                viewBuilder: (context, doc, onCreated) => _FakePdfView(onCreated: onCreated), onCompress: pdfCompressLauncher(ref.read)),
          },
          probes: FunctionProbes({ViewerKind.pdf: pdfViewerProbe(pdfs)}),
        )),
  ]);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DanaviewApp()));
  await pumpFrames(tester);
  await tester.runAsync(() async {
    await container.read(pdfToolsSupportedProvider.future);
    await container.read(pdfCapabilitiesProvider.future);
  });
  await pumpFrames(tester);
  return _App(tester, env, container, lib, entries, tmp, annotate, compress, tools);
}

/// Visits every S4 surface; [check] runs on each.
Future<void> _visit(_App app, Future<void> Function(String where) check) async {
  final tester = app.tester;
  final narrow = tester.view.physicalSize.width / tester.view.devicePixelRatio < 360;

  // A PDF's file menu.
  await app.tab(HomeTab.documents);
  final row = find.byKey(ValueKey('library-entry-${app.entries[_longPdf]!.id.value}'));
  await app.reveal(row);
  await tester.tap(find.descendant(of: row, matching: find.byTooltip('More')));
  await pumpFrames(tester);
  await app.tapText('More actions…');
  for (final k in ['file-organise-pages', 'file-merge-with', 'file-compress-pdf', 'file-sign-pdf']) {
    expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
  }
  await check('PDF file menu (S4 entries)');
  await app.popTop();

  // The selection bar with Merge into PDF.
  final photo = app.lib.store.reader.entry(app.entries[_photo]!.id)!;
  final pdf = app.lib.store.reader.entry(app.entries[_otherPdf]!.id)!;
  app.container.read(homeSelectionProvider.notifier)
    ..select(mediaItemOfEntry(photo, app.lib.store.paths.entryFile(photo.id, photo.displayName)))
    ..select(mediaItemOfEntry(pdf, app.lib.store.paths.entryFile(pdf.id, pdf.displayName)));
  await app.settle();
  expect(find.byKey(const ValueKey('selection-action-file-merge-pdf')), findsOneWidget);
  await check('selection bar with Merge into PDF');
  app.container.read(homeSelectionProvider.notifier).clear();
  await app.settle();

  // The viewer.
  await app.tab(HomeTab.documents);
  await app.reveal(row);
  await app.tapFinder(row);
  await app.settle(frames: 12);
  expect(find.byType(PdfViewer), findsOneWidget);
  await check('PDF viewer with the S4 top bar');
  await app.tapTooltip('View options');
  await check('PDF viewer menu (Merge with…, Compress…${narrow ? ', Sign…' : ''})');
  await app.closeMenu();

  // Organise pages.
  await app.tapKey('pdf-viewer-organise');
  await app.settle(frames: 12);
  await check('organiser');
  await app.tapKey('pdf-organiser-page-1');
  await app.tapKey('pdf-organiser-page-3');
  await check('organiser with a selection');
  await app.tapKey('pdf-organiser-rotate');
  await app.tapKey('pdf-organiser-split');
  // Empty field: "Split" is disabled; its title and its button share the label, so the contrast
  // guideline measures the disabled button's text (inactive controls are exempt, WCAG 1.4.3).
  await check('split sheet (ranges) [disabled action]');
  await tester.enterText(find.byKey(const ValueKey('pdf-split-field')), '1-3, 4-12');
  await app.settle();
  await check('split sheet (ranges typed)');
  await app.tapKey('pdf-split-every');
  await check('split sheet (every N pages)');
  await app.popTop();
  await app.tapKey('pdf-organiser-save');
  await check('save choice sheet');
  await app.tapKey('pdf-save-new');
  for (var i = 0; i < 4 && find.byKey(const ValueKey('pdf-tool-cancel')).evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(pdfToolProgressDelay + const Duration(milliseconds: 50));
    await app.settle(frames: 12);
  }
  expect(find.byKey(const ValueKey('pdf-tool-cancel')), findsOneWidget, reason: 'the progress sheet');
  await check('tool progress sheet');
  await app.tapKey('pdf-tool-cancel');
  await app.settle(frames: 12);
  await app.tapTooltip('Back');
  await check('organiser discard prompt');
  await app.tapText('Discard');
  await app.settle();

  // Merge with….
  await app.tapTooltip('View options');
  await app.tapText('Merge with…');
  await app.settle(frames: 12);
  expect(find.byKey(const ValueKey('pdf-merge-picker-list')), findsOneWidget);
  await check('merge picker');
  await app.tapKey('pdf-merge-pick-0');
  await app.tapKey('pdf-merge-pick-1');
  await app.tapKey('pdf-merge-picker-add');
  await app.settle(frames: 12);
  expect(find.byKey(const ValueKey('pdf-merge-list')), findsOneWidget);
  await check('merge screen');
  await app.tapTooltip('Back');
  await app.settle();

  // Compress….
  Future<void> openCompress() async {
    await app.tapTooltip('View options');
    await app.tapText('Compress…');
    await app.settle(frames: 12);
  }

  await openCompress();
  expect(find.byKey(const ValueKey('compress-run')), findsOneWidget);
  await check('compress sheet');
  app.compress.gate = Completer<void>();
  await app.tapKey('compress-run');
  await check('compress progress');
  app.compress.gate!.complete();
  app.compress.gate = null;
  await app.settle(frames: 16);
  await app.settle(frames: 16);
  await check('compress done');
  await app.popTop();
  app.compress.result = 'larger';
  await openCompress();
  await app.tapKey('compress-run');
  await app.settle(frames: 16);
  expect(find.byKey(const ValueKey('compress-not-smaller')), findsOneWidget);
  await check('compress not smaller');
  app.compress.result = 'error';
  await app.tapKey('compress-again');
  await app.tapKey('compress-run');
  await app.settle(frames: 16);
  expect(find.byKey(const ValueKey('compress-error')), findsOneWidget);
  await check('compress error');
  app.compress.result = 'done';
  await app.popTop();

  // Annotate.
  await app.tapKey('pdf-viewer-annotate');
  await app.settle(frames: 12);
  expect(find.byKey(const ValueKey('pdf-annotate-toolbar')), findsOneWidget);
  await check('annotate: select tool with a text selection');
  await app.tapKey('pdf-annotate-highlight');
  for (final tool in ['pen', 'text', 'eraser']) {
    await app.tapKey('pdf-annotate-tool-$tool');
    await check('annotate: $tool tool');
  }
  await app.tapKey('pdf-annotate-tool-text');
  app.annotate.events_.add(const PdfAnnotateTapEvent(1, 0, Offset(100, 300), null));
  await app.settle(frames: 12);
  await check('annotate: text prompt');
  await tester.enterText(find.byType(EditableText).hitTestable().last, 'A note that is long enough to wrap on a phone screen');
  await app.tapText('Add');
  await app.settle(frames: 12);
  await check('annotate: a selected text box');
  await app.tapTooltip('Back');
  await check('annotate discard prompt');
  await app.tapText('Discard');
  await app.settle();

  // Sign (in the menu under 360 pt).
  if (narrow) {
    expect(find.byKey(const ValueKey('pdf-viewer-sign')), findsNothing);
    await app.tapTooltip('View options');
    await app.tapText('Sign…');
  } else {
    await app.tapKey('pdf-viewer-sign');
  }
  await app.settle(frames: 12);
  expect(find.byKey(const ValueKey('signature-pad')), findsOneWidget, reason: 'New signature opens with none saved');
  await check('New signature: Draw');
  await app.tapText('Type');
  await check('New signature: Type');
  await tester.enterText(find.byKey(const ValueKey('signature-type-name')), 'Alexandrina Montgomery-Featherstonehaugh');
  await app.settle();
  await app.tapText('Import');
  await check('New signature: Import');
  await app.tapKey('signature-import-pick');
  await app.settle(frames: 12);
  await check('New signature: Import with a photo');
  await app.tapKey('signature-create-cancel');
  await app.settle(frames: 12);
  // A saved signature (the sheet's PNG rendering needs a real engine; the store is the real one).
  final store = app.container.read(signatureStoreProvider)!;
  final saved = (await tester.runAsync(() => store.add(_png, kind: SignatureKind.drawn)))!;
  await app.waitFor(find.byKey(ValueKey('sign-signature-${saved.id}')));
  expect(find.byKey(const ValueKey('pdf-sign-toolbar')), findsOneWidget);
  await app.tapKey('sign-signature-${saved.id}');
  await check('sign toolbar with a saved signature');
  app.annotate.events_.add(const PdfAnnotateTapEvent(1, 0, Offset(200, 500), null));
  await app.settle(frames: 12);
  expect(app.annotate.shown, isNotEmpty, reason: 'a signature placed');
  final placed = app.annotate.shown.isEmpty ? null : app.annotate.shown.last.id;
  app.annotate.events_.add(PdfAnnotateTapEvent(1, 0, const Offset(210, 510), placed));
  await app.settle(frames: 12);
  await check('sign: a selected signature');
  await app.tapKey('sign-manage-signatures');
  await app.settle(frames: 12);
  await check('saved signatures sheet');
  await app.popTop();
  await app.tapTooltip('Back');
  await check('sign discard prompt');
  await app.tapText('Discard');
  await app.settle();
  await app.tapTooltip('Back');
  await app.settle();

  // Settings › Privacy.
  unawaited(GoRouter.of(appNavigatorKey.currentContext!).push('/settings'));
  await app.settle(frames: 12);
  final rowFinder = find.byKey(const ValueKey('privacy-saved-signatures'));
  await app.reveal(rowFinder);
  await app.settle(frames: 8);
  expect(rowFinder, findsOneWidget);
  await check('Settings › Privacy saved signatures');
  await app.popTop();
}

/// The texts on screen drawn with Flutter's fallback style (yellow double underline).
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

  group('S4 surfaces: no overflow', () {
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
          expect(spy.attempts, isEmpty, reason: 'no HttpClient in the S4 flows');
          debugDefaultTargetPlatformOverride = null;
        });
      }
    }
  });

  testWidgets('S4 surfaces: every text uses the kit text style (no fallback underline)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    useSurface(tester, const TestSurface(Size(375, 812), 1.0));
    final app = await _pumpApp(tester, 1.0, outline: false);
    final failures = <String>[];
    await _visit(app, (where) async {
      final bad = _fallbackTexts(tester);
      if (bad.isNotEmpty) failures.add('$where: ${bad.length} texts, e.g. "${bad.first.length > 40 ? bad.first.substring(0, 40) : bad.first}"');
    });
    await app.dispose();
    debugDefaultTargetPlatformOverride = null;
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, skip: _skipTextStyle);

  group('S4 surfaces: targets, labels and contrast', () {
    for (final (width, scale) in [(375.0, 1.0), (1280.0, 1.35)]) {
      testWidgets('${width.toInt()} px @${scale}x', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        useSurface(tester, TestSurface(Size(width, width > 1000 ? 800 : 812), scale));
        final app = await _pumpApp(tester, scale, outline: false);
        final failures = <String>[];
        await _visit(app, (where) async {
          expect(tester.takeException(), isNull, reason: where);
          for (final (name, g) in [
            ('44 pt targets', iOSTapTargetGuideline),
            ('labelled targets', labeledTapTargetGuideline),
            if (!where.endsWith('[disabled action]')) ('text contrast', textContrastGuideline),
          ]) {
            final r = await g.evaluate(tester);
            if (!r.passed) failures.add('$where — $name: ${(r.reason ?? '').split('\n').take(3).join(' / ')}');
          }
        });
        await app.dispose();
        debugDefaultTargetPlatformOverride = null;
        expect(failures, isEmpty, reason: failures.join('\n'));
      });
    }
  });
}
