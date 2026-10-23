// OWNER: HOM-26
//
// The Quick Look viewer (HOM plan §8.4, ARCH §3 "Office / other files" and "Text / CSV", V2-120,
// G-R3): Word, Excel, PowerPoint, text, CSV and other types on iOS and macOS open in the system's
// Quick Look with editing disabled (QLPreviewController / a QLPreviewView sheet, over read-only
// copies; danaview_library_native). The Home registers [quickLookViewerBuilder] and
// [quickLookProbe] with HOM-23's DocumentViewer, which never imports native viewers itself: the
// probe sends types Quick Look can't preview on to the next candidate (the in-app text viewer, the
// file card), and a preview that fails to open calls `ViewerContext.unavailable` so the host falls
// back the same way.
//
// While the native preview is up, this screen sits underneath it: the document's top bar and its
// type tile. When the preview is dismissed the viewer closes (or, without a close callback, offers
// "Show preview again"). Kit components only, dark UI, hairline borders, targets ≥ 44 px, no
// overflow at 280–1280 px and text scale 0.85–1.35 (ARCH §1.4). Nothing logs names or paths (rule
// 30).

import 'dart:async';

import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import '../card/document_format.dart';
import '../card/viewer_bar.dart';
import '../router/document_viewer.dart';
import '../router/viewer_file.dart';

/// Quick Look as the viewers need it; [NativeQuickLookPort] is the plugin's, tests use fakes.
abstract interface class QuickLookPort {
  /// Whether Quick Look can preview [file] on this device.
  Future<bool> canPreview(ViewerFile file);

  /// Shows [files] from [initialIndex], editing disabled; completes when the preview is dismissed.
  Future<void> present(List<ViewerFile> files, {int initialIndex = 0});
}

/// [QuickLookPort] over danaview_library_native's [NativeQuickLook].
final class NativeQuickLookPort implements QuickLookPort {
  /// The port of [quickLook] (the default engine's when null).
  NativeQuickLookPort([NativeQuickLook? quickLook]) : _quickLook = quickLook ?? NativeQuickLook();

  final NativeQuickLook _quickLook;

  static NativeOutFile _out(ViewerFile f) => NativeOutFile(path: f.path, displayName: f.displayName, mimeType: f.mime, uti: f.uti);

  @override
  Future<bool> canPreview(ViewerFile file) => _quickLook.canPreview(_out(file));

  @override
  Future<void> present(List<ViewerFile> files, {int initialIndex = 0}) =>
      _quickLook.present(files.map(_out).toList(), initialIndex: initialIndex);
}

/// The router probe of the Quick Look viewer over [port]. Never throws: an error (a missing file,
/// no Quick Look on this platform) counts as "can't".
Future<bool> Function(ViewerFile file) quickLookProbe(QuickLookPort port) => (file) async {
      try {
        return await port.canPreview(file);
      } on Object {
        return false;
      }
    };

/// The [ViewerBuilder] of the Quick Look viewer over [port].
ViewerBuilder quickLookViewerBuilder(QuickLookPort port) => (context, viewer) => QuickLookViewer(
      file: viewer.file,
      port: port,
      onClose: viewer.onClose,
      onUnavailable: viewer.unavailable,
    );

/// Opens [file] in Quick Look and stands under the native preview.
class QuickLookViewer extends StatefulWidget {
  /// A viewer of [file] over [port].
  const QuickLookViewer({super.key, required this.file, required this.port, this.onClose, this.onUnavailable});

  /// The file.
  final ViewerFile file;

  /// Quick Look.
  final QuickLookPort port;

  /// Closes the viewer; called when the preview is dismissed. Without it the screen offers to
  /// show the preview again.
  final VoidCallback? onClose;

  /// The preview could not open; the host moves on to the next candidate.
  final VoidCallback? onUnavailable;

  @override
  State<QuickLookViewer> createState() => _QuickLookViewerState();
}

class _QuickLookViewerState extends State<QuickLookViewer> {
  bool _showing = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    // After the first frame, so the host's route is on screen under the native preview.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_present()));
  }

  @override
  void didUpdateWidget(QuickLookViewer old) {
    super.didUpdateWidget(old);
    if (old.file != widget.file && !_showing) unawaited(_present());
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _present() async {
    if (!mounted || _showing) return;
    final generation = ++_generation;
    setState(() => _showing = true);
    try {
      await widget.port.present([widget.file]);
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() => _showing = false);
      widget.onUnavailable?.call();
      return;
    }
    if (!mounted || generation != _generation) return;
    setState(() => _showing = false);
    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final closed = !_showing && widget.onClose == null;
    return ColoredBox(
      color: DanaviewColors.background,
      child: Column(
        children: [
          DocumentTopBar(title: file.displayName, subtitle: documentTypeLabel(file), onClose: widget.onClose),
          Expanded(
            child: ClipRect(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.xl, DanaviewSpacing.lg, DanaviewSpacing.xl),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 88,
                          height: 88,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: DanaviewColors.surfaceElevated,
                            borderRadius: DanaviewRadius.xlAll,
                            border: DanaviewBorders.all,
                          ),
                          child: Icon(documentIcon(file), size: 44, color: documentAccent(file), semanticLabel: documentTypeLabel(file)),
                        ),
                        const SizedBox(height: DanaviewSpacing.lg),
                        Text(
                          closed ? 'Preview closed.' : 'Showing the preview.',
                          textAlign: TextAlign.center,
                          style: DanaviewTextStyles.bodySecondary,
                        ),
                        if (closed) ...[
                          const SizedBox(height: DanaviewSpacing.md),
                          DanaviewButton.tonal(
                            label: 'Show preview again',
                            icon: Icons.visibility_outlined,
                            size: DanaviewButtonSize.lg,
                            expand: true,
                            semanticLabel: 'Show preview again',
                            onPressed: () => unawaited(_present()),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
