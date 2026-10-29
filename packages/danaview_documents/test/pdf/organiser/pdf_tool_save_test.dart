// OWNER: HOM-28
//
// The save rules of the PDF page tools (HOM plan §8.5, G-H6, ARCH v1.2 §9.3): Replace only for
// Danaview folder files; result names; the organiser model's edits; and LibraryPdfResultSink over a
// real library: a new file lands next to the original (or in Imported for linked files) and the
// original keeps its bytes, the staged file is consumed, and Replace keeps the entry's identity
// while its file takes the new bytes.

import 'dart:io';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../card/doc_harness.dart';

void main() {
  group('rules and names', () {
    test('Replace is offered only for Danaview folder files', () {
      final entry = ViewerFile(path: '/l/f.pdf', displayName: 'f.pdf', kind: FileKind.document, id: EntryId.parse('fe_abc'));
      final linked = ViewerFile(path: '/d/f.pdf', displayName: 'f.pdf', kind: FileKind.document, id: LinkedItemId.of('r1', 'f.pdf'));
      const incoming = ViewerFile(path: '/tmp/f.pdf', displayName: 'f.pdf', kind: FileKind.document);
      expect(canReplacePdf(entry), isTrue);
      expect(canReplacePdf(linked), isFalse);
      expect(canReplacePdf(incoming), isFalse);
    });

    test('result names', () {
      expect(editedPdfName('Report.pdf'), 'Report (edited).pdf');
      expect(editedPdfName('Report.PDF'), 'Report (edited).pdf');
      expect(editedPdfName('Notes'), 'Notes (edited).pdf');
      expect(editedPdfName(' '), 'Document (edited).pdf');
      expect(splitPdfName('Report.pdf', const PdfPageRange(0, 3)), 'Report (pages 1–3).pdf');
      expect(splitPdfName('Report.pdf', const PdfPageRange(3, 4)), 'Report (page 4).pdf');
      expect(extractPdfName('Report.pdf', [4, 0, 1]), 'Report (pages 1–2, 5).pdf');
      expect(extractPdfName('Report.pdf', [6]), 'Report (page 7).pdf');
      expect(extractPdfName('Report.pdf', [0, 2, 4, 6, 8]), 'Report (extract).pdf');
      expect(mergedPdfName('Scan 1.jpg'), 'Scan 1 (merged).pdf');
    });

    test('staging paths never name an existing file', () {
      final dir = docTempDir();
      final a = stagingPathFor(dir.path, 'a/b.pdf');
      expect(a, startsWith(dir.path));
      expect(a.substring(dir.path.length + 1), isNot(contains('/')));
      File(a).writeAsStringSync('x');
      expect(stagingPathFor(dir.path, 'a/b.pdf'), isNot(a));
    });
  });

  group('organiser model', () {
    test('select, rotate, delete, move, reset', () {
      final m = PdfOrganiserModel(4);
      expect(m.isDirty, isFalse);
      m.toggle(1);
      m.toggle(3);
      expect(m.selectedInOrder, const [PdfPagePlan(1), PdfPagePlan(3)]);
      m.rotate();
      expect(m.plan, const [PdfPagePlan(0), PdfPagePlan(1, rotation: 90), PdfPagePlan(2), PdfPagePlan(3, rotation: 90)]);
      m.rotate(degrees: 270, only: 1);
      expect(m.plan[1], const PdfPagePlan(1));
      m.move(3, 0);
      expect(m.plan.map((p) => p.sourcePage), [3, 0, 1, 2]);
      expect(m.deleteSelected(), 2);
      expect(m.plan.map((p) => p.sourcePage), [0, 2]);
      expect(m.hasSelection, isFalse);
      m.toggleAll();
      expect(m.allSelected, isTrue);
      expect(m.canDelete, isFalse);
      expect(m.deleteSelected(), 0, reason: 'one page must remain');
      m.reset();
      expect(m.isDirty, isFalse);
      expect(m.length, 4);
    });
  });

  group('LibraryPdfResultSink over a real library', () {
    late LibraryStore store;
    late LibraryFileActions actions;
    late ImportService imports;
    late Directory staging;

    setUp(() async {
      final root = docTempDir();
      staging = Directory('${docTempDir().path}/staging');
      store = await LibraryStore.open(root: root.path, background: false);
      addTearDown(store.close);
      actions = LibraryFileActions(store);
      imports = ImportService(store: store);
      addTearDown(imports.dispose);
    });

    Future<FileEntry> importPdf(String name, String bytes, {FolderId? folder}) async {
      final src = File('${docTempDir().path}/$name')..writeAsStringSync(bytes);
      final item = (await imports.importAll([ImportSource.file(src.path)], target: folder)).single;
      return item.entry!;
    }

    test('a new file goes next to the original; the original and its bytes stay', () async {
      final folder = await store.write((w, now) => w.createFolder('Work', now: now));
      final original = await importPdf('Report.pdf', '%PDF-original', folder: folder);
      final sink = LibraryPdfResultSink(imports: imports, actions: actions, staging: staging.path);
      final dir = await sink.stagingDirectory();
      final out = stagingPathFor(dir, 'Report (edited).pdf');
      File(out).writeAsStringSync('%PDF-edited');

      final saved = (await sink.saveNew([out], ['Report (edited).pdf'], besideEntry: original.id)).single;

      final entry = store.reader.entry(saved.entryId!)!;
      expect(entry.folderId, folder);
      expect(entry.displayName, 'Report (edited).pdf');
      expect(File(actions.pathOf(entry)).readAsStringSync(), '%PDF-edited');
      expect(File(actions.pathOf(original)).readAsStringSync(), '%PDF-original');
      expect(File(out).existsSync(), isFalse, reason: 'the staged file is consumed');
      expect(saved.replaced, isFalse);

      // A second save dedupes the name in the folder.
      final again = stagingPathFor(dir, 'Report (edited).pdf');
      File(again).writeAsStringSync('%PDF-edited-2');
      final second = (await sink.saveNew([again], ['Report (edited).pdf'], besideEntry: original.id)).single;
      expect(second.displayName, 'Report (edited) (2).pdf');
    });

    test('without a Danaview folder original the result goes to Imported', () async {
      final sink = LibraryPdfResultSink(imports: imports, actions: actions, staging: staging.path);
      final out = stagingPathFor(await sink.stagingDirectory(), 'x.pdf');
      File(out).writeAsStringSync('%PDF-x');
      final saved = (await sink.saveNew([out], ['Linked (edited).pdf'])).single;
      final entry = store.reader.entry(saved.entryId!)!;
      final imported = store.reader.allFolders().firstWhere((f) => f.systemRole == FolderSystemRole.imported);
      expect(entry.folderId, imported.id);
    });

    test('Replace keeps the entry and swaps its bytes; the staged file is removed', () async {
      final original = await importPdf('Report.pdf', '%PDF-original');
      final sink = LibraryPdfResultSink(imports: imports, actions: actions, staging: staging.path);
      final out = stagingPathFor(await sink.stagingDirectory(), 'r.pdf');
      File(out).writeAsStringSync('%PDF-replaced');
      final saved = await sink.replace(original.id, out, pageCount: 4);
      expect(saved.replaced, isTrue);
      expect(saved.entryId, original.id);
      expect(File(actions.pathOf(original)).readAsStringSync(), '%PDF-replaced');
      expect(store.reader.meta(original.id)?.pageCount, 4);
      expect(File(out).existsSync(), isFalse);
      expect(store.reader.allEntries(), hasLength(1));
    });
  });
}
