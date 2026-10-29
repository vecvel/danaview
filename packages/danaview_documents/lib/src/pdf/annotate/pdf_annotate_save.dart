// OWNER: HOM-29
//
// Saving an annotate session (HOM plan §8.5, G-H6): the annotations are written by the engine as
// real PDF annotations into a staged NEW file "<name> (annotated).pdf", which the HOM-28 result
// sink imports next to the original (its Danaview folder; `Imported` for linked and incoming files).
// "Replace" is offered only for a file in a Danaview folder (`canReplacePdf`) and renames the
// finished file over the entry's file. The original's bytes are never modified. The save runs off
// the UI thread with progress and Cancel (`runPdfTool`); a cancelled save leaves nothing behind.
// Nothing here logs a name, a path, a password or annotation text (rule 30).

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/widgets.dart';

import '../../router/viewer_file.dart';
import '../organiser/pdf_page_organiser.dart' show showPdfSaveModeSheet;
import '../organiser/pdf_tool_launcher.dart';
import '../organiser/pdf_tool_progress.dart';
import '../organiser/pdf_tool_save.dart';

/// The name of an annotated copy of [name]: `Report (annotated).pdf`.
String annotatedPdfName(String name) {
  final dot = name.lastIndexOf('.');
  final base = (dot > 0 ? name.substring(0, dot) : name).trim();
  return '${base.isEmpty ? 'Document' : base} (annotated).pdf';
}

/// The sentence for a failed annotate save.
String pdfAnnotateErrorMessage(Object error) {
  if (error is PdfException && error.code == PdfErrorCode.unsupported) return 'This PDF doesn’t allow annotations.';
  return pdfToolErrorMessage(error);
}

/// Saves [annotations] (and HOM-30's [stamps], burned in with [burnIn]) of [file], unlocked with
/// [password], through [engine] and [environment]'s sink. Asks new file or Replace for a Danaview
/// folder file ([chooseSaveMode], default [showPdfSaveModeSheet]). Resolves to the saved file, or
/// null when the user dismissed the choice or cancelled; throws [PdfException] or a sink error.
Future<PdfSavedFile?> savePdfAnnotations(
  BuildContext context, {
  required PdfToolsEnvironment environment,
  required PdfAnnotateEngine engine,
  required ViewerFile file,
  String? password,
  required List<PdfAnnotation> annotations,
  List<PdfStamp> stamps = const [],
  bool burnIn = false,
  Future<PdfSaveMode?> Function(BuildContext context, String newName)? chooseSaveMode,
}) async {
  final newName = annotatedPdfName(file.displayName);
  final entry = file.entryId;
  var mode = PdfSaveMode.newFile;
  if (canReplacePdf(file)) {
    final picked = await (chooseSaveMode ?? showPdfSaveModeSheet)(context, newName);
    if (picked == null || !context.mounted) return null;
    mode = picked;
  }
  final dir = await environment.sink.stagingDirectory();
  final out = stagingPathFor(dir, newName);
  if (!context.mounted) return null;
  final job = engine.save(PdfToolInput.pdf(file.path, password: password), annotations: annotations, stamps: stamps, burnIn: burnIn, outPath: out);
  final result = await runPdfTool(context, job, title: 'Saving annotations');
  if (result == null) return null;
  if (mode == PdfSaveMode.replace && entry != null) {
    return environment.sink.replace(entry, out, pageCount: result.pageCounts.isEmpty ? null : result.pageCounts.first);
  }
  return (await environment.sink.saveNew([out], [newName], besideEntry: entry)).single;
}
