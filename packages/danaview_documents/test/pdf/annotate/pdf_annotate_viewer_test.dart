// OWNER: HOM-29
//
// Annotate mode in the PDF viewer (BUILD_PLAN HOM-29, HOM plan §8.5) against fakes of the
// documents, the native view, the annotate engine and the result sink: "Annotate" shows only with
// an engine and the reported tool; the mode swaps the top bar (undo, redo, Save) and adds the
// toolbar under the same native view; tools map to the viewer's modes; ink strokes, taps (select,
// text boxes, eraser) and the text selection's markup become marks with undo / redo; Save writes
// "<name> (annotated).pdf" as a new file (Replace only for Danaview folder files, which reopens the
// file) with the unlock password; Cancel and errors leave the session as it was; leaving with
// unsaved marks asks first (the bar's close, the viewer's back, the system back); and the mode
// fits 280/375/1280 px at text scale 0.85 and 1.35 with 44 px labelled targets.


import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../card/doc_harness.dart';
import '../organiser/organiser_fakes.dart';
import '../viewer/pdf_fakes.dart';
import 'annotate_fakes.dart';

const _linked = ViewerFile(path: '/docs/Report.pdf', displayName: 'Report.pdf', kind: FileKind.document, docKind: DocumentKind.pdf);
final _entry = ViewerFile(
  path: '/library/files/fe_report/Report.pdf',
  displayName: 'Report.pdf',
  kind: FileKind.document,
  docKind: DocumentKind.pdf,
  id: EntryId.parse('fe_report'),
);

const _annotateCaps = PdfCapabilities(
  platformView: true,
  search: true,
  selection: true,
  outline: true,
  passwords: true,
  textExtraction: true,
  tools: {PdfTool.annotate},
);

Finder _key(String key) => find.byKey(ValueKey(key));

bool _enabled(WidgetTester tester, Finder f) => switch (tester.widget(f)) {
      final DanaviewButton b => b.onPressed != null,
      final DanaviewIconButton b => b.onPressed != null,
      final PdfAnnotateToolCapsule c => c.onTap != null,
      final w => throw StateError('unexpected ${w.runtimeType}'),
    };

