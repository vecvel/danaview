// OWNER: HOM-31
//
// The PDF viewer's entry to compress (BUILD_PLAN HOM-31): "Compress…" sits in the top bar's
// options menu when the app passes a launcher and the platform lists the compress tool, hands the
// launcher the file and the password the file was unlocked with, and stays hidden otherwise.

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../card/doc_harness.dart';
import '../viewer/pdf_fakes.dart';

const _file = ViewerFile(path: '/tmp/doc.pdf', displayName: 'Quarterly report.pdf', kind: FileKind.document, docKind: DocumentKind.pdf);

const _caps = PdfCapabilities(platformView: true, search: true, selection: true, outline: true, passwords: true, textExtraction: true, tools: {PdfTool.compress});

void main() {
  Widget viewer(FakePdfDocuments docs, {PdfCompressLauncher? onCompress, PdfPasswordPrompt? prompt}) => PdfViewer(
        file: _file,
        documents: docs,
        onClose: () {},
        onCompress: onCompress,
        passwordPrompt: prompt,
        viewBuilder: (context, d, onCreated) => FakeNativeView(controller: FakePdfViewController(d.pageCount), onCreated: onCreated),
      );

  testWidgets('"Compress…" opens the launcher with the file and the unlock password', (tester) async {
    final calls = <(String, String?)>[];
    await tester.pumpWidget(docApp(viewer(
      FakePdfDocuments(caps: _caps, password: 'secret'),
      prompt: (context, attempt) => attempt('secret'),
      onCompress: (context, file, {password}) async => calls.add((file.path, password)),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('View options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compress…'));
    await tester.pumpAndSettle();
    expect(calls, [('/tmp/doc.pdf', 'secret')]);
  });

  testWidgets('hidden without a launcher or without the compress tool', (tester) async {
    await tester.pumpWidget(docApp(viewer(FakePdfDocuments(caps: _caps))));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('View options'));
    await tester.pumpAndSettle();
    expect(find.text('Compress…'), findsNothing);

    await tester.pumpWidget(docApp(KeyedSubtree(
      key: UniqueKey(),
      child: viewer(FakePdfDocuments(caps: appleCaps), onCompress: (context, file, {password}) async {}),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('View options'));
    await tester.pumpAndSettle();
    expect(find.text('Compress…'), findsNothing);
  });
}
