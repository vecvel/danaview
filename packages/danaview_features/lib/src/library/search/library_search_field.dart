// OWNER: HOM-19
//
// The Home search field (HOM plan §8.1, D-98f / V2-119): as-you-type name search across Danaview
// folders, linked folders and (when shown) the system library, with the hits listed under the
// field. AIS-51 extends this file (index search, the "Search with AI" entry through an
// `onSearchWithAi` callback, ARCH rule 23). Kit components only; rows ≥ 44 px with semantics
// labels; no overflow at 280–1280 px and text scale 0.85–1.35 (test/v12/organise/). The widget
// takes no height of its own: hosts put it in their scroll view.

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../organise/organise_widgets.dart';
import 'name_search_controller.dart';

/// The search field and its hits.
class LibrarySearchField extends ConsumerStatefulWidget {
  /// A field; [onOpen] opens a hit (a Danaview file or folder, a linked file or folder, a system
  /// asset: the host routes by `hit.item.id` and `hit.item.origin`).
  const LibrarySearchField({
    super.key,
    required this.onOpen,
    this.hint = defaultHint,
    this.maxRows = 50,
    this.debounce = const Duration(milliseconds: 60),
  });

  /// The placeholder.
  static const String defaultHint = 'Search files and folders';

  /// Shown when nothing matches.
  static const String noMatches = 'No matches';

  /// Opens a hit.
  final ValueChanged<SearchHit> onOpen;

  /// The placeholder.
  final String hint;

  /// The most rows listed.
  final int maxRows;

  /// The keystroke debounce (the search itself is ≤ 50 ms over 50,000 names).
  final Duration debounce;

  @override
  ConsumerState<LibrarySearchField> createState() => _LibrarySearchFieldState();
}

class _LibrarySearchFieldState extends ConsumerState<LibrarySearchField> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(nameSearchControllerProvider);
    final controller = ref.read(nameSearchControllerProvider.notifier);
    final results = state.results;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DanaviewSearchField(
          key: const ValueKey('library-search-field'),
          controller: _text,
          hint: widget.hint,
          debounce: widget.debounce,
          semanticLabel: 'Search files and folders by name or type',
          onChanged: (text) => text.trim().isEmpty ? controller.clear() : controller.setQuery(text),
          onSubmitted: (text) => text.trim().isEmpty ? controller.clear() : controller.setQuery(text),
        ),
        if (state.active && results != null) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          if (results.hits.isEmpty)
            Semantics(
              liveRegion: true,
              child: Padding(
                key: const ValueKey('library-search-empty'),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: DanaviewSpacing.md),
                child: Text(LibrarySearchField.noMatches, style: DanaviewTextStyles.bodySecondary),
              ),
            )
          else ...[
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: DanaviewSpacing.xs),
                child: Text(
                  results.total == 1 ? '1 match' : '${results.total} matches',
                  key: const ValueKey('library-search-count'),
                  style: DanaviewTextStyles.caption,
                ),
              ),
            ),
            for (final hit in results.hits.take(widget.maxRows)) _HitRow(hit: hit, onTap: () => widget.onOpen(hit)),
          ],
        ],
      ],
    );
  }
}

class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit, required this.onTap});

  final SearchHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = hit.item;
    final kind = item.kind;
    final type = kind == null ? 'Folder' : organiseKindLabel(kind);
    final where = switch (item.origin) {
      SearchOrigin.danaview => item.folderName,
      SearchOrigin.linked => item.folderName == null ? 'Linked folder' : '${item.folderName} (linked)',
      SearchOrigin.system => 'Photos library',
    };
    final subtitle = where == null ? type : '$type · $where';
    return DanaviewListTile(
      key: ValueKey('library-search-hit-${item.id.value}'),
      title: item.name,
      subtitle: subtitle,
      leading: kind == null ? const DanaviewTileIcon.glyph(DanaviewGlyphKind.folder) : DanaviewTileIcon(organiseKindIcon(kind)),
      semanticLabel: '$type ${item.name}${where == null ? '' : ', in $where'}',
      onTap: onTap,
    );
  }
}
