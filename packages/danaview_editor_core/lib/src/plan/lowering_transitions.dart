// OWNER: CORE-31
//
// Transition lowering (ARCH §11.7, D-01, D-16): the seven owner transitions become plain layer
// edits, so engines contain no transition code.
//
// A transition of n frames at the cut c (frame index of `left.end`) covers the window
// `[w0, w1) = [timeOfFrame(c − ⌊n/2⌋), timeOfFrame(c + ⌈n/2⌉))` (ARCH §6.6, the window
// `TransitionLimits` and `packingInputsOf` use). Every edge stays on the project grid.
//
// | Kind              | Lowered to                                                                 |
// |-------------------|----------------------------------------------------------------------------|
// | Fade              | left `xf.op` ×(1→0) over [w0, c]; right ×(0→1) over [c, w1]; no overlap    |
// | Cross dissolve    | left extended to w1, right back to w0 (handles at the edge speed, [extendMap]); right on top (later t0) with `xf.op` ×(0→1) over [w0, w1] |
// | Dip to black/white| a `<left>#tx0` solid at lane z + 5 covering the project canvas, `xf.op` 0→1 over [w0, c] then 1→0 over [c, w1]; no overlap |
// | Slide (dir u)     | extended; incoming `xf.cx/cy` from off-canvas to final, outgoing from final to off-canvas along u (ease-in-out cubic, 8 linear segments) |
// | Wipe (dir u)      | extended; a `cmasks` rect on the incoming layer sweeps across the canvas along u (linear), feather 2% of the canvas dimension |
// | Zoom in/out       | extended; in: outgoing `xf.s` ×(1→1.25) and `op` ×(1→0), incoming `xf.s` ×(0.8→1) and `op` ×(0→1); out mirrors (outgoing ×(1→0.8), incoming ×(1.25→1)) |
//
// "Off-canvas" and "the canvas" mean the project canvas as it sits on the plan canvas (the
// letterboxed content rect of an export). Helper channels are merged with the user's keyframes
// on a merged breakpoint set ([composeChannel]): opacity and scale multiply, translation adds.
// Where two multiplied factors vary at once the product is sampled at every project frame start
// in between (exact at frame times, which is where engines evaluate, D-35). Every layer of a clip
// (`#v` and the `#bd` backdrop of a main-lane clip under `BlurOfMain`) gets the same edits.
//
// Direction defaults: slide and wipe `left`, zoom `zoomIn` (CORE-16). Direction vectors (y down):
// left (−1, 0), right (1, 0), up (0, −1), down (0, 1); a slide `left` moves both pictures toward
// the left, a wipe `left` moves the revealing edge toward the left.
//
// [transitionWindowsOf] and [clipExtentsOf] are shared with the audio lowering
// (`lowering_audio.dart`), so a clip's video layer and its audio segment always span the same
// extended range with the same map (A/V sync contract, ARCH §11.5).
//
// The file also offers [standardLoweringStages]: the CORE-31 stages in their required order
// (transitions, then text and subtitle sprites, then audio).

import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../eval/geometry.dart';
import '../ids/ids.dart';
import '../model/items.dart';
import '../model/track.dart';
import '../model/transition.dart';
import '../time/time.dart';
import 'compiler.dart';
import 'lowering_audio.dart';
import 'lowering_text.dart';
import 'lowering_visual.dart';
import 'render_plan.dart';
import 'sprite_request.dart';

/// Scale reached by the zooming picture of a zoom transition (in: outgoing grows to it; out:
/// incoming starts from it).
const double zoomTransitionLarge = 1.25;

/// Scale of the shrinking picture of a zoom transition (in: incoming starts from it; out:
/// outgoing shrinks to it).
const double zoomTransitionSmall = 0.8;

/// Feather of a wipe edge as a fraction of the canvas dimension along the sweep.
const double wipeFeatherFraction = 0.02;

/// Linear segments a slide's ease-in-out cubic is sampled at.
const int slideEaseSegments = 8;

