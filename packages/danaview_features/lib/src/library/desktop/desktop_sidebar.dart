// OWNER: HOM-03
//
// The desktop browser sidebar (ARCH v1.2 V2-109, HOM plan D-94): shortcuts to every photo root
// (All photos, the Pictures folders, external drives, folders the user dropped), each a kit list
// tile (≥ 44 px; its semantics read the name and photo count, under the group's header), with a drop target that adds dropped
// folders as roots and hands dropped files on (P-8: the player's own drop target is unchanged).
// [DesktopPhotoSidebar] is the plain widget; [DesktopPhotoSidebarPane] binds it to
// `desktopPhotosControllerProvider`. Danaview kit components only (ARCH §1.4, rule 31).

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sources/desktop_photos_source.dart';
import 'desktop_drop_target.dart';

/// "1 photo", "12 photos".
String desktopPhotoCountLabel(int count) => count == 1 ? '1 photo' : '$count photos';

/// The sidebar subtitle of [status].
String desktopRootSubtitle(DesktopRootStatus status) {
  if (!status.available) return 'Not available';
  if (!status.scanned) return 'Scanning…';
  return desktopPhotoCountLabel(status.photos.length);
}

/// The sidebar of the desktop photo browser.
class DesktopPhotoSidebar extends StatelessWidget {
  /// A sidebar over [state]. [onSelect] gets a root id, or null for All photos; [onRemove] (when
  /// set) is offered on folders the user added.
  const DesktopPhotoSidebar({super.key, required this.state, required this.onSelect, this.onRemove});

  /// The roots and selection.
  final DesktopPhotosState state;

  /// Called with the tapped root id (null: All photos).
  final ValueChanged<String?> onSelect;

  /// Removes a user-added folder.
  final ValueChanged<String>? onRemove;

  @override
  Widget build(BuildContext context) {
    final pictures = state.rootsOf(DesktopRootKind.pictures);
    final volumes = state.rootsOf(DesktopRootKind.volume);
    final custom = state.rootsOf(DesktopRootKind.custom);
    final total = state.roots.fold<int>(0, (n, r) => n + r.photos.length);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Photo locations',
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.sm, vertical: DanaviewSpacing.sm),
        children: [
          DanaviewListTile(
            key: const ValueKey('desktop-root-all'),
            dense: true,
            title: 'All photos',
            subtitle: state.scanning && total == 0 ? 'Scanning…' : desktopPhotoCountLabel(total),
            leading: const DanaviewTileIcon(Icons.photo_library_outlined),
            selected: state.selectedRootId == null,
            onTap: () => onSelect(null),
          ),
          if (pictures.isNotEmpty) ...[
            const DanaviewSectionHeader('Pictures'),
            for (final r in pictures) _tile(r, const DanaviewTileIcon.glyph(DanaviewGlyphKind.folder)),
          ],
          const DanaviewSectionHeader('Drives'),
          if (volumes.isEmpty)
            const Padding(
              key: ValueKey('desktop-no-drives'),
              padding: EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.sm),
              child: Text(
                'Connect a drive or memory card to see its photos here.',
                style: TextStyle(fontSize: 13, height: 1.35, color: DanaviewColors.textSecondary),
              ),
            )
          else
            for (final r in volumes) _tile(r, const DanaviewTileIcon(Icons.sd_storage_outlined)),
          if (custom.isNotEmpty) ...[
            const DanaviewSectionHeader('Added folders'),
            for (final r in custom) _tile(r, const DanaviewTileIcon.glyph(DanaviewGlyphKind.folderOpen), removable: true),
          ],
          const Padding(
            key: ValueKey('desktop-drop-hint'),
            padding: EdgeInsets.fromLTRB(DanaviewSpacing.md, DanaviewSpacing.lg, DanaviewSpacing.md, DanaviewSpacing.sm),
            child: Text(
              'Drop a folder here to add it.',
              style: TextStyle(fontSize: 12, height: 1.35, color: DanaviewColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(DesktopRootStatus status, Widget icon, {bool removable = false}) {
    final subtitle = desktopRootSubtitle(status);
    final remove = onRemove;
    return DanaviewListTile(
      key: ValueKey('desktop-root-${status.root.id}'),
      dense: true,
      title: status.root.label,
      subtitle: subtitle,
      leading: icon,
      enabled: status.available,
      selected: state.selectedRootId == status.root.id,
      onTap: () => onSelect(status.root.id),
      trailing: removable && remove != null
          ? DanaviewIconButton(
              key: ValueKey('desktop-remove-${status.root.id}'),
              icon: Icons.close_rounded,
              size: DanaviewSpacing.minTapTarget,
              tooltip: 'Remove ${status.root.label}',
              semanticLabel: 'Remove ${status.root.label}',
              onPressed: () => remove(status.root.id),
            )
          : null,
    );
  }
}

/// [DesktopPhotoSidebar] bound to `desktopPhotosControllerProvider`, inside a drop target: dropped
/// folders become roots; dropped files go to [onOpenFiles] (when set).
class DesktopPhotoSidebarPane extends ConsumerStatefulWidget {
  /// The bound sidebar.
  const DesktopPhotoSidebarPane({super.key, this.onOpenFiles});

  /// Receives the paths of dropped files (not folders).
  final ValueChanged<List<String>>? onOpenFiles;

  @override
  ConsumerState<DesktopPhotoSidebarPane> createState() => _DesktopPhotoSidebarPaneState();
}

class _DesktopPhotoSidebarPaneState extends ConsumerState<DesktopPhotoSidebarPane> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(desktopPhotosControllerProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(desktopPhotosControllerProvider);
    final controller = ref.read(desktopPhotosControllerProvider.notifier);
    return DesktopFolderDropTarget(
      onDropFolders: (paths) async {
        for (final path in paths) {
          await controller.addFolder(path);
        }
      },
      onDropFiles: widget.onOpenFiles,
      child: DesktopPhotoSidebar(state: state, onSelect: controller.select, onRemove: controller.removeFolder),
    );
  }
}
