// OWNER: API-01
//
// Thumbnails, waveforms and background media jobs (ARCH §12.3, §15). `MediaJobs.renderPreview` is
// the D-45 render-preview job, added by INT-06 (the lead-approved amendment of the frozen surface).

import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart' show RenderPlan;

import 'engine.dart';

/// Scheduling priority of a thumbnail tile.
///
/// See ARCH §12.3, §15.
enum ThumbPriority {
  /// On screen now.
  visible,

  /// Just outside the viewport.
  prefetch,

  /// Anything else.
  background,
}

/// One thumbnail strip request: [framesPerTile] frames every [intervalMs] starting at tile
/// [tileIndex].
///
/// See ARCH §12.3, §15.
@immutable
final class ThumbnailRequest {
  /// Creates a request.
  const ThumbnailRequest({
    required this.media,
    required this.intervalMs,
    required this.tileIndex,
    required this.heightPx,
    this.framesPerTile = 8,
    this.proxy = false,
  });

  /// Media.
  final EngineMedia media;

  /// Source interval between frames in ms.
  final int intervalMs;

  /// Tile index (tile i starts at `i·framesPerTile·intervalMs`).
  final int tileIndex;

  /// Frame height in px.
  final int heightPx;

  /// Frames per strip (8).
  final int framesPerTile;

  /// Decode from the proxy.
  final bool proxy;
}

/// A JPEG strip of [frames] frames, each [frameWidthPx] wide.
///
/// See ARCH §12.3, §15.
@immutable
final class ThumbnailTile {
  /// Creates a tile.
  const ThumbnailTile({required this.encoded, required this.frames, required this.frameWidthPx});

  /// JPEG bytes of the whole strip.
  final Uint8List encoded;

  /// Frames in the strip.
  final int frames;

  /// Width of one frame in px.
  final int frameWidthPx;
}

/// A cancellable thumbnail request.
///
/// See ARCH §12.3, §15.
abstract interface class ThumbnailHandle {
  /// The tile (throws `EngineFailure` on failure, `EngineCancelled` when cancelled).
  Future<ThumbnailTile> get result;

  /// Cancels (no-op when done).
  void cancel();
}

/// Thumbnail strips (disk-cached natively under `<cache>/danaview/editor/thumbs`).
///
/// See ARCH §12.3, §15.
abstract interface class ThumbnailSource {
  /// Requests one tile.
  ThumbnailHandle request(ThumbnailRequest request, {required ThumbPriority priority});
}

/// Waveform peaks: interleaved int8 (min, max) pairs at [pairsPerSecond] (200).
///
/// See ARCH §12.3, §15.
@immutable
final class WaveformPeaks {
  /// Creates peaks.
  const WaveformPeaks({required this.minMax, required this.duration, this.pairsPerSecond = 200});

  /// Interleaved min/max pairs.
  final Int8List minMax;

  /// Source duration covered.
  final TimeUs duration;

  /// Pairs per second (200).
  final int pairsPerSecond;
}

/// Waveforms (disk-cached natively as `.dvpk`).
///
/// See ARCH §12.3, §15.
abstract interface class WaveformSource {
  /// Peaks of one audio stream.
  MediaJob<WaveformPeaks> peaks(EngineMedia media, {int audioStream = 0});
}

/// Job scheduling priority (export and interactive jobs pre-empt background jobs).
///
/// See ARCH §12.3, §15.
enum JobPriority {
  /// User is waiting (freeze frame, reverse started from the panel).
  interactive,

  /// Default.
  normal,

  /// Proxies, prefetch.
  background,
}

/// A file produced by a job.
///
/// See ARCH §12.3, §15.
@immutable
final class GeneratedAsset {
  /// Creates the result.
  const GeneratedAsset({required this.path, required this.sizeBytes, this.duration});

  /// Absolute path under the Dart-supplied output location.
  final String path;

  /// Size in bytes.
  final int sizeBytes;

  /// Duration (video/audio outputs).
  final TimeUs? duration;
}

/// Proxy state of one media file.
///
/// See ARCH §12.3, §15.
enum ProxyStatus {
  /// No proxy and none queued.
  none,

