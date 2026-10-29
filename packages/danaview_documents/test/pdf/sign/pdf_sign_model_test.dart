// OWNER: HOM-30
//
// The sign session model (lib/src/pdf/sign/pdf_sign_model.dart): placing centres the chosen
// signature on the tap at a page-suited size with its aspect, inside the page, upright on a rotated
// page; moving and resizing replace a stamp; delete; several pages; undo / redo with the selection
// following; the paths in use (for the saved-signatures sheet); nothing without a signature; the
// names of signed copies.


import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter_test/flutter_test.dart';

final _t = DateTime.utc(2026, 10, 30);
final _sig = SavedSignature(id: 'sig-1-drawn', path: '/support/signatures/sig-1-drawn.png', kind: SignatureKind.drawn, createdAt: _t, width: 600, height: 200);
final _tall = SavedSignature(id: 'sig-2-typed', path: '/support/signatures/sig-2-typed.png', kind: SignatureKind.typed, createdAt: _t, width: 100, height: 100);

(double, double, double, double) _r(PdfRect r) => (r.x, r.y, r.width, r.height);

void main() {
  const letter = PdfPageSize(612, 792);

  test('nothing is placed without a chosen signature', () {
    final m = PdfSignModel();
    expect(m.place(0, const Offset(300, 300), letter), isNull);
    expect(m.isDirty, isFalse);
  });

  test('placing centres the signature with its aspect at a page-suited size, inside the page', () {
    final m = PdfSignModel()..signature = _sig;
    final id = m.place(0, const Offset(300, 400), letter)!;
    final s = m.stampOf(id)!;
    expect(_r(s.rect), (210, 370, 180, 60), reason: '180 pt wide at 3:1, centred');
    expect(s.imagePath, _sig.path);
    expect(s.rotationDegrees, 0);
    expect(m.selectedId, id);
    expect(m.isDirty, isTrue);
    // A square signature is capped by its height; a tap at the corner keeps it on the page.
    m.signature = _tall;
    final corner = m.stampOf(m.place(0, const Offset(5, 790), letter)!)!;
    expect(_r(corner.rect), (0, 792 - 90, 90, 90));
    // A small page: at most 40 % of its width.
    final small = PdfSignModel.placedRect(_sig, const Offset(50, 50), const PdfPageSize(200, 100));
    expect(_r(small), (10, 36.666666666666664, 80, 26.666666666666668));
  });

  test('on a page shown turned 90°, the stamp is upright: footprint swapped, image turned back', () {
    final m = PdfSignModel()..signature = _sig;
    final s = m.stampOf(m.place(2, const Offset(300, 400), const PdfPageSize(612, 792, 90))!)!;
    // Seen 180 × 60 on screen: in page space 60 wide and 180 tall.
    expect(_r(s.rect), (270, 310, 60, 180));
    expect(s.rotationDegrees, 270);
    expect(PdfSignModel.uprightRotation(const PdfPageSize(612, 792, 180)), 180);
    expect(PdfSignModel.uprightRotation(const PdfPageSize(612, 792, 270)), 90);
  });

  test('move, resize and delete are undo steps; several pages; the selection follows', () {
    final m = PdfSignModel()..signature = _sig;
    final a = m.place(0, const Offset(300, 400), letter)!;
    final b = m.place(3, const Offset(100, 100), letter)!;
    expect(m.signedPages, [0, 3]);
    expect(m.stamps.map((s) => s.pageIndex), [0, 3]);
    expect(m.selectedId, b);

    expect(m.move(a, const PdfRect(10, 20, 240, 80)), isTrue);
    expect(_r(m.stampOf(a)!.rect), (10, 20, 240, 80));
    expect(m.move(a, const PdfRect(10, 20, 240, 80)), isFalse, reason: 'nothing changed');
    expect(m.move('nope', const PdfRect(1, 1, 1, 1)), isFalse);
    expect(m.move(a, const PdfRect(1, 1, 0, 1)), isFalse);

    m.select(a);
    expect(m.remove(a), isTrue);
    expect(m.selectedId, isNull);
    expect(m.stamps.map((s) => s.pageIndex), [3]);

    m.undo();
    expect(_r(m.stampOf(a)!.rect), (10, 20, 240, 80));
    m.undo();
    expect(_r(m.stampOf(a)!.rect), (210, 370, 180, 60));
    m.undo();
    m.undo();
    expect(m.isDirty, isFalse);
    expect(m.canUndo, isFalse);
    m.redo();
    m.redo();
    expect(m.items, hasLength(2));
    expect(m.canRedo, isTrue);
    m.select('nope');
    expect(m.selectedId, isNull);
  });

  test('the paths in use include undoable ones', () {
    final m = PdfSignModel()..signature = _sig;
    final a = m.place(0, const Offset(300, 400), letter)!;
    m.signature = _tall;
    m.place(1, const Offset(300, 400), letter);
    m.remove(a);
    expect(m.pathsInUse, {_sig.path, _tall.path});
  });

  test('signed copies are named "<name> (signed).pdf"', () {
    expect(signedPdfName('Contract.pdf'), 'Contract (signed).pdf');
    expect(signedPdfName('Lease v2.final.PDF'), 'Lease v2.final (signed).pdf');
    expect(signedPdfName('  .pdf'), 'Document (signed).pdf');
    expect(pdfSignErrorMessage(const PdfException(PdfErrorCode.unsupported, 'x')), contains('can’t be signed'));
  });

  test('the toolbar hint says what the next tap does', () {
    final m = PdfSignModel();
    expect(pdfSignHint(m), 'Choose or create a signature');
    m.signature = _sig;
    expect(pdfSignHint(m), 'Tap the page where the signature goes');
    m.place(0, const Offset(300, 400), letter);
    expect(pdfSignHint(m), contains('round handle'));
    m.select(null);
    expect(pdfSignHint(m), contains('tap a page to add another'));
  });
}
