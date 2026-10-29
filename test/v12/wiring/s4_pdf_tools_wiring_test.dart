// OWNER: HOM-28
//
// S4 wiring of the PDF page tools (BUILD_PLAN v1.2 §1A slice S4; lib/wiring/pdf_tools_wiring.dart)
// over an in-process fixture library and a fake danaview_pdf engine:
//
// * flag off: no override on any platform (no menu entry, no handler, no tool button);
// * flag on: the handlers exist only where the engine reports the tools (not on Windows and Linux,
//   not on Android before HOM-28A), the merge picker offers the library's PDFs and photos newest
//   first;
// * a PDF's file menu lists "Organise pages" and "Merge with…" and opens the organiser; the
//   multi-select "Merge into PDF" opens the merge screen with the selection in order; the
//   viewer scope wraps document viewers.

// The root package reaches the library through danaview_features in its fixtures.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:io';
import 'dart:typed_data';

import 'package:danaview/wiring/files_home_wiring.dart' show mediaItemOfEntry;
import 'package:danaview/wiring/pdf_tools_wiring.dart';
import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/file_actions/file_actions.dart';
import 'package:danaview_features/src/library/import/import_providers.dart' show importStagingDirectoryProvider;
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../filters/filters_support.dart';

/// A 1×1 white PNG.
final Uint8List _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, //
  0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F, //
  0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, //
  0x44, 0xAE, 0x42, 0x60, 0x82,
]);

const Set<PdfTool> _pageTools = {PdfTool.merge, PdfTool.split, PdfTool.reorder, PdfTool.rotate, PdfTool.deletePages};

final class _Docs implements PdfDocuments {
  @override
  Future<PdfCapabilities> capabilities() async => const PdfCapabilities(platformView: true, tools: _pageTools);

  @override
  Future<PdfProbe> probe(String path) async => const PdfProbe(canOpen: true, pageCount: 3);

  @override
  Future<PdfDocumentInfo> open(String path, {String? password}) async =>
      const PdfDocumentInfo(handle: 1, pageCount: 3, pageSizes: [PdfPageSize(612, 792), PdfPageSize(612, 792), PdfPageSize(612, 792)]);

  @override
  Future<PdfDocumentInfo?> unlock(int handle, String password) async => null;

  @override
  Future<List<PdfOutlineEntry>> outline(int handle) async => const [];

