// OWNER: CORE-03
//
// Text overlay style and animation (ARCH §6.6). Sizes are points at a 1,080 px canvas short side.
// Layout is done by Flutter (API-04 TextLayoutEngine) for preview, handles and export sprites.

import 'package:meta/meta.dart';

import '../time/time.dart';

const Object _keep = Object();

/// Horizontal alignment of text lines.
enum TextAlignH {
  /// Left-aligned (start in LTR).
  left,

  /// Centred.
  center,

  /// Right-aligned.
  right,
}

/// Background box behind text.
@immutable
final class BoxStyle {
  /// Creates a box style.
  const BoxStyle({this.color = 0xFF000000, this.opacity = 0.6, this.paddingPt = 12, this.cornerRadiusPt = 8});

  /// ARGB colour.
  final int color;

  /// Box opacity in [0, 1].
  final double opacity;

  /// Padding around the text block, in points.
  final double paddingPt;

  /// Corner radius in points.
  final double cornerRadiusPt;

  /// A copy with the given fields replaced.
  BoxStyle copyWith({int? color, double? opacity, double? paddingPt, double? cornerRadiusPt}) => BoxStyle(
        color: color ?? this.color,
        opacity: opacity ?? this.opacity,
        paddingPt: paddingPt ?? this.paddingPt,
        cornerRadiusPt: cornerRadiusPt ?? this.cornerRadiusPt,
      );

  @override
  bool operator ==(Object other) =>
      other is BoxStyle &&
      other.color == color &&
      other.opacity == opacity &&
      other.paddingPt == paddingPt &&
      other.cornerRadiusPt == cornerRadiusPt;

  @override
  int get hashCode => Object.hash(color, opacity, paddingPt, cornerRadiusPt);
}

/// Text outline.
@immutable
final class StrokeStyle {
  /// Creates a stroke.
  const StrokeStyle({this.color = 0xFF000000, this.widthPt = 2});

  /// ARGB colour.
  final int color;

  /// Width in points, [0, 20].
  final double widthPt;

  /// A copy with the given fields replaced.
  StrokeStyle copyWith({int? color, double? widthPt}) =>
      StrokeStyle(color: color ?? this.color, widthPt: widthPt ?? this.widthPt);

  @override
  bool operator ==(Object other) => other is StrokeStyle && other.color == color && other.widthPt == widthPt;

  @override
  int get hashCode => Object.hash(color, widthPt);
}

/// Drop shadow.
@immutable
final class ShadowStyle {
  /// Creates a shadow.
  const ShadowStyle({
    this.color = 0xFF000000,
    this.opacity = 0.5,
    this.blurPt = 6,
    this.distancePt = 3,
    this.angleDeg = 90,
  });

  /// ARGB colour.
  final int color;

  /// Shadow opacity in [0, 1].
  final double opacity;

  /// Blur radius in points, [0, 40].
  final double blurPt;

  /// Offset distance in points, [0, 40].
  final double distancePt;

  /// Offset direction in degrees (90 = straight down).
  final double angleDeg;

  /// A copy with the given fields replaced.
  ShadowStyle copyWith({int? color, double? opacity, double? blurPt, double? distancePt, double? angleDeg}) =>
      ShadowStyle(
        color: color ?? this.color,
        opacity: opacity ?? this.opacity,
        blurPt: blurPt ?? this.blurPt,
        distancePt: distancePt ?? this.distancePt,
        angleDeg: angleDeg ?? this.angleDeg,
      );

  @override
  bool operator ==(Object other) =>
      other is ShadowStyle &&
      other.color == color &&
      other.opacity == opacity &&
      other.blurPt == blurPt &&
      other.distancePt == distancePt &&
      other.angleDeg == angleDeg;

  @override
  int get hashCode => Object.hash(color, opacity, blurPt, distancePt, angleDeg);
}

/// Style of a text overlay.
@immutable
final class TextStyleSpec {
  /// Creates a style; the default is Figtree 48 pt white, centred.
  const TextStyleSpec({
    this.fontFamily = 'figtree',
    this.fontSizePt = 48,
    this.bold = false,
    this.italic = false,
    this.align = TextAlignH.center,
    this.color = 0xFFFFFFFF,
    this.letterSpacing = 0,
    this.lineHeight = 1.2,
    this.maxWidth = 0.9,
    this.background,
    this.stroke,
    this.shadow,
  });

  /// Content-font id from the curated set (D-30); unknown ids fall back to Figtree.
  final String fontFamily;

  /// Size in points at a 1,080 px short side, [8, 200].
  final double fontSizePt;

  /// Bold weight.
  final bool bold;

  /// Italic style.
  final bool italic;

  /// Line alignment.
  final TextAlignH align;

  /// ARGB text colour (alpha is the text opacity).
  final int color;

  /// Letter spacing in em/100, [-20, 100].
  final double letterSpacing;

