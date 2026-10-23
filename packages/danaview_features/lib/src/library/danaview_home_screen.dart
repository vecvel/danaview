// EXTENDED: HOM-05 (Files & Media Home tab shell behind DANAVIEW_FILES_HOME; ARCH v1.2 V2-101, V2-32)
//
// With DANAVIEW_FILES_HOME off [DanaviewHomeScreen] builds exactly the 1.1 tree (pinned by
// test/home_screen_test.dart and the goldens of test/v12/home_shell/). With it on, the header and a
// tab strip sit in the top bar and a tab host shows one tab: `Home` holds the 1.1 sections
// unchanged plus the Recent photos and Favourites slots; the other tabs come from [HomeTabSlots].

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../controllers/providers.dart';
import '../flags.dart';
import '../player/danaview_player_actions.dart';
import 'add_to_playlist_sheet.dart';
import 'home/home_callbacks.dart';
import 'home/home_tab_host.dart';
import 'home/home_tab_strip.dart';
import 'home/home_tabs.dart';
import 'library_actions.dart';
import 'library_controller.dart';
import 'library_format.dart';
import 'library_providers.dart';
import 'library_widgets.dart';
import 'media_picker.dart';
import 'open_link_dialog.dart';

export 'home/home_callbacks.dart' show HomeCallbacks, HomeCallbacksScope;
export 'home/home_tab_strip.dart' show homeTabKey;
export 'home/home_tabs.dart' show HomeSlotBuilder, HomeTab, HomeTabSlots, homeEditorPlatform, visibleHomeTabs;

/// Start screen: now playing, quick open actions, continue watching, playlists and folders.
class DanaviewHomeScreen extends ConsumerStatefulWidget {
  const DanaviewHomeScreen({
    super.key,
    required this.onOpenPlayer,
    required this.onOpenFolder,
    required this.onOpenPlaylist,
    this.onOpenSettings,
    this.onOpenEditor,
    this.callbacks = HomeCallbacks.none,
    this.tabSlots = HomeTabSlots.none,
    this.initialTab = HomeTab.home,
  });

  final VoidCallback onOpenPlayer;
  final ValueChanged<String> onOpenFolder;
  final ValueChanged<String> onOpenPlaylist;

  /// Shows a settings button at the end of the header when set.
  final VoidCallback? onOpenSettings;

  /// Shows the video editor button immediately left of the settings button when set; null hides
  /// it (the app passes null where the editor is unavailable). This package never imports the
  /// editor: the router supplies the navigation.
  final VoidCallback? onOpenEditor;

  /// The optional 1.2.0 entry points (editor, projects, AI); used only with DANAVIEW_FILES_HOME on.
  final HomeCallbacks callbacks;

  /// The bodies of the 1.2.0 tabs and Overview slots; used only with DANAVIEW_FILES_HOME on.
  final HomeTabSlots tabSlots;

  /// The tab shown first with DANAVIEW_FILES_HOME on (falls back to `Home` when hidden).
  final HomeTab initialTab;

  @override
  ConsumerState<DanaviewHomeScreen> createState() => _DanaviewHomeScreenState();
}

class _DanaviewHomeScreenState extends ConsumerState<DanaviewHomeScreen> {
  static const _recentPreviewCount = 6;

  bool _showAllRecent = false;
  bool _busy = false;

  /// The selected tab with DANAVIEW_FILES_HOME on.
  late HomeTab _tab = widget.initialTab;

  /// The laid-out height of the selection bar slot (0 while it shows nothing). The tab host gets it
  /// as bottom MediaQuery padding so the last row of every page scrolls out from under the bar.
  double _selectionBarHeight = 0;

  void _onSelectionBarSize(Size size) {
    if (!mounted || size.height == _selectionBarHeight) return;
    setState(() => _selectionBarHeight = size.height);
  }

  LibraryController get _library => ref.read(libraryControllerProvider.notifier);

  void _play(List<MediaRef> items, {int startIndex = 0, bool shuffle = false}) {
    if (items.isEmpty) return;
    danaviewPlayItems(ref, items, startIndex: startIndex, shuffle: shuffle);
    widget.onOpenPlayer();
  }

  /// Runs a picker flow once at a time and turns failures into an error toast.
  Future<void> _guarded(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    try {
      await action();
    } catch (e) {
      if (mounted) showDanaviewError(context, e);
    } finally {
      _busy = false;
    }
  }

