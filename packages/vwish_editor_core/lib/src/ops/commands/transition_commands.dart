// OWNER: CORE-16
//
// Transition commands (ARCH §7.2, domain.md §6.5, D-16): `SetTransition` and
// `ApplyTransitionToAll`.
//
// * A transition lives on a video or overlay lane between two touching media clips; the cut is
//   addressed by a `TransitionRef(track, left, right)`.
// * The duration is in frames, centred on the cut: `[cut − ⌊n/2⌋, cut + ⌈n/2⌉)`.
// * Limits are `TransitionLimits` (the arithmetic the validator uses for I5): `SetTransition`
//   refuses a longer transition with `TransitionTooLong(maxFrames)`, or shortens it with
//   `clamp: true` (slider gestures); `ApplyTransitionToAll` clamps every cut to its own limit.
// * Kinds and directions (D-16): fade, crossDissolve, dipToBlack, dipToWhite take no direction;
//   slide and wipe take left/right/up/down (default left); zoom takes zoomIn/zoomOut (default
//   zoomIn). A direction on a kind without directions is ignored; one of the wrong family is
//   `InvalidValue('direction')`.
// * Edits that break adjacency (move, gap-creating trim, delete, split elsewhere) drop the
//   transition and re-clamp the ones that stay: that is the generic `finish()` of the framework,
//   not a command's business.

part of '../edit_command.dart';

/// What `SetTransition` and `ApplyTransitionToAll` put on a cut: a kind, a length in frames and
/// the direction of directional kinds (ux.md `TransitionSpec`).
@immutable
final class TransitionSpec {
  /// Creates a spec of [durationFrames] ≥ 1 frames.
  const TransitionSpec(this.kind, this.durationFrames, {this.direction});

  /// The kind.
  final TransitionKind kind;

  /// Length in project frames.
  final int durationFrames;

  /// Direction of slide, wipe (left/right/up/down) and zoom (zoomIn/zoomOut); null picks the
  /// default of the kind.
  final TransitionDirection? direction;

  /// The directions a kind accepts (empty: the kind has none).
  static List<TransitionDirection> directionsOf(TransitionKind kind) => switch (kind) {
        TransitionKind.slide || TransitionKind.wipe => const [
            TransitionDirection.left,
            TransitionDirection.right,
            TransitionDirection.up,
            TransitionDirection.down,
          ],
        TransitionKind.zoom => const [TransitionDirection.zoomIn, TransitionDirection.zoomOut],
        _ => const [],
      };

  /// The direction used when none is given.
  static TransitionDirection? defaultDirection(TransitionKind kind) {
    final all = directionsOf(kind);
    return all.isEmpty ? null : all.first;
  }

  /// A copy with the given fields replaced.
  TransitionSpec copyWith({TransitionKind? kind, int? durationFrames, TransitionDirection? direction}) =>
      TransitionSpec(kind ?? this.kind, durationFrames ?? this.durationFrames, direction: direction ?? this.direction);

  @override
  bool operator ==(Object other) =>
      other is TransitionSpec &&
      other.kind == kind &&
      other.durationFrames == durationFrames &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(kind, durationFrames, direction);

  @override
  String toString() => 'TransitionSpec(${kind.name}, ${durationFrames}f${direction == null ? '' : ', ${direction!.name}'})';
}

/// The direction a transition of [spec]'s kind stores, or an `InvalidValue('direction')` refusal.
TransitionDirection? _transitionDirection(_Draft d, TransitionSpec spec) {
  final allowed = TransitionSpec.directionsOf(spec.kind);
  if (allowed.isEmpty) return null;
  final given = spec.direction;
  if (given == null) return allowed.first;
  if (!allowed.contains(given)) d.reject(const InvalidValue('direction'));
  return given;
}

/// The lane for a transition command: unlocked and a video or overlay lane.
Track _transitionLane(_Draft d, TrackId id) {
  final lane = d.editableTrack(id);
  if (lane.kind != TrackKind.video && lane.kind != TrackKind.overlay) d.reject(IncompatibleTrack(id));
  return lane;
}

