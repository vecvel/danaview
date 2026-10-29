// OWNER: HOM-29
//
// S4 wiring of annotate (BUILD_PLAN v1.2 §1A slice S4; lib/wiring/pdf_tools_wiring.dart) over an
// in-process fixture library and fake danaview_pdf engines:
//
// * flag off: no override, so no viewer tool scope and no "Annotate";
// * flag on: the native engine carries danaview_pdf's annotate engine on iOS, macOS and Android, and
//   the environment hands it to the viewer, which shows "Annotate" only where the platform reports
//   the tool (not on Android before HOM-29A; Windows and Linux have no engine at all);
// * an annotated Danaview folder PDF is saved through the real library sink as a NEW file
//   "Report (annotated).pdf" next to the original, whose bytes stay the same.

// The root package reaches the library through danaview_features in its fixtures.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview/wiring/documents_wiring.dart' show viewerFileOfEntry;
import 'package:danaview/wiring/pdf_tools_wiring.dart';
import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_features/src/flags.dart';
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
  PdfToolJob _never() => PdfToolJobHandle.failed('x', const PdfException(PdfErrorCode.notSupportedOnDevice, 'fake'));

  @override
  Future<Set<PdfTool>> supported() async => const {};

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

/// Writes a stand-in file for every save; strokes are sent by the test.
final class _Annotate implements PdfAnnotateEngine {
  final StreamController<PdfAnnotateEvent> events_ = StreamController<PdfAnnotateEvent>.broadcast();
  final List<String> written = [];

  @override
  Future<void> setMode(int viewId, PdfAnnotateMode? mode) async {}

  @override
  Future<void> show(int viewId, List<PdfAnnotateItem> items, {String? selectedId}) async {}

  @override
  Future<List<PdfPageRects>> selectionLines(int viewId) async => const [];

  @override
  Stream<PdfAnnotateEvent> events(int viewId) => events_.stream;

  @override
  PdfToolJob save(PdfToolInput input, {required List<PdfAnnotation> annotations, List<PdfStamp> stamps = const [], bool burnIn = false, required String outPath}) {
    File(outPath).writeAsBytesSync(Uint8List(900));
    written.add(outPath);
    return PdfToolJobHandle(
      id: 'a${written.length}',
      run: Future.value(PdfToolResult(outPaths: [outPath], pageCounts: const [1], sizesBytes: const [900])),
      onCancel: () async {},
    );
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

  test('flag off: no override, so no tools scope', () {
    FeatureFlags.debugFilesHomeOverride = false;
    for (final platform in TargetPlatform.values) {
      expect(pdfToolsOverrides(platform: platform), isEmpty, reason: platform.name);
    }
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
      staging = Directory.systemTemp.createTempSync('hom29_staging_');
      addTearDown(() async {
        await lib.close(tester);
        await env.dispose();
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      });
    }

    testWidgets('the native engine carries annotate on iOS, macOS and Android; none on Windows and Linux', (tester) async {
      await setUpLibrary(tester);
      for (final platform in TargetPlatform.values) {
        final container = ProviderContainer(overrides: pdfToolsOverrides(platform: platform));
        addTearDown(container.dispose);
        final engine = container.read(pdfToolsEngineProvider);
        final native = platform == TargetPlatform.iOS || platform == TargetPlatform.macOS || platform == TargetPlatform.android;
        expect(engine != null, native, reason: platform.name);
        if (native) expect(engine!.annotate, isA<PlatformPdfAnnotateEngine>(), reason: platform.name);
      }
    });

    Future<void> pumpViewer(WidgetTester tester, {required Set<PdfTool> tools, required _Annotate annotate, required ViewerFile file}) async {
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
        overrides: [
          importStagingDirectoryProvider.overrideWithValue(staging.path),
          ...pdfToolsOverrides(platform: TargetPlatform.iOS, engine: PdfToolsEngine(documents: docs, tools: _Tools(), annotate: annotate)),
        ],
      ));
      await pumpFrames(tester, count: 8);
    }

    testWidgets('"Annotate" shows only where the platform reports the tool', (tester) async {
      await setUpLibrary(tester);
      final entry = files['Report.pdf']!;
      final file = viewerFileOfEntry(entry, lib.store.paths.entryFile(entry.id, entry.displayName));
      await pumpViewer(tester, tools: const {PdfTool.annotate}, annotate: _Annotate(), file: file);
      expect(find.byKey(const ValueKey('pdf-viewer-annotate')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await pumpViewer(tester, tools: const {}, annotate: _Annotate(), file: file);
      expect(find.byKey(const ValueKey('pdf-viewer-annotate')), findsNothing, reason: 'Android before HOM-29A reports no annotate');
    });

    testWidgets('an annotated Danaview folder PDF is saved as a new file next to the original', (tester) async {
      await setUpLibrary(tester);
      final entry = files['Report.pdf']!;
      final path = lib.store.paths.entryFile(entry.id, entry.displayName);
      final before = File(path).readAsBytesSync();
      final annotate = _Annotate();
      await pumpViewer(tester, tools: const {PdfTool.annotate}, annotate: annotate, file: viewerFileOfEntry(entry, path));
      await tester.tap(find.byKey(const ValueKey('pdf-viewer-annotate')));
      await pumpFrames(tester);
      expect(find.byKey(const ValueKey('pdf-annotate-toolbar')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pdf-annotate-tool-pen')));
      await pumpFrames(tester);
      annotate.events_.add(const PdfInkStrokeEvent(4, 0, [Offset(10, 10), Offset(50, 80)]));
      await pumpFrames(tester);
      expect(tester.widget<DanaviewButton>(find.byKey(const ValueKey('pdf-annotate-save'))).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('pdf-annotate-save')));
      // The save does real file IO (staging, import): let it run between frames.
      for (var i = 0; i < 20 && lib.store.reader.allEntries().every((e) => e.displayName != 'Report (annotated).pdf'); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(annotate.written, hasLength(1));
      final saved = lib.store.reader.allEntries().where((e) => e.displayName == 'Report (annotated).pdf').toList();
      expect(saved, hasLength(1));
      expect(saved.single.folderId, entry.folderId, reason: 'next to the original');
      expect(File(lib.store.paths.entryFile(saved.single.id, saved.single.displayName)).lengthSync(), 900);
      expect(File(path).readAsBytesSync(), before, reason: 'the original is never modified');
      expect(File(annotate.written.single).existsSync(), isFalse, reason: 'the staged file was imported');
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
