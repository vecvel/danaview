// OWNER: HOM-23
//
// BUILD_PLAN HOM-23 file card (HOM plan §8.4, D-98h, D-98k): icon, name, size and dates, "Open in
// another app" and Share through the FileOutPort where the platform has them (Windows/Linux: no
// share sheet), toasts for "no app" and failures, and the ARCH §1.4 matrix: no overflow at
// 280–1280 px × text scale 0.85–1.35, targets ≥ 44 px, labelled controls, computed contrast.

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'doc_harness.dart';

final ViewerFile _docx = ViewerFile(
  path: '/lib/files/fe_x/Quarterly report with a rather long name for small phones.docx',
  displayName: 'Quarterly report with a rather long name for small phones.docx',
  kind: FileKind.document,
  docKind: DocumentKind.word,
  id: EntryId.parse('fe_${'b' * 22}'),
  sizeBytes: 1520000,
  addedAt: DateTime(2026, 10, 20, 9, 5),
  modifiedAt: DateTime(2026, 10, 21, 14, 30),
  pageCount: 12,
);

void main() {
  testWidgets('shows the type, name, size, pages and dates', (tester) async {
    await tester.pumpWidget(docApp(FileCard(file: _docx, fileOut: RecordingPort(), onClose: () {})));
    expect(find.text(_docx.displayName), findsWidgets);
    expect(find.text('Document'), findsWidgets);
    expect(find.text('1.52 MB'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('20 Oct 2026, 09:05'), findsOneWidget);
    expect(find.text('21 Oct 2026, 14:30'), findsOneWidget);
    expect(find.bySemanticsLabel('Back'), findsOneWidget);
  });

  testWidgets('Open in another app and Share hand the library file to the port', (tester) async {
    final port = RecordingPort();
    await tester.pumpWidget(docApp(FileCard(file: _docx, fileOut: port)));
    await tester.tap(find.text('Open in another app'));
    await tester.pump();
    await tester.tap(find.text('Share'));
    await tester.pump();
    expect(port.calls.map((c) => c.$1), ['open', 'share']);
    expect(port.calls.every((c) => c.$2.single.path == _docx.path && c.$2.single.displayName == _docx.displayName), isTrue);
    DanaviewToast.dismiss();
  });

  testWidgets('Windows and Linux: no share sheet, so only Open in another app', (tester) async {
    await tester
        .pumpWidget(docApp(FileCard(file: _docx, fileOut: RecordingPort(FileOutPlatform.windows)), platform: TargetPlatform.windows));
    expect(find.text('Open in another app'), findsOneWidget);
    expect(find.text('Share'), findsNothing);
  });

  testWidgets('without a port there are no out actions', (tester) async {
    await tester.pumpWidget(docApp(FileCard(file: _docx)));
    expect(find.text('Open in another app'), findsNothing);
    expect(find.text('Share'), findsNothing);
  });

  testWidgets('no app for the file and failures become toasts', (tester) async {
    final port = RecordingPort()..openInAnswer = false;
    await tester.pumpWidget(docApp(FileCard(file: _docx, fileOut: port)));
    await tester.tap(find.text('Open in another app'));
    await tester.pump();
    expect(find.text('No app on this device opens this file'), findsOneWidget);
    DanaviewToast.dismiss();
    await tester.pumpAndSettle();
    port.fail = const FileOutException(FileOutError.missing);
    await tester.tap(find.text('Share'));
    await tester.pump();
    expect(find.text('This file is no longer available'), findsOneWidget);
    DanaviewToast.dismiss();
    await tester.pumpAndSettle();
  });

  test('formats', () {
    expect(formatByteSize(0), '0 bytes');
    expect(formatByteSize(1), '1 byte');
    expect(formatByteSize(999), '999 bytes');
    expect(formatByteSize(1000), '1 KB');
    expect(formatByteSize(1520000), '1.52 MB');
    expect(formatByteSize(52428800), '52.4 MB');
    expect(formatByteSize(2000000000), '2 GB');
    expect(formatCount(1234567), '1,234,567');
    expect(formatCount(12), '12');
  });

  test('type labels and the title/caption contrast', () {
    ViewerFile f(String name, FileKind kind) =>
        ViewerFile(path: '/x/$name', displayName: name, kind: kind, docKind: classify(fileName: name).docKind);
    expect(documentTypeLabel(f('a.pdf', FileKind.document)), 'PDF document');
    expect(documentTypeLabel(f('a.xlsx', FileKind.document)), 'Spreadsheet');
    expect(documentTypeLabel(f('a.key', FileKind.document)), 'Presentation');
    expect(documentTypeLabel(f('a.csv', FileKind.document)), 'Table (CSV)');
    expect(documentTypeLabel(f('a.zip', FileKind.document)), 'ZIP file');
    expect(documentTypeLabel(f('a.jpg', FileKind.photo)), 'Photo');
    for (final c in [DanaviewColors.textPrimary, DanaviewColors.textSecondary, DanaviewColors.textMuted]) {
      expect(DanaviewColors.contrastRatio(c, DanaviewColors.surface), greaterThanOrEqualTo(4.5));
      expect(DanaviewColors.contrastRatio(c, DanaviewColors.background), greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets('matrix: no overflow, targets ≥ 44 px, labelled controls (280–1280 px × 0.85–1.35)', (tester) async {
    final handle = tester.ensureSemantics();
    for (final surface in docMatrix) {
      applyDocSurface(tester, surface);
      await tester.pumpWidget(docApp(
        FileCard(file: _docx, fileOut: RecordingPort(), onClose: () {}, message: 'This file can\'t be shown here.'),
        textScale: surface.textScale,
      ));
      await tester.pump();
      expectNoLayoutErrors(tester, surface);
      await expectTargetsAndLabels(tester);
      // The card's actions sit together under the details (no big gaps).
      final open = tester.getRect(find.text('Open in another app'));
      final share = tester.getRect(find.text('Share'));
      expect(share.top - open.bottom, lessThan(60), reason: '$surface');
    }
    handle.dispose();
  });
}
