// OWNER: HOM-05
//
// The tabs of the Files & Media Home (ARCH v1.2 V2-101, HOM plan §5, D-86 updated by D-98a) and
// the slots later tickets fill (BUILD_PLAN HOM-05). The Home shell owns the order and the
// visibility rules; each tab's body comes from its owning ticket through [HomeTabSlots], so no
// ticket edits the shell to add its tab (BUILD_PLAN §0.2):
//
// * `All`, `Videos`, `Documents`, `Folders`: HOM-18 (`tabs/*.dart`); `Photos`: HOM-10.
// * `Projects`: the editor's project list (INT-105), shown only where the editor runs.
// * Overview slots: the Recent photos tray (HOM-09) and the Favourites row (HOM-19).
// * The selection bar over every tab (HOM-12).
//
// A tab without a body shows a neutral empty pane, except `Playlists` and `Folders`, which fall
// back to the 1.1 sections unchanged (P-4, P-5).

import 'package:flutter/widgets.dart';

/// A tab of the Files & Media Home, in strip order.
enum HomeTab {
  /// The Overview: the 1.1 Home sections unchanged plus the additive slots.
  home('Home'),

  /// Every kind, chronological (D-98a).
  all('All'),

  /// Videos only.
  videos('Videos'),

  /// Photos only (the masonry grid).
  photos('Photos'),

  /// Documents with sub-filters (shown from slice S3).
  documents('Documents'),

  /// The playlist manager (the 1.1 Playlists section).
  playlists('Playlists'),

  /// Danaview folders and linked folders.
  folders('Folders'),

  /// The editor's projects, only where the editor runs.
  projects('Projects');

  const HomeTab(this.label);

  /// The visible (and spoken) label.
  final String label;
}

/// Whether the platform runs the editor (iOS and Android; desktop hides it, v1.1 D-17).
bool homeEditorPlatform(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.android;

/// The visible tabs, in order.
///
/// `Projects` needs both [projectsAvailable] (the app passed `onOpenProjects` or a projects body)
/// and an editor platform; `Documents` follows [showDocuments].
List<HomeTab> visibleHomeTabs({
  required TargetPlatform platform,
  required bool projectsAvailable,
  bool showDocuments = true,
}) =>
    [
      for (final tab in HomeTab.values)
        if (switch (tab) {
          HomeTab.documents => showDocuments,
          HomeTab.projects => projectsAvailable && homeEditorPlatform(platform),
          _ => true,
        })
          tab,
    ];

/// The body of one Home tab or slot.
typedef HomeSlotBuilder = Widget Function(BuildContext context);

/// The bodies later tickets supply for the Home's tabs and the Overview's additive rows.
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
    this.showDocuments = true,
  });

  /// No bodies: every library tab shows its empty pane.
  static const HomeTabSlots none = HomeTabSlots();

  /// The `All` tab (HOM-18).
  final HomeSlotBuilder? all;

  /// The `Videos` tab (HOM-18).
  final HomeSlotBuilder? videos;

  /// The `Photos` tab (HOM-10).
  final HomeSlotBuilder? photos;

  /// The `Documents` tab (HOM-18).
  final HomeSlotBuilder? documents;

  /// The `Folders` tab (HOM-18); null shows the 1.1 Folders section.
  final HomeSlotBuilder? folders;

  /// The `Projects` tab body (INT-105); null shows a pane that calls `onOpenProjects`.
  final HomeSlotBuilder? projects;

  /// The Recent photos tray of the Overview (HOM-09), below Continue watching.
  final HomeSlotBuilder? recentPhotos;

  /// The Favourites row of the Overview (HOM-19), below the Recent photos tray.
  final HomeSlotBuilder? favourites;

  /// The multi-select bar drawn over the bottom of every tab (HOM-12).
  final HomeSlotBuilder? selectionBar;

  /// Whether the `Documents` tab is shown (slice S2 passes false; S3 shows it).
  final bool showDocuments;

  /// The body slot of [tab], or null (Home and Playlists have none; the shell builds them).
  HomeSlotBuilder? bodyOf(HomeTab tab) => switch (tab) {
        HomeTab.all => all,
        HomeTab.videos => videos,
        HomeTab.photos => photos,
        HomeTab.documents => documents,
        HomeTab.folders => folders,
        HomeTab.projects => projects,
        HomeTab.home || HomeTab.playlists => null,
      };
}
