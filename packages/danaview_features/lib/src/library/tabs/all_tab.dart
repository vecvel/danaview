// OWNER: HOM-18
//
// The `All` filter tab (ARCH v1.2 V2-114; HOM plan §5.2, D-98a; DESIGN_SYSTEM §10.4): every
// Danaview library entry of every kind (photos, videos, documents, audio, other files, and kinds of
// a newer build shown as files). Sort chips (Newest, Oldest, Name) and type chips (All types,
// Videos, Photos, Documents, Other) sit over a mixed adaptive grid (2 / 4 / 6 columns by width)
// of media cards and document tiles; the date sorts keep a month header whenever the month
// changes. Rows are read a page at a time from HOM-17's paged queries, so a 50,000-entry library
// builds only what is on screen. The tab re-reads after every library write. Without a store it
// shows the neutral empty pane.

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../filters/entry_widgets.dart';
import '../filters/filter_providers.dart';
import '../files/library_store_providers.dart';
import '../filters/library_filters.dart';
import '../home/home_grid.dart';
import '../home/home_media_card.dart';
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

/// The All tab's sort orders.
enum LibraryAllSort {
  /// Newest added first (the default, D-98a's chronological timeline).
  newest('Newest'),

  /// Oldest added first.
  oldest('Oldest'),

  /// By name, A to Z.
  name('Name');

  const LibraryAllSort(this.label);

  /// The chip label.
  final String label;

  /// Whether the grid is split by month.
  bool get byDate => this != LibraryAllSort.name;
}

/// The All tab's type chips.
enum LibraryAllType {
  /// Every kind (including kinds a newer build adds).
  all('All types', null),

  /// Videos.
  videos('Videos', {FileKind.video}),

  /// Photos.
  photos('Photos', {FileKind.photo}),

  /// Documents.
  documents('Documents', {FileKind.document}),

  /// Audio and other files.
  other('Other', {FileKind.audio, FileKind.other});

  const LibraryAllType(this.label, this.kinds);

  /// The chip label.
  final String label;

  /// The kinds shown, or null for every kind.
  final Set<FileKind>? kinds;
}

/// One list of the All tab: a sort and a type.
typedef LibraryAllKey = ({LibraryAllSort sort, LibraryAllType type});

/// The entries of the All tab for a sort and type (empty without a store). Newest of every type
/// is exactly the `All` filter list.
final libraryAllEntriesProvider = Provider.family<LibraryEntryPages, LibraryAllKey>((ref, key) {
  if (key.sort == LibraryAllSort.newest && key.type == LibraryAllType.all) {
    return ref.watch(libraryFilterEntriesProvider((filter: LibraryFilter.all, subFilter: null)));
  }
  final store = ref.watch(libraryStoreProvider);
  if (store == null) return LibraryEntryPages.empty();
  ref.watch(libraryRevisionProvider);
  return LibraryEntryPages(
    store.reader,
    EntryQuery(
      kinds: key.type.kinds,
      sort: key.sort == LibraryAllSort.name ? EntrySortKey.name : EntrySortKey.addedAt,
      descending: key.sort == LibraryAllSort.newest,
    ),
  );
});

/// The `All` tab.
class AllTab extends ConsumerStatefulWidget {
  /// The tab; [onOpenEntry] opens an entry in its viewer, [actions] add the card menus (the app
  /// passes the file actions; none by default).
  const AllTab({super.key, this.onOpenEntry, this.actions});

  /// Opens an entry.
  final LibraryEntryOpen? onOpenEntry;

  /// The card menus' actions (Open is always [onOpenEntry]).
  final LibraryEntryActions? actions;

  @override
  ConsumerState<AllTab> createState() => _AllTabState();
}

