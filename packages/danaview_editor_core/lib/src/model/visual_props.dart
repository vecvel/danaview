// OWNER: CORE-03
//
// Visual properties of clips on video and overlay lanes (ARCH §6.5). All canvas-space values are
// normalized so changing the canvas never rewrites items.

import 'package:meta/meta.dart';

import '../ids/ids.dart';

const Object _keep = Object();

/// A 2-D vector of doubles (canvas fractions or item-local normalized units, by context).
@immutable
final class Vec2 {
  /// Creates `(x, y)`.
  const Vec2(this.x, this.y);

  /// `(0, 0)`.
  static const Vec2 zero = Vec2(0, 0);

  /// Horizontal component.
  final double x;

  /// Vertical component (y grows downward).
  final double y;

  /// A copy with the given components replaced.
  Vec2 copyWith({double? x, double? y}) => Vec2(x ?? this.x, y ?? this.y);

  @override
  bool operator ==(Object other) => other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Vec2($x, $y)';
}

/// Placement of an item on the canvas.
///
/// [position] is in canvas fractions with `(0, 0)` at the canvas centre, range [-2, 2];
/// [scale] in [0.01, 8] where 1 means the fit base size; [rotationDeg] in [-360, 360] clockwise;
/// [opacity] in [0, 1]. Text items ignore the flips.
@immutable
final class Transform2D {
  /// Creates a transform; defaults are the identity placement.
  const Transform2D({
    this.position = Vec2.zero,
    this.scale = 1,
    this.rotationDeg = 0,
    this.flipH = false,
    this.flipV = false,
    this.opacity = 1,
  });

  /// The identity placement (centred, scale 1, no rotation, opaque).
  static const Transform2D identity = Transform2D();

  /// Centre offset in canvas fractions (0 = centre).
  final Vec2 position;

  /// Uniform scale relative to the fit base size.
  final double scale;

  /// Clockwise rotation in degrees (y-down canvas).
  final double rotationDeg;

  /// Horizontal mirror.
  final bool flipH;

  /// Vertical mirror.
  final bool flipV;

  /// Layer opacity in [0, 1].
  final double opacity;

  /// A copy with the given fields replaced.
  Transform2D copyWith({
    Vec2? position,
    double? scale,
    double? rotationDeg,
    bool? flipH,
    bool? flipV,
    double? opacity,
  }) =>
      Transform2D(
        position: position ?? this.position,
        scale: scale ?? this.scale,
        rotationDeg: rotationDeg ?? this.rotationDeg,
        flipH: flipH ?? this.flipH,
        flipV: flipV ?? this.flipV,
        opacity: opacity ?? this.opacity,
      );

  @override
  bool operator ==(Object other) =>
      other is Transform2D &&
      other.position == position &&
      other.scale == scale &&
      other.rotationDeg == rotationDeg &&
      other.flipH == flipH &&
      other.flipV == flipV &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(position, scale, rotationDeg, flipH, flipV, opacity);
}

/// How the (cropped) source maps onto the canvas before the transform.
enum FitMode {
  /// Letterbox inside the canvas (default for the main lane).
  fit,

  /// Cover the canvas, cropping the overflow.
  fill,

  /// Stretch to the canvas aspect ratio.
  stretch,
}

/// A crop rectangle in normalized, display-oriented source coordinates (left, top, right,
/// bottom in [0, 1], right > left, bottom > top).
@immutable
final class CropRect {
  /// Creates a crop; the default is the full source.
  const CropRect({this.left = 0, this.top = 0, this.right = 1, this.bottom = 1});

  /// The full source (no crop).
  static const CropRect full = CropRect();

  /// Left edge.
  final double left;

  /// Top edge.
  final double top;

  /// Right edge.
  final double right;

  /// Bottom edge.
  final double bottom;

  /// Whether this crop keeps the whole source.
  bool get isFull => left == 0 && top == 0 && right == 1 && bottom == 1;

