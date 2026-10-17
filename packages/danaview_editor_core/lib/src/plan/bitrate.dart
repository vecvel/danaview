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

import 'dart:math' as math;

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

// Multi-pass precompose intermediates (D-45(B), ARCH §14.1 step 5, IOS-20 / AND-19). When the
// engine's preflight reports `layersVsResolution`, the export may run a precompose whose
// video-only intermediates live next to the output in the work directory. Dart does not know the
// pass count or (in core) the platform, so it counts the larger of the two native models
// (FIX-PRECOMPOSE-ESTIMATE):
//
// * Android (AND-19 `PrecomposePlanner.diskEstimate` / `paddedDurationUs`): one intermediate is
//   `4 · videoBitrate · (dur + 1 grid frame) / 8 · 1.02`; pass n ≥ 2 holds its input and its
//   output, the final pass the last intermediate and the output, so the work volume peaks at
//   `max(2·I, I + output)` and the extra is that minus the output.
// * iOS (IOS-20 `PrecomposePass.estimatedBytes` / `PrecomposeExporter.requiredBytes`): the
//   intermediate bitrate is `min(240 Mbit/s, max(4 · videoBitrate, 0.2 · w · h · fps))`, one
//   intermediate is `b · dur / 8 · 1.02 + b · 10 s / 8` (one 10 s segment while it is joined),
//   and the disk check needs the export (estimate + one export segment, which the preflight adds
//   on iOS itself) plus two intermediates alive at once, so the extra is `2·I`.
//
// The iOS model is above the Android one whenever 4 · videoBitrate is within the iOS cap (the
// joining segment, and the bits-per-pixel floor at low bitrates); the Android one can win above
// that cap (export bitrates well over 60 Mbit/s: high custom bitrates, 2160p60 at Maximum) or when
// the output outweighs an intermediate.

/// Bitrate multiple of a precompose intermediate over the export video bitrate (D-45(B)).
const int precomposeBitrateFactor = 4;

/// iOS (IOS-20): lowest intermediate bitrate in bits per pixel and frame.
const double iosPrecomposeMinBitsPerPixel = 0.2;

/// iOS (IOS-20): highest intermediate bitrate in bits per second.
const int iosPrecomposeMaxBitrate = 240000000;

/// iOS (IOS-17): segment duration of the segmented writer; one segment is counted while an
/// intermediate is joined.
const TimeUs iosSegmentDurationUs = 10000000;

/// The platform whose native precompose disk model a per-platform estimate follows.
enum PrecomposeDiskModel {
  /// AND-19's `PrecomposePlanner.diskEstimate`.
  android,

  /// IOS-20's `PrecomposeExporter.requiredBytes`.
  ios,
}

/// [durationUs] plus one frame of the [gridFps] grid: the end of the grid frame after the one
/// containing [durationUs] (`timeOfFrame(frameIndexOf(dur) + 1)`), as the intermediates are rendered.
TimeUs precomposePaddedDurationUs(TimeUs durationUs, int gridFps) {
  final grid = FrameRate(gridFps, 1);
  return grid.timeOfFrame(grid.frameIndexOf(durationUs) + 1);
}

/// Android (AND-19): bytes of one video-only precompose intermediate: `4 · videoBitrate · (dur + 1
/// grid frame) / 8 · 1.02` (rounded down like the native planner).
int precomposeIntermediateBytes({required int videoBitrate, required TimeUs durationUs, required int gridFps}) =>
    (precomposeBitrateFactor * videoBitrate * (precomposePaddedDurationUs(durationUs, gridFps) / microsPerSecond) / 8 * containerOverhead)
        .floor();

/// iOS (IOS-20 `PrecomposePass.bitrate`): the intermediate bitrate of an export of [encode]:
/// `min(240 Mbit/s, max(4 · videoBitrate, 0.2 · width · height · fps))`, truncated.
int iosPrecomposeIntermediateBitrate(EncodeSettings encode) {
  final floor = encode.width * encode.height * encode.fps * iosPrecomposeMinBitsPerPixel;
  final wanted = math.max((encode.videoBitrate * precomposeBitrateFactor).toDouble(), floor);
  return math.min(iosPrecomposeMaxBitrate.toDouble(), wanted).toInt();
}

/// iOS (IOS-20 `PrecomposePass.estimatedBytes`): bytes of one intermediate of [encode] over
/// [durationUs] plus one segment while it is joined: `b · dur / 8 · 1.02 + b · 10 s / 8`, truncated.
int iosPrecomposeIntermediateBytes(EncodeSettings encode, TimeUs durationUs) {
  final bps = iosPrecomposeIntermediateBitrate(encode).toDouble();
  final seconds = math.max(0, durationUs) / microsPerSecond;
  final segment = bps * (iosSegmentDurationUs / microsPerSecond) / 8;
  return (bps * seconds / 8 * containerOverhead + segment).toInt();
}

/// What a precomposed export of [encode] over [durationUs] (plan grid [gridFps]) needs on the work
/// volume beyond the single-pass check under one platform's [model]: Android
/// `max(2·I, I + output) − output`, iOS `2·I` (two intermediates alive at once; the export segment
/// is part of the single-pass check).
int precomposeExtraBytesFor(PrecomposeDiskModel model, EncodeSettings encode, TimeUs durationUs, int gridFps) {
  switch (model) {
    case PrecomposeDiskModel.android:
      final output = estimateEncodeBytes(encode, durationUs);
      final i = precomposeIntermediateBytes(videoBitrate: encode.videoBitrate, durationUs: durationUs, gridFps: gridFps);
      return math.max(2 * i, i + output) - output;
    case PrecomposeDiskModel.ios:
      return 2 * iosPrecomposeIntermediateBytes(encode, durationUs);
  }
}

/// What a precomposed export of [encode] over [durationUs] (plan grid [gridFps]) needs on the work
/// volume beyond the single-pass estimate: the maximum of [precomposeExtraBytesFor] over every
/// platform, so the preflight never asks for less than the engine's own disk check.
int precomposeExtraBytesOf(EncodeSettings encode, TimeUs durationUs, int gridFps) => PrecomposeDiskModel.values
    .map((m) => precomposeExtraBytesFor(m, encode, durationUs, gridFps))
    .reduce(math.max);
