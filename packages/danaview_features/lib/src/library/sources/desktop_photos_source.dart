// OWNER: HOM-03
//
// The desktop Pictures folder source of the Photos tab (ARCH v1.2 V2-109, HOM plan D-94): on
// macOS, Windows and Linux it discovers the Pictures folders and mounted external volumes
// (danaview_library `DesktopRootResolver`), scans them read-only and incrementally
// (`DesktopScanner`, rule 27) and keeps the photos per root for the sidebar shortcuts and the
// Photos grid. Folders dropped on the sidebar become extra roots. A drive that is unplugged
// simply disappears on the next refresh. On macOS the PhotoKit library comes from HOM-02's
// system source; the scanner skips the Photos library package inside ~/Pictures. Nothing here
// logs names or paths (rule 30).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// The library types of this source's API, so its users need no direct danaview_library import.
export 'package:danaview_library/danaview_library.dart'
    show
        DesktopEntryType,
        DesktopPlatform,
        DesktopRoot,
        DesktopRootKind,
        DesktopRootResolver,
        DesktopScanner,
        ItemId,
        LinkedItemId,
        MediaItem,
        PhotoMediaItem;

/// The [DesktopPlatform] of [platform], or null on iOS, Android and Fuchsia (no desktop scan).
DesktopPlatform? desktopPlatformFor(TargetPlatform platform, {bool isWeb = kIsWeb}) {
  if (isWeb) return null;
  return switch (platform) {
    TargetPlatform.macOS => DesktopPlatform.macos,
    TargetPlatform.windows => DesktopPlatform.windows,
    TargetPlatform.linux => DesktopPlatform.linux,
    _ => null,
  };
}

/// One root as the sidebar shows it.
@immutable
class DesktopRootStatus {
  /// [root] with its [items]; [available] false when it could not be read on the last scan.
  const DesktopRootStatus({required this.root, this.items = const [], this.available = true, this.scanned = false});

  /// The root.
  final DesktopRoot root;

  /// Its media items (photos by default), sorted by path.
  final List<MediaItem> items;

  /// False when the last scan found the root missing or unreadable.
  final bool available;

  /// True once the root has been scanned at least once.
  final bool scanned;

  /// The photos among [items].
  Iterable<PhotoMediaItem> get photos => items.whereType<PhotoMediaItem>();
}

/// The state of [DesktopPhotosController].
@immutable
class DesktopPhotosState {
  /// A state with [roots] in sidebar order.
  const DesktopPhotosState({this.roots = const [], this.selectedRootId, this.scanning = false});

  /// Every root: Pictures folders, then volumes, then folders the user added.
  final List<DesktopRootStatus> roots;

  /// The root the grid shows, or null for all roots.
  final String? selectedRootId;

  /// True while a refresh runs.
  final bool scanning;

  /// The roots of [kind].
  List<DesktopRootStatus> rootsOf(DesktopRootKind kind) => [
        for (final r in roots)
          if (r.root.kind == kind) r,
      ];

  /// The photos of the selected root (or of every root), newest first, each item once.
  List<PhotoMediaItem> get photos {
    final seen = <ItemId>{};
    final out = <PhotoMediaItem>[
      for (final r in roots)
        if (selectedRootId == null || r.root.id == selectedRootId)
          for (final photo in r.photos)
            if (seen.add(photo.id)) photo,
    ];
    out.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return out;
  }

  /// A copy with the given fields replaced (pass [clearSelection] to select all roots).
  DesktopPhotosState copyWith({
    List<DesktopRootStatus>? roots,
    String? selectedRootId,
    bool clearSelection = false,
    bool? scanning,
  }) =>
      DesktopPhotosState(
        roots: roots ?? this.roots,
        selectedRootId: clearSelection ? null : (selectedRootId ?? this.selectedRootId),
        scanning: scanning ?? this.scanning,
      );
}

/// Discovers and scans the desktop photo roots.
class DesktopPhotosController extends StateNotifier<DesktopPhotosState> {
  /// A controller over [resolver] and [scanner]; null [resolver] (not a desktop) keeps it empty.
  DesktopPhotosController({required this.resolver, DesktopScanner? scanner})
      : scanner = scanner ?? DesktopScanner(fs: resolver?.fs ?? const IoDesktopFs(), pathContext: resolver?.platform.pathContext),
        super(const DesktopPhotosState());