  /// A copy with the given edges replaced.
  CropRect copyWith({double? left, double? top, double? right, double? bottom}) => CropRect(
        left: left ?? this.left,
        top: top ?? this.top,
        right: right ?? this.right,
        bottom: bottom ?? this.bottom,
      );

  @override
  bool operator ==(Object other) =>
      other is CropRect && other.left == left && other.top == top && other.right == right && other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// Colour adjustments shared by "Video Effects" and "Color & LUT" (ARCH §6.5). Each value is in
/// [-1, 1] with 0 neutral; the UI shows ×100. Render math: ARCH §11.6.
@immutable
final class ColorAdjust {
  /// Creates an adjustment; the default is neutral.
  const ColorAdjust({
    this.exposure = 0,
    this.brightness = 0,
    this.contrast = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.saturation = 0,
    this.temperature = 0,
    this.tint = 0,
  });

  /// All zeros.
  static const ColorAdjust neutral = ColorAdjust();

  /// ±2 EV at the extremes.
  final double exposure;

  /// Additive brightness.
  final double brightness;

  /// Contrast around mid grey.
  final double contrast;

  /// Highlights lift/cut.
  final double highlights;

  /// Shadows lift/cut.
  final double shadows;

  /// Saturation (−1 = monochrome).
  final double saturation;

  /// Warm (+) / cool (−).
  final double temperature;

  /// Magenta (+) / green (−).
  final double tint;

  /// Whether every value is zero.
  bool get isNeutral => this == neutral;

  /// A copy with the given values replaced.
  ColorAdjust copyWith({
    double? exposure,
    double? brightness,
    double? contrast,
    double? highlights,
    double? shadows,
    double? saturation,
    double? temperature,
    double? tint,
  }) =>
      ColorAdjust(
        exposure: exposure ?? this.exposure,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        highlights: highlights ?? this.highlights,
        shadows: shadows ?? this.shadows,
        saturation: saturation ?? this.saturation,
        temperature: temperature ?? this.temperature,
        tint: tint ?? this.tint,
      );

  @override
  bool operator ==(Object other) =>
      other is ColorAdjust &&
      other.exposure == exposure &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.highlights == highlights &&
      other.shadows == shadows &&
      other.saturation == saturation &&
      other.temperature == temperature &&
      other.tint == tint;

  @override
  int get hashCode =>
      Object.hash(exposure, brightness, contrast, highlights, shadows, saturation, temperature, tint);
}

/// Detail effects, each in [0, 1] with 0 off.
@immutable
final class DetailFx {
  /// Creates detail effects; the default is off.
  const DetailFx({this.sharpness = 0, this.blur = 0, this.vignette = 0});

  /// All off.
  static const DetailFx none = DetailFx();

  /// Unsharp-mask amount.
  final double sharpness;

  /// Gaussian blur amount (σ = blur·0.03·min(W,H) canvas px, ARCH §11.6).
  final double blur;

  /// Vignette strength.
  final double vignette;

  /// A copy with the given values replaced.
  DetailFx copyWith({double? sharpness, double? blur, double? vignette}) => DetailFx(
        sharpness: sharpness ?? this.sharpness,
        blur: blur ?? this.blur,
        vignette: vignette ?? this.vignette,
      );

  @override
  bool operator ==(Object other) =>
      other is DetailFx && other.sharpness == sharpness && other.blur == blur && other.vignette == vignette;

  @override
  int get hashCode => Object.hash(sharpness, blur, vignette);
}

/// A colour look: one of the 12 bundled presets or an imported `.cube` LUT, mixed by
/// [intensity] in [0, 1]. Not keyframable.
@immutable
sealed class LookRef {
  const LookRef(this.intensity);

  /// Mix amount in [0, 1].
  final double intensity;

