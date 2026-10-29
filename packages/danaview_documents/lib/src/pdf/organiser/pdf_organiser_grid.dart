// OWNER: HOM-28
//
// The page organiser's thumbnail grid (HOM plan §8.5, DESIGN_SYSTEM §3/§4/§12): a wrapping grid of
// page thumbnails from the viewer's thumbnail API, each in a white page clipped to
// DanaviewRadius.thumb with its extra rotation shown, a check mark and a selection ring drawn
// outside the clipped page (never clipped by the cell). Tap selects; drag reorders (long press on
// touch, a plain drag with a pointer), the grid scrolling itself near its edges; screen readers and
// keyboards get "Move earlier", "Move later" and "Rotate" as custom actions. No hover or press
// tints. The grid is clipped to its panel.

import 'dart:async';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import '../viewer/pdf_viewer_panels.dart' show PdfThumbnailLoader;
import 'pdf_organiser_model.dart';

/// The grid aims at cells about this wide.
const double pdfOrganiserCellExtent = 148;

/// The organiser grid over [model].
class PdfOrganiserGrid extends StatefulWidget {
  /// A grid of [model]'s pages; [pageSizes] gives their shapes, [load] renders thumbnails.
  const PdfOrganiserGrid({super.key, required this.model, required this.pageSizes, required this.load, this.dragEnabled = true});

  /// Pages, order, rotation and selection.
  final PdfOrganiserModel model;

  /// One size per source page (aspect ratios), when known.
  final List<PdfPageSize> pageSizes;

  /// Renders a source page's thumbnail.
  final PdfThumbnailLoader load;

  /// Drag-and-drop reordering (off while a tool runs).
  final bool dragEnabled;

  @override
  State<PdfOrganiserGrid> createState() => _PdfOrganiserGridState();
}

class _PdfOrganiserGridState extends State<PdfOrganiserGrid> {
  final Map<int, Future<PdfPageImage>> _thumbs = {};
  final ScrollController _scroll = ScrollController();
  final GlobalKey _viewport = GlobalKey();
  int? _dragging;
  Offset? _pointer;
  Timer? _autoScroll;

  Future<PdfPageImage> _thumb(int page, int w, int h) => _thumbs.putIfAbsent(page, () => widget.load(page, w, h));

  @override
  void dispose() {
    _autoScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _startDrag(int sourcePage) {
    setState(() => _dragging = sourcePage);
    _autoScroll?.cancel();
    _autoScroll = Timer.periodic(const Duration(milliseconds: 16), (_) => _edgeScroll());
  }

  void _endDrag() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _pointer = null;
    if (mounted) setState(() => _dragging = null);
  }

  /// Scrolls while the dragged page is held near the top or bottom edge.
  void _edgeScroll() {
    final pointer = _pointer;
    final box = _viewport.currentContext?.findRenderObject();
    if (pointer == null || box is! RenderBox || !box.hasSize || !_scroll.hasClients) return;
    final local = box.globalToLocal(pointer);
    const edge = 56.0;
    double delta = 0;
    if (local.dy < edge) delta = -(edge - local.dy) / 4;
    if (local.dy > box.size.height - edge) delta = (local.dy - (box.size.height - edge)) / 4;
    if (delta == 0) return;
    final position = _scroll.position;
    final next = (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent);
    if (next != position.pixels) _scroll.jumpTo(next);
  }

