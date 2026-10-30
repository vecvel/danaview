// OWNER: HOM-05
// EXTENDED: Home four tabs (DESIGN_SYSTEM §10.2–10.4: Home · Videos · Photos · Documents; the
// Projects, Playlists and Folders lists are full screens opened from "See all"; every file is the
// filter's "Show: All" view)
//
// The tabs of the Files & Media Home (ARCH v1.2 V2-101, HOM plan §5, D-86 updated by D-98a), the
// full screens the tabs open, and the slots later tickets fill (BUILD_PLAN HOM-05). The Home
// shell owns the order and the visibility rules; each body comes from its owning ticket through
// [HomeTabSlots], so no ticket edits the shell to add its body (BUILD_PLAN §0.2):
//
// * Tabs: `Videos`, `Documents` (HOM-18, `tabs/*.dart`); `Photos` (HOM-10).
// * The "Show: All" view of the filter (every file): HOM-18's `All` grid.
// * Screens ([HomeDestination]): `Folders` (HOM-18), `Projects` (the editor's project list,
//   INT-105, only where the editor runs) and `Playlists` (the shell's own).
// * Overview slots: the Recent photos tray (HOM-09), the Favourites row (HOM-19), Recent projects
//   and Documents.
// * The selection bar over every tab and screen (HOM-12).
//
// A tab without a body shows a neutral empty pane, except `Videos`, which falls back to the
// shell's own Videos page; the Folders screen without a body shows the 1.1 Folders section
// unchanged (P-5).

import 'package:flutter/widgets.dart';

/// A tab of the Files & Media Home, in strip order.
enum HomeTab {
  /// The Overview: the 1.1 Home sections plus the additive slots.
  home('Home'),

  /// Videos: Continue watching, Projects, Playlists and every video.
  videos('Videos'),

  /// Photos only (the square grid).
  photos('Photos'),

  /// Documents with sub-filters (shown from slice S3).
  documents('Documents');

  const HomeTab(this.label);

  /// The visible (and spoken) label.
  final String label;
}

/// A full screen of the Files & Media Home, pushed on the navigator by a section's "See all".
enum HomeDestination {
  /// The editor's projects (the Videos tab's Projects row, the Home's Recent projects).
  projects('Projects'),

  /// The playlist manager (the Videos tab's Playlists row).
  playlists('Playlists'),

  /// Danaview folders and linked folders (the Home's Folders section).
  folders('Folders');

  const HomeDestination(this.label);

  /// The screen title.
  final String label;
}

/// Whether the platform runs the editor (iOS and Android; desktop hides it, v1.1 D-17).
bool homeEditorPlatform(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.android;

/// The visible tabs, in order: `Documents` follows [showDocuments].
List<HomeTab> visibleHomeTabs({bool showDocuments = true}) => [
      for (final tab in HomeTab.values)
        if (tab != HomeTab.documents || showDocuments) tab,
    ];

/// Whether the editor's projects (the Videos tab's Projects row and the Projects screen) exist:
/// [projectsAvailable] (the app passed a projects callback or body) on an editor platform.
bool homeProjectsShown({required TargetPlatform platform, required bool projectsAvailable}) =>
    projectsAvailable && homeEditorPlatform(platform);

/// Asks the Home shell to show [tab]. Any page or slot can dispatch it (the Recent photos tray's
/// See all does when it has no `onSeeAll`); `DanaviewHomeScreen` selects the tab when it is
/// visible and lets the notification keep bubbling so an app shell above can follow along.
class HomeTabRequestNotification extends Notification {
  /// A request for [tab].
  const HomeTabRequestNotification(this.tab);

  /// The tab to show.
  final HomeTab tab;
}

/// Asks the Home shell to push the full screen [destination] (a section's "See all", a folder
/// hit in search, a favourite folder). `DanaviewHomeScreen` pushes it and stops the notification.
class HomeDestinationRequestNotification extends Notification {
  /// A request for [destination].
  const HomeDestinationRequestNotification(this.destination);

  /// The screen to push.
  final HomeDestination destination;
}

/// The body of one Home tab, screen or slot.
typedef HomeSlotBuilder = Widget Function(BuildContext context);

/// The bodies later tickets supply for the Home's tabs, screens and the Overview's additive rows.
///
/// Every builder is optional; the app root (INT-103) fills them as the owning tickets land.
@immutable
class HomeTabSlots {
  /// Creates the slots; a null builder falls back as the library doc of this file says.
  const HomeTabSlots({
    this.all,
    this.videos,
    this.photos,
    this.documents,
    this.folders,
    this.projects,
    this.recentPhotos,
    this.favourites,
    this.selectionBar,
    this.search,
    this.documentsOverview,
    this.projectsOverview,
    this.showDocuments = true,
  });

  /// No bodies: every library tab shows its empty pane.
  static const HomeTabSlots none = HomeTabSlots();

  /// The filter's "Show: All" view, every file (HOM-18's All grid).
  final HomeSlotBuilder? all;

  /// The `Videos` tab (HOM-18); null shows the shell's own Videos page.
  final HomeSlotBuilder? videos;

  /// The `Photos` tab (HOM-10).
  final HomeSlotBuilder? photos;

  /// The `Documents` tab (HOM-18).
  final HomeSlotBuilder? documents;

  /// The body of the Folders screen (HOM-18); null shows the 1.1 Folders section.
  final HomeSlotBuilder? folders;

  /// The body of the Projects screen (INT-105); null shows the shell's project grid when the app
  /// opens projects by id, else a pane that calls `onOpenProjects`.
  final HomeSlotBuilder? projects;

  /// The Recent photos tray of the Overview (HOM-09), below Continue watching.
  final HomeSlotBuilder? recentPhotos;

  /// The Favourites row of the Overview (HOM-19), below the Recent photos tray.
  final HomeSlotBuilder? favourites;

  /// The multi-select bar drawn over the bottom of every tab and screen (HOM-12).
  final HomeSlotBuilder? selectionBar;

  /// The search field of the top bar (HOM-19; DESIGN_SYSTEM §10.1): it takes the full width left
  /// of the filter button. Null hides the search row.
  final HomeSlotBuilder? search;

  /// The Documents section of the Overview (§10.3, Files Home only); shown with [showDocuments].
  /// It hides itself when there are no documents.
  final HomeSlotBuilder? documentsOverview;

  /// The Recent projects section of the Overview (§10.3, editor only); the app fills it where the
  /// editor runs. It hides itself when there are no projects.
  final HomeSlotBuilder? projectsOverview;

  /// Whether the `Documents` tab is shown (slice S2 passes false; S3 shows it).
  final bool showDocuments;

  /// The body slot of [tab], or null (the shell builds Home itself).
  HomeSlotBuilder? bodyOf(HomeTab tab) => switch (tab) {
        HomeTab.home => null,
        HomeTab.videos => videos,
        HomeTab.photos => photos,
        HomeTab.documents => documents,
      };

  /// The body slot of the screen [destination], or null (the shell builds Playlists itself).
  HomeSlotBuilder? screenOf(HomeDestination destination) => switch (destination) {
        HomeDestination.projects => projects,
        HomeDestination.folders => folders,
        HomeDestination.playlists => null,
      };
}
