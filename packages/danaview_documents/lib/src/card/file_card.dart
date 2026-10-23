// OWNER: HOM-23
//
// The file card (HOM plan §8.4, D-98h, D-98k; ARCH §3): what a file shows when no viewer on this
// platform can display it (Office on Android, PDFs on Windows and Linux, other types, a password
// PDF older Android can't open): the type icon, the name, size and dates, and "Open in another
// app" and Share where the platform has them (FileOutPort capabilities). Kit components only, dark
// UI, hairline borders, no overflow at 280–1280 px and text scale 0.85–1.35 (ARCH §1.4).

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import '../router/viewer_file.dart';
import 'document_format.dart';
import 'document_out.dart';
import 'viewer_bar.dart';

/// The file card of [file].
class FileCard extends StatelessWidget {
  /// A card for [file]; [fileOut] supplies "Open in another app" and Share (hidden without it or
  /// when the platform lacks them); [onClose] shows the top bar's back button.
  const FileCard({super.key, required this.file, this.fileOut, this.onClose, this.message, this.showTopBar = true});

  /// The file.
  final ViewerFile file;

  /// Getting files out; null hides both actions.
  final FileOutPort? fileOut;

  /// Closes the viewer.
  final VoidCallback? onClose;

  /// Why the card is shown (e.g. "This file can't be previewed on this device"), when it helps.
  final String? message;

  /// Whether the card draws its own top bar.
  final bool showTopBar;

  @override
  Widget build(BuildContext context) {
    final caps = fileOut?.capabilities ?? FileOutCapabilities.none;
    final port = fileOut;
    final rows = <(String, String)>[
      ('Type', documentTypeLabel(file)),
      if (file.sizeBytes != null) ('Size', formatByteSize(file.sizeBytes!)),
      if (file.pageCount != null) ('Pages', formatCount(file.pageCount!)),
      if (file.addedAt != null) ('Added', formatDocumentDate(file.addedAt!)),
      if (file.modifiedAt != null) ('Modified', formatDocumentDate(file.modifiedAt!)),
    ];
    final accent = documentAccent(file);

    final body = SingleChildScrollView(
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
                child: Icon(documentIcon(file), size: 44, color: accent, semanticLabel: documentTypeLabel(file)),
              ),
              const SizedBox(height: DanaviewSpacing.lg),
              Text(
                file.displayName,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: DanaviewTextStyles.headline,
              ),
              if (message != null) ...[
                const SizedBox(height: DanaviewSpacing.sm),
                Text(message!, textAlign: TextAlign.center, style: DanaviewTextStyles.bodySecondary),
              ],
              const SizedBox(height: DanaviewSpacing.lg),
              DecoratedBox(
                decoration: const BoxDecoration(
                  color: DanaviewColors.surface,
                  borderRadius: DanaviewRadius.lgAll,
                  border: DanaviewBorders.all,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.xs),
                  child: Column(
                    children: [
                      for (var i = 0; i < rows.length; i++) ...[
                        if (i > 0) const SizedBox(height: DanaviewBorders.width, child: ColoredBox(color: DanaviewColors.hairlineSubtle)),
                        _InfoRow(label: rows[i].$1, value: rows[i].$2),
                      ],
                    ],
                  ),
                ),
              ),
              if (port != null && (caps.canOpenIn || caps.canShare)) ...[
                const SizedBox(height: DanaviewSpacing.lg),
                if (caps.canOpenIn)
                  Builder(
                    builder: (context) => DanaviewButton.primary(
                      label: 'Open in another app',
                      icon: Icons.open_in_new_rounded,
                      size: DanaviewButtonSize.lg,
                      expand: true,
                      semanticLabel: 'Open in another app',
                      onPressed: () => openInAnotherApp(context, port, file),
                    ),
                  ),
                if (caps.canOpenIn && caps.canShare) const SizedBox(height: DanaviewSpacing.sm),
                if (caps.canShare)
                  Builder(
                    builder: (context) => DanaviewButton.secondary(
                      label: 'Share',
                      icon: Icons.ios_share_rounded,
                      size: DanaviewButtonSize.lg,
                      expand: true,
                      semanticLabel: 'Share',
                      onPressed: () => shareDocument(context, port, file),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );

    return ColoredBox(
      color: DanaviewColors.background,
      child: Column(
        children: [
          if (showTopBar) DocumentTopBar(title: file.displayName, subtitle: documentTypeLabel(file), onClose: onClose),
          Expanded(child: ClipRect(child: body)),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.sm + 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: DanaviewTextStyles.bodySecondary),
            const SizedBox(width: DanaviewSpacing.md),
            Expanded(
              child: Text(value, textAlign: TextAlign.end, maxLines: 2, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.body),
            ),
          ],
        ),
      ),
    );
  }
}
