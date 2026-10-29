// OWNER: HOM-18
//
// The Folders tab (ARCH v1.2 V2-115, §5.4; HOM plan §5.2, §8.1, D-98b; BUILD_PLAN HOM-18). Two
// groups:
//
// * **Danaview folders**: the app-private library (HOM-17). Browse any depth with a breadcrumb
//   trail, create, rename, move and nest folders, rename, move and delete files, and the
//   **Recently deleted** view (each row with its days left, Restore, Empty now). Every operation
//   is one store write; the store's change event re-reads the lists in the next frame.
//   A folder's files sit in the All tab's mixed card grid (DESIGN_SYSTEM §10.4).
// * **Linked folders**: the 1.1 Folders section unchanged (P-5): the same rows open the same 1.1
//   folder browser, and nothing in it renames, moves or deletes a file.
//
// Without a store (DANAVIEW_FILES_HOME off, or before the app opened it) only the linked group
// shows. Where it is in the tree stays across tab switches (HOM-05's host keeps the page alive).

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../files/library_store_providers.dart';
import '../filters/entry_widgets.dart';
import '../filters/filter_providers.dart';
import '../folders/folder_actions.dart';
import '../folders/folder_widgets.dart';
import '../home/home_grid.dart';
import '../home/home_media_card.dart';
import '../library_format.dart';
import '../library_widgets.dart';

/// Where the Folders tab is: the root, a Danaview folder, or Recently deleted.
sealed class FoldersTabLocation {
  const FoldersTabLocation();
}

/// Both groups.
final class FoldersRoot extends FoldersTabLocation {
  /// The root.
  const FoldersRoot();
}

/// Inside Danaview folder [id].
final class FoldersInFolder extends FoldersTabLocation {
  /// Inside [id].
  const FoldersInFolder(this.id);

  /// The open folder.
  final FolderId id;
}

/// The Recently deleted view.
final class FoldersRecentlyDeleted extends FoldersTabLocation {
  /// Recently deleted.
  const FoldersRecentlyDeleted();
}

/// The Folders tab.
class FoldersTab extends ConsumerStatefulWidget {
  /// The tab; [onOpenFolder] opens the 1.1 browser at a linked folder's path, [onOpenEntry] a
  /// Danaview file in its viewer, [onOpenPlayer] the player after a linked folder's Play all.
  const FoldersTab({super.key, required this.onOpenFolder, this.onOpenEntry, this.onOpenPlayer, this.onMoreEntry});

  /// Opens the 1.1 folder browser (linked folders).
  final ValueChanged<String> onOpenFolder;

  /// Opens a Danaview file.
  final LibraryEntryOpen? onOpenEntry;

  /// Shows the player.
  final VoidCallback? onOpenPlayer;

  /// A Danaview file row's "More actions…" (the host's file menu, FIX-S3Q-1); null hides it.
  final ValueChanged<FileEntry>? onMoreEntry;

  @override
  ConsumerState<FoldersTab> createState() => _FoldersTabState();
}

class _FoldersTabState extends ConsumerState<FoldersTab> {
  FoldersTabLocation _at = const FoldersRoot();

  // Grid columns of the current width (set each layout; 1 keeps the list rows).
  /// The content width (the entries' card grid sizes its cells from it).
  double _contentWidth = 0;

  void _go(FoldersTabLocation to) => setState(() => _at = to);

  void _openFolder(FolderId? id) => _go(id == null ? const FoldersRoot() : FoldersInFolder(id));

