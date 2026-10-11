// OWNER: CORE-33
//
// Export bitrates and the size estimate (ARCH §14.1):
//
// * auto video bitrate by output short side {720: 5 / 7.5, 1080: 8 / 12, 1440: 16 / 24,
//   2160: 40 / 60} Mbps for ≤ 30 / > 30 fps, × 0.6 for HEVC, × quality (Smaller 0.6, Balanced 1.0,
//   High 1.5, Maximum 2.0). A short side between rows uses the next larger row (above 2160 the
//   2160 row);
// * custom bitrates: video 2–100 Mbps, audio 96–320 kbps (clamped);
// * size estimate `(video + audio bps) · seconds / 8 · 1.02` bytes (container overhead 2%).
//
// V-D9 (non-binding platform hints, reviewed 2026-10): the table follows YouTube's published
// "recommended upload encoding settings" (SDR: 1080p 8 / 12 Mbps, 1440p 16 / 24 Mbps, 2160p
// 35–45 / 53–68 Mbps, rounded to 40 / 60; 720p 5 / 7.5 Mbps), and the social presets use the
// sizes and rates Instagram's and TikTok's creator help pages give for Reels/feed and uploads
// (1080×1920 and 1080×1350, H.264 + AAC, 30 fps). Sources were reviewed from the platforms' public
// help centres as of the review date and are guidance only: every preset stays valid if the
// platforms change their advice, which re-encode uploads anyway. Recheck before each release.

import '../time/time.dart';
import 'encode_settings.dart';

/// Export quality: a multiplier of the auto bitrate.
enum ExportQuality {
  /// × 0.6.
  smaller(0.6),

  /// × 1.0 (default).
  balanced(1.0),

  /// × 1.5.
  high(1.5),

  /// × 2.0.
  maximum(2.0);

  const ExportQuality(this.factor);

  /// Bitrate multiplier.
  final double factor;
}

/// Auto bitrate table: short side → (Mbps at ≤ 30 fps, Mbps at > 30 fps).
const Map<int, (double, double)> autoBitrateTableMbps = {
  720: (5, 7.5),
  1080: (8, 12),
  1440: (16, 24),
  2160: (40, 60),
};

/// HEVC needs this fraction of the H.264 bitrate.
const double hevcBitrateFactor = 0.6;

/// Lowest custom video bitrate (Mbps).
const double minCustomVideoMbps = 2;

/// Highest custom video bitrate (Mbps).
const double maxCustomVideoMbps = 100;

/// Lowest audio bitrate (kbps).
const int minAudioKbps = 96;

/// Highest audio bitrate (kbps).
const int maxAudioKbps = 320;

/// Container overhead of the size estimate.
const double containerOverhead = 1.02;

/// The table row used for an output whose short side is [shortSide]: the smallest row ≥ it, or
/// the largest row above 2160.
int bitrateRowFor(int shortSide) {
  for (final row in autoBitrateTableMbps.keys) {
    if (shortSide <= row) return row;
  }
  return autoBitrateTableMbps.keys.last;
}

/// The auto video bitrate in bits per second of an output of [shortSide] px at [fps] encoded
/// with [codec] at [quality].
int autoVideoBitrate({
  required int shortSide,
  required int fps,
  VideoCodec codec = VideoCodec.h264,
  ExportQuality quality = ExportQuality.balanced,
}) {
  final row = autoBitrateTableMbps[bitrateRowFor(shortSide)]!;
  final mbps = fps > 30 ? row.$2 : row.$1;
  return mbpsToBps(mbps * (codec == VideoCodec.hevc ? hevcBitrateFactor : 1) * quality.factor);
}

/// [mbps] in bits per second (rounded).
int mbpsToBps(double mbps) => (mbps * 1000000).round();

/// A custom video bitrate in Mbps clamped to 2–100, in bits per second.
int customVideoBitrate(double mbps) => mbpsToBps(mbps.clamp(minCustomVideoMbps, maxCustomVideoMbps).toDouble());

/// An audio bitrate in kbps clamped to 96–320, in bits per second.
int audioBitrateOf(int kbps) => kbps.clamp(minAudioKbps, maxAudioKbps) * 1000;

/// The estimated file size in bytes of [durationUs] of output at [videoBitrate] + [audioBitrate]
/// bits per second: `(v + a) · seconds / 8 · 1.02` (ARCH §14.1).
int estimateExportBytes({required int videoBitrate, required int audioBitrate, required TimeUs durationUs}) =>
    ((videoBitrate + audioBitrate) * (durationUs / microsPerSecond) / 8 * containerOverhead).round();

/// [estimateExportBytes] of [encode] over [durationUs].
int estimateEncodeBytes(EncodeSettings encode, TimeUs durationUs) =>
    estimateExportBytes(videoBitrate: encode.videoBitrate, audioBitrate: encode.audioBitrate, durationUs: durationUs);
