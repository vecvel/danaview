// OWNER: HOM-19
//
// Organise UI (HOM plan §8.1, D-98f / V2-119; ARCH §1.4): the favourite star, the Favourites filter
// toggle, the Favourites row of the Overview (HOM-05 hosts it in its slot), the Recents section
// with its one Clear button, and the sort button (mode and direction, remembered per folder or
// list). Kit components only, Figtree through the kit theme, dark surfaces, ≥ 44 px targets,
// semantics labels on every control, no overflow at 280–1280 px and text scale 0.85–1.35
// (test/v12/organise/). Without a store (DANAVIEW_FILES_HOME off) the row and the section render
// nothing.

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'organise_providers.dart';

/// The icon of a file kind (folders draw the kit's folder glyph).
IconData organiseKindIcon(FileKind kind) => switch (kind) {
      FileKind.video => Icons.movie_outlined,
      FileKind.photo => Icons.image_outlined,
      FileKind.document => Icons.description_outlined,
      FileKind.audio => Icons.music_note_outlined,
      FileKind.other => Icons.insert_drive_file_outlined,
    };

/// The singular label of a file kind.
String organiseKindLabel(FileKind kind) => switch (kind) {
      FileKind.video => 'Video',
      FileKind.photo => 'Photo',
      FileKind.document => 'Document',
      FileKind.audio => 'Audio',
      FileKind.other => 'File',
    };

/// The star on a Danaview file or folder: toggles its favourite. Disabled without a store.
class FavouriteToggleButton extends ConsumerWidget {
  /// The star of [id]; [name] goes into the semantics label.
  const FavouriteToggleButton({super.key, required this.id, required this.name, this.size = 40});

  /// The item.
  final ItemId id;

  /// Its name.
  final String name;

  /// The visual circle diameter (the hit area is at least 44).
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final organiser = ref.watch(libraryOrganiserProvider);
    final starred = ref.watch(isFavouriteProvider(id));
    return DanaviewIconButton(
      key: ValueKey('favourite-toggle-${id.value}'),
      icon: starred ? Icons.star_rounded : Icons.star_border_rounded,
      color: starred ? DanaviewColors.warning : null,
      selected: starred,
      size: size,
      tooltip: starred ? 'Remove from favourites' : 'Add to favourites',
      semanticLabel: starred ? 'Remove $name from favourites' : 'Add $name to favourites',
      onPressed: organiser == null ? null : () => organiser.setFavourite(id, !starred),
    );
  }
}

/// The Favourites filter toggle of the Home tabs.
class FavouritesFilterToggle extends StatelessWidget {
  /// A toggle showing [selected]; [onChanged] gets the new state.
  const FavouritesFilterToggle({super.key, required this.selected, required this.onChanged});

  /// The label.
  static const String label = 'Favourites';

  /// On.
  final bool selected;

  /// Called with the new state.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
        label: selected ? 'Favourites filter, on' : 'Favourites filter, off',
        excludeSemantics: true,
        button: true,
        toggled: selected,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: DanaviewSpacing.minTapTarget),
          child: Center(
            widthFactor: 1,
            child: DanaviewChoiceChip(
              key: const ValueKey('favourites-filter'),
              label: label,
              icon: Icons.star_rounded,
              selected: selected,
              onTap: () => onChanged(!selected),
            ),
          ),
        ),
      );
}

/// The Favourites row of the Overview: starred folders then files, scrolling sideways. Renders
/// nothing when there are none (or no store).
class FavouritesRow extends ConsumerWidget {
  /// A row; [onOpen] opens a folder or a file.
  const FavouritesRow({super.key, required this.onOpen});

  /// The header.
  static const String title = 'Favourites';

  /// Opens the tapped item.
  final ValueChanged<FavouriteItem> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(favouritesProvider);
    if (items.isEmpty) return const SizedBox.shrink();
    final scale = MediaQuery.textScalerOf(context).scale(1);
    // Icon 48 + gaps 8 + two caption lines, grown with the text.
    final height = 48 + 8 + 2 * 16 * scale + 16;
    return Column(
      key: const ValueKey('favourites-row'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DanaviewSectionHeader(title, subtitle: '${items.length}'),
        SizedBox(
          height: height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: DanaviewSpacing.sm),
            itemBuilder: (context, i) => _FavouriteTile(item: items[i], onTap: () => onOpen(items[i])),
          ),
        ),
      ],
    );
  }
}

