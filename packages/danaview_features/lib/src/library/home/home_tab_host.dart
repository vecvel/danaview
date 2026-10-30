// OWNER: HOM-05
// EXTENDED: Home four tabs (the filter's "Show: All" view is a page of the host beside the tabs)
//
// The tab host under the Home's tab strip (ARCH v1.2 V2-101): shows one tab at a time and keeps
// every visited tab alive, so scroll positions and tab-local state survive tab switches (HOM-10's
// "scroll position restored"). Tabs are built only on first visit, so an unvisited Photos grid
// costs nothing. Hidden tabs neither tick, paint, take pointers, focus nor semantics. The
// filter's "Show: All" view (every file) is one more page, kept alive the same way and shown in
// place of the selected tab while [HomeTabHost.showAll] is set.
// The neutral panes for tabs whose bodies have not been supplied yet live here too.

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';

import '../library_widgets.dart';
import 'home_tabs.dart';

/// The key of the page of [tab] in the host.
ValueKey<String> homeTabPageKey(HomeTab tab) => ValueKey('home-tab-page-${tab.name}');

/// The key of the filter's "Show: All" page (every file) in the host.
const ValueKey<String> homeAllPageKey = ValueKey('home-all-page');

/// Shows [selected]'s page and keeps the pages of earlier visits alive.
class HomeTabHost extends StatefulWidget {
  /// A host of [tabs]; [pageBuilder] builds a tab's page on its first visit, [allPageBuilder] the
  /// "Show: All" page on the first time [showAll] is set.
  const HomeTabHost({
    super.key,
    required this.tabs,
    required this.selected,
    required this.pageBuilder,
    this.showAll = false,
    this.allPageBuilder,
  });

  /// The visible tabs.
  final List<HomeTab> tabs;

  /// The tab on screen.
  final HomeTab selected;

  /// Builds the page of a tab.
  final Widget Function(BuildContext context, HomeTab tab) pageBuilder;

  /// Shows the "Show: All" page instead of [selected] (needs [allPageBuilder]).
  final bool showAll;

  /// Builds the "Show: All" page.
  final WidgetBuilder? allPageBuilder;

  @override
  State<HomeTabHost> createState() => _HomeTabHostState();
}

class _HomeTabHostState extends State<HomeTabHost> {
  /// The visited tabs in visit order: a page never moves once built, so a tab visited later (one
  /// left of it in the strip) never re-attaches it and its scroll position stays.
  final List<HomeTab> _visited = [];
  bool _allVisited = false;

  @override
  Widget build(BuildContext context) {
    final allBuilder = widget.allPageBuilder;
    final showAll = widget.showAll && allBuilder != null;
    _visited.removeWhere((tab) => !widget.tabs.contains(tab));
    if (showAll) {
      _allVisited = true;
    } else if (!_visited.contains(widget.selected)) {
      _visited.add(widget.selected);
    }
    final alive = List<HomeTab>.of(_visited);
    final index = showAll ? alive.length : alive.indexOf(widget.selected);
    return IndexedStack(
      index: index < 0 ? null : index,
      sizing: StackFit.expand,
      children: [
        for (final tab in alive)
          KeyedSubtree(
            key: homeTabPageKey(tab),
            child: _HiddenUnless(
              visible: !showAll && tab == widget.selected,
              child: Builder(builder: (context) => widget.pageBuilder(context, tab)),
            ),
          ),
        if (_allVisited && allBuilder != null)
          KeyedSubtree(
            key: homeAllPageKey,
            child: _HiddenUnless(visible: showAll, child: Builder(builder: allBuilder)),
          ),
      ],
    );
  }
}

class _HiddenUnless extends StatelessWidget {
  const _HiddenUnless({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: visible,
      child: ExcludeFocus(
        excluding: !visible,
        child: ExcludeSemantics(excluding: !visible, child: IgnorePointer(ignoring: !visible, child: child)),
      ),
    );
  }
}

/// The pane of a library tab (or of the "Show: All" view) whose body hasn't been supplied (the
/// app wires it per release slice).
class HomeEmptyTabPane extends StatelessWidget {
  /// The empty pane of [tab]; null is the "Show: All" view.
  const HomeEmptyTabPane({super.key, required this.tab, required this.padding});

  /// The tab, or null for the "Show: All" view.
  final HomeTab? tab;

  /// Gutters and bottom inset.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: padding,
      children: [
        DanaviewInlineEmpty(
          icon: switch (tab) {
            HomeTab.photos => Icons.photo_library_outlined,
            HomeTab.videos => Icons.video_library_outlined,
            HomeTab.documents => Icons.description_outlined,
            _ => Icons.grid_view_rounded,
          },
          title: 'Nothing here yet',
          message: switch (tab) {
            HomeTab.photos => 'Photos you add to Danaview show up here.',
            HomeTab.videos => 'Videos you add to Danaview show up here.',
            HomeTab.documents => 'Documents you add to Danaview show up here.',
            _ => 'Files you add to Danaview show up here.',
          },
        ),
      ],
    );
  }
}

/// The `Projects` pane when the app supplied no project list body: one button that opens the
/// editor's projects.
class HomeProjectsPane extends StatelessWidget {
  /// A pane that calls [onOpenProjects].
  const HomeProjectsPane({super.key, required this.onOpenProjects, required this.padding});

  /// Opens the editor's project list.
  final VoidCallback onOpenProjects;

  /// Gutters and bottom inset.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: padding,
      children: [
        DanaviewInlineEmpty(
          icon: Icons.movie_edit,
          title: 'Video projects',
          message: 'Edit videos and photos, then export them back to your library.',
          action: DanaviewButton.secondary(
            label: 'Open projects',
            icon: Icons.folder_open_rounded,
            size: DanaviewButtonSize.sm,
            onPressed: onOpenProjects,
          ),
        ),
      ],
    );
  }
}
