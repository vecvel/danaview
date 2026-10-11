// OWNER: CORE-33
//
// Export compilation (ARCH §14.1 steps 2–4):
//
// 1. [resolveExportSettings]: preset (export_presets.dart) + user choices → `EncodeSettings`,
//    with the capability clamps — output size within `maxExportSize` (largest fitting short side
//    of 2160/1440/1080/720/540/480/360 at the same aspect), fps within `maxFpsByHeight` (halved
//    when that is a v1 rate within the limit, else the highest v1 rate within it), HEVC only with
//    `hevcEncode`, MOV only with `movContainer` — plus the notices the sheet shows (aspect
//    mismatch "Change project to 9:16": the project is letterboxed, never silently cropped) and
//    the size estimate `(video + audio bps)·seconds/8·1.02`;
// 2. [exportSpriteRequests]: what the sprite pre-pass must rasterize for those settings;
// 3. [compileExport]: the export plan from **original media only** (never proxies), on an
//    output canvas of the output size and fps with `gridFps` = the project rate, the project
//    canvas letterboxed inside, burned subtitle tracks per `settings.burnInSubtitles`, through the
//    standard lowering stages (transitions, sprites, audio). Returns [ExportBlocked] instead of a
//    plan when media is offline, a reverse or freeze still is pending, a sprite is missing from
//    the manifest, or the timeline is empty.

import 'package:meta/meta.dart';

import '../eval/geometry.dart';
import '../model/project.dart';
import '../model/settings.dart';
import '../time/time.dart';
import 'asset_resolver.dart';
import 'bitrate.dart';
import 'compiler.dart';
import 'encode_settings.dart';
import 'export_presets.dart';
import 'export_settings.dart';
import 'lowering_audio.dart';
import 'lowering_text.dart';
import 'lowering_transitions.dart';
import 'render_plan.dart';
import 'sprite_request.dart';
import 'sprite_requests.dart';

/// Why the export sheet shows a notice.
enum ExportNoticeCode {
  /// The output aspect differs from the project's: the project is letterboxed ("Change project
  /// to 9:16").
  aspectMismatch,

  /// The output size was reduced to the device's `maxExportSize`.
  resolutionClamped,

  /// The frame rate was reduced to the device's `maxFpsByHeight`.
  fpsClamped,

  /// HEVC was asked for but is unavailable; H.264 is used.
  hevcUnavailable,

  /// MOV was asked for but is unavailable; MP4 is used.
  movUnavailable,

  /// A custom bitrate was clamped to its range.
  bitrateClamped,
}

/// One notice of [resolveExportSettings].
@immutable
final class ExportNotice {
  /// Creates a notice.
  const ExportNotice(this.code, this.message, {this.suggestedAspect});

  /// Code.
  final ExportNoticeCode code;

  /// User-facing text.
  final String message;

  /// For [ExportNoticeCode.aspectMismatch]: the aspect to change the project to.
  final AspectRatio? suggestedAspect;

  @override
  bool operator ==(Object other) =>
      other is ExportNotice && other.code == code && other.message == message && other.suggestedAspect == suggestedAspect;

  @override
  int get hashCode => Object.hash(code, message, suggestedAspect);

  @override
  String toString() => 'ExportNotice(${code.name}: $message)';
}

/// The engine-level result of [resolveExportSettings].
@immutable
final class ResolvedExport {
  /// Creates a result.
  ResolvedExport({required this.encode, required List<ExportNotice> notices, required this.durationUs})
      : notices = List.unmodifiable(notices);

  /// What the engine encodes.
  final EncodeSettings encode;

  /// Notices for the sheet.
  final List<ExportNotice> notices;

  /// Timeline duration exported.
  final TimeUs durationUs;

  /// The output canvas.
  PlanOutputSpec get output => PlanOutputSpec(width: encode.width, height: encode.height, fps: encode.fps);

  /// Estimated file size in bytes: `(video + audio bps)·seconds/8·1.02`.
  int get estimatedBytes => estimateEncodeBytes(encode, durationUs);

  /// Whether the output aspect differs from the project's.
  bool get aspectMismatch => notices.any((n) => n.code == ExportNoticeCode.aspectMismatch);
}

/// The output size `(w, h)` of [aspect] with short side [shortSide] (even sides, the long side
/// rounded like `CanvasSpec`).
(int, int) outputSizeOf(AspectRatio aspect, int shortSide) {
  final c = CanvasSpec(aspect: aspect, baseShortSide: shortSide);
  return (c.widthPx, c.heightPx);
}

/// The aspect of [project]'s canvas.
AspectRatio projectAspectOf(EditProject project) => project.settings.canvas.aspect;

/// Whether two sizes differ in aspect by more than 1%.
bool aspectsDiffer(int w1, int h1, int w2, int h2) => ((w1 * h2) - (w2 * h1)).abs() > 0.01 * (w2 * h1);

