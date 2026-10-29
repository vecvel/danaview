// OWNER: HOM-30
//
// The public entry of lib/src/pdf/sign/ (HOM plan §8.5, D-98j): visual signatures in the PDF
// viewer. "Sign" (next to Annotate, and the file menu's "Sign…") opens a sign mode over the same
// native view: pick or create a signature (lib/src/signatures/), tap a page to place it, drag to
// move it and the round handle to resize it, delete it, place it on several pages; Save burns the
// signatures into the page content of a NEW file "<name> (signed).pdf" (Replace only for Danaview
// folder files). Shown when a PdfToolsScope above the viewer carries an annotate engine and a
// signature store and the platform reports the sign tool.

/// The public entry of lib/src/pdf/sign/: the PDF Sign tool.
library;

export 'pdf_sign_model.dart';
export 'pdf_sign_save.dart';
export 'pdf_sign_session.dart';
export 'pdf_sign_toolbar.dart';
