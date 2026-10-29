// OWNER: HOM-30
//
// Saving a sign session (HOM plan §8.5, G-H6): the placed signatures are burned into the page
// content by the annotate engine (`save(stamps:, burnIn: true)`: text stays text, the pages' own
// annotations, boxes and rotation stay, no Stamp annotation is left) into a staged NEW file
// "<name> (signed).pdf", which the HOM-28 result sink imports next to the original (`Imported` for
// linked and incoming files). "Replace" is offered only for a file in a Danaview folder. An
// encrypted source is opened with its password and the signed copy is encrypted with it. Progress
// with Cancel; a cancelled save leaves nothing behind. Nothing here logs a name, a path or a
// password (rule 30).

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/widgets.dart';

import '../../router/viewer_file.dart';
import '../annotate/pdf_annotate_save.dart';
import '../organiser/pdf_tool_launcher.dart';
import '../organiser/pdf_tool_progress.dart' show pdfToolErrorMessage;
import '../organiser/pdf_tool_save.dart';

/// The name of a signed copy of [name]: `Contract (signed).pdf`.
String signedPdfName(String name) {
  final dot = name.lastIndexOf('.');
  final base = (dot > 0 ? name.substring(0, dot) : name).trim();
  return '${base.isEmpty ? 'Document' : base} (signed).pdf';
}

/// The sentence for a failed sign save.
String pdfSignErrorMessage(Object error) {
  if (error is PdfException && error.code == PdfErrorCode.unsupported) return 'This PDF doesn’t allow changes, so it can’t be signed.';
  if (error is PdfException && error.code == PdfErrorCode.notFound) return 'A signature image is missing. Place it again and save.';
  return pdfToolErrorMessage(error);
}

/// Burns [stamps] into a signed copy of [file] (unlocked with [password]) through [engine] and
/// [environment]'s sink; asks new file or Replace for a Danaview folder file. Resolves to the
/// saved file, or null when dismissed or cancelled; throws [PdfException] or a sink error.
Future<PdfSavedFile?> savePdfSignatures(
  BuildContext context, {
  required PdfToolsEnvironment environment,
  required PdfAnnotateEngine engine,
  required ViewerFile file,
  String? password,
  required List<PdfStamp> stamps,
  Future<PdfSaveMode?> Function(BuildContext context, String newName)? chooseSaveMode,
}) =>
    savePdfAnnotations(
      context,
      environment: environment,
      engine: engine,
      file: file,
      password: password,
      annotations: const [],
      stamps: stamps,
      burnIn: true,
      chooseSaveMode: chooseSaveMode,
      newName: signedPdfName(file.displayName),
      progressTitle: 'Signing',
    );