/// The fps after the `maxFpsByHeight` clamp: [fps] when allowed; else half of it when that is a
/// v1 rate within [max]; else the highest v1 rate within [max] (24 at least).
int clampExportFps(int fps, int max) {
  if (fps <= max) return fps;
  if (fps.isEven && customFrameRates.contains(fps ~/ 2) && fps ~/ 2 <= max) return fps ~/ 2;
  var best = customFrameRates.first;
  for (final r in customFrameRates) {
    if (r <= max) best = r;
  }
  return best;
}

/// User-level [settings] → engine-level encode settings with presets, capability clamps,
/// notices and the size estimate (file header).
ResolvedExport resolveExportSettings(
  EditProject project,
  ExportSettings settings, {
  ExportCapabilities capabilities = const ExportCapabilities(),
}) {
  final caps = capabilities;
  final preset = ExportPreset.of(settings.preset);
  final notices = <ExportNotice>[];
  final projectFps = project.settings.frameRate.num;
  final pAspect = projectAspectOf(project);

  // Size.
  final aspect = preset.fixedAspect ?? pAspect;
  final wanted = preset.id == ExportPresetId.custom ? settings.shortSide : preset.shortSide!;
  var (w, h) = outputSizeOf(aspect, wanted);
  bool fits(int w, int h) {
    final long = w > h ? w : h;
    final short = w > h ? h : w;
    return long <= caps.maxExportLongSide && short <= caps.maxExportShortSide;
  }

  if (!fits(w, h)) {
    var done = false;
    for (final s in fallbackShortSides) {
      if (s >= wanted) continue;
      final (cw, ch) = outputSizeOf(aspect, s);
      if (fits(cw, ch)) {
        (w, h) = (cw, ch);
        done = true;
        break;
      }
    }
    if (!done) {
      // Smaller than every fallback: scale uniformly into the limits (even sides, ≥ 16).
      final long = w > h ? w : h;
      final short = w > h ? h : w;
      final k = [caps.maxExportLongSide / long, caps.maxExportShortSide / short].reduce((a, b) => a < b ? a : b);
      int even(double v) {
        final i = v.floor();
        final e = i.isEven ? i : i - 1;
        return e < 16 ? 16 : e;
      }

      (w, h) = (even(w * k), even(h * k));
    }
    notices.add(ExportNotice(ExportNoticeCode.resolutionClamped,
        'This device exports up to ${caps.maxExportShortSide}p, so the video is ${w < h ? w : h}p.'));
  }
  final shortSide = w < h ? w : h;

  // Aspect mismatch: letterboxed, never cropped.
  final pc = project.settings.canvas;
  if (aspectsDiffer(w, h, pc.widthPx, pc.heightPx)) {
    notices.add(ExportNotice(ExportNoticeCode.aspectMismatch, 'Change project to $aspect', suggestedAspect: aspect));
  }

  // Frame rate.
  final int fpsWanted = switch (preset.fps) {
    PresetFps.project => projectFps,
    PresetFps.thirty => 30,
    PresetFps.thirtyOrSixty => projectFps == 60 ? 60 : 30,
    PresetFps.custom => settings.fps ?? projectFps,
  };
  final maxFps = caps.maxFpsFor(shortSide);
  final fps = clampExportFps(fpsWanted, maxFps);
  if (fps != fpsWanted) {
    notices.add(ExportNotice(ExportNoticeCode.fpsClamped, 'This device exports ${shortSide}p at up to $maxFps fps, so the video is $fps fps.'));
  }

  // Codec and container.
  final wantHevc = switch (preset.codec) {
    PresetCodec.h264 => false,
    PresetCodec.hevcIfAvailable => true,
    PresetCodec.custom => settings.codec == VideoCodec.hevc,
  };
  var codec = wantHevc && caps.hevcEncode ? VideoCodec.hevc : VideoCodec.h264;
  if (codec == VideoCodec.h264 && !caps.h264Encode && caps.hevcEncode) codec = VideoCodec.hevc;
  if (wantHevc && codec != VideoCodec.hevc) {
    notices.add(const ExportNotice(ExportNoticeCode.hevcUnavailable, 'HEVC isn\'t available on this device, so H.264 is used.'));
  }
  var container = ExportContainer.mp4;
  if (preset.id == ExportPresetId.custom && settings.container == ExportContainer.mov) {
    if (caps.movContainer) {
      container = ExportContainer.mov;
    } else {
      notices.add(const ExportNotice(ExportNoticeCode.movUnavailable, 'MOV isn\'t available on this device, so MP4 is used.'));
    }
  }

  // Bitrates.
  final int videoBitrate;
  final custom = preset.id == ExportPresetId.custom ? settings.videoBitrateMbps : null;
  if (custom != null) {
    videoBitrate = customVideoBitrate(custom);
    if (custom < minCustomVideoMbps || custom > maxCustomVideoMbps) {
      notices.add(const ExportNotice(ExportNoticeCode.bitrateClamped, 'Video bitrate is between 2 and 100 Mbps.'));
    }
  } else if (preset.fixedVideoMbps != null) {
    videoBitrate = mbpsToBps(preset.fixedVideoMbps! * settings.quality.factor);
  } else {
    videoBitrate = autoVideoBitrate(shortSide: shortSide, fps: fps, codec: codec, quality: settings.quality);
  }
  final kbps = preset.id == ExportPresetId.custom ? settings.audioBitrateKbps ?? preset.audioKbps : preset.audioKbps;
  if (kbps < minAudioKbps || kbps > maxAudioKbps) {
    notices.add(const ExportNotice(ExportNoticeCode.bitrateClamped, 'Audio bitrate is between 96 and 320 kbps.'));
  }

  return ResolvedExport(
    encode: EncodeSettings(
      container: container,
      codec: codec,
      width: w,
      height: h,
      fps: fps,
      videoBitrate: videoBitrate,
      audioBitrate: audioBitrateOf(kbps),
    ),
    notices: notices,
    durationUs: project.duration,
  );
}

