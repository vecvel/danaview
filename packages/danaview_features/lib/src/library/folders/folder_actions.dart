// OWNER: HOM-18
//
// The Danaview folder operations of the Folders tab (ARCH v1.2 V2-06, V2-08, §5.3–§5.4; HOM plan
// §8.1, D-98b): create, rename, move (any depth; the store refuses cycles), delete to Recently
// deleted after asking, Restore and Empty now. Every operation is one HOM-17 store write; the store
// emits a change after it, so the tab re-reads in the next frame. Refusals become a toast whose
// text never holds a file or folder name (ARCH rule 30 applies to logs; the toast is for the user
// and still names nothing it doesn't need to).

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../files/library_store_providers.dart';

/// The user-facing text of a refused write.
String libraryWriteErrorMessage(LibraryWriteError error) => switch (error) {
      LibraryWriteError.notFound => "That item isn't in your library anymore.",
      LibraryWriteError.trashed => 'That item is in Recently deleted. Restore it first.',
      LibraryWriteError.notTrashed => "That item isn't in Recently deleted.",
      LibraryWriteError.systemFolder => "This folder can't be renamed, moved or deleted.",
      LibraryWriteError.cycle => "A folder can't be moved inside itself.",
      LibraryWriteError.invalidName => "That name can't be used. Try a shorter name without / or :.",
      LibraryWriteError.missingPart => "The file couldn't be found. Try again.",
      LibraryWriteError.readOnly => 'This library was made by a newer Danaview, so it opens read-only.',
    };

