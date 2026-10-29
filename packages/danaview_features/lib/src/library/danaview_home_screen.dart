// EXTENDED: HOM-05 (Files & Media Home tab shell behind DANAVIEW_FILES_HOME; ARCH v1.2 V2-101, V2-32)
// EXTENDED: UI pivot (DESIGN_SYSTEM §10: Cinema B Home structure)
//
// [DanaviewHomeScreen] builds the §10 Home. The top bar holds the logo tile, the "Danaview" large
// title and the round toolbar buttons (Import on phones; Video editor, Import and Settings on
// tablets and desktops); on phones the editor and settings move to the bottom tab bar (§10.5).
// The Home sections follow §10.3: Now Playing, Continue watching (16:9 media cards), Recent
// photos, Projects, Playlists, Folders and Documents. Empty sections are hidden; when everything
// is empty one empty state offers Open file / Open folder / Open link. Wide layouts split the
// sections into two columns, tablets in portrait put the grouped lists 2-up.
//
// With DANAVIEW_FILES_HOME off the header scrolls with the sections and there are no tabs (pinned
// by test/home_screen_test.dart and the goldens of test/v12/home_shell/). With it on, the header,
// the search row and a tab strip sit in the top bar and a tab host shows one tab: `Home` holds the
// same sections plus the Files Home slots; the other tabs come from [HomeTabSlots].

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
import 'home/home_chrome.dart';
import 'home/home_media_card.dart';
import 'home/home_tab_host.dart';
import 'home/home_tab_strip.dart';
import 'home/home_tabs.dart';
import 'import/import_providers.dart';
import 'import/import_sheet.dart';
import 'library_actions.dart';
import 'library_controller.dart';
import 'library_format.dart';
import 'library_providers.dart';
import 'library_widgets.dart';
import 'media_picker.dart';
import 'open_link_dialog.dart';

export 'home/home_callbacks.dart' show HomeCallbacks, HomeCallbacksScope;
export 'home/home_chrome.dart' show HomeChromeLabels, HomePhoneTabBar, homeIsCompact;
export 'home/home_media_card.dart' show HomeMediaCard, HomeMediaCardGrid, HomeMediaCardRow;
export 'home/home_tab_strip.dart' show homeTabKey;
export 'home/home_tabs.dart' show HomeSlotBuilder, HomeTab, HomeTabSlots, homeEditorPlatform, visibleHomeTabs;

/// The content width from which the Home splits into two columns (iPad landscape, desktop).
const double homeTwoColumnMinWidth = 1100;

/// The content width from which the Home's grouped lists sit 2-up (tablets in portrait).
const double homeTwoUpListsMinWidth = 600 - 2 * DanaviewSpacing.xl;

