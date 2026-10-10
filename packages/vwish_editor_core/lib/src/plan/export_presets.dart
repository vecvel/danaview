// OWNER: CORE-33
//
// Export presets (ARCH §14.1 table, exactly; non-binding platform hints [VERIFY V-D9], sources in
// bitrate.dart):
//
// | Preset          | Size                                   | FPS                         | Codec                    | Video bitrate                  | Audio    |
// |-----------------|----------------------------------------|-----------------------------|--------------------------|--------------------------------|----------|
// | YouTube         | short side 1080, project aspect        | project, ≤ 60               | H.264 High               | 8 / 12 Mbps (auto table)       | 192 kbps |
// | YouTube 4K      | short side 2160 (capability-gated)     | project, ≤ 60               | HEVC if available, else H.264 | 40 / 60 Mbps; HEVC × 0.6  | 256 kbps |
// | YouTube Shorts  | 1080×1920                              | project, ≤ 60               | H.264                    | 8 / 12 Mbps (auto table)       | 192 kbps |
// | Instagram Reels | 1080×1920                              | 30                          | H.264                    | 8 Mbps                         | 128 kbps |
// | Instagram Feed  | 1080×1350                              | 30                          | H.264                    | 6 Mbps                         | 128 kbps |
// | TikTok          | 1080×1920                              | 30 (60 if the project is 60)| H.264                    | 8 Mbps                         | 128 kbps |
// | Custom          | short side 720/1080/1440/2160, project aspect | Match project (default) or 24/25/30/48/50/60 | H.264 / H.265*; MP4 / MOV* | auto, or 2–100 Mbps | 96–320 kbps |
//
// Every preset's bitrate is then multiplied by the export quality (Balanced = 1.0 gives the table
// values) unless Custom sets an explicit bitrate. All presets write MP4 except Custom with MOV.

import 'package:meta/meta.dart';

import '../model/settings.dart';

/// The presets of ARCH §14.1.
enum ExportPresetId {
  /// YouTube 1080p, project aspect.
  youtube,

  /// YouTube 2160p, project aspect (capability-gated).
  youtube4k,

  /// YouTube Shorts 1080×1920.
  youtubeShorts,

  /// Instagram Reels 1080×1920.
  instagramReels,

  /// Instagram Feed 1080×1350.
  instagramFeed,

  /// TikTok 1080×1920.
  tiktok,

  /// User-chosen resolution, rate, container, codec and bitrates.
  custom,
}

/// How a preset picks its frame rate.
enum PresetFps {
  /// The project rate (all v1 rates are ≤ 60).
  project,

  /// 30 fps.
  thirty,

  /// 30 fps, or 60 when the project is 60.
  thirtyOrSixty,

  /// The user's choice (Custom): Match project or a fixed rate.
  custom,
}

/// How a preset picks its codec.
enum PresetCodec {
  /// H.264.
  h264,

  /// HEVC when the device encodes it, else H.264.
  hevcIfAvailable,

  /// The user's choice (Custom).
  custom,
}

/// One preset row.
@immutable
final class ExportPreset {
  /// Creates a preset.
  const ExportPreset({
    required this.id,
    required this.label,
    this.shortSide,
    this.fixedAspect,
    required this.fps,
    required this.codec,
    this.fixedVideoMbps,
    required this.audioKbps,
  });

  /// Id.
  final ExportPresetId id;

  /// UI label.
  final String label;

  /// Output short side in px (null for Custom, which the user chooses).
  final int? shortSide;

  /// Fixed output aspect (vertical presets), or null for the project aspect.
  final AspectRatio? fixedAspect;

  /// Frame rate rule.
  final PresetFps fps;

  /// Codec rule.
  final PresetCodec codec;

  /// A fixed video bitrate in Mbps, or null for the auto table.
  final double? fixedVideoMbps;

  /// Audio bitrate in kbps (Custom: the default).
  final int audioKbps;

  /// The preset of [id].
  static ExportPreset of(ExportPresetId id) => all.firstWhere((p) => p.id == id);

  /// Every preset in UI order.
  static const List<ExportPreset> all = [
    ExportPreset(
      id: ExportPresetId.youtube,
      label: 'YouTube',
      shortSide: 1080,
      fps: PresetFps.project,
      codec: PresetCodec.h264,
      audioKbps: 192,
    ),
    ExportPreset(
      id: ExportPresetId.youtube4k,
      label: 'YouTube 4K',
      shortSide: 2160,
      fps: PresetFps.project,
      codec: PresetCodec.hevcIfAvailable,
      audioKbps: 256,
    ),
    ExportPreset(
      id: ExportPresetId.youtubeShorts,
      label: 'YouTube Shorts',
      shortSide: 1080,
      fixedAspect: AspectRatio.portrait9x16,
      fps: PresetFps.project,
      codec: PresetCodec.h264,
      audioKbps: 192,
    ),
    ExportPreset(
      id: ExportPresetId.instagramReels,
      label: 'Instagram Reels',
      shortSide: 1080,
      fixedAspect: AspectRatio.portrait9x16,
      fps: PresetFps.thirty,
      codec: PresetCodec.h264,
      fixedVideoMbps: 8,
      audioKbps: 128,
    ),
    ExportPreset(
      id: ExportPresetId.instagramFeed,
      label: 'Instagram Feed',
      shortSide: 1080,
      fixedAspect: AspectRatio.portrait4x5,
      fps: PresetFps.thirty,
      codec: PresetCodec.h264,
      fixedVideoMbps: 6,
      audioKbps: 128,
    ),
    ExportPreset(
      id: ExportPresetId.tiktok,
      label: 'TikTok',
      shortSide: 1080,
      fixedAspect: AspectRatio.portrait9x16,
      fps: PresetFps.thirtyOrSixty,
      codec: PresetCodec.h264,
      fixedVideoMbps: 8,
      audioKbps: 128,
    ),
    ExportPreset(
      id: ExportPresetId.custom,
      label: 'Custom',
      fps: PresetFps.custom,
      codec: PresetCodec.custom,
      audioKbps: 192,
    ),
  ];
}

/// Short sides offered by Custom.
const List<int> customShortSides = [720, 1080, 1440, 2160];

/// Frame rates offered by Custom besides Match project.
const List<int> customFrameRates = [24, 25, 30, 48, 50, 60];

/// Short sides tried, largest first, when a capability limit forces a smaller output.
const List<int> fallbackShortSides = [2160, 1440, 1080, 720, 540, 480, 360];
