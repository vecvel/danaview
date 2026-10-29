// The Home's media cards (DESIGN_SYSTEM §8 "Media card", §10.3 #1): Continue watching as a
// horizontal row of 16:9 cards, and the same cards as a grid once expanded with Show all.
//
// A card is a `surface` card, radius 14, padding 5, holding a 16:9 thumbnail at radius 10 with a
// play disc, an optional episode badge, a duration badge and a 3 pt progress bar; under it a
// one-line title, a footnote line and the item's menu. Cards in a row share one height.

import 'dart:math' as math;

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';

/// One media card.
class HomeMediaCard extends StatelessWidget {
  /// A card for [title]; the fields mirror the 1.1 Continue watching row.
  const HomeMediaCard({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.badge,
    this.duration,
    this.progress,
    this.dimmed = false,
    this.onTap,
    this.trailing,
    this.semanticLabel,
  });

  /// The media title (one line).
  final String title;

  /// The type glyph drawn on the neutral placeholder (§2.5).
  final IconData icon;

  /// The footnote line (time left, host, length, or "File not found").
  final String? subtitle;

  /// The episode label (`S01E02`), drawn on the thumbnail's top corner.
  final String? badge;

  /// The length label on the thumbnail (`52:00`), or null.
  final String? duration;

  /// Watched fraction (0–1); no bar at 0 or null.
  final double? progress;

  /// A missing file: the thumbnail fades and the footnote takes the error colour.
  final bool dimmed;

  /// Plays the item.
  final VoidCallback? onTap;

  /// The item's menu button, beside the title.
  final Widget? trailing;

  /// Overrides the merged semantics of the card's text.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final showProgress = (progress ?? 0) > 0;
    final thumbnail = AspectRatio(
      aspectRatio: 16 / 9,
      child: DanaviewDepth.clip(
        borderRadius: DanaviewRadius.thumbAll,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Opacity(
              opacity: dimmed ? 0.45 : 1,
              child: ColoredBox(
                color: DanaviewColors.mediaPlaceholder,
                child: Center(child: Icon(icon, size: 20, color: DanaviewColors.textSecondary)),
              ),
            ),
            if (!dimmed)
              Center(
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(color: Color(0x73000000), shape: BoxShape.circle),
                  child: const Icon(Icons.play_arrow_rounded, size: 18, color: DanaviewColors.textPrimary),
                ),
              ),
            if (badge case final badge?) PositionedDirectional(top: 6, start: 6, child: _ThumbLabel(badge)),
            if (duration case final duration?)
              PositionedDirectional(bottom: showProgress ? 13 : 6, end: 6, child: _ThumbLabel(duration)),
            if (showProgress)
              PositionedDirectional(
                start: 6,
                end: 6,
                bottom: 6,
                child: _ThumbProgress(progress: progress!.clamp(0.0, 1.0)),
              ),
          ],
        ),
      ),
    );
    final text = Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 6, 0, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DanaviewTextStyles.subhead.copyWith(
                    fontWeight: FontWeight.w500,
                    height: 20 / 15,
                    color: dimmed ? DanaviewColors.textSecondary : DanaviewColors.textPrimary,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DanaviewTextStyles.footnote.copyWith(
                      height: 16 / 13,
                      color: dimmed ? DanaviewColors.errorLight : DanaviewColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
    return DanaviewPressable.builder(
      onTap: onTap,
      semanticLabel: semanticLabel,
      isButton: onTap != null,
      builder: (context, state) => Container(
        padding: const EdgeInsets.all(5),
        decoration: DanaviewDepth.card(borderRadius: DanaviewRadius.mediaAll),
        // Keyboard focus only; drawn on the card's own edge so a row never clips it.
        foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused, borderRadius: DanaviewRadius.mediaAll),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [thumbnail, text],
        ),
      ),
    );
  }
}

/// A duration or episode label on a thumbnail: black 55 %, radius 5.
class _ThumbLabel extends StatelessWidget {
  const _ThumbLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: const ShapeDecoration(
          color: Color(0x8C000000),
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(5))),
        ),
        child: Text(text, maxLines: 1, style: DanaviewTextStyles.captionStrong.copyWith(fontSize: 11, height: 1.3)),
      );
}

/// The 3 pt progress bar on a thumbnail: `primary` on white 18 %.
class _ThumbProgress extends StatelessWidget {
  const _ThumbProgress({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '${(progress * 100).round()}% watched',
        child: Container(
          height: 3,
          decoration: BoxDecoration(color: DanaviewColors.trackBackground, borderRadius: BorderRadius.circular(2)),
          alignment: AlignmentDirectional.centerStart,
          child: FractionallySizedBox(
            widthFactor: progress,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(color: DanaviewColors.primary, borderRadius: BorderRadius.circular(2)),
            ),
          ),
        ),
      );
}

/// The gap between media cards (§5 grid gap).
const double homeMediaCardGap = 10;

/// The width of a card in a horizontal row [width] wide: as many whole cards of at least 250 pt
/// as fit, plus a peek of the next one, so the row reads as scrollable.
double homeMediaCardWidth(double width) {
  if (!width.isFinite || width <= 0) return 240;
  final whole = math.max(1, (width / 250).floor());
  return (width - homeMediaCardGap * whole) / (whole + 0.4);
}

/// How many columns the expanded (Show all) grid uses in [width]: cards of at least 160 pt.
int homeMediaGridColumns(double width) => math.max(1, ((width + homeMediaCardGap) / (160 + homeMediaCardGap)).floor());

/// Continue watching collapsed: one horizontal, scrollable row of equal-height cards. The row is
/// clipped to its column at the sides (it never paints under a neighbouring column) but not above
/// or below, so a card's focus ring is never cut.
class HomeMediaCardRow extends StatelessWidget {
  /// A row of [children] (usually [HomeMediaCard]s).
  const HomeMediaCardRow({super.key, required this.children});

  /// The cards.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = homeMediaCardWidth(constraints.maxWidth);
        return ClipRect(
          clipper: const _SidesClipper(),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(width: homeMediaCardGap),
                    SizedBox(width: cardWidth, child: children[i]),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Clips at the left and right edges only, with room above and below for focus rings.
class _SidesClipper extends CustomClipper<Rect> {
  const _SidesClipper();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, -DanaviewSpacing.sm, size.width, size.height + DanaviewSpacing.sm);

  @override
  bool shouldReclip(_SidesClipper oldClipper) => false;
}

/// Continue watching expanded: the cards as a grid, each row of equal height.
class HomeMediaCardGrid extends StatelessWidget {
  /// A grid of [children].
  const HomeMediaCardGrid({super.key, required this.children});

  /// The cards.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = homeMediaGridColumns(constraints.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var start = 0; start < children.length; start += columns) ...[
              if (start > 0) const SizedBox(height: homeMediaCardGap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < columns; i++) ...[
                      if (i > 0) const SizedBox(width: homeMediaCardGap),
                      Expanded(child: start + i < children.length ? children[start + i] : const SizedBox.shrink()),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
