// OWNER: CORE-16
//
// Transition limits as the editor and the commands see them (ARCH §7.2, domain.md §6.5):
// `TransitionLimits.of(project, ref)` is what ux.md §10.12 reads as `maxAllowed`.
//
// For a transition of n frames at the cut between `left` and `right` (window
// `[cut − ⌊n/2⌋, cut + ⌈n/2⌉)` frames):
//
// * all kinds: n ≤ 2·min(leftAvail, rightAvail), each half of the window lies inside its own clip;
//   `avail` is the clip's frame count minus the part of a neighbouring transition at its other
//   edge;
// * overlap kinds (cross dissolve, slide, wipe, zoom) also n ≤ 2·min(leftHandle, rightHandle):
//   whole frames of unused source after the left clip and before the right clip, at the speed at
//   that edge (mirrored for reversed clips); images and stills have unbounded handles;
// * transitions exist only on video and overlay lanes, between touching media clips.
//
// The arithmetic is `TransitionBounds` (validate/transition_bounds.dart), the one the validator
// uses for invariant I5, so a command can never create a transition the validator refuses.

import '../model/items.dart';
import '../model/project.dart';
import '../model/track.dart';
import '../model/transition.dart';
import '../validate/transition_bounds.dart';

/// Longest allowed transitions (see the file header).
abstract final class TransitionLimits {
  /// Stands for "no limit" (a cut between images or stills).
  static const int unbounded = TransitionBounds.unbounded;

  /// The longest transition (frames) of [kind] at [ref], 0 when none fits or [ref] does not name
  /// touching neighbours on a video or overlay lane. [kind] defaults to the kind of the
  /// transition already at the cut, else to the most restrictive kind (a cross dissolve, which
  /// needs handles). The transition currently at the cut is not counted against itself; its
  /// neighbours' transitions are.
  static int of(EditProject project, TransitionRef ref, {TransitionKind? kind}) {
    final pair = _pair(project, ref);
    if (pair == null) return 0;
    final (track, left, right) = pair;
    kind ??= _existing(track, ref)?.kind ?? TransitionKind.crossDissolve;
    return TransitionBounds.maxFrames(
      track: track,
      left: left,
      right: right,
      kind: kind,
      rate: project.settings.frameRate,
      pool: project.pool,
    );
  }

  /// [of] for every kind (the transitions panel shows one slider range per tile).
  static Map<TransitionKind, int> ofAll(EditProject project, TransitionRef ref) =>
      {for (final k in TransitionKind.values) k: of(project, ref, kind: k)};

  /// The transition at [ref], if any.
  static Transition? at(EditProject project, TransitionRef ref) {
    final loc = project.index.trackIndexOf(ref.track);
    if (loc == null) return null;
    return _existing(project.tracks[loc], ref);
  }

  /// Every cut of [track] that can take a transition: consecutive touching media clips on a video
  /// or overlay lane, in time order. Empty for other lanes.
  static List<TransitionRef> cutsOf(Track track) {
    if (track.kind != TrackKind.video && track.kind != TrackKind.overlay) return const [];
    final out = <TransitionRef>[];
    final items = track.items;
    for (var i = 0; i + 1 < items.length; i++) {
      final a = items[i];
      final b = items[i + 1];
      if (a is MediaClip && b is MediaClip && a.end == b.start) out.add(TransitionRef(track.id, a.id, b.id));
    }
    return out;
  }

  /// Whether [ref] names touching neighbouring media clips on a video or overlay lane.
  static bool isCut(EditProject project, TransitionRef ref) => _pair(project, ref) != null;

  static Transition? _existing(Track track, TransitionRef ref) {
    for (final t in track.transitions) {
      if (t.left == ref.left && t.right == ref.right) return t;
    }
    return null;
  }

  static (Track, MediaClip, MediaClip)? _pair(EditProject project, TransitionRef ref) {
    final ti = project.index.trackIndexOf(ref.track);
    if (ti == null) return null;
    final track = project.tracks[ti];
    if (track.kind != TrackKind.video && track.kind != TrackKind.overlay) return null;
    final items = track.items;
    for (var i = 0; i + 1 < items.length; i++) {
      final a = items[i];
      if (a.id != ref.left) continue;
      final b = items[i + 1];
      if (b.id == ref.right && a is MediaClip && b is MediaClip && a.end == b.start) return (track, a, b);
      return null;
    }
    return null;
  }
}
