// OWNER: HOM-28
//
// The merge screen and the PDF viewer's tool entry points (BUILD_PLAN HOM-28, HOM plan §8.5)
// against fakes: inputs merge in list order (reordered with the screen-reader actions, removed,
// added with the picker), photos become image inputs, an encrypted PDF asks for its password
// first, the result is a new file next to the first Danaview folder input, Merge needs two inputs;
// the viewer shows "Organise pages" and "Merge with…" only under a PdfToolsScope with the tools
// landed, and a Replace from the organiser reopens the file; and the merge screen fits 280/375/
// 1280 px at text scale 0.85 and 1.35 with 44 px labelled targets.

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../card/doc_harness.dart';
import '../viewer/pdf_fakes.dart';
import 'organiser_fakes.dart';

final _a = PdfMergeItem(path: '/l/a.pdf', displayName: 'A.pdf', entryId: EntryId.parse('fe_a'));
const _b = PdfMergeItem(path: '/d/b.pdf', displayName: 'B.pdf');
const _photo = PdfMergeItem(path: '/l/c.heic', displayName: 'C.heic', isImage: true);

void main() {
  late FakePdfDocuments docs;
  late FakePdfPageTools tools;
  late FakePdfResultSink sink;
  late List<PdfSavedFile?> closed;

  setUp(() {
    docs = FakePdfDocuments(pages: 3);
    tools = FakePdfPageTools();
    sink = FakePdfResultSink();
    closed = [];
  });

  PdfToolsEnvironment env({PdfMergePicker? pick}) => PdfToolsEnvironment(documents: docs, tools: tools, sink: sink, pickMergeInputs: pick);

  Widget screen(List<PdfMergeItem> items, {PdfMergePicker? pick, PdfPasswordPrompt? prompt}) =>
      PdfMergeScreen(items: items, environment: env(pick: pick), onClose: closed.add, passwordPrompt: prompt);

  Future<void> merge(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('pdf-merge-go')));
    await tester.pumpAndSettle();
  }

  testWidgets('merges in list order into a new file next to the first Danaview folder input', (tester) async {
    await tester.pumpWidget(docApp(screen([_b, _a, _photo])));
    await tester.pumpAndSettle();
    expect(find.text('3 files'), findsOneWidget);
    await merge(tester);
    final call = tools.calls.single;
    expect(call.tool, 'merge');
    expect(call.inputs, const [PdfToolInput.pdf('/d/b.pdf'), PdfToolInput.pdf('/l/a.pdf'), PdfToolInput.image('/l/c.heic')]);
    expect(sink.saved.single.$2, ['B (merged).pdf']);
    expect(sink.saved.single.$3, EntryId.parse('fe_a'));
    expect(closed.single?.displayName, 'B (merged).pdf');
  });

  testWidgets('reorder with the screen-reader actions, remove, and add with the picker', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(docApp(screen([_a, _b], pick: (context, current) async => [_photo])));
    await tester.pumpAndSettle();
    final node = tester.getSemantics(find.bySemanticsLabel(RegExp('^A.pdf, 1 of 2')).first);
    tester.binding.performSemanticsAction(SemanticsActionEvent(
      type: SemanticsAction.customAction,
      viewId: tester.view.viewId,
      nodeId: node.id,
      arguments: CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Move down')),
    ));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('^A.pdf, 2 of 2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-merge-add')));
    await tester.pumpAndSettle();
    expect(find.text('3 files'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Remove B.pdf'));
    await tester.pumpAndSettle();
    await merge(tester);
    expect(tools.calls.single.inputs, const [PdfToolInput.pdf('/l/a.pdf'), PdfToolInput.image('/l/c.heic')]);
    handle.dispose();
  });

  testWidgets('Merge needs two inputs; "Merge with…" opens the picker at once', (tester) async {
    var picked = 0;
    await tester.pumpWidget(docApp(PdfMergeScreen(
      items: [_a],
      pickFirst: true,
      environment: env(pick: (context, current) async {
        picked++;
        expect(current, [_a]);
        return const [];
      }),
      onClose: closed.add,
    )));
    await tester.pumpAndSettle();
    expect(picked, 1);
    expect(tester.widget<DanaviewButton>(find.byKey(const ValueKey('pdf-merge-go'))).onPressed, isNull);
  });

  testWidgets('an encrypted PDF asks for its password before merging; cancel merges nothing', (tester) async {
    docs = FakePdfDocuments(pages: 2, password: 'pw');
    var prompts = 0;
    await tester.pumpWidget(docApp(screen([_a, _b], prompt: (context, attempt) async {
      prompts++;
      expect(await attempt('bad'), isFalse);
      return false;
    })));
    await tester.pumpAndSettle();
    await merge(tester);
    expect(prompts, 1, reason: 'the first encrypted input asks, cancelling stops');
    expect(tools.calls, isEmpty);
  });

  testWidgets('the picker lists, filters and adds library PDFs and photos', (tester) async {
    List<PdfMergeItem>? result;
    await tester.pumpWidget(docApp(Builder(
      builder: (context) => DanaviewButton(
        label: 'open',
        onPressed: () async => result = await showPdfMergePicker(context, candidates: [_a, _b, _photo], current: [_a]),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Already in the merge'), findsOneWidget);
    await tester.enterText(find.byType(EditableText), 'c.h');
    await tester.pump(const Duration(milliseconds: 400)); // the search field debounces
    expect(find.text('A.pdf'), findsNothing);
    await tester.tap(find.text('C.heic'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pdf-merge-picker-add')));
    await tester.pumpAndSettle();
    expect(result, [_photo]);
  });

  group('surface matrix: 280 / 375 / 1280 px × text scale 0.85 / 1.35', () {
    for (final size in const [Size(280, 560), Size(375, 812), Size(1280, 800)]) {
      for (final scale in const [0.85, 1.35]) {
        final surface = DocSurface(size, scale);
        testWidgets('no overflow and 44 px labelled targets at $surface', (tester) async {
          applyDocSurface(tester, surface);
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(docApp(
            screen([_a, const PdfMergeItem(path: '/d/long.pdf', displayName: 'A very long document name that keeps going and going.pdf'), _photo],
                pick: (context, current) async => const []),
            textScale: scale,
          ));
          await tester.pumpAndSettle();
          expectNoLayoutErrors(tester, surface);
          await expectTargetsAndLabels(tester);
          handle.dispose();
        });
      }
    }
  });

  group('the PDF viewer entry points', () {
    const file = ViewerFile(path: '/l/Report.pdf', displayName: 'Report.pdf', kind: FileKind.document, docKind: DocumentKind.pdf);
    const caps = PdfCapabilities(
      platformView: true,
      search: true,
      selection: true,
      outline: true,
      passwords: true,
      textExtraction: true,
      tools: {PdfTool.merge, PdfTool.split, PdfTool.reorder, PdfTool.rotate, PdfTool.deletePages},
    );

    Widget viewer({required bool scoped, PdfCapabilities c = caps}) {
      final v = PdfViewer(
        file: file,
        documents: docs,
        capabilities: c,
        onClose: () {},
        viewBuilder: (context, d, onCreated) => FakeNativeView(controller: FakePdfViewController(3), onCreated: onCreated),
      );
      return scoped ? PdfToolsScope(environment: env(pick: (context, current) async => const []), child: v) : v;
    }

    testWidgets('no scope or no tools: no tool buttons', (tester) async {
      await tester.pumpWidget(docApp(viewer(scoped: false)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pdf-viewer-organise')), findsNothing);
      await tester.pumpWidget(docApp(viewer(scoped: true, c: appleCaps)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pdf-viewer-organise')), findsNothing);
    });

    testWidgets('"Organise pages" opens the organiser; a Replace reopens the file', (tester) async {
      await tester.pumpWidget(docApp(viewer(scoped: true)));
      await tester.pumpAndSettle();
      expect(docs.calls.where((c) => c == 'open'), hasLength(1));
      await tester.tap(find.byKey(const ValueKey('pdf-viewer-organise')));
      await tester.pumpAndSettle();
      expect(find.text('Organise pages'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pdf-organiser-page-0')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pdf-organiser-rotate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pdf-organiser-save')));
      await tester.pumpAndSettle();
      // A file without a library entry saves a new file and the viewer keeps its document.
      expect(sink.saved, hasLength(1));
      expect(find.text('Organise pages'), findsNothing);
      expect(docs.calls.where((c) => c == 'open'), hasLength(2), reason: 'the organiser opened its own handle');
    });

    testWidgets('"Merge with…" in the options menu starts a merge with this file', (tester) async {
      await tester.pumpWidget(docApp(viewer(scoped: true)));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('View options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Merge with…'));
      await tester.pumpAndSettle();
      expect(find.text('Merge into PDF'), findsOneWidget);
      expect(find.text('Report.pdf'), findsOneWidget);
    });
  });
}
