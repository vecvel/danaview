// OWNER: HOM-30
//
// Sign mode in the PDF viewer (BUILD_PLAN HOM-30, HOM plan §8.5) against fakes of the documents,
// the native view, the annotate engine, the signature store and the result sink: "Sign" shows only
// with an engine, a store and the reported sign tool; the mode swaps the top bar (undo, redo, Save)
// and adds the signature strip under the same native view in the place input; the newest saved
// signature is ready, or "New signature" opens; a tap places it (several pages; upright on a turned
// page), a tap on one selects it, the viewer's drag / resize replaces it, Delete removes it, undo /
// redo; Save burns the stamps in ("<name> (signed).pdf" as a new file with the password; Replace only
// for Danaview folder files, which reopens the file); Cancel and errors keep the session; leaving
// with placed signatures asks first (the bar, the viewer back, the system back); a scope opening the
// viewer in sign mode (the file menu's "Sign…") starts it at once; and the mode fits 280 / 375 /
// 1280 px at text scale 0.85 and 1.35 with 44 px labelled targets.

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../card/doc_harness.dart';
import '../../signatures/signature_fakes.dart';
import '../annotate/annotate_fakes.dart';
import '../organiser/organiser_fakes.dart';
import '../viewer/pdf_fakes.dart';

const _linked = ViewerFile(path: '/docs/Contract.pdf', displayName: 'Contract.pdf', kind: FileKind.document, docKind: DocumentKind.pdf);
final _entry = ViewerFile(
  path: '/library/files/fe_contract/Contract.pdf',
  displayName: 'Contract.pdf',
  kind: FileKind.document,
  docKind: DocumentKind.pdf,
  id: EntryId.parse('fe_contract'),
);

const _signCaps = PdfCapabilities(
  platformView: true,
  search: true,
  selection: true,
  outline: true,
  passwords: true,
  textExtraction: true,
  tools: {PdfTool.annotate, PdfTool.sign},
);

Finder _key(String key) => find.byKey(ValueKey(key));

bool _enabled(WidgetTester tester, Finder f) => switch (tester.widget(f)) {
      final DanaviewButton b => b.onPressed != null,
      final DanaviewIconButton b => b.onPressed != null,
      final w => throw StateError('unexpected ${w.runtimeType}'),
    };

