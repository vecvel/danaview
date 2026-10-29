// OWNER: HOM-30
//
// S4 wiring of sign (BUILD_PLAN v1.2 §1A slice S4; lib/wiring/pdf_tools_wiring.dart and the
// Settings › Privacy rows in lib/wiring/files_home_wiring.dart) over an in-process fixture library
// and fake danaview_pdf engines:
//
// * flag off: no override and Settings unchanged;
// * flag on: the saved signatures live app-private in `<app support>/signatures` (beside the
//   library root, never in it) on iOS, macOS and Android, none on Windows and Linux or without the
//   support folder; the file menu's "Sign…" handler and the viewer's "Sign" appear only where the
//   platform reports the sign tool; Settings › Privacy lists the saved signatures there;
// * a signed Danaview folder PDF is burned in by the engine and saved through the real library sink
//   as a NEW file "Report (signed).pdf" next to the original, whose bytes stay the same.

// The root package reaches the library through danaview_features in its fixtures.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview/wiring/documents_wiring.dart' show viewerFileOfEntry;
import 'package:danaview/wiring/files_home_wiring.dart' show appSettingsSectionsFor;
import 'package:danaview/wiring/pdf_tools_wiring.dart';
import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_features/danaview_features.dart' show SettingsSections;
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/file_actions/file_actions.dart' show SignPdfHandler, signPdfHandlerProvider;
import 'package:danaview_features/src/library/import/import_providers.dart' show importStagingDirectoryProvider;
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../filters/filters_support.dart';

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

  PdfToolJob _never() => PdfToolJobHandle.failed('x', const PdfException(PdfErrorCode.notSupportedOnDevice, 'fake'));

  @override
  Future<Set<PdfTool>> supported() async => tools;

  @override
  PdfToolJob merge(List<PdfToolInput> inputs, {required String outPath}) => _never();

  @override
  PdfToolJob split(PdfToolInput input, List<PdfPageRange> ranges, {required List<String> outPaths}) => _never();

  @override
  PdfToolJob reorder(PdfToolInput input, List<int> order, {required String outPath}) => _never();

  @override
  PdfToolJob rotate(PdfToolInput input, List<int> pages, {int degrees = 90, required String outPath}) => _never();

  @override
  PdfToolJob deletePages(PdfToolInput input, List<int> pages, {required String outPath}) => _never();

  @override
  PdfToolJob organise(PdfToolInput input, List<PdfPagePlan> plan, {required String outPath}) => _never();
}

/// Writes a stand-in file for every save and records what it was asked; taps are sent by the test.
final class _Engine implements PdfAnnotateEngine {
  final StreamController<PdfAnnotateEvent> events_ = StreamController<PdfAnnotateEvent>.broadcast();
  final List<(List<PdfStamp>, bool, String)> saves = [];
  PdfAnnotateMode? mode;

  @override
  Future<void> setMode(int viewId, PdfAnnotateMode? mode) async => this.mode = mode;

  @override
  Future<void> show(int viewId, List<PdfAnnotateItem> items, {String? selectedId}) async {}

  @override
  Future<List<PdfPageRects>> selectionLines(int viewId) async => const [];

  @override
  Stream<PdfAnnotateEvent> events(int viewId) => events_.stream;

  @override
  PdfToolJob save(PdfToolInput input, {required List<PdfAnnotation> annotations, List<PdfStamp> stamps = const [], bool burnIn = false, required String outPath}) {
    File(outPath).writeAsBytesSync(Uint8List(700));
    saves.add((stamps, burnIn, outPath));
    return PdfToolJobHandle(
      id: 's${saves.length}',
      run: Future.value(PdfToolResult(outPaths: [outPath], pageCounts: const [1], sizesBytes: const [700])),
      onCancel: () async {},
    );
  }
}

/// One saved signature, in memory (the file store's IO is covered by danaview_documents' tests).
final class _Store extends SignatureStore {
  final List<SavedSignature> items = [
    SavedSignature(id: 'sig-1-drawn', path: '/support/signatures/sig-1-drawn.png', kind: SignatureKind.drawn, createdAt: DateTime.utc(2026, 10, 30), width: 300, height: 100),
  ];