  /// Queued.
  queued,

  /// Being generated.
  running,

  /// Ready (same timestamps as the original).
  ready,

  /// Generation failed.
  failed,
}

/// A request to extract 16 kHz s16 mono WAV for speech recognition (ai.md §7, D-28).
@immutable
final class SpeechAudioJobRequest {
  /// Creates a request.
  const SpeechAudioJobRequest({required this.media, required this.range, required this.outputPath, this.audioStream});

  /// Original media (never a proxy unless the original is offline).
  final EngineMedia media;

  /// Source range in µs; sample 0 corresponds exactly to `range.start`.
  final TimeRange range;

  /// Output WAV path under `<support>/danaview/speech/work/`.
  final String outputPath;

  /// Audio stream, null = first.
  final int? audioStream;
}

/// A speech WAV written by [MediaJobs.extractSpeechAudio].
///
/// See ARCH §12.3, §15.
@immutable
final class ExtractedSpeechAudio {
  /// Creates the result.
  const ExtractedSpeechAudio({
    required this.path,
    required this.frames,
    required this.duration,
    required this.sourceChannels,
    required this.sourceSampleRate,
    required this.codec,
  });

  /// WAV path.
  final String path;

  /// Sample frames written.
  final int frames;

  /// Duration.
  final TimeUs duration;

  /// Channels of the source stream.
  final int sourceChannels;

  /// Sample rate of the source stream.
  final int sourceSampleRate;

  /// Source codec name.
  final String codec;
}

/// Name of the render-preview cache directory below the editor cache root
/// (`<cache>/danaview/editor/renders/`, ARCH D-45(A)).
const String renderPreviewDirName = 'renders';

/// A running engine job.
///
/// See ARCH §12.3, §15.
abstract interface class MediaJob<T> {
  /// Job id.
  String get id;

  /// Progress 0..1 (≤ 4 Hz).
  Stream<double> get progress;

  /// Result (throws `EngineFailure`; `EngineCancelled` after [cancel]).
  Future<T> get result;

  /// Cancels and deletes partial output.
  void cancel();

  /// Changes the priority.
  void setPriority(JobPriority priority);
}

/// Background media jobs (proxies, reverse renditions, freeze stills, speech audio, render previews).
///
/// See ARCH §12.3, §15.
abstract interface class MediaJobs {
  /// 540p proxy with the same timestamps (`<cache>/danaview/editor/proxies/<quickHash>-540.mp4`).
  MediaJob<GeneratedAsset> proxy(EngineMedia media);

  /// Reversed rendition of [source] into [outputPath] (refuses ranges > 10 min with
  /// `LimitExceeded('reverseRange')`; checks free space first).
  MediaJob<GeneratedAsset> reverse(EngineMedia media, TimeRange source, {required String outputPath});

  /// PNG still of the frame at [sourceTime] (zero tolerance / EXACT).
  MediaJob<GeneratedAsset> freezeFrame(EngineMedia media, TimeUs sourceTime, {required String outputPath});

  /// 16 kHz s16 mono WAV, sample-accurate (±20 ms clap test).
  MediaJob<ExtractedSpeechAudio> extractSpeechAudio(SpeechAudioJobRequest request);

  /// Renders [rangePlan] into the render-preview file [outputPath] (ARCH D-45(A)).
  ///
  /// [rangePlan] is a preview plan (`PlanTarget.preview`) cut to one range, with times relative
  /// to the range start; [outputPath] lies inside `<cache>/danaview/editor/renders/`
  /// ([renderPreviewDirName]). The output is a video-only, preview-size H.264 file on the plan's
  /// frame grid. The job reports progress at ≤ 4 Hz; [MediaJob.cancel] deletes the partial file;
  /// failures are `EngineFailure`s (`planInvalid` for a plan the engine refuses). Until IOS-19 and
  /// AND-18 land, the mobile engine fails with `notSupportedOnDevice`. Default priority
  /// [JobPriority.background].
  MediaJob<GeneratedAsset> renderPreview(RenderPlan rangePlan, {required String outputPath});

  /// Proxy state of [media].
  ProxyStatus proxyStatus(EngineMedia media);
}
