// OWNER: HOM-11
//
// The fullscreen photo viewer (ARCH v1.2 V2-106 / HOM D-91, §1.4, §3; BUILD_PLAN HOM-11). The
// Photos tab and the Recent photos tray open it with their list of photos and the tapped index
// ([openPhotoViewer]); it shows one photo per page:
//
// * swipe (or the arrow keys) between photos; pinch, a trackpad pinch or a double tap zooms, and
//   page swipes pause while a photo is zoomed so a pan never flips the page;
// * a single tap hides and shows the chrome; Escape or Close leaves;
// * the top bar names the photo, its position ("3 of 20") and shows the Live Photo indicator;
// * the bottom toolbar holds Share, Favourite, Edit, File info and Delete (photo_viewer_actions.dart
//   decides which are shown: hidden, not disabled);
// * opening a Danaview photo records it in Recents (HOM-19's hook, once per photo per visit).
//
// The viewer is a route above the Home, so it captures the Home's `onEditPhoto` when it opens.
// Kit components only, Figtree through the kit theme, solid dark bars (contrast computed in the
// tests), targets 44 px, semantics on every control; every text is one line with an ellipsis.

import 'dart:async';

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../files/library_store_providers.dart';
import '../home/home_callbacks.dart';
import '../organise/organise_providers.dart';
import '../photos/photo_grid_item.dart';
import 'photo_info_sheet.dart';
import 'photo_viewer_actions.dart';
import 'photo_viewer_entry.dart';
import 'photo_zoom_view.dart';

/// The bar colour: solid enough that white text keeps ≥ 4.5:1 over a white photo.
const Color photoViewerBarColor = DanaviewColors.overlayDark;

/// The viewer's background.
const Color photoViewerBackground = Color(0xFF000000);

/// Opens [photos] at [index] in the viewer. [onEditPhoto] defaults to the Home's
/// (`HomeCallbacksScope`) callback at [context].
Future<void> openPhotoViewer(
  BuildContext context,
  List<PhotoGridItem> photos,
  int index, {
  ValueChanged<PhotoMediaItem>? onEditPhoto,
}) {
  if (photos.isEmpty) return Future<void>.value();
  final edit = onEditPhoto ?? HomeCallbacksScope.of(context).onEditPhoto;
  final disable = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  return Navigator.of(context).push<void>(PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: disable ? Duration.zero : DanaviewMotion.normal,
    reverseTransitionDuration: disable ? Duration.zero : DanaviewMotion.fast,
    pageBuilder: (context, _, __) => PhotoViewerScreen(photos: photos, initialIndex: index, onEditPhoto: edit),
    transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ));
}

/// The fullscreen photo viewer.
class PhotoViewerScreen extends ConsumerStatefulWidget {
  /// A viewer of [photos] starting at [initialIndex].
  const PhotoViewerScreen({
    super.key,
    required this.photos,
    this.initialIndex = 0,
    this.onEditPhoto,
    this.fullResolution = true,
  });

  /// The photos, in the order of the grid that opened the viewer.
  final List<PhotoGridItem> photos;

  /// The first photo shown.
  final int initialIndex;

  /// Opens a photo in the editor's Still Photo Mode; null hides Edit.
  final ValueChanged<PhotoMediaItem>? onEditPhoto;

  /// Whether zoomed photos load their full-resolution layer.
  final bool fullResolution;

  @override
  ConsumerState<PhotoViewerScreen> createState() => PhotoViewerScreenState();
}

/// The viewer's state (public for tests).
class PhotoViewerScreenState extends ConsumerState<PhotoViewerScreen> {
  late List<PhotoGridItem> _photos;
  late int _index;
  late final PageController _pages;
  final FocusNode _focus = FocusNode(debugLabel: 'Photo viewer');
  final Map<ItemId, PhotoViewerEntry> _entries = {};
  final Set<ItemId> _recorded = {};
  final Map<ItemId, GlobalKey<PhotoZoomViewState>> _zoomKeys = {};
  bool _chrome = true;
  bool _zoomed = false;
  bool _busy = false;

  /// The photo on screen.
  int get index => _index;

  /// The photos still in the viewer (deleted ones leave).
  List<PhotoGridItem> get photos => _photos;

  /// Whether the bars are shown.
  bool get chromeVisible => _chrome;

  /// Whether page swipes are paused (a zoomed photo).
  bool get swipeLocked => _zoomed;

  @override
  void initState() {
    super.initState();
    _photos = List.of(widget.photos);
    _index = widget.initialIndex.clamp(0, _photos.isEmpty ? 0 : _photos.length - 1);
    _pages = PageController(initialPage: _index);
    WidgetsBinding.instance.addPostFrameCallback((_) => _record());
  }