class _AllTabState extends ConsumerState<AllTab> {
  LibraryAllSort _sort = LibraryAllSort.newest;
  LibraryAllType _type = LibraryAllType.all;

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(libraryAllEntriesProvider((sort: _sort, type: _type)));
    final actions = widget.actions;
    final cardActions = LibraryEntryActions(
      onOpen: widget.onOpenEntry,
      onRename: actions?.onRename,
      onMove: actions?.onMove,
      onDelete: actions?.onDelete,
      onMore: actions?.onMore,
    );
    final chips = Semantics(
      container: true,
      label: 'Sort and type',
      child: DanaviewChipGroup(
        key: const ValueKey('library-all-chips'),
        children: [
          for (final sort in LibraryAllSort.values)
            DanaviewChoiceChip(
              key: ValueKey('library-all-sort-${sort.name}'),
              label: sort.label,
              icon: sort == _sort ? Icons.swap_vert_rounded : null,
              selected: sort == _sort,
              onTap: () => setState(() => _sort = sort),
            ),
          // A hairline-free gap between the sort and the type chips.
          const SizedBox(width: DanaviewSpacing.sm),
          for (final type in LibraryAllType.values)
            DanaviewChoiceChip(
              key: ValueKey('library-all-type-${type.name}'),
              label: type.label,
              selected: type == _type,
              onTap: () => setState(() => _type = type),
            ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = danaviewLibraryInsets(constraints.maxWidth);
        final padding = insets.copyWith(top: DanaviewSpacing.lg, bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl);
        final width = constraints.maxWidth - padding.horizontal;
        final columns = homeAdaptiveColumns(width);
        return CustomScrollView(
          key: const PageStorageKey('library-all-tab'),
          slivers: [
            SliverPadding(
              padding: padding.copyWith(bottom: DanaviewSpacing.md),
              sliver: SliverToBoxAdapter(child: chips),
            ),
            SliverPadding(
              padding: padding.copyWith(top: 0),
              sliver: entries.isEmpty
                  ? SliverToBoxAdapter(
                      child: _type == LibraryAllType.all
                          ? const LibraryFilterEmpty(filter: LibraryFilter.all)
                          : const DanaviewInlineEmpty(
                              icon: Icons.filter_alt_off_rounded,
                              title: 'Nothing of this type',
                              message: 'Pick another type to see more of your library.',
                            ),
                    )
                  : _grid(entries, columns, homeCardCellWidth(width, columns), cardActions),
            ),
          ],
        );
      },
    );
  }

  static Widget _card(LibraryEntryPages entries, int index, LibraryEntryActions actions) {
    final entry = index < 0 ? null : entries.at(index);
    return entry == null ? const SizedBox.shrink() : LibraryEntryCard(entry: entry, actions: actions);
  }

  /// The mixed grid, lazily in order: month headers between rows for the date sorts (a row never
  /// mixes two months), plain rows by name. Every card of a row has the same height.
  Widget _grid(LibraryEntryPages entries, int columns, double cell, LibraryEntryActions actions) {
    final rows = _MonthGridRows(entries, columns, byMonth: _sort.byDate);
    return SliverList.builder(
      key: ValueKey('library-all-grid-${_sort.name}-${_type.name}'),
      itemBuilder: (context, i) {
        final item = rows.item(i);
        if (item == null) return null;
        if (item.header case final month?) return DanaviewLibrarySectionHeader(month, topSpacing: i == 0 ? 0 : 20);
        final height = homeMediaCardExtent(cell, context);
        final row = SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var c = 0; c < columns; c++) ...[
                if (c > 0) const SizedBox(width: homeCardGridGap),
                Expanded(child: _card(entries, item.start + c < item.end ? item.start + c : -1, actions)),
              ],
            ],
          ),
        );
        final afterRow = i > 0 && rows.item(i - 1)?.header == null;
        return afterRow ? Padding(padding: const EdgeInsets.only(top: homeCardGridGap), child: row) : row;
      },
    );
  }
}

/// The All grid's items: a month header, or one row of entries [start, end) of that month.
typedef _MonthGridItem = ({String? header, int start, int end});

class _MonthGridRows {
  _MonthGridRows(this.entries, this.columns, {this.byMonth = true});

  final LibraryEntryPages entries;
  final int columns;

  /// Split by month (the date sorts); false makes plain rows.
  final bool byMonth;
  final List<_MonthGridItem> _items = [];
  int _next = 0;
  String? _month;

  String? _monthOf(int index) {
    if (!byMonth) return null;
    final entry = entries.at(index);
    return entry == null ? _month : libraryMonthLabel(entry.addedAt);
  }

  /// Item [index], or null past the end.
  _MonthGridItem? item(int index) {
    while (_items.length <= index && _next < entries.length) {
      final month = _monthOf(_next);
      if (byMonth && month != null && (_items.isEmpty || month != _month)) {
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
