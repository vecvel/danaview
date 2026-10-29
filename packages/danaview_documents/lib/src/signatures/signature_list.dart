// OWNER: HOM-30
//
// Showing, choosing and deleting saved signatures (HOM plan §8.5 "saved signatures … the user can
// delete them"): a signature tile (the PNG on paper), the strip of the sign toolbar (every saved
// signature, wrapped, then "New"; the chosen one has a check), the "Saved signatures" sheet (use one
// again, delete one, or delete all; a signature placed in the open PDF can't be deleted until it is
// removed from the page), and the Settings › Privacy rows (how many are saved, "Delete all"). Cinema
// B kit only, 44 pt targets, labels for screen readers, no hover or press tints. Nothing here logs a
// path or an image (rule 30).

import 'dart:async';
import 'dart:io';

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import 'signature_pad.dart' show signaturePaperColor;
import 'signature_store.dart';

/// The spoken name of [s] at [index] (1-based) in the list.
String signatureLabel(SavedSignature s, int index) => switch (s.kind) {
      SignatureKind.drawn => 'Drawn signature $index',
      SignatureKind.typed => 'Typed signature $index',
      SignatureKind.imported => 'Imported signature $index',
    };

/// A saved signature on paper, [width] × [height].
class SignatureTile extends StatelessWidget {
  /// The tile of [signature].
  const SignatureTile({super.key, required this.signature, this.width = 112, this.height = 48, this.selected = false});

  /// The signature.
  final SavedSignature signature;

  /// Size.
  final double width;

  /// Size.
  final double height;

  /// Marked with a check.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: const ShapeDecoration(
                color: signaturePaperColor,
                shape: RoundedSuperellipseBorder(borderRadius: DanaviewRadius.smAll, side: DanaviewBorders.hairline),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs, vertical: DanaviewSpacing.xxs),
                child: Image.file(
                  File(signature.path),
                  fit: BoxFit.contain,
                  excludeFromSemantics: true,
                  errorBuilder: (context, _, __) => const Icon(Icons.broken_image_outlined, size: 18, color: Color(0xFF8A8A8E)),
                ),
              ),
            ),
          ),
          if (selected)
            const Positioned(
              right: 3,
              top: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Color(0xFF1C1C1E), shape: BoxShape.circle),
                child: Padding(padding: EdgeInsets.all(1), child: Icon(Icons.check_rounded, size: 14, color: Color(0xFFFFFFFF))),
              ),
            ),
        ],
      ),
    );
  }
}

/// The saved signatures of [store], reloaded when it changes.
class SignatureListBuilder extends StatefulWidget {
  /// Builds [builder] with the list (null while loading).
  const SignatureListBuilder({super.key, required this.store, required this.builder});

  /// The store.
  final SignatureStore store;

  /// The child.
  final Widget Function(BuildContext context, List<SavedSignature>? signatures) builder;

  @override
  State<SignatureListBuilder> createState() => _SignatureListBuilderState();
}

class _SignatureListBuilderState extends State<SignatureListBuilder> {
  List<SavedSignature>? _list;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(SignatureListBuilder old) {
    super.didUpdateWidget(old);
    if (old.store != widget.store) {
      old.store.removeListener(_load);
      widget.store.addListener(_load);
      _load();
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_load);
    super.dispose();
  }

  void _load() {
    final g = ++_generation;
    widget.store.list().then((l) {
      if (mounted && g == _generation) setState(() => _list = l);
    }, onError: (Object _) {
      if (mounted && g == _generation) setState(() => _list = const []);
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _list);
}

/// The sign toolbar's strip: "New", "Saved signatures" (when there are any), then every saved
/// signature (the [selected] one checked); one row that scrolls sideways, "New" always in reach.
class SignatureStrip extends StatelessWidget {
  /// The strip over [signatures].
  const SignatureStrip({
    super.key,
    required this.signatures,
    required this.selected,
    required this.onSelect,
    required this.onNew,
    required this.onManage,
    this.enabled = true,
  });

  /// Saved signatures, newest first.
  final List<SavedSignature> signatures;

  /// The chosen one.
  final SavedSignature? selected;

  /// Chooses one.
  final ValueChanged<SavedSignature> onSelect;

  /// "New signature".
  final VoidCallback onNew;

  /// "Saved signatures" (delete).
  final VoidCallback onManage;

  /// False while saving.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // One row that scrolls sideways inside the toolbar, so ten signatures never push the pages away.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (i, w) in _children().indexed) ...[
            if (i > 0) const SizedBox(width: DanaviewSpacing.xs),
            w,
          ],
        ],
      ),
    );
  }

  List<Widget> _children() => [
        DanaviewButton.secondary(
          key: const ValueKey('sign-new-signature'),
          label: 'New',
          icon: Icons.add_rounded,
          size: DanaviewButtonSize.sm,
          semanticLabel: 'New signature',
          onPressed: enabled ? onNew : null,
        ),
        if (signatures.isNotEmpty)
          DanaviewIconButton.toolbar(
            key: const ValueKey('sign-manage-signatures'),
            icon: Icons.tune_rounded,
            tooltip: 'Saved signatures',
            semanticLabel: 'Saved signatures',
            onPressed: enabled ? onManage : null,
          ),
        for (final (i, s) in signatures.indexed)
          DanaviewPressable.builder(
            key: ValueKey('sign-signature-${s.id}'),
            onTap: enabled ? () => onSelect(s) : null,
            enabled: enabled,
            selected: selected?.id == s.id,
            semanticLabel: signatureLabel(s, i + 1),
            builder: (context, state) => Container(
              constraints: const BoxConstraints(minHeight: DanaviewSpacing.minTapTarget, minWidth: DanaviewSpacing.minTapTarget),
              alignment: Alignment.center,
              foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused, borderRadius: DanaviewRadius.smAll),
              child: SignatureTile(signature: s, width: 104, height: 44, selected: selected?.id == s.id),
            ),
          ),
      ];
}

