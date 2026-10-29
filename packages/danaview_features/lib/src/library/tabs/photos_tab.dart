// OWNER: HOM-10
//
// The Photos tab (ARCH v1.2 V2-102, V2-103, V2-108; HOM plan §5.2, D-87, D-93; Q-N8; BUILD_PLAN
// HOM-10): the album chips and density buttons over a virtualised masonry grid of every photo,
// grouped by date (Today, Yesterday, This month, then months). Danaview folders are shown by
// default; the "Show my photo library" row opts in to the system library (PhotoKit, MediaStore)
// and, on desktop, the Pictures folders — access is asked only then. Pinch (or a trackpad pinch,
// Ctrl/Cmd + plus/minus, or the density buttons) changes the number of columns while keeping the
// first visible photo in place. The tab remembers density, album and scroll offset for the app's
// lifetime, so switching tabs and coming back lands on the same photo. The 1.1 Home is untouched:
// HOM-05 shows this tab only with DANAVIEW_FILES_HOME on.
//
// DESIGN_SYSTEM §10.4: the grid is a full-width square grid with 2 pt gaps (3 / 5 / 8 columns by
// width at the default density, [photoGridSquareColumns]); the masonry layout lays square cells
// out row by row. The date-group header of the photos at the top stays pinned over the grid
// (sticky month headers) until the next group's header pushes it away.

import 'dart:async';
import 'dart:math' as math;

import 'package:danaview_library_native/danaview_library_native.dart' show SystemPhotoFilter;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../photos/photo_date_groups.dart' show PhotoDateGroup;
import '../photos/photo_grid_item.dart';
import '../photos/photo_masonry_layout.dart';
import '../photos/photos_tab_providers.dart';
import '../photos/photos_tab_widgets.dart';
import '../photos/sliver_photo_masonry.dart';
import '../sources/desktop_photos_source.dart';
import '../sources/system_photos_source.dart';

export '../photos/photo_grid_item.dart' show PhotoGridItem, PhotoOrigin;

/// Opens [photos] at [index] (the viewer, HOM-11).
typedef PhotosTabOpen = void Function(List<PhotoGridItem> photos, int index);

/// The Photos tab.
class PhotosTab extends ConsumerStatefulWidget {
  /// The tab; [onOpenPhoto] opens a photo, [onLongPressPhoto] starts a selection (HOM-12).
  const PhotosTab({super.key, this.onOpenPhoto, this.onLongPressPhoto});

  /// Opens a photo in the viewer.
  final PhotosTabOpen? onOpenPhoto;

  /// Long press on a photo.
  final ValueChanged<PhotoGridItem>? onLongPressPhoto;

  @override
  ConsumerState<PhotosTab> createState() => _PhotosTabState();
}

/// Horizontal inset (none: full width) and gap of the grid.
const double _gridPadding = 0;
const double _gridSpacing = 2;

/// Pinch ratio that steps one density level.
const double _pinchStep = 1.25;

class _PhotosTabState extends ConsumerState<PhotosTab> {
  late final ScrollController _scroll;
  final FocusNode _focus = FocusNode(debugLabel: 'Photos tab');
  final GlobalKey _gridKey = GlobalKey();
  final Map<int, Offset> _pointers = {};
  double? _pinchBaseline;
  double _panZoomBaseline = 1;

  // Layout memo: recomputed only when the model, width, columns or header height change.
  PhotosGridModel? _memoModel;
  double _memoWidth = -1;
  int _memoColumns = -1;
  double _memoHeader = -1;
  PhotoMasonryLayout? _memoLayout;

  @override
  void initState() {
    super.initState();
    final memory = ref.read(photosTabMemoryProvider.notifier);
    _scroll = ScrollController(initialScrollOffset: memory.scrollOffset, keepScrollOffset: false);
    _scroll.addListener(_onScrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(photosLibraryOptInProvider)) _showLibrary();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScrolled);
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScrolled() {
    if (!_scroll.hasClients) return;
    ref.read(photosTabMemoryProvider.notifier).scrollOffset = _scroll.offset;
    _maybeLoadMore();
  }

  /// Starts listing the system library (asks for access the first time, V2-103) and the desktop
  /// Pictures folders.
  void _showLibrary() {
    final system = ref.read(systemPhotosControllerProvider.notifier);
    final album = ref.read(effectivePhotoAlbumProvider);
    final state = ref.read(systemPhotosControllerProvider);
    if (state.available) {
      unawaited(system
          .setFilter(SystemPhotoFilter.photos, albumId: album is SystemAlbumSelection ? album.albumId : null)
          .then((_) => state.opened ? null : system.open()));
    }
    if (ref.read(desktopRootResolverProvider) != null) unawaited(ref.read(desktopPhotosControllerProvider.notifier).refresh());
  }

  Future<void> _setOptIn(bool on) async {
    await ref.read(photosLibraryOptInProvider.notifier).set(on);
    if (!mounted) return;
    if (on) _showLibrary();
  }