class _FavouriteTile extends StatelessWidget {
  const _FavouriteTile({required this.item, required this.onTap});

  final FavouriteItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, kindLabel) = switch (item) {
      FavouriteFolder() => (null, 'Folder'),
      FavouriteEntry(:final entry) => (organiseKindIcon(entry.kind), organiseKindLabel(entry.kind)),
    };
    return DanaviewPressable(
      key: ValueKey('favourite-${item.id.value}'),
      onTap: onTap,
      semanticLabel: '$kindLabel ${item.name}, favourite',
      borderRadius: DanaviewRadius.mdAll,
      child: ExcludeSemantics(
        child: SizedBox(
          width: 104,
          child: Padding(
            padding: const EdgeInsets.all(DanaviewSpacing.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon == null ? const DanaviewTileIcon.glyph(DanaviewGlyphKind.folder, size: 48) : DanaviewTileIcon(icon, size: 48),
                const SizedBox(height: DanaviewSpacing.sm),
                Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textPrimary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Recents section: the last files opened in any viewer and one Clear button. Renders nothing
/// when empty (or no store).
class RecentFilesSection extends ConsumerWidget {
  /// A section showing at most [maxRows] rows; [onOpen] opens a file.
  const RecentFilesSection({super.key, required this.onOpen, this.maxRows = recentsCap});

  /// The header.
  static const String title = 'Recents';

  /// Opens the tapped file.
  final ValueChanged<FileEntry> onOpen;

  /// The most rows shown.
  final int maxRows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recents = ref.watch(recentFilesProvider);
    if (recents.isEmpty) return const SizedBox.shrink();
    final organiser = ref.watch(libraryOrganiserProvider);
    return Column(
      key: const ValueKey('recents-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DanaviewSectionHeader(
          title,
          action: DanaviewButton(
            key: const ValueKey('recents-clear'),
            label: 'Clear',
            variant: DanaviewButtonVariant.ghost,
            size: DanaviewButtonSize.sm,
            semanticLabel: 'Clear recents',
            onPressed: organiser == null ? null : organiser.clearRecents,
          ),
        ),
        for (final e in recents.take(maxRows))
          DanaviewListTile(
            key: ValueKey('recent-${e.id.value}'),
            title: e.displayName,
            subtitle: organiseKindLabel(e.kind),
            leading: DanaviewTileIcon(organiseKindIcon(e.kind)),
            semanticLabel: '${organiseKindLabel(e.kind)} ${e.displayName}, opened recently',
            onTap: () => onOpen(e),
          ),
      ],
    );
  }
}

/// The sort button of a list: a menu of modes and the direction, remembered for [scope].
class LibrarySortButton extends ConsumerWidget {
  /// The sort button of [scope]. [modes] limits the menu (folders and linked lists may drop
  /// [LibrarySortMode.size] when sizes are unknown).
  const LibrarySortButton({super.key, required this.scope, this.modes = LibrarySortMode.values});

  /// The list.
  final SortScope scope;

  /// The modes offered.
  final List<LibrarySortMode> modes;

  static String directionLabel(LibrarySortMode mode, {required bool descending}) => switch (mode) {
        LibrarySortMode.name || LibrarySortMode.type => descending ? 'Z to A' : 'A to Z',
        LibrarySortMode.dateAdded || LibrarySortMode.dateModified => descending ? 'Newest first' : 'Oldest first',
        LibrarySortMode.size => descending ? 'Largest first' : 'Smallest first',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sort = ref.watch(librarySortProvider(scope));
    final memory = ref.read(librarySortMemoryProvider);
    return DanaviewMenuIconTrigger(
      key: const ValueKey('library-sort'),
      icon: Icons.sort_rounded,
      tooltip: 'Sort',
      semanticLabel: 'Sort by ${sort.mode.label}, ${directionLabel(sort.mode, descending: sort.descending)}',
      menuWidth: 220,
      entries: [
        const DanaviewMenuHeader('Sort by'),
        for (final mode in modes)
          DanaviewMenuItem(
            label: mode.label,
            selected: mode == sort.mode,
            onTap: () => memory.remember(scope, sort.withMode(mode)),
          ),
        const DanaviewMenuDivider(),
        for (final descending in [false, true])
          DanaviewMenuItem(
            label: directionLabel(sort.mode, descending: descending),
            selected: descending == sort.descending,
            onTap: () => memory.remember(scope, LibrarySort(sort.mode, descending: descending)),
          ),
      ],
    );
  }
}
