// OWNER: HOM-23
//
// "Open in another app" and Share from the document viewers and the file card (HOM plan §8.3,
// §8.4) through the library's FileOutPort (implemented by the Home over danaview_library_native,
// HOM-22). The other app gets a temporary read-only copy; the library file never changes. Failures
// become a toast; nothing logs a name or a path (rule 30).

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';

import '../router/viewer_file.dart';

/// The popover anchor of the widget at [context] (iPad and macOS place sheets next to it).
OutAnchor? outAnchorOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  final o = box.localToGlobal(Offset.zero);
  return OutAnchor(o.dx, o.dy, box.size.width, box.size.height);
}

String _failureText(FileOutError error) => switch (error) {
      FileOutError.unsupported => 'Not available on this device',
      FileOutError.denied => 'Danaview isn\'t allowed to do that',
      FileOutError.missing => 'This file is no longer available',
      FileOutError.busy => 'Close the open sheet first',
      FileOutError.failed => 'Something went wrong. Try again.',
    };

/// Offers [file] to another app through [port]; shows a toast when no app takes it or it fails.
Future<void> openInAnotherApp(BuildContext context, FileOutPort port, ViewerFile file) async {
  final anchor = outAnchorOf(context);
  try {
    final shown = await port.openIn(file.outFile, anchor: anchor);
    if (!shown && context.mounted) DanaviewToast.show(context, 'No app on this device opens this file');
  } on FileOutException catch (e) {
    if (context.mounted) DanaviewToast.show(context, _failureText(e.error), kind: DanaviewToastKind.error);
  } on Object {
    if (context.mounted) DanaviewToast.show(context, _failureText(FileOutError.failed), kind: DanaviewToastKind.error);
  }
}

/// Shows the share sheet for [file] through [port]; shows a toast when it fails.
Future<void> shareDocument(BuildContext context, FileOutPort port, ViewerFile file) async {
  final anchor = outAnchorOf(context);
  try {
    await port.share([file.outFile], anchor: anchor);
  } on FileOutException catch (e) {
    if (context.mounted) DanaviewToast.show(context, _failureText(e.error), kind: DanaviewToastKind.error);
  } on Object {
    if (context.mounted) DanaviewToast.show(context, _failureText(FileOutError.failed), kind: DanaviewToastKind.error);
  }
}
