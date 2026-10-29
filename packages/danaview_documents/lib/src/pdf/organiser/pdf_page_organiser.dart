// OWNER: HOM-28
//
// The page organiser (HOM plan §8.5, D-98j): every page of a PDF as a thumbnail, selectable and
// draggable, with a toolbar to select all, rotate, delete, extract the selection into a new file
// and split, and Save (a new file next to the original, or Replace for a Danaview folder file
// only). The original is never modified; tools run off the main thread with progress and Cancel
// (pdf_tool_progress.dart). Works from 280 px to desktop widths and at text scale 0.85–1.35:
// a compact icon-and-label toolbar on narrow windows, labelled buttons on wide ones, targets
// ≥ 44 px, no hover or press tints, kit components only (rule 31). Nothing here logs a name or a
// path (rule 30).

import 'dart:async';
import 'dart:io';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import '../../card/viewer_bar.dart';
import '../../router/viewer_file.dart';
import '../../text/viewer_parts.dart';
import '../viewer/pdf_password_sheet.dart';
import '../viewer/pdf_viewer.dart' show PdfPasswordPrompt;
import 'pdf_organiser_grid.dart';
import 'pdf_organiser_model.dart';
import 'pdf_split_sheet.dart';
import 'pdf_tool_launcher.dart';
import 'pdf_tool_progress.dart';
import 'pdf_tool_save.dart';

/// Windows at least this wide get the labelled toolbar.
const double _wideToolbar = 600;

/// The organiser of [file].
class PdfPageOrganiser extends StatefulWidget {
  /// An organiser over [environment].
  const PdfPageOrganiser({
    super.key,
    required this.file,
    required this.environment,
    this.password,
    this.onClose,
    this.onMergeWith,
    this.passwordPrompt,
    this.chooseSaveMode,
  });

  /// The PDF.
  final ViewerFile file;

  /// Documents, tools and the result sink.
  final PdfToolsEnvironment environment;

  /// The password the caller already unlocked it with.
  final String? password;

  /// Closes the organiser with the saved result that ended it (or null).
  final ValueChanged<PdfSavedFile?>? onClose;

  /// Opens the merge screen with this file first (with its password); null hides "Merge with…".
  final Future<PdfSavedFile?> Function(String? password)? onMergeWith;

  /// The password prompt (default [showPdfPasswordSheet]).
  final PdfPasswordPrompt? passwordPrompt;

  /// Asks new file or Replace (default [showPdfSaveModeSheet]).
  final Future<PdfSaveMode?> Function(BuildContext context, String newName)? chooseSaveMode;

  @override
  State<PdfPageOrganiser> createState() => _PdfPageOrganiserState();
}

class _PdfPageOrganiserState extends State<PdfPageOrganiser> {
  PdfDocumentInfo? _doc;
  PdfOrganiserModel? _model;
  String? _password;
  bool _failed = false;
  bool _needsPassword = false;
  bool _busy = false;
  final GlobalKey _menuKey = GlobalKey();

  PdfToolsEnvironment get _env => widget.environment;

  @override
  void initState() {
    super.initState();
    _password = widget.password;
    unawaited(_open());
  }

  @override
  void dispose() {
    final doc = _doc;
    if (doc != null) unawaited(_env.documents.close(doc.handle).catchError((Object _) {}));
    _model?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final doc = await _env.documents.open(widget.file.path, password: _password);
      if (!mounted) {
        unawaited(_env.documents.close(doc.handle).catchError((Object _) {}));
        return;
      }
      setState(() {
        _doc = doc;
        _needsPassword = doc.locked;
        if (!doc.locked) _model = PdfOrganiserModel(doc.pageCount);
      });
      if (doc.locked) await _askPassword();
    } on PdfException {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<bool> _tryPassword(String password) async {
    final doc = _doc;
    if (doc == null) return false;
    final unlocked = await _env.documents.unlock(doc.handle, password);
    if (unlocked == null || unlocked.locked) return false;
    if (mounted) {
      setState(() {
        _password = password;
        _doc = unlocked;
        _needsPassword = false;
        _model = PdfOrganiserModel(unlocked.pageCount);
      });
    }
    return true;
  }

  Future<void> _askPassword() async {
    if (!mounted) return;
    final prompt = widget.passwordPrompt ?? (context, attempt) => showPdfPasswordSheet(context, tryPassword: attempt);
    await prompt(context, _tryPassword);
  }

  PdfToolInput get _input => PdfToolInput.pdf(widget.file.path, password: _password);

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    DanaviewToast.show(
      context,
      message,
      kind: error ? DanaviewToastKind.error : DanaviewToastKind.success,
      icon: error ? Icons.error_outline_rounded : null,
    );
  }