/// Start screen: now playing, continue watching, recent photos, playlists, folders and documents.
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

  /// Shows a settings button at the end of the top bar when set (the tab bar's More on phones).
  final VoidCallback? onOpenSettings;

  /// Shows the video editor button left of Import when set (the tab bar's Editor on phones); null
  /// hides it (the app passes null where the editor is unavailable). This package never imports
  /// the editor: the router supplies the navigation.
  final VoidCallback? onOpenEditor;

  /// The optional 1.2.0 entry points (editor, projects, AI).
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

  // ---- Chrome (§10.1, §10.5) ----

  /// The quick actions: the empty state's buttons and the Import menu's first rows.
  List<_QuickAction> get _quickActions => [
        _QuickAction('Open file', _openFile, icon: Icons.video_file_rounded),
        _QuickAction('Open folder', _openFolder, glyph: DanaviewGlyphKind.folderOpen),
        _QuickAction('Open link', _openLink, icon: Icons.link_rounded),
      ];

  /// The Import (+) menu: import into the library (Files Home), the quick actions, then New
  /// playlist and Add folder, so every 1.1 entry point stays one menu away when its section is
  /// hidden.
  List<DanaviewMenuEntry> _importEntries({required bool canImport}) => [
        if (canImport) ...[
          DanaviewMenuItem(
            label: HomeChromeLabels.importToLibrary,
            icon: Icons.download_rounded,
            onTap: () => showImportSheet(context),
          ),
          const DanaviewMenuDivider(),
        ],
        for (final action in _quickActions)
          DanaviewMenuItem(label: action.label, icon: action.icon, glyph: action.glyph, onTap: action.onTap),
        const DanaviewMenuDivider(),
        DanaviewMenuItem(label: 'New playlist', icon: Icons.playlist_add_rounded, onTap: _newPlaylist),
        if (canPickFolders) DanaviewMenuItem(label: 'Add folder', glyph: DanaviewGlyphKind.folderAdd, onTap: _addFolder),
      ];

  /// The top bar's round buttons: Import only on phones; Video editor, Import and Settings on
  /// tablets and desktops.
  List<Widget> _topBarActions({required bool compact, required bool canImport}) => [
        if (!compact && widget.onOpenEditor != null)
          DanaviewIconButton.toolbar(
            icon: Icons.movie_edit,
            tooltip: HomeChromeLabels.editor,
            semanticLabel: HomeChromeLabels.editorSemantics,
            onPressed: widget.onOpenEditor,
          ),
        HomeImportButton(entries: _importEntries(canImport: canImport)),
        if (!compact && widget.onOpenSettings != null)
          DanaviewIconButton.toolbar(
            icon: Icons.settings_rounded,
            tooltip: HomeChromeLabels.settings,
            semanticLabel: HomeChromeLabels.settings,
            onPressed: widget.onOpenSettings,
          ),
      ];

  Widget _topBar(BuildContext context, {required bool compact}) => HomeTopBar(
        key: const ValueKey('home-top-bar'),
        compact: compact,
        actions: _topBarActions(compact: compact, canImport: ref.watch(importServiceProvider) != null),
      );

  /// The phone tab bar (compact widths only): Library · Editor · AI Studio · More, or null when it
  /// would hold Library alone.
  Widget? _phoneTabBar(BuildContext context, {required bool compact}) {
    if (!compact) return null;
    final aiStudio = widget.callbacks.onOpenAiStudio;
    final items = [
      HomeTabBarItem(
        key: const ValueKey('home-tabbar-library'),
        label: 'Library',
        icon: Icons.video_library_rounded,
        selected: true,
        onTap: () => _selectTab(HomeTab.home),
      ),
      if (widget.onOpenEditor case final openEditor?)
        HomeTabBarItem(
          key: const ValueKey('home-tabbar-editor'),
          label: 'Editor',
          icon: Icons.movie_edit,
          tooltip: HomeChromeLabels.editor,
          semanticLabel: HomeChromeLabels.editorSemantics,
          onTap: openEditor,
        ),
      if (FeatureFlags.aiStudioEnabled && aiStudio != null)
        HomeTabBarItem(
          key: const ValueKey('home-tabbar-ai-studio'),
          label: 'AI Studio',
          icon: Icons.auto_awesome_rounded,
          onTap: aiStudio,
        ),
      if (widget.onOpenSettings case final openSettings?)
        HomeTabBarItem(
          key: const ValueKey('home-tabbar-more'),
          label: 'More',
          icon: Icons.more_horiz_rounded,
          tooltip: HomeChromeLabels.settings,
          semanticLabel: 'More: ${HomeChromeLabels.settings}',
          onTap: openSettings,
        ),
    ];
    if (items.length < 2) return null;
    return HomePhoneTabBar(key: const ValueKey('home-phone-tab-bar'), items: items);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryControllerProvider);
    final compact = homeIsCompact(MediaQuery.sizeOf(context).width);
    if (FeatureFlags.filesHomeEnabled) return _buildFilesHome(context, compact: compact);
    return DanaviewRefreshOnReturn(
      onReturn: () => _library.refresh(),
      child: Scaffold(
        backgroundColor: DanaviewColors.background,
        bottomNavigationBar: _phoneTabBar(context, compact: compact),
        body: DanaviewLibraryFrame(
          body: LayoutBuilder(
            builder: (context, constraints) {
              final insets = danaviewLibraryInsets(constraints.maxWidth);
              return CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: insets.copyWith(
                      top: DanaviewSpacing.lg,
                      bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl,
                    ),
                    sliver: SliverList.list(
                      children: [
                        _topBar(context, compact: compact),
                        ..._overviewSections(state, width: constraints.maxWidth - insets.horizontal),
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

  /// The Home sections below the top bar (§10.3). With [slots] (DANAVIEW_FILES_HOME on) the Files
  /// Home rows join them; the 1.1 sections are the same widgets either way.
  List<Widget> _overviewSections(LibraryState state, {required double width, HomeTabSlots? slots}) {
    return [
      _NowPlayingCard(onOpen: widget.onOpenPlayer),
      if (state.error != null)
        Padding(
          padding: const EdgeInsets.only(top: DanaviewSpacing.lg),
          child: DanaviewInlineEmpty(
            icon: Icons.error_outline_rounded,
            iconColor: DanaviewColors.error,
            title: state.error!,
            message: 'Your files are safe. Try loading the library again.',
            action: DanaviewButton.secondary(
              label: 'Try again',
              icon: Icons.refresh_rounded,
              size: DanaviewButtonSize.sm,
              onPressed: () => _library.refresh(),
            ),
          ),
        ),
      if (state.hasLoaded) _overviewLayout(state, width: width, slots: slots),
    ];
  }

  /// Lays the sections out for [width]: one column on phones, the grouped lists 2-up on tablets
  /// in portrait, and two columns (media ≈ 60 %, lists ≈ 40 %) from [homeTwoColumnMinWidth].
  Widget _overviewLayout(LibraryState state, {required double width, HomeTabSlots? slots}) {
    final empty = state.recent.isEmpty && state.playlists.isEmpty && state.roots.isEmpty;
    final media = <Widget>[
      if (empty) _HomeEmptyState(actions: _quickActions),
      if (_recentSection(state.recent) case final recent?) recent,
      if (slots?.recentPhotos case final tray?)
        KeyedSubtree(key: const ValueKey('home-slot-recent-photos'), child: Builder(builder: tray)),
      if (slots?.favourites case final favourites?)
        KeyedSubtree(key: const ValueKey('home-slot-favourites'), child: Builder(builder: favourites)),
      if (slots?.projectsOverview case final projects?)
        KeyedSubtree(key: const ValueKey('home-slot-projects'), child: Builder(builder: projects)),
    ];
    final lists = <Widget>[
      if (_playlistSection(state.playlists, hideEmpty: true) case final playlists?) playlists,
      if (_folderSection(state.roots, hideEmpty: true) case final folders?) folders,
      if (slots != null && slots.showDocuments)
        if (slots.documentsOverview case final documents?)
          KeyedSubtree(key: const ValueKey('home-slot-documents'), child: Builder(builder: documents)),
    ];
    Widget column(List<Widget> children) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
    if (width >= homeTwoColumnMinWidth && media.isNotEmpty && lists.isNotEmpty) {
      return Row(
        key: const ValueKey('home-two-columns'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: column(media)),
          const SizedBox(width: DanaviewSpacing.xl),
          Expanded(flex: 2, child: column(lists)),
        ],
      );
    }
    if (width >= homeTwoUpListsMinWidth && lists.length > 1) {
      return column([
        ...media,
        for (var i = 0; i < lists.length; i += 2)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: lists[i]),
              const SizedBox(width: DanaviewSpacing.lg),
              Expanded(child: i + 1 < lists.length ? lists[i + 1] : const SizedBox.shrink()),
            ],
          ),
      ]);
    }
    return column([...media, ...lists]);
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

  /// The filter menu: one row per visible tab, the selected one checked.
  List<DanaviewMenuEntry> _filterEntries(List<HomeTab> tabs, HomeTab selected) => [
        const DanaviewMenuHeader('Show'),
        for (final tab in tabs)
          DanaviewMenuItem(label: tab.label, selected: tab == selected, onTap: () => _selectTab(tab)),
      ];

  Widget _buildFilesHome(BuildContext context, {required bool compact}) {
    final tabs = _visibleTabs(context);
    final selected = tabs.contains(_tab) ? _tab : HomeTab.home;
    final selectionBar = widget.tabSlots.selectionBar;
    final search = widget.tabSlots.search;
    return HomeCallbacksScope(
      callbacks: widget.callbacks,
      child: DanaviewRefreshOnReturn(
        onReturn: () => _library.refresh(),
        child: Scaffold(
          backgroundColor: DanaviewColors.background,
          bottomNavigationBar: _phoneTabBar(context, compact: compact),
          body: DanaviewLibraryFrame(
            topBar: LayoutBuilder(
              builder: (context, constraints) {
                final insets = danaviewLibraryInsets(constraints.maxWidth);
                return Column(
                  key: const ValueKey('home-files-top-bar'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(padding: insets.copyWith(top: DanaviewSpacing.md), child: _topBar(context, compact: compact)),
                    if (search != null)
                      Padding(
                        padding: insets.copyWith(top: DanaviewSpacing.md),
                        child: HomeSearchRow(
                          search: KeyedSubtree(key: const ValueKey('home-slot-search'), child: Builder(builder: search)),
                          filter: HomeFilterButton(
                            entries: _filterEntries(tabs, selected),
                            active: selected != HomeTab.home,
                            semanticLabel: 'Filter: showing ${selected.label}',
                          ),
                        ),
                      ),
                    const SizedBox(height: DanaviewSpacing.xs),
                    HomeTabStrip(
                      key: const ValueKey('home-tab-strip'),
                      tabs: tabs,
                      selected: selected,
                      onSelected: _selectTab,
                      padding: insets,
                    ),
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
          top: DanaviewSpacing.xs,
          bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl,
        );
        final width = constraints.maxWidth - insets.horizontal;
        // Each page reads the latest library state itself: pages built once stay alive.
        return Consumer(
          builder: (context, ref, _) {
            final state = ref.watch(libraryControllerProvider);
            final sections = switch (tab) {
              HomeTab.home => _overviewSections(state, width: width, slots: widget.tabSlots),
              HomeTab.playlists => state.hasLoaded ? [_playlistSection(state.playlists)!] : const <Widget>[],
              HomeTab.folders => state.hasLoaded ? [_folderSection(state.roots)!] : const <Widget>[],
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

  // ---- Sections (§10.3) ----

  Widget _section(List<Widget> children, {Key? key}) => Column(
        key: key,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );

  /// Continue watching: a horizontal row of media cards (all of them in a grid once expanded),
  /// or null when there is no history.
  Widget? _recentSection(List<LibraryRecentItem> recent) {
    if (recent.isEmpty) return null;
    final visible = _showAllRecent ? recent : recent.take(_recentPreviewCount);
    final cards = [for (final item in visible) _recentCard(item)];
    return _section(key: const ValueKey('home-continue-watching'), [
      DanaviewLibrarySectionHeader(
        'Continue watching',
        prominent: true,
        action: DanaviewButton.text(label: 'Clear', size: DanaviewButtonSize.sm, onPressed: _clearHistory),
      ),
      if (_showAllRecent) HomeMediaCardGrid(children: cards) else HomeMediaCardRow(children: cards),
      if (recent.length > _recentPreviewCount)
        Padding(
          padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: DanaviewButton.text(
              label: _showAllRecent ? 'Show less' : 'Show all ${recent.length}',
              size: DanaviewButtonSize.sm,
              onPressed: () => setState(() => _showAllRecent = !_showAllRecent),
            ),
          ),
        ),
    ]);
  }

  Widget _recentCard(LibraryRecentItem item) {
    final media = item.media;
    final resumeLength = item.resume?.duration ?? Duration.zero;
    final length = resumeLength > Duration.zero ? resumeLength : media.duration;
    return HomeMediaCard(
      icon: mediaIcon(media),
      title: media.title,
      badge: episodeLabel(media),
      subtitle: mediaSubtitle(media, item.resume, exists: item.exists, fallback: parentFolderName(media.pathOrUri)),
      duration: length > Duration.zero ? formatClock(length) : null,
      progress: item.exists ? item.progress : null,
      dimmed: !item.exists,
      onTap: () => _playRecent(item),
      trailing: DanaviewMenuIconTrigger(
        icon: Icons.more_horiz_rounded,
        tooltip: 'More',
        size: 32,
        iconSize: 18,
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

  /// Playlists as a grouped list with New in the header. Empty: hidden on Home ([hideEmpty]), an
  /// empty state with New playlist on the Playlists tab.
  Widget? _playlistSection(List<PlaylistSummary> playlists, {bool hideEmpty = false}) {
    if (playlists.isEmpty && hideEmpty) return null;
    return _section(key: const ValueKey('home-playlists'), [
      DanaviewLibrarySectionHeader(
        'Playlists',
        prominent: true,
        action: playlists.isEmpty
            ? null
            : DanaviewButton.text(label: 'New', size: DanaviewButtonSize.sm, onPressed: _newPlaylist),
      ),
      if (playlists.isEmpty)
        DanaviewInlineEmpty(
          icon: Icons.queue_music_rounded,
          title: 'No playlists yet',
          message: 'Collect videos and links to play them in order.',
          action: DanaviewButton.secondary(
            label: 'New playlist',
            icon: Icons.add_rounded,
            size: DanaviewButtonSize.sm,
            onPressed: _newPlaylist,
          ),
        )
      else
        DanaviewLibraryCardGrid(
          children: [
            for (final playlist in playlists)
              DanaviewLibraryRow(
                leading: const DanaviewIconTile(Icons.queue_music_rounded),
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
    ]);
  }

  /// Folders as a grouped list with Add in the header. Empty: hidden on Home ([hideEmpty]), an
  /// empty state with Add folder on the Folders tab.
  Widget? _folderSection(List<LibraryFolder> roots, {bool hideEmpty = false}) {
    if (roots.isEmpty && hideEmpty) return null;
    return _section(key: const ValueKey('home-folders'), [
      DanaviewLibrarySectionHeader(
        'Folders',
        prominent: true,
        action: canPickFolders && roots.isNotEmpty
            ? DanaviewButton.text(label: 'Add', size: DanaviewButtonSize.sm, onPressed: _addFolder)
            : null,
      ),
      if (roots.isEmpty)
        DanaviewInlineEmpty(
          glyph: DanaviewGlyphKind.folderVideo,
          title: 'No folders yet',
          message: canPickFolders
              ? 'Add a folder to browse its videos here. Nothing is copied or moved.'
              : 'Use Open file to add videos from your device.',
          action: canPickFolders
              ? DanaviewButton.secondary(
                  label: 'Add folder',
                  glyph: DanaviewGlyphKind.folderAdd,
                  size: DanaviewButtonSize.sm,
                  onPressed: _addFolder,
                )
              : null,
        )
      else
        DanaviewLibraryCardGrid(children: [for (final folder in roots) _folderRow(folder)]),
    ]);
  }

  Widget _folderRow(LibraryFolder folder) {
    if (folder.isDevice) {
      return DanaviewLibraryRow(
        leading: const DanaviewIconTile.glyph(DanaviewGlyphKind.device),
        title: folder.label,
        subtitle: Theme.of(context).platform == TargetPlatform.iOS
            ? 'Files app › ${LibraryStorage.iosFilesLocation(tablet: LibraryStorage.isTabletWidth(MediaQuery.sizeOf(context).shortestSide))}'
            : 'Device storage',
        subtitleMaxLines: 2,
        onTap: () => widget.onOpenFolder(folder.path),
        trailing: const Padding(
          padding: EdgeInsets.all(DanaviewSpacing.sm),
          child: Icon(Icons.chevron_right_rounded, size: 20, color: DanaviewColors.chevron),
        ),
      );
    }
    return DanaviewLibraryRow(
      leading: const DanaviewIconTile.glyph(DanaviewGlyphKind.folderVideo),
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

/// The Now Playing card: a `surface` card with the current media, its play/pause (the view's one
/// filled red control), Retry on errors and Clear; a tap returns to the player.
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
      padding: const EdgeInsets.only(top: DanaviewSpacing.lg),
      child: DanaviewPressable(
        onTap: onOpen,
        borderRadius: DanaviewRadius.cardAll,
        semanticLabel: isError
            ? 'Playback error: ${media.title}. Open player'
            : 'Now playing: ${media.title}. Open player',
        child: Container(
          decoration: DanaviewDepth.card(),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  DanaviewIconTile(
                    isError
                        ? Icons.error_outline_rounded
                        : (playing ? Icons.graphic_eq_rounded : mediaIcon(media)),
                    color: isError ? DanaviewColors.error : DanaviewColors.textPrimary,
                    size: 44,
                  ),
                  const SizedBox(width: DanaviewSpacing.md),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isError ? "Couldn't play" : 'Now playing',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.footnote.copyWith(
                            color: isError ? DanaviewColors.error : DanaviewColors.primaryLight,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          media.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.rowTitle,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.footnote.copyWith(
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
                      variant: DanaviewIconButtonVariant.filled,
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
  const _QuickAction(this.label, this.onTap, {this.icon, this.glyph}) : assert(icon != null || glyph != null);

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final DanaviewGlyphKind? glyph;
}

/// The one empty state of an empty Home (§8, §10.3): a neutral icon tile, a title, a line of body
/// text and the three quick actions.
class _HomeEmptyState extends StatelessWidget {
  const _HomeEmptyState({required this.actions});

  final List<_QuickAction> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('home-empty-state'),
      padding: const EdgeInsets.only(top: DanaviewSpacing.xl),
      child: Container(
        decoration: DanaviewDepth.card(),
        padding: const EdgeInsets.all(DanaviewSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DanaviewIconTile(Icons.video_library_rounded, size: 48, iconSize: 24),
            const SizedBox(height: DanaviewSpacing.md),
            Semantics(
              header: true,
              child: Text(
                'Nothing here yet',
                textAlign: TextAlign.center,
                style: DanaviewTextStyles.rowTitle,
              ),
            ),
            const SizedBox(height: DanaviewSpacing.xs),
            Text(
              'Open a video, a folder or a link to start watching.',
              textAlign: TextAlign.center,
              style: DanaviewTextStyles.subhead,
            ),
            const SizedBox(height: DanaviewSpacing.lg),
            _QuickActions(actions: actions),
          ],
        ),
      ),
    );
  }
}

/// The quick actions as equal secondary buttons: one row when the labels fit, else stacked.
class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.actions});

  final List<_QuickAction> actions;

  static const _gap = DanaviewSpacing.sm;
  static const _minButtonWidth = 132.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final buttons = [
          for (final action in actions)
            DanaviewButton.secondary(
              label: action.label,
              icon: action.icon,
              glyph: action.glyph,
              expand: true,
              onPressed: action.onTap,
            ),
        ];
        final fits = constraints.maxWidth >= actions.length * _minButtonWidth * scale + (actions.length - 1) * _gap;
        if (fits) {
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < buttons.length; i++) ...[
                  if (i > 0) const SizedBox(width: _gap),
                  Expanded(child: buttons[i]),
                ],
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < buttons.length; i++) ...[
              if (i > 0) const SizedBox(height: _gap),
              buttons[i],
            ],
          ],
        );
      },
    );
  }
}
