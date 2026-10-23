// OWNER: HOM-13
//
// The badge overlay of a thumbnail (ARCH v1.2 V2-110, §1.4; BUILD_PLAN HOM-13): the indicator
// pills (Live, RAW, HDR, 4K/1080p, >= 50 fps) along the top-start edge and the duration pill at the
// bottom-end corner. Every pill sits on its own dark scrim whose opacity is chosen so the white
// text and icons keep a computed contrast of at least 4.5:1 over ANY thumbnail, from pure white to
// pure black (`mediaBadgeContrastOver`, tested over light and dark frames). Kit tokens and Figtree
// through the kit theme only; texts are one line with an ellipsis and narrow cells (< 120 px)
// show only the first indicator, so nothing overflows at 280–1280 px or text scale 0.85–1.35.

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';

import 'media_badges.dart';

/// The pill scrim: black at 72 % opacity. Over a pure white thumbnail it composites to #474747,
/// on which white text measures about 9:1; the floor that still gives 4.5:1 over white is about
/// 53 %, so the margin covers anti-aliasing and the thumbnail fade-in.
const Color mediaBadgeScrim = Color(0xB8000000);

/// The pill text and icon colour.
const Color mediaBadgeForeground = DanaviewColors.textPrimary;

/// The minimum contrast every badge keeps (ARCH §1.4).
const double mediaBadgeMinContrast = 4.5;

/// Below this cell width only the first indicator is shown (with the duration pill).
const double mediaBadgeCompactWidth = 120;

/// The contrast of the badge text over a pill composited on a [thumbnail] pixel (any colour; a
/// translucent pixel is first composited over black, the grid's empty-cell colour).
double mediaBadgeContrastOver(Color thumbnail) {
  final opaque = thumbnail.a >= 1.0 ? thumbnail : Color.alphaBlend(thumbnail, const Color(0xFF000000));
  final pill = Color.alphaBlend(mediaBadgeScrim, opaque);
  return DanaviewColors.contrastRatio(mediaBadgeForeground, pill);
}

/// The badges of one thumbnail, as a full-size overlay: put it last in the cell's [Stack] (it
/// fills the stack and positions its pills itself). Draws nothing for [MediaBadges.isEmpty].
class MediaBadgeOverlay extends StatelessWidget {
  /// The overlay of [badges]. [inset] is the distance of the pills from the cell edges.
  /// [excludeSemantics] drops the overlay's own label, for a cell that already speaks
  /// [MediaBadges.semanticsLabel] in its own label.
  const MediaBadgeOverlay({
    super.key,
    required this.badges,
    this.inset = 6,
    this.excludeSemantics = false,
  });

  /// What to show.
  final MediaBadges badges;

  /// Distance from the cell edges.
  final double inset;

  /// True when the enclosing cell already speaks the badges.
  final bool excludeSemantics;

  @override
  Widget build(BuildContext context) {
    if (badges.isEmpty) return const SizedBox.shrink();
    final duration = badges.durationLabel;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite ? constraints.maxWidth : mediaBadgeCompactWidth;
      final compact = width < mediaBadgeCompactWidth;
      final all = badges.labels;
      final shown = compact && all.length > 1 ? all.sublist(0, 1) : all;
      final pillMax = (width - 2 * inset).clamp(0.0, double.infinity);
      final overlay = Stack(fit: StackFit.expand, children: [
        if (shown.isNotEmpty)
          PositionedDirectional(
            top: inset,
            start: inset,
            end: inset,
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: Wrap(
                key: const ValueKey('media-badges-top'),
                spacing: 4,
                runSpacing: 4,
                children: [for (final l in shown) MediaBadgePill(label: l.label, kind: l.kind, maxWidth: pillMax)],
              ),
            ),
          ),
        if (duration != null)
          PositionedDirectional(
            bottom: inset,
            end: inset,
            child: MediaBadgePill(
              key: const ValueKey('media-badge-duration'),
              label: duration,
              maxWidth: pillMax,
            ),
          ),
      ]);
      if (excludeSemantics) return ExcludeSemantics(child: overlay);
      return Semantics(
        container: true,
        label: badges.semanticsLabel,
        child: ExcludeSemantics(child: overlay),
      );
    });
  }
}

/// One badge: [label] (and the Live icon for [MediaBadgeKind.live]) on the scrim.
class MediaBadgePill extends StatelessWidget {
  /// A pill no wider than [maxWidth].
  const MediaBadgePill({super.key, required this.label, this.kind, this.maxWidth = double.infinity});

  /// The text.
  final String label;

  /// The indicator kind; null for the duration pill.
  final MediaBadgeKind? kind;

  /// The widest the pill may be (the text ellipsises).
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final style = DanaviewTextStyles.micro.copyWith(
      color: mediaBadgeForeground,
      fontWeight: FontWeight.w700,
      height: 1.25,
      letterSpacing: kind == null ? 0 : 0.3,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final text = Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: style);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: DecoratedBox(
        decoration: const BoxDecoration(color: mediaBadgeScrim, borderRadius: DanaviewRadius.xsAll),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          child: kind == MediaBadgeKind.live
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.motion_photos_on_outlined, size: 11, color: mediaBadgeForeground),
                  const SizedBox(width: 3),
                  Flexible(child: text),
                ])
              : text,
        ),
      ),
    );
  }
}