  Future<void> _openFile() => _guarded(() async {
        final refs = await pickVideoRefs();
        if (refs.isNotEmpty && mounted) _play(refs);
      });

  Future<void> _openFolder() => _guarded(() async {
        if (canPickFolders) {
          final path = await pickFolderPath();
          if (path == null || !mounted) return;
          final folder = await _library.addFolder(path);
          if (mounted) widget.onOpenFolder(folder.path);
          return;
        }
        final device =
            ref.read(libraryControllerProvider).deviceFolder ?? await ref.read(libraryRepositoryProvider).getDeviceFolder();
        if (device != null && mounted) widget.onOpenFolder(device.path);
      });

  Future<void> _addFolder() => _guarded(() async {
        final path = await pickFolderPath();
        if (path == null || !mounted) return;
        final folder = await _library.addFolder(path);
        if (mounted) showDanaviewSuccess(context, 'Added "${folder.label}" to your library');
      });

  Future<void> _openLink() async {
    final media = await showDanaviewOpenLinkDialog(context);
    if (media != null && mounted) _play([media]);
  }

  void _playRecent(LibraryRecentItem item) {
    if (!item.exists) {
      DanaviewToast.show(
        context,
        "This file isn't available anymore. It may have been moved or deleted.",
        kind: DanaviewToastKind.error,
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    _play([item.media]);
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDanaviewConfirm(
      context,
      title: 'Clear Continue watching',
      message: 'Your watch history and resume points will be cleared. Your files stay on disk.',
      confirmLabel: 'Clear',
      destructive: true,
      icon: Icons.history_rounded,
    );
    if (!confirmed) return;
    await _library.clearHistory();
    if (mounted) setState(() => _showAllRecent = false);
  }

  Future<void> _newPlaylist() async {
    final name = await promptNewPlaylist(context, ref);
    if (name != null && mounted) widget.onOpenPlaylist(name);
  }

  void _playPlaylist(String name, {bool shuffle = false}) {
    final items = _library.playlistItems(name);
    if (items.isEmpty) {
      DanaviewToast.show(context, '"$name" is empty. Add videos to play it.', icon: Icons.info_outline_rounded);
      return;
    }
    _play(items, shuffle: shuffle);
  }

  Future<void> _renamePlaylist(String name) async {
    final renamed = await promptRenamePlaylist(context, ref, name);
    if (renamed != null && mounted) showDanaviewSuccess(context, 'Renamed to "$renamed"');
  }

  Future<void> _deletePlaylist(String name) async {
    if (!await confirmDeletePlaylist(context, name)) return;
    await _library.deletePlaylist(name);
    if (mounted) showDanaviewSuccess(context, 'Deleted "$name"');
  }

  Future<void> _playFolder(LibraryFolder folder) async {
    final listing = await LibraryRepository.browseDirectory(folder.path);
    if (!mounted) return;
    if (listing.hasError) {
      DanaviewToast.show(context, listing.error!, kind: DanaviewToastKind.error, icon: Icons.error_outline_rounded);
    } else if (listing.media.isEmpty) {
      DanaviewToast.show(
        context,
        'No videos directly in "${folder.label}". Open it to browse its folders.',
        icon: Icons.info_outline_rounded,
      );
    } else {
      _play(listing.media);
    }
  }

  Future<void> _removeFolder(LibraryFolder folder) async {
    final confirmed = await showDanaviewConfirm(
      context,
      title: 'Remove from library',
      message: '"${folder.label}" will be removed from Danaview. Your files stay on disk.',
      confirmLabel: 'Remove',
      destructive: true,
      icon: Icons.remove_circle_outline_rounded,
    );
    if (confirmed) await _library.removeFolder(folder.path);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryControllerProvider);
    if (FeatureFlags.filesHomeEnabled) return _buildFilesHome(context);
    return DanaviewRefreshOnReturn(
      onReturn: () => _library.refresh(),
      child: Scaffold(
        backgroundColor: DanaviewColors.background,
        body: DanaviewLibraryFrame(
          body: LayoutBuilder(
            builder: (context, constraints) {
              final insets = danaviewLibraryInsets(constraints.maxWidth);
              return CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: insets.copyWith(
                      top: DanaviewSpacing.xl,
                      bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl,
                    ),
                    sliver: SliverList.list(
                      children: [
                        _HomeHeader(onOpenSettings: widget.onOpenSettings, onOpenEditor: widget.onOpenEditor),
                        const SizedBox(height: DanaviewSpacing.xl),
                        ..._overviewSections(state),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The 1.1 Home sections below the header, in 1.1 order. With [slots] (DANAVIEW_FILES_HOME on)
  /// the Overview's additive rows (Recent photos, Favourites) follow Continue watching; the 1.1
  /// sections themselves are the same widgets either way.
  List<Widget> _overviewSections(LibraryState state, {HomeTabSlots? slots}) {
    return [
      _NowPlayingCard(onOpen: widget.onOpenPlayer),
      _QuickActions(
        actions: [
          _QuickAction(
            'Open file',
            'Pick videos to play',
            DanaviewColors.primaryLight,
            _openFile,
            icon: Icons.video_file_rounded,
          ),
          _QuickAction(
            'Open folder',
            canPickFolders ? 'Browse a folder' : 'Videos on this device',
            DanaviewColors.purple,
            _openFolder,
            glyph: DanaviewGlyphKind.folderOpen,
          ),
          _QuickAction(
            'Open link',
            'Stream from a URL',
            DanaviewColors.cyan,
            _openLink,
            icon: Icons.link_rounded,
          ),
        ],
      ),
      if (state.error != null) ...[
        const SizedBox(height: DanaviewSpacing.xl),
        DanaviewInlineEmpty(
          icon: Icons.error_outline_rounded,
          iconColor: DanaviewColors.errorLight,
          title: state.error!,
          message: 'Your files are safe. Try loading the library again.',
          action: DanaviewButton.secondary(
            label: 'Try again',
            icon: Icons.refresh_rounded,
            size: DanaviewButtonSize.sm,
            onPressed: () => _library.refresh(),
          ),
        ),
      ],
      if (state.hasLoaded) ...[
        ..._recentSection(state.recent),
        if (slots?.recentPhotos case final tray?)
          KeyedSubtree(key: const ValueKey('home-slot-recent-photos'), child: Builder(builder: tray)),
        if (slots?.favourites case final favourites?)
          KeyedSubtree(key: const ValueKey('home-slot-favourites'), child: Builder(builder: favourites)),
        ..._playlistSection(state.playlists),
        ..._folderSection(state.roots),
      ],
    ];
  }

  // ---- DANAVIEW_FILES_HOME on (HOM-05) ----

  List<HomeTab> _visibleTabs(BuildContext context) => visibleHomeTabs(
        platform: Theme.of(context).platform,
        projectsAvailable: widget.callbacks.onOpenProjects != null || widget.tabSlots.projects != null,
        showDocuments: widget.tabSlots.showDocuments,
      );

  void _selectTab(HomeTab tab) {
    if (tab != _tab) setState(() => _tab = tab);
  }

  Widget _buildFilesHome(BuildContext context) {
    final tabs = _visibleTabs(context);
    final selected = tabs.contains(_tab) ? _tab : HomeTab.home;
    final selectionBar = widget.tabSlots.selectionBar;
    return HomeCallbacksScope(
      callbacks: widget.callbacks,
      child: DanaviewRefreshOnReturn(
        onReturn: () => _library.refresh(),
        child: Scaffold(
          backgroundColor: DanaviewColors.background,
          body: DanaviewLibraryFrame(
            topBar: LayoutBuilder(
              builder: (context, constraints) {
                final insets = danaviewLibraryInsets(constraints.maxWidth);
                return Column(
                  key: const ValueKey('home-files-top-bar'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: insets.copyWith(top: DanaviewSpacing.lg),
                      child: _HomeHeader(onOpenSettings: widget.onOpenSettings, onOpenEditor: widget.onOpenEditor),
                    ),
                    const SizedBox(height: DanaviewSpacing.sm),
                    HomeTabStrip(
                      key: const ValueKey('home-tab-strip'),
                      tabs: tabs,
                      selected: selected,
                      onSelected: _selectTab,
                      padding: insets,
                    ),
                    const SizedBox(height: DanaviewSpacing.xs),
                  ],
                );
              },
            ),
            body: Stack(
              children: [
                Positioned.fill(
                  // A page or slot asks for a tab (See all of the Recent photos tray): select it
                  // here, and let the request keep bubbling to any app shell above (false).
                  child: NotificationListener<HomeTabRequestNotification>(
                    onNotification: (request) {
                      if (_visibleTabs(context).contains(request.tab)) _selectTab(request.tab);
                      return false;
                    },
                    child: Builder(
                      builder: (context) {
                        final host = HomeTabHost(
                          tabs: tabs,
                          selected: selected,
                          pageBuilder: _tabPage,
                        );
                        final barHeight = selectionBar == null ? 0.0 : _selectionBarHeight;
                        // Always wrapped (same tree shape) so the tab pages keep their state when
                        // the bar appears. The bar already includes the bottom safe area, so it
                        // replaces that inset rather than adding to it.
                        final media = MediaQuery.of(context);
                        final bottom = barHeight > media.padding.bottom ? barHeight : media.padding.bottom;
                        return MediaQuery(
                          data: media.copyWith(padding: media.padding.copyWith(bottom: bottom)),
                          child: host,
                        );
                      },
                    ),
                  ),
                ),
                if (selectionBar != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _SizeReporter(
                      onSize: _onSelectionBarSize,
                      child: KeyedSubtree(key: const ValueKey('home-slot-selection-bar'), child: Builder(builder: selectionBar)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The page of [tab]: the shell's own pages for Home and Playlists, the supplied body for the
  /// others, and the fallbacks of home_tabs.dart when none was supplied.
  Widget _tabPage(BuildContext context, HomeTab tab) {
    final body = widget.tabSlots.bodyOf(tab);
    if (body != null) return body(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = danaviewLibraryInsets(constraints.maxWidth);
        final padding = insets.copyWith(
          top: DanaviewSpacing.lg,
          bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl,
        );
        // Each page reads the latest library state itself: pages built once stay alive.
        return Consumer(
          builder: (context, ref, _) {
            final state = ref.watch(libraryControllerProvider);
            final sections = switch (tab) {
              HomeTab.home => _overviewSections(state, slots: widget.tabSlots),
              HomeTab.playlists => state.hasLoaded ? _playlistSection(state.playlists) : const <Widget>[],
              HomeTab.folders => state.hasLoaded ? _folderSection(state.roots) : const <Widget>[],
              _ => null,
            };
            if (sections == null) {
              if (tab == HomeTab.projects && widget.callbacks.onOpenProjects != null) {
                return HomeProjectsPane(onOpenProjects: widget.callbacks.onOpenProjects!, padding: padding);
              }
              return HomeEmptyTabPane(tab: tab, padding: padding);
            }
            return CustomScrollView(
              key: PageStorageKey('home-tab-scroll-${tab.name}'),
              slivers: [SliverPadding(padding: padding, sliver: SliverList.list(children: sections))],
            );
          },
        );
      },
    );
  }

  List<Widget> _recentSection(List<LibraryRecentItem> recent) {
    if (recent.isEmpty) return const [];
    final visible = _showAllRecent ? recent : recent.take(_recentPreviewCount);
    return [
      DanaviewLibrarySectionHeader(
        'Continue watching',
        prominent: true,
        action: DanaviewButton.ghost(label: 'Clear', size: DanaviewButtonSize.sm, onPressed: _clearHistory),
      ),
      DanaviewLibraryGroup(children: [for (final item in visible) _recentRow(item)]),
      if (recent.length > _recentPreviewCount)
        Padding(
          padding: const EdgeInsets.only(top: DanaviewSpacing.sm),
          child: Center(
            child: DanaviewButton.ghost(
              label: _showAllRecent ? 'Show less' : 'Show all ${recent.length}',
              trailingIcon: _showAllRecent ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: DanaviewButtonSize.sm,
              onPressed: () => setState(() => _showAllRecent = !_showAllRecent),
            ),
          ),
        ),
    ];
  }

  Widget _recentRow(LibraryRecentItem item) {
    final media = item.media;
    return DanaviewLibraryRow(
      leading: DanaviewTileIcon(mediaIcon(media), color: mediaIconColor(media), size: 40),
      title: media.title,
      badge: episodeLabel(media),
      subtitle: mediaSubtitle(media, item.resume, exists: item.exists, fallback: parentFolderName(media.pathOrUri)),
      progress: item.exists ? item.progress : null,
      dimmed: !item.exists,
      onTap: () => _playRecent(item),
      trailing: DanaviewMenuIconTrigger(
        icon: Icons.more_horiz_rounded,
        tooltip: 'More',
        entries: [
          DanaviewMenuItem(
            label: 'Play',
            icon: Icons.play_arrow_rounded,
            enabled: item.exists,
            onTap: () => _playRecent(item),
          ),
          DanaviewMenuItem(
            label: 'Add to playlist…',
            icon: Icons.playlist_add_rounded,
            onTap: () => showDanaviewAddToPlaylistSheet(context, [media]),
          ),
          const DanaviewMenuDivider(),
          DanaviewMenuItem(
            label: 'Remove from history',
            icon: Icons.remove_circle_outline_rounded,
            destructive: true,
            onTap: () => _library.removeFromHistory(media),
          ),
        ],
      ),
    );
  }

  List<Widget> _playlistSection(List<PlaylistSummary> playlists) {
    return [
      DanaviewLibrarySectionHeader(
        'Playlists',
        prominent: true,
        action: playlists.isEmpty
            ? null
            : DanaviewButton.ghost(
                label: 'New',
                icon: Icons.add_rounded,
                size: DanaviewButtonSize.sm,
                onPressed: _newPlaylist,
              ),
      ),
      if (playlists.isEmpty)
        DanaviewInlineEmpty(
          icon: Icons.queue_music_rounded,
          iconColor: DanaviewColors.purple,
          title: 'No playlists yet',
          message: 'Collect videos and links to play them in order.',
          action: DanaviewButton.tonal(
            label: 'New playlist',
            icon: Icons.add_rounded,
            size: DanaviewButtonSize.sm,
            onPressed: _newPlaylist,
          ),
        )
      else
        DanaviewLibraryGroup(
          children: [
            for (final playlist in playlists)
              DanaviewLibraryRow(
                leading: const DanaviewTileIcon(Icons.queue_music_rounded, color: DanaviewColors.purple, size: 40),
                title: playlist.name,
                subtitle: playlist.itemCount == 0 ? 'No videos yet' : formatCount(playlist.itemCount, 'video'),
                onTap: () => widget.onOpenPlaylist(playlist.name),
                trailing: DanaviewMenuIconTrigger(
                  icon: Icons.more_horiz_rounded,
                  tooltip: 'More',
                  entries: [
                    DanaviewMenuItem(
                      label: 'Play',
                      icon: Icons.play_arrow_rounded,
                      enabled: playlist.itemCount > 0,
                      onTap: () => _playPlaylist(playlist.name),
                    ),
                    DanaviewMenuItem(
                      label: 'Shuffle',
                      icon: Icons.shuffle_rounded,
                      enabled: playlist.itemCount > 1,
                      onTap: () => _playPlaylist(playlist.name, shuffle: true),
                    ),
                    const DanaviewMenuDivider(),
                    DanaviewMenuItem(
                      label: 'Rename',
                      icon: Icons.edit_rounded,
                      onTap: () => _renamePlaylist(playlist.name),
                    ),
                    DanaviewMenuItem(
                      label: 'Delete',
                      icon: Icons.delete_outline_rounded,
                      destructive: true,
                      onTap: () => _deletePlaylist(playlist.name),
                    ),
                  ],
                ),
              ),
          ],
        ),
    ];
  }

  List<Widget> _folderSection(List<LibraryFolder> roots) {
    return [
      DanaviewLibrarySectionHeader(
        'Folders',
        prominent: true,
        action: canPickFolders && roots.isNotEmpty
            ? DanaviewButton.ghost(
                label: 'Add',
                icon: Icons.add_rounded,
                size: DanaviewButtonSize.sm,
                onPressed: _addFolder,
              )
            : null,
      ),
      if (roots.isEmpty)
        DanaviewInlineEmpty(
          glyph: DanaviewGlyphKind.folderVideo,
          iconColor: DanaviewColors.primaryLight,
          title: 'No folders yet',
          message: canPickFolders
              ? 'Add a folder to browse its videos here. Nothing is copied or moved.'
              : 'Use Open file to add videos from your device.',
          action: canPickFolders
              ? DanaviewButton.tonal(
                  label: 'Add folder',
                  glyph: DanaviewGlyphKind.folderAdd,
                  size: DanaviewButtonSize.sm,
                  onPressed: _addFolder,
                )
              : null,
        )
      else
        DanaviewLibraryGroup(children: [for (final folder in roots) _folderRow(folder)]),
    ];
  }

  Widget _folderRow(LibraryFolder folder) {
    if (folder.isDevice) {
      return DanaviewLibraryRow(
        leading: const DanaviewTileIcon.glyph(DanaviewGlyphKind.device, color: DanaviewColors.cyan, size: 40),
        title: folder.label,
        subtitle: Theme.of(context).platform == TargetPlatform.iOS
            ? 'Files app › ${LibraryStorage.iosFilesLocation(tablet: LibraryStorage.isTabletWidth(MediaQuery.sizeOf(context).shortestSide))}'
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
          DanaviewMenuItem(
            label: 'Open',
            glyph: DanaviewGlyphKind.folderOpen,
            onTap: () => widget.onOpenFolder(folder.path),
          ),
          DanaviewMenuItem(
            label: 'Play all',
            icon: Icons.play_arrow_rounded,
            onTap: () => _playFolder(folder),
          ),
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

/// Reports [child]'s laid-out size after each layout in which it changed (HOM-05 selection bar).
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeReporter renderObject) => renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);

  ValueChanged<Size> onSize;
  Size? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final current = size;
    if (current == _reported) return;
    _reported = current;
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(current));
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({this.onOpenSettings, this.onOpenEditor});

  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenEditor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const DanaviewLogo(size: 36),
        const SizedBox(width: DanaviewSpacing.md),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              'Danaview',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DanaviewTextStyles.largeTitle.copyWith(fontSize: 26, height: 1.15),
            ),
          ),
        ),
        // Fixed-size buttons: the title ellipsizes first (it keeps 96 px at 280 px wide).
        if (onOpenEditor != null) ...[
          const SizedBox(width: DanaviewSpacing.sm),
          DanaviewIconButton(
            icon: Icons.movie_edit,
            variant: DanaviewIconButtonVariant.tonal,
            size: 44,
            iconSize: 22,
            tooltip: 'Video editor',
            semanticLabel: 'Open video editor',
            onPressed: onOpenEditor,
          ),
        ],
        if (onOpenSettings != null) ...[
          const SizedBox(width: DanaviewSpacing.sm),
          DanaviewIconButton(
            icon: Icons.settings_rounded,
            variant: DanaviewIconButtonVariant.tonal,
            size: 44,
            iconSize: 22,
            tooltip: 'Settings',
            onPressed: onOpenSettings,
          ),
        ],
      ],
    );
  }
}

class _NowPlayingCard extends ConsumerWidget {
  const _NowPlayingCard({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = ref.watch(queueControllerProvider.select((q) => q.currentItem));
    if (media == null) return const SizedBox.shrink();
    final (status, position, duration, error) = ref.watch(
      playerControllerProvider.select((s) => (s.status, s.position.inSeconds, s.duration.inSeconds, s.error)),
    );
    final isError = status == PlaybackStatus.error || (error != null && playerErrorToastKind(error) == DanaviewToastKind.error);
    final playing = !isError && (status == PlaybackStatus.playing || status == PlaybackStatus.buffering);
    final progress = (!isError && duration > 0) ? position / duration : 0.0;
    final subtitle = switch (status) {
      _ when isError => error != null ? playerErrorMessage(error) : "Couldn't play this video",
      PlaybackStatus.loading => 'Loading…',
      _ when duration > 0 =>
        '${formatClock(Duration(seconds: position))} / ${formatClock(Duration(seconds: duration))}',
      _ => mediaHost(media) ?? 'Ready to play',
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: DanaviewSpacing.md),
      child: DanaviewPressable(
        onTap: onOpen,
        borderRadius: DanaviewRadius.lgAll,
        semanticLabel: isError
            ? 'Playback error: ${media.title}. Open player'
            : 'Now playing: ${media.title}. Open player',
        child: DanaviewSurface(
          shadow: DanaviewShadow.subtle,
          padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 10, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  DanaviewTileIcon(
                    isError
                        ? Icons.error_outline_rounded
                        : (playing ? Icons.graphic_eq_rounded : mediaIcon(media)),
                    color: isError ? DanaviewColors.errorLight : DanaviewColors.primaryLight,
                    size: 44,
                  ),
                  const SizedBox(width: DanaviewSpacing.md),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isError ? 'COULD NOT PLAY' : 'NOW PLAYING',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.micro.copyWith(
                            color: isError ? DanaviewColors.errorLight : DanaviewColors.primaryLight,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          media.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.headline,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.caption.copyWith(
                            color: isError ? DanaviewColors.errorLight : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: DanaviewSpacing.xs),
                  if (isError)
                    DanaviewIconButton(
                      icon: Icons.refresh_rounded,
                      variant: DanaviewIconButtonVariant.tonal,
                      size: 40,
                      tooltip: 'Retry',
                      onPressed: () => ref.read(playerControllerProvider.notifier).openMedia(media),
                    )
                  else
                    DanaviewIconButton(
                      icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      variant: DanaviewIconButtonVariant.primary,
                      size: 40,
                      tooltip: playing ? 'Pause' : 'Play',
                      onPressed: () => ref.read(playerControllerProvider.notifier).togglePlay(),
                    ),
                  const SizedBox(width: 4),
                  DanaviewIconButton(
                    icon: Icons.close_rounded,
                    variant: DanaviewIconButtonVariant.plain,
                    size: 40,
                    tooltip: 'Clear',
                    onPressed: () => ref.read(queueControllerProvider.notifier).clear(),
                  ),
                ],
              ),
              if (!isError && progress > 0) ...[
                const SizedBox(height: DanaviewSpacing.md),
                DanaviewProgressLine(progress: progress),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAction {
  const _QuickAction(this.label, this.caption, this.color, this.onTap, {this.icon, this.glyph})
      : assert(icon != null || glyph != null);

  final String label;
  final String caption;
  final Color color;
  final VoidCallback onTap;
  final IconData? icon;
  final DanaviewGlyphKind? glyph;

  Widget tile(double size) => glyph != null
      ? DanaviewTileIcon.glyph(glyph!, color: color, size: size)
      : DanaviewTileIcon(icon!, color: color, size: size);
}

/// Three equal tiles in a row: icon beside the text when tiles are wide, icon above the
/// label when narrow, and two columns (last tile full width) when labels would not fit.
class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.actions});

  final List<_QuickAction> actions;

  static const _gap = 10.0;
  static const _minTileWidth = 96.0;
  static const _wideTileWidth = 190.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final width = constraints.maxWidth;
        final tileWidth = (width - _gap * (actions.length - 1)) / actions.length;
        if (width >= actions.length * _minTileWidth * scale + (actions.length - 1) * _gap) {
          final horizontal = tileWidth >= _wideTileWidth * scale;
          return _row([for (final action in actions) _QuickActionTile(action: action, horizontal: horizontal)]);
        }
        final tiles = [for (final action in actions) _QuickActionTile(action: action, horizontal: false)];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < tiles.length; i += 2) ...[
              if (i > 0) const SizedBox(height: _gap),
              _row(tiles.sublist(i, i + 2 > tiles.length ? tiles.length : i + 2)),
            ],
          ],
        );
      },
    );
  }

  Widget _row(List<Widget> tiles) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: _gap),
            Expanded(child: tiles[i]),
          ],
        ],
      ),
    );
  }
}

class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({required this.action, required this.horizontal});

  final _QuickAction action;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      action.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: horizontal ? TextAlign.start : TextAlign.center,
      style: DanaviewTextStyles.headline.copyWith(fontSize: horizontal ? 15 : 14),
    );
    return DanaviewPressable(
      onTap: action.onTap,
      borderRadius: DanaviewRadius.lgAll,
      semanticLabel: action.label,
      child: DanaviewSurface(
        padding: horizontal ? const EdgeInsets.all(14) : const EdgeInsets.fromLTRB(10, 16, 10, 14),
        child: horizontal
            ? Row(
                children: [
                  action.tile(40),
                  const SizedBox(width: DanaviewSpacing.md),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        label,
                        const SizedBox(height: 2),
                        Text(
                          action.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.caption,
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  action.tile(44),
                  const SizedBox(height: 10),
                  label,
                ],
              ),
      ),
    );
  }
}