/// Asks before deleting every saved signature; true when deleted.
Future<bool> confirmDeleteAllSignatures(BuildContext context, SignatureStore store) async {
  final ok = await showDanaviewConfirm(
    context,
    title: 'Delete all saved signatures?',
    message: 'They are removed from this device. PDFs you already signed keep their signatures.',
    confirmLabel: 'Delete all',
    destructive: true,
  );
  if (!ok) return false;
  await store.deleteAll();
  return true;
}

/// The "Saved signatures" sheet: use one again or delete it ([inUse] paths can't be deleted while
/// they are placed in the open PDF). Resolves to the signature chosen to use, or null.
Future<SavedSignature?> showSavedSignaturesSheet(BuildContext context, {required SignatureStore store, Set<String> inUse = const {}}) =>
    showDanaviewSheet<SavedSignature>(
      context,
      title: 'Saved signatures',
      builder: (sheetContext) => SavedSignaturesPanel(store: store, inUse: inUse, onUse: (s) => Navigator.of(sheetContext).pop(s)),
    );

/// The body of the "Saved signatures" sheet.
class SavedSignaturesPanel extends StatelessWidget {
  /// The panel over [store].
  const SavedSignaturesPanel({super.key, required this.store, required this.onUse, this.inUse = const {}});

  /// The store.
  final SignatureStore store;

  /// Uses one.
  final ValueChanged<SavedSignature> onUse;

  /// Paths placed in the open PDF.
  final Set<String> inUse;

  @override
  Widget build(BuildContext context) {
    return SignatureListBuilder(
      store: store,
      builder: (context, list) {
        if (list == null) return const SizedBox(height: 120, child: Center(child: DanaviewSpinner()));
        if (list.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.lg),
            child: Text('No saved signatures.', key: const ValueKey('saved-signatures-empty'), style: DanaviewTextStyles.bodySecondary),
          );
        }
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DanaviewGroupedList(
                dividerIndent: DanaviewSpacing.md,
                children: [
                  for (final (i, s) in list.indexed)
                    DanaviewListTile(
                      key: ValueKey('saved-signature-${s.id}'),
                      leading: SignatureTile(signature: s, width: 96, height: 40),
                      title: signatureLabel(s, i + 1),
                      subtitle: inUse.contains(s.path) ? 'On this PDF' : null,
                      semanticLabel: 'Use ${signatureLabel(s, i + 1)}',
                      onTap: () => onUse(s),
                      trailing: DanaviewIconButton(
                        key: ValueKey('saved-signature-delete-${s.id}'),
                        icon: Icons.delete_outline_rounded,
                        size: 44,
                        semanticLabel: 'Delete ${signatureLabel(s, i + 1)}',
                        tooltip: 'Delete',
                        onPressed: inUse.contains(s.path) ? null : () => unawaited(store.delete(s.id)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: DanaviewSpacing.sm),
              Text(
                'Saved signatures stay on this device and aren’t backed up. Up to ${SignatureStore.maxCount}.',
                style: DanaviewTextStyles.footnote.copyWith(color: DanaviewColors.textSecondary),
              ),
              if (inUse.isEmpty) ...[
                const SizedBox(height: DanaviewSpacing.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DanaviewButton.destructive(
                    key: const ValueKey('saved-signatures-delete-all'),
                    label: 'Delete all',
                    icon: Icons.delete_sweep_outlined,
                    semanticLabel: 'Delete all saved signatures',
                    onPressed: () => unawaited(confirmDeleteAllSignatures(context, store)),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Settings › Privacy: how many signatures are saved on this device, and "Delete all".
class SavedSignaturesSettingsSection extends StatelessWidget {
  /// The rows of [store].
  const SavedSignaturesSettingsSection({super.key, required this.store});

  /// The store.
  final SignatureStore store;

  @override
  Widget build(BuildContext context) {
    return SignatureListBuilder(
      store: store,
      builder: (context, list) {
        final n = list?.length;
        final subtitle = switch (n) {
          null => '…',
          0 => 'None saved',
          1 => '1 saved on this device',
          _ => '$n saved on this device',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: DanaviewSpacing.md),
            DanaviewGroupedList(
              children: [
                DanaviewListTile(
                  key: const ValueKey('privacy-saved-signatures'),
                  leading: const DanaviewIconTile(Icons.history_edu_rounded, size: 40),
                  title: 'Saved signatures',
                  subtitle: subtitle,
                  semanticLabel: 'Saved signatures, $subtitle',
                ),
              ],
            ),
            const SizedBox(height: DanaviewSpacing.sm),
            // Under the row (not beside it), so it never squeezes the text on narrow screens.
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: DanaviewButton.destructive(
                key: const ValueKey('privacy-saved-signatures-delete-all'),
                label: 'Delete all saved signatures',
                icon: Icons.delete_sweep_outlined,
                size: DanaviewButtonSize.sm,
                semanticLabel: 'Delete all saved signatures',
                onPressed: (n ?? 0) == 0
                    ? null
                    : () async {
                        if (await confirmDeleteAllSignatures(context, store) && context.mounted) {
                          DanaviewToast.show(context, 'Saved signatures deleted');
                        }
                      },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(DanaviewSpacing.xs, DanaviewSpacing.sm, DanaviewSpacing.xs, 0),
              child: Text(
                'Signatures you save to sign PDFs stay on this device, aren’t backed up and never leave Danaview.',
                style: DanaviewTextStyles.caption,
              ),
            ),
          ],
        );
      },
    );
  }
}
