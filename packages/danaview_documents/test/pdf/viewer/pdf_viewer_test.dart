// OWNER: HOM-24
//
// The PDF viewer screen (BUILD_PLAN HOM-24, HOM plan §8.4) against fakes of danaview_pdf: opens
// read-only and closes the handle, search with a result list finds fixture strings and steps
// through hits, the password PDF opens after the prompt (wrong password keeps the sheet), pages
// grid and outline navigate, copy of the selection, damaged / unsupported files fall back through
// the viewer host to the file card, and every state stays inside ARCH §1.4's surface matrix
// (280–1280 px × text scale 0.85–1.35) with 44 px labelled targets.

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../card/doc_harness.dart';
import 'pdf_fakes.dart';

const _file = ViewerFile(path: '/tmp/doc.pdf', displayName: 'Quarterly report.pdf', kind: FileKind.document, docKind: DocumentKind.pdf);

void main() {
  late FakePdfDocuments docs;
  late FakePdfViewController view;

  Widget viewer({FakePdfDocuments? documents, VoidCallback? onUnavailable, RecordingPort? port, PdfPasswordPrompt? prompt}) => PdfViewer(
        file: _file,
        documents: documents ?? docs,
        fileOut: port,
        onClose: () {},
        onUnavailable: onUnavailable,
        passwordPrompt: prompt,
        viewBuilder: (context, d, onCreated) => FakeNativeView(controller: view, onCreated: onCreated),
      );

  setUp(() {
    docs = FakePdfDocuments();
    view = FakePdfViewController(12);
  });

  testWidgets('opens read-only, shows the page position and closes the handle', (tester) async {
    await tester.pumpWidget(docApp(viewer()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-native-pdf')), findsOneWidget);
    expect(find.text('Quarterly report.pdf'), findsOneWidget);
    expect(find.text('Page 1 of 12'), findsOneWidget);
    expect(docs.calls, containsAllInOrder(['capabilities', 'open', 'outline']));

    await view.goToPage(5);
    await tester.pump();
    expect(find.text('Page 6 of 12'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    expect(docs.closed, [7]);
  });

  testWidgets('search finds fixture strings, lists them and steps through hits', (tester) async {
    await tester.pumpWidget(docApp(viewer()));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Search in PDF').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'token-1');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // TOKEN-1, TOKEN-10, TOKEN-11, TOKEN-12.
    expect(find.text('1 of 4 matches'), findsOneWidget);
    expect(find.text('Page 1'), findsOneWidget);
    expect(find.text('Page 12'), findsOneWidget);
    expect(view.calls, contains('showHit:0'));

    await tester.tap(find.bySemanticsLabel('Next match'));
    await tester.pumpAndSettle();
    expect(view.calls.last, 'showHit:9');
    expect(find.text('2 of 4 matches'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Previous match'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Previous match'));
    await tester.pumpAndSettle();
    expect(view.calls.last, 'showHit:11', reason: 'wraps around');

    await tester.tap(find.text('Page 11'));
    await tester.pumpAndSettle();
    expect(view.calls.last, 'showHit:10');

    await tester.enterText(find.byType(EditableText), 'nothing-like-this');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);

    // Closing the panel cancels and clears the search.
    await tester.tap(find.bySemanticsLabel('Search in PDF').first);
    await tester.pumpAndSettle();
    expect(view.calls, containsAllInOrder(['cancelSearch', 'clearSearch']));
  });

  testWidgets('a password PDF opens after the prompt; a wrong password keeps the sheet', (tester) async {
    docs = FakePdfDocuments(password: 'open sesame');
    await tester.pumpWidget(docApp(viewer()));
    await tester.pumpAndSettle();

    expect(find.text('Password required'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-native-pdf')), findsNothing);

    await tester.enterText(find.byType(EditableText), 'guess');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('That password didn\'t work. Try again.'), findsOneWidget);
    expect(find.text('Password required'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'open sesame');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Password required'), findsNothing);
    expect(find.byKey(const ValueKey('fake-native-pdf')), findsOneWidget);
    expect(docs.tried, ['guess', 'open sesame']);
    expect(find.text('Page 1 of 12'), findsOneWidget);
  });

  testWidgets('cancelling the prompt leaves a locked state that can ask again', (tester) async {
    docs = FakePdfDocuments(password: 'pw');
    var asked = 0;
    await tester.pumpWidget(docApp(viewer(prompt: (context, attempt) async {
      asked++;
      return asked == 1 ? false : attempt('pw');
    })));
    await tester.pumpAndSettle();
    expect(find.text('This PDF is protected'), findsOneWidget);
    await tester.tap(find.text('Enter password'));
    await tester.pumpAndSettle();
    expect(asked, 2);
    expect(find.byKey(const ValueKey('fake-native-pdf')), findsOneWidget);
  });

  testWidgets('pages grid and outline go to pages', (tester) async {
    await tester.pumpWidget(docApp(viewer()));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Pages'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pdf-pages-grid')), findsOneWidget);
    expect(docs.calls.where((c) => c.startsWith('thumbnail:')), isNotEmpty);
    await tester.tap(find.bySemanticsLabel('Page 3'));
    await tester.pumpAndSettle();
    expect(view.calls.last, 'goToPage:2');
    expect(find.bySemanticsLabel('Page 3, current page'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Contents'));
    await tester.pumpAndSettle();
    expect(find.text('Introduction'), findsOneWidget);
    await tester.tap(find.text('Appendix'));
    await tester.pumpAndSettle();
    expect(view.calls.last, 'goToPage:9');
  });

  testWidgets('copies the selected text and changes the layout', (tester) async {
    await tester.pumpWidget(docApp(viewer()));
    await tester.pumpAndSettle();
    view.select('TOKEN-1');
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('View options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy selected text'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(view.calls, contains('copy'));
    expect(find.text('Copied'), findsOneWidget);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('View options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Two pages'));
    await tester.pumpAndSettle();
    expect(view.calls, contains('mode:twoUpContinuous'));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a damaged file or a platform without a viewer is unavailable', (tester) async {
    var unavailable = 0;
    await tester.pumpWidget(docApp(viewer(
      documents: FakePdfDocuments(openError: const PdfException(PdfErrorCode.damaged, 'x')),
      onUnavailable: () => unavailable++,
    )));
    await tester.pumpAndSettle();
    expect(unavailable, 1);

    await tester.pumpWidget(docApp(
        KeyedSubtree(key: UniqueKey(), child: viewer(documents: FakePdfDocuments(caps: PdfCapabilities.none), onUnavailable: () => unavailable++))));
    await tester.pumpAndSettle();
    expect(unavailable, 2);

    // Android without passwords: a locked file isn't shown (the router then shows the file card).
    final noPasswords = FakePdfDocuments(password: 'pw', caps: const PdfCapabilities(textureView: true));
    await tester.pumpWidget(docApp(KeyedSubtree(key: UniqueKey(), child: viewer(documents: noPasswords, onUnavailable: () => unavailable++))));
    await tester.pumpAndSettle();
    expect(unavailable, 3);
    expect(noPasswords.closed, [7]);

    // A missing file stays here with "Open in another app".
    await tester.pumpWidget(docApp(viewer(
      documents: FakePdfDocuments(openError: const PdfException(PdfErrorCode.notFound, 'x')),
      onUnavailable: () => unavailable++,
      port: RecordingPort(),
    )));
    await tester.pumpAndSettle();
    expect(unavailable, 3);
    expect(find.text('Can\'t show this PDF'), findsOneWidget);
    expect(find.text('Open in another app'), findsOneWidget);
  });

  group('viewer host registration', () {
    Future<List<ViewerKind>> host(WidgetTester tester, FakePdfDocuments documents) async {
      final shown = <ViewerKind>[];
      await tester.pumpWidget(docApp(DocumentViewer(
        file: _file,
        platform: ViewerPlatform.iOS,
        viewers: {
          ViewerKind.pdf: pdfViewerBuilder(documents, viewBuilder: (context, d, onCreated) => FakeNativeView(controller: view, onCreated: onCreated)),
        },
        probes: FunctionProbes({ViewerKind.pdf: pdfViewerProbe(documents)}),
        onResolved: shown.add,
      )));
      await tester.pumpAndSettle();
      return shown;
    }

    testWidgets('a PDF opens in the PDF viewer', (tester) async {
      expect(await host(tester, FakePdfDocuments()), [ViewerKind.pdf]);
      expect(find.byKey(const ValueKey('fake-native-pdf')), findsOneWidget);
    });

    testWidgets('a damaged PDF fails the probe and shows the file card', (tester) async {
      final documents = FakePdfDocuments(probeResult: const PdfProbe(canOpen: false));
      expect(await host(tester, documents), [ViewerKind.fileCard]);
      expect(documents.calls, isNot(contains('open')));
    });

    testWidgets('a PDF that fails after opening falls back to the file card', (tester) async {
      final documents = FakePdfDocuments(openError: const PdfException(PdfErrorCode.unsupported, 'x'));
      expect(await host(tester, documents), [ViewerKind.pdf, ViewerKind.fileCard]);
    });

    test('the probe refuses password files without password support and never throws', () async {
      expect(await pdfViewerProbe(FakePdfDocuments(password: 'pw', caps: const PdfCapabilities(textureView: true)))(_file), isFalse);
      expect(await pdfViewerProbe(FakePdfDocuments(password: 'pw'))(_file), isTrue);
      expect(await pdfViewerProbe(_ThrowingDocs())(_file), isFalse);
    });
  });

  group('surface matrix (ARCH §1.4)', () {
    for (final surface in docMatrix) {
      testWidgets('no overflow and 44 px labelled targets at $surface', (tester) async {
        applyDocSurface(tester, surface);
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(docApp(viewer(port: RecordingPort()), textScale: surface.textScale));
        await tester.pumpAndSettle();
        expectNoLayoutErrors(tester, '$surface open');
        await expectTargetsAndLabels(tester);

        for (final label in ['Search in PDF', 'Pages', 'Contents']) {
          await tester.tap(find.bySemanticsLabel(label).first);
          await tester.pumpAndSettle();
          if (label == 'Search in PDF') {
            await tester.enterText(find.byType(EditableText), 'token');
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pumpAndSettle();
          }
          expectNoLayoutErrors(tester, '$surface $label');
          await expectTargetsAndLabels(tester);
        }
        handle.dispose();
      });
    }

    for (final surface in [docMatrix.first, docMatrix[2], docMatrix.last]) {
      testWidgets('password sheet and locked state fit at $surface', (tester) async {
        applyDocSurface(tester, surface);
        docs = FakePdfDocuments(password: 'pw');
        await tester.pumpWidget(docApp(viewer(), textScale: surface.textScale));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(EditableText), 'nope');
        await tester.tap(find.text('Unlock'));
        await tester.pumpAndSettle();
        expectNoLayoutErrors(tester, '$surface sheet');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('This PDF is protected'), findsOneWidget);
        expectNoLayoutErrors(tester, '$surface locked');
      });
    }
  });
}

final class _ThrowingDocs extends FakePdfDocuments {
  @override
  Future<PdfProbe> probe(String path) => throw const PdfException(PdfErrorCode.internal, 'x');
}
