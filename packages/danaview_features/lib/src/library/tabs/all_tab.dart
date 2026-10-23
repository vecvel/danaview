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
        final columns = danaviewLibraryGridColumns(constraints.maxWidth - padding.horizontal);
        return CustomScrollView(
          key: const PageStorageKey('library-all-tab'),
          slivers: [
            SliverPadding(
              padding: padding,
              sliver: entries.isEmpty
                  ? const SliverToBoxAdapter(child: LibraryFilterEmpty(filter: LibraryFilter.all))
                  : columns > 1
                      ? _monthGrid(entries, columns, rowActions)
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

  /// The timeline as month sections of card rows (wide screens): built lazily in order, a row never
  /// mixes two months.
  static Widget _monthGrid(LibraryEntryPages entries, int columns, LibraryEntryActions actions) {
    final rows = _MonthGridRows(entries, columns);
    return SliverList.builder(
      key: const ValueKey('library-all-grid'),
      itemBuilder: (context, i) {
        final item = rows.item(i);
        if (item == null) return null;
        if (item.header case final month?) return DanaviewLibrarySectionHeader(month, topSpacing: i == 0 ? 0 : 20);
        final row = DanaviewLibraryGridRow(
          columns: columns,
          children: [
            for (var e = item.start; e < item.end; e++)
              if (entries.at(e) case final entry?) LibraryEntryRow(entry: entry, actions: actions) else const SizedBox(height: 56),
          ],
        );
        final afterRow = i > 0 && rows.item(i - 1)?.header == null;
        return afterRow ? Padding(padding: const EdgeInsets.only(top: danaviewLibraryGridGap), child: row) : row;
      },
    );
  }
}

/// The All grid's items: a month header, or one row of entries [start, end) of that month.
typedef _MonthGridItem = ({String? header, int start, int end});

class _MonthGridRows {
  _MonthGridRows(this.entries, this.columns);

  final LibraryEntryPages entries;
  final int columns;
  final List<_MonthGridItem> _items = [];
  int _next = 0;
  String? _month;

  String? _monthOf(int index) {
    final entry = entries.at(index);
    return entry == null ? _month : libraryMonthLabel(entry.addedAt);
  }

  /// Item [index], or null past the end.
  _MonthGridItem? item(int index) {
    while (_items.length <= index && _next < entries.length) {
      final month = _monthOf(_next);
      if (month != null && (_items.isEmpty || month != _month)) {
        _month = month;
        _items.add((header: month, start: _next, end: _next));
        continue;
      }
      var end = _next + 1;
      while (end < entries.length && end - _next < columns && _monthOf(end) == _month) {
        end++;
      }
      _items.add((header: null, start: _next, end: end));
      _next = end;
    }
    return index < _items.length ? _items[index] : null;
  }
}