/// The sprite requests of an export of [project] with [settings] (the pre-pass input; pass the
/// same list to [compileExport]).
List<SpriteRequest> exportSpriteRequests(
  EditProject project,
  ExportSettings settings, {
  ExportCapabilities capabilities = const ExportCapabilities(),
  TextMetricsProvider? metrics,
  int fontsVersion = contentFontsVersion,
}) {
  final out = resolveExportSettings(project, settings, capabilities: capabilities).encode;
  final canvas = Size2(out.width.toDouble(), out.height.toDouble());
  return collectSpriteRequests(
    project,
    canvas,
    exportScaleOf(project.settings.canvas, canvas),
    maxTextureSize: capabilities.maxTextureSize,
    burnIn: settings.burnInSubtitles,
    metrics: metrics,
    fontsVersion: fontsVersion,
  );
}

/// The outcome of [compileExport].
@immutable
sealed class ExportCompileResult {
  const ExportCompileResult();
}

/// A renderable export plan.
final class ExportReady extends ExportCompileResult {
  /// Creates a result.
  const ExportReady({required this.plan, required this.resolved, required this.sprites});

  /// The export plan.
  final RenderPlan plan;

  /// Encode settings, notices and estimate.
  final ResolvedExport resolved;

  /// The sprite requests the plan's sprite layers come from.
  final List<SpriteRequest> sprites;

  /// What the engine encodes.
  EncodeSettings get encode => resolved.encode;
}

/// The export cannot start (ARCH §11.2 Requirements, §14.1 pre-checks).
final class ExportBlocked extends ExportCompileResult {
  /// Creates a blocked result.
  ExportBlocked({required this.requirements, List<String> missingSprites = const [], this.emptyTimeline = false})
      : missingSprites = List.unmodifiable(missingSprites);

  /// Offline media, pending reverses and pending freeze stills.
  final PlanRequirements requirements;

  /// Keys of sprite requests without a (suitable) manifest file: run the pre-pass first.
  final List<String> missingSprites;

  /// The timeline has nothing to export.
  final bool emptyTimeline;

  @override
  String toString() => 'ExportBlocked(offline: ${requirements.offline}, pendingReverse: ${requirements.pendingReverse}, '
      'pendingStill: ${requirements.pendingStill}, missingSprites: ${missingSprites.length}, empty: $emptyTimeline)';
}

/// Compiles the export plan of [project] with [settings] (file header). [sprites] is the
/// pre-pass manifest for [spriteRequests] (default [exportSpriteRequests] of the same inputs);
/// [resolver] resolves original media. Pure; callers run it in `Isolate.run` for large projects.
ExportCompileResult compileExport(
  EditProject project,
  ExportSettings settings,
  SpriteManifest sprites, {
  required PlanAssetResolver resolver,
  ExportCapabilities capabilities = const ExportCapabilities(),
  List<SpriteRequest>? spriteRequests,
  int? rev,
}) {
  final resolved = resolveExportSettings(project, settings, capabilities: capabilities);
  if (project.duration <= 0) return ExportBlocked(requirements: PlanRequirements(), emptyTimeline: true);
  final requests = spriteRequests ?? exportSpriteRequests(project, settings, capabilities: capabilities);
  final missing = <String>{
    for (final r in requests)
      if (sprites[r.key] == null || (r.reveal && !sprites[r.key]!.reveal)) r.key,
  }.toList();
  final compiled = compilePlan(
    project,
    PlanTarget.export,
    resolver,
    options: CompileOptions(
      rev: rev,
      output: resolved.output,
      holdFrame: capabilities.holdFrame,
      stages: [
        const TransitionLoweringStage(),
        TextLoweringStage(
          sprites: sprites,
          requests: requests,
          burnIn: settings.burnInSubtitles,
          maxTextureSize: capabilities.maxTextureSize,
        ),
        AudioLoweringStage(maxAudioSpeed: capabilities.maxAudioSpeed),
      ],
    ),
  );
  if (!compiled.isComplete || missing.isNotEmpty) {
    return ExportBlocked(requirements: compiled.requirements, missingSprites: missing);
  }
  return ExportReady(plan: compiled.plan, resolved: resolved, sprites: requests);
}
