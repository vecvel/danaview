// OWNER: HOM-09
//
// The Recent photos tray of the Overview (BUILD_PLAN HOM-09; HOM plan §5.1 "Recent photos &
// stills", §2 item 6; ARCH v1.2 V2-101, V2-102, V2-103; Q-N8): a horizontal carousel of the newest
// photos from every Danaview folder and, once the user opted in to "Show my photo library" on the
// Photos tab (Q-N8 default: off), the system photo library (PhotoKit, MediaStore) and the desktop
// Pictures folders. It is additive: it sits in HOM-05's Overview slot below Continue watching and
// draws nothing when there are no photos or when DANAVIEW_FILES_HOME is off, so the 1.1 Home stays
// exactly as it is (ARCH v1.2 §1.5).
//
// * Tap opens the photo in the viewer (HOM-11) through [RecentPhotosTray.onOpenPhoto], with the
//   whole newest-first list so the viewer can swipe past the tray's last photo.
// * See all opens the Photos tab: [RecentPhotosTray.onSeeAll] when set, otherwise a
//   [HomeTabRequestNotification] for [HomeTab.photos] bubbles up to the Home shell.
// * The system photos come from the tray's own listing of the whole library
//   ([recentSystemPhotosProvider]), so an album picked on the Photos tab does not narrow it.
// * The tray never asks for photo access: it lists the system library only after the opt-in, and
//   then only when the OS already grants read access (checked without prompting); a stored opt-in
//   with access not yet decided leaves the library unlisted until the Photos tab asks (V2-103).

import 'dart:async';

import 'package:danaview_library_native/danaview_library_native.dart' show LibraryNativeException, SystemPhotoFilter;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../flags.dart';
import '../library_widgets.dart';
import '../photos/photo_grid_item.dart';
import '../photos/photos_tab_providers.dart';
import '../photos/photos_tab_widgets.dart' show photoCellLabel;
import '../sources/desktop_photos_source.dart';
import '../sources/system_photos_source.dart';
import '../thumbs/library_thumbnail.dart';
import '../thumbs/thumb_key.dart' show ThumbSizeClass;
import 'home_tabs.dart';

export 'home_tabs.dart' show HomeTabRequestNotification;

/// How many photos the tray shows at most (a "See all" tile follows when there are more).
const int recentPhotosTrayLimit = 20;

/// Opens [photos] (newest first) at [index] in the viewer (HOM-11).
typedef RecentPhotosOpen = void Function(List<PhotoGridItem> photos, int index);

/// The newest system-library photos of the tray: the first page of the whole library, photos only,
/// listed on its own so the Photos tab's album choice never narrows the Overview (HOM §2 item 6).
@immutable
class RecentSystemPhotos {
  /// [items] newest first, out of [totalCount] photos in the whole library.
  const RecentSystemPhotos(this.items, this.totalCount);

  /// Nothing listed (not opted in, no access, no system library).
  static const RecentSystemPhotos none = RecentSystemPhotos([], 0);

  /// The newest photos.
  final List<PhotoGridItem> items;

  /// Photos in the whole library.
  final int totalCount;
}

/// The newest [limit] photos of the whole system library, whatever album the Photos tab lists.
/// It lists only after the opt-in (Q-N8) and once the shared controller holds readable access (the
/// tray never asks for access itself), and lists again when that controller sees the library
/// change (a new snapshot token or reloaded items).
final recentSystemPhotosProvider = FutureProvider.autoDispose.family<RecentSystemPhotos, int>((ref, limit) async {
  if (!ref.watch(photosLibraryOptInProvider)) return RecentSystemPhotos.none;
  final library = ref.watch(systemPhotoLibraryProvider);
  final platform = ref.watch(systemPhotosControllerProvider.select((s) => s.platform));
  final readable = ref.watch(systemPhotosControllerProvider.select((s) => s.opened && s.authorization.canRead));
  // Library changes reach the shared controller first (it observes); follow its snapshots.
  ref.watch(systemPhotosControllerProvider.select((s) => s.changeToken));
  ref.watch(systemPhotosControllerProvider.select((s) => s.items));
  if (library == null || platform == null || !readable) return RecentSystemPhotos.none;
  try {
    final page = await library.fetchPage(filter: SystemPhotoFilter.photos, limit: limit);
    final items = <PhotoGridItem>[];
    for (final asset in page.assets) {
      try {
        final item = systemMediaItem(asset, platform);
        if (item is PhotoMediaItem) items.add(photoGridItemOf(item, PhotoOrigin.system));
      } on FormatException {
        // A platform id outside the V2-09 rules is skipped, as on the Photos tab.
      }
    }
    final total = page.totalCount < items.length ? items.length : page.totalCount;
    return RecentSystemPhotos(List.unmodifiable(items), total);
  } on LibraryNativeException {
    return RecentSystemPhotos.none;
  }
});

