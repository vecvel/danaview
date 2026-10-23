// OWNER: S3-Q
//
// S3's light share of HOM-14 / HOM-32 (library scale): the Documents tab with 5,000 generated
// Danaview-folder documents (PDF, Word, Excel, text, CSV in turn) builds only the rows in view,
// jumps to the end and flings back without exceptions, and the PDF sub-filter narrows the list.
// No simulator: a widget test on a real LibraryStore in a temp dir.

import 'package:danaview_features/src/library/filters/entry_widgets.dart';
import 'package:danaview_features/src/library/tabs/documents_tab.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../filters/filters_support.dart';

const int _count = 5000;
const List<String> _exts = ['pdf', 'docx', 'xlsx', 'txt', 'csv'];

Future<List<FileEntry>> _seed(WidgetTester tester, FixtureLibrary lib) => lib.run(tester, (s) => s.write((w, now) {
      final out = <FileEntry>[];
      for (var i = 0; i < _count; i++) {
        final name = 'Doc ${i.toString().padLeft(4, '0')}.${_exts[i % _exts.length]}';
        final cls = classify(fileName: name);
        final job = w.beginImport(now: now.subtract(Duration(minutes: i)));
        (w.fs.openPart(job.id)..writeFromSync(const [7, 7, 7])).closeSync();
        out.add(w.commitImport(
          job.id,
          ImportedFileInfo(displayName: name, kind: cls.kind, subKind: cls.subKind, meta: name.endsWith('.pdf') ? const EntryMeta(pageCount: 3) : null),
          now: now.subtract(Duration(minutes: i)),
        ));
      }
      return out;
    }));

int _builtRows() => find.byType(LibraryEntryRow, skipOffstage: false).evaluate().length;

void main() {
  testWidgets('Documents tab: 5,000 documents scroll with bounded rows (HOM-14/HOM-32, S3 share)', (tester) async {
    useSurface(tester, const TestSurface(Size(375, 812), 1.0));
    final env = await LibraryTestEnv.create();
    final lib = await FixtureLibrary.open(tester);
    final seeded = await _seed(tester, lib);
    expect(seeded, hasLength(_count));
    expect(seeded.every((e) => e.kind == FileKind.document), isTrue, reason: 'all classified as documents');

    await tester.pumpWidget(filtersApp(env, const DocumentsTab(), lib: lib));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    final first = _builtRows();
    expect(first, greaterThan(5));
    expect(first, lessThan(60), reason: 'only the viewport and its cache extent are built');

    final position = tester.state<ScrollableState>(find.descendant(
      of: find.byKey(const PageStorageKey('library-documents-tab')),
      matching: find.byType(Scrollable),
    ).first).position;
    final totalExtent = position.maxScrollExtent;
    expect(totalExtent, greaterThan(_count * 40.0), reason: 'every row has extent');

    final sw = Stopwatch()..start();
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    sw.stop();
    expect(tester.takeException(), isNull);
    expect(_builtRows(), lessThan(60));
    // ignore: avoid_print
    print('S3-Q 5k documents jump-to-end frame: ${sw.elapsedMicroseconds} µs (test mode)');

    await tester.fling(find.byKey(const PageStorageKey('library-documents-tab')), const Offset(0, 3000), 6000);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(_builtRows(), lessThan(60));
    }
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);

    // The PDF sub-filter: a fifth of the list, still lazily built.
    position.jumpTo(0);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('documents-sub-pdf')));
    await pumpFrames(tester);
    final pdfPosition = tester.state<ScrollableState>(find.descendant(
      of: find.byKey(const PageStorageKey('library-documents-tab')),
      matching: find.byType(Scrollable),
    ).first).position;
    expect(pdfPosition.maxScrollExtent, lessThan(totalExtent / 3));
    expect(pdfPosition.maxScrollExtent, greaterThan(_count / 5 * 40.0));
    expect(find.textContaining('.docx'), findsNothing);
    expect(_builtRows(), lessThan(60));
    expect(tester.takeException(), isNull);

    await lib.close(tester);
    await env.dispose();
  });
}