  void _hoverOver(int dragged, int target) {
    if (dragged == target) return;
    final from = widget.model.indexOf(dragged);
    final to = widget.model.indexOf(target);
    if (from >= 0 && to >= 0) widget.model.move(from, to);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final touch = context.isTouchPlatform;
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) => ClipRect(
        child: LayoutBuilder(
          key: _viewport,
          builder: (context, c) {
            final gutter = DanaviewSpacing.pageGutter(c.maxWidth);
            final inner = c.maxWidth - gutter * 2;
            final columns = (inner / pdfOrganiserCellExtent).floor().clamp(2, 12);
            const gap = DanaviewSpacing.md;
            final cell = (inner - gap * (columns - 1)) / columns;
            final label = MediaQuery.textScalerOf(context).scale(13) * 1.3;
            final pages = widget.model.pages;
            return Listener(
              onPointerMove: (e) => _pointer = e.position,
              child: GridView.builder(
                key: const ValueKey('pdf-organiser-grid'),
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(gutter, DanaviewSpacing.lg, gutter, DanaviewSpacing.xl),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: gap,
                  mainAxisSpacing: DanaviewSpacing.lg,
                  mainAxisExtent: cell * 1.32 + DanaviewSpacing.xs + label,
                ),
                itemCount: pages.length,
                itemBuilder: (context, i) {
                  final page = pages[i];
                  final px = (cell * dpr).round().clamp(64, 640);
                  final size = page.sourcePage < widget.pageSizes.length ? widget.pageSizes[page.sourcePage] : null;
                  final cellWidget = _PageCell(
                    key: ValueKey('pdf-organiser-page-${page.sourcePage}'),
                    position: i,
                    count: pages.length,
                    page: page,
                    aspect: size?.aspectRatio ?? 0.77,
                    selected: widget.model.isSelected(page.sourcePage),
                    dragging: _dragging == page.sourcePage,
                    image: _thumb(page.sourcePage, px, (px * 1.32).round()),
                    onTap: () => widget.model.toggle(page.sourcePage),
                    onMoveEarlier: i > 0 ? () => widget.model.move(i, i - 1) : null,
                    onMoveLater: i < pages.length - 1 ? () => widget.model.move(i, i + 1) : null,
                    onRotate: () => widget.model.rotate(only: page.sourcePage),
                  );
                  if (!widget.dragEnabled) return cellWidget;
                  final feedback = SizedBox(
                    width: cell,
                    height: cell * 1.32,
                    child: Opacity(opacity: 0.85, child: _PageImage(page: page, aspect: size?.aspectRatio ?? 0.77, image: _thumb(page.sourcePage, px, (px * 1.32).round()))),
                  );
                  final dragged = touch
                      ? LongPressDraggable<int>(
                          data: page.sourcePage,
                          feedback: feedback,
                          childWhenDragging: cellWidget,
                          onDragStarted: () => _startDrag(page.sourcePage),
                          onDragEnd: (_) => _endDrag(),
                          onDraggableCanceled: (_, __) => _endDrag(),
                          child: cellWidget,
                        )
                      : Draggable<int>(
                          data: page.sourcePage,
                          feedback: feedback,
                          childWhenDragging: cellWidget,
                          onDragStarted: () => _startDrag(page.sourcePage),
                          onDragEnd: (_) => _endDrag(),
                          onDraggableCanceled: (_, __) => _endDrag(),
                          child: cellWidget,
                        );
                  return DragTarget<int>(
                    onWillAcceptWithDetails: (d) {
                      _hoverOver(d.data, page.sourcePage);
                      return true;
                    },
                    builder: (context, _, __) => dragged,
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Space between a page and its selection ring, and the ring's width: the ring is drawn outside
/// the clipped page, so its corners are never cut.
const double _ringGap = 4;
const double _ringWidth = 2;

/// The white page with its thumbnail, turned by the page's extra rotation; [selected] adds the
/// ring around it and fills the check mark (null: no mark, the drag feedback).
class _PageImage extends StatelessWidget {
  const _PageImage({required this.page, required this.aspect, required this.image, this.selected});

  final PdfPagePlan page;
  final double aspect;
  final Future<PdfPageImage> image;
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final quarter = page.rotation ~/ 90;
    final shown = quarter.isOdd ? 1 / aspect : aspect;
    final ring = selected ?? false;
    return Center(
      child: AspectRatio(
        aspectRatio: shown.clamp(0.3, 3.0),
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            DanaviewDepth.clip(
              borderRadius: DanaviewRadius.thumbAll,
              child: ColoredBox(
                color: const Color(0xFFFFFFFF),
                child: RotatedBox(
                  quarterTurns: quarter,
                  child: FutureBuilder<PdfPageImage>(
                    future: image,
                    builder: (context, snap) => snap.hasData
                        ? Image.memory(snap.data!.png, fit: BoxFit.contain, gaplessPlayback: true, excludeFromSemantics: true)
                        : const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            if (ring)
              const Positioned(
                left: -(_ringGap + _ringWidth),
                top: -(_ringGap + _ringWidth),
                right: -(_ringGap + _ringWidth),
                bottom: -(_ringGap + _ringWidth),
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.all(Radius.circular(DanaviewRadius.thumb + _ringGap + _ringWidth)),
                        side: BorderSide(color: DanaviewColors.primary, width: _ringWidth),
                      ),
                    ),
                  ),
                ),
              ),
            if (selected != null) Positioned(top: 6, right: 6, child: _CheckMark(selected: ring)),
          ],
        ),
      ),
    );
  }
}

class _PageCell extends StatelessWidget {
  const _PageCell({
    super.key,
    required this.position,
    required this.count,
    required this.page,
    required this.aspect,
    required this.selected,
    required this.dragging,
    required this.image,
    required this.onTap,
    required this.onMoveEarlier,
    required this.onMoveLater,
    required this.onRotate,
  });

  final int position;
  final int count;
  final PdfPagePlan page;
  final double aspect;
  final bool selected;
  final bool dragging;
  final Future<PdfPageImage> image;
  final VoidCallback onTap;
  final VoidCallback? onMoveEarlier;
  final VoidCallback? onMoveLater;
  final VoidCallback onRotate;

  String get _label {
    final parts = ['Page ${position + 1} of $count'];
    if (page.sourcePage != position) parts.add('originally page ${page.sourcePage + 1}');
    if (page.rotation != 0) parts.add('turned ${page.rotation} degrees');
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    return DanaviewPressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: _label,
      // Merged into the pressable's node, next to its label and tap.
      child: Semantics(
        customSemanticsActions: {
          if (onMoveEarlier != null) const CustomSemanticsAction(label: 'Move earlier'): onMoveEarlier!,
          if (onMoveLater != null) const CustomSemanticsAction(label: 'Move later'): onMoveLater!,
          const CustomSemanticsAction(label: 'Rotate'): onRotate,
        },
        child: ExcludeSemantics(
          child: Opacity(
            opacity: dragging ? 0.35 : 1,
            child: Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(_ringGap + _ringWidth),
                    child: _PageImage(page: page, aspect: aspect, image: image, selected: selected),
                  ),
                ),
                const SizedBox(height: DanaviewSpacing.xs),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        '${position + 1}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DanaviewTextStyles.caption.copyWith(color: selected ? DanaviewColors.textPrimary : DanaviewColors.textSecondary),
                      ),
                    ),
                    if (page.rotation != 0) ...[
                      const SizedBox(width: DanaviewSpacing.xs),
                      const Icon(Icons.rotate_right_rounded, size: 14, color: DanaviewColors.textSecondary),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckMark extends StatelessWidget {
  const _CheckMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? DanaviewColors.primary : DanaviewColors.scrim,
          border: Border.all(color: DanaviewColors.textPrimary, width: 1.5),
        ),
        child: selected ? const Icon(Icons.check_rounded, size: 14, color: DanaviewColors.onPrimary) : null,
      );
}
