// OWNER: HOM-24
//
// How the Home registers the PDF viewer with the viewer host (HOM-23's DocumentViewer, which never
// imports native viewers itself): a [ViewerBuilder] for ViewerKind.pdf and the router's probe. The
// probe opens nothing for long: it asks the platform's capabilities and a read-only probe of the
// file, so a damaged file or a password file on a platform without passwords goes on to the next
// candidate (Quick Look, then the file card).

import 'package:danaview_pdf/danaview_pdf.dart';

import '../../router/document_viewer.dart';
import '../../router/viewer_file.dart';
import 'pdf_viewer.dart';

/// The router probe of the PDF viewer over [documents]. Never throws.
Future<bool> Function(ViewerFile file) pdfViewerProbe(PdfDocuments documents) {
  Future<PdfCapabilities>? caps;
  return (file) async {
    try {
      final PdfCapabilities c;
      try {
        c = await (caps ??= documents.capabilities());
      } on Object {
        caps = null; // cache only a successful answer, so a transient failure is retried
        rethrow;
      }
      if (!c.canView) return false;
      final probe = await documents.probe(file.path);
      return probe.canOpen && (!probe.encrypted || c.passwords);
    } on Object {
      return false;
    }
  };
}

/// The [ViewerBuilder] of the PDF viewer over [documents]; [viewBuilder] replaces the native view
/// (tests).
ViewerBuilder pdfViewerBuilder(PdfDocuments documents, {PdfViewBuilder? viewBuilder}) => (context, viewer) => PdfViewer(
      file: viewer.file,
      documents: documents,
      fileOut: viewer.fileOut,
      onClose: viewer.onClose,
      onUnavailable: viewer.unavailable,
      viewBuilder: viewBuilder,
    );