/// The lane's transitions in cut order.
List<Transition> _inCutOrder(List<TimelineItem> items, Iterable<Transition> transitions) {
  final position = <ItemId, int>{for (var i = 0; i < items.length; i++) items[i].id: i};
  return [...transitions]..sort((a, b) => (position[a.left] ?? 0).compareTo(position[b.left] ?? 0));
}

// -------------------------------------------------------------------------------------------
// SetTransition
// -------------------------------------------------------------------------------------------

/// Puts [spec] on the cut [ref], replacing the transition already there; a null [spec] removes
/// it (removing where there is none is a no-op).
///
/// Rejections: `ItemNotFound` (lane or clip), `TrackLocked`, `IncompatibleTrack` (not a video or
/// overlay lane), `NotAdjacent` (the clips are not neighbours that touch), `InvalidValue`
/// (`duration` below one frame, wrong `direction`), `TransitionTooLong(maxFrames)` (0 when the
/// clips cannot take any). With [clamp] a too-long transition is shortened to the limit instead
/// (notice `transitionsShortened`); the cut that takes none still refuses.
final class SetTransition extends EditCommand {
  /// Creates the command.
  const SetTransition(this.ref, this.spec, {this.clamp = false});

  /// The cut.
  final TransitionRef ref;

  /// The transition, or null to remove it.
  final TransitionSpec? spec;

  /// Whether to shorten a too-long transition to its limit instead of refusing it.
  final bool clamp;

  @override
  String get label => spec == null ? 'Remove transition' : 'Set transition';

  @override
  void _apply(_Draft d) {
    final lane = _transitionLane(d, ref.track);
    final existing = lane.transitions.where((t) => t.left == ref.left && t.right == ref.right).firstOrNull;
    final wanted = spec;
    if (wanted == null) {
      if (existing == null) {
        if (lane.items.every((i) => i.id != ref.left)) d.reject(ItemNotFound(ref.left));
        if (lane.items.every((i) => i.id != ref.right)) d.reject(ItemNotFound(ref.right));
        return;
      }
      d.putTrack(lane.copyWith(transitions: [for (final t in lane.transitions) if (t != existing) t]));
      d.affected.addAll([ref.left, ref.right]);
      return;
    }

    if (wanted.durationFrames < 1) d.reject(const InvalidValue('duration'));
    final direction = _transitionDirection(d, wanted);
    final items = lane.items;
    final li = items.indexWhere((i) => i.id == ref.left);
    if (li < 0) d.reject(ItemNotFound(ref.left));
    final ri = items.indexWhere((i) => i.id == ref.right);
    if (ri < 0) d.reject(ItemNotFound(ref.right));
    final left = items[li];
    final right = items[ri];
    if (ri != li + 1 || left.end != right.start || left is! MediaClip || right is! MediaClip) {
      d.reject(const NotAdjacent());
    }

    final max = TransitionBounds.maxFrames(
      track: lane,
      left: left,
      right: right,
      kind: wanted.kind,
      rate: d.rate,
      pool: d.pool,
    );
    var frames = wanted.durationFrames;
    if (frames > max) {
      if (!clamp || max < 1) d.reject(TransitionTooLong(max));
      frames = max;
      d.notices.add(EditNotice(EditNoticeCodes.transitionsShortened, count: 1));
    }
    final next = Transition(
      id: existing?.id ?? d.ids.transitionId(),
      left: ref.left,
      right: ref.right,
      kind: wanted.kind,
      durationFrames: frames,
      direction: direction,
    );
    final others = [for (final t in lane.transitions) if (t != existing) t];
    d.putTrack(lane.copyWith(transitions: _inCutOrder(items, [...others, next])));
    d.affected.addAll([ref.left, ref.right]);
  }

  @override
  String toString() => 'SetTransition(${ref.track}: ${ref.left}|${ref.right}, $spec, clamp: $clamp)';
}

// -------------------------------------------------------------------------------------------
// ApplyTransitionToAll
// -------------------------------------------------------------------------------------------

