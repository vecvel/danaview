// OWNER: CORE-29
//
// Engine-level encode parameters (ARCH §12.4, D-27). User-level choices are `ExportSettings`
// (CORE-33), which `compileExport` turns into these after presets and capability clamps.

import 'package:meta/meta.dart';

/// Output container. MOV only where the engine reports `movContainer` (iOS, D-23).
enum ExportContainer {
  /// MPEG-4.
  mp4,

  /// QuickTime (iOS only).
  mov,
}

/// Output video codec. HEVC only where a hardware encoder is probed (D-23).
enum VideoCodec {
  /// H.264 / AVC (High profile, auto level).
  h264,

  /// H.265 / HEVC (Main profile, `hvc1`).
  hevc,
}

/// What the engine encodes: SDR BT.709 8-bit video plus AAC audio (always present, D-38).
@immutable
final class EncodeSettings {
  /// Creates settings.
  const EncodeSettings({
    this.container = ExportContainer.mp4,
    this.codec = VideoCodec.h264,
    required this.width,
    required this.height,
    required this.fps,
    required this.videoBitrate,
    this.audioBitrate = 192000,
    this.audioSampleRate = 48000,
    this.audioChannels = 2,
    this.keyframeIntervalMs = 2000,
    this.stripLocation = true,
  });

  /// Container.
  final ExportContainer container;

  /// Video codec.
  final VideoCodec codec;

  /// Output width in px (even).
  final int width;

  /// Output height in px (even).
  final int height;

  /// Output frame rate (integer v1 rate).
  final int fps;

  /// Video bitrate in bits per second.
  final int videoBitrate;

  /// Audio bitrate in bits per second (96–320 kbps).
  final int audioBitrate;

  /// Audio sample rate (48,000).
  final int audioSampleRate;

  /// Audio channels (2).
  final int audioChannels;

  /// Maximum keyframe interval.
  final int keyframeIntervalMs;

  /// Never write location metadata (always true in v1).
  final bool stripLocation;

  /// A copy with the given fields replaced.
  EncodeSettings copyWith({
    ExportContainer? container,
    VideoCodec? codec,
    int? width,
    int? height,
    int? fps,
    int? videoBitrate,
    int? audioBitrate,
    int? keyframeIntervalMs,
  }) =>
      EncodeSettings(
        container: container ?? this.container,
        codec: codec ?? this.codec,
        width: width ?? this.width,
        height: height ?? this.height,
        fps: fps ?? this.fps,
        videoBitrate: videoBitrate ?? this.videoBitrate,
        audioBitrate: audioBitrate ?? this.audioBitrate,
        audioSampleRate: audioSampleRate,
        audioChannels: audioChannels,
        keyframeIntervalMs: keyframeIntervalMs ?? this.keyframeIntervalMs,
        stripLocation: stripLocation,
      );

  /// JSON form (used by fixtures and diagnostics; the Pigeon message mirrors these fields).
  Map<String, Object?> toJson() => {
        'container': container.name,
        'codec': codec.name,
        'width': width,
        'height': height,
        'fps': fps,
        'videoBitrate': videoBitrate,
        'audioBitrate': audioBitrate,
        'audioSampleRate': audioSampleRate,
        'audioChannels': audioChannels,
        'keyframeIntervalMs': keyframeIntervalMs,
        'stripLocation': stripLocation,
      };

  /// Inverse of [toJson].
  factory EncodeSettings.fromJson(Map<String, Object?> j) => EncodeSettings(
        container: ExportContainer.values.byName(j['container']! as String),
        codec: VideoCodec.values.byName(j['codec']! as String),
        width: j['width']! as int,
        height: j['height']! as int,
        fps: j['fps']! as int,
        videoBitrate: j['videoBitrate']! as int,
        audioBitrate: (j['audioBitrate'] as int?) ?? 192000,
        audioSampleRate: (j['audioSampleRate'] as int?) ?? 48000,
        audioChannels: (j['audioChannels'] as int?) ?? 2,
        keyframeIntervalMs: (j['keyframeIntervalMs'] as int?) ?? 2000,
        stripLocation: (j['stripLocation'] as bool?) ?? true,
      );

  @override
  bool operator ==(Object other) =>
      other is EncodeSettings &&
      other.container == container &&
      other.codec == codec &&
      other.width == width &&
      other.height == height &&
      other.fps == fps &&
      other.videoBitrate == videoBitrate &&
      other.audioBitrate == audioBitrate &&
      other.audioSampleRate == audioSampleRate &&
      other.audioChannels == audioChannels &&
      other.keyframeIntervalMs == keyframeIntervalMs &&
      other.stripLocation == stripLocation;

  @override
  int get hashCode => Object.hash(container, codec, width, height, fps, videoBitrate, audioBitrate, audioSampleRate,
      audioChannels, keyframeIntervalMs, stripLocation);
}
