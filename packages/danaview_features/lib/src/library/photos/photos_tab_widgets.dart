// OWNER: HOM-10
//
// Pieces of the Photos tab (ARCH v1.2 §1.4, V2-103, V2-108; Q-N8): the album chips, the density
// buttons, the "Show my photo library" opt-in row with its access states, the date-group header
// and the photo cell. Kit components only, Figtree through the kit theme, dark surfaces, targets
// ≥ 44 px, semantics labels on every control; every text is one line with an ellipsis or wraps
// inside a scrollable, so nothing overflows at 280–1280 px and text scale 0.85–1.35.

import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../badges/media_badge_overlay.dart';
import '../sources/system_photos_source.dart';
import '../thumbs/library_thumbnail.dart';
import '../thumbs/thumb_key.dart';
import 'photo_date_groups.dart';
import 'photo_grid_item.dart';
import 'photo_masonry_layout.dart';
import 'photos_tab_providers.dart';

/// The album chips: All photos, Favourites, Danaview folders, then system albums.
class PhotoAlbumChips extends ConsumerWidget {
  /// The chips; [onSelect] gets the chosen album.
  const PhotoAlbumChips({super.key, required this.onSelect});

  /// Called with the album the user picked.
  final ValueChanged<PhotoAlbumSelection> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(effectivePhotoAlbumProvider);
    final folders = ref.watch(danaviewPhotoFoldersProvider);
    final albums = ref.watch(systemPhotoAlbumsProvider).valueOrNull ?? const <SystemPhotoAlbum>[];
    Widget chip(String key, String label, PhotoAlbumSelection value, {IconData? icon}) => Padding(
          padding: const EdgeInsets.only(right: DanaviewSpacing.sm),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: DanaviewChoiceChip(
              key: ValueKey('photos-album-$key'),
              label: label,
              icon: icon,
              selected: selected == value,
              onTap: () => onSelect(value),
            ),
          ),
        );
    return Semantics(
      container: true,
      label: 'Albums',
      child: SingleChildScrollView(
        key: const ValueKey('photos-albums'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md),
        child: Row(children: [
          chip('all', 'All photos', PhotoAlbumSelection.all, icon: Icons.photo_library_outlined),
          chip('favourites', 'Favourites', PhotoAlbumSelection.favourites, icon: Icons.star_border_rounded),
          for (final f in folders) chip(f.id.value, f.name, DanaviewFolderSelection(f.id), icon: Icons.folder_outlined),
          for (final a in albums) chip('system-${a.albumId}', a.title, SystemAlbumSelection(a.albumId), icon: Icons.photo_album_outlined),
        ]),
      ),
    );
  }
}

/// The two density buttons (an accessible alternative to pinching).
class PhotoDensityButtons extends StatelessWidget {
  /// Buttons for [density]; [onChanged] gets the new level.
  const PhotoDensityButtons({super.key, required this.density, required this.onChanged});

  /// The current level.
  final int density;

  /// Called with the new level.
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final densest = photoGridDensityTargets.length - 1;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      DanaviewIconButton(
        key: const ValueKey('photos-density-smaller'),
        icon: Icons.zoom_out_rounded,
        tooltip: 'Smaller photos',
        semanticLabel: 'Show smaller photos',
        onPressed: density < densest ? () => onChanged(density + 1) : null,
      ),
      DanaviewIconButton(
        key: const ValueKey('photos-density-larger'),
        icon: Icons.zoom_in_rounded,
        tooltip: 'Larger photos',
        semanticLabel: 'Show larger photos',
        onPressed: density > 0 ? () => onChanged(density - 1) : null,
      ),
    ]);
  }
}

/// "Show my photo library" (Q-N8) and, once on, what access allows.
class PhotoLibraryOptInRow extends ConsumerWidget {
  /// The row; [onChanged] turns the library on or off.
  const PhotoLibraryOptInRow({super.key, required this.onChanged});

