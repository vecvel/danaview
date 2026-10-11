// OWNER: API-01
//
// Live preview contract (ARCH §12.2, §12.7, §13). Normative semantics:
// - `seq` increases with every seek, play and pause; each clock sample carries the `seq` of the
//   last command it reflects.
// - `seek(exact)` completes only after the composed frame for `frameIndexOf(t)` is in the
//   texture; engines identify the displayed frame with `frameIndexNearest` of its platform time
//   and report `displayedFrameTime = timeOfFrame(displayedFrame)` (D-35).
// - `seek(scrub)` may show any frame within ±1 GOP and still reports the displayed frame.
// - Transients never touch the plan revision, history or disk.

import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Size;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import 'engine.dart';
import 'failures.dart';

/// Preview render quality. `auto` lets the engine's quality governor step down and up.
///
/// See ARCH §12.2.
enum PreviewQuality {
  /// Governor-controlled.
  auto,

  /// Canvas size (capped by `maxPreviewLongSide`).
  full,

  /// Half size.
  half,

  /// Quarter size.
  quarter,
}

/// How to open a preview session.
///
/// See ARCH §12.2.
@immutable
final class PreviewConfig {
  /// Creates a config.
  const PreviewConfig({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.fps,
    this.quality = PreviewQuality.auto,
    this.useProxies = true,
  });

  /// Plan canvas width.
  final int canvasWidth;

  /// Plan canvas height.
  final int canvasHeight;

  /// Project frame rate.
  final int fps;

  /// Initial quality.
  final PreviewQuality quality;

  /// Use proxies when a plan asset carries `proxyUri`.
  final bool useProxies;
}

/// Seek precision.
///
/// See ARCH §12.2.
enum SeekKind {
  /// Frame-exact; completes when the exact frame is displayed.
  exact,

  /// Fast, may show a frame within ±1 GOP.
  scrub,
}

/// Special preview rendering modes (crop and chroma panels).
///
/// See ARCH §12.2.
@immutable
sealed class PreviewEditingMode {
  const PreviewEditingMode();

  /// Normal rendering.
  static const PreviewEditingMode normal = NormalPreviewMode();
}

/// Normal rendering.
///
/// See ARCH §12.2.
final class NormalPreviewMode extends PreviewEditingMode {
  /// Creates the mode.
  const NormalPreviewMode();
}

/// Shows the whole uncropped source of [item] for crop editing.
///
/// See ARCH §12.2.
final class CropSourceMode extends PreviewEditingMode {
  /// Creates the mode.
  const CropSourceMode(this.item);

  /// Item being cropped.
  final ItemId item;
}

/// Shows the chroma-key matte of [item].
///
/// See ARCH §12.2.
final class MatteMode extends PreviewEditingMode {
  /// Creates the mode.
  const MatteMode(this.item);

  /// Item being keyed.
  final ItemId item;
}

/// Preview lifecycle events.
///
/// See ARCH §12.2.
@immutable
sealed class PreviewEvent {
  const PreviewEvent();
}

/// The first frame of the session is on screen.
///
/// See ARCH §12.2.
final class PreviewFirstFrame extends PreviewEvent {
  /// Creates the event.
  const PreviewFirstFrame();
}

/// Playback stalled (decoder starvation).
///
/// See ARCH §12.2.
final class PreviewStalled extends PreviewEvent {
  /// Creates the event.
  const PreviewStalled();
}

/// Playback recovered after a stall or surface loss.
///
/// See ARCH §12.2.
final class PreviewRecovered extends PreviewEvent {
  /// Creates the event.
  const PreviewRecovered();
}

/// The quality governor stepped down to [quality].
///
/// See ARCH §12.2.
final class PreviewDegraded extends PreviewEvent {
  /// Creates the event.
  const PreviewDegraded(this.quality);

  /// New quality.
  final PreviewQuality quality;
}

/// The texture surface was lost (auto-recovered by the engine).
///
/// See ARCH §12.2.
final class PreviewSurfaceLost extends PreviewEvent {
  /// Creates the event.
  const PreviewSurfaceLost();
}

/// The session failed.
///
/// See ARCH §12.2.
final class PreviewFailedEvent extends PreviewEvent {
  /// Creates the event.
  const PreviewFailedEvent(this.failure);

  /// Why.
  final EngineFailure failure;
}

