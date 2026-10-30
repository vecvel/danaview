// OWNER: S4-W
//
// The S4 gate's root wiring test (BUILD_PLAN v1.2 §1A S4-W; the slice's share of INT-103): every
// S4 entry point, reached through the app root's own composition (`filesHomeOverrides` →
// `documentsOverrides` → `pdfToolsOverrides`), is present with DANAVIEW_FILES_HOME on exactly where
// the platform reports its tool, and absent with the flag off. Only the platform leaves are fakes
// (the danaview_pdf engines, the saved-signature store, the PDF view); the rest is the app's.
//
// Surfaces: the PDF viewer's Organise pages, Annotate, Sign (top bar) and Merge with…, Compress…
// (menu); a PDF's file menu Organise pages, Merge with…, Compress…, Sign…; the multi-select bar's
// Merge into PDF; Settings › Privacy's saved signatures.
//
// Capability sets: iOS and macOS (PDFKit: every tool); Android as merged today (HOM-28A page tools
// and HOM-31A compress; annotate and sign not yet reported); Android once HOM-29A / HOM-30A report
// annotate and sign; Windows and Linux (no danaview_pdf: nothing, PDFs go to the file card).
//
// Run plain (the flag-off group runs, the flag-on group overrides the flag) and with
// `--dart-define=DANAVIEW_FILES_HOME=true`.

// The root package reaches the library through danaview_features in its fixtures.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:danaview/wiring/documents_wiring.dart';
import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview/wiring/pdf_tools_wiring.dart';
import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_features/danaview_features.dart' show SettingsSections;
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/file_actions/file_actions.dart';
import 'package:danaview_features/src/library/home/home_callbacks.dart' show HomeCallbacks;
import 'package:danaview_features/src/library/selection/selection_actions.dart';
import 'package:danaview_features/src/library/selection/selection_bar.dart' show mediaSelectionGroup;
import 'package:danaview_features/src/library/selection/selection_model.dart' show HomeSelection;
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../library_test_utils.dart';
import '../filters/filters_support.dart';

// ---------------------------------------------------------------------------------------------
// Capability sets.
// ---------------------------------------------------------------------------------------------

const Set<PdfTool> _pageTools = {PdfTool.merge, PdfTool.split, PdfTool.reorder, PdfTool.rotate, PdfTool.deletePages};

/// iOS and macOS: PDFKit reports every S4 tool.
const Set<PdfTool> _apple = {..._pageTools, PdfTool.annotate, PdfTool.sign, PdfTool.compress};

/// Android today: HOM-28A (`PdfPageTools.supported`) and HOM-31A (`PdfCompressor.supported`);
/// `PdfAnnotator.supported` and `PdfSigner.supported` are still empty.
const Set<PdfTool> _androidNow = {..._pageTools, PdfTool.compress};

/// Android once HOM-29A and HOM-30A report their tools.
const Set<PdfTool> _androidLater = {..._androidNow, PdfTool.annotate, PdfTool.sign};

/// What each case expects to see.
final class _Case {
  const _Case(this.name, this.platform, this.tools);

  final String name;
  final TargetPlatform platform;

  /// The tools the platform reports; null: no danaview_pdf on this platform.
  final Set<PdfTool>? tools;

  bool has(PdfTool t) => tools?.contains(t) ?? false;
  bool get organise => tools != null && canOrganise(tools!);
  bool get merge => has(PdfTool.merge);
  bool get annotate => has(PdfTool.annotate);
  bool get sign => has(PdfTool.sign) && annotate;
  bool get compress => has(PdfTool.compress);
}

const List<_Case> _cases = [
  _Case('iOS', TargetPlatform.iOS, _apple),
  _Case('macOS', TargetPlatform.macOS, _apple),
  _Case('Android (HOM-28A, HOM-31A)', TargetPlatform.android, _androidNow),
  _Case('Android (+ HOM-29A, HOM-30A)', TargetPlatform.android, _androidLater),
  _Case('Windows', TargetPlatform.windows, null),
  _Case('Linux', TargetPlatform.linux, null),
];

