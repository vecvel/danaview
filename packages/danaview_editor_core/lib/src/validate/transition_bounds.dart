// OWNER: CORE-08
//
// Transition length bounds (domain.md §6.5, BUILD_PLAN CORE-16) as the validator checks them for
// invariant I5. CORE-16's `TransitionLimits.of(project, ref)` (eval/transition_limits.dart) owns
// the public command-facing API and must agree with [TransitionBounds.maxFrames] (it may simply
// delegate to it), so commands never create a transition the validator rejects.
//
// For a transition of n frames at the cut c between `left` and `right` (window
// `[c − ⌊n/2⌋, c + ⌈n/2⌉)` frames):
//
// * all kinds: n ≤ 2·min(leftAvail, rightAvail), where `avail` is the clip's frame count minus the
//   part of the transition at its other edge that lies inside it (⌈m/2⌉ frames of the transition
//   at the left clip's start, ⌊p/2⌋ frames of the transition at the right clip's end);
// * overlap kinds (cross dissolve, slide, wipe, zoom) also n ≤ 2·min(leftHandle, rightHandle):
//   whole frames of unused source after the left clip's end and before the right clip's start at
//   the speed at that edge (mirrored for reversed clips); images and stills have unbounded
//   handles; a missing asset has no handle.

import '../eval/clip_time_map.dart';
import '../eval/speed_math.dart';
import '../model/items.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/speed_spec.dart';
import '../model/track.dart';
import '../model/transition.dart';
import '../time/time.dart';

/// Transition length bounds in frames (see the file header).
abstract final class TransitionBounds {
  /// Stands for an unbounded handle (images and stills).
  static const int unbounded = 1 << 40;

  /// Whole frames of [item] at [rate] (`frameIndexOf(end) − frameIndexOf(start)`).
  static int framesOf(TimelineItem item, FrameRate rate) => rate.frameIndexOf(item.end) - rate.frameIndexOf(item.start);

  /// Whether [speed] is usable by a time map (constant in [0.1, 10], or a valid ramp).
  static bool speedValid(SpeedSpec speed) => switch (speed) {
        ConstantSpeed(:final rate) => rate >= minClipSpeed && rate <= maxClipSpeed,
        SpeedRamp() => speedRampIssues(speed).isEmpty,
      };

  /// The largest transition (frames) of [kind] allowed between [left] and [right] on [track]
  /// (rules in the file header). The other transitions of [track] that touch `left`'s start or
  /// `right`'s end reduce the available frames. Returns 0 when nothing fits.
  static int maxFrames({
    required Track track,
    required MediaClip left,
    required MediaClip right,
    required TransitionKind kind,
    required FrameRate rate,
    required MediaPool pool,
  }) {
    var before = 0; // frames of the transition at left's start that lie inside left: ⌈m/2⌉
    var after = 0; // frames of the transition at right's end that lie inside right: ⌊p/2⌋
    for (final t in track.transitions) {
      if (t.right == left.id && t.left != left.id) before = (t.durationFrames + 1) ~/ 2;
      if (t.left == right.id && t.right != right.id) after = t.durationFrames ~/ 2;
    }
    return maxFramesBetween(
      left: left,
      right: right,
      kind: kind,
      rate: rate,
      pool: pool,
      framesBeforeInLeft: before,
      framesAfterInRight: after,
    );
  }

  /// [maxFrames] with the neighbouring transitions already resolved: [framesBeforeInLeft] frames
  /// of the transition at `left`'s start lie inside `left` (`⌈m/2⌉`, 0 when none) and
  /// [framesAfterInRight] frames of the transition at `right`'s end lie inside `right` (`⌊p/2⌋`).
  /// The validator resolves them for a whole track in one pass.
  static int maxFramesBetween({
    required MediaClip left,
    required MediaClip right,
    required TransitionKind kind,
    required FrameRate rate,
    required MediaPool pool,
    int framesBeforeInLeft = 0,
    int framesAfterInRight = 0,
  }) {
    final before = framesBeforeInLeft;
    final after = framesAfterInRight;
    final leftAvail = framesOf(left, rate) - (before < 0 ? 0 : before);
    final rightAvail = framesOf(right, rate) - (after < 0 ? 0 : after);
    var bound = 2 * (leftAvail < rightAvail ? leftAvail : rightAvail);
    if (kind.needsHandles) {
      final lh = handleFramesAfter(left, rate, pool);
      final rh = handleFramesBefore(right, rate, pool);
      final h = 2 * (lh < rh ? lh : rh);
      if (h < bound) bound = h;
    }
    return bound < 0 ? 0 : bound;
  }

  /// Whole frames of unused source after [clip]'s timeline end, played at the speed at that edge
  /// (source before `sourceIn` for reversed clips); [unbounded] for images and stills, 0 when the
  /// asset is missing or the speed is invalid.
  static int handleFramesAfter(MediaClip clip, FrameRate rate, MediaPool pool) =>
      _handle(clip, rate, pool, atEnd: true);

  /// Whole frames of unused source before [clip]'s timeline start, played at the speed at that
  /// edge (source after `sourceOut` for reversed clips); [unbounded] for images and stills, 0 when
  /// the asset is missing or the speed is invalid.
  static int handleFramesBefore(MediaClip clip, FrameRate rate, MediaPool pool) =>
      _handle(clip, rate, pool, atEnd: false);

  static int _handle(MediaClip clip, FrameRate rate, MediaPool pool, {required bool atEnd}) {
    final asset = pool[clip.media];
    if (asset == null) return 0;
    if (asset.kind == MediaKind.image || asset.kind == MediaKind.still) return unbounded;
    if (!speedValid(clip.speed) || clip.duration <= 0) return 0;
    final map = ClipTimeMap.forClip(clip, rate);
    final mediaEnd = asset.probe.duration;
    // Forward clips: the end edge continues after sourceOut, the start edge before sourceIn.
    // Reversed clips play the range backwards, so the sides swap.
    final useAfterOut = atEnd != clip.reversed;
    final available = useAfterOut ? mediaEnd - map.sourceOut : map.sourceIn;
    if (available <= 0) return 0;
    final speed = map.speedAt(atEnd ? clip.end : clip.start);
    if (!(speed > 0)) return 0;
    final timelineUs = available / speed;
    final frames = (timelineUs * rate.num / (microsPerSecond * rate.den)).floor();
    return frames > unbounded ? unbounded : frames;
  }
}