/// One clock sample (state changes + 10 Hz while playing; the UI extrapolates per vsync).
///
/// See ARCH §12.2.
@immutable
final class PreviewClock {
  /// Creates a sample.
  const PreviewClock({required this.time, required this.playing, required this.rate, required this.seq});

  /// Plan time of the displayed frame (`timeOfFrame(k)`, D-35).
  final TimeUs time;

  /// Whether playing.
  final bool playing;

  /// Playback rate (1 while playing, 0 when paused).
  final double rate;

  /// Command sequence number this sample reflects.
  final int seq;
}

/// Acknowledgement of a seek.
///
/// See ARCH §12.2.
@immutable
final class SeekAck {
  /// Creates an ack.
  const SeekAck({required this.requested, required this.displayedFrameTime, required this.displayedFrame, required this.seq});

  /// Requested time.
  final TimeUs requested;

  /// `timeOfFrame(displayedFrame)`.
  final TimeUs displayedFrameTime;

  /// Displayed frame index (`frameIndexNearest` of its platform time).
  final int displayedFrame;

  /// Command sequence number.
  final int seq;
}

/// Acknowledgement of a plan or patch.
///
/// See ARCH §12.2.
@immutable
final class PlanAck {
  /// Creates an ack.
  const PlanAck({required this.rev, required this.structural, required this.applyMs});

  /// Engine revision after applying.
  final int rev;

  /// Whether the platform composition was rebuilt.
  final bool structural;

  /// Time to apply in ms.
  final int applyMs;
}

/// A look to render as a still for the Filters panel.
///
/// See ARCH §12.2.
@immutable
final class LookSpec {
  /// Creates a look spec.
  const LookSpec({required this.id, required this.lutUri, required this.lutSize, this.intensity = 1});

  /// Look id (preset id or imported LUT media id).
  final String id;

  /// `file://` URI of the `.vlut`.
  final String lutUri;

  /// N of the `.vlut`.
  final int lutSize;

  /// Mix intensity [0, 1].
  final double intensity;
}

/// One live preview bound to a Flutter texture.
///
/// See ARCH §12.2, §12.7, §13.
abstract interface class PreviewSession {
  /// Flutter texture id (may back two `Texture` widgets: editor and fullscreen).
  int get textureId;

  /// Current rendered frame size, null before the first frame.
  ValueListenable<Size?> get frameSize;

  /// Replaces the whole plan (encoded in an isolate).
  Future<PlanAck> setPlan(RenderPlan plan);

  /// Applies a patch; throws [EngineFailure] `planOutOfSync` when `patch.from` ≠ the engine
  /// revision (PlanSync then resends the full plan once).
  Future<PlanAck> applyPatch(RenderPlanPatch patch);

  /// Fire-and-forget param-only override (≤ 1 per frame natively).
  void setTransient(ItemId item, PlanTransient transient);

  /// Drops the transient of [item].
  void clearTransient(ItemId item);

  /// Starts playback, optionally looping [loop].
  Future<void> play({TimeRange? loop});

  /// Pauses.
  Future<void> pause();

  /// Seeks to [t]; see the library comment for exact vs scrub semantics.
  Future<SeekAck> seek(TimeUs t, {SeekKind kind = SeekKind.exact});

  /// Changes the render quality.
  Future<void> setQuality(PreviewQuality quality);

  /// Uses proxies when available.
  Future<void> setUseProxies(bool on);

  /// Switches the editing mode.
  Future<void> setEditingMode(PreviewEditingMode mode);

  /// Shows one source frame (trim-edge preview); cleared by the next seek or play.
  Future<void> showSourceFrame(EngineMedia media, TimeUs sourceTime);

  /// Average colour of a 3×3 area of the **pre-key** source of [item] (eyedropper), or null.
  Future<Color?> sampleColor(ItemId item, Offset normalizedSourcePoint);

  /// JPEG stills of [item] at the playhead with each look applied.
  Future<List<Uint8List>> renderLookStills(ItemId item, List<LookSpec> looks, {required int heightPx});

  /// Redraws the current frame (after resume or a cache trim).
  Future<void> refresh();

  /// RGBA bytes of the displayed frame (debug/profile builds; QA barcode checks).
  Future<Uint8List> debugCaptureFrame();

  /// Clock samples.
  Stream<PreviewClock> get clock;

  /// Lifecycle events.
  Stream<PreviewEvent> get events;

  /// Releases the session and its texture.
  Future<void> dispose();
}