// ---------------------------------------------------------------------------------------------
// Platform fakes (only the leaves: engines, store, native view).
// ---------------------------------------------------------------------------------------------

final class _Docs implements PdfDocuments {
  _Docs(this.tools);

  final Set<PdfTool> tools;

  @override
  Future<PdfCapabilities> capabilities() async => PdfCapabilities(platformView: true, selection: true, tools: tools);

  @override
  Future<PdfProbe> probe(String path) async => const PdfProbe(canOpen: true, pageCount: 1);

  @override
  Future<PdfDocumentInfo> open(String path, {String? password}) async => const PdfDocumentInfo(handle: 1, pageCount: 1, pageSizes: [PdfPageSize(612, 792)]);

  @override
  Future<PdfDocumentInfo?> unlock(int handle, String password) async => null;

  @override
  Future<List<PdfOutlineEntry>> outline(int handle) async => const [];

  @override
  Future<PdfPageImage> thumbnail(int handle, int pageIndex, {required int maxWidth, required int maxHeight}) async =>
      throw const PdfException(PdfErrorCode.notSupportedOnDevice, 'fake');

  @override
  Future<void> close(int handle) async {}
}

final class _Tools implements PdfPageTools {
  _Tools(this.tools);

  final Set<PdfTool> tools;

  @override
  Future<Set<PdfTool>> supported() async => tools;

  @override
  dynamic noSuchMethod(Invocation invocation) => PdfToolJobHandle.failed('x', const PdfException(PdfErrorCode.notSupportedOnDevice, 'fake'));
}

