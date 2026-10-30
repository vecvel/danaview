// OWNER: INT-101
//
// Public barrel of danaview_pdf (ARCH v1.2 §4.3, §8): document handle, viewer, text and page tools
// over the Pigeon surface of HOM-24 (lib/src/pigeon/ stays private). Rule 27: sources are opened
// read-only; tools write only new files.

library;

export 'src/pdf_annotate.dart';
export 'src/pdf_compress.dart';
export 'src/pdf_document.dart';
export 'src/pdf_text.dart';
// HOM-29A: the texture view's annotate geometry (the registry and the rules stay internal).
export 'src/pdf_texture_annotate.dart' show PdfPageSpace;
export 'src/pdf_tools.dart';
export 'src/pdf_view.dart';
