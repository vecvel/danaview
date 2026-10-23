// OWNER: HOM-20
//
// The import sheet (ARCH v1.2 §5.6, HOM plan §8.2; ARCH §1.4): "From Photos" and "From Files"
// (the pickers need no library permission), the Danaview folder the copies go to (default
// `Imported`), and one progress row per item with its bytes, a cancel button, the "Already in
// Danaview: keep both or skip?" question and the outcome. Kit components only, Figtree through the
// kit theme, dark surfaces, ≥ 44 px targets, semantics labels on every control, no overflow at
// 280–1280 px and text scale 0.85–1.35 (test/v12/import/). Without a library store
// (DANAVIEW_FILES_HOME off) the sheet says import is unavailable and offers nothing; nothing in
// the 1.1 Home opens it.

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../files/library_store_providers.dart';
import 'import_pickers.dart';
import 'import_providers.dart';

/// Opens the import sheet; copies go to [initialFolder] (`Imported` when null) unless the user
/// picks another folder.
Future<void> showImportSheet(BuildContext context, {FolderId? initialFolder}) => showDanaviewSheet<void>(
      context,
      title: 'Import',
      builder: (_) => ImportSheet(initialFolder: initialFolder),
    );

/// `1.2 MB`-style sizes (decimal units, as the Files app shows them).
String formatImportBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1000;
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[u]}';
}

/// The status line of an import row.
String importItemStatus(ImportItem item) => switch (item.state) {
      ImportItemState.queued => item.resumed ? 'Waiting to continue' : 'Waiting',
      ImportItemState.copying => item.bytesTotal > 0
          ? '${formatImportBytes(item.bytesDone)} of ${formatImportBytes(item.bytesTotal)}'
          : (item.bytesDone > 0 ? formatImportBytes(item.bytesDone) : 'Starting'),
      ImportItemState.finishing => 'Finishing',
      ImportItemState.awaitingDuplicateDecision => 'Already in Danaview. Keep both or skip?',
      ImportItemState.done => 'Imported',
      ImportItemState.skipped => 'Skipped: already in Danaview',
      ImportItemState.cancelled => 'Cancelled',
      ImportItemState.failed => switch (item.failure) {
          ImportFailure.sourceUnreadable => "Couldn't read the file",
          ImportFailure.sourceChanged => 'The file changed while copying',
          ImportFailure.unsupportedSource => "This file can't be imported here",
          ImportFailure.refused => "The library can't take new files",
          _ => "Couldn't copy the file",
        },
    };

/// The body of the import sheet.
class ImportSheet extends ConsumerStatefulWidget {
  /// A sheet targeting [initialFolder] (`Imported` when null).
  const ImportSheet({super.key, this.initialFolder});

  /// The preselected Danaview folder.
  final FolderId? initialFolder;

