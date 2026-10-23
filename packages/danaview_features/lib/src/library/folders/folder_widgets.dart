// OWNER: HOM-18
//
// The pieces of the Folders tab (HOM plan §5.2, §8.1, D-98b; ARCH v1.2 §5.4): a Danaview folder
// row with its menu, the breadcrumb trail of a nested folder, the Recently deleted entry row and
// its rows ("N days left", Restore), and the **Linked folders** group, which is the 1.1 Folders
// section unchanged (P-5): the device-storage root and user-added folders open the 1.1 folder
// browser; their only action that changes anything is "Remove from library", which never touches
// the files. Linked-folder files offer no rename, move or delete anywhere. Kit components only,
// ≥ 44 px targets, semantics labels, ellipsised text (ARCH §1.4).

import 'package:danaview_data/danaview_data.dart' as data;
import 'package:danaview_domain/danaview_domain.dart' as domain show LibraryFolder, MediaRef;
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../filters/entry_widgets.dart';
import '../library_actions.dart';
import '../library_format.dart';
import '../library_providers.dart';
import '../library_widgets.dart';
import '../media_picker.dart';

/// One Danaview folder: tap opens it; the menu renames, moves and deletes (not for `Imported` and
/// `Recovered`, which the store keeps).
class DanaviewFolderRow extends StatelessWidget {
  /// The row of [folder].
  const DanaviewFolderRow({
    super.key,
    required this.folder,
    required this.onOpen,
    this.onRename,
    this.onMove,
    this.onDelete,
    this.subtitle,
  });

  /// The folder.
  final LibraryFolder folder;

  /// Opens it.
  final VoidCallback onOpen;

  /// Rename, move and delete (hidden for system folders or when null).
  final VoidCallback? onRename;
  final VoidCallback? onMove;
  final VoidCallback? onDelete;

  /// The line under the name.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final editable = !folder.isSystem;
    return KeyedSubtree(
      key: ValueKey('danaview-folder-${folder.id.value}'),
      child: DanaviewLibraryRow(
        leading: const DanaviewTileIcon.glyph(DanaviewGlyphKind.folder, color: DanaviewColors.primaryLight, size: 40),
        title: folder.name,
        subtitle: subtitle ?? (folder.isSystem ? 'Danaview folder · kept by Danaview' : 'Danaview folder'),
        semanticLabel: 'Folder ${folder.name}',
        onTap: onOpen,
        trailing: DanaviewMenuIconTrigger(
          icon: Icons.more_horiz_rounded,
          tooltip: 'More',
          entries: [
            DanaviewMenuItem(label: 'Open', glyph: DanaviewGlyphKind.folderOpen, onTap: onOpen),
            if (editable && onRename != null) DanaviewMenuItem(label: 'Rename…', icon: Icons.edit_rounded, onTap: onRename),
            if (editable && onMove != null) DanaviewMenuItem(label: 'Move to…', glyph: DanaviewGlyphKind.folderOpen, onTap: onMove),
            if (editable && onDelete != null) ...[
              const DanaviewMenuDivider(),
              DanaviewMenuItem(label: 'Delete', icon: Icons.delete_outline_rounded, destructive: true, onTap: onDelete),
            ],
          ],
        ),
      ),
    );
  }
}

/// The breadcrumb trail of a nested folder: `Folders › A › B`, each crumb a ≥ 44 px target.
class FolderBreadcrumbs extends StatelessWidget {
  /// A trail through [path]; [onSelect] gets the crumb's folder (null for the Folders root).
  const FolderBreadcrumbs({super.key, required this.path, required this.onSelect});

  /// The folders from the top level down to the open one.
  final List<LibraryFolder> path;

  /// Opens a crumb.
  final ValueChanged<FolderId?> onSelect;

  @override
  Widget build(BuildContext context) {
    final crumbs = <Widget>[
      _Crumb(label: 'Folders', current: path.isEmpty, onTap: () => onSelect(null)),
      for (var i = 0; i < path.length; i++) ...[
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 2),
          child: Icon(Icons.chevron_right_rounded, size: 18, color: DanaviewColors.textMuted),
        ),
        _Crumb(label: path[i].name, current: i == path.length - 1, onTap: () => onSelect(path[i].id)),
      ],
    ];
    return Semantics(
      container: true,
      label: 'Folder path',
      child: SingleChildScrollView(
        key: const ValueKey('folder-breadcrumbs'),
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(mainAxisSize: MainAxisSize.min, children: crumbs),
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({required this.label, required this.current, required this.onTap});

  final String label;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DanaviewPressable(
      onTap: current ? null : onTap,
      borderRadius: DanaviewRadius.smAll,
      semanticLabel: current ? '$label, current folder' : 'Go to $label',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44, maxWidth: 220),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Align(
            widthFactor: 1,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DanaviewTextStyles.label.copyWith(color: current ? DanaviewColors.textPrimary : DanaviewColors.primaryLight),
            ),
          ),
        ),
      ),
    );
  }
}

