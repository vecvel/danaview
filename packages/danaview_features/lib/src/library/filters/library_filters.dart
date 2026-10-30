// OWNER: HOM-18
//
// The library filters of the Files & Media Home (ARCH v1.2 V2-114, HOM plan §5.2, §8.1, D-98a):
// `All` (every kind), `Videos`, `Photos` and `Documents` with the sub-filter chips `PDF`, `Word`,
// `Excel`, `PowerPoint`, `Text/CSV` and `Other`. A filter is the set of HOM-16 classifier kinds it
// shows; nothing here classifies a file again (the kind and sub-kind are stored per entry).
//
// Release slices (BUILD_PLAN §1A): slice S2 ships `All`, `Videos`, `Photos` and `Folders`; the
// `Documents` filter and its tab stay hidden until S3 behind [documentsFilterShown], the one switch
// this ticket owns. [libraryFilterTabSlots] is what the app root (INT-103) calls to fill the Home's
// tab slots, so flipping the switch at S3 is the only change needed.

import 'package:danaview_library/danaview_library.dart';

import '../home/home_tabs.dart';

/// Whether the `Documents` filter, its tab and its sub-filter chips are shown.
///
/// False in slice S2 (BUILD_PLAN §1A: "Documents tab hidden until S3"); slice S3 flips it to true.
/// It is a release switch, not a user setting and not one of the `--dart-define` flags.
const bool documentsFilterShown = false;

/// One library filter of the Home (V2-114).
enum LibraryFilter {
  /// Every kind, chronological.
  all('All', null),

  /// Videos only.
  videos('Videos', {FileKind.video}),

  /// Photos only.
  photos('Photos', {FileKind.photo}),

  /// Documents only (sub-filters by [DocumentKind]).
  documents('Documents', {FileKind.document});

  const LibraryFilter(this.label, this.kinds);

  /// The visible (and spoken) label.
  final String label;

  /// The classifier kinds shown, or null for every kind (including kinds this build doesn't know,
  /// which decode to [FileKind.other]).
  final Set<FileKind>? kinds;

  /// True when an entry of [kind] belongs under this filter.
  bool matches(FileKind kind) => kinds?.contains(kind) ?? true;

  /// True when [entry] belongs under this filter and the optional document [subFilter].
  bool matchesEntry(FileEntry entry, {DocumentKind? subFilter}) {
    if (!matches(entry.kind)) return false;
    if (subFilter == null) return true;
    return entry.kind == FileKind.document && entry.docKind == subFilter;
  }

  /// The Home tab of this filter; `All` is no tab but the filter's "Show: All" view (null).
  HomeTab? get tab => switch (this) {
        LibraryFilter.all => null,
        LibraryFilter.videos => HomeTab.videos,
        LibraryFilter.photos => HomeTab.photos,
        LibraryFilter.documents => HomeTab.documents,
      };
}

/// The filters shown, in order; `Documents` follows [showDocuments].
List<LibraryFilter> visibleLibraryFilters({bool showDocuments = documentsFilterShown}) => [
      for (final filter in LibraryFilter.values)
        if (filter != LibraryFilter.documents || showDocuments) filter,
    ];

/// The Documents sub-filter chips, in HOM plan §8.1 order (null is the leading "All documents").
List<DocumentKind?> get documentSubFilters => const [null, ...DocumentKind.values];

/// The chip label of a Documents sub-filter.
String documentSubFilterLabel(DocumentKind? subFilter) => subFilter?.filterLabel ?? 'All documents';

/// The Home's tab slots with this ticket's tab bodies filled in over [base] (the photos tab, the
/// Overview slots and the selection bar stay as [base] has them).
///
/// With [showDocuments] false (slice S2) the `Documents` body is dropped and the tab is hidden, so
/// no route reaches it.
HomeTabSlots libraryFilterTabSlots({
  HomeTabSlots base = HomeTabSlots.none,
  HomeSlotBuilder? all,
  HomeSlotBuilder? videos,
  HomeSlotBuilder? documents,
  HomeSlotBuilder? folders,
  bool showDocuments = documentsFilterShown,
}) =>
    HomeTabSlots(
      all: all ?? base.all,
      videos: videos ?? base.videos,
      photos: base.photos,
      documents: showDocuments ? documents ?? base.documents : null,
      folders: folders ?? base.folders,
      projects: base.projects,
      recentPhotos: base.recentPhotos,
      favourites: base.favourites,
      selectionBar: base.selectionBar,
      search: base.search,
      documentsOverview: showDocuments ? base.documentsOverview : null,
      projectsOverview: base.projectsOverview,
      showDocuments: showDocuments,
    );