/// The tray's photos: [items] newest first, out of [totalCount] recent photos in all.
@immutable
class RecentPhotos {
  /// [items] out of [totalCount].
  const RecentPhotos(this.items, this.totalCount);

  /// The photos the tray can show and hand to the viewer, newest first.
  final List<PhotoGridItem> items;

  /// Every photo the Photos tab holds (the system library counted whole), for the "+N" tile.
  final int totalCount;
}

/// The recent photos for a [limit]-tile tray, newest first: the Danaview photos and, after the
/// opt-in (Q-N8), the newest photos of the whole system library and the desktop Pictures folders.
final recentPhotosProvider = Provider.autoDispose.family<RecentPhotos, int>((ref, limit) {
  final danaview = ref.watch(danaviewPhotoItemsProvider);
  final system = ref.watch(recentSystemPhotosProvider(limit)).valueOrNull ?? RecentSystemPhotos.none;
  final desktop = ref.watch(desktopPhotoItemsProvider);
  final items = mergeNewestFirst(mergeNewestFirst(danaview, system.items), desktop);
  return RecentPhotos(items, danaview.length + system.totalCount + desktop.length);
});

/// The square tile side of the tray for a [width]-wide Overview: about three tiles on a phone,
/// more on wider screens, never under the 88 px that keeps the target well above 44 px.
double recentPhotosTileExtent(double width) {
  if (!width.isFinite || width <= 0) return 112;
  final perRow = width < 480 ? 3.3 : (width < 900 ? 4.6 : 6.6);
  return (width / perRow).clamp(88.0, 148.0);
}

/// The gap between tiles.
const double _tileGap = DanaviewSpacing.sm;

/// The Recent photos tray.
class RecentPhotosTray extends ConsumerStatefulWidget {
  /// The tray; [onOpenPhoto] opens a photo (null makes the tiles inert), [onSeeAll] opens the
  /// Photos tab (null bubbles a [HomeTabRequestNotification]).
  const RecentPhotosTray({super.key, this.onOpenPhoto, this.onSeeAll, this.limit = recentPhotosTrayLimit})
      : assert(limit > 0);

  /// Opens a photo in the viewer.
  final RecentPhotosOpen? onOpenPhoto;

  /// Opens the Photos tab.
  final VoidCallback? onSeeAll;

  /// How many photos are shown at most.
  final int limit;

  @override
  ConsumerState<RecentPhotosTray> createState() => _RecentPhotosTrayState();
}