void main() {
  late FakePdfDocuments docs;
  late FakePdfAnnotateEngine engine;
  late FakePdfResultSink sink;
  FakePdfViewController? current;
  FakePdfViewController view() => current!;
  late List<String?> prompts;
  late List<String?> answers;
  late int closed;

  setUp(() {
    docs = FakePdfDocuments(pages: 4, caps: _annotateCaps);
    engine = FakePdfAnnotateEngine();
    sink = FakePdfResultSink();
    prompts = [];
    answers = [];
    closed = 0;
  });

  Widget viewer(ViewerFile file, {PdfAnnotateEngine? annotate, Future<PdfSaveMode?> Function(BuildContext, String)? choose, PdfPasswordPrompt? prompt}) {
    final env = PdfToolsEnvironment(documents: docs, tools: FakePdfPageTools(tools: const {}), sink: sink, annotate: annotate);
    return PdfToolsScope(
      environment: env,
      child: PdfViewer(
        file: file,
        documents: docs,
        onClose: () => closed++,
        passwordPrompt: prompt,
        chooseSaveMode: choose,
        annotateTextPrompt: (context, initial) async {
          prompts.add(initial);
          return answers.isEmpty ? null : answers.removeAt(0);
        },
        viewBuilder: (context, d, onCreated) => FakeNativeView(controller: current ??= FakePdfViewController(d.pageCount), onCreated: onCreated),
      ),
    );
  }

  Future<void> open(WidgetTester tester, Widget w, {double textScale = 1}) async {
    current = null;
    await tester.pumpWidget(docApp(w, textScale: textScale));
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester) async {
    await tester.tap(_key('pdf-viewer-annotate'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(_key(key));
    await tester.pumpAndSettle();
  }

  /// Taps [key] and pumps without settling, so a toast is still on screen.
  Future<void> tapForToast(WidgetTester tester, String key) async {
    await tester.tap(_key(key));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Lets a toast run out.
  Future<void> toastGone(WidgetTester tester) => tester.pump(const Duration(seconds: 3));

  Future<void> emit(WidgetTester tester, PdfAnnotateEvent e) async {
    engine.emit(e);
    await tester.pumpAndSettle();
  }

  const stroke = PdfInkStrokeEvent(1, 0, [Offset(10, 10), Offset(40, 60)]);

  testWidgets('"Annotate" shows only with an engine and the reported tool', (tester) async {
    await open(tester, viewer(_linked, annotate: engine));
    expect(_key('pdf-viewer-annotate'), findsOneWidget);

    await open(tester, KeyedSubtree(key: UniqueKey(), child: viewer(_linked)));
    expect(_key('pdf-viewer-annotate'), findsNothing, reason: 'no engine');

    docs = FakePdfDocuments(pages: 4, caps: appleCaps);
    await open(tester, KeyedSubtree(key: UniqueKey(), child: viewer(_linked, annotate: engine)));
    expect(_key('pdf-viewer-annotate'), findsNothing, reason: 'the platform does not report annotate (Android before HOM-29A)');
  });

  testWidgets('the mode swaps the bar, keeps the native view and maps tools to viewer modes', (tester) async {
    await open(tester, viewer(_linked, annotate: engine));
    final native = tester.element(find.byKey(const ValueKey('fake-native-pdf')));
    await enter(tester);
    expect(find.text('Annotate'), findsOneWidget);
    expect(_key('pdf-annotate-toolbar'), findsOneWidget);
    expect(identical(tester.element(find.byKey(const ValueKey('fake-native-pdf'))), native), isTrue, reason: 'the same native view');
    expect(engine.modes.single, (1, const PdfAnnotateMode(input: PdfAnnotateInput.select, inkColorArgb: 0xFFE53935, inkWidth: 3)));
    expect(_enabled(tester, _key('pdf-annotate-save')), isFalse);
    expect(_enabled(tester, _key('pdf-annotate-undo')), isFalse);

    await tap(tester, 'pdf-annotate-tool-pen');
    expect(engine.mode?.input, PdfAnnotateInput.ink);
    await tap(tester, 'pdf-annotate-pen-color-ff1e6fe5');
    await tap(tester, 'pdf-annotate-width-2');
    expect(engine.mode, const PdfAnnotateMode(input: PdfAnnotateInput.ink, inkColorArgb: 0xFF1E6FE5, inkWidth: 6));
    await tap(tester, 'pdf-annotate-tool-text');
    expect(engine.mode?.input, PdfAnnotateInput.text);
    await tap(tester, 'pdf-annotate-tool-eraser');
    expect(engine.mode?.input, PdfAnnotateInput.erase);
    expect(find.text('Tap a mark to remove it'), findsOneWidget);

    // Leaving without marks asks nothing and ends the viewer's mode.
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Discard annotations?'), findsNothing);
    expect(find.byKey(const ValueKey('pdf-annotate-toolbar')), findsNothing);
    expect(engine.mode, isNull);
    expect(_key('pdf-annotate-toolbar'), findsNothing);
    expect(_key('pdf-viewer-annotate'), findsOneWidget);
    expect(closed, 0);
  });

  testWidgets('ink strokes become marks with undo and redo; the preview follows', (tester) async {
    await open(tester, viewer(_linked, annotate: engine));
    await enter(tester);
    await emit(tester, stroke);
    expect(engine.preview, isEmpty, reason: 'strokes count only with the pen');
    await tap(tester, 'pdf-annotate-tool-pen');
    await emit(tester, stroke);
    await emit(tester, const PdfInkStrokeEvent(2, 0, [Offset(1, 1)]));
    expect(engine.preview, hasLength(1), reason: 'another viewer’s strokes are ignored');
    final ink = engine.preview.single.annotation!;
    expect(ink.kind, PdfAnnotationKind.ink);
    expect(ink.strokes.single, const [Offset(10, 10), Offset(40, 60)]);
    expect(ink.colorArgb, 0xFFE53935);
    expect(ink.lineWidth, 3);
    expect(_enabled(tester, _key('pdf-annotate-save')), isTrue);

    await tap(tester, 'pdf-annotate-undo');
    expect(engine.preview, isEmpty);
    expect(_enabled(tester, _key('pdf-annotate-save')), isFalse);
    await tap(tester, 'pdf-annotate-redo');
    expect(engine.preview, hasLength(1));
  });

  testWidgets('the text selection is highlighted, underlined or struck through in the markup colour', (tester) async {
    await open(tester, viewer(_linked, annotate: engine));
    await enter(tester);
    expect(_enabled(tester, _key('pdf-annotate-highlight')), isFalse, reason: 'nothing selected');
    expect(find.text('Select text to mark it'), findsOneWidget);
    view().select('TOKEN-1');
    await tester.pumpAndSettle();
    engine.selection = const [
      PdfPageRects(0, [PdfRect(72, 700, 120, 18), PdfRect(72, 680, 80, 18)]),
      PdfPageRects(1, [PdfRect(72, 760, 50, 18)]),
    ];
    await tap(tester, 'pdf-annotate-markup-color-ff34c759');
    await tap(tester, 'pdf-annotate-highlight');
    expect(engine.preview.map((i) => (i.annotation!.kind, i.annotation!.pageIndex, i.annotation!.rects.length, i.annotation!.colorArgb)), [
      (PdfAnnotationKind.highlight, 0, 2, 0xFF34C759),
      (PdfAnnotationKind.highlight, 1, 1, 0xFF34C759),
    ]);
    expect(view().selection, isNull, reason: 'the selection is cleared after marking');
    // Both pages' marks were one step.
    await tap(tester, 'pdf-annotate-undo');
    expect(engine.preview, isEmpty);

    view().select('TOKEN-1');
    await tester.pumpAndSettle();
    await tap(tester, 'pdf-annotate-underline');
    view().select('TOKEN-1');
    await tester.pumpAndSettle();
    await tap(tester, 'pdf-annotate-strike');
    expect(engine.preview.map((i) => i.annotation!.kind),
        [PdfAnnotationKind.underline, PdfAnnotationKind.underline, PdfAnnotationKind.strikeOut, PdfAnnotationKind.strikeOut]);

    // A selection the platform can't measure marks nothing.
    engine.selection = const [];
    view().select('TOKEN-1');
    await tester.pumpAndSettle();
    await tapForToast(tester, 'pdf-annotate-highlight');
    expect(find.text('Select some text first.'), findsOneWidget);
    expect(engine.preview, hasLength(4));
    await toastGone(tester);
  });

  testWidgets('text boxes: a tap places one, a tap on one edits it, an emptied one goes', (tester) async {
    await open(tester, viewer(_linked, annotate: engine));
    await enter(tester);
    await tap(tester, 'pdf-annotate-tool-text');
    await tap(tester, 'pdf-annotate-text-color-ff1e6fe5');
    answers = ['Check this'];
    await emit(tester, const PdfAnnotateTapEvent(1, 2, Offset(500, 700), null));
    expect(prompts, [null]);
    final box = engine.preview.single;
    expect(box.annotation!.kind, PdfAnnotationKind.freeText);
    expect(box.annotation!.text, 'Check this');
    expect(box.annotation!.pageIndex, 2);
    expect(box.annotation!.colorArgb, 0xFF1E6FE5);
    expect(box.annotation!.rects.single.x, 500);
    expect(box.annotation!.rects.single.width, 104, reason: 'fitted to the 612 pt page');
    expect(engine.previewSelected, box.id);

    answers = ['Checked'];
    await emit(tester, PdfAnnotateTapEvent(1, 2, const Offset(510, 690), box.id));
    expect(prompts, [null, 'Check this']);
    expect(engine.preview.single.annotation!.text, 'Checked');

    // The toolbar's Edit text does the same; an empty answer removes the box.
    answers = [''];
    await tap(tester, 'pdf-annotate-edit');
    expect(engine.preview, isEmpty);

    // A cancelled prompt adds nothing.
    await emit(tester, const PdfAnnotateTapEvent(1, 0, Offset(10, 10), null));
    expect(engine.preview, isEmpty);
  });

  testWidgets('select a mark and delete it; the eraser removes what it taps', (tester) async {
    await open(tester, viewer(_linked, annotate: engine));
    await enter(tester);
    await tap(tester, 'pdf-annotate-tool-pen');
    await emit(tester, stroke);
    await emit(tester, stroke);
    final [first, second] = [for (final i in engine.preview) i.id];
    await tap(tester, 'pdf-annotate-tool-select');
    await emit(tester, PdfAnnotateTapEvent(1, 0, const Offset(10, 10), first));
    expect(engine.previewSelected, first);
    expect(_key('pdf-annotate-delete'), findsOneWidget);
    expect(_key('pdf-annotate-edit'), findsNothing, reason: 'only text boxes are edited');
    await tap(tester, 'pdf-annotate-delete');
    expect([for (final i in engine.preview) i.id], [second]);
    expect(_key('pdf-annotate-delete'), findsNothing);
    // A tap on nothing deselects.
    await emit(tester, PdfAnnotateTapEvent(1, 0, const Offset(10, 10), second));
    await emit(tester, const PdfAnnotateTapEvent(1, 0, Offset(300, 300), null));
    expect(engine.previewSelected, isNull);

    await tap(tester, 'pdf-annotate-tool-eraser');
    await emit(tester, const PdfAnnotateTapEvent(1, 0, Offset(300, 300), null));
    expect(engine.preview, hasLength(1));
    await emit(tester, PdfAnnotateTapEvent(1, 0, const Offset(10, 10), second));
    expect(engine.preview, isEmpty);
    await tap(tester, 'pdf-annotate-undo');
    expect([for (final i in engine.preview) i.id], [second]);
  });

  testWidgets('Save writes "<name> (annotated).pdf" as a new file with the password, then leaves the mode', (tester) async {
    docs = FakePdfDocuments(pages: 4, caps: _annotateCaps, password: 'secret');
    var asked = 0;
    await open(
      tester,
      viewer(_linked, annotate: engine, prompt: (context, attempt) => attempt('secret'), choose: (context, name) async {
        asked++;
        return PdfSaveMode.newFile;
      }),
    );
    await enter(tester);
    await tap(tester, 'pdf-annotate-tool-pen');
    await emit(tester, stroke);
    await tapForToast(tester, 'pdf-annotate-save');
    expect(asked, 0, reason: 'a linked file has no Replace');
    final save = engine.saves.single;
    expect(save.input, const PdfToolInput.pdf('/docs/Report.pdf', password: 'secret'));
    expect(save.annotations.single.kind, PdfAnnotationKind.ink);
    expect(save.stamps, isEmpty);
    expect(save.burnIn, isFalse);
    expect(save.outPath, startsWith('/staging'));
    expect(save.outPath, endsWith('Report (annotated).pdf'));
    final (paths, names, beside) = sink.saved.single;
    expect(paths, [save.outPath]);
    expect(names, ['Report (annotated).pdf']);
    expect(beside, isNull);
    expect(sink.replaced, isEmpty);
    expect(find.text('Saved as Report (annotated).pdf'), findsOneWidget);
    await toastGone(tester);
    expect(_key('pdf-annotate-toolbar'), findsNothing);
    expect(engine.mode, isNull);
  });

  testWidgets('a Danaview folder file offers Replace, which reopens the file', (tester) async {
    final offered = <String>[];
    await open(
      tester,
      viewer(_entry, annotate: engine, choose: (context, name) async {
        offered.add(name);
        return PdfSaveMode.replace;
      }),
    );
    await enter(tester);
    await tap(tester, 'pdf-annotate-tool-pen');
    await emit(tester, stroke);
    final opens = docs.calls.where((c) => c == 'open').length;
    await tapForToast(tester, 'pdf-annotate-save');
    expect(offered, ['Report (annotated).pdf']);
    final (entry, path, pages) = sink.replaced.single;
    expect(entry, EntryId.parse('fe_report'));
    expect(path, engine.saves.single.outPath);
    expect(pages, 3);
    expect(sink.saved, isEmpty);
    expect(docs.calls.where((c) => c == 'open').length, opens + 1, reason: 'the replaced file is opened again');
    expect(find.text('Replaced Report.pdf'), findsOneWidget);
    await toastGone(tester);
    await tester.pumpAndSettle();
  });

  testWidgets('dismissing the new-file-or-Replace choice saves nothing and keeps the session', (tester) async {
    await open(tester, viewer(_entry, annotate: engine, choose: (context, name) async => null));
    await enter(tester);
    await tap(tester, 'pdf-annotate-tool-pen');
    await emit(tester, stroke);
    await tap(tester, 'pdf-annotate-save');
    expect(engine.saves, isEmpty);
    expect(sink.saved, isEmpty);
    expect(_key('pdf-annotate-toolbar'), findsOneWidget);
    expect(engine.preview, hasLength(1));
  });

  testWidgets('Cancel during a long save and failures keep the session', (tester) async {
    await open(tester, viewer(_linked, annotate: engine));
    await enter(tester);
    await tap(tester, 'pdf-annotate-tool-pen');
    await emit(tester, stroke);
    engine.hold = true;
    await tester.tap(_key('pdf-annotate-save'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Saving annotations'), findsOneWidget);
    expect(_enabled(tester, _key('pdf-annotate-undo')), isFalse, reason: 'locked while saving');
    await tester.tap(_key('pdf-tool-cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Saving annotations'), findsNothing);
    expect(sink.saved, isEmpty);
    expect(_enabled(tester, _key('pdf-annotate-undo')), isTrue, reason: 'unlocked again');
    expect(_key('pdf-annotate-toolbar'), findsOneWidget);
    expect(engine.preview, hasLength(1));

    engine
      ..hold = false
      ..failWith = const PdfException(PdfErrorCode.unsupported, 'x');
    await tapForToast(tester, 'pdf-annotate-save');
    expect(find.text('This PDF doesn’t allow annotations.'), findsOneWidget);
    await toastGone(tester);
    expect(sink.saved, isEmpty);
    expect(_enabled(tester, _key('pdf-annotate-save')), isTrue);
  });

  testWidgets('leaving with unsaved marks asks first: the bar, the viewer back and the system back', (tester) async {
    await open(tester, viewer(_linked, annotate: engine));
    await enter(tester);
    await tap(tester, 'pdf-annotate-tool-pen');
    await emit(tester, stroke);

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Discard annotations?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_key('pdf-annotate-toolbar'), findsOneWidget, reason: 'kept');
    expect(engine.preview, hasLength(1));

    // The system back on the viewer route.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard annotations?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(closed, 1, reason: 'the viewer closes after discarding');
    expect(engine.mode, isNull);

    // The bar's close with marks, discarded: back to plain viewing.
    await open(tester, KeyedSubtree(key: UniqueKey(), child: viewer(_linked, annotate: engine)));
    await enter(tester);
    await tap(tester, 'pdf-annotate-tool-pen');
    await emit(tester, stroke);
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(_key('pdf-annotate-toolbar'), findsNothing);
    expect(_key('pdf-viewer-annotate'), findsOneWidget);
    expect(closed, 1);
  });

  testWidgets('a viewer that refuses annotate mode leaves it with a calm message', (tester) async {
    engine.failMode = const PdfException(PdfErrorCode.notSupportedOnDevice, 'x');
    await open(tester, viewer(_linked, annotate: engine));
    await tapForToast(tester, 'pdf-viewer-annotate');
    expect(find.text('Annotate isn’t available for this PDF.'), findsOneWidget);
    await toastGone(tester);
    expect(_key('pdf-annotate-toolbar'), findsNothing);
  });

  group('surface matrix: 280 / 375 / 1280 px × text scale 0.85 / 1.35', () {
    for (final size in const [Size(280, 560), Size(375, 812), Size(1280, 800)]) {
      for (final scale in const [0.85, 1.35]) {
        final surface = DocSurface(size, scale);
        testWidgets('no overflow and 44 px labelled targets at $surface', (tester) async {
          applyDocSurface(tester, surface);
          final handle = tester.ensureSemantics();
          await open(tester, viewer(_entry, annotate: engine), textScale: scale);
          await enter(tester);
          expectNoLayoutErrors(tester, '$surface select');
          await expectTargetsAndLabels(tester);
          view().select('TOKEN-1');
          await tester.pumpAndSettle();
          await tap(tester, 'pdf-annotate-tool-pen');
          await emit(tester, stroke);
          expectNoLayoutErrors(tester, '$surface pen');
          await expectTargetsAndLabels(tester);
          await tap(tester, 'pdf-annotate-tool-text');
          answers = ['Note'];
          await emit(tester, const PdfAnnotateTapEvent(1, 0, Offset(72, 700), null));
          expectNoLayoutErrors(tester, '$surface text selected');
          await expectTargetsAndLabels(tester);
          await tap(tester, 'pdf-annotate-tool-eraser');
          expectNoLayoutErrors(tester, '$surface eraser');
          await tester.tap(_key('pdf-annotate-save'));
          await tester.pumpAndSettle();
          expectNoLayoutErrors(tester, '$surface save sheet');
          await tester.tap(find.byKey(const ValueKey('pdf-save-new')));
          await tester.pumpAndSettle();
          expectNoLayoutErrors(tester, '$surface saved');
          handle.dispose();
        });
      }
    }
  });
}
