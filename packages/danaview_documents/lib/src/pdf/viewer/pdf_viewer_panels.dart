// OWNER: HOM-24
//
// The side / bottom panels of the PDF viewer (HOM plan §8.4): search with a result list, page
// thumbnails as a wrapping grid, and the outline. Kit components, Figtree, dark surfaces with
// hairlines, targets ≥ 44 px, scrollables clipped to the panel, the current page's ring drawn
// outside its clipped thumbnail. Snippets and outline titles are shown, never logged (rule 30).

import 'dart:async';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

/// The search state the viewer keeps.
enum PdfSearchStatus {
  /// No query.
  idle,

  /// A search runs.
  searching,

  /// Results are in.
  done,

  /// The search failed.
  failed,
}

/// Search: the field with previous / next right next to it, the result count and the result list.
class PdfSearchPanel extends StatelessWidget {
  /// A panel showing [hits].
  const PdfSearchPanel({
    super.key,
    required this.controller,
    required this.status,
    required this.hits,
    required this.truncated,
    required this.current,
    required this.onQuery,
    required this.onSelect,
    this.focusNode,
  });

  /// The query field's controller.
  final TextEditingController controller;

  /// The field's focus.
  final FocusNode? focusNode;

  /// Where the search is.
  final PdfSearchStatus status;

  /// The hits.
  final List<PdfSearchHit> hits;

  /// More hits exist.
  final bool truncated;

  /// The hit shown, or -1.
  final int current;

  /// A new query (debounced by the field).
  final ValueChanged<String> onQuery;

  /// Shows hit [index].
  final ValueChanged<int> onSelect;

  String get _summary => switch (status) {
        PdfSearchStatus.idle => 'Find text in this PDF',
        PdfSearchStatus.searching => 'Searching…',
        PdfSearchStatus.failed => 'Search isn\'t available for this file',
        PdfSearchStatus.done when hits.isEmpty => 'No matches',
        PdfSearchStatus.done => '${current >= 0 ? '${current + 1} of ' : ''}${hits.length}${truncated ? '+' : ''} '
            '${hits.length == 1 ? 'match' : 'matches'}',
      };

  @override
  Widget build(BuildContext context) {
    final canStep = hits.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DanaviewSpacing.md, DanaviewSpacing.sm, DanaviewSpacing.xs, DanaviewSpacing.xs),
          child: Row(
            children: [
              Expanded(
                child: DanaviewSearchField(
                  controller: controller,
                  focusNode: focusNode,
                  hint: 'Search in PDF',
                  semanticLabel: 'Search in PDF',
                  onChanged: onQuery,
                  onSubmitted: (_) {
                    if (canStep) onSelect(current < 0 ? 0 : (current + 1) % hits.length);
                  },
                ),
              ),
              const SizedBox(width: DanaviewSpacing.md),
              DanaviewIconButton(
                icon: Icons.keyboard_arrow_up_rounded,
                size: DanaviewSpacing.controlHeight,
                semanticLabel: 'Previous match',
                tooltip: 'Previous match',
                onPressed: canStep ? () => onSelect(current <= 0 ? hits.length - 1 : current - 1) : null,
              ),
              DanaviewIconButton(
                icon: Icons.keyboard_arrow_down_rounded,
                size: DanaviewSpacing.controlHeight,
                semanticLabel: 'Next match',
                tooltip: 'Next match',
                onPressed: canStep ? () => onSelect(current < 0 ? 0 : (current + 1) % hits.length) : null,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.xs),
          child: Semantics(
            liveRegion: true,
            child: Text(_summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.caption),
          ),
        ),
        Expanded(
          child: ClipRect(
            child: ListView.builder(
              key: const ValueKey('pdf-search-results'),
              padding: const EdgeInsets.only(bottom: DanaviewSpacing.sm),
              itemCount: hits.length,
              itemBuilder: (context, i) => _HitRow(hit: hits[i], selected: i == current, onTap: () => onSelect(i)),
            ),
          ),
        ),
      ],
    );
  }
}

class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit, required this.selected, required this.onTap});

  final PdfSearchHit hit;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final page = 'Page ${hit.pageIndex + 1}';
    return DanaviewPressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: '$page: ${hit.snippet.trim()}',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: ColoredBox(
            color: selected ? DanaviewColors.surfaceElevated : const Color(0x00000000),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(page, style: DanaviewTextStyles.caption),
                  const SizedBox(height: DanaviewSpacing.xxs),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: hit.before.trimLeft()),
                        TextSpan(text: hit.match, style: const TextStyle(fontWeight: FontWeight.w700, color: DanaviewColors.textPrimary)),
                        TextSpan(text: hit.after.trimRight()),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: DanaviewTextStyles.bodySecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Loads a page thumbnail.
typedef PdfThumbnailLoader = Future<PdfPageImage> Function(int pageIndex, int maxWidth, int maxHeight);