/// Puts [spec] on every cut of a lane in one command ("Apply to all cuts"); a null [spec]
/// removes every transition of the lane. [track] defaults to the main lane. Each cut is clamped to
/// its own limit (notice `transitionsShortened` with the number of clamped cuts); a cut that
/// cannot take even one frame is left as it is (notice `itemsSkipped` with the right-hand clips).
/// A lane without cuts is a no-op.
///
/// Rejections: `ItemNotFound` (no lane), `TrackLocked`, `IncompatibleTrack`, `InvalidValue`
/// (`duration`, `direction`).
final class ApplyTransitionToAll extends EditCommand {
  /// Creates the command.
  const ApplyTransitionToAll(this.spec, {this.track});

  /// The transition for every cut, or null to remove them all.
  final TransitionSpec? spec;

  /// The lane, or null for the main lane.
  final TrackId? track;

  @override
  String get label => spec == null ? 'Remove all transitions' : 'Apply transition to all cuts';

  @override
  void _apply(_Draft d) {
    final id = track ?? d.mainTrack?.id;
    if (id == null) d.reject(const ItemNotFound('track'));
    final lane = _transitionLane(d, id);
    final wanted = spec;
    final cuts = TransitionLimits.cutsOf(lane);
    if (wanted == null) {
      if (lane.transitions.isEmpty) return;
      d.affected.addAll([for (final t in lane.transitions) ...[t.left, t.right]]);
      d.putTrack(lane.copyWith(transitions: const []));
      return;
    }
    if (wanted.durationFrames < 1) d.reject(const InvalidValue('duration'));
    final direction = _transitionDirection(d, wanted);
    if (cuts.isEmpty) return;

    final items = lane.items;
    final byId = <ItemId, MediaClip>{
      for (final i in items)
        if (i is MediaClip) i.id: i,
    };
    final existing = <(ItemId, ItemId), Transition>{for (final t in lane.transitions) (t.left, t.right): t};
    final chosen = <Transition>[];
    var clamped = 0;
    final skipped = <ItemId>{};
    var prevFrames = 0; // frames of the transition at the previous cut (chosen, or kept)
    for (var i = 0; i < cuts.length; i++) {
      final cut = cuts[i];
      final left = byId[cut.left]!;
      final right = byId[cut.right]!;
      final chained = i > 0 && cuts[i - 1].right == cut.left;
      final nextChained = i + 1 < cuts.length && cuts[i + 1].left == cut.right;
      final before = chained ? (prevFrames + 1) ~/ 2 : 0;
      int limit(int n) => TransitionBounds.maxFramesBetween(
            left: left,
            right: right,
            kind: wanted.kind,
            rate: d.rate,
            pool: d.pool,
            framesBeforeInLeft: before,
            framesAfterInRight: nextChained ? n ~/ 2 : 0,
          );
      // The longest n ≤ requested that fits when the next cut gets the same length (the check is
      // monotone: a longer n leaves less room). The generic normalization afterwards settles any
      // asymmetry between neighbours.
      var n = wanted.durationFrames;
      if (limit(n) < n) {
        var lo = 0;
        var hi = n - 1;
        while (lo < hi) {
          final mid = (lo + hi + 1) >> 1;
          if (limit(mid) >= mid) {
            lo = mid;
          } else {
            hi = mid - 1;
          }
        }
        n = lo;
      }
      final old = existing[(cut.left, cut.right)];
      if (n < 1) {
        skipped.add(cut.right);
        prevFrames = old?.durationFrames ?? 0;
        if (old != null) chosen.add(old);
        continue;
      }
      if (n < wanted.durationFrames) clamped++;
      prevFrames = n;
      chosen.add(Transition(
        id: old?.id ?? d.ids.transitionId(),
        left: cut.left,
        right: cut.right,
        kind: wanted.kind,
        durationFrames: n,
        direction: direction,
      ));
    }
    if (clamped > 0) d.notices.add(EditNotice(EditNoticeCodes.transitionsShortened, count: clamped));
    if (skipped.isNotEmpty) d.notices.add(EditNotice(EditNoticeCodes.itemsSkipped, items: skipped, count: skipped.length));
    for (final c in cuts) {
      if (existing[(c.left, c.right)] != chosen.where((t) => t.left == c.left && t.right == c.right).firstOrNull) {
        d.affected.addAll([c.left, c.right]);
      }
    }
    d.putTrack(lane.copyWith(transitions: chosen));
  }

  @override
  String toString() => 'ApplyTransitionToAll($spec, track: $track)';
}
