// OWNER: HOM-28
//
// The merge screen (HOM plan §8.5 "pick 2+ PDFs (or images), order them, Merge"): the inputs as a
// list in merge order, reordered by their drag handles (or "Move up" / "Move down" for screen
// readers and keyboards), removable, with "Add files" (the app's picker of library PDFs and
// photos) and Merge. Encrypted PDFs ask for their password first. The result is a new file
// (`Report (merged).pdf`) next to the first Danaview folder input, or in `Imported`; the inputs are
// only read. Kit components only (rule 31), targets ≥ 44 px, no hover or press tints.

import 'dart:async';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import '../../card/viewer_bar.dart';
import '../viewer/pdf_password_sheet.dart';
import '../viewer/pdf_viewer.dart' show PdfPasswordPrompt;
import 'pdf_tool_launcher.dart';
import 'pdf_tool_progress.dart';
import 'pdf_tool_save.dart';

/// The merge screen.
class PdfMergeScreen extends StatefulWidget {
  /// A screen merging [items] over [environment].
  const PdfMergeScreen({
    super.key,
    required this.items,
    required this.environment,
    this.pickFirst = false,
    this.onClose,
    this.passwordPrompt,
  });

  /// The inputs in their first order.
  final List<PdfMergeItem> items;

  /// Documents, tools, the result sink and the picker.
  final PdfToolsEnvironment environment;

  /// Opens the picker at once ("Merge with…").
  final bool pickFirst;

  /// Closes the screen with the merged file, or null.
  final ValueChanged<PdfSavedFile?>? onClose;

  /// The password prompt (default [showPdfPasswordSheet]).
  final PdfPasswordPrompt? passwordPrompt;

  @override
  State<PdfMergeScreen> createState() => _PdfMergeScreenState();
}

class _PdfMergeScreenState extends State<PdfMergeScreen> {
  late List<PdfMergeItem> _items = [...widget.items];
  bool _busy = false;

  PdfToolsEnvironment get _env => widget.environment;

