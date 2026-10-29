// OWNER: HOM-30
//
// The sign toolbar under the PDF pages (HOM plan §8.5; Cinema B, DESIGN_SYSTEM §7–§8): the saved
// signatures wrapped in a strip (the chosen one has a check), "New" and "Saved signatures", then
// one line saying what a tap does next, with Delete for a selected signature. Every control is at
// least 44 pt and labelled for screen readers, without hover or press tints and without accent
// outlines. Nothing here logs a path (rule 30).

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import '../../signatures/signature_list.dart';
import '../../signatures/signature_store.dart';
import '../annotate/pdf_annotate_toolbar.dart' show pdfAnnotateWideToolbar;
import 'pdf_sign_model.dart';

/// What the sign toolbar says the next tap does.
String pdfSignHint(PdfSignModel model) {
  if (model.signature == null) return 'Choose or create a signature';
  if (model.selectedId != null) return 'Drag to move it, or drag the round handle to resize';
  if (model.items.isEmpty) return 'Tap the page where the signature goes';
  return 'Tap a signature to move it, or tap a page to add another';
}

/// The toolbar of a sign session.
class PdfSignToolbar extends StatelessWidget {
  /// The toolbar of [model] over [store].
  const PdfSignToolbar({
    super.key,
    required this.model,
    required this.store,
    required this.onNew,
    required this.onManage,
    required this.onDeleteSelected,
    this.enabled = true,
  });

  /// The session.
  final PdfSignModel model;

  /// The saved signatures.
  final SignatureStore store;

  /// "New signature".
  final VoidCallback onNew;

  /// "Saved signatures".
  final VoidCallback onManage;

  /// Deletes the selected signature from the page.
  final VoidCallback onDeleteSelected;

  /// False while a save runs.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: DanaviewColors.surface, border: Border(top: DanaviewBorders.hairline)),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= pdfAnnotateWideToolbar;
            final gutter = wide ? DanaviewSpacing.pageGutter(c.maxWidth) : DanaviewSpacing.sm;
            return Padding(
              padding: EdgeInsets.fromLTRB(gutter, DanaviewSpacing.xs, gutter, DanaviewSpacing.xs),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SignatureListBuilder(
                    store: store,
                    builder: (context, list) => SignatureStrip(
                      key: const ValueKey('pdf-sign-strip'),
                      signatures: list ?? const [],
                      selected: model.signature,
                      enabled: enabled,
                      onSelect: (s) => model.signature = s,
                      onNew: onNew,
                      onManage: onManage,
                    ),
                  ),
                  const SizedBox(height: DanaviewSpacing.xxs),
                  Wrap(
                    spacing: DanaviewSpacing.xs,
                    runSpacing: DanaviewSpacing.xxs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (model.selectedId != null)
                        wide
                            ? DanaviewButton.secondary(
                                key: const ValueKey('pdf-sign-delete'),
                                label: 'Delete',
                                icon: Icons.delete_outline_rounded,
                                size: DanaviewButtonSize.sm,
                                semanticLabel: 'Delete signature from the page',
                                onPressed: enabled ? onDeleteSelected : null,
                              )
                            : DanaviewIconButton.toolbar(
                                key: const ValueKey('pdf-sign-delete'),
                                icon: Icons.delete_outline_rounded,
                                tooltip: 'Delete',
                                semanticLabel: 'Delete signature from the page',
                                onPressed: enabled ? onDeleteSelected : null,
                              ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: DanaviewSpacing.minTapTarget),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            widthFactor: 1,
                            child: Text(
                              pdfSignHint(model),
                              key: const ValueKey('pdf-sign-hint'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: DanaviewTextStyles.footnote.copyWith(color: DanaviewColors.textSecondary),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