void main() {
  late FakePdfDocuments docs;
  late FakePdfAnnotateEngine engine;
  late FakePdfResultSink sink;
  late MemorySignatureStore store;
  late int closed;

  setUp(() {
    docs = FakePdfDocuments(pages: 4, caps: _signCaps);
    engine = FakePdfAnnotateEngine();
    sink = FakePdfResultSink();
    store = MemorySignatureStore(count: 2);
    closed = 0;
  });

  Widget viewer(
    ViewerFile file, {
    bool withEngine = true,
    bool withStore = true,
    PdfViewerStartTool? startWith,
    Future<PdfSaveMode?> Function(BuildContext, String)? choose,
    PdfPasswordPrompt? prompt,
  }) {
    final env = PdfToolsEnvironment(
      documents: docs,
      tools: FakePdfPageTools(tools: const {}),
      sink: sink,
      annotate: withEngine ? engine : null,
      signatures: withStore ? store : null,
    );
    FakePdfViewController? current;
    return PdfToolsScope(
      environment: env,
      startWith: startWith,
      child: PdfViewer(
        file: file,
        documents: docs,
        onClose: () => closed++,
        passwordPrompt: prompt,
        chooseSaveMode: choose,
        viewBuilder: (context, d, onCreated) => FakeNativeView(controller: current ??= FakePdfViewController(d.pageCount), onCreated: onCreated),
      ),
    );
  }

  Future<void> open(WidgetTester tester, Widget w, {double textScale = 1}) async {
    await tester.pumpWidget(docApp(w, textScale: textScale));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(_key(key));
    await tester.pumpAndSettle();
  }

  /// "Sign" in the top bar, or "Sign…" in the viewer's menu on windows under 360 px.
  Future<void> enter(WidgetTester tester) async {
    if (_key('pdf-viewer-sign').evaluate().isNotEmpty) return tap(tester, 'pdf-viewer-sign');
    await tester.tap(find.byTooltip('View options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign…'));
    await tester.pumpAndSettle();
  }

  Future<void> emit(WidgetTester tester, PdfAnnotateEvent e) async {
    engine.emit(e);
    await tester.pumpAndSettle();
  }

  PdfAnnotateTapEvent tapAt(int page, double x, double y, [String? item]) => PdfAnnotateTapEvent(1, page, Offset(x, y), item);

  (double, double, double, double) r(PdfRect rect) => (rect.x, rect.y, rect.width, rect.height);

  testWidgets('"Sign" shows only with an engine, a store and the reported tool', (tester) async {
    await open(tester, viewer(_linked));
    expect(_key('pdf-viewer-sign'), findsOneWidget);
    expect(_key('pdf-viewer-annotate'), findsOneWidget, reason: 'next to Annotate');

    await open(tester, KeyedSubtree(key: UniqueKey(), child: viewer(_linked, withStore: false)));
    expect(_key('pdf-viewer-sign'), findsNothing, reason: 'no signature store');
    await open(tester, KeyedSubtree(key: UniqueKey(), child: viewer(_linked, withEngine: false)));
    expect(_key('pdf-viewer-sign'), findsNothing, reason: 'no engine');

    docs = FakePdfDocuments(pages: 4, caps: const PdfCapabilities(platformView: true, search: true, selection: true, tools: {PdfTool.annotate}));
    await open(tester, KeyedSubtree(key: UniqueKey(), child: viewer(_linked)));
    expect(_key('pdf-viewer-sign'), findsNothing, reason: 'the platform does not report sign (Android before HOM-30A)');
  });

  testWidgets('the mode swaps the bar, keeps the native view, uses the place input and the newest signature', (tester) async {
    await open(tester, viewer(_linked));
    final native = tester.element(find.byKey(const ValueKey('fake-native-pdf')));
    await enter(tester);
    expect(find.text('Sign'), findsOneWidget);
    expect(_key('pdf-sign-toolbar'), findsOneWidget);
    expect(identical(tester.element(find.byKey(const ValueKey('fake-native-pdf'))), native), isTrue, reason: 'the same native view');
    expect(engine.modes.single.$2!.input, PdfAnnotateInput.place);
    final newest = (await store.list()).first;
    expect(_key('sign-signature-${newest.id}'), findsOneWidget);
    expect(find.text('Tap the page where the signature goes'), findsOneWidget, reason: 'the newest one is ready');
    expect(_enabled(tester, _key('pdf-sign-save')), isFalse);
    expect(_enabled(tester, _key('pdf-sign-undo')), isFalse);

    // Leaving without placing asks nothing and ends the viewer's mode.
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Discard signatures?'), findsNothing);
    expect(_key('pdf-sign-toolbar'), findsNothing);
    expect(engine.mode, isNull);
    expect(closed, 0);
  });

  testWidgets('place, select, move, resize, delete, several pages, undo and redo', (tester) async {
    await open(tester, viewer(_linked));
    await enter(tester);
    final newest = (await store.list()).first; // 300 × 100 px

    await emit(tester, tapAt(0, 300, 400));
    final first = engine.preview.single;
    expect(first.stamp!.pageIndex, 0);
    expect(first.stamp!.imagePath, newest.path);
    expect(r(first.stamp!.rect), (210, 370, 180, 60));
    expect(engine.previewSelected, first.id, reason: 'a placed signature is selected (its handle shows)');
    expect(find.text('Drag to move it, or drag the round handle to resize'), findsOneWidget);
    expect(_enabled(tester, _key('pdf-sign-save')), isTrue);

    // Another page, and a page shown turned 90° (upright there).
    await emit(tester, tapAt(1, 100, 100));
    await emit(tester, tapAt(2, 300, 400));
    expect(engine.preview.map((i) => i.pageIndex), [0, 1, 2]);
    expect(engine.preview[2].stamp!.rotationDegrees, 270);
    expect(r(engine.preview[2].stamp!.rect), (270, 310, 60, 180));

    // A tap on a placed one selects it; another viewer's taps are ignored.
    await emit(tester, tapAt(0, 250, 390, first.id));
    expect(engine.previewSelected, first.id);
    expect(engine.preview, hasLength(3));
    await emit(tester, const PdfAnnotateTapEvent(9, 0, Offset(1, 1), null));
    expect(engine.preview, hasLength(3));

    // The viewer's drag, then its resize.
    await emit(tester, PdfStampMovedEvent(1, 0, first.id, const PdfRect(50, 60, 180, 60)));
    expect(r(engine.preview.first.stamp!.rect), (50, 60, 180, 60));
    await emit(tester, PdfStampMovedEvent(1, 0, first.id, const PdfRect(50, 30, 270, 90)));
    expect(r(engine.preview.first.stamp!.rect), (50, 30, 270, 90));

    // Delete, then undo and redo.
    await tap(tester, 'pdf-sign-delete');
    expect(engine.preview.map((i) => i.pageIndex), [1, 2]);
    expect(_key('pdf-sign-delete'), findsNothing);
    await tap(tester, 'pdf-sign-undo');
    expect(r(engine.preview.first.stamp!.rect), (50, 30, 270, 90));
    await tap(tester, 'pdf-sign-undo');
    expect(r(engine.preview.first.stamp!.rect), (50, 60, 180, 60));
    await tap(tester, 'pdf-sign-redo');
    expect(r(engine.preview.first.stamp!.rect), (50, 30, 270, 90));
  });

  testWidgets('choosing another saved signature places that one', (tester) async {
    await open(tester, viewer(_linked));
    await enter(tester);
    final list = await store.list();
    await tap(tester, 'sign-signature-${list[1].id}');
    await emit(tester, tapAt(0, 300, 400));
    expect(engine.preview.single.stamp!.imagePath, list[1].path);
  });

  testWidgets('without a saved signature "New signature" opens; a drawn one is then placed', (tester) async {
    store = MemorySignatureStore();
    await open(tester, viewer(_linked));
    await enter(tester);
    expect(find.text('New signature'), findsOneWidget, reason: 'the sheet opens at once');
    await tester.tap(_key('signature-create-cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Choose or create a signature'), findsOneWidget);

    // A tap on the page asks for one again; this time a signature is drawn and saved.
    await emit(tester, tapAt(0, 300, 400));
    expect(find.text('New signature'), findsOneWidget);
    expect(engine.preview, isEmpty);
    final pad = tester.getRect(_key('signature-pad'));
    final g = await tester.startGesture(pad.center);
    await g.moveBy(const Offset(40, 10));
    await g.up();
    await tester.pumpAndSettle();
    // The real image maker needs the engine's renderer: run it outside the fake clock.
    await tester.runAsync(() async {
      await tester.tap(_key('signature-create-save'));
      for (var i = 0; i < 50 && find.text('New signature').evaluate().isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(await store.count(), 1);
    await emit(tester, tapAt(0, 300, 400));
    expect(engine.preview.single.stamp!.imagePath, (await store.list()).single.path);
  });

  testWidgets('Save burns the signatures into "<name> (signed).pdf" as a new file with the password', (tester) async {
    docs = FakePdfDocuments(pages: 4, caps: _signCaps, password: 'pw');
    await open(tester, viewer(_linked, prompt: (context, attempt) async => attempt('pw')));
    await enter(tester);
    await emit(tester, tapAt(0, 300, 400));
    await emit(tester, tapAt(3, 300, 400));
    await tester.tap(_key('pdf-sign-save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final save = engine.saves.single;
    expect(save.burnIn, isTrue);
    expect(save.annotations, isEmpty);
    expect(save.stamps.map((s) => s.pageIndex), [0, 3]);
    expect(save.input.path, _linked.path);
    expect(save.input.password, 'pw');
    expect(save.outPath, startsWith('/staging/'));
    expect(save.outPath, endsWith('Contract (signed).pdf'));
    expect(sink.saved.single.$2, ['Contract (signed).pdf']);
    expect(sink.replaced, isEmpty);
    expect(_key('pdf-sign-toolbar'), findsNothing, reason: 'the mode ends after saving');
    expect(engine.mode, isNull);
    expect(find.text('Saved as Contract (signed).pdf'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a Danaview folder file offers Replace, which reopens the file', (tester) async {
    await open(tester, viewer(_entry, choose: (context, name) async => PdfSaveMode.replace));
    
    await enter(tester);
    await emit(tester, tapAt(0, 300, 400));
    final opens = docs.calls.where((c) => c == 'open').length;
    await tap(tester, 'pdf-sign-save');
    expect(sink.replaced.single.$1, _entry.entryId);
    expect(sink.replaced.single.$2, engine.saves.single.outPath);
    expect(sink.saved, isEmpty);
    expect(docs.calls.where((c) => c == 'open').length, opens + 1, reason: 'the replaced file is opened again');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Cancel during a long save, a dismissed choice and failures keep the session', (tester) async {
    await open(tester, viewer(_entry, choose: (context, name) async => null));
    await enter(tester);
    await emit(tester, tapAt(0, 300, 400));
    await tap(tester, 'pdf-sign-save');
    expect(engine.saves, isEmpty, reason: 'the choice was dismissed');
    expect(_key('pdf-sign-toolbar'), findsOneWidget);

    await open(tester, KeyedSubtree(key: UniqueKey(), child: viewer(_linked)));
    await enter(tester);
    await emit(tester, tapAt(0, 300, 400));
    engine.hold = true;
    await tester.tap(_key('pdf-sign-save'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Signing'), findsOneWidget);
    expect(_enabled(tester, _key('pdf-sign-undo')), isFalse, reason: 'locked while saving');
    await tester.tap(_key('pdf-tool-cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Signing'), findsNothing);
    expect(sink.saved, isEmpty);
    expect(_enabled(tester, _key('pdf-sign-save')), isTrue, reason: 'unlocked again');
    expect(_key('pdf-sign-toolbar'), findsOneWidget);
    expect(engine.preview, hasLength(1));

    engine.hold = false;
    engine.failWith = const PdfException(PdfErrorCode.unsupported, 'no changes');
    await tester.tap(_key('pdf-sign-save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('This PDF doesn’t allow changes, so it can’t be signed.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(_key('pdf-sign-toolbar'), findsOneWidget);
  });

  testWidgets('leaving with placed signatures asks first: the bar, the viewer back and the system back', (tester) async {
    await open(tester, viewer(_linked));
    await enter(tester);
    await emit(tester, tapAt(0, 300, 400));
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Discard signatures?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_key('pdf-sign-toolbar'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard signatures?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(closed, 1, reason: 'the viewer closes after discarding');
    expect(engine.mode, isNull);
  });

  testWidgets('the file menu’s "Sign…" opens the viewer in sign mode at once', (tester) async {
    await open(tester, viewer(_linked, startWith: PdfViewerStartTool.sign));
    expect(_key('pdf-sign-toolbar'), findsOneWidget);
    expect(engine.mode?.input, PdfAnnotateInput.place);
  });

  testWidgets('a signature placed on the PDF can’t be deleted from the saved list', (tester) async {
    await open(tester, viewer(_linked));
    await enter(tester);
    final list = await store.list();
    await emit(tester, tapAt(0, 300, 400));
    await tap(tester, 'sign-manage-signatures');
    expect(find.text('On this PDF'), findsOneWidget);
    expect(_enabled(tester, _key('saved-signature-delete-${list[0].id}')), isFalse);
    await tap(tester, 'saved-signature-delete-${list[1].id}');
    await tester.tap(_key('saved-signature-${list[0].id}'));
    await tester.pumpAndSettle();
    expect(await store.count(), 1);
    expect(_key('pdf-sign-toolbar'), findsOneWidget);
  });

  group('surface matrix: 280 / 375 / 1280 px × text scale 0.85 / 1.35', () {
    for (final size in const [Size(280, 560), Size(375, 812), Size(1280, 800)]) {
      for (final scale in const [0.85, 1.35]) {
        final surface = DocSurface(size, scale);
        testWidgets('no overflow and 44 px labelled targets at $surface', (tester) async {
          applyDocSurface(tester, surface);
          final handle = tester.ensureSemantics();
          store = MemorySignatureStore(count: SignatureStore.maxCount);
          await open(tester, viewer(_entry), textScale: scale);
          expectNoLayoutErrors(tester, '$surface viewer');
          await enter(tester);
          expectNoLayoutErrors(tester, '$surface sign');
          await expectTargetsAndLabels(tester);
          await emit(tester, tapAt(0, 300, 400));
          expectNoLayoutErrors(tester, '$surface placed');
          await expectTargetsAndLabels(tester);
          await tap(tester, 'sign-manage-signatures');
          expectNoLayoutErrors(tester, '$surface manage');
          await expectTargetsAndLabels(tester);
          await tester.tapAt(const Offset(4, 4));
          await tester.pumpAndSettle();
          await tap(tester, 'sign-new-signature');
          expectNoLayoutErrors(tester, '$surface new');
          await tester.tap(_key('signature-create-cancel'));
          await tester.pumpAndSettle();
          await tester.tap(_key('pdf-sign-save'));
          await tester.pumpAndSettle();
          expectNoLayoutErrors(tester, '$surface save sheet');
          await tester.tap(find.byKey(const ValueKey('pdf-save-new')));
          await tester.pumpAndSettle();
          expectNoLayoutErrors(tester, '$surface saved');
          await tester.pump(const Duration(seconds: 3));
          handle.dispose();
        });
      }
    }
  });
}