final class _Annotate implements PdfAnnotateEngine {
  @override
  Stream<PdfAnnotateEvent> events(int viewId) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

final class _Compress implements PdfCompressEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Store extends SignatureStore {
  @override
  Future<List<SavedSignature>> list() async => [
        SavedSignature(id: 'sig-1-drawn', path: '/support/signatures/sig-1-drawn.png', kind: SignatureKind.drawn, createdAt: DateTime.utc(2026, 10, 30), width: 300, height: 100),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _View implements PdfViewController {
  @override
  int get viewId => 7;

  @override
  Stream<PdfViewState> get states => const Stream.empty();

  @override
  Future<PdfViewState> state() async => const PdfViewState(viewId: 7, pageIndex: 0, pageCount: 1);

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

Widget _fakeView(BuildContext context, PdfDocumentInfo document, ValueChanged<PdfViewController> onCreated) {
  scheduleMicrotask(() => onCreated(_View()));
  return const ColoredBox(color: Color(0xFF808080));
}

/// The leaves of [c]'s platform replaced by fakes, only where the app root put a real one.
List<Override> _fakeLeaves(_Case c, {required bool engine, required bool compress, required bool store}) {
  final tools = c.tools ?? const <PdfTool>{};
  final docs = _Docs(tools);
  return [
    if (engine) pdfToolsEngineProvider.overrideWithValue(PdfToolsEngine(documents: docs, tools: _Tools(tools), annotate: _Annotate())),
    if (compress) ...[
      pdfCapabilitiesProvider.overrideWith((ref) async => docs.capabilities()),
      pdfCompressEngineProvider.overrideWithValue(_Compress()),
    ],
    if (store) signatureStoreProvider.overrideWithValue(_Store()),
    documentViewerSetupProvider.overrideWith((ref) => documentViewerSetupFor(
          c.platform,
          pdf: c.tools == null ? null : docs,
          compress: pdfCompressLauncher(ref.read),
          pdfView: _fakeView,
        )),
  ];
}

List<String> _menuLabels(WidgetTester tester) => [
      for (final e in tester.widget<ViewerOptionsButton>(find.byType(ViewerOptionsButton)).entries)
        if (e is DanaviewMenuItem) e.label,
    ];

void main() {
  tearDown(FeatureFlags.debugReset);

  group('flag off', () {
    setUp(() => FeatureFlags.debugFilesHomeOverride = false);

    test('the app root adds no S4 override on any platform', () async {
      for (final platform in TargetPlatform.values) {
        expect(documentsOverrides(platform: platform, support: '/support', excludeStagingFromBackup: false), isEmpty, reason: platform.name);
        expect(pdfToolsOverrides(platform: platform, support: '/support'), isEmpty, reason: platform.name);
      }
      SharedPreferences.setMockInitialValues({});
      final runtime = await filesHomeOverrides(prefs: await SharedPreferences.getInstance(), platform: TargetPlatform.iOS, observeLifecycle: false);
      expect(runtime.overrides, isEmpty);
      const base = SettingsSections();
      expect(identical(appSettingsSectionsFor(base), base), isTrue, reason: 'no saved-signature rows');
    });

    test('every S4 entry point is absent', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(pdfToolsEngineProvider), isNull);
      expect(container.read(pdfCompressEngineProvider), isNull);
      expect(container.read(signatureStoreProvider), isNull);
      expect(container.read(pdfToolsEnvironmentProvider), isNull);
      expect(container.read(pdfPageToolsHandlerProvider), isNull, reason: 'file menu Organise pages / Merge with…');
      expect(container.read(compressPdfHandlerProvider), isNull, reason: 'file menu Compress…');
      expect(container.read(signPdfHandlerProvider), isNull, reason: 'file menu Sign…');
      expect(container.read(mergeIntoPdfHandlerProvider), isNull, reason: 'multi-select Merge into PDF');
      expect(container.read(selectionActionGroupsProvider), [mediaSelectionGroup]);
      const viewer = SizedBox();
      expect(identical(withPdfTools(container.read, viewer), viewer), isTrue, reason: 'no tools scope around the viewer');
      expect(identical(withPdfTools(container.read, viewer, startWith: PdfViewerStartTool.sign), viewer), isTrue);
    });
  });

  group('flag on', () {
    for (final c in _cases) {
      testWidgets('${c.name}: the S4 entry points follow the reported tools', (tester) async {
        FeatureFlags.debugFilesHomeOverride = true;
        final env = await LibraryTestEnv.create();
        final lib = await FixtureLibrary.open(tester);
        final files = await lib.seedFixture(tester);
        final dirs = Directory.systemTemp.createTempSync('s4w_dirs_');
        addTearDown(() async {
          await lib.close(tester);
          await env.dispose();
          if (dirs.existsSync()) dirs.deleteSync(recursive: true);
        });

        // The app root's own composition for this platform.
        final runtime = (await tester.runAsync(() => filesHomeOverrides(
              prefs: env.prefs,
              platform: c.platform,
              directories: FilesHomeDirectories(support: dirs.path, cache: dirs.path),
              openStore: (_, __) async => lib.store,
              openThumbnails: (_) async => throw const FileSystemException('no thumbnails in tests'),
              observeLifecycle: false,
            )))!;
        final real = ProviderContainer(overrides: [...env.overrides, ...runtime.overrides]);
        final native = c.tools != null;
        final hasEngine = real.read(pdfToolsEngineProvider) != null;
        final hasCompress = real.read(pdfCompressEngineProvider) != null;
        final realStore = real.read(signatureStoreProvider);
        real.dispose();
        expect(hasEngine, native, reason: 'danaview_pdf engine on iOS, macOS and Android only');
        expect(hasCompress, native);
        expect(realStore != null, native, reason: 'saved signatures where signing can run');
        if (realStore is FileSignatureStore) {
          expect(realStore.directory.path, '${dirs.path}${Platform.pathSeparator}signatures', reason: 'app-private, beside the library');
        }

        late ProviderContainer container;
        late BuildContext hostContext;
        late WidgetRef hostRef;
        await tester.pumpWidget(filtersApp(
          env,
          Consumer(builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            hostContext = context;
            hostRef = ref;
            return SingleChildScrollView(child: appSettingsSectionsFor(const SettingsSections()).privacy!(context));
          }),
          lib: lib,
          overrides: [
            ...runtime.overrides,
            ..._fakeLeaves(c, engine: hasEngine, compress: hasCompress, store: realStore != null),
          ],
        ));
        await tester.runAsync(() async {
          await container.read(pdfToolsSupportedProvider.future);
          await container.read(pdfCapabilitiesProvider.future);
        });
        await pumpFrames(tester, count: 4);

        // Settings › Privacy: saved signatures.
        expect(find.byKey(const ValueKey('settings-saved-signatures')), c.sign ? findsOneWidget : findsNothing, reason: 'Settings rows');

        // Handlers behind the file menu and the selection bar.
        expect(container.read(pdfPageToolsHandlerProvider) != null, c.organise && c.merge, reason: 'Organise pages / Merge with…');
        expect(container.read(compressPdfHandlerProvider) != null, c.compress, reason: 'Compress…');
        expect(container.read(signPdfHandlerProvider) != null, c.sign, reason: 'Sign…');
        expect(container.read(mergeIntoPdfHandlerProvider) != null, c.merge, reason: 'Merge into PDF');

        // The multi-select bar: Merge into PDF for a PDF and a photo.
        final pdf = files['Report.pdf']!;
        final photo = files['Beach.jpg']!;
        final pdfItem = mediaItemOfEntry(pdf, lib.store.paths.entryFile(pdf.id, pdf.displayName));
        final photoItem = mediaItemOfEntry(photo, lib.store.paths.entryFile(photo.id, photo.displayName));
        final selection = SelectionActionContext(selection: HomeSelection.of([pdfItem, photoItem]), callbacks: const HomeCallbacks(), platform: c.platform);
        final barActions = [
          for (final builder in container.read(selectionActionGroupsProvider))
            if (builder(selection) case final g?) ...g.actions.map((a) => a.id),
        ];
        expect(barActions.contains(fileActionId(FileAction.mergeIntoPdf)), c.merge, reason: 'selection bar Merge into PDF');
        expect(barActions, contains(fileActionId(FileAction.delete)), reason: 'the file group itself is there');

        // A PDF's file menu.
        unawaited(showFileActionsMenu(hostContext, hostRef, pdfItem));
        await pumpFrames(tester, count: 4);
        expect(find.byKey(ValueKey(fileActionId(FileAction.organisePages))), c.organise && c.merge ? findsOneWidget : findsNothing, reason: 'file menu');
        expect(find.byKey(ValueKey(fileActionId(FileAction.mergeWith))), c.organise && c.merge ? findsOneWidget : findsNothing, reason: 'file menu');
        expect(find.byKey(ValueKey(fileActionId(FileAction.compressPdf))), c.compress ? findsOneWidget : findsNothing, reason: 'file menu');
        expect(find.byKey(ValueKey(fileActionId(FileAction.signPdf))), c.sign ? findsOneWidget : findsNothing, reason: 'file menu');
        Navigator.of(hostContext).pop();
        await pumpFrames(tester, count: 4);

        // The PDF viewer.
        unawaited(openDocumentViewer(hostContext, container.read, viewerFileOfEntry(pdf, lib.store.paths.entryFile(pdf.id, pdf.displayName))));
        await pumpFrames(tester, count: 8);
        expect(find.byType(PdfViewer), native ? findsOneWidget : findsNothing, reason: 'no PDF viewer on Windows and Linux');
        expect(find.byType(PdfToolsScope), native ? findsOneWidget : findsNothing, reason: 'the tools scope wraps the viewer where the tools run');
        if (native) {
          expect(find.byKey(const ValueKey('pdf-viewer-organise')), c.organise ? findsOneWidget : findsNothing, reason: 'viewer Organise pages');
          expect(find.byKey(const ValueKey('pdf-viewer-annotate')), c.annotate ? findsOneWidget : findsNothing, reason: 'viewer Annotate');
          expect(find.byKey(const ValueKey('pdf-viewer-sign')), c.sign ? findsOneWidget : findsNothing, reason: 'viewer Sign');
          final menu = _menuLabels(tester);
          expect(menu.contains('Merge with…'), c.merge, reason: 'viewer menu');
          expect(menu.contains('Compress…'), c.compress, reason: 'viewer menu');
        } else {
          expect(find.byType(FileCard), findsOneWidget, reason: 'a PDF gets the file card');
        }
        expect(tester.takeException(), isNull);
      });
    }
  });
}
