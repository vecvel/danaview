// OWNER: HOM-18
//
// The `All` filter tab (ARCH v1.2 V2-114; HOM plan §5.2, D-98a): every Danaview library entry of
// every kind (photos, videos, documents, audio, other files, and kinds of a newer build shown as
// files), newest first, with a month header when the month changes. Rows are read a page at a
// time from HOM-17's paged queries, so a 50,000-entry library builds only what is on screen. The
// tab re-reads after every library write. Without a store it shows the neutral empty pane.

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../filters/entry_widgets.dart';
import '../filters/filter_providers.dart';
import '../filters/library_filters.dart';
import '../library_widgets.dart';

const List<String> _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// The month header of [date]: `October 2026`.
String libraryMonthLabel(DateTime date) {
  final local = date.toLocal();
  return '${_monthNames[local.month - 1]} ${local.year}';
}

/// The empty state of a filter list.
class LibraryFilterEmpty extends StatelessWidget {
  /// The empty state of [filter].
  const LibraryFilterEmpty({super.key, required this.filter});

  /// The filter.
  final LibraryFilter filter;

  @override
  Widget build(BuildContext context) => DanaviewInlineEmpty(
        icon: switch (filter) {
          LibraryFilter.all => Icons.grid_view_rounded,
          LibraryFilter.videos => Icons.video_library_outlined,
          LibraryFilter.photos => Icons.photo_library_outlined,
          LibraryFilter.documents => Icons.description_outlined,
        },
        title: 'Nothing here yet',
        message: switch (filter) {
          LibraryFilter.all => 'Photos, videos and files you add to Danaview show up here.',
          LibraryFilter.videos => 'Videos you add to Danaview show up here.',
          LibraryFilter.photos => 'Photos you add to Danaview show up here.',
          LibraryFilter.documents => 'Documents you add to Danaview show up here.',
        },
      );
}

/// The `All` tab.
class AllTab extends ConsumerWidget {
  /// The tab; [onOpenEntry] opens an entry in its viewer, [actions] add the row menus (the app
  /// passes the file actions; none by default).
  const AllTab({super.key, this.onOpenEntry, this.actions});

  /// Opens an entry.
  final LibraryEntryOpen? onOpenEntry;

  /// The row menus' actions (Open is always [onOpenEntry]).
  final LibraryEntryActions? actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(libraryFilterEntriesProvider((filter: LibraryFilter.all, subFilter: null)));
    final rowActions = LibraryEntryActions(
      onOpen: onOpenEntry,
      onRename: actions?.onRename,
      onMove: actions?.onMove,
      onDelete: actions?.onDelete,
      onMore: actions?.onMore,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = danaviewLibraryInsets(constraints.maxWidth);
        final padding = insets.copyWith(top: DanaviewSpacing.lg, bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl);
        return CustomScrollView(
          key: const PageStorageKey('library-all-tab'),
          slivers: [
            SliverPadding(
              padding: padding,
              sliver: entries.isEmpty
                  ? const SliverToBoxAdapter(child: LibraryFilterEmpty(filter: LibraryFilter.all))
                  : SliverList.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, i) {
                        final entry = entries.at(i);
                        if (entry == null) return const SizedBox(height: 56);
                        final previous = i == 0 ? null : entries.at(i - 1);
                        final month = libraryMonthLabel(entry.addedAt);
                        final row = LibraryEntryRow(entry: entry, actions: rowActions);
                        if (previous != null && libraryMonthLabel(previous.addedAt) == month) return row;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            DanaviewLibrarySectionHeader(month, topSpacing: i == 0 ? 0 : 20),
                            row,
                          ],
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