class _RecentPhotosTrayState extends ConsumerState<RecentPhotosTray> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && FeatureFlags.filesHomeEnabled && ref.read(photosLibraryOptInProvider)) _loadLibrary();
    });
  }

  /// Opens the shared system controller (access, observing) and lists the desktop folders if
  /// nothing did yet (the Overview usually shows before the Photos tab). The tray's own system
  /// listing ([recentSystemPhotosProvider]) covers the whole library; the Photos tab's album filter
  /// is left as it is.
  void _loadLibrary() {
    final system = ref.read(systemPhotosControllerProvider);
    if (system.available && !system.opened) {
      final controller = ref.read(systemPhotosControllerProvider.notifier);
      unawaited(controller.setFilter(SystemPhotoFilter.photos, albumId: system.albumId).then((_) async {
        // The stored opt-in can disagree with the OS (a backup restored on a new device, reset
        // privacy settings, the app killed during the first prompt): read the access without
        // prompting and open only when it is already readable. Otherwise the system library stays
        // unlisted until the Photos tab's own opt-in asks (V2-103).
        await controller.refreshAuthorization();
        if (!mounted) return;
        final now = ref.read(systemPhotosControllerProvider);
        if (!now.opened && now.authorization.canRead) await controller.open();
      }));
    }
    if (ref.read(desktopRootResolverProvider) != null) {
      final desktop = ref.read(desktopPhotosControllerProvider);
      if (desktop.roots.isEmpty && !desktop.scanning) unawaited(ref.read(desktopPhotosControllerProvider.notifier).refresh());
    }
  }

  void _seeAll(BuildContext context) {
    final onSeeAll = widget.onSeeAll;
    if (onSeeAll != null) {
      onSeeAll();
    } else {
      const HomeTabRequestNotification(HomeTab.photos).dispatch(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!FeatureFlags.filesHomeEnabled) return const SizedBox.shrink();
    final recent = ref.watch(recentPhotosProvider(widget.limit));
    final photos = recent.items;
    if (photos.isEmpty) return const SizedBox.shrink(key: ValueKey('recent-photos-hidden'));
    final shown = photos.length < widget.limit ? photos.length : widget.limit;
    final remaining = (recent.totalCount < photos.length ? photos.length : recent.totalCount) - shown;
    final more = remaining > 0;
    final open = widget.onOpenPhoto;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Column(
        key: const ValueKey('recent-photos-tray'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          DanaviewLibrarySectionHeader(
            'Recent photos',
            action: DanaviewButton.ghost(
              key: const ValueKey('recent-photos-see-all'),
              label: 'See all',
              size: DanaviewButtonSize.sm,
              onPressed: () => _seeAll(context),
            ),
          ),
          LayoutBuilder(builder: (context, constraints) {
            final extent = recentPhotosTileExtent(constraints.maxWidth);
            final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
            final sizeClass = extent * dpr <= ThumbSizeClass.s.pixels ? ThumbSizeClass.s : ThumbSizeClass.m;
            final count = shown + (more ? 1 : 0);
            return SizedBox(
              height: extent,
              child: ListView.separated(
                key: const PageStorageKey('recent-photos-list'),
                scrollDirection: Axis.horizontal,
                itemCount: count,
                separatorBuilder: (_, __) => const SizedBox(width: _tileGap),
                itemBuilder: (context, i) {
                  if (i == shown) {
                    return _SeeAllTile(
                      key: const ValueKey('recent-photos-more'),
                      extent: extent,
                      remaining: remaining,
                      onTap: () => _seeAll(context),
                    );
                  }
                  final photo = photos[i];
                  return _RecentPhotoTile(
                    key: ValueKey('recent-photo-${photo.id.value}'),
                    photo: photo,
                    extent: extent,
                    sizeClass: sizeClass,
                    onTap: open == null ? null : () => open(photos, i),
                  );
                },
              ),
            );
          }),
        ],
      ),
    );
  }
}

/// One square photo of the tray.
class _RecentPhotoTile extends StatelessWidget {
  const _RecentPhotoTile({super.key, required this.photo, required this.extent, required this.sizeClass, this.onTap});

  final PhotoGridItem photo;
  final double extent;
  final ThumbSizeClass sizeClass;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: extent,
        child: DanaviewPressable(
          onTap: onTap,
          semanticLabel: photoCellLabel(photo),
          borderRadius: DanaviewRadius.mdAll,
          child: ClipRRect(
            borderRadius: DanaviewRadius.mdAll,
            child: Stack(fit: StackFit.expand, children: [
              LibraryThumbnail(
                itemId: photo.id.value,
                source: photo.thumbSource,
                modifiedAt: photo.modifiedAt,
                sizeClass: sizeClass,
                placeholder: const Icon(Icons.image_outlined, size: 24, color: DanaviewColors.textMuted),
              ),
              if (photo.isFavourite)
                const PositionedDirectional(
                  start: 6,
                  bottom: 6,
                  child: Icon(Icons.star_rounded, size: 16, color: DanaviewColors.warning),
                ),
            ]),
          ),
        ),
      );
}

/// The trailing tile when the tray holds more photos than it shows.
class _SeeAllTile extends StatelessWidget {
  const _SeeAllTile({super.key, required this.extent, required this.remaining, required this.onTap});

  final double extent;
  final int remaining;
  final VoidCallback onTap;

  /// The tile fill; its text colour is computed from it (ARCH §1.4).
  static const Color fill = DanaviewColors.surfaceElevated;

  @override
  Widget build(BuildContext context) {
    final foreground = DanaviewColors.foregroundOn(fill);
    return SizedBox.square(
      dimension: extent,
      child: DanaviewPressable(
        onTap: onTap,
        semanticLabel: 'See all photos, $remaining more',
        borderRadius: DanaviewRadius.mdAll,
        child: DecoratedBox(
          decoration: const BoxDecoration(color: fill, borderRadius: DanaviewRadius.mdAll),
          child: Padding(
            padding: const EdgeInsets.all(DanaviewSpacing.sm),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: ExcludeSemantics(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.photo_library_outlined, size: 24, color: foreground),
                    const SizedBox(height: DanaviewSpacing.xs),
                    Text('+$remaining', maxLines: 1, style: DanaviewTextStyles.title.copyWith(color: foreground)),
                    Text('See all', maxLines: 1, style: DanaviewTextStyles.caption.copyWith(color: foreground)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
