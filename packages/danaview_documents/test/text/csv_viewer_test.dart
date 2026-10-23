// OWNER: HOM-23
//
// BUILD_PLAN HOM-23 CSV/TSV grid (HOM plan §8.4): `,` `;` and tab files render as a read-only grid
// with the header row fixed while the body scrolls, the separator can be changed from the menu, a
// large generated CSV scrolls with fixed-extent rows, and the ARCH §1.4 matrix (no overflow at
// 280–1280 px × 0.85–1.35 with the menu open, targets ≥ 44 px, labels).

import 'dart:convert';
import 'dart:typed_data';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../card/doc_harness.dart';

ViewerFile _file(String name) => ViewerFile(path: '/x/$name', displayName: name, kind: FileKind.document, docKind: DocumentKind.text);

CsvTable _table(String text, {CsvDelimiter preferred = CsvDelimiter.comma}) =>
    CsvTable.build(TextDocument.fromBytes(Uint8List.fromList(utf8.encode(text))), preferred: preferred);

void main() {
  for (final (name, text, delimiter) in [
    ('comma.csv', 'Name,City,Score\nAda,London,"1,5"\nLin,Oslo,2\n', CsvDelimiter.comma),
    ('semicolon.csv', 'Name;City;Score\nAda;London;1,5\nLin;Oslo;2\n', CsvDelimiter.semicolon),
    ('tabs.tsv', 'Name\tCity\tScore\nAda\tLondon\t1,5\nLin\tOslo\t2\n', CsvDelimiter.tab),
  ]) {
    testWidgets('$name renders as a grid with a header', (tester) async {
      final t = _table(text, preferred: name.endsWith('.tsv') ? CsvDelimiter.tab : CsvDelimiter.comma);
      expect(t.delimiter, delimiter);
      await tester.pumpWidget(docApp(CsvViewer(file: _file(name), table: t, onClose: () {})));
      for (final cell in ['Name', 'City', 'Score', 'Ada', 'London', '1,5', 'Lin', 'Oslo', '2']) {
        expect(find.text(cell), findsOneWidget, reason: cell);
      }
      expect(find.text('${delimiter.label} · 2 rows · UTF-8'), findsOneWidget);
      // Header above the first row, aligned in the same column.
      expect(tester.getTopLeft(find.text('Name')).dy, lessThan(tester.getTopLeft(find.text('Ada')).dy));
      expect(tester.getTopLeft(find.text('Name')).dx, tester.getTopLeft(find.text('Ada')).dx);
    });
  }

  testWidgets('the header row stays fixed while the body scrolls', (tester) async {
    final rows = List.generate(500, (i) => 'item $i,${i * 3},note $i').join('\n');
    await tester.pumpWidget(docApp(CsvViewer(file: _file('big.csv'), table: _table('Item,Count,Note\n$rows'))));
    final headerY = tester.getTopLeft(find.text('Item')).dy;
    await tester.fling(find.byKey(const ValueKey('csv-viewer-rows')), const Offset(0, -2000), 6000);
    await tester.pumpAndSettle();
    expect(find.text('item 0'), findsNothing);
    expect(tester.getTopLeft(find.text('Item')).dy, headerY);
  });

  testWidgets('the separator menu re-splits the rows', (tester) async {
    await tester.pumpWidget(docApp(CsvViewer(file: _file('mixed.csv'), table: _table('a,b;c\n1,2;3\n'))));
    expect(find.text('a'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('View options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Semicolon'));
    await tester.pumpAndSettle();
    expect(find.text('a,b'), findsOneWidget);
    expect(find.text('1,2'), findsOneWidget);
    expect(find.text('Semicolon · 1 row · UTF-8'), findsOneWidget);
  });

  testWidgets('an empty file shows the empty state', (tester) async {
    await tester.pumpWidget(docApp(CsvViewer(file: _file('empty.csv'), table: _table(''))));
    expect(find.text('This table is empty'), findsOneWidget);
  });

  testWidgets('matrix: no overflow with the menu open, targets ≥ 44 px, labels', (tester) async {
    final handle = tester.ensureSemantics();
    final wide = List.generate(12, (c) => 'Column number $c').join(',');
    final body = List.generate(60, (r) => List.generate(12, (c) => 'r$r c$c ${'v' * (c * 3)}').join(',')).join('\n');
    final t = CsvTable.build(TextDocument.fromBytes(Uint8List.fromList(utf8.encode('$wide\n$body')), fileSize: 80000000));
    final file = _file('A spreadsheet export with a long file name.csv');
    for (final surface in docMatrix) {
      applyDocSurface(tester, surface);
      await tester
          .pumpWidget(docApp(CsvViewer(file: file, table: t, fileOut: RecordingPort(), onClose: () {}), textScale: surface.textScale));
      await tester.pump();
      expectNoLayoutErrors(tester, surface);
      await expectTargetsAndLabels(tester);
      await tester.tap(find.bySemanticsLabel('View options'));
      await tester.pumpAndSettle();
      expectNoLayoutErrors(tester, '$surface menu');
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
    }
    handle.dispose();
  });
}
