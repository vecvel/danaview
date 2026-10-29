// OWNER: HOM-31
//
// The compress sheet (HOM plan §8.5 "presets High / Medium / Small, showing the before and after
// size"), Cinema B kit components only: the size now, the three presets in a grouped list with
// each one's estimated ("about 3.1 MB") or measured size, one primary Compress button, a
// cancelable progress bar while it runs, then the saved name with the before → after sizes and
// the saving, or a plain "not smaller, nothing saved". Its own sheet; HOM-28's page organiser is
// separate. Nothing here logs a path, a name or a password (rule 30).

import 'dart:async';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import '../../card/document_format.dart';
import 'pdf_compress_controller.dart';

/// The title of a preset.
String compressPresetTitle(PdfCompressPreset preset) => switch (preset) {
      PdfCompressPreset.high => 'High quality',
      PdfCompressPreset.medium => 'Medium',
      PdfCompressPreset.small => 'Small file',
    };

/// What a preset is for.
String compressPresetDescription(PdfCompressPreset preset) => switch (preset) {
      PdfCompressPreset.high => 'Sharpest pictures, modest saving',
      PdfCompressPreset.medium => 'Good on screens and for email',
      PdfCompressPreset.small => 'Smallest file, softer pictures',
    };

/// Shows the compress sheet for the PDF at [path] named [displayName]: [engine] compresses,
/// [save] stores the new file. [password] is the password an encrypted file was opened with.
Future<void> showPdfCompressSheet(
  BuildContext context, {
  required String path,
  required String displayName,
  required PdfCompressEngine engine,
  required PdfCompressSave save,
  String? password,
  String? tempDirectory,
}) =>
    showDanaviewSheet<void>(
      context,
      title: 'Compress PDF',
      builder: (sheetContext) => PdfCompressPanel(
        controller: () => PdfCompressController(
          engine: engine,
          path: path,
          displayName: displayName,
          save: save,
          password: password,
          tempDirectory: tempDirectory,
        ),
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    );

/// The body of the compress sheet; owns the controller [controller] creates.
class PdfCompressPanel extends StatefulWidget {
  /// A panel over a new controller from [controller].
  const PdfCompressPanel({super.key, required this.controller, this.onClose});

  /// Creates the controller (called once).
  final PdfCompressController Function() controller;

  /// Closes the sheet (Done).
  final VoidCallback? onClose;

  @override
  State<PdfCompressPanel> createState() => _PdfCompressPanelState();
}

class _PdfCompressPanelState extends State<PdfCompressPanel> {
  late final PdfCompressController _c = widget.controller();

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    unawaited(_c.load());
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _sizeLabel(PdfCompressPreset preset) {
    final size = _c.sizeOf(preset);
    if (size == null) return _c.estimating ? '…' : '';
    return _c.isActual(preset) ? formatByteSize(size) : 'about ${formatByteSize(size)}';
  }

  @override
  Widget build(BuildContext context) {
    final running = _c.phase == PdfCompressPhase.running;
    final before = _c.beforeBytes;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_c.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.headline),
          const SizedBox(height: DanaviewSpacing.xs),
          Text(
            before == null ? 'Size now: …' : 'Size now: ${formatByteSize(before)}',
            key: const ValueKey('compress-before'),
            style: DanaviewTextStyles.bodySecondary.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewGroupedList(
            children: [
              for (final preset in PdfCompressPreset.values)
                DanaviewListTile(
                  key: ValueKey('compress-preset-${preset.name}'),
                  title: compressPresetTitle(preset),
                  subtitle: compressPresetDescription(preset),
                  subtitleMaxLines: 2,
                  value: _sizeLabel(preset),
                  selected: _c.preset == preset,
                  enabled: !running,
                  borderRadius: BorderRadius.zero,
                  semanticLabel: '${compressPresetTitle(preset)}, ${compressPresetDescription(preset)}'
                      '${_sizeLabel(preset).isEmpty || _sizeLabel(preset) == '…' ? '' : ', ${_sizeLabel(preset)}'}',
                  onTap: () => _c.select(preset),
                ),
            ],
          ),
          const SizedBox(height: DanaviewSpacing.lg),
          ..._footer(),
        ],
      ),
    );
  }

  List<Widget> _footer() {
    switch (_c.phase) {
      case PdfCompressPhase.idle:
        return [
          if (_c.notice case final notice?) ...[
            _Status(icon: Icons.info_outline_rounded, color: DanaviewColors.textSecondary, text: notice),
            const SizedBox(height: DanaviewSpacing.md),
          ],
          DanaviewButton.primary(
            key: const ValueKey('compress-run'),
            label: 'Compress',
            semanticLabel: 'Compress with ${compressPresetTitle(_c.preset)}',
            icon: Icons.compress_rounded,
            expand: true,
            onPressed: () => unawaited(_c.run()),
          ),
        ];
      case PdfCompressPhase.running:
        final percent = (_c.progress * 100).round();
        return [
          Text(
            _c.cancelling ? 'Cancelling…' : 'Compressing… $percent %',
            key: const ValueKey('compress-progress-label'),
            style: DanaviewTextStyles.bodySecondary.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          const SizedBox(height: DanaviewSpacing.sm),
          DanaviewProgressBar(key: const ValueKey('compress-progress'), value: _c.progress, semanticLabel: 'Compressing'),
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewButton.secondary(
            key: const ValueKey('compress-cancel'),
            label: 'Cancel',
            semanticLabel: 'Cancel compressing',
            expand: true,
            onPressed: _c.cancelling ? null : () => unawaited(_c.cancel()),
          ),
        ];
      case PdfCompressPhase.done:
        final before = _c.beforeBytes, after = _c.afterBytes;
        return [
          _Status(
            key: const ValueKey('compress-done'),
            icon: Icons.check_circle_rounded,
            color: DanaviewColors.success,
            text: 'Saved as “${_c.savedName ?? compressedPdfName(_c.displayName)}”',
          ),
          if (before != null && after != null) ...[
            const SizedBox(height: DanaviewSpacing.xs),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text(
                '${formatByteSize(before)} → ${formatByteSize(after)} · ${_c.savingPercent ?? 0} % smaller',
                key: const ValueKey('compress-saving'),
                style: DanaviewTextStyles.bodySecondary.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ],
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewButton.primary(
            key: const ValueKey('compress-close'),
            label: 'Done',
            semanticLabel: 'Done',
            expand: true,
            onPressed: widget.onClose,
          ),
        ];
      case PdfCompressPhase.notSmaller:
        final before = _c.beforeBytes, after = _c.afterBytes;
        return [
          _Status(
            key: const ValueKey('compress-not-smaller'),
            icon: Icons.info_outline_rounded,
            color: DanaviewColors.textSecondary,
            text: 'This PDF is already as small as ${compressPresetTitle(_c.preset)} can make it. Nothing was saved.',
          ),
          if (before != null && after != null) ...[
            const SizedBox(height: DanaviewSpacing.xs),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text(
                'The result was ${formatByteSize(after)}; the file is ${formatByteSize(before)} now.',
                style: DanaviewTextStyles.bodySecondary,
              ),
            ),
          ],
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewButton.secondary(
            key: const ValueKey('compress-again'),
            label: 'Try another preset',
            semanticLabel: 'Try another preset',
            expand: true,
            onPressed: _c.reset,
          ),
        ];
      case PdfCompressPhase.error:
        return [
          _Status(
            key: const ValueKey('compress-error'),
            icon: Icons.error_outline_rounded,
            color: DanaviewColors.error,
            text: _c.error ?? 'That didn’t work. Try again.',
          ),
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewButton.secondary(
            key: const ValueKey('compress-retry'),
            label: 'Try again',
            semanticLabel: 'Try again',
            expand: true,
            onPressed: _c.reset,
          ),
        ];
    }
  }
}

/// A status icon plus words (DESIGN_SYSTEM §2.3: never a coloured border or fill).
class _Status extends StatelessWidget {
  const _Status({super.key, required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 20, color: color)),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: DanaviewTextStyles.body)),
          ],
        ),
      );
}