/// Page thumbnails as a wrapping grid; tapping one goes to it.
class PdfPagesPanel extends StatefulWidget {
  /// A grid of [pageCount] pages.
  const PdfPagesPanel({
    super.key,
    required this.pageCount,
    required this.pageSizes,
    required this.currentPage,
    required this.load,
    required this.onSelect,
  });

  /// Pages.
  final int pageCount;

  /// Page sizes (aspect ratios), when known.
  final List<PdfPageSize> pageSizes;

  /// The page on screen.
  final int currentPage;

  /// Renders a thumbnail.
  final PdfThumbnailLoader load;

  /// Goes to a page.
  final ValueChanged<int> onSelect;

  @override
  State<PdfPagesPanel> createState() => _PdfPagesPanelState();
}

class _PdfPagesPanelState extends State<PdfPagesPanel> {
  final Map<int, Future<PdfPageImage>> _cache = {};

  Future<PdfPageImage> _thumb(int page, int w, int h) => _cache.putIfAbsent(page, () => widget.load(page, w, h));

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, c) {
          const maxExtent = 132.0;
          final columns = (c.maxWidth / maxExtent).ceil().clamp(2, 12);
          final cell = (c.maxWidth - DanaviewSpacing.md * 2 - DanaviewSpacing.sm * (columns - 1)) / columns;
          final label = MediaQuery.textScalerOf(context).scale(12) * 1.4;
          return GridView.builder(
            key: const ValueKey('pdf-pages-grid'),
            padding: const EdgeInsets.all(DanaviewSpacing.md),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: DanaviewSpacing.sm,
              mainAxisSpacing: DanaviewSpacing.md,
              mainAxisExtent: cell * 1.3 + DanaviewSpacing.xs + label + 8,
            ),
            itemCount: widget.pageCount,
            itemBuilder: (context, i) {
              final px = (cell * dpr).round().clamp(48, 600);
              return _PageCell(
                index: i,
                selected: i == widget.currentPage,
                aspect: i < widget.pageSizes.length ? widget.pageSizes[i].aspectRatio : 0.77,
                image: _thumb(i, px, (px * 1.3).round()),
                onTap: () => widget.onSelect(i),
              );
            },
          );
        },
      ),
    );
  }
}

class _PageCell extends StatelessWidget {
  const _PageCell({required this.index, required this.selected, required this.aspect, required this.image, required this.onTap});

  final int index;
  final bool selected;
  final double aspect;
  final Future<PdfPageImage> image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final page = 'Page ${index + 1}';
    return DanaviewPressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: selected ? '$page, current page' : page,
      child: ExcludeSemantics(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: aspect.clamp(0.3, 3.0),
                  // The ring sits outside the clipped page image (4 px apart).
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: DanaviewRadius.smAll,
                      border: Border.all(color: selected ? DanaviewColors.primary : const Color(0x00000000), width: 2),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: ClipRRect(
                        borderRadius: DanaviewRadius.xsAll,
                        child: DecoratedBox(
                          decoration: const BoxDecoration(color: Color(0xFFFFFFFF)),
                          child: FutureBuilder<PdfPageImage>(
                            future: image,
                            builder: (context, snap) => snap.hasData
                                ? Image.memory(snap.data!.png, fit: BoxFit.contain, gaplessPlayback: true, excludeFromSemantics: true)
                                : const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: DanaviewSpacing.xs),
            Text(
              '${index + 1}',
              maxLines: 1,
              style: DanaviewTextStyles.caption.copyWith(color: selected ? DanaviewColors.textPrimary : DanaviewColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// The outline as an indented list.
class PdfOutlinePanel extends StatelessWidget {
  /// A list of [entries].
  const PdfOutlinePanel({super.key, required this.entries, required this.onSelect});

  /// The flattened outline.
  final List<PdfOutlineEntry> entries;

  /// Goes to a page.
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(
        child: DanaviewEmptyState(
            icon: Icons.toc_rounded, iconColor: DanaviewColors.textSecondary, title: 'No contents', message: 'This PDF has no outline.'),
      );
    }
    return ClipRect(
      child: ListView.builder(
        key: const ValueKey('pdf-outline'),
        padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xs),
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final e = entries[i];
          final title = e.title.trim().isEmpty ? 'Untitled' : e.title.trim();
          return Padding(
            padding: EdgeInsets.only(left: (e.depth.clamp(0, 6)) * DanaviewSpacing.lg),
            child: DanaviewListTile(
              title: title,
              titleMaxLines: 2,
              trailing: e.pageIndex >= 0 ? Text('${e.pageIndex + 1}', style: DanaviewTextStyles.caption) : null,
              enabled: e.pageIndex >= 0,
              semanticLabel: e.pageIndex >= 0 ? '$title, page ${e.pageIndex + 1}' : title,
              onTap: e.pageIndex >= 0 ? () => onSelect(e.pageIndex) : null,
            ),
          );
        },
      ),
    );
  }
}

/// Unawaited helper for fire-and-forget controller calls whose failures don't matter to the UI.
void pdfIgnore(Future<void> future) => unawaited(future.catchError((Object _) {}));