  @override
  Future<List<SavedSignature>> list() async => List.of(items);

  @override
  Future<SavedSignature> add(Uint8List png, {required SignatureKind kind}) => throw UnimplementedError();

  @override
  Future<void> delete(String id) async {
    items.removeWhere((s) => s.id == id);
    notifyListeners();
  }

  @override
  Future<void> deleteAll() async {
    items.clear();
    notifyListeners();
  }
}

final class _View implements PdfViewController {
  @override
  int get viewId => 4;

  @override
  Stream<PdfViewState> get states => const Stream.empty();

  @override
  Future<PdfViewState> state() async => const PdfViewState(viewId: 4, pageIndex: 0, pageCount: 1);

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  tearDown(FeatureFlags.debugReset);

  test('flag off: no override and the Settings sections stay as given', () {
    FeatureFlags.debugFilesHomeOverride = false;
    for (final platform in TargetPlatform.values) {
      expect(pdfToolsOverrides(platform: platform, support: '/support'), isEmpty, reason: platform.name);
    }
    const base = SettingsSections();
    expect(identical(appSettingsSectionsFor(base), base), isTrue);
  });

  test('flag on: the signatures folder is app-private on iOS, macOS and Android only', () {
    FeatureFlags.debugFilesHomeOverride = true;
    final support = Directory.systemTemp.createTempSync('hom30_support_');
    addTearDown(() => support.deleteSync(recursive: true));
    for (final platform in TargetPlatform.values) {
      final container = ProviderContainer(overrides: pdfToolsOverrides(platform: platform, support: support.path));
      addTearDown(container.dispose);
      final store = container.read(signatureStoreProvider);
      final native = platform == TargetPlatform.iOS || platform == TargetPlatform.macOS || platform == TargetPlatform.android;
      expect(store != null, native, reason: platform.name);
      if (store is FileSignatureStore) {
        expect(store.directory.path, '${support.path}${Platform.pathSeparator}signatures');
        for (final style in LibraryRootStyle.values) {
          final root = libraryRootIn(support.path, style);
          expect(store.directory.path.startsWith('$root${Platform.pathSeparator}'), isFalse, reason: 'never inside the Danaview folders');
        }
      }
    }
    final without = ProviderContainer(overrides: pdfToolsOverrides(platform: TargetPlatform.iOS));
    addTearDown(without.dispose);
    expect(without.read(signatureStoreProvider), isNull, reason: 'no support folder, no store');
    expect(pdfSignatureFonts.map((f) => f.family), ['Caveat', 'Pacifico', 'Playfair Display'], reason: 'OFL fonts the app already bundles');
    expect(pdfSignatureFonts.every((f) => f.package == 'danaview_editor_fonts'), isTrue);
  });