/// A quick check of a name before the store's own (empty, path separators, too long).
String? validateLibraryName(String value) {
  final name = value.trim();
  if (name.isEmpty) return 'Enter a name';
  if (name.contains('/') || name.contains(r'\') || name.contains(':')) return "Names can't contain / \\ or :";
  if (name == '.' || name == '..') return "That name can't be used";
  if (name.length > 255) return 'That name is too long';
  return null;
}

/// Where a moved item goes: a folder, or the top level ([id] null; folders only).
@immutable
final class FolderPick {
  /// A choice.
  const FolderPick(this.id);

  /// The folder, or null for the top level.
  final FolderId? id;
}

/// Runs the Danaview folder operations against the store in [ref].
final class DanaviewFolderActions {
  /// Actions for the widget at [context] reading the store through [ref].
  DanaviewFolderActions(this.context, this.ref);

  /// Where dialogs, sheets and toasts show.
  final BuildContext context;

  /// The provider container.
  final WidgetRef ref;

  LibraryStore? get _store => ref.read(libraryStoreProvider);

  Future<R?> _write<R>(LibraryWrite<R> op) async {
    final store = _store;
    if (store == null) return null;
    try {
      return await store.write(op);
    } on LibraryWriteException catch (e) {
      _toast(libraryWriteErrorMessage(e.error), error: true);
      return null;
    }
  }

  void _toast(String message, {bool error = false}) {
    if (!context.mounted) return;
    DanaviewToast.show(
      context,
      message,
      kind: error ? DanaviewToastKind.error : DanaviewToastKind.success,
      icon: error ? Icons.error_outline_rounded : Icons.check_circle_rounded,
    );
  }

  /// Asks for a name and creates a folder in [parent] (the top level when null).
  Future<FolderId?> createFolder(FolderId? parent) async {
    final name = await showDanaviewPrompt(
      context,
      title: 'New folder',
      hint: 'Folder name',
      confirmLabel: 'Create',
      prefixIcon: Icons.create_new_folder_outlined,
      validator: validateLibraryName,
    );
    if (name == null) return null;
    final trimmed = name.trim();
    return _write((w, now) => w.createFolder(trimmed, parent: parent, now: now));
  }

  /// Asks for a new name for [folder].
  Future<void> renameFolder(LibraryFolder folder) async {
    final name = await showDanaviewPrompt(
      context,
      title: 'Rename folder',
      initialValue: folder.name,
      hint: 'Folder name',
      confirmLabel: 'Rename',
      prefixIcon: Icons.edit_rounded,
      validator: validateLibraryName,
    );
    if (name == null || name.trim() == folder.name) return;
    final id = folder.id;
    final trimmed = name.trim();
    await _write((w, now) => w.renameFolder(id, trimmed, now: now));
  }

  /// Asks for a new name for [entry].
  Future<void> renameEntry(FileEntry entry) async {
    final name = await showDanaviewPrompt(
      context,
      title: 'Rename file',
      initialValue: entry.displayName,
      hint: 'File name',
      confirmLabel: 'Rename',
      prefixIcon: Icons.edit_rounded,
      validator: validateLibraryName,
    );
    if (name == null || name.trim() == entry.displayName) return;
    final id = entry.id;
    final trimmed = name.trim();
    await _write((w, now) => w.renameEntry(id, trimmed, now: now));
  }

  /// Asks where [folder] goes and moves it there (a subfolder of itself is not offered).
  Future<void> moveFolder(LibraryFolder folder) async {
    final store = _store;
    if (store == null) return;
    final excluded = store.reader.subtreeFolderIds(folder.id).toSet();
    final pick = await showFolderPicker(context, store, title: 'Move folder to', allowTopLevel: true, excluded: excluded);
    if (pick == null || pick.id == folder.parentId) return;
    final id = folder.id;
    final target = pick.id;
    await _write((w, now) => w.moveFolder(id, target, now: now));
  }

  /// Asks where [entry] goes and moves it there.
  Future<void> moveEntry(FileEntry entry) async {
    final store = _store;
    if (store == null) return;
    final pick = await showFolderPicker(context, store, title: 'Move to', allowTopLevel: false, excluded: const {});
    final target = pick?.id;
    if (target == null || target == entry.folderId) return;
    final id = entry.id;
    await _write((w, now) => w.moveEntries([id], target, now: now));
  }

  /// Asks, then moves [folder] and everything in it to Recently deleted.
  Future<bool> deleteFolder(LibraryFolder folder) async {
    final ok = await showDanaviewConfirm(
      context,
      title: 'Delete folder',
      message: '"${folder.name}" and everything in it move to Recently deleted for 30 days.',
      confirmLabel: 'Delete',
      destructive: true,
      icon: Icons.delete_outline_rounded,
    );
    if (!ok) return false;
    final id = folder.id;
    return await _write((w, now) {
          w.trashFolder(id, now: now);
          return true;
        }) ??
        false;
  }

  /// Asks, then moves [entry] to Recently deleted.
  Future<void> deleteEntry(FileEntry entry) async {
    final ok = await showDanaviewConfirm(
      context,
      title: 'Delete file',
      message: '"${entry.displayName}" moves to Recently deleted for 30 days.',
      confirmLabel: 'Delete',
      destructive: true,
      icon: Icons.delete_outline_rounded,
    );
    if (!ok) return;
    final id = entry.id;
    await _write((w, now) => w.trashEntries([id], now: now));
  }

  /// Restores [item] to its folder (or `Imported` when that folder is gone).
  Future<void> restore(TrashedItem item) async {
    final id = item.id;
    final store = _store;
    if (store == null) return;
    try {
      await store.write((w, now) => w.restore(id, now: now));
      _toast('Restored "${item.name}"');
    } on LibraryWriteException catch (e) {
      _toast(libraryWriteErrorMessage(e.error), error: true);
    }
  }

  /// Asks, then removes everything in Recently deleted for good.
  Future<void> emptyNow() async {
    final ok = await showDanaviewConfirm(
      context,
      title: 'Empty Recently deleted',
      message: 'Everything in Recently deleted is removed for good. This cannot be undone.',
      confirmLabel: 'Empty now',
      destructive: true,
      icon: Icons.delete_forever_outlined,
    );
    if (!ok) return;
    await _write((w, _) => w.emptyTrash());
  }
}

/// Shows the live Danaview folders as a tree and returns the one picked (null when cancelled).
///
/// [allowTopLevel] offers "Top level" (folders only; files always live in a folder); [excluded]
/// folders (the moved folder's subtree) are not offered.
Future<FolderPick?> showFolderPicker(
  BuildContext context,
  LibraryStore store, {
  required String title,
  required bool allowTopLevel,
  required Set<FolderId> excluded,
}) {
  final rows = <(LibraryFolder, int)>[];
  void walk(FolderId? parent, int depth) {
    for (final f in store.reader.childFolders(parent)) {
      if (excluded.contains(f.id)) continue;
      rows.add((f, depth));
      walk(f.id, depth + 1);
    }
  }

  walk(null, 0);
  return showDanaviewSheet<FolderPick>(
    context,
    title: title,
    builder: (context) => ListView(
      shrinkWrap: true,
      children: [
        if (allowTopLevel)
          _PickRow(
            key: const ValueKey('folder-pick-top'),
            label: 'Top level',
            depth: 0,
            icon: Icons.home_outlined,
            onTap: () => Navigator.of(context).pop(const FolderPick(null)),
          ),
        for (final (folder, depth) in rows)
          _PickRow(
            key: ValueKey('folder-pick-${folder.id.value}'),
            label: folder.name,
            depth: depth,
            onTap: () => Navigator.of(context).pop(FolderPick(folder.id)),
          ),
        if (rows.isEmpty && !allowTopLevel)
          const Padding(
            padding: EdgeInsets.all(DanaviewSpacing.lg),
            child: Text('Create a folder first.', style: DanaviewTextStyles.caption),
          ),
      ],
    ),
  );
}

class _PickRow extends StatelessWidget {
  const _PickRow({super.key, required this.label, required this.depth, required this.onTap, this.icon});

  final String label;
  final int depth;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final indent = (depth * 16.0).clamp(0.0, 96.0);
    return DanaviewPressable(
      onTap: onTap,
      borderRadius: DanaviewRadius.mdAll,
      semanticLabel: depth == 0 ? label : '$label, level ${depth + 1}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(8 + indent, 8, 8, 8),
          child: Row(
            children: [
              icon == null
                  ? const DanaviewGlyph(DanaviewGlyphKind.folderOpen, size: 22, color: DanaviewColors.primaryLight)
                  : Icon(icon, size: 22, color: DanaviewColors.primaryLight),
              const SizedBox(width: DanaviewSpacing.md),
              Expanded(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.body),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