/// The days-left text of a Recently deleted row.
String daysLeftLabel(int days) => switch (days) {
      0 => 'Removed today',
      1 => '1 day left',
      _ => '$days days left',
    };

/// The row that opens Recently deleted: how many items and how much space they still use.
class RecentlyDeletedEntryRow extends StatelessWidget {
  /// The row; [usage] gives the count and size.
  const RecentlyDeletedEntryRow({super.key, required this.itemCount, required this.usage, required this.onOpen});

  /// Top-level rows in Recently deleted.
  final int itemCount;

  /// Sizes (trashed files still count towards storage, V2-08).
  final LibraryStorageUsage usage;

  /// Opens the view.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final subtitle = itemCount == 0 ? 'Empty' : '${formatCount(itemCount, 'item')} · ${formatFileSize(usage.trashedBytes)}';
    return DanaviewLibraryRow(
      key: const ValueKey('recently-deleted-row'),
      leading: const DanaviewTileIcon(Icons.delete_outline_rounded, color: DanaviewColors.textSecondary, size: 40),
      title: 'Recently deleted',
      subtitle: subtitle,
      semanticLabel: 'Recently deleted, $subtitle',
      onTap: onOpen,
      trailing: const Padding(
        padding: EdgeInsets.all(DanaviewSpacing.sm),
        child: Icon(Icons.chevron_right_rounded, size: 22, color: DanaviewColors.textMuted),
      ),
    );
  }
}

/// One row of Recently deleted: name, what it holds, days left at [now], and Restore.
class TrashedItemRow extends StatelessWidget {
  /// The row of [item].
  const TrashedItemRow({super.key, required this.item, required this.now, required this.onRestore});

  /// The trashed entry or folder.
  final TrashedItem item;

  /// The store clock's now.
  final DateTime now;

  /// Restores it.
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final days = daysLeftLabel(item.daysLeft(now));
    final what = item.isFolder ? 'Folder · ${formatCount(item.itemCount, 'file')}' : formatFileSize(item.sizeBytes);
    final subtitle = '$days · $what';
    return KeyedSubtree(
      key: ValueKey('trashed-${item.id.value}'),
      child: DanaviewLibraryRow(
        leading: item.isFolder
            ? const DanaviewTileIcon.glyph(DanaviewGlyphKind.folder, color: DanaviewColors.textSecondary, size: 40)
            : DanaviewTileIcon(Icons.insert_drive_file_outlined, color: DanaviewColors.textSecondary, size: 40),
        title: item.name,
        subtitle: subtitle,
        semanticLabel: '${item.isFolder ? 'Folder' : 'File'} ${item.name}, $subtitle',
        trailing: DanaviewButton.ghost(label: 'Restore', size: DanaviewButtonSize.sm, onPressed: onRestore),
      ),
    );
  }
}

/// The **Linked folders** group: the 1.1 Folders section's rows unchanged (P-5).
class LinkedFoldersGroup extends ConsumerStatefulWidget {
  /// The group; [onOpenFolder] opens the 1.1 folder browser, [onOpenPlayer] the player.
  const LinkedFoldersGroup({super.key, required this.onOpenFolder, this.onOpenPlayer});

  /// Opens the 1.1 folder browser at a path.
  final ValueChanged<String> onOpenFolder;

  /// Shows the player after Play all.
  final VoidCallback? onOpenPlayer;

  @override
  ConsumerState<LinkedFoldersGroup> createState() => _LinkedFoldersGroupState();
}

class _LinkedFoldersGroupState extends ConsumerState<LinkedFoldersGroup> {
  bool _busy = false;

  void _play(List<domain.MediaRef> items) {
    if (items.isEmpty) return;
    danaviewPlayItems(ref, items);
    widget.onOpenPlayer?.call();
  }

  Future<void> _addFolder() async {
    if (_busy) return;
    _busy = true;
    try {
      final path = await pickFolderPath();
      if (path == null || !mounted) return;
      final folder = await ref.read(libraryControllerProvider.notifier).addFolder(path);
      if (mounted) showDanaviewSuccess(context, 'Added "${folder.label}" to your library');
    } catch (e) {
      if (mounted) showDanaviewError(context, e);
    } finally {
      _busy = false;
    }
  }