  /// Line height multiplier, [0.6, 3].
  final double lineHeight;

  /// Wrap width as a fraction of the canvas width.
  final double maxWidth;

  /// Optional background box.
  final BoxStyle? background;

  /// Optional outline.
  final StrokeStyle? stroke;

  /// Optional drop shadow.
  final ShadowStyle? shadow;

  /// A copy with the given fields replaced; pass null to remove background/stroke/shadow.
  TextStyleSpec copyWith({
    String? fontFamily,
    double? fontSizePt,
    bool? bold,
    bool? italic,
    TextAlignH? align,
    int? color,
    double? letterSpacing,
    double? lineHeight,
    double? maxWidth,
    Object? background = _keep,
    Object? stroke = _keep,
    Object? shadow = _keep,
  }) =>
      TextStyleSpec(
        fontFamily: fontFamily ?? this.fontFamily,
        fontSizePt: fontSizePt ?? this.fontSizePt,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        align: align ?? this.align,
        color: color ?? this.color,
        letterSpacing: letterSpacing ?? this.letterSpacing,
        lineHeight: lineHeight ?? this.lineHeight,
        maxWidth: maxWidth ?? this.maxWidth,
        background: identical(background, _keep) ? this.background : background as BoxStyle?,
        stroke: identical(stroke, _keep) ? this.stroke : stroke as StrokeStyle?,
        shadow: identical(shadow, _keep) ? this.shadow : shadow as ShadowStyle?,
      );

  @override
  bool operator ==(Object other) =>
      other is TextStyleSpec &&
      other.fontFamily == fontFamily &&
      other.fontSizePt == fontSizePt &&
      other.bold == bold &&
      other.italic == italic &&
      other.align == align &&
      other.color == color &&
      other.letterSpacing == letterSpacing &&
      other.lineHeight == lineHeight &&
      other.maxWidth == maxWidth &&
      other.background == background &&
      other.stroke == stroke &&
      other.shadow == shadow;

  @override
  int get hashCode => Object.hash(fontFamily, fontSizePt, bold, italic, align, color, letterSpacing, lineHeight,
      maxWidth, background, stroke, shadow);
}

/// Kinds of text in/out animation. Typewriter is an "in" animation only.
enum TextAnimKind {
  /// No animation.
  none,

  /// Opacity 0 → 1.
  fade,

  /// Offset 10% of min(W, H) from a direction, plus fade.
  slide,

  /// Scale 0.6 → 1, plus fade.
  scale,

  /// Reveals `floor(n·p)` grapheme clusters (in only).
  typewriter,
}

/// Direction a sliding text comes from (in) or goes to (out).
enum TextSlideDirection {
  /// From/to the left.
  left,

  /// From/to the right.
  right,

  /// From/to the top.
  up,

  /// From/to the bottom.
  down,
}

/// In/out animation of a text item. Evaluated by the one shared `evaluateTextAnimation`
/// (CORE-07): ease-out cubic sampled at 6 linear segments; out mirrors in.
@immutable
final class TextAnimation {
  /// Creates an animation; the default is none.
  const TextAnimation({
    this.inKind = TextAnimKind.none,
    this.inDirection = TextSlideDirection.up,
    this.inDuration = 0,
    this.outKind = TextAnimKind.none,
    this.outDirection = TextSlideDirection.down,
    this.outDuration = 0,
  });

  /// No animation.
  static const TextAnimation none = TextAnimation();

  /// In animation kind.
  final TextAnimKind inKind;

  /// Slide direction for [inKind] == slide.
  final TextSlideDirection inDirection;

  /// In duration (on grid).
  final TimeUs inDuration;

  /// Out animation kind (never typewriter).
  final TextAnimKind outKind;

  /// Slide direction for [outKind] == slide.
  final TextSlideDirection outDirection;

  /// Out duration (on grid).
  final TimeUs outDuration;

  /// A copy with the given fields replaced.
  TextAnimation copyWith({
    TextAnimKind? inKind,
    TextSlideDirection? inDirection,
    TimeUs? inDuration,
    TextAnimKind? outKind,
    TextSlideDirection? outDirection,
    TimeUs? outDuration,
  }) =>
      TextAnimation(
        inKind: inKind ?? this.inKind,
        inDirection: inDirection ?? this.inDirection,
        inDuration: inDuration ?? this.inDuration,
        outKind: outKind ?? this.outKind,
        outDirection: outDirection ?? this.outDirection,
        outDuration: outDuration ?? this.outDuration,
      );

  @override
  bool operator ==(Object other) =>
      other is TextAnimation &&
      other.inKind == inKind &&
      other.inDirection == inDirection &&
      other.inDuration == inDuration &&
      other.outKind == outKind &&
      other.outDirection == outDirection &&
      other.outDuration == outDuration;

  @override
  int get hashCode => Object.hash(inKind, inDirection, inDuration, outKind, outDirection, outDuration);
}
