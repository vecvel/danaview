// OWNER: CORE-04
//
// Probe results from the engine (one type across packages, D-27).

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../time/time.dart';

const Object _keep = Object();

/// Kind of a pool asset.
enum MediaKind {
  /// Video (may also carry audio).
  video,

  /// Audio only.
  audio,

  /// Still image (photo, PNG).
  image,

  /// A colour lookup table (`.cube` + `.vlut`).
  lut,

  /// A freeze-frame still rendered by the engine.
  still,

  /// A voice recording (WAV, D-25).
  recording,
}

/// Transfer function of the source (HDR sources are tone-mapped to SDR, ARCH §1.2).
enum ColorTransfer {
  /// SDR (BT.709/sRGB).
  sdr,

  /// HLG (iPhone HDR video).
  hlg,

  /// PQ (HDR10).
  pq,
}

/// What the engine learned about a media file.
@immutable
final class MediaProbe {
  /// Creates a probe result.
  MediaProbe({
    required this.kind,
    this.duration = 0,
    this.hasVideo = false,
    this.hasAudio = false,
    this.width,
    this.height,
    this.rotation = 0,
    this.nominalFrameRate,
    this.nominalFps,
    this.variableFrameRate = false,
    this.container,
    this.videoCodec,
    this.audioCodec,
    this.audioStreams = 0,
    this.channels,
    this.sampleRate,
    this.bitDepth,
    this.transfer = ColorTransfer.sdr,
    this.sizeBytes = 0,
    this.editable = true,
    List<String> issues = const [],
  }) : issues = List.unmodifiable(issues);

  /// A copy with the given fields replaced. Pass `null` explicitly to clear a nullable field
  /// (`width`, `height`, `nominalFrameRate`, `nominalFps`, `container`, `videoCodec`, `audioCodec`,
  /// `channels`, `sampleRate`, `bitDepth`).
  MediaProbe copyWith({
    MediaKind? kind,
    TimeUs? duration,
    bool? hasVideo,
    bool? hasAudio,
    Object? width = _keep,
    Object? height = _keep,
    int? rotation,
    Object? nominalFrameRate = _keep,
    Object? nominalFps = _keep,
    bool? variableFrameRate,
    Object? container = _keep,
    Object? videoCodec = _keep,
    Object? audioCodec = _keep,
    int? audioStreams,
    Object? channels = _keep,
    Object? sampleRate = _keep,
    Object? bitDepth = _keep,
    ColorTransfer? transfer,
    int? sizeBytes,
    bool? editable,
    List<String>? issues,
  }) =>
      MediaProbe(
        kind: kind ?? this.kind,
        duration: duration ?? this.duration,
        hasVideo: hasVideo ?? this.hasVideo,
        hasAudio: hasAudio ?? this.hasAudio,
        width: identical(width, _keep) ? this.width : width as int?,
        height: identical(height, _keep) ? this.height : height as int?,
        rotation: rotation ?? this.rotation,
        nominalFrameRate: identical(nominalFrameRate, _keep) ? this.nominalFrameRate : nominalFrameRate as FrameRate?,
        nominalFps: identical(nominalFps, _keep) ? this.nominalFps : nominalFps as double?,
        variableFrameRate: variableFrameRate ?? this.variableFrameRate,
        container: identical(container, _keep) ? this.container : container as String?,
        videoCodec: identical(videoCodec, _keep) ? this.videoCodec : videoCodec as String?,
        audioCodec: identical(audioCodec, _keep) ? this.audioCodec : audioCodec as String?,
        audioStreams: audioStreams ?? this.audioStreams,
        channels: identical(channels, _keep) ? this.channels : channels as int?,
        sampleRate: identical(sampleRate, _keep) ? this.sampleRate : sampleRate as int?,
        bitDepth: identical(bitDepth, _keep) ? this.bitDepth : bitDepth as int?,
        transfer: transfer ?? this.transfer,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        editable: editable ?? this.editable,
        issues: issues ?? this.issues,
      );

  /// Kind.
  final MediaKind kind;

  /// Duration (0 for images).
  final TimeUs duration;

  /// Has a video track.
  final bool hasVideo;

  /// Has at least one audio stream.
  final bool hasAudio;

  /// Display width (rotation applied).
  final int? width;

  /// Display height (rotation applied).
  final int? height;

  /// Rotation of the encoded frames: 0, 90, 180 or 270.
  final int rotation;

  /// Integer project rate nearest to the source rate (e.g. 29.97 → 30), when it has video.
  final FrameRate? nominalFrameRate;

  /// Measured average fps (display only).
  final double? nominalFps;

  /// Variable frame rate detected.
  final bool variableFrameRate;

  /// Container short name (`mp4`, `mov`, `mkv`, …).
  final String? container;

  /// Video codec (`h264`, `hevc`, …).
  final String? videoCodec;

  /// Audio codec (`aac`, `ac3`, …).
  final String? audioCodec;

  /// Number of audio streams.
  final int audioStreams;

  /// Channels of the first audio stream.
  final int? channels;

  /// Sample rate of the first audio stream.
  final int? sampleRate;

  /// Video bit depth (8 or 10).
  final int? bitDepth;

  /// Transfer function.
  final ColorTransfer transfer;

  /// File size.
  final int sizeBytes;

  /// Whether the editor can use this file on this platform.
  final bool editable;

  /// Machine-readable issue codes (e.g. `container_unsupported_ios`, `protected`).
  final List<String> issues;

  @override
  bool operator ==(Object other) =>
      other is MediaProbe &&
      other.kind == kind &&
      other.duration == duration &&
      other.hasVideo == hasVideo &&
      other.hasAudio == hasAudio &&
      other.width == width &&
      other.height == height &&
      other.rotation == rotation &&
      other.nominalFrameRate == nominalFrameRate &&
      other.nominalFps == nominalFps &&
      other.variableFrameRate == variableFrameRate &&
      other.container == container &&
      other.videoCodec == videoCodec &&
      other.audioCodec == audioCodec &&
      other.audioStreams == audioStreams &&
      other.channels == channels &&
      other.sampleRate == sampleRate &&
      other.bitDepth == bitDepth &&
      other.transfer == transfer &&
      other.sizeBytes == sizeBytes &&
      other.editable == editable &&
      const ListEquality<String>().equals(other.issues, issues);

  @override
  int get hashCode => Object.hashAll([
        kind, duration, hasVideo, hasAudio, width, height, rotation, nominalFrameRate, nominalFps,
        variableFrameRate, container, videoCodec, audioCodec, audioStreams, channels, sampleRate, bitDepth,
        transfer, sizeBytes, editable, Object.hashAll(issues),
      ]);
}