  Future<void> _playFolder(domain.LibraryFolder folder) async {
    final listing = await data.LibraryRepository.browseDirectory(folder.path);
    if (!mounted) return;
    if (listing.hasError) {
      DanaviewToast.show(context, listing.error!, kind: DanaviewToastKind.error, icon: Icons.error_outline_rounded);
    } else if (listing.media.isEmpty) {
      DanaviewToast.show(context, 'No videos directly in "${folder.label}". Open it to browse its folders.', icon: Icons.info_outline_rounded);
    } else {
      _play(listing.media);
    }
  }

  Future<void> _removeFolder(domain.LibraryFolder folder) async {
    final confirmed = await showDanaviewConfirm(
      context,
      title: 'Remove from library',
      message: '"${folder.label}" will be removed from Danaview. Your files stay on disk.',
      confirmLabel: 'Remove',
      destructive: true,
      icon: Icons.remove_circle_outline_rounded,
    );
    if (confirmed) await ref.read(libraryControllerProvider.notifier).removeFolder(folder.path);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryControllerProvider);
    final roots = state.roots;
    return Column(
      key: const ValueKey('linked-folders-group'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DanaviewLibrarySectionHeader(
          'Linked folders',
          prominent: true,
          action: canPickFolders && roots.isNotEmpty
              ? DanaviewButton.ghost(label: 'Add', icon: Icons.add_rounded, size: DanaviewButtonSize.sm, onPressed: _addFolder)
              : null,
        ),
        if (!state.hasLoaded)
          const SizedBox.shrink()
        else if (roots.isEmpty)
          DanaviewInlineEmpty(
            glyph: DanaviewGlyphKind.folderVideo,
            iconColor: DanaviewColors.primaryLight,
            title: 'No folders yet',
            message: canPickFolders
                ? 'Add a folder to browse its videos here. Nothing is copied or moved.'
                : 'Use Open file to add videos from your device.',
            action: canPickFolders
                ? DanaviewButton.tonal(label: 'Add folder', glyph: DanaviewGlyphKind.folderAdd, size: DanaviewButtonSize.sm, onPressed: _addFolder)
                : null,
          )
        else
          // Its own layer, as the 1.1 Home's sliver list gives it, so the rows rasterize
          // pixel-equal to 1.1 wherever the group sits (HOM-08 goldens, P-5).
          RepaintBoundary(child: DanaviewLibraryCardGrid(children: [for (final folder in roots) _row(folder)])),
      ],
    );
  }

  Widget _row(domain.LibraryFolder folder) {
    if (folder.isDevice) {
      return DanaviewLibraryRow(
        leading: const DanaviewTileIcon.glyph(DanaviewGlyphKind.device, color: DanaviewColors.cyan, size: 40),
        title: folder.label,
        subtitle: Theme.of(context).platform == TargetPlatform.iOS
            ? 'Files app › ${data.LibraryStorage.iosFilesLocation(tablet: data.LibraryStorage.isTabletWidth(MediaQuery.sizeOf(context).shortestSide))}'
            : 'Device storage',
        subtitleMaxLines: 2,
        onTap: () => widget.onOpenFolder(folder.path),
        trailing: const Padding(
          padding: EdgeInsets.all(DanaviewSpacing.sm),
          child: Icon(Icons.chevron_right_rounded, size: 22, color: DanaviewColors.textMuted),
        ),
      );
    }
    return DanaviewLibraryRow(
      leading: const DanaviewTileIcon.glyph(DanaviewGlyphKind.folderVideo, size: 40),
      title: folder.label,
      subtitle: folder.path,
      onTap: () => widget.onOpenFolder(folder.path),
      trailing: DanaviewMenuIconTrigger(
        icon: Icons.more_horiz_rounded,
        tooltip: 'More',
        entries: [
          DanaviewMenuItem(label: 'Open', glyph: DanaviewGlyphKind.folderOpen, onTap: () => widget.onOpenFolder(folder.path)),
          DanaviewMenuItem(label: 'Play all', icon: Icons.play_arrow_rounded, onTap: () => _playFolder(folder)),
          const DanaviewMenuDivider(),
          DanaviewMenuItem(
            label: 'Remove from library',
            icon: Icons.remove_circle_outline_rounded,
            destructive: true,
            onTap: () => _removeFolder(folder),
          ),
        ],
      ),
    );
  }
}