  /// Called with the new opt-in.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(photosLibraryOptInProvider);
    final system = ref.watch(systemPhotosControllerProvider);
    final asked = on && system.available && system.opened;
    final blocked = asked && (system.authorization == PhotoLibraryAuthorization.denied || system.authorization == PhotoLibraryAuthorization.restricted);
    final limited = asked && system.limited;
    final subtitle = !on
        ? 'Only photos in Danaview folders are shown. Turn this on to see your device library too.'
        : blocked
            ? 'Photo access is off. Allow it in Settings to see your library.'
            : limited
                ? 'Showing the photos you selected.'
                : 'Your device photos are shown with your Danaview photos.';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.xs),
      child: DecoratedBox(
        decoration: BoxDecoration(color: DanaviewColors.surface, borderRadius: DanaviewRadius.mdAll, border: DanaviewBorders.all),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DanaviewSwitchRow(
            key: const ValueKey('photos-show-library'),
            title: 'Show my photo library',
            subtitle: subtitle,
            value: on,
            leading: const DanaviewTileIcon(Icons.photo_library_outlined),
            onChanged: onChanged,
          ),
          if (blocked || limited)
            Padding(
              padding: const EdgeInsets.fromLTRB(DanaviewSpacing.md, 0, DanaviewSpacing.md, DanaviewSpacing.sm),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: blocked
                    ? DanaviewButton.secondary(
                        key: const ValueKey('photos-open-settings'),
                        label: 'Open Settings',
                        semanticLabel: 'Open Settings to allow photo access',
                        onPressed: () => ref.read(systemPhotosControllerProvider.notifier).openSettings(),
                      )
                    : DanaviewButton.ghost(
                        key: const ValueKey('photos-manage-selection'),
                        label: 'Manage selection',
                        semanticLabel: 'Manage the selected photos',
                        onPressed: () => ref.read(systemPhotosControllerProvider.notifier).manageLimitedSelection(),
                      ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// The header of one date group.
class PhotoDateHeader extends StatelessWidget {
  /// The header of [group].
  const PhotoDateHeader({super.key, required this.group});

  /// The group.
  final PhotoDateGroup group;

  /// The header height at [textScaler]: one line of the headline style plus padding, ≥ 44.
  static double extentFor(TextScaler textScaler) {
    final line = textScaler.scale(DanaviewTextStyles.headline.fontSize!) * 1.4;
    final h = line + 2 * DanaviewSpacing.md;
    return h < DanaviewSpacing.minTapTarget ? DanaviewSpacing.minTapTarget : h.ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final count = group.count == 1 ? '1 photo' : '${group.count} photos';
    return Semantics(
      header: true,
      label: '${group.label}, $count',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            group.label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: DanaviewTextStyles.headline.copyWith(height: 1.2),
          ),
        ),
      ),
    );
  }
}

/// The semantics label of a cell.
String photoCellLabel(PhotoGridItem photo) {
  final d = photo.date.toLocal();
  final date = '${d.day} ${photoMonthName(d.month)} ${d.year}';
  final base = photo.name.isEmpty ? 'Photo, $date' : 'Photo ${photo.name}, $date';
  final badges = photo.badges.semanticsLabel;
  return badges.isEmpty ? base : '$base, $badges';
}

/// One photo of the grid: its thumbnail (HOM-04), centre-cropped to the cell.
class PhotoGridCell extends StatelessWidget {
  /// The cell of [photo], [cellWidth] wide.
  const PhotoGridCell({super.key, required this.photo, required this.cellWidth, this.onTap, this.onLongPress});

  /// The photo.
  final PhotoGridItem photo;

  /// The column width (picks the thumbnail size class).
  final double cellWidth;

  /// Opens it.
  final VoidCallback? onTap;

  /// Long press (selection, HOM-12).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final sizeClass = cellWidth * dpr <= ThumbSizeClass.s.pixels ? ThumbSizeClass.s : ThumbSizeClass.m;
    return DanaviewPressable(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: photoCellLabel(photo),
      borderRadius: DanaviewRadius.xsAll,
      child: ClipRRect(
        borderRadius: DanaviewRadius.xsAll,
        child: Stack(fit: StackFit.expand, children: [
          LibraryThumbnail(
            itemId: photo.id.value,
            source: photo.thumbSource,
            modifiedAt: photo.modifiedAt,
            sizeClass: sizeClass,
            placeholder: const Icon(Icons.image_outlined, size: 20, color: DanaviewColors.textMuted),
          ),
          if (photo.isFavourite)
            const PositionedDirectional(
              start: 4,
              bottom: 4,
              child: Icon(Icons.star_rounded, size: 14, color: DanaviewColors.warning),
            ),
          MediaBadgeOverlay(badges: photo.badges, excludeSemantics: true),
        ]),
      ),
    );
  }
}