  /// Finds the Pictures folders and volumes; null on platforms without a desktop scan.
  final DesktopRootResolver? resolver;

  /// Walks each root read-only.
  final DesktopScanner scanner;

  final Map<String, DesktopScanCache> _caches = {};
  final List<DesktopRoot> _customRoots = [];
  Future<void>? _running;
  bool _again = false;

  /// Rediscovers the roots and rescans each incrementally. Calls made while a refresh runs are
  /// folded into one more refresh after it.
  Future<void> refresh() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    final run = _refreshLoop();
    _running = run;
    return run.whenComplete(() => _running = null);
  }

  Future<void> _refreshLoop() async {
    do {
      _again = false;
      await _refreshOnce();
    } while (_again && mounted);
  }

  Future<void> _refreshOnce() async {
    final resolver = this.resolver;
    if (resolver == null || !mounted) return;
    state = state.copyWith(scanning: true);
    final discovered = await resolver.discover();
    final paths = {for (final r in discovered) r.path};
    final roots = [
      ...discovered,
      for (final r in _customRoots)
        if (!paths.contains(r.path)) r,
    ];
    final previous = {for (final s in state.roots) s.root.id: s};
    // Show the current root list at once (a pulled drive disappears now), then fill in scans.
    if (!mounted) return;
    state = state.copyWith(
      roots: [for (final r in roots) previous[r.id] ?? DesktopRootStatus(root: r)],
      clearSelection: state.selectedRootId != null && !roots.any((r) => r.id == state.selectedRootId),
    );
    _caches.removeWhere((id, _) => !roots.any((r) => r.id == id));
    for (final root in roots) {
      final result = await scanner.scan(root, previous: _caches[root.id]);
      if (!mounted) return;
      _caches[root.id] = result.cache;
      state = state.copyWith(roots: [
        for (final s in state.roots)
          s.root.id == root.id
              ? DesktopRootStatus(root: root, items: result.items, available: result.available, scanned: true)
              : s,
      ]);
    }
    if (mounted) state = state.copyWith(scanning: false);
  }

  /// Adds the folder at [path] (dropped on the sidebar) as a root and scans it. Returns false when
  /// it is not a readable directory or is already a root.
  Future<bool> addFolder(String path) async {
    final resolver = this.resolver;
    if (resolver == null) return false;
    final st = await resolver.fs.stat(path);
    if (st == null || st.type != DesktopEntryType.directory) return false;
    final canonical = await resolver.fs.resolve(path) ?? path;
    if (state.roots.any((s) => s.root.path == canonical) || _customRoots.any((r) => r.path == canonical)) return false;
    final label = resolver.platform.pathContext.basename(canonical);
    _customRoots.add(DesktopRoot.at(DesktopRootKind.custom, canonical, label: label.isEmpty ? canonical : label));
    await refresh();
    return true;
  }

  /// Removes a folder the user added; discovered roots cannot be removed.
  Future<void> removeFolder(String rootId) async {
    final before = _customRoots.length;
    _customRoots.removeWhere((r) => r.id == rootId);
    if (_customRoots.length == before || !mounted) return;
    _caches.remove(rootId);
    state = state.copyWith(
      roots: [
        for (final s in state.roots)
          if (s.root.id != rootId) s,
      ],
      clearSelection: state.selectedRootId == rootId,
    );
  }

  /// Shows only [rootId] in the grid (null: every root).
  void select(String? rootId) {
    if (rootId == null) {
      state = state.copyWith(clearSelection: true);
    } else if (state.roots.any((s) => s.root.id == rootId)) {
      state = state.copyWith(selectedRootId: rootId);
    }
  }
}

/// The desktop root resolver of this platform, or null where there is no desktop scan.
final desktopRootResolverProvider = Provider<DesktopRootResolver?>((ref) {
  final platform = desktopPlatformFor(defaultTargetPlatform);
  if (platform == null) return null;
  return DesktopRootResolver(platform: platform, environment: Platform.environment);
});

/// The desktop photos of the Photos tab and the sidebar shortcuts. Call
/// `DesktopPhotosController.refresh` when the tab first shows and when the window regains focus.
final desktopPhotosControllerProvider = StateNotifierProvider<DesktopPhotosController, DesktopPhotosState>(
  (ref) => DesktopPhotosController(resolver: ref.watch(desktopRootResolverProvider)),
);