  @override
  Future<PdfPageImage> thumbnail(int handle, int pageIndex, {required int maxWidth, required int maxHeight}) async =>
      PdfPageImage(png: _png, width: 1, height: 1);

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

PdfToolsEngine _engine([Set<PdfTool> tools = _pageTools]) => PdfToolsEngine(documents: _Docs(), tools: _Tools(tools));

void main() {
  tearDown(FeatureFlags.debugReset);

  test('flag off: no override on any platform', () {
    FeatureFlags.debugFilesHomeOverride = false;
    expect(pdfToolsWired, isFalse);
    for (final platform in TargetPlatform.values) {
      expect(pdfToolsOverrides(platform: platform, engine: _engine()), isEmpty, reason: platform.name);
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
      staging = Directory.systemTemp.createTempSync('hom28_staging_');
      addTearDown(() async {
        await lib.close(tester);
        await env.dispose();
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      });
    }

    List<Override> overrides(TargetPlatform platform, {PdfToolsEngine? engine}) => [
          importStagingDirectoryProvider.overrideWithValue(staging.path),
          ...pdfToolsOverrides(platform: platform, engine: engine),
        ];

    Future<ProviderContainer> pumpHost(WidgetTester tester, List<Override> o, Widget Function(WidgetRef ref) body) async {
      late ProviderContainer container;
      await tester.pumpWidget(filtersApp(
        env,
        Consumer(builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return body(ref);
        }),
        lib: lib,
        overrides: o,
      ));
      await pumpFrames(tester);
      return container;
    }

    testWidgets('handlers exist only where the engine reports the tools', (tester) async {
      await setUpLibrary(tester);
      for (final (platform, engine, wired) in [
        (TargetPlatform.iOS, _engine(), true),
        (TargetPlatform.macOS, _engine(), true),
        (TargetPlatform.android, _engine(const {}), false), // HOM-28A not landed
        (TargetPlatform.windows, null, false),
        (TargetPlatform.linux, null, false),
      ]) {
        final container = await pumpHost(tester, overrides(platform, engine: engine), (ref) => const SizedBox());
        await tester.runAsync(() => container.read(pdfToolsSupportedProvider.future));
        await pumpFrames(tester, count: 2);
        expect(container.read(pdfPageToolsHandlerProvider) != null, wired, reason: platform.name);
        expect(container.read(mergeIntoPdfHandlerProvider) != null, wired, reason: platform.name);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('the merge picker offers the library PDFs and photos, newest first', (tester) async {
      await setUpLibrary(tester);
      final names = [for (final c in pdfMergeCandidates(lib.store)) c.displayName];
      expect(names, ['Report.pdf', 'Portrait.heic', 'Beach.jpg']);
      final report = pdfMergeCandidates(lib.store).first;
      expect(report.entryId, files['Report.pdf']!.id);
      expect(File(report.path).existsSync(), isTrue);
      expect(report.isImage, isFalse);
    });

    testWidgets('a PDF file menu lists Organise pages and Merge with…; Organise opens the organiser', (tester) async {
      await setUpLibrary(tester);
      final entry = files['Report.pdf']!;
      final item = mediaItemOfEntry(entry, lib.store.paths.entryFile(entry.id, entry.displayName));
      final container = await pumpHost(
        tester,
        overrides(TargetPlatform.iOS, engine: _engine()),
        (ref) => Builder(
          builder: (context) => TextButton(onPressed: () => showFileActionsMenu(context, ref, item), child: const Text('menu')),
        ),
      );
      await tester.runAsync(() => container.read(pdfToolsSupportedProvider.future));
      await pumpFrames(tester, count: 2);
      await tester.tap(find.text('menu'));
      await pumpFrames(tester);
      expect(find.text('Organise pages'), findsOneWidget);
      expect(find.text('Merge with…'), findsOneWidget);
      await tester.tap(find.text('Organise pages'));
      await pumpFrames(tester, count: 10);
      expect(find.text('Organise pages'), findsOneWidget, reason: 'the organiser title');
      expect(find.text('Report.pdf · 3 pages'), findsOneWidget);
    });

    testWidgets('Merge into PDF opens the merge screen with the selection in order', (tester) async {
      await setUpLibrary(tester);
      final beach = files['Beach.jpg']!;
      final report = files['Report.pdf']!;
      final items = [
        for (final e in [beach, report]) mediaItemOfEntry(e, lib.store.paths.entryFile(e.id, e.displayName)),
      ];
      final container = await pumpHost(
        tester,
        overrides(TargetPlatform.iOS, engine: _engine()),
        (ref) => Builder(
          builder: (context) => TextButton(onPressed: () => ref.read(mergeIntoPdfHandlerProvider)!(context, items), child: const Text('merge')),
        ),
      );
      await tester.runAsync(() => container.read(pdfToolsSupportedProvider.future));
      await pumpFrames(tester, count: 2);
      await tester.tap(find.text('merge'));
      await pumpFrames(tester, count: 6);
      expect(find.text('Merge into PDF'), findsOneWidget);
      expect(find.text('2 files'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Beach.jpg')).dy, lessThan(tester.getTopLeft(find.text('Report.pdf')).dy));
    });

    testWidgets('document viewers get the tools scope only when the tools are wired', (tester) async {
      await setUpLibrary(tester);
      final container = await pumpHost(tester, overrides(TargetPlatform.iOS, engine: _engine()), (ref) => const SizedBox());
      final wrapped = withPdfTools(container.read, const SizedBox());
      expect(wrapped, isA<PdfToolsScope>());
      FeatureFlags.debugFilesHomeOverride = false;
      expect(withPdfTools(container.read, const SizedBox()), isA<SizedBox>());
    });
  });
}