  void _selectAlbum(PhotoAlbumSelection album) {
    final previous = ref.read(effectivePhotoAlbumProvider);
    ref.read(photosTabMemoryProvider.notifier).setAlbum(album);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (album is SystemAlbumSelection || previous is SystemAlbumSelection) {
      final albumId = album is SystemAlbumSelection ? album.albumId : null;
      unawaited(ref.read(systemPhotosControllerProvider.notifier).setFilter(SystemPhotoFilter.photos, albumId: albumId));
    }
  }

  void _maybeLoadMore() {
    final state = ref.read(systemPhotosControllerProvider);
    if (!ref.read(photosLibraryOptInProvider) || !state.opened || state.loading || state.complete) return;
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    if (position.extentAfter < position.viewportDimension * 2) unawaited(ref.read(systemPhotosControllerProvider.notifier).loadMore());
  }

  /// Steps the density by [delta] levels, keeping the first visible photo at the top.
  void _changeDensity(int delta) {
    final memory = ref.read(photosTabMemoryProvider.notifier);
    final current = ref.read(photosTabMemoryProvider).density;
    final next = (current + delta).clamp(0, photoGridDensityTargets.length - 1);
    if (next == current) return;
    final anchor = _firstVisiblePhoto();
    memory.setDensity(next);
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final layout = _memoLayout;
      if (!mounted || layout == null || !_scroll.hasClients || anchor >= layout.photoCount) return;
      final target = _gridStart() + layout.topOf(layout.childOfPhoto(anchor));
      _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  double _gridStart() {
    final render = _gridKey.currentContext?.findRenderObject();
    return render is RenderSliver ? render.constraints.precedingScrollExtent : 0;
  }

  /// [_gridStart] for the sticky header, which can build before the grid's first layout: the last
  /// laid-out value until then (null before any).
  double? _laidOutGridStart() {
    final render = _gridKey.currentContext?.findRenderObject();
    if (render is! RenderSliver || render.geometry == null) return null;
    return render.constraints.precedingScrollExtent;
  }

  int? _firstVisiblePhoto() {
    final layout = _memoLayout;
    if (layout == null || layout.photoCount == 0 || !_scroll.hasClients) return null;
    final offset = math.max(0.0, _scroll.offset - _gridStart());
    final range = layout.visibleRange(offset, offset + 1);
    if (range == null) return null;
    for (var i = range.$1; i < layout.childCount; i++) {
      if (!layout.isHeader(i)) return layout.photoOf(i);
    }
    return null;
  }

  // Pinch from raw pointers, so the scroll view keeps every one-finger drag.
  double _span() {
    final points = _pointers.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) _pinchBaseline = _span();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final base = _pinchBaseline;
    if (_pointers.length < 2 || base == null || base <= 0) return;
    final ratio = _span() / base;
    if (ratio >= _pinchStep) {
      _changeDensity(-1);
      _pinchBaseline = _span();
    } else if (ratio <= 1 / _pinchStep) {
      _changeDensity(1);
      _pinchBaseline = _span();
    }
  }

