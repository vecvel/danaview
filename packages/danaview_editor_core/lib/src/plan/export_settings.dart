// OWNER: CORE-33
//
// User-level export settings (ARCH §14.1 step 2) and the capability subset the export needs.
//
// [ExportSettings] is what the export sheet (UX-39) edits: a preset, and for Custom a short side,
// a frame rate (Match project by default), container, codec and explicit bitrates; the quality
// multiplier; per-track burn-in of subtitle tracks; subtitle side files. `resolveExportSettings`
// (compile_export.dart) turns it into engine-level `EncodeSettings` after presets and the
// [ExportCapabilities] clamps.
//
// [ExportCapabilities] mirrors the fields of the engine's `EditorCapabilities` (ARCH §12.5) that
// the export reads; INT-02/UX-39 build it from the engine's capabilities (core cannot import the
// engine API, ARCH §4.2).

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../ids/ids.dart';
import 'bitrate.dart';
import 'encode_settings.dart';
import 'export_presets.dart';

const Object _keep = Object();

/// A subtitle side file written next to the export.
enum SideFileFormat {
  /// SubRip.
  srt,

  /// WebVTT.
  vtt,
}

/// What the export needs of `EditorCapabilities`.
@immutable
final class ExportCapabilities {
  /// Creates capabilities; the default is a capable device (H.264 only, MP4 only, 4K, 60 fps).
  const ExportCapabilities({
    this.h264Encode = true,
    this.hevcEncode = false,
    this.movContainer = false,
    this.maxExportLongSide = 3840,
    this.maxExportShortSide = 2160,
    this.maxFpsByHeight = const {},
    this.maxTextureSize = 4096,
    this.maxAudioSpeed = 4,
    this.holdFrame = true,
  });

  /// H.264 encoding available.
  final bool h264Encode;

  /// HEVC encoding available (a hardware encoder was probed, D-23).
  final bool hevcEncode;

  /// MOV container available (iOS).
  final bool movContainer;

  /// Longest output side in px (`maxExportSize`, larger side).
  final int maxExportLongSide;

  /// Shortest-side limit in px (`maxExportSize`, smaller side).
  final int maxExportShortSide;

  /// Highest export fps by output short side (`maxFpsByHeight`): an output of short side s may use
  /// the value of the smallest key ≥ s (the largest key's value above every key); empty = 60.
  final Map<int, int> maxFpsByHeight;

  /// `maxTextureSize` (sprite raster clamp).
  final int maxTextureSize;

  /// `maxAudioSpeed` (D-15).
  final double maxAudioSpeed;

  /// `holdFrame`.
  final bool holdFrame;

  /// The highest fps allowed at an output short side of [shortSide].
  int maxFpsFor(int shortSide) {
    if (maxFpsByHeight.isEmpty) return 60;
    final keys = maxFpsByHeight.keys.toList()..sort();
    for (final k in keys) {
      if (shortSide <= k) return maxFpsByHeight[k]!;
    }
    return maxFpsByHeight[keys.last]!;
  }

  /// A copy with the given fields replaced.
  ExportCapabilities copyWith({
    bool? h264Encode,
    bool? hevcEncode,
    bool? movContainer,
    int? maxExportLongSide,
    int? maxExportShortSide,
    Map<int, int>? maxFpsByHeight,
    int? maxTextureSize,
    double? maxAudioSpeed,
    bool? holdFrame,
  }) =>
      ExportCapabilities(
        h264Encode: h264Encode ?? this.h264Encode,
        hevcEncode: hevcEncode ?? this.hevcEncode,
        movContainer: movContainer ?? this.movContainer,
        maxExportLongSide: maxExportLongSide ?? this.maxExportLongSide,
        maxExportShortSide: maxExportShortSide ?? this.maxExportShortSide,
        maxFpsByHeight: maxFpsByHeight ?? this.maxFpsByHeight,
        maxTextureSize: maxTextureSize ?? this.maxTextureSize,
        maxAudioSpeed: maxAudioSpeed ?? this.maxAudioSpeed,
        holdFrame: holdFrame ?? this.holdFrame,
      );

  @override
  bool operator ==(Object other) =>
      other is ExportCapabilities &&
      other.h264Encode == h264Encode &&
      other.hevcEncode == hevcEncode &&
      other.movContainer == movContainer &&
      other.maxExportLongSide == maxExportLongSide &&
      other.maxExportShortSide == maxExportShortSide &&
      const MapEquality<int, int>().equals(other.maxFpsByHeight, maxFpsByHeight) &&
      other.maxTextureSize == maxTextureSize &&
      other.maxAudioSpeed == maxAudioSpeed &&
      other.holdFrame == holdFrame;