/// Most samples added inside one interval where two multiplied channel factors vary at once.
const int maxProductSamplesPerInterval = 64;

/// `x < ½ ? 4x³ : 1 − (−2x + 2)³ / 2` for x in [0, 1] (clamped).
double easeInOutCubic(double x) {
  final c = x <= 0 ? 0.0 : (x >= 1 ? 1.0 : x);
  if (c < 0.5) return 4 * c * c * c;
  final r = -2 * c + 2;
  return 1 - r * r * r / 2;
}

/// The CORE-31 lowering stages in their required order: transitions (they extend and animate the
/// clip layers), text items and burned subtitle cues (export only, [TextLoweringStage]), then
/// audio ([AudioLoweringStage], which reads the extended clip layers).
///
/// [sprites] is the export's sprite manifest (export plans need an entry for every request of
/// [collectSpriteRequests]; `compileExport` checks that first). [burnIn] overrides the per-track
/// burn-in default of subtitle tracks. [maxAudioSpeed] is `capabilities.maxAudioSpeed` (D-15).
/// [memo] and [transitionMemo] let the stages reuse unchanged segments and edited layers (CORE-32's
/// `PlanMemo`).
List<PlanLoweringStage> standardLoweringStages({
  SpriteManifest? sprites,
  Map<TrackId, bool> burnIn = const {},
  double maxAudioSpeed = defaultMaxAudioSpeed,
  AudioSegMemo? memo,
  TransitionLayerMemo? transitionMemo,
}) =>
    [
      TransitionLoweringStage(memo: transitionMemo),
      TextLoweringStage(sprites: sprites ?? SpriteManifest.empty, burnIn: burnIn),
      AudioLoweringStage(maxAudioSpeed: maxAudioSpeed, memo: memo),
    ];

// ---------------------------------------------------------------------------------------------
// Windows and extents (shared with audio).
// ---------------------------------------------------------------------------------------------

/// One transition resolved against its lane: the clips, the cut and the window on the grid.
@immutable
final class TransitionWindow {
  /// Creates a window.
  const TransitionWindow({
    required this.transition,
    required this.left,
    required this.right,
    required this.cut,
    required this.w0,
    required this.w1,
  });

  /// The model transition.
  final Transition transition;

  /// Outgoing clip.
  final MediaClip left;

  /// Incoming clip.
  final MediaClip right;

  /// The cut (`left.end == right.start`).
  final TimeUs cut;

  /// Window start `timeOfFrame(c − ⌊n/2⌋)`.
  final TimeUs w0;

  /// Window end `timeOfFrame(c + ⌈n/2⌉)`.
  final TimeUs w1;

  /// Kind.
  TransitionKind get kind => transition.kind;

  /// Whether the clips overlap during the window (cross dissolve, slide, wipe, zoom).
  bool get overlaps => transition.kind.needsHandles;

  @override
  bool operator ==(Object other) =>
      other is TransitionWindow &&
      other.transition == transition &&
      identical(other.left, left) &&
      identical(other.right, right) &&
      other.cut == cut &&
      other.w0 == w0 &&
      other.w1 == w1;

  @override
  int get hashCode => Object.hash(transition, left.id, right.id, cut, w0, w1);
}

/// The windows of [track]'s transitions on the grid of [rate], in cut order. Transitions whose
/// clips are missing, are not media clips, do not touch, or that have no frames are skipped (a
/// validated project has none of those).
List<TransitionWindow> transitionWindowsOf(Track track, FrameRate rate) {
  if (track.transitions.isEmpty) return const [];
  if (track.kind != TrackKind.video && track.kind != TrackKind.overlay) return const [];
  final byId = <ItemId, MediaClip>{
    for (final i in track.items)
      if (i is MediaClip) i.id: i,
  };
  final out = <TransitionWindow>[];
  for (final tr in track.transitions) {
    final n = tr.durationFrames;
    if (n <= 0) continue;
    final left = byId[tr.left];
    final right = byId[tr.right];
    if (left == null || right == null || left.end != right.start) continue;
    final c = rate.frameIndexOf(left.end);
    final w0 = rate.timeOfFrame(c - n ~/ 2);
    final w1 = rate.timeOfFrame(c + (n + 1) ~/ 2);
    out.add(TransitionWindow(transition: tr, left: left, right: right, cut: left.end, w0: w0, w1: w1));
  }
  out.sort((a, b) => a.cut.compareTo(b.cut));
  return out;
}

