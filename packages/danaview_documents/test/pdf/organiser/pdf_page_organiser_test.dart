// OWNER: HOM-28
//
// The page organiser (BUILD_PLAN HOM-28, HOM plan §8.5) against fakes of the documents, the page
// tools and the result sink: the thumbnail grid with selection, rotate, delete (never the last
// page), drag to reorder (pointer drag and touch long-press drag) and the screen-reader move
// actions; Save writes one organise plan and saves a NEW file next to the original, with Replace
// offered only for Danaview folder files; Extract and Split save new files (Split of unsaved
// changes splits a staged organised copy); a long job shows progress and Cancel leaves nothing
// saved; errors become toasts; closing with changes asks first; a password file is unlocked once
// and the tools get its password; and the organiser fits 280/375/1280 px at text scale 0.85 and
// 1.35 with 44 px labelled targets.

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../card/doc_harness.dart';
import '../viewer/pdf_fakes.dart';
import 'organiser_fakes.dart';

const _linked = ViewerFile(path: '/docs/Report.pdf', displayName: 'Report.pdf', kind: FileKind.document, docKind: DocumentKind.pdf);
final _entry = ViewerFile(
  path: '/library/files/fe_report/Report.pdf',
  displayName: 'Report.pdf',
  kind: FileKind.document,
  docKind: DocumentKind.pdf,
  id: EntryId.parse('fe_report'),
);

Finder _page(int sourcePage) => find.byKey(ValueKey('pdf-organiser-page-$sourcePage'));
Finder _tool(String key) => find.byKey(ValueKey('pdf-organiser-$key'));

/// Whether the toolbar or top-bar control [f] is enabled (a labelled button on wide windows, a
/// compact glyph-and-label button on narrow ones).
bool _enabled(WidgetTester tester, Finder f) => switch (tester.widget(f)) {
      final DanaviewButton b => b.onPressed != null,
      final DanaviewPressable p => p.onTap != null,
      final w => throw StateError('unexpected ${w.runtimeType}'),
    };