  @override
  int get hashCode => Object.hash(h264Encode, hevcEncode, movContainer, maxExportLongSide, maxExportShortSide,
      const MapEquality<int, int>().hash(maxFpsByHeight), maxTextureSize, maxAudioSpeed, holdFrame);
}

/// The export sheet's choices (file header). Custom-only fields are ignored by other presets.
@immutable
final class ExportSettings {
  /// Creates settings; the default is the YouTube preset at Balanced quality.
  ExportSettings({
    this.preset = ExportPresetId.youtube,
    this.shortSide = 1080,
    this.fps,
    this.container = ExportContainer.mp4,
    this.codec = VideoCodec.h264,
    this.quality = ExportQuality.balanced,
    this.videoBitrateMbps,
    this.audioBitrateKbps,
    Map<TrackId, bool> burnInSubtitles = const {},
    Set<SideFileFormat> sideFiles = const {},
  })  : burnInSubtitles = Map.unmodifiable(burnInSubtitles),
        sideFiles = Set.unmodifiable(sideFiles) {
    if (!customShortSides.contains(shortSide)) {
      throw ArgumentError.value(shortSide, 'shortSide', 'must be one of $customShortSides');
    }
    final f = fps;
    if (f != null && !customFrameRates.contains(f)) throw ArgumentError.value(f, 'fps', 'must be one of $customFrameRates');
  }

  /// Preset.
  final ExportPresetId preset;

  /// Custom: output short side (720, 1080, 1440 or 2160; the project aspect gives the long side).
  final int shortSide;

  /// Custom: frame rate, or null for Match project (default).
  final int? fps;

  /// Custom: container (MOV only where the engine has it).
  final ExportContainer container;

  /// Custom: codec (HEVC only where the engine has it).
  final VideoCodec codec;

  /// Bitrate multiplier of the auto table (every preset).
  final ExportQuality quality;

  /// Custom: explicit video bitrate in Mbps (2–100, clamped), or null for the auto table.
  final double? videoBitrateMbps;

  /// Custom: audio bitrate in kbps (96–320, clamped), or null for the preset default.
  final int? audioBitrateKbps;

  /// Per subtitle track: burn into the video (overrides `SubtitleTrackData.burnIn`).
  final Map<TrackId, bool> burnInSubtitles;

  /// Subtitle side files to write next to the export.
  final Set<SideFileFormat> sideFiles;

  /// A copy with the given fields replaced; pass null to reset `fps`, `videoBitrateMbps` or
  /// `audioBitrateKbps`.
  ExportSettings copyWith({
    ExportPresetId? preset,
    int? shortSide,
    Object? fps = _keep,
    ExportContainer? container,
    VideoCodec? codec,
    ExportQuality? quality,
    Object? videoBitrateMbps = _keep,
    Object? audioBitrateKbps = _keep,
    Map<TrackId, bool>? burnInSubtitles,
    Set<SideFileFormat>? sideFiles,
  }) =>
      ExportSettings(
        preset: preset ?? this.preset,
        shortSide: shortSide ?? this.shortSide,
        fps: identical(fps, _keep) ? this.fps : fps as int?,
        container: container ?? this.container,
        codec: codec ?? this.codec,
        quality: quality ?? this.quality,
        videoBitrateMbps: identical(videoBitrateMbps, _keep) ? this.videoBitrateMbps : videoBitrateMbps as double?,
        audioBitrateKbps: identical(audioBitrateKbps, _keep) ? this.audioBitrateKbps : audioBitrateKbps as int?,
        burnInSubtitles: burnInSubtitles ?? this.burnInSubtitles,
        sideFiles: sideFiles ?? this.sideFiles,
      );

  @override
  bool operator ==(Object other) =>
      other is ExportSettings &&
      other.preset == preset &&
      other.shortSide == shortSide &&
      other.fps == fps &&
      other.container == container &&
      other.codec == codec &&
      other.quality == quality &&
      other.videoBitrateMbps == videoBitrateMbps &&
      other.audioBitrateKbps == audioBitrateKbps &&
      const MapEquality<TrackId, bool>().equals(other.burnInSubtitles, burnInSubtitles) &&
      const SetEquality<SideFileFormat>().equals(other.sideFiles, sideFiles);

  @override
  int get hashCode => Object.hash(preset, shortSide, fps, container, codec, quality, videoBitrateMbps, audioBitrateKbps,
      const MapEquality<TrackId, bool>().hash(burnInSubtitles), const SetEquality<SideFileFormat>().hash(sideFiles));
}
