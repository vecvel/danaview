import 'package:meta/meta.dart';

enum HwdecMode {
  autoSafe('auto-safe'),
  auto('auto'),
  no('no');

  final String mpvValue;
  const HwdecMode(this.mpvValue);
}

@immutable
class VideoAdjust {
  final double brightness; // -100 to 100, default 0
  final double contrast;   // -100 to 100, default 0
  final double saturation; // -100 to 100, default 0
  final double gamma;      // -100 to 100, default 0
  final double hue;        // -100 to 100, default 0

  const VideoAdjust({
    this.brightness = 0.0,
    this.contrast = 0.0,
    this.saturation = 0.0,
    this.gamma = 0.0,
    this.hue = 0.0,
  });

  static const VideoAdjust normal = VideoAdjust();

  VideoAdjust copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? gamma,
    double? hue,
  }) {
    return VideoAdjust(
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      gamma: gamma ?? this.gamma,
      hue: hue ?? this.hue,
    );
  }

  Map<String, dynamic> toJson() => {
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
        'gamma': gamma,
        'hue': hue,
      };

  factory VideoAdjust.fromJson(Map<String, dynamic> json) {
    return VideoAdjust(
      brightness: (json['brightness'] as num?)?.toDouble() ?? 0.0,
      contrast: (json['contrast'] as num?)?.toDouble() ?? 0.0,
      saturation: (json['saturation'] as num?)?.toDouble() ?? 0.0,
      gamma: (json['gamma'] as num?)?.toDouble() ?? 0.0,
      hue: (json['hue'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

@immutable
class VideoTransform {
  final double zoom;       // 1.0 = normal, 0.5 - 4.0
  final double panX;       // -1.0 to 1.0
  final double panY;       // -1.0 to 1.0
  final int rotation;      // 0, 90, 180, 270
  final String? aspectOverride; // '16:9', '4:3', '2.35:1', null = auto
  final bool flipHorizontal;
  final bool flipVertical;

  const VideoTransform({
    this.zoom = 1.0,
    this.panX = 0.0,
    this.panY = 0.0,
    this.rotation = 0,
    this.aspectOverride,
    this.flipHorizontal = false,
    this.flipVertical = false,
  });

  static const VideoTransform normal = VideoTransform();

  VideoTransform copyWith({
    double? zoom,
    double? panX,
    double? panY,
    int? rotation,
    Object? aspectOverride = _sentinel,
    bool? flipHorizontal,
    bool? flipVertical,
  }) {
    return VideoTransform(
      zoom: zoom ?? this.zoom,
      panX: panX ?? this.panX,
      panY: panY ?? this.panY,
      rotation: rotation ?? this.rotation,
      aspectOverride: aspectOverride == _sentinel ? this.aspectOverride : aspectOverride as String?,
      flipHorizontal: flipHorizontal ?? this.flipHorizontal,
      flipVertical: flipVertical ?? this.flipVertical,
    );
  }
}

@immutable
class SubtitleStyle {
  final String fontFamily;
  final double fontSize;
  final int fontColor;
  final int borderColor;
  final double borderSize;
  final int backgroundColor;
  final double shadowOffset;
  final int verticalPosition; // 0–100, 100 = bottom
  final double scale;
  final String assOverrideMode; // 'yes', 'no', 'force', 'strip'

  const SubtitleStyle({
    this.fontFamily = 'Figtree',
    this.fontSize = 55.0,
    this.fontColor = 0xFFFFFFFF,
    this.borderColor = 0xFF000000,
    this.borderSize = 3.0,
    this.backgroundColor = 0x00000000,
    this.shadowOffset = 1.5,
    this.verticalPosition = 100,
    this.scale = 1.0,
    this.assOverrideMode = 'yes',
  });

  static const SubtitleStyle normal = SubtitleStyle();

  SubtitleStyle copyWith({
    String? fontFamily,
    double? fontSize,
    int? fontColor,
    int? borderColor,
    double? borderSize,
    int? backgroundColor,
    double? shadowOffset,
    int? verticalPosition,
    double? scale,
    String? assOverrideMode,
  }) {
    return SubtitleStyle(
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      fontColor: fontColor ?? this.fontColor,
      borderColor: borderColor ?? this.borderColor,
      borderSize: borderSize ?? this.borderSize,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      shadowOffset: shadowOffset ?? this.shadowOffset,
      verticalPosition: verticalPosition ?? this.verticalPosition,
      scale: scale ?? this.scale,
      assOverrideMode: assOverrideMode ?? this.assOverrideMode,
    );
  }

  Map<String, dynamic> toJson() => {
        'fontFamily': fontFamily,
        'fontSize': fontSize,
        'fontColor': fontColor,
        'borderColor': borderColor,
        'borderSize': borderSize,
        'backgroundColor': backgroundColor,
        'shadowOffset': shadowOffset,
        'verticalPosition': verticalPosition,
        'scale': scale,
        'assOverrideMode': assOverrideMode,
      };

  factory SubtitleStyle.fromJson(Map<String, dynamic> json) {
    return SubtitleStyle(
      // Inter was never bundled; saved styles move to Figtree, the app's only typeface.
      fontFamily: switch (json['fontFamily']) { final String f when f != 'Inter' => f, _ => 'Figtree' },
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 55.0,
      fontColor: json['fontColor'] as int? ?? 0xFFFFFFFF,
      borderColor: json['borderColor'] as int? ?? 0xFF000000,
      borderSize: (json['borderSize'] as num?)?.toDouble() ?? 3.0,
      backgroundColor: json['backgroundColor'] as int? ?? 0x00000000,
      shadowOffset: (json['shadowOffset'] as num?)?.toDouble() ?? 1.5,
      verticalPosition: json['verticalPosition'] as int? ?? 100,
      scale: (json['scale'] as num?)?.toDouble() ?? 1.0,
      assOverrideMode: json['assOverrideMode'] as String? ?? 'yes',
    );
  }
}

const Object _sentinel = Object();