  @override
  void dispose() {
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  PhotoViewerEntry _entryOf(PhotoGridItem item) =>
      _entries[item.id] ??= resolvePhotoViewerEntry(item, store: ref.read(libraryStoreProvider));

  GlobalKey<PhotoZoomViewState> _zoomKey(PhotoGridItem item) => _zoomKeys[item.id] ??= GlobalKey<PhotoZoomViewState>();

  PhotoGridItem? get _current => _photos.isEmpty ? null : _photos[_index];

  /// Records the current Danaview photo in Recents (once per visit).
  void _record() {
    if (!mounted) return;
    final item = _current;
    if (item == null || item.origin != PhotoOrigin.danaview || !_recorded.add(item.id)) return;
    final id = EntryId.tryParse(item.id.value);
    if (id != null) unawaited(ref.read(recordLibraryOpenProvider)(id));
  }

  void _onPageChanged(int i) {
    final previous = _current;
    setState(() {
      _index = i;
      _zoomed = false;
    });
    if (previous != null) _zoomKeys[previous.id]?.currentState?.reset();
    _record();
  }

  /// Shows photo [i] (keyboard and tests).
  void goTo(int i) {
    if (_photos.isEmpty || i < 0 || i >= _photos.length || i == _index) return;
    final disable = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (disable || !_pages.hasClients) {
      if (_pages.hasClients) _pages.jumpToPage(i);
      _onPageChanged(i);
      return;
    }
    unawaited(_pages.animateToPage(i, duration: DanaviewMotion.normal, curve: DanaviewMotion.curve));
  }

  void _toggleChrome() => setState(() => _chrome = !_chrome);

  void _close() => Navigator.of(context).maybePop();

  Future<void> _share(PhotoViewerEntry entry) async {
    final share = ref.read(photoViewerHooksProvider).share;
    if (share == null) return;
    await share(context, entry);
  }

  Future<void> _toggleFavourite(PhotoViewerEntry entry) async {
    final organiser = ref.read(libraryOrganiserProvider);
    if (organiser == null) return;
    final starred = await organiser.toggleFavourite(entry.id);
    if (!mounted) return;
    DanaviewToast.show(context, starred ? 'Added to Favourites' : 'Removed from Favourites',
        icon: starred ? Icons.star_rounded : Icons.star_border_rounded);
  }

  void _edit(PhotoViewerEntry entry) {
    final edit = widget.onEditPhoto;
    if (edit == null) return;
    edit(entry.toPhotoMediaItem(store: ref.read(libraryStoreProvider)));
  }

  Future<void> _info(PhotoViewerEntry entry) => showPhotoInfoSheet(context, entry.item);

  Future<void> _delete(PhotoViewerEntry entry) async {
    if (_busy) return;
    var deleted = false;
    if (entry.item.origin == PhotoOrigin.system) {
      final hook = ref.read(photoViewerHooksProvider).deleteSystemPhoto;
      if (hook == null) return;
      deleted = await hook(context, entry);
    } else {
      final store = ref.read(libraryStoreProvider);
      final id = entry.entryId;
      if (store == null || id == null) return;
      final usage = store.reader.refUsage(entries: [id]);
      final ok = await showDanaviewConfirm(
        context,
        title: 'Delete this photo?',
        message: photoDeleteMessage(projects: usage.projects, recipes: usage.photos),
        confirmLabel: 'Delete',
        destructive: true,
        icon: Icons.delete_outline_rounded,
      );
      if (!ok || !mounted) return;
      _busy = true;
      try {
        await store.write((w, now) => w.trashEntries([id], now: now));
        deleted = true;
      } on LibraryWriteException {
        deleted = false;
      } finally {
        _busy = false;
      }
    }
    if (!mounted) return;
    if (!deleted) {
      DanaviewToast.show(context, 'The photo couldn’t be deleted', kind: DanaviewToastKind.error);
      return;
    }
    DanaviewToast.show(context, 'Moved to Recently deleted', icon: Icons.delete_outline_rounded);
    _removeCurrent();
  }

  void _removeCurrent() {
    final item = _current;
    if (item == null) return;
    if (_photos.length == 1) {
      setState(() => _photos = const []);
      _close();
      return;
    }
    setState(() {
      _photos = List.of(_photos)..removeAt(_index);
      _entries.remove(item.id);
      _zoomKeys.remove(item.id);
      _zoomed = false;
      if (_index >= _photos.length) _index = _photos.length - 1;
    });
    if (_pages.hasClients) _pages.jumpToPage(_index);
    _record();
  }

  Future<void> _invoke(PhotoViewerAction action, PhotoViewerEntry entry) async {
    switch (action) {
      case PhotoViewerAction.share:
        await _share(entry);
      case PhotoViewerAction.favourite:
        await _toggleFavourite(entry);
      case PhotoViewerAction.edit:
        _edit(entry);
      case PhotoViewerAction.info:
        await _info(entry);
      case PhotoViewerAction.delete:
        await _delete(entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    if (current == null) return const ColoredBox(color: photoViewerBackground);
    final entry = _entryOf(current);
    final store = ref.watch(libraryStoreProvider);
    final hooks = ref.watch(photoViewerHooksProvider);
    final platform = Theme.of(context).platform;
    final actions = photoViewerActionsFor(
      entry: entry,
      platform: platform,
      hasEditCallback: widget.onEditPhoto != null,
      libraryWritable: store != null && !store.readOnly,
      hooks: hooks,
    );
    final favourite = actions.contains(PhotoViewerAction.favourite) && ref.watch(isFavouriteProvider(current.id));

    final pages = PageView.builder(
      key: const ValueKey('photo-viewer-pages'),
      controller: _pages,
      physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
      onPageChanged: _onPageChanged,
      itemCount: _photos.length,
      itemBuilder: (context, i) {
        final item = _photos[i];
        final e = _entryOf(item);
        return Semantics(
          key: ValueKey('photo-viewer-page-${item.id.value}'),
          label: item.name.isEmpty ? 'Photo ${i + 1} of ${_photos.length}' : 'Photo ${item.name}, ${i + 1} of ${_photos.length}',
          image: true,
          onTapHint: _chrome ? 'Hide controls' : 'Show controls',
          child: PhotoZoomView(
            key: _zoomKey(item),
            entry: e,
            fullResolution: widget.fullResolution,
            onTap: _toggleChrome,
            onZoomChanged: (z) {
              if (i == _index && z != _zoomed) setState(() => _zoomed = z);
            },
          ),
        );
      },
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => goTo(_index - 1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => goTo(_index + 1),
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: ColoredBox(
          color: photoViewerBackground,
          child: Stack(fit: StackFit.expand, children: [
            pages,
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: _Bar(
                visible: _chrome,
                top: true,
                child: _TopBar(
                  name: current.name,
                  position: '${_index + 1} of ${_photos.length}',
                  isLive: entry.isLivePhoto,
                  onClose: _close,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _Bar(
                visible: _chrome,
                top: false,
                child: _Toolbar(
                  actions: actions,
                  favourite: favourite,
                  onInvoke: (a) => unawaited(_invoke(a, entry)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A bar that fades with the chrome and takes no input while hidden.
class _Bar extends StatelessWidget {
  const _Bar({required this.visible, required this.top, required this.child});

  final bool visible;
  final bool top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final disable = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: disable ? Duration.zero : DanaviewMotion.fast,
          child: ColoredBox(
            color: photoViewerBarColor,
            child: SafeArea(
              top: top,
              bottom: !top,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs, vertical: DanaviewSpacing.xs),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.name, required this.position, required this.isLive, required this.onClose});

  final String name;
  final String position;
  final bool isLive;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(children: [
      DanaviewIconButton(
        key: const ValueKey('photo-viewer-close'),
        icon: Icons.close_rounded,
        size: DanaviewSpacing.minTapTarget,
        tooltip: 'Close',
        onPressed: onClose,
      ),
      const SizedBox(width: DanaviewSpacing.xs),
      Expanded(
        child: Semantics(
          container: true,
          label: name.isEmpty ? 'Photo $position' : '$name, $position',
          excludeSemantics: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (name.isNotEmpty)
              Text(
                name,
                key: const ValueKey('photo-viewer-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: (text.titleSmall ?? const TextStyle()).copyWith(color: DanaviewColors.textPrimary),
              ),
            Text(
              position,
              key: const ValueKey('photo-viewer-position'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (text.bodySmall ?? const TextStyle()).copyWith(color: DanaviewColors.textSecondary),
            ),
          ]),
        ),
      ),
      if (isLive) ...[
        const SizedBox(width: DanaviewSpacing.sm),
        Flexible(
          flex: 0,
          child: Semantics(
            key: const ValueKey('photo-viewer-live'),
            label: 'Live Photo',
            excludeSemantics: true,
            child: const DanaviewBadge('LIVE', icon: Icons.motion_photos_on_outlined, color: DanaviewColors.textPrimary),
          ),
        ),
        const SizedBox(width: DanaviewSpacing.sm),
      ],
    ]);
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.actions, required this.favourite, required this.onInvoke});

  final List<PhotoViewerAction> actions;
  final bool favourite;
  final ValueChanged<PhotoViewerAction> onInvoke;

  @override
  Widget build(BuildContext context) {
    Widget button(PhotoViewerAction a) {
      final (IconData icon, String label) = switch (a) {
        PhotoViewerAction.share => (Icons.ios_share_rounded, 'Share'),
        PhotoViewerAction.favourite =>
          favourite ? (Icons.star_rounded, 'Remove from Favourites') : (Icons.star_border_rounded, 'Add to Favourites'),
        PhotoViewerAction.edit => (Icons.tune_rounded, 'Edit'),
        PhotoViewerAction.info => (Icons.info_outline_rounded, 'File info'),
        PhotoViewerAction.delete => (Icons.delete_outline_rounded, 'Delete'),
      };
      return DanaviewIconButton(
        key: ValueKey('photo-viewer-${a.name}'),
        icon: icon,
        size: DanaviewSpacing.minTapTarget,
        tooltip: label,
        selected: a == PhotoViewerAction.favourite && favourite,
        color: a == PhotoViewerAction.favourite && favourite ? DanaviewColors.warning : null,
        onPressed: () => onInvoke(a),
      );
    }

    return Row(
      key: const ValueKey('photo-viewer-toolbar'),
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [for (final a in actions) Flexible(child: button(a))],
    );
  }
}
