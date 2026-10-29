// OWNER: HOM-29
//
// The annotate session model (lib/src/pdf/annotate/pdf_annotate_model.dart): adding, removing and
// replacing are undo steps (redo until the next edit), several marks can be one step, the
// selection follows the items, the tool maps to the viewer's mode with the pen's look, the session
// is dirty only while it holds marks, and the history is capped.


import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter_test/flutter_test.dart';

const _ink = PdfAnnotation.ink(0, [
  [Offset(1, 1), Offset(2, 2)],
], colorArgb: 0xFF000000);
const _mark = PdfAnnotation.markup(PdfAnnotationKind.highlight, 1, [PdfRect(0, 0, 10, 10)], colorArgb: 0xFFFFD60A);

void main() {
  test('edits are undo steps; redo until the next edit', () {
    final m = PdfAnnotateModel();
    var notified = 0;
    m.addListener(() => notified++);
    expect(m.isDirty, isFalse);
    expect(m.canUndo, isFalse);
    final a = m.add(_ink);
    final [b, c] = m.addAll([_mark, _mark]);
    expect(m.items.map((i) => i.id), [a, b, c]);
    expect(m.isDirty, isTrue);
    m.undo();
    expect(m.items.map((i) => i.id), [a], reason: 'addAll was one step');
    expect(m.canRedo, isTrue);
    m.redo();
    expect(m.items, hasLength(3));
    expect(m.remove(b), isTrue);
    expect(m.remove('nope'), isFalse);
    expect(m.items.map((i) => i.id), [a, c]);
    m.undo();
    expect(m.items.map((i) => i.id), [a, b, c]);
    m.undo();
    m.add(_ink);
    expect(m.canRedo, isFalse, reason: 'a new edit drops the redo branch');
    m
      ..undo()
      ..undo();
    expect(m.isDirty, isFalse, reason: 'back to nothing: nothing to save');
    expect(m.canUndo, isFalse);
    expect(notified, greaterThan(8));
  });

  test('replace keeps the id; the selection follows the items', () {
    final m = PdfAnnotateModel();
    final text = PdfAnnotation.freeText(0, const Offset(10, 700), 'One', colorArgb: 0xFF000000);
    final id = m.add(text);
    m.select(id);
    expect(m.selected?.annotation?.text, 'One');
    expect(m.replace(id, text.withText('Two')), isTrue);
    expect(m.annotationOf(id)?.text, 'Two');
    expect(m.selectedId, id);
    m.select('unknown');
    expect(m.selectedId, isNull);
    m.select(id);
    m.remove(id);
    expect(m.selectedId, isNull, reason: 'a removed item is no longer selected');
    m.undo();
    m.select(id);
    m
      ..undo()
      ..undo();
    expect(m.items, isEmpty);
    expect(m.selectedId, isNull, reason: 'an undone item is no longer selected');
    final other = m.add(_ink);
    m
      ..select(other)
      ..tool = PdfAnnotateTool.pen;
    expect(m.selectedId, isNull, reason: 'the pen drops the selection');
  });

  test('the tool maps to the viewer mode with the pen look', () {
    final m = PdfAnnotateModel();
    expect(m.mode.input, PdfAnnotateInput.select);
    m
      ..tool = PdfAnnotateTool.pen
      ..penColor = PdfAnnotateModel.inkColors[2]
      ..penWidth = PdfAnnotateModel.penWidths[2];
    expect(m.mode, PdfAnnotateMode(input: PdfAnnotateInput.ink, inkColorArgb: PdfAnnotateModel.inkColors[2], inkWidth: 6));
    m.tool = PdfAnnotateTool.text;
    expect(m.mode.input, PdfAnnotateInput.text);
    m.tool = PdfAnnotateTool.eraser;
    expect(m.mode.input, PdfAnnotateInput.erase);
  });

  test('the history is capped', () {
    final m = PdfAnnotateModel();
    for (var i = 0; i < PdfAnnotateModel.historyLimit + 50; i++) {
      m.add(_ink);
    }
    var steps = 0;
    while (m.canUndo) {
      m.undo();
      steps++;
    }
    expect(steps, PdfAnnotateModel.historyLimit);
    expect(m.items, hasLength(50));
  });

  test('the annotated name', () {
    expect(annotatedPdfName('Report.pdf'), 'Report (annotated).pdf');
    expect(annotatedPdfName('notes'), 'notes (annotated).pdf');
    expect(annotatedPdfName('.pdf'), '.pdf (annotated).pdf');
    expect(annotatedPdfName(' .pdf'), 'Document (annotated).pdf');
  });
}
