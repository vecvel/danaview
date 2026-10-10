// OWNER: CORE-31
//
// Helpers of the CORE-31 lowering tests: standard-stage compiles, a fake sprite pre-pass
// (manifest entries sized from the request's estimate), a fixed-size text metrics provider, and
// project builders for text, cues and audio. The visual builders come from CORE-30's
// `compile_visual/support.dart`.

import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart';

import '../compile_visual/support.dart';

export '../compile_visual/support.dart';

/// Measures every spec as [size] layout px (a stand-in for API-04's `TextLayoutEngine`).
final class FixedMetrics implements TextMetricsProvider {
  /// Creates a provider.
  const FixedMetrics(this.size);

  /// The size of every block.
  final Size2 size;

  @override
  Size2 measure(TextLayoutSpec spec) => size;
}

/// A fake pre-pass: one file per request key, `sw × sh` = the block (measured by [metrics], else
/// estimated) times the request's scale, rounded up; `sscale` = the request's scale.
SpriteManifest fakeManifest(List<SpriteRequest> requests, {TextMetricsProvider? metrics}) {
  final files = <String, SpriteFile>{};
  for (final r in requests) {
    final block = metrics?.measure(_specOf(r)) ?? estimateTextBlockSize(_specOf(r));
    files[r.key] = SpriteFile(
      uri: 'file:///cache/vwish/editor/sprites/${r.key}.vsprite',
      sw: (block.width * r.scale).ceil().clamp(1, 1 << 20),
      sh: (block.height * r.scale).ceil().clamp(1, 1 << 20),
      sscale: r.scale,
      reveal: r.reveal,
    );
  }
  return SpriteManifest(files);
}

/// Rebuilds the spec of a request from its JSON (enough fields for the estimate).
TextLayoutSpec _specOf(SpriteRequest r) {
  final j = r.layoutSpec;
  final runs = [
    for (final run in (j['runs']! as List<Object?>).cast<Map<String, Object?>>())
      TextRun(run['text']! as String, bold: run['bold']! as bool, italic: run['italic']! as bool),
  ];
  return TextLayoutSpec(
    runs: runs,
    fontFamily: j['fontFamily']! as String,
    fontSizePx: (j['fontSizePx']! as num).toDouble(),
    color: j['color']! as int,
    letterSpacingPx: (j['letterSpacingPx']! as num).toDouble(),
    lineHeight: (j['lineHeight']! as num).toDouble(),
    maxWidthPx: (j['maxWidthPx']! as num).toDouble(),
    maxLines: j['maxLines'] as int?,
    scale: (j['scale']! as num).toDouble(),
    canvasWidth: j['canvasWidth']! as int,
    canvasHeight: j['canvasHeight']! as int,
  );
}

/// Compiles [p] for [target] with the standard stages; export plans get a fake manifest covering
/// every request (or [sprites]).
CompiledPlan compileStd(
  EditProject p,
  PlanTarget target, {
  PlanAssetResolver? resolver,
  PlanOutputSpec? output,
  SpriteManifest? sprites,
  Map<TrackId, bool> burnIn = const {},
  double maxAudioSpeed = defaultMaxAudioSpeed,
  bool holdFrame = true,
}) {
  final r = resolver ?? resolverFor(p);
  var manifest = sprites;
  if (manifest == null && target == PlanTarget.export) {
    final canvas = output == null
        ? p.settings.canvas.sizePx
        : Size2(output.width.toDouble(), output.height.toDouble());
    manifest = fakeManifest(collectSpriteRequests(p, canvas, exportScaleOf(p.settings.canvas, canvas), burnIn: burnIn));
  }
  return compilePlan(
    p,
    target,
    r,
    options: CompileOptions(
      output: output,
      holdFrame: holdFrame,
      stages: standardLoweringStages(sprites: manifest, burnIn: burnIn, maxAudioSpeed: maxAudioSpeed),
    ),
  );
}

/// A text item from frame [k0] to [k1] (30 fps).
TextItem textItem(
  String id,
  int k0,
  int k1, {
  String text = 'Hello',
  TextAnimation animation = TextAnimation.none,
  Transform2D transform = Transform2D.identity,
  KeyframeSet keyframes = KeyframeSet.empty,
  TextStyleSpec style = const TextStyleSpec(),
}) =>
    TextItem(
      id: ItemId(id),
      start: fr(k0),
      duration: fr(k1) - fr(k0),
      text: text,
      animation: animation,
      transform: transform,
      keyframes: keyframes,
      style: style,
    );

/// A subtitle cue from frame [k0] to [k1] (30 fps).
SubtitleCue cue(String id, int k0, int k1, String text) =>
    SubtitleCue(id: ItemId(id), start: fr(k0), duration: fr(k1) - fr(k0), text: text);

/// An audio clip from frame [k0] to [k1] (30 fps).
MediaClip audioClip(
  String id,
  int k0,
  int k1,
  String media, {
  TimeUs sourceIn = 0,
  AudioProps audio = AudioProps.unity,
  KeyframeSet keyframes = KeyframeSet.empty,
  SpeedSpec speed = SpeedSpec.normal,
  bool maintainPitch = true,
}) =>
    MediaClip(
      id: ItemId(id),
      start: fr(k0),
      duration: fr(k1) - fr(k0),
      media: MediaId(media),
      sourceIn: sourceIn,
      audio: audio,
      keyframes: keyframes,
      speed: speed,
      maintainPitch: maintainPitch,
    );

/// One keyframe channel.
KeyframeSet keys(String channel, List<(TimeUs, double)> ks) =>
    KeyframeSet({channel: KeyframeTrack([for (final (t, v) in ks) Keyframe(t, v)])});

/// A transition.
Transition transition(String id, String left, String right, TransitionKind kind, int frames, {TransitionDirection? direction}) =>
    Transition(
      id: TransitionId(id),
      left: ItemId(left),
      right: ItemId(right),
      kind: kind,
      durationFrames: frames,
      direction: direction,
    );