/// The timeline range each clip of [track] spans after overlap transitions extend it (the
/// outgoing clip to `w1`, the incoming clip back to `w0`); clips without an overlap transition
/// are absent. The same rule as `packingInputsOf` (CORE-36).
Map<ItemId, TimeRange> clipExtentsOf(Track track, FrameRate rate) {
  final windows = transitionWindowsOf(track, rate);
  if (windows.isEmpty) return const {};
  final out = <ItemId, TimeRange>{};
  for (final w in windows) {
    if (!w.overlaps) continue;
    final l = out[w.left.id] ?? w.left.range;
    out[w.left.id] = TimeRange(l.start, w.w1);
    final r = out[w.right.id] ?? w.right.range;
    out[w.right.id] = TimeRange(w.w0, r.end);
  }
  return out;
}

/// [layer]'s map re-covered over `[t0, t1)` (a transition extension): a `hold` layer gets a new
/// hold segment of the same frame, any other media layer the map extended at its edge rates
/// ([extendMap]). Non-media layers have no map.
List<MapSegment> extendLayerMap(PlanLayer layer, TimeUs t0, TimeUs t1, {TimeUs? sourceDurationUs}) {
  if (layer.kind != PlanLayerKind.media || layer.map.isEmpty) return layer.map;
  if (layer.t0 == t0 && layer.t1 == t1) return layer.map;
  if (layer.hold) return [holdSegment(t0, t1, layer.map.first.s0, sourceDurationUs: sourceDurationUs)];
  return extendMap(layer.map, t0: t0 < layer.t0 ? t0 : null, t1: t1 > layer.t1 ? t1 : null);
}

// ---------------------------------------------------------------------------------------------
// Channel composition (shared with text).
// ---------------------------------------------------------------------------------------------

/// How a helper channel combines with the layer's own value.
enum ChannelOp {
  /// value × helper (opacity, scale).
  multiply,

  /// value + helper (translation in canvas px).
  add,
}

/// A helper channel: linear keys in absolute µs (held outside), multiplied into or added to a
/// layer channel.
@immutable
final class ChannelHelper {
  /// Creates a helper; [keys] must be sorted with unique times and non-empty.
  ChannelHelper(this.op, List<AnimKey> keys) : keys = List.unmodifiable(keys);

  /// Multiply or add.
  final ChannelOp op;

  /// Keys.
  final List<AnimKey> keys;

  /// The helper value at [t].
  double at(TimeUs t) => evaluateAnimKeys(keys, t);

  bool _variesOn(TimeUs a, TimeUs b) => at(a) != at(b);

  @override
  bool operator ==(Object other) => other is ChannelHelper && other.op == op && _keysEqual(other.keys, keys);

  @override
  int get hashCode => Object.hash(op, keys.length);
}