  group('flag on', () {
    late LibraryTestEnv env;
    late FixtureLibrary lib;
    late Map<String, FileEntry> files;
    late Directory staging;

    Future<void> setUpLibrary(WidgetTester tester) async {
      FeatureFlags.debugFilesHomeOverride = true;
      env = await LibraryTestEnv.create();
      lib = await FixtureLibrary.open(tester);
      files = await lib.seedFixture(tester);
      staging = Directory.systemTemp.createTempSync('hom30_staging_');
      addTearDown(() async {
        await lib.close(tester);
        await env.dispose();
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      });
    }

    List<Override> overrides(Set<PdfTool> tools, _Engine engine, _Store store, _Docs docs) => [
          importStagingDirectoryProvider.overrideWithValue(staging.path),
          ...pdfToolsOverrides(
            platform: TargetPlatform.iOS,
            engine: PdfToolsEngine(documents: docs, tools: _Tools(tools), annotate: engine),
            signatures: store,
          ),
        ];

    Future<void> pumpViewer(WidgetTester tester, {required Set<PdfTool> tools, required _Engine engine, required _Store store, required ViewerFile file}) async {
      final docs = _Docs(tools);
      await tester.pumpWidget(filtersApp(
        env,
        Consumer(
          builder: (context, ref, _) => withPdfTools(
            ref.read,
            PdfViewer(
              file: file,
              documents: docs,
              onClose: () {},
              chooseSaveMode: (context, name) async => PdfSaveMode.newFile,
              viewBuilder: (context, d, onCreated) {
                scheduleMicrotask(() => onCreated(_View()));
                return const ColoredBox(color: Color(0xFF808080));
              },
            ),
          ),
        ),
        lib: lib,
        overrides: overrides(tools, engine, store, docs),
      ));
      await pumpFrames(tester, count: 8);
    }

    testWidgets('"Sign", "Sign…" and the Settings rows appear only where the platform reports the tool', (tester) async {
      await setUpLibrary(tester);
      final entry = files['Report.pdf']!;
      final file = viewerFileOfEntry(entry, lib.store.paths.entryFile(entry.id, entry.displayName));
      const sign = {PdfTool.annotate, PdfTool.sign};
      for (final (tools, shown) in [(sign, true), (const {PdfTool.annotate}, false)]) {
        await tester.pumpWidget(const SizedBox());
        await pumpViewer(tester, tools: tools, engine: _Engine(), store: _Store(), file: file);
        expect(find.byKey(const ValueKey('pdf-viewer-sign')), shown ? findsOneWidget : findsNothing, reason: '$tools');

        final settings = appSettingsSectionsFor(const SettingsSections());
        SignPdfHandler? handler;
        await tester.pumpWidget(filtersApp(
          env,
          Consumer(builder: (context, ref, _) {
            handler = ref.watch(signPdfHandlerProvider);
            return SingleChildScrollView(child: settings.privacy!(context));
          }),
          lib: lib,
          overrides: overrides(tools, _Engine(), _Store(), _Docs(tools)),
        ));
        await pumpFrames(tester, count: 8);
        expect(handler != null, shown, reason: 'the file menu’s Sign… with $tools');
        expect(find.byKey(const ValueKey('settings-saved-signatures')), shown ? findsOneWidget : findsNothing, reason: '$tools');
        if (shown) expect(find.text('1 saved on this device'), findsOneWidget);
      }
    });

    testWidgets('a signed Danaview folder PDF is saved as a new file next to the original', (tester) async {
      await setUpLibrary(tester);
      final entry = files['Report.pdf']!;
      final path = lib.store.paths.entryFile(entry.id, entry.displayName);
      final before = File(path).readAsBytesSync();
      final engine = _Engine();
      final store = _Store();
      await pumpViewer(tester, tools: const {PdfTool.annotate, PdfTool.sign}, engine: engine, store: store, file: viewerFileOfEntry(entry, path));
      await tester.tap(find.byKey(const ValueKey('pdf-viewer-sign')));
      await pumpFrames(tester);
      expect(find.byKey(const ValueKey('pdf-sign-toolbar')), findsOneWidget);
      expect(engine.mode?.input, PdfAnnotateInput.place);
      engine.events_.add(const PdfAnnotateTapEvent(4, 0, Offset(300, 200), null));
      await pumpFrames(tester);
      expect(tester.widget<DanaviewButton>(find.byKey(const ValueKey('pdf-sign-save'))).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('pdf-sign-save')));
      for (var i = 0; i < 20 && lib.store.reader.allEntries().every((e) => e.displayName != 'Report (signed).pdf'); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final (stamps, burnIn, out) = engine.saves.single;
      expect(burnIn, isTrue);
      expect(stamps.single.imagePath, store.items.single.path);
      final saved = lib.store.reader.allEntries().where((e) => e.displayName == 'Report (signed).pdf').toList();
      expect(saved, hasLength(1));
      expect(saved.single.folderId, entry.folderId, reason: 'next to the original');
      expect(File(lib.store.paths.entryFile(saved.single.id, saved.single.displayName)).lengthSync(), 700);
      expect(File(path).readAsBytesSync(), before, reason: 'the original is never modified');
      expect(File(out).existsSync(), isFalse, reason: 'the staged file was imported');
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
