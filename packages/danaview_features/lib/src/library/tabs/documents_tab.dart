// OWNER: HOM-18
//
// The `Documents` filter tab (ARCH v1.2 V2-114; HOM plan §5.2, §8.1, D-98a): sub-filter chips
// (`All documents`, `PDF`, `Word`, `Excel`, `PowerPoint`, `Text/CSV`, `Other`) over the Danaview
// folder documents (type icon or first-page thumbnail, name, size, date, page count where known)
// and the documents of the user's linked folders, which are read-only: they open, and nothing
// renames, moves or deletes them (§8.1). DESIGN_SYSTEM §10.4: a grouped list on phones (one card,
// inset dividers), a 2-up grid of row cards on tablets and wider.
//
// Slice S2 hides this tab: [documentsFilterShown] (filters/library_filters.dart) is false, so
// [libraryFilterTabSlots] never hands this body to the Home. It is built and tested now so S3
// only flips the switch.

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../filters/entry_widgets.dart';
import '../filters/filter_providers.dart';
import '../filters/library_filters.dart';
import '../library_widgets.dart';
import 'all_tab.dart' show LibraryFilterEmpty;

/// The Documents tab's columns for a content [width] (§10.4): 1 (a grouped list) on phones, 2 from
/// the library grid's tablet width; never more.
int documentsTabColumns(double width) => danaviewLibraryGridColumns(width) > 1 ? 2 : 1;

/// The `Documents` tab.
class DocumentsTab extends ConsumerStatefulWidget {
  /// The tab; [onOpenEntry] opens a Danaview document, [onOpenLinked] a linked-folder document,
  /// [actions] add the Danaview rows' menus.
  const DocumentsTab({super.key, this.onOpenEntry, this.onOpenLinked, this.actions});

  /// Opens a Danaview document.
  final LibraryEntryOpen? onOpenEntry;

  /// Opens a linked-folder document.
  final LinkedDocumentOpen? onOpenLinked;

  /// The Danaview rows' menu actions (Open is always [onOpenEntry]).
  final LibraryEntryActions? actions;

  @override
  ConsumerState<DocumentsTab> createState() => _DocumentsTabState();
}

class _DocumentsTabState extends ConsumerState<DocumentsTab> {
  DocumentKind? _sub;

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(libraryFilterEntriesProvider((filter: LibraryFilter.documents, subFilter: _sub)));
    final linked = [
      for (final d in ref.watch(linkedDocumentsProvider))
        if (_sub == null || d.docKind == _sub) d,
    ];
    final rowActions = LibraryEntryActions(
      onOpen: widget.onOpenEntry,
      onRename: widget.actions?.onRename,
      onMove: widget.actions?.onMove,
      onDelete: widget.actions?.onDelete,
      onMore: widget.actions?.onMore,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = danaviewLibraryInsets(constraints.maxWidth);
        final padding = insets.copyWith(top: DanaviewSpacing.lg, bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl);
        final side = padding.copyWith(top: 0, bottom: 0);
        final columns = documentsTabColumns(constraints.maxWidth - side.horizontal);
        return CustomScrollView(
          key: const PageStorageKey('library-documents-tab'),
          slivers: [
            SliverPadding(
              padding: padding.copyWith(bottom: DanaviewSpacing.md),
              sliver: SliverToBoxAdapter(
                child: Semantics(
                  container: true,
                  label: 'Document types',
                  child: DanaviewChipGroup(
                    key: const ValueKey('documents-sub-filters'),
                    children: [
                      for (final sub in documentSubFilters)
                        DanaviewChoiceChip(
                          key: ValueKey('documents-sub-${sub?.code ?? 'all'}'),
                          label: documentSubFilterLabel(sub),
                          selected: _sub == sub,
                          onTap: () => setState(() => _sub = sub),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (entries.isEmpty && linked.isEmpty)
              SliverPadding(padding: side, sliver: const SliverToBoxAdapter(child: LibraryFilterEmpty(filter: LibraryFilter.documents))),
            if (entries.length > 0)
              SliverPadding(
                padding: side,
                sliver: _list(
                  columns,
                  entries.length,
                  (context, i) {
                    final entry = entries.at(i);
                    if (entry == null) return const SizedBox(height: 56);
                    return LibraryEntryRow(entry: entry, actions: rowActions);
                  },
                ),
              ),
            if (linked.isNotEmpty) ...[
              SliverPadding(padding: side, sliver: const SliverToBoxAdapter(child: DanaviewLibrarySectionHeader('In linked folders'))),
              SliverPadding(
                padding: side,
                sliver: _list(
                  columns,
                  linked.length,
                  (context, i) => LinkedDocumentRow(document: linked[i], onOpen: widget.onOpenLinked),
                ),
              ),
            ],
            SliverToBoxAdapter(child: SizedBox(height: padding.bottom)),
          ],
        );
      },
    );
  }

  /// A grouped list on phones, a 2-up grid where two columns fit.
  static Widget _list(int columns, int count, IndexedWidgetBuilder builder) => columns > 1
      ? danaviewLibrarySliverGrid(columns: columns, itemCount: count, itemBuilder: builder)
      : danaviewLibrarySliverGroup(itemCount: count, itemBuilder: builder);
}