  /// The same look with a different mix amount.
  LookRef withIntensity(double intensity);
}

/// A bundled look (`assets/looks/<presetId>.vlut`, ARCH §10.2).
final class BuiltinLook extends LookRef {
  /// Creates a reference to bundled look [presetId].
  const BuiltinLook(this.presetId, {double intensity = 1}) : super(intensity);

  /// Stable preset id, e.g. `tealOrange`.
  final String presetId;

  /// A copy with the given fields replaced.
  BuiltinLook copyWith({String? presetId, double? intensity}) =>
      BuiltinLook(presetId ?? this.presetId, intensity: intensity ?? this.intensity);

  @override
  BuiltinLook withIntensity(double intensity) => BuiltinLook(presetId, intensity: intensity);

  @override
  bool operator ==(Object other) =>
      other is BuiltinLook && other.presetId == presetId && other.intensity == intensity;

  @override
  int get hashCode => Object.hash(presetId, intensity);
}

/// An imported LUT: a pool asset of kind `lut` (project-owned `.cube` + `.vlut`).
final class ImportedLut extends LookRef {
  /// Creates a reference to the LUT asset [lut].
  const ImportedLut(this.lut, {double intensity = 1}) : super(intensity);

  /// Pool asset of kind lut.
  final MediaId lut;

  /// A copy with the given fields replaced.
  ImportedLut copyWith({MediaId? lut, double? intensity}) =>
      ImportedLut(lut ?? this.lut, intensity: intensity ?? this.intensity);

  @override
  ImportedLut withIntensity(double intensity) => ImportedLut(lut, intensity: intensity);

  @override
  bool operator ==(Object other) => other is ImportedLut && other.lut == lut && other.intensity == intensity;

  @override
  int get hashCode => Object.hash(lut, intensity);
}

/// Chroma key settings (keyed on source colours, before grading; D-08). Not keyframable.
@immutable
final class ChromaKey {
  /// Creates chroma key settings; the default is off with a green key.
  const ChromaKey({
    this.enabled = false,
    this.color = 0x00B140,
    this.similarity = 0.4,
    this.smoothness = 0.1,
    this.spill = 0.3,
  });

  /// Off.
  static const ChromaKey off = ChromaKey();

  /// Whether keying is applied.
  final bool enabled;

  /// Key colour as `0xRRGGBB`.
  final int color;

  /// Distance threshold in [0, 1].
  final double similarity;

  /// Edge softness in [0, 1].
  final double smoothness;

  /// Spill reduction in [0, 1].
  final double spill;

  /// A copy with the given values replaced.
  ChromaKey copyWith({bool? enabled, int? color, double? similarity, double? smoothness, double? spill}) =>
      ChromaKey(
        enabled: enabled ?? this.enabled,
        color: color ?? this.color,
        similarity: similarity ?? this.similarity,
        smoothness: smoothness ?? this.smoothness,
        spill: spill ?? this.spill,
      );

  @override
  bool operator ==(Object other) =>
      other is ChromaKey &&
      other.enabled == enabled &&
      other.color == color &&
      other.similarity == similarity &&
      other.smoothness == smoothness &&
      other.spill == spill;

  @override
  int get hashCode => Object.hash(enabled, color, similarity, smoothness, spill);
}

/// Shape of an item mask.
enum MaskShape {
  /// No mask.
  none,

  /// Rounded rectangle.
  rectangle,

  /// Ellipse (the "circle mask" bullet).
  ellipse,
}

/// An item mask in item-local normalized coordinates (ARCH §6.5, §11.6 "Mask").
@immutable
final class MaskSpec {
  /// Creates a mask; the default is no mask.
  const MaskSpec({
    this.shape = MaskShape.none,
    this.center = const Vec2(0.5, 0.5),
    this.size = const Vec2(0.6, 0.6),
    this.rotationDeg = 0,
    this.cornerRadius = 0,
    this.feather = 0,
    this.opacity = 1,
    this.invert = false,
  });

  /// No mask.
  static const MaskSpec none = MaskSpec();