  @override
  void initState() {
    super.initState();
    if (widget.pickFirst && _env.pickMergeInputs != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_add());
      });
    }
  }

  Future<void> _add() async {
    final pick = _env.pickMergeInputs;
    if (pick == null || _busy) return;
    final more = await pick(context, List.unmodifiable(_items));
    if (!mounted || more.isEmpty) return;
    setState(() => _items = [..._items, ...more]);
  }

  void _move(int from, int to) {
    if (from == to || from < 0 || from >= _items.length) return;
    setState(() {
      final next = [..._items];
      final item = next.removeAt(from);
      next.insert(to.clamp(0, next.length), item);
      _items = next;
    });
  }

  void _remove(int index) => setState(() => _items = [..._items]..removeAt(index));

  /// Asks for the password of every encrypted PDF without one; false when the user cancelled.
  Future<bool> _unlockAll() async {
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (item.isImage || item.password != null) continue;
      final PdfProbe probe;
      try {
        probe = await _env.documents.probe(item.path);
      } on PdfException {
        continue; // the merge itself reports it
      }
      if (!probe.encrypted || !mounted) continue;
      String? accepted;
      Future<bool> attempt(String password) async {
        final doc = await _env.documents.open(item.path, password: password);
        unawaited(_env.documents.close(doc.handle).catchError((Object _) {}));
        if (doc.locked) return false;
        accepted = password;
        return true;
      }

      final prompt = widget.passwordPrompt ?? (context, attempt) => showPdfPasswordSheet(context, tryPassword: attempt);
      final ok = await prompt(context, attempt);
      final pw = accepted;
      if (!ok || pw == null || !mounted) return false;
      setState(() => _items[i] = item.withPassword(pw));
    }
    return true;
  }

  Future<void> _merge() async {
    if (_busy || _items.length < 2) return;
    setState(() => _busy = true);
    try {
      if (!await _unlockAll() || !mounted) return;
      final name = mergedPdfName(_items.first.displayName);
      final dir = await _env.sink.stagingDirectory();
      final out = stagingPathFor(dir, name);
      if (!mounted) return;
      final result = await runPdfTool(context, _env.tools.merge([for (final i in _items) i.input], outPath: out), title: 'Merging');
      if (result == null) return;
      final beside = [
        for (final i in _items)
          if (i.entryId case final id?) id
      ].firstOrNull;
      final saved = (await _env.sink.saveNew([out], [name], besideEntry: beside)).single;
      if (mounted) DanaviewToast.show(context, 'Saved as ${saved.displayName}', kind: DanaviewToastKind.success);
      widget.onClose?.call(saved);
    } on PdfException catch (e) {
      if (mounted) DanaviewToast.show(context, pdfToolErrorMessage(e), kind: DanaviewToastKind.error, icon: Icons.error_outline_rounded);
    } on Object {
      if (mounted) {
        DanaviewToast.show(context, 'The result couldn’t be saved. Try again.',
            kind: DanaviewToastKind.error, icon: Icons.error_outline_rounded);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _items.length;
    return Column(
      children: [
        DocumentTopBar(
          title: 'Merge into PDF',
          subtitle: count == 1 ? '1 file' : '$count files',
          onClose: () => widget.onClose?.call(null),
        ),
        Expanded(
          child: ClipRect(
            child: count == 0
                ? const DanaviewEmptyState(
                    icon: Icons.picture_as_pdf_outlined,
                    iconColor: DanaviewColors.textSecondary,
                    title: 'Nothing to merge',
                    message: 'Add PDFs or photos to merge them into one PDF.',
                  )
                : LayoutBuilder(
                    builder: (context, c) => ReorderableList(
                      key: const ValueKey('pdf-merge-list'),
                      padding: EdgeInsets.symmetric(horizontal: DanaviewSpacing.pageGutter(c.maxWidth), vertical: DanaviewSpacing.md),
                      itemCount: count,
                      onReorderItem: _move,
                      itemBuilder: (context, i) => _MergeRow(
                        key: ObjectKey(_items[i]),
                        index: i,
                        count: count,
                        item: _items[i],
                        enabled: !_busy,
                        onRemove: () => _remove(i),
                        onMoveUp: i > 0 ? () => _move(i, i - 1) : null,
                        onMoveDown: i < count - 1 ? () => _move(i, i + 1) : null,
                      ),
                    ),
                  ),
          ),
        ),
        DecoratedBox(
          decoration: const BoxDecoration(color: DanaviewColors.surface, border: Border(top: DanaviewBorders.hairline)),
          child: SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, c) => Padding(
                padding: EdgeInsets.symmetric(horizontal: DanaviewSpacing.pageGutter(c.maxWidth), vertical: DanaviewSpacing.sm),
                child: DanaviewButtonBar(
                  children: [
                    if (_env.pickMergeInputs != null)
                      DanaviewButton.secondary(
                        key: const ValueKey('pdf-merge-add'),
                        label: 'Add files',
                        icon: Icons.add_rounded,
                        semanticLabel: 'Add files',
                        onPressed: _busy ? null : () => unawaited(_add()),
                      ),
                    DanaviewButton.primary(
                      key: const ValueKey('pdf-merge-go'),
                      label: 'Merge',
                      icon: Icons.merge_rounded,
                      semanticLabel: 'Merge',
                      onPressed: !_busy && count >= 2 ? () => unawaited(_merge()) : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MergeRow extends StatelessWidget {
  const _MergeRow({
    super.key,
    required this.index,
    required this.count,
    required this.item,
    required this.enabled,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final int index;
  final int count;
  final PdfMergeItem item;
  final bool enabled;
  final VoidCallback onRemove;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: DanaviewSpacing.sm),
      child: DecoratedBox(
        decoration: DanaviewDepth.card(borderRadius: DanaviewRadius.controlAll, shadows: DanaviewShadows.none),
        child: Row(
          children: [
            Expanded(
              // One node: the name, its position and the move actions (screen readers, keyboards).
              child: Semantics(
                container: true,
                label: '${item.displayName}, ${index + 1} of $count',
                customSemanticsActions: {
                  if (onMoveUp != null) const CustomSemanticsAction(label: 'Move up'): onMoveUp!,
                  if (onMoveDown != null) const CustomSemanticsAction(label: 'Move down'): onMoveDown!,
                },
                child: ExcludeSemantics(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.sm),
                      child: Row(
                        children: [
                          DanaviewIconTile(item.isImage ? Icons.image_outlined : Icons.picture_as_pdf_outlined),
                          const SizedBox(width: DanaviewSpacing.md),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.rowTitle),
                                Text(
                                  '${index + 1} of $count · ${item.isImage ? 'Photo' : 'PDF'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: DanaviewTextStyles.footnote,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            DanaviewIconButton(
              icon: Icons.close_rounded,
              size: 44,
              iconSize: 18,
              semanticLabel: 'Remove ${item.displayName}',
              tooltip: 'Remove',
              onPressed: enabled ? onRemove : null,
            ),
            ReorderableDragStartListener(
              index: index,
              enabled: enabled,
              child: const ExcludeSemantics(
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(Icons.drag_indicator_rounded, size: 20, color: DanaviewColors.textSecondary),
                ),
              ),
            ),
            const SizedBox(width: DanaviewSpacing.xs),
          ],
        ),
      ),
    );
  }
}