bool _keysEqual(List<AnimKey> a, List<AnimKey> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Memo of transition-edited layers (CORE-32's `PlanMemo` implements it): keyed by the input
/// layer object's identity (memoized visual layers are identical across compiles) plus the edit.
abstract interface class TransitionLayerMemo {
  /// The edited layer stored for this very [input] under a key equal to [key], or null.
  PlanLayer? lookup(PlanLayer input, Object key);

  /// Remembers [output] for [input] under [key].
  void store(PlanLayer input, Object key, PlanLayer output);
}

/// The memo key of one clip edit.
@immutable
final class _EditKey {
  const _EditKey(this.t0, this.t1, this.helpers, this.cmasks, this.canvas, this.rate, this.sourceDurationUs);
  final TimeUs? t0;
  final TimeUs? t1;
  final Map<String, List<ChannelHelper>> helpers;
  final List<CanvasMask> cmasks;
  final PlanCanvas canvas;
  final FrameRate rate;
  final TimeUs? sourceDurationUs;

  @override
  bool operator ==(Object other) {
    if (other is! _EditKey ||
        other.t0 != t0 ||
        other.t1 != t1 ||
        other.canvas != canvas ||
        other.rate != rate ||
        other.sourceDurationUs != sourceDurationUs ||
        other.helpers.length != helpers.length ||
        other.cmasks.length != cmasks.length) {
      return false;
    }
    for (var i = 0; i < cmasks.length; i++) {
      if (other.cmasks[i] != cmasks[i]) return false;
    }
    for (final e in helpers.entries) {
      final o = other.helpers[e.key];
      if (o == null || o.length != e.value.length) return false;
      for (var i = 0; i < o.length; i++) {
        if (o[i] != e.value[i]) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(t0, t1, helpers.length, cmasks.length);
}

/// The plan channel `user(t) × Π multiply(t) + Σ add(t)` as linear keys, where `user` is [anim]
/// (when the layer animates the channel) or the constant [base]. Keys sit at the union of every
/// input's key times; where two multiplied factors vary within one interval (a non-linear
/// product), extra keys are added at each frame start of [rate] inside it (at most
/// [maxProductSamplesPerInterval]). Returns [anim] unchanged when [helpers] is empty.
List<AnimKey> composeChannel({
  List<AnimKey>? anim,
  required double base,
  required List<ChannelHelper> helpers,
  required FrameRate rate,
}) {
  if (helpers.isEmpty) return anim ?? [AnimKey(0, base)];
  final times = <TimeUs>{};
  if (anim != null) {
    for (final k in anim) {
      times.add(k.tUs);
    }
  }
  for (final h in helpers) {
    for (final k in h.keys) {
      times.add(k.tUs);
    }
  }
  final sorted = times.toList()..sort();
  double userAt(TimeUs t) => anim == null ? base : evaluateAnimKeys(anim, t);
  double valueAt(TimeUs t) {
    var v = userAt(t);
    for (final h in helpers) {
      if (h.op == ChannelOp.multiply) v *= h.at(t);
    }
    for (final h in helpers) {
      if (h.op == ChannelOp.add) v += h.at(t);
    }
    return v;
  }

  final all = <TimeUs>[];
  for (var i = 0; i < sorted.length; i++) {
    final a = sorted[i];
    all.add(a);
    if (i + 1 == sorted.length) break;
    final b = sorted[i + 1];
    var varying = anim != null && userAt(a) != userAt(b) ? 1 : 0;
    for (final h in helpers) {
      if (h.op == ChannelOp.multiply && h._variesOn(a, b)) varying++;
    }
    if (varying < 2) continue;
    // Non-linear product: sample at the frame starts strictly inside (a, b).
    var k = rate.frameIndexOf(a) + 1;
    var added = 0;
    while (added < maxProductSamplesPerInterval) {
      final t = rate.timeOfFrame(k);
      if (t >= b) break;
      if (t > a) {
        all.add(t);
        added++;
      }
      k++;
    }
  }
  return [for (final t in all) AnimKey(t, valueAt(t))];
}

/// The static value of [channel] on [layer] on a plan canvas of [canvas] (the `xf` defaults of
/// ARCH §11.2: a null centre is the canvas centre).
double staticChannelValue(PlanLayer layer, String channel, PlanCanvas canvas) {
  final xf = layer.xf;
  return switch (channel) {
    PlanChannels.xfCx => xf.cx ?? canvas.w / 2,
    PlanChannels.xfCy => xf.cy ?? canvas.h / 2,
    PlanChannels.xfS => xf.s,
    PlanChannels.xfR => xf.r,
    PlanChannels.xfOp => xf.op,
    _ => 0,
  };
}

/// Accumulated edits of one clip's layers.
final class _ClipEdit {
  TimeUs? t0;
  TimeUs? t1;
  final Map<String, List<ChannelHelper>> helpers = {};
  final List<CanvasMask> cmasks = [];

  void help(String channel, ChannelOp op, List<AnimKey> keys) => (helpers[channel] ??= []).add(ChannelHelper(op, keys));
}

// ---------------------------------------------------------------------------------------------
// The stage.
// ---------------------------------------------------------------------------------------------

/// Lowers the transitions of every visible video and overlay lane (file header). Runs first.
final class TransitionLoweringStage implements PlanLoweringStage {
  /// Creates the stage; [memo] reuses unchanged edited layers (CORE-32).
  const TransitionLoweringStage({this.memo});

  /// Memo of edited layers, or null.
  final TransitionLayerMemo? memo;

  @override
  void lower(PlanCompilation c) {
    final rate = c.project.settings.frameRate;
    final content = c.mapping.contentRect;
    for (final lane in c.lanes) {
      if (lane.hidden) continue;
      final kind = lane.track.kind;
      if (kind != TrackKind.video && kind != TrackKind.overlay) continue;
      final windows = transitionWindowsOf(lane.track, rate);
      if (windows.isEmpty) continue;
      final edits = <ItemId, _ClipEdit>{};
      for (final w in windows) {
        if (!c.clips.containsKey(w.left.id) || !c.clips.containsKey(w.right.id)) continue;
        final left = edits[w.left.id] ??= _ClipEdit();
        final right = edits[w.right.id] ??= _ClipEdit();
        if (w.overlaps) {
          left.t1 = w.w1;
          right.t0 = w.w0;
        }
        switch (w.kind) {
          case TransitionKind.fade:
            if (w.w0 < w.cut) left.help(PlanChannels.xfOp, ChannelOp.multiply, [AnimKey(w.w0, 1), AnimKey(w.cut, 0)]);
            right.help(PlanChannels.xfOp, ChannelOp.multiply, [AnimKey(w.cut, 0), AnimKey(w.w1, 1)]);
          case TransitionKind.crossDissolve:
            right.help(PlanChannels.xfOp, ChannelOp.multiply, [AnimKey(w.w0, 0), AnimKey(w.w1, 1)]);
          case TransitionKind.dipToBlack:
          case TransitionKind.dipToWhite:
            final solid = _dipSolid(c, lane.transitionHelperZ, w, content);
            c.layers[solid.id] = solid;
          case TransitionKind.slide:
            _slide(w, left, right, content);
          case TransitionKind.wipe:
            right.cmasks.add(wipeMask(w.transition.direction ?? TransitionDirection.left, w.w0, w.w1, content));
          case TransitionKind.zoom:
            final out = w.transition.direction == TransitionDirection.zoomOut;
            left.help(PlanChannels.xfS, ChannelOp.multiply,
                [AnimKey(w.w0, 1), AnimKey(w.w1, out ? zoomTransitionSmall : zoomTransitionLarge)]);
            left.help(PlanChannels.xfOp, ChannelOp.multiply, [AnimKey(w.w0, 1), AnimKey(w.w1, 0)]);
            right.help(PlanChannels.xfS, ChannelOp.multiply,
                [AnimKey(w.w0, out ? zoomTransitionLarge : zoomTransitionSmall), AnimKey(w.w1, 1)]);
            right.help(PlanChannels.xfOp, ChannelOp.multiply, [AnimKey(w.w0, 0), AnimKey(w.w1, 1)]);
        }
      }
      for (final e in edits.entries) {
        _apply(c, e.key, e.value, rate);
      }
    }
  }

  void _apply(PlanCompilation c, ItemId item, _ClipEdit edit, FrameRate rate) {
    final lowered = c.clips[item]!;
    for (final original in lowered.layers) {
      final layer = c.layers[original.id];
      if (layer == null) continue;
      final sourceDurationUs = layer.asset == null ? null : c.assets[layer.asset!]?.durUs;
      final m = memo;
      final key = m == null ? null : _EditKey(edit.t0, edit.t1, edit.helpers, edit.cmasks, c.canvas, rate, sourceDurationUs);
      var out = key == null ? null : m!.lookup(layer, key);
      if (out == null) {
        out = applyClipEdit(
          layer,
          t0: edit.t0,
          t1: edit.t1,
          helpers: edit.helpers,
          cmasks: edit.cmasks,
          canvas: c.canvas,
          rate: rate,
          sourceDurationUs: sourceDurationUs,
        );
        if (key != null) m!.store(layer, key, out);
      }
      c.layers[layer.id] = out;
    }
  }
}

/// [layer] with its range moved to `[t0, t1)` (null keeps an edge; media maps re-covered with
/// [extendLayerMap]), each channel of [helpers] composed into `anim` ([composeChannel]) and
/// [cmasks] appended. The same instance when nothing changes.
PlanLayer applyClipEdit(
  PlanLayer layer, {
  TimeUs? t0,
  TimeUs? t1,
  Map<String, List<ChannelHelper>> helpers = const {},
  List<CanvasMask> cmasks = const [],
  required PlanCanvas canvas,
  required FrameRate rate,
  TimeUs? sourceDurationUs,
}) {
  final nt0 = t0 ?? layer.t0;
  final nt1 = t1 ?? layer.t1;
  if (nt0 == layer.t0 && nt1 == layer.t1 && helpers.isEmpty && cmasks.isEmpty) return layer;
  var anim = layer.anim;
  if (helpers.isNotEmpty) {
    anim = {...layer.anim};
    for (final e in helpers.entries) {
      anim[e.key] = composeChannel(
        anim: layer.anim[e.key],
        base: staticChannelValue(layer, e.key, canvas),
        helpers: e.value,
        rate: rate,
      );
    }
  }
  return PlanLayer(
    id: layer.id,
    z: layer.z,
    seq: layer.seq,
    t0: nt0,
    t1: nt1,
    kind: layer.kind,
    asset: layer.asset,
    map: extendLayerMap(layer, nt0, nt1, sourceDurationUs: sourceDurationUs),
    hold: layer.hold,
    color: layer.color,
    base: layer.base,
    crop: layer.crop,
    xf: layer.xf,
    fx: layer.fx,
    anim: anim,
    cmasks: cmasks.isEmpty ? layer.cmasks : [...layer.cmasks, ...cmasks],
  );
}

/// The unit vector (y down) of a slide or wipe [direction]; zoom directions have none.
Offset2 transitionVector(TransitionDirection direction) => switch (direction) {
      TransitionDirection.left => const Offset2(-1, 0),
      TransitionDirection.right => const Offset2(1, 0),
      TransitionDirection.up => const Offset2(0, -1),
      TransitionDirection.down => const Offset2(0, 1),
      TransitionDirection.zoomIn || TransitionDirection.zoomOut => const Offset2(-1, 0),
    };

/// The [slideEaseSegments] + 1 sample times of a window `[w0, w1]`: `w0 + round((w1 − w0)·j/8)`.
List<TimeUs> slideSampleTimes(TimeUs w0, TimeUs w1) {
  final d = w1 - w0;
  final out = <TimeUs>[];
  for (var j = 0; j <= slideEaseSegments; j++) {
    final t = w0 + (d * j + slideEaseSegments ~/ 2) ~/ slideEaseSegments;
    if (out.isEmpty || out.last != t) out.add(t);
  }
  return out;
}

void _slide(TransitionWindow w, _ClipEdit left, _ClipEdit right, Rect2 content) {
  final v = transitionVector(w.transition.direction ?? TransitionDirection.left);
  final dist = v.dx != 0 ? content.width : content.height;
  final times = slideSampleTimes(w.w0, w.w1);
  final span = w.w1 - w.w0;
  double e(TimeUs t) => easeInOutCubic((t - w.w0) / span);
  if (v.dx != 0) {
    // Outgoing moves from 0 to v·dist; incoming from −v·dist to 0.
    left.help(PlanChannels.xfCx, ChannelOp.add, [for (final t in times) AnimKey(t, v.dx * dist * e(t))]);
    right.help(PlanChannels.xfCx, ChannelOp.add, [for (final t in times) AnimKey(t, -v.dx * dist * (1 - e(t)))]);
  } else {
    left.help(PlanChannels.xfCy, ChannelOp.add, [for (final t in times) AnimKey(t, v.dy * dist * e(t))]);
    right.help(PlanChannels.xfCy, ChannelOp.add, [for (final t in times) AnimKey(t, -v.dy * dist * (1 - e(t)))]);
  }
}

/// The canvas mask of a wipe toward [direction] over `[w0, w1]` on the [content] rect (plan px):
/// a rect 4 feathers larger than the content in both dimensions whose leading edge moves
/// linearly from one feather beyond the far side (nothing visible) to one feather beyond the near
/// side (everything visible); feather = [wipeFeatherFraction] of the content dimension along the
/// sweep. The static value is the end state.
CanvasMask wipeMask(TransitionDirection direction, TimeUs w0, TimeUs w1, Rect2 content) {
  final v = transitionVector(direction);
  final horizontal = v.dx != 0;
  final f = wipeFeatherFraction * (horizontal ? content.width : content.height);
  final w = content.width + 4 * f;
  final h = content.height + 4 * f;
  final cx = content.center.dx;
  final cy = content.center.dy;
  if (horizontal) {
    // left: the rect's left edge runs from right + f to left − f; right: its right edge from
    // left − f to right + f.
    final double from;
    final double to;
    if (v.dx < 0) {
      from = content.right + f + w / 2;
      to = content.left - f + w / 2;
    } else {
      from = content.left - f - w / 2;
      to = content.right + f - w / 2;
    }
    return CanvasMask(cx: to, cy: cy, w: w, h: h, feather: f, anim: {
      'cx': [AnimKey(w0, from), AnimKey(w1, to)],
    });
  }
  final double from;
  final double to;
  if (v.dy < 0) {
    from = content.bottom + f + h / 2;
    to = content.top - f + h / 2;
  } else {
    from = content.top - f - h / 2;
    to = content.bottom + f - h / 2;
  }
  return CanvasMask(cx: cx, cy: to, w: w, h: h, feather: f, anim: {
    'cy': [AnimKey(w0, from), AnimKey(w1, to)],
  });
}

PlanLayer _dipSolid(PlanCompilation c, int z, TransitionWindow w, Rect2 content) {
  final color = w.kind == TransitionKind.dipToWhite ? 0xFFFFFFFF : 0xFF000000;
  final centre = content.center;
  final keys = <AnimKey>[
    if (w.w0 < w.cut) AnimKey(w.w0, 0),
    AnimKey(w.cut, 1),
    AnimKey(w.w1, 0),
  ];
  return PlanLayer(
    id: PlanIds.transitionHelper(w.left.id, 0),
    z: z,
    t0: w.w0,
    t1: w.w1,
    kind: PlanLayerKind.solid,
    color: color,
    base: PlanSize(content.width, content.height),
    xf: PlanTransform(
      cx: centre.dx == c.canvas.w / 2 ? null : centre.dx,
      cy: centre.dy == c.canvas.h / 2 ? null : centre.dy,
    ),
    anim: {PlanChannels.xfOp: keys},
  );
}

/// The equal-power crossfade gains of an overlap window at [t]: (outgoing, incoming) =
/// `(cos(π/2·x), sin(π/2·x))`, `x = (t − w0)/(w1 − w0)` clamped to [0, 1].
(double, double) equalPowerGains(TimeUs t, TimeUs w0, TimeUs w1) {
  final x = ((t - w0) / (w1 - w0)).clamp(0.0, 1.0);
  final a = math.pi / 2 * x;
  return (math.cos(a), math.sin(a));
}