  void _onPointerEnd(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) _pinchBaseline = null;
  }

  void _onPanZoomStart(PointerPanZoomStartEvent e) => _panZoomBaseline = 1;

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    final ratio = e.scale / _panZoomBaseline;
    if (ratio >= _pinchStep) {
      _changeDensity(-1);
      _panZoomBaseline = e.scale;
    } else if (ratio <= 1 / _pinchStep) {
      _changeDensity(1);
      _panZoomBaseline = e.scale;
    }
  }

  PhotoMasonryLayout _layoutFor(PhotosGridModel model, double width, int columns, double header) {
    final memo = _memoLayout;
    if (memo != null && identical(model, _memoModel) && width == _memoWidth && columns == _memoColumns && header == _memoHeader) {
      return memo;
    }
    final layout = PhotoMasonryLayout.compute(
      buckets: model.buckets,
      groups: model.groups,
      width: width,
      columns: columns,
      headerExtent: header,
      padding: _gridPadding,
      spacing: _gridSpacing,
      square: true,
    );
    _memoModel = model;
    _memoWidth = width;
    _memoColumns = columns;
    _memoHeader = header;
    _memoLayout = layout;
    return layout;
  }

  @override
  Widget build(BuildContext context) {
    final model = ref.watch(photosGridModelProvider);
    final density = ref.watch(photosTabMemoryProvider.select((v) => v.density));
    final album = ref.watch(effectivePhotoAlbumProvider);
    final libraryAvailable = ref.watch(photosSystemLibraryAvailableProvider);
    final optIn = ref.watch(photosLibraryOptInProvider);
    // A page landing near the end of a short grid asks for the next one.
    ref.listen(systemPhotosControllerProvider.select((s) => s.items.length), (_, __) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeLoadMore();
      });
    });
    final header = PhotoDateHeader.extentFor(MediaQuery.textScalerOf(context));
    final open = widget.onOpenPhoto;
    final longPress = widget.onLongPressPhoto;

    final toolbar = Padding(
      padding: const EdgeInsets.only(top: DanaviewSpacing.xs, right: DanaviewSpacing.xs),
      child: Row(children: [
        Expanded(child: PhotoAlbumChips(onSelect: _selectAlbum)),
        PhotoDensityButtons(density: density, onChanged: (level) => _changeDensity(level - density)),
      ]),
    );

    final grid = LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = photoGridSquareColumns(math.max(0.0, width - 2 * _gridPadding), density, spacing: _gridSpacing);
      final layout = _layoutFor(model, width, columns, header);
      return Semantics(
        customSemanticsActions: {
          if (density > 0) const CustomSemanticsAction(label: 'Show larger photos'): () => _changeDensity(-1),
          if (density < photoGridDensityTargets.length - 1)
            const CustomSemanticsAction(label: 'Show smaller photos'): () => _changeDensity(1),
        },
        child: Stack(children: [
          CustomScrollView(
            key: const ValueKey('photos-grid'),
            controller: _scroll,
            slivers: [
              if (libraryAvailable) SliverToBoxAdapter(child: PhotoLibraryOptInRow(onChanged: _setOptIn)),
              if (model.isEmpty)
                SliverToBoxAdapter(
                  child: Center(
                    child: DanaviewEmptyState(
                      key: const ValueKey('photos-empty'),
                      icon: Icons.photo_library_outlined,
                      title: album is AllPhotosSelection ? 'No photos yet' : 'No photos here',
                      message: album is AllPhotosSelection
                          ? (libraryAvailable && !optIn
                              ? 'Import photos into a Danaview folder, or show your photo library.'
                              : 'Import photos into a Danaview folder to see them here.')
                          : 'Photos you add to this album appear here.',
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.only(top: DanaviewSpacing.xs, bottom: DanaviewSpacing.xl),
                  sliver: SliverPhotoMasonry(
                    key: _gridKey,
                    layout: layout,
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        if (index >= layout.childCount) return null;
                        if (layout.isHeader(index)) return PhotoDateHeader(group: model.groups[layout.groupOf(index)]);
                        final p = layout.photoOf(index);
                        final photo = model.photos[p];
                        return PhotoGridCell(
                          key: ValueKey(photo.id.value),
                          photo: photo,
                          cellWidth: layout.cellWidth,
                          onTap: open == null ? null : () => open(model.photos, p),
                          onLongPress: longPress == null ? null : () => longPress(photo),
                        );
                      },
                      childCount: layout.childCount,
                      addAutomaticKeepAlives: false,
                    ),
                  ),
                ),
            ],
          ),
          if (!model.isEmpty)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _StickyGroupHeader(
                scroll: _scroll,
                layout: layout,
                groups: model.groups,
                extent: header,
                gridStart: _laidOutGridStart,
              ),
            ),
        ]),
      );
    });

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () => _changeDensity(-1),
        const SingleActivator(LogicalKeyboardKey.equal, meta: true): () => _changeDensity(-1),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () => _changeDensity(1),
        const SingleActivator(LogicalKeyboardKey.minus, meta: true): () => _changeDensity(1),
      },
      child: Focus(
        key: const ValueKey('photos-tab-focus'),
        focusNode: _focus,
        child: ColoredBox(
          color: DanaviewColors.background,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            toolbar,
            Expanded(
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerEnd,
                onPointerCancel: _onPointerEnd,
                onPointerPanZoomStart: _onPanZoomStart,
                onPointerPanZoomUpdate: _onPanZoomUpdate,
                child: grid,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The pinned date-group header over the grid (sticky month headers, §10.4): it shows the group of
/// the photos at the top of the viewport once its own header has scrolled away, and the next
/// group's header pushes it up. Paint only: it follows the scroll controller without rebuilding
/// the grid, it takes no pointers (taps reach the photos) and screen readers hear the real headers
/// in the grid instead.
class _StickyGroupHeader extends StatelessWidget {
  const _StickyGroupHeader({
    required this.scroll,
    required this.layout,
    required this.groups,
    required this.extent,
    required this.gridStart,
  });

  final ScrollController scroll;
  final PhotoMasonryLayout layout;
  final List<PhotoDateGroup> groups;
  final double extent;
  final double? Function() gridStart;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: ListenableBuilder(
          listenable: scroll,
          builder: (context, _) {
            if (!scroll.hasClients || layout.groupCount == 0) return const SizedBox.shrink();
            final start = gridStart();
            if (start == null) return const SizedBox.shrink();
            final offset = scroll.offset - start;
            if (offset <= 0) return const SizedBox.shrink();
            final g = layout.groupAt(offset);
            if (g < 0 || g >= groups.length) return const SizedBox.shrink();
            var dy = 0.0;
            if (g + 1 < layout.groupCount) {
              final next = layout.topOf(layout.headerChildOf(g + 1));
              dy = math.min(0.0, next - offset - extent);
            }
            return Transform.translate(
              key: const ValueKey('photos-sticky-header'),
              offset: Offset(0, dy),
              child: SizedBox(
                height: extent,
                child: ColoredBox(color: DanaviewColors.background, child: PhotoDateHeader(group: groups[g])),
              ),
            );
          },
        ),
      ),
    );
  }
}