void main() {
  late FakePdfDocuments docs;
  late FakePdfPageTools tools;
  late FakePdfResultSink sink;
  late List<PdfSavedFile?> closed;

  setUp(() {
    docs = FakePdfDocuments(pages: 6);
    tools = FakePdfPageTools();
    sink = FakePdfResultSink();
    closed = [];
  });

  PdfToolsEnvironment env() => PdfToolsEnvironment(documents: docs, tools: tools, sink: sink);

  Widget organiser(ViewerFile file, {Future<PdfSaveMode?> Function(BuildContext, String)? choose, PdfPasswordPrompt? prompt}) => PdfPageOrganiser(
        file: file,
        environment: env(),
        onClose: closed.add,
        chooseSaveMode: choose,
        passwordPrompt: prompt,
      );

  Future<void> open(WidgetTester tester, Widget w, {TargetPlatform platform = TargetPlatform.iOS, double textScale = 1}) async {
    await tester.pumpWidget(docApp(w, platform: platform, textScale: textScale));
    await tester.pumpAndSettle();
  }

  Future<void> tapTool(WidgetTester tester, String key) async {
    await tester.tap(_tool(key));
    await tester.pumpAndSettle();
  }

  Future<void> tapPage(WidgetTester tester, int sourcePage) async {
    await tester.tap(_page(sourcePage));
    await tester.pump();
  }

  bool saveEnabled(WidgetTester tester) => _enabled(tester, _tool('save'));

  testWidgets('shows every page as a thumbnail and nothing to save yet; closes its handle', (tester) async {
    await open(tester, organiser(_linked));
    expect(find.text('Organise pages'), findsOneWidget);
    expect(find.text('Report.pdf · 6 pages'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      expect(_page(i), findsOneWidget);
    }
    expect(docs.calls, contains('thumbnail:0'));
    expect(saveEnabled(tester), isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(docs.closed, [7]);
  });

  testWidgets('select, rotate and delete; the last page can never be deleted', (tester) async {
    await open(tester, organiser(_linked));
    await tapPage(tester, 1);
    await tapPage(tester, 3);
    await tester.pump();
    expect(find.text('2 of 6 selected'), findsOneWidget);
    await tapTool(tester, 'rotate');
    await tapTool(tester, 'delete');
    expect(_page(1), findsNothing);
    expect(_page(3), findsNothing);
    expect(find.text('Report.pdf · 4 pages'), findsOneWidget);
    expect(saveEnabled(tester), isTrue);

    await tapTool(tester, 'select-all');
    expect(find.text('4 of 4 selected'), findsOneWidget);
    expect(_enabled(tester, _tool('delete')), isFalse, reason: 'one page must remain');
  });

  testWidgets('Save writes one organise plan and saves a new file for a linked file (no Replace)', (tester) async {
    await open(tester, organiser(_linked, choose: (_, __) async => fail('no Replace for a linked file')));
    await tapPage(tester, 0);
    await tapTool(tester, 'rotate');
    await tapTool(tester, 'select-all'); // select all
    await tapTool(tester, 'select-all'); // select none
    await tapPage(tester, 5);
    await tapTool(tester, 'delete');
    await tapTool(tester, 'save');

    final call = tools.calls.single;
    expect(call.tool, 'organise');
    expect(call.inputs.single, const PdfToolInput.pdf('/docs/Report.pdf'));
    expect(call.plan, const [PdfPagePlan(0, rotation: 90), PdfPagePlan(1), PdfPagePlan(2), PdfPagePlan(3), PdfPagePlan(4)]);
    expect(call.outPaths.single, startsWith('/staging/'));
    expect(sink.saved.single.$1, call.outPaths);
    expect(sink.saved.single.$2, ['Report (edited).pdf']);
    expect(sink.saved.single.$3, isNull, reason: 'a linked file is saved into Imported');
    expect(sink.replaced, isEmpty);
    expect(closed.single?.displayName, 'Report (edited).pdf');
  });

  testWidgets('a Danaview folder file offers Replace; both choices save where they should', (tester) async {
    await open(tester, organiser(_entry));
    await tapPage(tester, 2);
    await tapTool(tester, 'rotate');
    await tapTool(tester, 'save');
    expect(find.text('Save as a new file'), findsOneWidget);
    expect(find.text('Replace the original'), findsOneWidget);
    expect(find.text('Report (edited).pdf'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-save-replace')));
    await tester.pumpAndSettle();
    expect(sink.replaced.single.$1, EntryId.parse('fe_report'));
    expect(sink.replaced.single.$2, tools.calls.single.outPaths.single);
    expect(sink.replaced.single.$3, 3, reason: 'the page count of the written file');
    expect(sink.saved, isEmpty);
    expect(closed.single?.replaced, isTrue);

    closed.clear();
    await tester.pumpWidget(const SizedBox());
    await open(tester, organiser(_entry));
    await tapPage(tester, 2);
    await tapTool(tester, 'rotate');
    await tapTool(tester, 'save');
    await tester.tap(find.byKey(const ValueKey('pdf-save-new')));
    await tester.pumpAndSettle();
    expect(sink.saved.single.$3, EntryId.parse('fe_report'), reason: 'next to the original');
  });

  testWidgets('dismissing the save sheet writes nothing', (tester) async {
    await open(tester, organiser(_entry, choose: (_, __) async => null));
    await tapPage(tester, 2);
    await tapTool(tester, 'rotate');
    await tapTool(tester, 'save');
    expect(tools.calls, isEmpty);
    expect(closed, isEmpty);
  });

  testWidgets('drag a page onto another reorders (pointer drag)', (tester) async {
    await open(tester, organiser(_linked), platform: TargetPlatform.macOS);
    final from = tester.getCenter(_page(0));
    final to = tester.getCenter(_page(2));
    final gesture = await tester.startGesture(from);
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await tapTool(tester, 'save');
    expect(tools.calls.single.plan.map((p) => p.sourcePage).toList(), [1, 2, 0, 3, 4, 5]);
  });

  testWidgets('drag after a long press on touch reorders; a tap only selects', (tester) async {
    await open(tester, organiser(_linked));
    final gesture = await tester.startGesture(tester.getCenter(_page(3)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(_page(0)));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    await tapPage(tester, 5);
    await tester.pump();
    expect(find.text('1 of 6 selected'), findsOneWidget);
    await tapTool(tester, 'save');
    expect(tools.calls.single.plan.map((p) => p.sourcePage).toList(), [3, 0, 1, 2, 4, 5]);
  });

  testWidgets('screen readers move and rotate pages with custom actions', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, organiser(_linked));
    SemanticsNode node(String label) => tester.getSemantics(find.bySemanticsLabel(RegExp('^$label')).first);
    void perform(String label, String action) {
      final id = CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: action));
      tester.binding.performSemanticsAction(
        SemanticsActionEvent(type: SemanticsAction.customAction, viewId: tester.view.viewId, nodeId: node(label).id, arguments: id),
      );
    }

    expect(node('Page 1 of 6').getSemanticsData().customSemanticsActionIds, isNotEmpty);
    perform('Page 1 of 6', 'Move later');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('Page 2 of 6, originally page 1')), findsOneWidget);
    perform('Page 2 of 6', 'Rotate');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('turned 90 degrees')), findsOneWidget);
    await tapTool(tester, 'save');
    expect(tools.calls.single.plan.take(2), const [PdfPagePlan(1), PdfPagePlan(0, rotation: 90)]);
    handle.dispose();
  });

  testWidgets('Extract saves the selected pages, in grid order, as a new file', (tester) async {
    await open(tester, organiser(_entry));
    await tapPage(tester, 4);
    await tapPage(tester, 0);
    await tapPage(tester, 1);
    // Toasts run one animation for their whole life: pump, don't settle, to see them.
    await tester.tap(_tool('extract'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final call = tools.calls.single;
    expect(call.plan, const [PdfPagePlan(0), PdfPagePlan(1), PdfPagePlan(4)]);
    expect(sink.saved.single.$2, ['Report (pages 1–2, 5).pdf']);
    expect(sink.saved.single.$3, EntryId.parse('fe_report'));
    expect(find.text('Saved as Report (pages 1–2, 5).pdf'), findsOneWidget);
    expect(closed, isEmpty, reason: 'the organiser stays open');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Split by ranges and every N pages; unsaved changes are split from a staged copy', (tester) async {
    await open(tester, organiser(_linked));
    await tapTool(tester, 'split');
    await tester.enterText(find.byType(EditableText), '1-2, 3-6');
    await tester.pump();
    expect(find.text('Makes 2 new files'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-split-go')));
    await tester.pumpAndSettle();
    var call = tools.calls.single;
    expect(call.tool, 'split');
    expect(call.inputs.single.path, '/docs/Report.pdf');
    expect(call.ranges, const [PdfPageRange(0, 2), PdfPageRange(2, 6)]);
    expect(sink.saved.single.$2, ['Report (pages 1–2).pdf', 'Report (pages 3–6).pdf']);

    tools.calls.clear();
    await tapPage(tester, 0);
    await tapTool(tester, 'delete');
    await tapTool(tester, 'split');
    await tester.tap(find.byKey(const ValueKey('pdf-split-every')));
    await tester.pumpAndSettle();
    expect(find.text('Makes 2 new files'), findsOneWidget, reason: '5 pages, 3 per file by default');
    await tester.tap(find.byKey(const ValueKey('pdf-split-go')));
    await tester.pumpAndSettle();
    expect(tools.calls.map((c) => c.tool), ['organise', 'split']);
    call = tools.calls.last;
    expect(call.inputs.single.path, tools.calls.first.outPaths.single, reason: 'the staged organised copy');
    expect(call.ranges, const [PdfPageRange(0, 3), PdfPageRange(3, 5)]);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the Split sheet rejects bad ranges and the whole file', (tester) async {
    await open(tester, organiser(_linked));
    await tapTool(tester, 'split');
    final go = find.byKey(const ValueKey('pdf-split-go'));
    await tester.enterText(find.byType(EditableText), '4-9');
    await tester.pump();
    expect(find.text('Use pages 1 to 6, like 1-3, 5'), findsOneWidget);
    expect(tester.widget<DanaviewButton>(go).onPressed, isNull);
    await tester.enterText(find.byType(EditableText), '1-6');
    await tester.pump();
    expect(find.text('That’s the whole file'), findsOneWidget);
    expect(tester.widget<DanaviewButton>(go).onPressed, isNull);
  });

  testWidgets('a long job shows progress; Cancel stops it and saves nothing', (tester) async {
    tools.hold = true;
    await open(tester, organiser(_linked));
    await tapPage(tester, 0);
    await tapTool(tester, 'rotate');
    await tester.tap(_tool('save'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Saving pages'), findsOneWidget);
    tools.held.single.report(const PdfToolProgress(fraction: 0.5, pagesDone: 3, pagesTotal: 6));
    await tester.pump();
    expect(find.text('3 of 6 pages'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-tool-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Saving pages'), findsNothing);
    expect(sink.saved, isEmpty);
    expect(closed, isEmpty);
    expect(saveEnabled(tester), isTrue, reason: 'the changes are still there');
  });

  testWidgets('a failed tool says why in a toast', (tester) async {
    tools.failWith = const PdfException(PdfErrorCode.unsupported, 'x');
    await open(tester, organiser(_linked));
    await tapPage(tester, 0);
    await tapTool(tester, 'rotate');
    await tester.tap(_tool('save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('This PDF doesn’t allow changing its pages.'), findsOneWidget);
    expect(sink.saved, isEmpty);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('closing with changes asks before discarding them', (tester) async {
    await open(tester, organiser(_linked));
    await tapPage(tester, 0);
    await tapTool(tester, 'rotate');
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed, isEmpty);
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(closed, [null]);
  });

  testWidgets('a password file is unlocked once and the tools get its password', (tester) async {
    docs = FakePdfDocuments(pages: 3, password: 'pw');
    await open(tester, organiser(_linked, prompt: (context, attempt) async => attempt('pw')));
    expect(_page(0), findsOneWidget);
    await tapPage(tester, 0);
    await tapTool(tester, 'rotate');
    await tapTool(tester, 'save');
    expect(tools.calls.single.inputs.single.password, 'pw');
  });

  testWidgets('a file that can’t be opened shows a calm empty state', (tester) async {
    docs = FakePdfDocuments(openError: const PdfException(PdfErrorCode.damaged, 'x'));
    await open(tester, organiser(_linked));
    expect(find.text('Can’t open this PDF'), findsOneWidget);
  });

  group('surface matrix: 280 / 375 / 1280 px × text scale 0.85 / 1.35', () {
    for (final size in const [Size(280, 560), Size(375, 812), Size(1280, 800)]) {
      for (final scale in const [0.85, 1.35]) {
        final surface = DocSurface(size, scale);
        testWidgets('no overflow and 44 px labelled targets at $surface', (tester) async {
          applyDocSurface(tester, surface);
          docs = FakePdfDocuments(pages: 24);
          final handle = tester.ensureSemantics();
          await open(tester, organiser(_entry), textScale: scale);
          expectNoLayoutErrors(tester, '$surface open');
          await expectTargetsAndLabels(tester);
          await tapPage(tester, 1);
          await tapTool(tester, 'rotate');
          expectNoLayoutErrors(tester, '$surface selected');
          await expectTargetsAndLabels(tester);
          await tapTool(tester, 'split');
          expectNoLayoutErrors(tester, '$surface split sheet');
          await tester.tap(find.byKey(const ValueKey('pdf-split-every')));
          await tester.pumpAndSettle();
          expectNoLayoutErrors(tester, '$surface split every');
          handle.dispose();
        });
      }
    }
  });
}