  @override
  ConsumerState<ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends ConsumerState<ImportSheet> {
  late FolderId? _target = widget.initialFolder;
  bool _picking = false;

  Future<void> _pick({required bool photos}) async {
    final picker = ref.read(importPickerProvider);
    final service = ref.read(importServiceProvider);
    if (picker == null || service == null || _picking) return;
    setState(() => _picking = true);
    try {
      final sources = photos ? await picker.pickPhotos() : await picker.pickFiles();
      if (!mounted || sources.isEmpty) return;
      service.enqueueAll(sources, target: _target);
    } on ImportPickException catch (e) {
      if (mounted) {
        DanaviewToast.show(
          context,
          e.unsupported ? "This device can't pick files here." : "Couldn't open the picker. Please try again.",
          kind: DanaviewToastKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _chooseFolder(LibraryStore store) async {
    final chosen = await showDanaviewSheet<_FolderChoice>(
      context,
      title: 'Save to',
      builder: (_) => _FolderChooser(store: store, selected: _target),
    );
    if (chosen != null && mounted) setState(() => _target = chosen.id);
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(libraryStoreProvider);
    final service = ref.watch(importServiceProvider);
    final picker = ref.watch(importPickerProvider);
    ref.watch(libraryRevisionProvider);
    final items = ref.watch(importItemsProvider).valueOrNull ?? const <ImportItem>[];

    if (store == null || service == null) {
      return const Padding(
        key: ValueKey('import-unavailable'),
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text("Import into Danaview folders isn't available.", style: DanaviewTextStyles.bodySecondary),
      );
    }

    final target = _target == null ? null : store.reader.folder(_target!);
    final targetName = target == null || target.isTrashed ? (store.reader.systemFolder(FolderSystemRole.imported)?.name ?? 'Imported') : target.name;
    final canPick = picker != null && !_picking;
    final finished = items.where((i) => i.state.isFinal).length;

    return Column(
      key: const ValueKey('import-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Imports are copies. Your originals are never changed.', style: DanaviewTextStyles.bodySecondary),
        const SizedBox(height: 12),
        DanaviewSurface(
          child: DanaviewListTile(
            key: const ValueKey('import-target'),
            leading: const DanaviewTileIcon(Icons.folder_outlined),
            title: targetName,
            subtitle: 'Save to',
            showChevron: true,
            semanticLabel: 'Save to $targetName. Change folder',
            onTap: () => _chooseFolder(store),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (picker?.canPickPhotos ?? false)
              DanaviewButton.primary(
                key: const ValueKey('import-from-photos'),
                label: 'From Photos',
                icon: Icons.photo_library_outlined,
                semanticLabel: 'Import from Photos',
                onPressed: canPick ? () => _pick(photos: true) : null,
              ),
            DanaviewButton(
              key: const ValueKey('import-from-files'),
              variant: picker?.canPickPhotos ?? false ? DanaviewButtonVariant.secondary : DanaviewButtonVariant.primary,
              label: 'From Files',
              icon: Icons.folder_open_outlined,
              semanticLabel: 'Import from Files',
              onPressed: canPick ? () => _pick(photos: false) : null,
            ),
          ],
        ),
        if (items.isNotEmpty) ...[
          DanaviewSectionHeader(
            'Imports',
            action: finished == 0
                ? null
                : DanaviewButton.ghost(
                    key: const ValueKey('import-clear-finished'),
                    label: 'Clear',
                    size: DanaviewButtonSize.sm,
                    semanticLabel: 'Clear finished imports',
                    onPressed: service.clearFinished,
                  ),
          ),
          for (final item in items) ImportProgressRow(key: ValueKey('import-row-${item.id}'), item: item, service: service),
        ],
      ],
    );
  }
}

/// One item of the import queue: name, status, progress, cancel and the duplicate question.
class ImportProgressRow extends StatelessWidget {
  /// The row of [item] in [service].
  const ImportProgressRow({super.key, required this.item, required this.service});

  /// The item.
  final ImportItem item;

  /// Its queue.
  final ImportService service;

  IconData get _icon => switch (item.state) {
        ImportItemState.done => Icons.check_circle_outline_rounded,
        ImportItemState.failed => Icons.error_outline_rounded,
        ImportItemState.skipped || ImportItemState.cancelled => Icons.remove_circle_outline_rounded,
        ImportItemState.awaitingDuplicateDecision => Icons.content_copy_rounded,
        _ => Icons.downloading_rounded,
      };

  Color get _color => switch (item.state) {
        ImportItemState.done => DanaviewColors.success,
        ImportItemState.failed => DanaviewColors.errorLight,
        ImportItemState.awaitingDuplicateDecision => DanaviewColors.warning,
        ImportItemState.skipped || ImportItemState.cancelled => DanaviewColors.textMuted,
        _ => DanaviewColors.primaryLight,
      };

  @override
  Widget build(BuildContext context) {
    final status = importItemStatus(item);
    final active = !item.state.isFinal && item.state != ImportItemState.awaitingDuplicateDecision;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(_icon, size: 22, color: _color),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  container: true,
                  label: '${item.displayName}. $status',
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.body),
                      Text(status, maxLines: 2, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary)),
                    ],
                  ),
                ),
              ),
              if (!item.state.isFinal)
                DanaviewIconButton(
                  key: ValueKey('import-cancel-${item.id}'),
                  icon: Icons.close_rounded,
                  size: 44,
                  tooltip: 'Cancel',
                  semanticLabel: 'Cancel import of ${item.displayName}',
                  onPressed: () => service.cancel(item.id),
                ),
            ],
          ),
          if (active && item.state != ImportItemState.queued)
            Padding(
              padding: const EdgeInsets.only(left: 34, top: 6, right: 52),
              child: DanaviewProgressBar(
                // A new bar when it switches between determinate and indeterminate: the kit bar's
                // single ticker can't be recreated in one State (defect reported against the kit).
                key: ValueKey(item.state == ImportItemState.finishing || item.fraction == null),
                value: item.state == ImportItemState.finishing ? null : item.fraction,
                semanticLabel: 'Importing ${item.displayName}',
              ),
            ),
          if (item.state == ImportItemState.awaitingDuplicateDecision)
            Padding(
              padding: const EdgeInsets.only(left: 34, top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  DanaviewButton.secondary(
                    key: ValueKey('import-keep-both-${item.id}'),
                    label: 'Keep both',
                    size: DanaviewButtonSize.sm,
                    semanticLabel: 'Keep both copies of ${item.displayName}',
                    onPressed: () => service.resolveDuplicate(item.id, DuplicateDecision.keepBoth),
                  ),
                  DanaviewButton.ghost(
                    key: ValueKey('import-skip-${item.id}'),
                    label: 'Skip',
                    size: DanaviewButtonSize.sm,
                    semanticLabel: 'Skip ${item.displayName}',
                    onPressed: () => service.resolveDuplicate(item.id, DuplicateDecision.skip),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

final class _FolderChoice {
  const _FolderChoice(this.id);

  final FolderId? id;
}

/// The live Danaview folders, `Imported` first, nested folders indented.
class _FolderChooser extends StatelessWidget {
  const _FolderChooser({required this.store, required this.selected});

  final LibraryStore store;
  final FolderId? selected;

  @override
  Widget build(BuildContext context) {
    final reader = store.reader;
    final imported = reader.systemFolder(FolderSystemRole.imported);
    final rows = <(LibraryFolder, int)>[];
    void walk(FolderId? parent, int depth) {
      if (depth > 8) return;
      for (final f in reader.childFolders(parent)) {
        if (f.id == imported?.id) continue;
        rows.add((f, depth));
        walk(f.id, depth + 1);
      }
    }

    walk(null, 0);
    Widget tile(LibraryFolder? f, int depth) {
      final name = f?.name ?? imported?.name ?? 'Imported';
      final id = f?.id;
      final isSelected = f == null ? (selected == null || selected == imported?.id) : f.id == selected;
      return DanaviewListTile(
        key: ValueKey('import-folder-${id?.value ?? 'imported'}'),
        padding: EdgeInsetsDirectional.only(start: 12 + 16.0 * (depth > 4 ? 4 : depth), end: 12, top: 6, bottom: 6),
        leading: DanaviewTileIcon(f == null ? Icons.move_to_inbox_outlined : Icons.folder_outlined),
        title: name,
        selected: isSelected,
        trailing: isSelected ? const Icon(Icons.check_rounded, size: 20, color: DanaviewColors.primaryLight) : null,
        semanticLabel: 'Save to $name',
        onTap: () => Navigator.of(context).pop(_FolderChoice(id)),
      );
    }

    return Column(
      key: const ValueKey('import-folder-chooser'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile(null, 0),
        for (final (f, depth) in rows) tile(f, depth),
      ],
    );
  }
}
