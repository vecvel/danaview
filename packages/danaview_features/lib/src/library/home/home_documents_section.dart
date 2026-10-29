// The Overview's Documents section (DESIGN_SYSTEM §10.3 #6, Files Home only): the newest
// Danaview documents as a grouped list (type tile, name, size), with See all opening the
// Documents tab. It draws nothing when there are no documents, so Home never shows an empty
// section.

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../filters/entry_widgets.dart';
import '../filters/filter_providers.dart';
import '../filters/library_filters.dart';
import '../library_widgets.dart';
import 'home_tabs.dart';

/// The Documents section of the Overview.
class HomeDocumentsSection extends ConsumerWidget {
  /// The section; [onOpenEntry] opens a document, [limit] rows at most.
  const HomeDocumentsSection({super.key, required this.onOpenEntry, this.limit = 5});

  /// Opens a document in its viewer.
  final LibraryEntryOpen onOpenEntry;

  /// How many documents are listed.
  final int limit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(libraryFilterEntriesProvider((filter: LibraryFilter.documents, subFilter: null)));
    if (entries.isEmpty) return const SizedBox.shrink(key: ValueKey('home-documents-hidden'));
    final shown = [
      for (var i = 0; i < entries.length && i < limit; i++)
        if (entries.at(i) case final entry?) entry,
    ];
    return Column(
      key: const ValueKey('home-documents'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DanaviewLibrarySectionHeader(
          'Documents',
          prominent: true,
          action: DanaviewButton.text(
            key: const ValueKey('home-documents-see-all'),
            label: 'See all',
            size: DanaviewButtonSize.sm,
            onPressed: () => const HomeTabRequestNotification(HomeTab.documents).dispatch(context),
          ),
        ),
        DanaviewLibraryGroup(
          children: [
            for (final entry in shown) LibraryEntryRow(entry: entry, actions: LibraryEntryActions(onOpen: onOpenEntry)),
          ],
        ),
      ],
    );
  }
}