  /// Shape.
  final MaskShape shape;

  /// Centre in item-local normalized units.
  final Vec2 center;

  /// Size in item-local normalized units.
  final Vec2 size;

  /// Clockwise rotation in degrees.
  final double rotationDeg;

  /// Corner radius as a fraction of min(w, h), [0, 0.5].
  final double cornerRadius;

  /// Edge feather in [0, 1].
  final double feather;

  /// Mask strength in [0, 1].
  final double opacity;

  /// Keeps the outside instead of the inside.
  final bool invert;

  /// A copy with the given values replaced.
  MaskSpec copyWith({
    MaskShape? shape,
    Vec2? center,
    Vec2? size,
    double? rotationDeg,
    double? cornerRadius,
    double? feather,
    double? opacity,
    bool? invert,
  }) =>
      MaskSpec(
        shape: shape ?? this.shape,
        center: center ?? this.center,
        size: size ?? this.size,
        rotationDeg: rotationDeg ?? this.rotationDeg,
        cornerRadius: cornerRadius ?? this.cornerRadius,
        feather: feather ?? this.feather,
        opacity: opacity ?? this.opacity,
        invert: invert ?? this.invert,
      );

  @override
  bool operator ==(Object other) =>
      other is MaskSpec &&
      other.shape == shape &&
      other.center == center &&
      other.size == size &&
      other.rotationDeg == rotationDeg &&
      other.cornerRadius == cornerRadius &&
      other.feather == feather &&
      other.opacity == opacity &&
      other.invert == invert;

  @override
  int get hashCode => Object.hash(shape, center, size, rotationDeg, cornerRadius, feather, opacity, invert);
}

/// All visual properties of a clip on a video or overlay lane (ARCH §6.5).
@immutable
final class VisualProps {
  /// Creates visual properties; defaults are neutral.
  const VisualProps({
    this.transform = Transform2D.identity,
    this.fit = FitMode.fit,
    this.crop = CropRect.full,
    this.adjust = ColorAdjust.neutral,
    this.detail = DetailFx.none,
    this.look,
    this.chroma = ChromaKey.off,
    this.mask = MaskSpec.none,
  });

  /// Neutral visual properties.
  static const VisualProps neutral = VisualProps();

  /// Placement (position, scale, rotation, flips, opacity).
  final Transform2D transform;

  /// Base-size fit mode.
  final FitMode fit;

  /// Source crop.
  final CropRect crop;

  /// Colour adjustments.
  final ColorAdjust adjust;

  /// Sharpness, blur, vignette.
  final DetailFx detail;

  /// Optional look (preset or LUT).
  final LookRef? look;

  /// Chroma key.
  final ChromaKey chroma;

  /// Item mask.
  final MaskSpec mask;

  /// A copy with the given fields replaced; pass `look: null` to remove the look.
  VisualProps copyWith({
    Transform2D? transform,
    FitMode? fit,
    CropRect? crop,
    ColorAdjust? adjust,
    DetailFx? detail,
    Object? look = _keep,
    ChromaKey? chroma,
    MaskSpec? mask,
  }) =>
      VisualProps(
        transform: transform ?? this.transform,
        fit: fit ?? this.fit,
        crop: crop ?? this.crop,
        adjust: adjust ?? this.adjust,
        detail: detail ?? this.detail,
        look: identical(look, _keep) ? this.look : look as LookRef?,
        chroma: chroma ?? this.chroma,
        mask: mask ?? this.mask,
      );

  @override
  bool operator ==(Object other) =>
      other is VisualProps &&
      other.transform == transform &&
      other.fit == fit &&
      other.crop == crop &&
      other.adjust == adjust &&
      other.detail == detail &&
      other.look == look &&
      other.chroma == chroma &&
      other.mask == mask;

  @override
  int get hashCode => Object.hash(transform, fit, crop, adjust, detail, look, chroma, mask);
}
