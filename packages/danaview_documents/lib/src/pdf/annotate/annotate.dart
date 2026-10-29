// OWNER: HOM-29
//
// The public entry of lib/src/pdf/annotate/ (HOM plan §8.5, D-98j): annotate and highlight in the
// PDF viewer. The session model with undo / redo, the Cinema B toolbar, the session that ties the
// model to the native viewer's preview and events, and the save into a new file
// "<name> (annotated).pdf" (Replace only for Danaview folder files). The viewer shows "Annotate"
// when a PdfToolsScope above it carries an annotate engine and the platform reports the tool.

/// The public entry of lib/src/pdf/annotate/: PDF annotate and highlight.
library;

export 'pdf_annotate_model.dart';
export 'pdf_annotate_save.dart';
export 'pdf_annotate_session.dart';
export 'pdf_annotate_toolbar.dart';