  DanaviewFolderActions get _actions => DanaviewFolderActions(context, ref);

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(libraryStoreProvider);
    var at = _at;
    // A folder that went to Recently deleted (here or elsewhere) drops back to the root.
    if (at is FoldersInFolder && (store == null || ref.watch(libraryFolderPathProvider(at.id)).isEmpty)) {
      at = const FoldersRoot();
    }
    if (at is FoldersRecentlyDeleted && store == null) at = const FoldersRoot();
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = danaviewLibraryInsets(constraints.maxWidth);
        final padding = insets.copyWith(top: DanaviewSpacing.lg, bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl);
        _contentWidth = constraints.maxWidth - padding.horizontal;
        final slivers = switch (at) {
          FoldersRoot() => _root(store),
          FoldersInFolder(:final id) => _folder(store!, id),
          FoldersRecentlyDeleted() => _trash(store!),
        };
        return CustomScrollView(
          key: PageStorageKey('folders-tab-${switch (at) {
            FoldersRoot() => 'root',
            FoldersInFolder(:final id) => id.value,
            FoldersRecentlyDeleted() => 'trash',
          }}'),
          slivers: [for (final s in slivers) SliverPadding(padding: padding.copyWith(top: 0, bottom: 0), sliver: s)]
            ..insert(0, SliverToBoxAdapter(child: SizedBox(height: padding.top)))
            ..add(SliverToBoxAdapter(child: SizedBox(height: padding.bottom))),
        );
      },
    );
  }

  // ---- Root: both groups ----

  List<Widget> _root(LibraryStore? store) {
    return [
      if (store != null) ...[
        SliverToBoxAdapter(
          child: DanaviewLibrarySectionHeader(
            'Danaview folders',
            prominent: true,
            topSpacing: 0,
            action: store.readOnly
                ? null
                : DanaviewButton.text(
                    key: const ValueKey('folders-new-root'),
                    label: 'New folder',
                    size: DanaviewButtonSize.sm,
                    onPressed: () => _actions.createFolder(null),
                  ),
          ),
        ),
        SliverToBoxAdapter(child: _danaviewRootGroup()),
      ],
      SliverToBoxAdapter(child: LinkedFoldersGroup(onOpenFolder: widget.onOpenFolder, onOpenPlayer: widget.onOpenPlayer)),
    ];
  }

  Widget _danaviewRootGroup() {
    final folders = ref.watch(libraryChildFoldersProvider(null));
    final trash = ref.watch(recentlyDeletedProvider);
    final usage = ref.watch(libraryStorageUsageProvider) ?? LibraryStorageUsage.empty;
    return DanaviewLibraryCardGrid(
      children: [
        for (final folder in folders) _folderRow(folder),
        RecentlyDeletedEntryRow(itemCount: trash.length, usage: usage, onOpen: () => _go(const FoldersRecentlyDeleted())),
      ],
    );
  }

  Widget _folderRow(LibraryFolder folder) => DanaviewFolderRow(
        folder: folder,
        onOpen: () => _openFolder(folder.id),
        onRename: () => _actions.renameFolder(folder),
        onMove: () => _actions.moveFolder(folder),
        onDelete: () => _actions.deleteFolder(folder),
      );

  // ---- Inside a Danaview folder ----

  List<Widget> _folder(LibraryStore store, FolderId id) {
    final path = ref.watch(libraryFolderPathProvider(id));
    final folder = path.last;
    final subfolders = ref.watch(libraryChildFoldersProvider(id));
    final entries = ref.watch(libraryFolderEntriesProvider(id));
    final writable = !store.readOnly;
    final entryActions = LibraryEntryActions(
      onOpen: widget.onOpenEntry,
      onRename: writable ? _actions.renameEntry : null,
      onMove: writable ? _actions.moveEntry : null,
      onDelete: writable ? _actions.deleteEntry : null,
      onMore: widget.onMoreEntry,
    );
    final summary = [
      if (subfolders.isNotEmpty) formatCount(subfolders.length, 'folder'),
      formatCount(entries.length, 'file'),
    ].join(' · ');
    return [
      SliverToBoxAdapter(child: FolderBreadcrumbs(path: path, onSelect: _openFolder)),
      SliverToBoxAdapter(
        child: Row(
          children: [
            DanaviewIconButton(
              key: const ValueKey('folders-up'),
              icon: Icons.arrow_back_rounded,
              variant: DanaviewIconButtonVariant.plain,
              size: 44,
              tooltip: 'Back',
              onPressed: () => _openFolder(folder.parentId),
            ),
            const SizedBox(width: DanaviewSpacing.xs),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.title),
              ),
            ),
            if (writable)
              DanaviewIconButton(
                key: const ValueKey('folders-new-here'),
                icon: Icons.create_new_folder_outlined,
                variant: DanaviewIconButtonVariant.tonal,
                size: 44,
                tooltip: 'New folder',
                onPressed: () => _actions.createFolder(id),
              ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, DanaviewSpacing.xs, 0, DanaviewSpacing.md),
          child: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.caption),
        ),
      ),
      if (subfolders.isEmpty && entries.isEmpty)
        const SliverToBoxAdapter(
          child: DanaviewInlineEmpty(
            glyph: DanaviewGlyphKind.folder,
            title: 'This folder is empty',
            message: 'Import files or move them here. Folders can hold photos, videos and documents.',
          ),
        ),
      if (subfolders.isNotEmpty)
        SliverToBoxAdapter(
          child: DanaviewLibraryCardGrid(
            children: [
              for (final sub in subfolders)
                DanaviewFolderRow(
                  folder: sub,
                  onOpen: () => _openFolder(sub.id),
                  onRename: writable ? () => _actions.renameFolder(sub) : null,
                  onMove: writable ? () => _actions.moveFolder(sub) : null,
                  onDelete: writable ? () => _actions.deleteFolder(sub) : null,
                ),
            ],
          ),
        ),
      if (subfolders.isNotEmpty && entries.length > 0) const SliverToBoxAdapter(child: SizedBox(height: DanaviewSpacing.md)),
      // A folder's files in the same mixed grid as the All tab (DESIGN_SYSTEM §10.4).
      if (entries.length > 0)
        homeSliverCardGrid(
          key: const ValueKey('folders-entries-grid'),
          columns: homeAdaptiveColumns(_contentWidth),
          width: _contentWidth,
          extent: homeMediaCardExtent,
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final entry = entries.at(i);
            if (entry == null) return const SizedBox.shrink();
            return LibraryEntryCard(entry: entry, actions: entryActions);
          },
        ),
    ];
  }

  // ---- Recently deleted ----

  List<Widget> _trash(LibraryStore store) {
    final items = ref.watch(recentlyDeletedProvider);
    final usage = ref.watch(libraryStorageUsageProvider) ?? LibraryStorageUsage.empty;
    final now = store.now();
    final writable = !store.readOnly;
    final summary = items.isEmpty
        ? 'Nothing here'
        : '${formatCount(items.length, 'item')} · ${formatFileSize(usage.trashedBytes)} · kept for 30 days';
    return [
      SliverToBoxAdapter(
        child: Row(
          children: [
            DanaviewIconButton(
              key: const ValueKey('folders-up'),
              icon: Icons.arrow_back_rounded,
              variant: DanaviewIconButtonVariant.plain,
              size: 44,
              tooltip: 'Back',
              onPressed: () => _go(const FoldersRoot()),
            ),
            const SizedBox(width: DanaviewSpacing.xs),
            Expanded(
              child: Semantics(
                header: true,
                child: Text('Recently deleted', maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.title),
              ),
            ),
            if (writable && items.isNotEmpty)
              DanaviewButton.ghost(
                key: const ValueKey('recently-deleted-empty-now'),
                label: 'Empty now',
                size: DanaviewButtonSize.sm,
                onPressed: _actions.emptyNow,
              ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, DanaviewSpacing.xs, 0, DanaviewSpacing.md),
          child: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.caption),
        ),
      ),
      if (items.isEmpty)
        const SliverToBoxAdapter(
          child: DanaviewInlineEmpty(
            icon: Icons.delete_outline_rounded,
            title: 'Recently deleted is empty',
            message: 'Deleted files and folders stay here for 30 days, then are removed for good.',
          ),
        )
      else
        SliverToBoxAdapter(
          child: DanaviewLibraryCardGrid(
            children: [
              for (final item in items)
                TrashedItemRow(item: item, now: now, onRestore: writable ? () => _actions.restore(item) : () {}),
            ],
          ),
        ),
    ];
  }
}
