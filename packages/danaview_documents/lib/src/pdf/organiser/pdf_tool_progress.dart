// OWNER: HOM-28
//
// Running a PDF tool from the UI (HOM plan §8.5 "Large files: tools run off the UI thread with a
// progress bar and can be cancelled"): a job that takes longer than a moment shows a kit sheet
// with the progress bar, "n of m pages" and Cancel; the sheet closes when the job ends. Errors
// become calm sentences (never a name, a path or document text, rule 30).

import 'dart:async';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';

/// Jobs that end within this long show no sheet.
const Duration pdfToolProgressDelay = Duration(milliseconds: 250);

/// The sentence for a failed tool.
String pdfToolErrorMessage(Object error) {
  if (error is! PdfException) return 'That didn’t work. Try again.';
  return switch (error.code) {
    PdfErrorCode.passwordRequired => 'This PDF is password-protected. Unlock it and try again.',
    PdfErrorCode.unsupported => 'This PDF doesn’t allow changing its pages.',
    PdfErrorCode.damaged => 'This file couldn’t be read.',
    PdfErrorCode.noSpace => 'There isn’t enough space on this device.',
    PdfErrorCode.notFound => 'The file is no longer there.',
    PdfErrorCode.notSupportedOnDevice => 'PDF tools aren’t available on this device.',
    PdfErrorCode.cancelled => 'Cancelled.',
    _ => 'That didn’t work. Try again.',
  };
}

/// Waits for [job]; when it runs longer than [pdfToolProgressDelay] a sheet titled [title] shows
/// its progress with Cancel. Resolves to the result, or null when the user cancelled; other
/// failures are rethrown ([PdfException]).
Future<PdfToolResult?> runPdfTool(BuildContext context, PdfToolJob job, {required String title}) async {
  var finished = false;
  final done = job.result.whenComplete(() => finished = true);
  unawaited(done.then<void>((_) {}, onError: (Object _) {}));
  await Future.any<void>([done.then<void>((_) {}, onError: (Object _) {}), Future<void>.delayed(pdfToolProgressDelay)]);
  if (!finished && context.mounted) {
    final sheet = showDanaviewSheet<void>(
      context,
      title: title,
      isDismissible: false,
      showDragHandle: false,
      builder: (sheetContext) => PdfToolProgressBody(job: job, onEnded: () => Navigator.of(sheetContext).pop()),
    );
    unawaited(sheet);
  }
  try {
    return await done;
  } on PdfException catch (e) {
    if (e.code == PdfErrorCode.cancelled) return null;
    rethrow;
  }
}

/// The sheet body: the bar, the count and Cancel; calls [onEnded] once when the job ends.
class PdfToolProgressBody extends StatefulWidget {
  /// The progress of [job].
  const PdfToolProgressBody({super.key, required this.job, required this.onEnded});

  /// The running job.
  final PdfToolJob job;

  /// Closes the sheet.
  final VoidCallback onEnded;

  @override
  State<PdfToolProgressBody> createState() => _PdfToolProgressBodyState();
}

class _PdfToolProgressBodyState extends State<PdfToolProgressBody> {
  PdfToolProgress? _last;
  StreamSubscription<PdfToolProgress>? _sub;
  bool _cancelling = false;
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.job.progress.listen((p) {
      if (mounted) setState(() => _last = p);
    });
    widget.job.result.then<void>((_) => _end(), onError: (Object _) => _end());
  }

  void _end() {
    if (_ended || !mounted) return;
    _ended = true;
    widget.onEnded();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _last;
    final label = _cancelling
        ? 'Cancelling…'
        : p == null || p.pagesTotal <= 0
            ? 'Working…'
            : '${p.pagesDone.clamp(0, p.pagesTotal)} of ${p.pagesTotal} pages';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: DanaviewSpacing.sm),
        DanaviewProgressBar(value: p?.fraction, semanticLabel: 'Progress'),
        const SizedBox(height: DanaviewSpacing.sm),
        Semantics(liveRegion: true, child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.bodySecondary)),
        const SizedBox(height: DanaviewSpacing.lg),
        DanaviewButton.secondary(
          key: const ValueKey('pdf-tool-cancel'),
          label: 'Cancel',
          expand: true,
          semanticLabel: 'Cancel',
          onPressed: _cancelling
              ? null
              : () {
                  setState(() => _cancelling = true);
                  unawaited(widget.job.cancel());
                },
        ),
      ],
    );
  }
}