  /// Runs [body] with the toolbar locked; failures become a toast.
  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } on PdfException catch (e) {
      _toast(pdfToolErrorMessage(e), error: true);
    } on Object {
      _toast('The result couldn’t be saved. Try again.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Actions

  Future<void> _save() => _run(() async {
        final model = _model!;
        final newName = editedPdfName(widget.file.displayName);
        final entry = widget.file.entryId;
        var mode = PdfSaveMode.newFile;
        if (canReplacePdf(widget.file)) {
          final choose = widget.chooseSaveMode ?? showPdfSaveModeSheet;
          final picked = await choose(context, newName);
          if (picked == null || !mounted) return;
          mode = picked;
        }
        final dir = await _env.sink.stagingDirectory();
        final out = stagingPathFor(dir, newName);
        if (!mounted) return;
        final result = await runPdfTool(context, _env.tools.organise(_input, model.plan, outPath: out), title: 'Saving pages');
        if (result == null) return;
        final PdfSavedFile saved;
        if (mode == PdfSaveMode.replace && entry != null) {
          saved = await _env.sink.replace(entry, out, pageCount: result.pageCounts.first);
          _toast('Replaced ${saved.displayName}');
        } else {
          saved = (await _env.sink.saveNew([out], [newName], besideEntry: entry)).single;
          _toast('Saved as ${saved.displayName}');
        }
        widget.onClose?.call(saved);
      });

  Future<void> _extract() => _run(() async {
        final model = _model!;
        final plan = model.selectedInOrder;
        if (plan.isEmpty) return;
        final name = extractPdfName(widget.file.displayName, [for (final p in plan) model.indexOf(p.sourcePage)]);
        final dir = await _env.sink.stagingDirectory();
        final out = stagingPathFor(dir, name);
        if (!mounted) return;
        final result = await runPdfTool(context, _env.tools.organise(_input, plan, outPath: out), title: 'Extracting pages');
        if (result == null) return;
        final saved = (await _env.sink.saveNew([out], [name], besideEntry: widget.file.entryId)).single;
        _toast('Saved as ${saved.displayName}');
      });

  Future<void> _split() async {
    final model = _model!;
    final ranges = await showPdfSplitSheet(context, pageCount: model.length);
    if (ranges == null || !mounted) return;
    await _run(() async {
      final dir = await _env.sink.stagingDirectory();
      // Split what the grid shows: unsaved changes are written to a staged copy first.
      var input = _input;
      String? staged;
      if (model.isDirty) {
        staged = stagingPathFor(dir, editedPdfName(widget.file.displayName));
        if (!mounted) return;
        final r = await runPdfTool(context, _env.tools.organise(_input, model.plan, outPath: staged), title: 'Preparing pages');
        if (r == null) return;
        input = PdfToolInput.pdf(staged);
      }
      try {
        final names = [for (final r in ranges) splitPdfName(widget.file.displayName, r)];
        final outs = [for (final n in names) stagingPathFor(dir, n)];
        if (!mounted) return;
        final result = await runPdfTool(context, _env.tools.split(input, ranges, outPaths: outs), title: 'Splitting');
        if (result == null) return;
        final saved = await _env.sink.saveNew(outs, names, besideEntry: widget.file.entryId);
        _toast(saved.length == 1 ? 'Saved as ${saved.single.displayName}' : 'Saved ${saved.length} files');
      } finally {
        if (staged != null) {
          try {
            File(staged).deleteSync();
          } on FileSystemException {
            // App-owned staging; cleared with the folder.
          }
        }
      }
    });
  }

  void _rotate() => _model?.rotate();

  void _delete() {
    final removed = _model?.deleteSelected() ?? 0;
    if (removed > 0) DanaviewToast.show(context, removed == 1 ? 'Removed 1 page' : 'Removed $removed pages');
  }

  Future<void> _close() async {
    final model = _model;
    if (model != null && model.isDirty) {
      final discard = await showDanaviewConfirm(
        context,
        title: 'Discard changes?',
        message: 'Your page changes haven’t been saved.',
        confirmLabel: 'Discard',
        destructive: true,
      );
      if (!discard || !mounted) return;
    }
    widget.onClose?.call(null);
  }

  // ---------------------------------------------------------------------------------------------
  // Build

  String _subtitle() {
    final model = _model;
    if (model == null) return widget.file.displayName;
    if (model.hasSelection) return '${model.selectedCount} of ${model.length} selected';
    final pages = model.length == 1 ? '1 page' : '${model.length} pages';
    return '${widget.file.displayName} · $pages';
  }

  List<DanaviewMenuEntry> _menu() {
    final model = _model;
    final merge = widget.onMergeWith;
    return [
      if (merge != null)
        DanaviewMenuItem(
          label: model != null && model.isDirty ? 'Merge with… (save first)' : 'Merge with…',
          icon: Icons.merge_rounded,
          enabled: !_busy && model != null && !model.isDirty,
          onTap: () => unawaited(merge(_password)),
        ),
      DanaviewMenuItem(
        label: 'Undo all changes',
        icon: Icons.restart_alt_rounded,
        enabled: !_busy && model != null && model.isDirty,
        onTap: () => _model?.reset(),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    final top = model == null
        ? _topBar(null)
        : ListenableBuilder(listenable: model, builder: (context, _) => _topBar(model));
    return Column(
      children: [
        top,
        Expanded(child: ClipRect(child: _body(context))),
      ],
    );
  }

  Widget _topBar(PdfOrganiserModel? model) => DocumentTopBar(
        title: 'Organise pages',
        subtitle: _subtitle(),
        onClose: () => unawaited(_close()),
        actions: [
          ViewerOptionsButton(key: _menuKey, entries: _menu()),
          const SizedBox(width: DanaviewSpacing.xs),
          DanaviewButton.primary(
            key: const ValueKey('pdf-organiser-save'),
            label: 'Save',
            size: DanaviewButtonSize.sm,
            semanticLabel: 'Save',
            onPressed: model != null && model.isDirty && !_busy ? () => unawaited(_save()) : null,
          ),
          const SizedBox(width: DanaviewSpacing.sm),
        ],
      );

  Widget _body(BuildContext context) {
    if (_failed) {
      return const DanaviewEmptyState(
        icon: Icons.error_outline_rounded,
        iconColor: DanaviewColors.textSecondary,
        title: 'Can’t open this PDF',
        message: 'Danaview couldn’t read its pages.',
      );
    }
    final doc = _doc;
    if (doc == null) return const DocumentLoading();
    final model = _model;
    if (_needsPassword || model == null) {
      return DanaviewEmptyState(
        icon: Icons.lock_outline_rounded,
        iconColor: DanaviewColors.textSecondary,
        title: 'This PDF is protected',
        message: 'Enter its password to organise its pages.',
        actions: [
          DanaviewButton.primary(label: 'Enter password', semanticLabel: 'Enter password', onPressed: () => unawaited(_askPassword())),
        ],
      );
    }
    return Column(
      children: [
        Expanded(
          child: PdfOrganiserGrid(
            model: model,
            pageSizes: doc.pageSizes,
            dragEnabled: !_busy,
            load: (page, w, h) => _env.documents.thumbnail(doc.handle, page, maxWidth: w, maxHeight: h),
          ),
        ),
        ListenableBuilder(listenable: model, builder: (context, _) => _toolbar(context, model)),
      ],
    );
  }

  Widget _toolbar(BuildContext context, PdfOrganiserModel model) {
    final idle = !_busy;
    final actions = [
      _ToolAction(
        key: 'pdf-organiser-select-all',
        icon: model.allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
        label: model.allSelected ? 'Select none' : 'Select all',
        onPressed: idle ? model.toggleAll : null,
      ),
      _ToolAction(key: 'pdf-organiser-rotate', icon: Icons.rotate_right_rounded, label: 'Rotate', onPressed: idle && model.hasSelection ? _rotate : null),
      _ToolAction(key: 'pdf-organiser-delete', icon: Icons.delete_outline_rounded, label: 'Delete', onPressed: idle && model.canDelete ? _delete : null),
      _ToolAction(
        key: 'pdf-organiser-extract',
        icon: Icons.file_copy_outlined,
        label: 'Extract',
        onPressed: idle && model.hasSelection ? () => unawaited(_extract()) : null,
      ),
      _ToolAction(
        key: 'pdf-organiser-split',
        icon: Icons.call_split_rounded,
        label: 'Split',
        onPressed: idle && model.length > 1 ? () => unawaited(_split()) : null,
      ),
    ];
    return DecoratedBox(
      decoration: const BoxDecoration(color: DanaviewColors.surface, border: Border(top: DanaviewBorders.hairline)),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth >= _wideToolbar) {
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: DanaviewSpacing.pageGutter(c.maxWidth), vertical: DanaviewSpacing.sm),
                child: Wrap(
                  spacing: DanaviewSpacing.sm,
                  runSpacing: DanaviewSpacing.sm,
                  children: [
                    for (final a in actions)
                      DanaviewButton.secondary(
                        key: ValueKey(a.key),
                        label: a.label,
                        icon: a.icon,
                        semanticLabel: a.label,
                        onPressed: a.onPressed,
                      ),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs, vertical: DanaviewSpacing.xxs),
              child: Row(
                children: [
                  for (final a in actions) Expanded(child: _CompactToolButton(action: a)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ToolAction {
  const _ToolAction({required this.key, required this.icon, required this.label, required this.onPressed});

  final String key;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
}

/// A narrow-window toolbar button: the glyph over a one-line label, at least 44 px tall.
class _CompactToolButton extends StatelessWidget {
  const _CompactToolButton({required this.action});

  final _ToolAction action;

  @override
  Widget build(BuildContext context) {
    final enabled = action.onPressed != null;
    final color = enabled ? DanaviewColors.textPrimary : DanaviewColors.textMuted;
    return DanaviewPressable(
      key: ValueKey(action.key),
      onTap: action.onPressed,
      enabled: enabled,
      semanticLabel: action.label,
      tooltip: action.label,
      borderRadius: DanaviewRadius.controlAll,
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(action.icon, size: 20, color: color),
                const SizedBox(height: DanaviewSpacing.xxs),
                Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: DanaviewTextStyles.micro.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks how to save an organised copy: a new file named [newName] next to the original, or
/// Replace (only offered for Danaview folder files). Null when dismissed.
Future<PdfSaveMode?> showPdfSaveModeSheet(BuildContext context, String newName) => showDanaviewSheet<PdfSaveMode>(
      context,
      title: 'Save changes',
      builder: (sheetContext) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DanaviewListTile(
              key: const ValueKey('pdf-save-new'),
              leading: const DanaviewIconTile(Icons.note_add_outlined),
              title: 'Save as a new file',
              subtitle: newName,
              subtitleMaxLines: 2,
              onTap: () => Navigator.of(sheetContext).pop(PdfSaveMode.newFile),
            ),
            DanaviewListTile(
              key: const ValueKey('pdf-save-replace'),
              leading: const DanaviewIconTile(Icons.published_with_changes_rounded),
              title: 'Replace the original',
              subtitle: 'The file in its Danaview folder changes',
              subtitleMaxLines: 2,
              onTap: () => Navigator.of(sheetContext).pop(PdfSaveMode.replace),
            ),
          ],
        ),
      ),
    );
