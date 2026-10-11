// OWNER: CORE-03
//
// Project settings (ARCH §6.1): canvas, frame rate, background, audio sample rate.

import 'package:meta/meta.dart';

import '../time/time.dart';

/// An aspect ratio `w:h` in small integers (e.g. 16:9, 9:16, 4:5).
@immutable
final class AspectRatio {
  /// Creates `w:h`.
  const AspectRatio(this.w, this.h) : assert(w > 0 && h > 0);

  /// 16:9 landscape.
  static const AspectRatio landscape16x9 = AspectRatio(16, 9);

  /// 9:16 portrait (Shorts, Reels, TikTok).
  static const AspectRatio portrait9x16 = AspectRatio(9, 16);

  /// 1:1 square.
  static const AspectRatio square = AspectRatio(1, 1);

  /// 4:5 portrait (Instagram feed).
  static const AspectRatio portrait4x5 = AspectRatio(4, 5);

  /// 4:3.
  static const AspectRatio classic4x3 = AspectRatio(4, 3);

  /// 21:9.
  static const AspectRatio cinema21x9 = AspectRatio(21, 9);

  /// Standard ratios offered by the Format panel and used when snapping source aspects (±1%).
  static const List<AspectRatio> standard = [landscape16x9, portrait9x16, square, portrait4x5, classic4x3, cinema21x9];

  /// Width term.
  final int w;

  /// Height term.
  final int h;

  /// A copy with the given terms.
  AspectRatio copyWith({int? w, int? h}) => AspectRatio(w ?? this.w, h ?? this.h);

  /// `w / h`.
  double get value => w / h;

  /// Whether this ratio is taller than wide.
  bool get isPortrait => h > w;

  @override
  bool operator ==(Object other) => other is AspectRatio && other.w * h == w * other.h;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$w:$h';
}

/// The project canvas: an aspect ratio plus the short side in pixels (720, 1080 or 2160).
/// The long side is rounded to an even number of pixels.
@immutable
final class CanvasSpec {
  /// Creates a canvas.
  const CanvasSpec({this.aspect = AspectRatio.landscape16x9, this.baseShortSide = 1080});

  /// Short sides a v1 project may use.
  static const List<int> supportedShortSides = [720, 1080, 2160];

  /// Aspect ratio.
  final AspectRatio aspect;

  /// Short side in px.
  final int baseShortSide;

  /// Canvas width in px (even).
  int get widthPx => aspect.isPortrait ? baseShortSide : _evenLong;

  /// Canvas height in px (even).
  int get heightPx => aspect.isPortrait ? _evenLong : baseShortSide;

  int get _evenLong {
    final ratio = aspect.isPortrait ? aspect.h / aspect.w : aspect.w / aspect.h;
    final long = (baseShortSide * ratio).round();
    return long.isEven ? long : long + 1;
  }

  /// A copy with the given fields replaced.
  CanvasSpec copyWith({AspectRatio? aspect, int? baseShortSide}) =>
      CanvasSpec(aspect: aspect ?? this.aspect, baseShortSide: baseShortSide ?? this.baseShortSide);

  @override
  bool operator ==(Object other) =>
      other is CanvasSpec && other.aspect == aspect && other.baseShortSide == baseShortSide;

  @override
  int get hashCode => Object.hash(aspect, baseShortSide);

  @override
  String toString() => 'CanvasSpec($aspect, ${widthPx}x$heightPx)';
}

/// What fills the canvas behind the main lane.
@immutable
sealed class BackgroundSpec {
  const BackgroundSpec();

  /// Opaque black.
  static const BackgroundSpec black = SolidBackground(0xFF000000);
}

/// A solid colour background.
final class SolidBackground extends BackgroundSpec {
  /// Creates a solid background of ARGB [color].
  const SolidBackground(this.color);

  /// ARGB colour (alpha is ignored; the canvas is opaque).
  final int color;

  /// A copy with the given colour.
  SolidBackground copyWith({int? color}) => SolidBackground(color ?? this.color);

  @override
  bool operator ==(Object other) => other is SolidBackground && other.color == color;

  @override
  int get hashCode => color.hashCode;
}

/// A blurred, canvas-filling copy of each main-lane clip behind it (lowered to `#bd` layers).
final class BlurOfMainBackground extends BackgroundSpec {
  /// Creates a blurred background with blur [radius] in [0, 1].
  const BlurOfMainBackground(this.radius);

  /// Blur amount in [0, 1] (same scale as `DetailFx.blur`).
  final double radius;

  /// A copy with the given radius.
  BlurOfMainBackground copyWith({double? radius}) => BlurOfMainBackground(radius ?? this.radius);

  @override
  bool operator ==(Object other) => other is BlurOfMainBackground && other.radius == radius;

  @override
  int get hashCode => radius.hashCode;
}

/// Settings shared by the whole project (history-tracked, part of `Timeline`).
@immutable
final class ProjectSettings {
  /// Creates settings; the default is 16:9 1080p at 30 fps on black, 48 kHz audio.
  const ProjectSettings({
    this.canvas = const CanvasSpec(),
    this.frameRate = FrameRate.fps30,
    this.background = BackgroundSpec.black,
    this.audioSampleRate = 48000,
  });

  /// Canvas.
  final CanvasSpec canvas;

  /// Project frame rate (integer, D-03).
  final FrameRate frameRate;

  /// Background.
  final BackgroundSpec background;

  /// Audio sample rate (48,000 in v1).
  final int audioSampleRate;

  /// A copy with the given fields replaced.
  ProjectSettings copyWith({CanvasSpec? canvas, FrameRate? frameRate, BackgroundSpec? background, int? audioSampleRate}) =>
      ProjectSettings(
        canvas: canvas ?? this.canvas,
        frameRate: frameRate ?? this.frameRate,
        background: background ?? this.background,
        audioSampleRate: audioSampleRate ?? this.audioSampleRate,
      );

  @override
  bool operator ==(Object other) =>
      other is ProjectSettings &&
      other.canvas == canvas &&
      other.frameRate == frameRate &&
      other.background == background &&
      other.audioSampleRate == audioSampleRate;

  @override
  int get hashCode => Object.hash(canvas, frameRate, background, audioSampleRate);
}
