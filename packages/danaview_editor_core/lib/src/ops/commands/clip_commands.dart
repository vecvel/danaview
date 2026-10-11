// OWNER: CORE-10
//
// Structural clip commands (ARCH §7.2, domain.md §6.2–6.3): `InsertMedia`, `MoveItems`,
// `TrimItem`, `SplitItems`, `DeleteItems`, `DeleteGap`.
//
// Rules shared by all of them:
// * every edge lands on the project grid (inputs are quantized: positions to the nearest frame,
//   split times down to the frame start, deltas to whole frames);
// * ripple affects the edited lanes plus the linked partners of moved items (D-10, ripple.dart);
//   non-ripple moves and inserts into occupied space go to the nearest free lane of the same kind,
//   creating one (D-11, `_Draft.placeGroup`); on the main lane with ripple on, inserts and moves
//   snap to the nearest cut;
// * link groups move, split and delete together; trims also trim the partners whose same edge
//   coincides (an extracted-audio clip follows its video), so a ripple trim keeps them in sync;
// * keyframes stay on their content (a head trim shifts them, a split partitions them with
//   boundary keys, keyframe_ops.dart); fades are clamped to half the clip and transitions whose
//   clips stop touching are dropped (generic `finish()` of the framework);
// * locked lanes refuse (`TrackLocked`); `clamp: true` gestures return the nearest valid result
//   and report it in `EditPreview.clampedTo`;
// * inserted images and stills last `EditPolicy.defaultImageUs`.
//
// **Trims keep content attached.** A media clip stores `(sourceIn, duration, speed)`. Trimming an
// edge keeps what the rest of the clip shows: a forward clip's head trim moves `sourceIn` by the
// source played in the trimmed time, a reversed clip's tail trim does the same (it plays the
// source backwards); speed ramps are cropped to the kept part, and extended past it at the edge
// speed (domain.md §4.5). The source range is limited to `[0, probe.duration]` for video and
// audio; images, stills, text and cues may be any length of at least one frame.

part of '../edit_command.dart';

/// How `InsertMedia` resolves occupied space.
enum InsertMode {
  /// Ripple when the project's ripple mode is on (`ViewState.rippleEnabled`), else [newLane].
  auto,

  /// Snap to a cut and push later items on the lane right (partners follow).
  ripple,

  /// Place at `at`; occupied space goes to the nearest free lane of the same kind (D-11).
  newLane,
}

/// The edge a `TrimItem` moves.
enum TrimEdge {
  /// The head (start) of the item.
  start,

  /// The tail (end) of the item.
  end,
}

/// An empty span of a lane (selected in the timeline and removed by `DeleteGap`).
@immutable
final class GapRef {
  /// Creates a gap reference.
  const GapRef(this.track, this.range);

  /// The lane.
  final TrackId track;

  /// The empty span.
  final TimeRange range;

  @override
  bool operator ==(Object other) => other is GapRef && other.track == track && other.range == range;

  @override
  int get hashCode => Object.hash(track, range);

  @override
  String toString() => 'GapRef($track, $range)';
}

// -------------------------------------------------------------------------------------------
// InsertMedia
// -------------------------------------------------------------------------------------------

/// Adds clips of [media] back to back at [at] (ARCH §7.2): full media for video and audio,
/// `defaultImageUs` for images and stills. Without [track] visual media goes to the main lane and
/// audio to the first audio lane of its role (music for audio files, voice for recordings).
final class InsertMedia extends EditCommand {
  /// Creates the command.
  InsertMedia(List<MediaId> media, this.at, {this.track, this.mode = InsertMode.auto}) : media = List.unmodifiable(media);

  /// The assets, in timeline order.
  final List<MediaId> media;

  /// Requested start (quantized to the nearest frame, ≥ 0).
  final TimeUs at;

  /// Target lane, or null for the default lane of the media kind.
  final TrackId? track;

  /// Occupied-space resolution.
  final InsertMode mode;

  @override
  String get label => media.length == 1 ? 'Add clip' : 'Add clips';

  @override
  void _apply(_Draft d) {
    if (media.isEmpty) d.reject(const InvalidValue('media'));
    final assets = <MediaAsset>[];
    for (final id in media) {
      final a = d.pool[id];
      if (a == null || a.status is FailedStatus) d.reject(MediaUnavailable(id));
      if (a.kind == MediaKind.lut) d.reject(const UnsupportedForKind('lut'));
      assets.add(a);
    }

    // The lane.
    Track lane;
    AudioRole? role;
    bool Function(Track)? accept;
    final explicit = track;
    if (explicit != null) {
      lane = d.editableTrack(explicit);
      for (final a in assets) {
        if (!_mediaFitsLane(a, lane.kind)) d.reject(IncompatibleTrack(lane.id));
      }
      role = lane.audioRole;
    } else if (assets.every((a) => _visualMedia(a.kind))) {
      final main = d.mainTrack;
      lane = main ?? d.track(d.createTrack(TrackKind.video));
      if (lane.locked) d.reject(TrackLocked(lane.id));
    } else if (assets.every((a) => a.kind == MediaKind.audio || a.kind == MediaKind.recording)) {
      role = assets.first.kind == MediaKind.recording ? AudioRole.voice : AudioRole.music;
      final wanted = role;
      accept = (t) => t.audioRole == wanted;
      Track? found;
      for (final t in d.tracks) {
        if (t.kind == TrackKind.audio && !t.locked && t.audioRole == wanted) {
          found = t;
          break;
        }
      }
      lane = found ?? d.track(d.createTrack(TrackKind.audio, role: wanted));
    } else {
      d.reject(const IncompatibleTrack());
    }

    final ripple = switch (mode) {
      InsertMode.auto => d.view.rippleEnabled,
      InsertMode.ripple => true,
      InsertMode.newLane => false,
    };
    var at0 = d.rate.quantizeNearest(at < 0 ? 0 : at);
    if (ripple) at0 = lane.isMain ? d.nearestCut(lane, at0) : d.cutAt(lane, at0);

    // Build the clips back to back.
    final visualLane = lane.kind == TrackKind.video || lane.kind == TrackKind.overlay;
    final clips = <TimelineItem>[];
    var k = d.frameOf(at0);
    for (final a in assets) {
      final int frames;
      if (_timeBased(a.kind)) {
        frames = d.framesFitting(k, a.probe.duration);
        if (frames < 1) d.reject(const BelowMinDuration());
      } else {
        frames = d.lengthFrames(d.policy.defaultImageUs);
      }
      clips.add(MediaClip(
        id: d.ids.itemId(),
        start: d.timeOf(k),
        duration: d.timeOf(k + frames) - d.timeOf(k),
        media: a.id,
        visual: visualLane ? VisualProps.neutral : null,
      ));
      k += frames;
    }
    final ids = {for (final c in clips) c.id};

    final TrackId used;
    if (ripple) {
      d.openGap([lane.id], d.timeOf(d.frameOf(at0)), k - d.frameOf(at0));
      final now = d.track(lane.id);
      if (!LanePlacement.isFree(now, [for (final c in clips) c.range])) {
        d.reject(WouldOverlap(lane.id, TimeRange(clips.first.start, clips.last.end)));
      }
      d.addItems(lane.id, clips);
      used = lane.id;
    } else {
      used = d.placeGroup(clips, kind: lane.kind, preferred: lane.id, role: role, accept: accept);
    }
    d.selection = SelectionHint(ids, primary: clips.first.id, lane: used);
  }

  @override
  String toString() => 'InsertMedia($media, at: $at, track: $track, mode: ${mode.name})';
}

bool _visualMedia(MediaKind k) => k == MediaKind.video || k == MediaKind.image || k == MediaKind.still;

/// Whether an asset can be placed on a lane of [kind] (I4 compatibility).
bool _mediaFitsLane(MediaAsset a, TrackKind kind) => switch (kind) {
      TrackKind.video || TrackKind.overlay => _visualMedia(a.kind),
      TrackKind.audio =>
        a.kind == MediaKind.audio || a.kind == MediaKind.recording || (a.kind == MediaKind.video && a.probe.hasAudio),
      TrackKind.text || TrackKind.subtitle => false,
    };

// -------------------------------------------------------------------------------------------
// MoveItems
// -------------------------------------------------------------------------------------------

/// Moves items by [delta] (whole frames), keeping their relative offsets; link partners move too.
///
/// * Non-ripple: each source lane's group goes back onto its lane (or [toTrack] for a
///   single-lane selection) when the space is free, else to the nearest free lane of the same
///   kind (D-11). Moving before 0 is refused (`InvalidValue('delta')`), or clamped with [clamp].
/// * Ripple: the gaps left at the source close (partners follow), then the group is
///   ripple-inserted at the target, whose position is measured in the timeline as it was before
///   the move (minus the closed space before it); on the main lane it snaps to the nearest cut.
final class MoveItems extends EditCommand {
  /// Creates the command.
  MoveItems(Set<ItemId> ids, this.delta, {this.toTrack, this.ripple = false, this.clamp = false}) : ids = Set.unmodifiable(ids);

  /// Items to move (link partners are added).
  final Set<ItemId> ids;

  /// Time offset (rounded to whole frames).
  final TimeUs delta;

  /// Destination lane for a single-lane selection (vertical move), or null.
  final TrackId? toTrack;

  /// Ripple mode (close at the source, insert at the target).
  final bool ripple;

  /// Return the nearest valid result instead of refusing.
  final bool clamp;

  @override
  String get label => ids.length == 1 ? 'Move clip' : 'Move clips';

  @override
  void _apply(_Draft d) {
    if (ids.isEmpty) d.reject(const InvalidValue('ids'));
    final given = [for (final id in ids) d.locate(id)];
    final all = d.withPartners(ids);
    final locs = [for (final id in all) d.locate(id)]..sort((a, b) => a.trackIndex != b.trackIndex
        ? a.trackIndex.compareTo(b.trackIndex)
        : a.item.start.compareTo(b.item.start));
    for (final l in locs) {
      if (l.track.locked) d.reject(TrackLocked(l.track.id));
    }
    var primaryIndex = given.first.trackIndex;
    for (final g in given) {
      if (g.trackIndex < primaryIndex) primaryIndex = g.trackIndex;
    }
    final primaryLane = d.tracks[primaryIndex];
    Track? target;
    final to = toTrack;
    if (to != null && to != primaryLane.id) {
      if (given.any((l) => l.track.id != primaryLane.id)) d.reject(IncompatibleTrack(to));
      target = d.editableTrack(to);
      if (!LanePlacement.compatibleKinds(primaryLane.kind, target.kind)) d.reject(IncompatibleTrack(to));
    }
    // Groups by source lane, in lane order, items in time order.
    final groups = <TrackId, List<TimelineItem>>{};
    for (final l in locs) {
      (groups[l.track.id] ??= <TimelineItem>[]).add(l.item);
    }
    // Transitions between moved clips travel with their group.
    final internal = <TrackId, List<Transition>>{
      for (final laneId in groups.keys)
        laneId: [
          for (final tr in d.track(laneId).transitions)
            if (all.contains(tr.left) && all.contains(tr.right)) tr,
        ],
    };
    final df = d.deltaFrames(delta);
    if (ripple) {
      _rippleMove(d, groups, internal, primaryLane.id, target, df);
    } else {
      _plainMove(d, groups, internal, primaryLane.id, target, df);
    }
    _checkLinksOnDistinctLanes(d, all);
    d.selection = SelectionHint(ids, primary: given.first.item.id);
  }

  void _plainMove(
    _Draft d,
    Map<TrackId, List<TimelineItem>> groups,
    Map<TrackId, List<Transition>> internal,
    TrackId primaryLane,
    Track? target,
    int requested,
  ) {
    var df = requested;
    var minK = 1 << 40;
    for (final g in groups.values) {
      for (final i in g) {
        final k = d.frameOf(i.start);
        if (k < minK) minK = k;
      }
    }
    var clamped = false;
    if (minK + df < 0) {
      if (!clamp) d.reject(const InvalidValue('delta'));
      df = -minK;
      clamped = true;
    }
    final all = {for (final g in groups.values) for (final i in g) i.id};
    d.removeItems(all);
    TrackId destOf(TrackId lane) => lane == primaryLane && target != null ? target.id : lane;

    if (d.policy.overlap == OverlapPolicy.reject) {
      // No other lane may be used: find a shift at which every group fits on its own lane.
      bool fits(int shift) => groups.entries.every((e) => LanePlacement.isFree(
            d.track(destOf(e.key)),
            [for (final i in e.value) TimeRange(d.timeOf(d.frameOf(i.start) + shift), d.timeOf(d.frameOf(i.end) + shift))],
          ));
      if (!fits(df)) {
        if (!clamp) {
          final g = groups.entries.first;
          final lane = d.track(destOf(g.key));
          for (final i in g.value) {
            final r = TimeRange(d.timeOf(d.frameOf(i.start) + df), d.timeOf(d.frameOf(i.end) + df));
            final hit = LanePlacement.firstOverlap(lane, r);
            if (hit != null) d.reject(WouldOverlap(lane.id, hit.range.intersect(r) ?? r));
          }
          d.reject(WouldOverlap(lane.id, TimeRange(d.timeOf(minK + df), d.timeOf(minK + df))));
        }
        final p = groups[primaryLane]!;
        final shift = LanePlacement.nearestFreeShift(
          d.track(destOf(primaryLane)),
          [for (final i in p) (d.frameOf(i.start), d.frameOf(i.end))],
          df,
          d.rate,
        );
        if (shift == null || !fits(shift)) d.reject(WouldOverlap(destOf(primaryLane), TimeRange(p.first.start, p.last.end)));
        df = shift;
        clamped = true;
      }
    }

    for (final e in groups.entries) {
      final dest = d.track(destOf(e.key));
      final moved = [for (final i in e.value) d.shiftFrames(i, df)];
      final lane = d.placeGroup(moved, kind: dest.kind, preferred: dest.id, role: dest.audioRole);
      d.transferTransitions(e.key, lane, internal[e.key]!);
    }
    if (clamped) {
      final p = groups[primaryLane]!;
      d.clampedTo = TimeRange(d.timeOf(d.frameOf(p.first.start) + df), d.timeOf(d.frameOf(p.last.end) + df));
    }
  }

  void _rippleMove(
    _Draft d,
    Map<TrackId, List<TimelineItem>> groups,
    Map<TrackId, List<Transition>> internal,
    TrackId primaryLane,
    Track? target,
    int df,
  ) {
    final all = {for (final g in groups.values) for (final i in g) i.id};
    final removed = d.removeItems(all);
    d.ripple(d.closingPoints(removed));

    final primary = groups[primaryLane]!;
    final pStart = d.frameOf(primary.first.start);
    final destPrimary = target?.id ?? primaryLane;
    var t = pStart + df;
    final removedOnDest = removed[destPrimary];
    if (removedOnDest != null) t = d.frameAfterClosing(t, d.mergedFrameIntervals(removedOnDest));
    if (t < 0) t = 0;
    final destTrack = d.track(destPrimary);
    t = d.frameOf(destTrack.isMain ? d.nearestCut(destTrack, d.timeOf(t)) : d.cutAt(destTrack, d.timeOf(t)));

    var minK = 1 << 40;
    var maxK = -(1 << 40);
    for (final g in groups.values) {
      for (final i in g) {
        final s = d.frameOf(i.start);
        final e = d.frameOf(i.end);
        if (s < minK) minK = s;
        if (e > maxK) maxK = e;
      }
    }
    var shift = t - pStart; // every moved item shifts by this many frames
    var clamped = false;
    if (minK + shift < 0) {
      if (!clamp) d.reject(const InvalidValue('delta'));
      shift = -minK;
      clamped = true;
    }
    TrackId destOf(TrackId lane) => lane == primaryLane ? destPrimary : lane;
    d.openGap({for (final lane in groups.keys) destOf(lane)}, d.timeOf(minK + shift), maxK - minK);
    for (final e in groups.entries) {
      final dest = destOf(e.key);
      final moved = [for (final i in e.value) d.shiftFrames(i, shift)];
      final lane = d.track(dest);
      for (final m in moved) {
        final hit = LanePlacement.firstOverlap(lane, m.range);
        if (hit != null) {
          if (e.key != primaryLane) d.reject(RippleBlockedByLinkedItem(m.id));
          d.reject(WouldOverlap(dest, hit.range.intersect(m.range) ?? m.range));
        }
      }
      d.addItems(dest, moved);
      d.transferTransitions(e.key, dest, internal[e.key]!);
    }
    if (clamped) {
      d.clampedTo = TimeRange(d.timeOf(pStart + shift), d.timeOf(d.frameOf(primary.last.end) + shift));
    }
  }

  @override
  String toString() => 'MoveItems($ids, $delta, toTrack: $toTrack, ripple: $ripple, clamp: $clamp)';
}

/// Refuses when two members of one link group of [ids] ended up on one lane (I7).
void _checkLinksOnDistinctLanes(_Draft d, Set<ItemId> ids) {
  final seen = <(LinkId, TrackId)>{};
  for (final id in ids) {
    final loc = d.find(id);
    final link = loc?.item.link;
    if (loc == null || link == null) continue;
    if (!seen.add((link, loc.track.id))) d.reject(IncompatibleTrack(loc.track.id));
  }
}

// -------------------------------------------------------------------------------------------
// TrimItem
// -------------------------------------------------------------------------------------------

/// Moves one edge of an item to [newTime] (nearest frame), keeping its content attached (see the
/// file header). Link partners whose same edge coincides are trimmed with it.
///
/// * Non-ripple: the item never overlaps a neighbour; a shorter item leaves a gap (and drops its
///   transition at that edge).
/// * Ripple: an end trim shifts the later items of the lane (partners follow) by the change; a
///   head trim keeps the start fixed, removes (or restores) content at the head and pulls (or
///   pushes) the rest of the lane by the change.
/// * Limits: at least one frame; video and audio stay inside their media. Refusals:
///   `BelowMinDuration`, `OutOfSourceRange(limit)`, `WouldOverlap`; with [clamp] the nearest valid
///   edge is used and reported in `clampedTo`.
final class TrimItem extends EditCommand {
  /// Creates the command.
  const TrimItem(this.item, this.edge, this.newTime, {this.ripple = false, this.clamp = false});

  /// The item.
  final ItemId item;

  /// The edge to move.
  final TrimEdge edge;

  /// The proposed edge time (for a ripple head trim: where the head handle was dragged).
  final TimeUs newTime;

  /// Ripple mode.
  final bool ripple;

  /// Return the nearest valid result instead of refusing.
  final bool clamp;

  @override
  String get label => 'Trim clip';

  @override
  void _apply(_Draft d) {
    final loc = d.locate(item);
    if (loc.track.locked) d.reject(TrackLocked(loc.track.id));
    final main = loc.item;
    final atEnd = edge == TrimEdge.end;
    final targets = <_Loc>[loc];
    for (final pid in d.partnersOf(main)) {
      final p = d.locate(pid);
      final sameEdge = atEnd ? p.item.end == main.end : p.item.start == main.start;
      if (!sameEdge) continue;
      if (p.track.locked) d.reject(TrackLocked(p.track.id));
      targets.add(p);
    }

    final requested = d.rate.quantizeNearest(newTime);
    var t = requested;
    // Every target's bounds; refuse (or clamp) on the first violated one.
    var lo = -(1 << 62);
    var hi = 1 << 62;
    final List<_Bound> violations = [];
    for (final x in targets) {
      for (final b in _bounds(d, x)) {
        if (b.isMin ? t < b.limit : t > b.limit) violations.add(b);
        if (b.isMin && b.limit > lo) lo = b.limit;
        if (!b.isMin && b.limit < hi) hi = b.limit;
      }
    }
    if (violations.isNotEmpty) {
      if (!clamp || lo > hi) d.reject(violations.first.rejection);
      t = t < lo ? lo : hi;
    }
    final current = atEnd ? main.end : main.start;
    if (t == current) {
      if (t != requested) d.clampedTo = main.range;
      return;
    }

    final points = <_RipplePoint>[];
    final trimmed = <TimelineItem>[];
    for (final x in targets) {
      final i = x.item;
      if (atEnd) {
        trimmed.add(d.trimEnd(i, t));
        if (ripple) points.add((lane: x.track.id, at: i.end, frames: d.frameOf(t) - d.frameOf(i.end)));
      } else if (!ripple) {
        trimmed.add(d.trimStart(i, t));
      } else {
        final df = d.frameOf(t) - d.frameOf(i.start);
        final cut = d.trimStart(i, t);
        var kept = d.shiftFrames(cut, -df);
        // Moving back onto the grid can change the duration by 1 µs; a forward clip keeps the
        // exact source end of the trimmed content.
        if (kept is MediaClip && cut is MediaClip && !kept.reversed && d.isTimeBased(kept)) {
          final out = cut.sourceIn + ClipTimeMap.sourceLengthOf(cut.duration, cut.speed);
          final sourceIn = out - ClipTimeMap.sourceLengthOf(kept.duration, kept.speed);
          if (sourceIn >= 0) kept = kept.copyWith(sourceIn: sourceIn);
        }
        trimmed.add(kept);
        points.add((lane: x.track.id, at: i.end, frames: -df));
      }
    }
    if (ripple && points.isNotEmpty) {
      // Shift first (measured on the original positions), then put the trimmed items in.
      final shrinking = points.first.frames < 0;
      if (shrinking) {
        d.replaceItems(trimmed);
        d.ripple(points);
      } else {
        d.ripple(points);
        d.replaceItems(trimmed);
      }
    } else {
      d.replaceItems(trimmed);
    }
    if (t != requested) d.clampedTo = d.locate(item).item.range;
  }

  /// The constraints on the new edge of [x] (in the order they are reported).
  List<_Bound> _bounds(_Draft d, _Loc x) {
    final i = x.item;
    final k0 = d.frameOf(i.start);
    final k1 = d.frameOf(i.end);
    final out = <_Bound>[];
    final timeBased = i is MediaClip && d.isTimeBased(i);
    if (edge == TrimEdge.end) {
      out.add(_Bound(d.timeOf(k0 + 1), isMin: true, rejection: const BelowMinDuration()));
      if (timeBased) {
        final max = d.maxEnd(i);
        out.add(_Bound(max, isMin: false, rejection: OutOfSourceRange(max)));
      }
      if (!ripple && x.itemIndex + 1 < x.track.items.length) {
        final next = x.track.items[x.itemIndex + 1];
        out.add(_Bound(next.start, isMin: false, rejection: WouldOverlap(x.track.id, TimeRange(next.start, next.end))));
      }
    } else {
      out.add(_Bound(d.timeOf(k1 - 1), isMin: false, rejection: const BelowMinDuration()));
      if (timeBased) {
        final min = d.minStart(i, allowNegative: ripple);
        out.add(_Bound(min, isMin: true, rejection: OutOfSourceRange(min)));
      }
      if (!ripple) {
        out.add(const _Bound(0, isMin: true, rejection: InvalidValue('newTime')));
        if (x.itemIndex > 0) {
          final prev = x.track.items[x.itemIndex - 1];
          out.add(_Bound(prev.end, isMin: true, rejection: WouldOverlap(x.track.id, TimeRange(prev.start, prev.end))));
        }
      }
    }
    return out;
  }

  @override
  String toString() => 'TrimItem($item, ${edge.name}, $newTime, ripple: $ripple, clamp: $clamp)';
}

/// One limit on a trimmed edge and the rejection reported when it is crossed.
final class _Bound {
  const _Bound(this.limit, {required this.isMin, required this.rejection});
  final TimeUs limit;
  final bool isMin;
  final EditRejection rejection;
}

/// Content-attached trimming math for media clips (see the file header).
extension _TrimOps on _Draft {
  /// The largest number of frames from frame [k0] whose span fits in [available] µs (speed 1).
  int framesFitting(int k0, TimeUs available) {
    var n = rate.frameIndexOf(available);
    while (n > 0 && timeOf(k0 + n) - timeOf(k0) > available) {
      n--;
    }
    while (timeOf(k0 + n + 1) - timeOf(k0) <= available) {
      n++;
    }
    return n;
  }

  /// [item] with its end at [newEnd] (content attached).
  TimelineItem trimEnd(TimelineItem item, TimeUs newEnd) {
    final d1 = newEnd - item.start;
    if (d1 == item.duration) return item;
    if (item is! MediaClip || !isTimeBased(item)) return _retimed(item, item.start, d1);
    final c = item;
    final d0 = c.duration;
    final map = ClipTimeMap.forClip(c, rate);
    var speed = c.speed;
    if (speed is SpeedRamp) {
      if (d1 < d0) {
        speed = SpeedRamps.crop(speed, 0, _positionFraction(map, c.start + d1));
      } else {
        final l0 = d0 / speedTimeFactor(speed);
        speed = _extendRamp(speed, oldLength: l0, newLength: l0 + (d1 - d0) * speed.points.last.y, atEnd: true);
      }
    }
    final l1 = ClipTimeMap.sourceLengthOf(d1, speed);
    final sourceIn = c.reversed ? c.sourceIn + map.sourceLengthUs - l1 : c.sourceIn;
    return c.copyWith(duration: d1, speed: speed, sourceIn: sourceIn);
  }

  /// [item] with its start at [newStart] (content attached; keys shift by the change).
  TimelineItem trimStart(TimelineItem item, TimeUs newStart) {
    final delta = newStart - item.start;
    if (delta == 0) return item;
    final d1 = item.end - newStart;
    switch (item) {
      case TextItem():
        return item.copyWith(start: newStart, duration: d1, keyframes: KeyframeOps.shift(item.keyframes, -delta));
      case SubtitleCue():
        return item.copyWith(start: newStart, duration: d1);
      case MediaClip():
        final keys = KeyframeOps.shift(item.keyframes, -delta);
        if (!isTimeBased(item)) return item.copyWith(start: newStart, duration: d1, keyframes: keys);
        final c = item;
        final map = ClipTimeMap.forClip(c, rate);
        var speed = c.speed;
        if (speed is SpeedRamp) {
          if (delta > 0) {
            speed = SpeedRamps.crop(speed, _positionFraction(map, newStart), 1);
          } else {
            final l0 = c.duration / speedTimeFactor(speed);
            speed = _extendRamp(speed, oldLength: l0, newLength: l0 + (-delta) * speed.points.first.y, atEnd: false);
          }
        }
        final l1 = ClipTimeMap.sourceLengthOf(d1, speed);
        final sourceIn = c.reversed ? c.sourceIn : c.sourceIn + map.sourceLengthUs - l1;
        return c.copyWith(start: newStart, duration: d1, speed: speed, sourceIn: sourceIn, keyframes: keys);
    }
  }

  /// Whether [clip] plays only source inside its media.
  bool sourceFits(TimelineItem clip) {
    if (clip is! MediaClip) return true;
    final a = assetOf(clip);
    if (a == null || !_timeBased(a.kind)) return true;
    if (clip.sourceIn < 0 || !TransitionBounds.speedValid(clip.speed)) return false;
    return clip.sourceIn + ClipTimeMap.sourceLengthOf(clip.duration, clip.speed) <= a.probe.duration;
  }

  /// The latest grid end [clip] can be trimmed or extended to without leaving its media.
  TimeUs maxEnd(MediaClip clip) {
    final a = assetOf(clip)!;
    final map = ClipTimeMap.forClip(clip, rate);
    final available = clip.reversed ? clip.sourceIn : a.probe.duration - map.sourceOut;
    if (available <= 0) return clip.end;
    final v = _edgeSpeed(clip.speed, atEnd: true);
    var k = frameOf(clip.end + (available / v).floor());
    while (k > frameOf(clip.end) && !sourceFits(trimEnd(clip, timeOf(k)))) {
      k--;
    }
    for (var n = 0; n < 3 && sourceFits(trimEnd(clip, timeOf(k + 1))); n++) {
      k++;
    }
    return timeOf(k);
  }

  /// The earliest grid start [clip] can be trimmed or extended to without leaving its media
  /// (never before 0 unless [allowNegative], for ripple head trims that keep the start).
  TimeUs minStart(MediaClip clip, {bool allowNegative = false}) {
    final a = assetOf(clip)!;
    final map = ClipTimeMap.forClip(clip, rate);
    final available = clip.reversed ? a.probe.duration - map.sourceOut : clip.sourceIn;
    if (available <= 0) return clip.start;
    final v = _edgeSpeed(clip.speed, atEnd: false);
    var estimate = clip.start - (available / v).floor();
    if (!allowNegative && estimate < 0) estimate = 0;
    var k = frameOf(estimate);
    if (timeOf(k) < estimate) k++;
    while (k < frameOf(clip.start) && !sourceFits(trimStart(clip, timeOf(k)))) {
      k++;
    }
    for (var n = 0; n < 3 && (allowNegative || k > 0) && sourceFits(trimStart(clip, timeOf(k - 1))); n++) {
      k--;
    }
    return timeOf(k);
  }
}

/// The playback speed at the clip's first or last frame.
double _edgeSpeed(SpeedSpec speed, {required bool atEnd}) => switch (speed) {
      ConstantSpeed(:final rate) => rate,
      SpeedRamp(:final points) => atEnd ? points.last.y : points.first.y,
    };

/// The normalized playback position (0 → 1 from the clip start) shown at timeline time [t].
double _positionFraction(ClipTimeMap map, TimeUs t) {
  final s = map.sourceAt(t);
  final pos = map.reversed ? map.sourceOut - s : s - map.sourceIn;
  final x = pos / map.sourceLengthUs;
  return x <= 0 ? 1e-9 : (x >= 1 ? 1 - 1e-9 : x);
}

/// [ramp] extended at one edge by holding that edge's speed (domain.md §4.5): the original curve
/// covers `oldLength / newLength` of the new one. A ramp already at 16 points (or whose edge
/// segment is flat) stretches its edge segment instead of gaining a point.
SpeedRamp _extendRamp(SpeedRamp ramp, {required double oldLength, required double newLength, required bool atEnd}) {
  final scale = oldLength / newLength;
  final pts = ramp.points;
  final n = pts.length;
  final out = <SpeedPoint>[];
  if (atEnd) {
    for (final p in pts) {
      out.add(SpeedPoint(p.x * scale, p.y));
    }
    final flat = pts[n - 2].y == pts[n - 1].y;
    if (flat || n >= 16) {
      out[n - 1] = SpeedPoint(1, pts[n - 1].y);
    } else {
      out.add(SpeedPoint(1, pts[n - 1].y));
    }
    out[0] = SpeedPoint(0, pts[0].y);
  } else {
    final off = 1 - scale;
    for (final p in pts) {
      out.add(SpeedPoint(off + p.x * scale, p.y));
    }
    out[n - 1] = SpeedPoint(1, pts[n - 1].y);
    final flat = pts[0].y == pts[1].y;
    if (flat || n >= 16) {
      out[0] = SpeedPoint(0, pts[0].y);
    } else {
      out.insert(0, SpeedPoint(0, pts[0].y));
    }
  }
  return SpeedRamp(out);
}

// -------------------------------------------------------------------------------------------
// SplitItems
// -------------------------------------------------------------------------------------------

/// Splits every item of [ids] (plus link partners) that contains [at] strictly into two, at the
/// frame start of [at]. Empty [ids]: the main-lane item under [at]. Split goes through the clip
/// time map, so ramped and reversed clips play exactly as before; keys are partitioned with
/// boundary keys; the left half keeps the fade-in, the incoming transition and a text item's in
/// animation, the right half (a new id) the fade-out, the outgoing transition and the out
/// animation. Right halves of one link group share a new link. Subtitle cues are split by
/// `SplitCue` (CORE-15), not here.
final class SplitItems extends EditCommand {
  /// Creates the command.
  SplitItems(Set<ItemId> ids, this.at) : ids = Set.unmodifiable(ids);

  /// Items to split (empty: the main-lane item under [at]).
  final Set<ItemId> ids;

  /// Split time (floored to its frame start).
  final TimeUs at;

  @override
  String get label => 'Split';

  @override
  void _apply(_Draft d) {
    final t = d.rate.quantize(at);
    final Set<ItemId> wanted;
    if (ids.isEmpty) {
      final main = d.mainTrack;
      ItemId? hit;
      if (main != null) {
        for (final i in main.items) {
          if (i.start < t && t < i.end) {
            hit = i.id;
            break;
          }
        }
      }
      if (hit == null) d.reject(NothingAtTime(t));
      wanted = {hit};
    } else {
      for (final id in ids) {
        d.locate(id);
      }
      wanted = ids;
    }
    final candidates = [
      for (final id in d.withPartners(wanted))
        if (d.find(id) case final l? when l.item.start < t && t < l.item.end) l,
    ];
    final splittable = [for (final c in candidates) if (c.item is! SubtitleCue) c];
    if (candidates.isEmpty) d.reject(NothingAtTime(t));
    if (splittable.isEmpty) d.reject(const UnsupportedForKind('subtitle'));
    if (splittable.length < candidates.length) {
      d.notices.add(EditNotice(EditNoticeCodes.itemsSkipped, items: {
        for (final c in candidates)
          if (c.item is SubtitleCue) c.item.id,
      }));
    }
    for (final c in splittable) {
      if (c.track.locked) d.reject(TrackLocked(c.track.id));
    }

    final rightLinks = <LinkId, LinkId>{};
    final byLane = <TrackId, List<(TimelineItem, TimelineItem)>>{};
    for (final c in splittable) {
      final item = c.item;
      final oldLink = item.link;
      final rightLink = oldLink == null ? null : (rightLinks[oldLink] ??= d.ids.linkId());
      final pair = _split(d, item, t, d.ids.itemId(), rightLink);
      (byLane[c.track.id] ??= []).add(pair);
    }
    for (final e in byLane.entries) {
      final lane = d.track(e.key);
      final lefts = {for (final p in e.value) p.$1.id: p.$1};
      final rightOf = {for (final p in e.value) p.$1.id: p.$2.id};
      final items = <TimelineItem>[
        for (final i in lane.items) lefts[i.id] ?? i,
        for (final p in e.value) p.$2,
      ];
      final transitions = [
        for (final tr in lane.transitions)
          if (rightOf[tr.left] case final r?)
            Transition(id: tr.id, left: r, right: tr.right, kind: tr.kind, durationFrames: tr.durationFrames, direction: tr.direction)
          else
            tr,
      ];
      d.setItems(e.key, items, transitions: transitions);
      for (final p in e.value) {
        d.affected
          ..add(p.$1.id)
          ..add(p.$2.id);
        d.noteLink(p.$2.link);
      }
    }
    for (final l in rightLinks.keys) {
      d.noteLink(l);
    }
  }

  @override
  String toString() => 'SplitItems($ids, $at)';
}

/// The two halves of [item] split at [t] (strictly inside); the right half gets [rightId] and
/// [rightLink].
(TimelineItem, TimelineItem) _split(_Draft d, TimelineItem item, TimeUs t, ItemId rightId, LinkId? rightLink) {
  final local = t - item.start;
  switch (item) {
    case MediaClip():
      final keys = KeyframeOps.partition(item.keyframes, at: local, duration: item.duration, rate: d.rate, itemStart: item.start);
      final MediaClip left;
      final MediaClip right;
      if (d.isTimeBased(item)) {
        final s = ClipTimeMap.forClip(item, d.rate).splitAt(t);
        left = item.copyWith(duration: s.leftDuration, speed: s.leftSpeed, sourceIn: s.leftSourceIn);
        right = item.copyWith(start: t, duration: s.rightDuration, speed: s.rightSpeed, sourceIn: s.rightSourceIn);
      } else {
        left = item.copyWith(duration: local);
        right = item.copyWith(start: t, duration: item.end - t);
      }
      return (
        left.copyWith(audio: left.audio.copyWith(fadeOut: 0), keyframes: keys.left),
        right.withId(rightId).copyWith(link: rightLink, audio: right.audio.copyWith(fadeIn: 0), keyframes: keys.right),
      );
    case TextItem():
      final keys = KeyframeOps.partition(item.keyframes, at: local, duration: item.duration, rate: d.rate, itemStart: item.start);
      final a = item.animation;
      final left = item.copyWith(
        duration: local,
        animation: a.copyWith(outKind: TextAnimKind.none, outDuration: 0),
        keyframes: keys.left,
      );
      final right = TextItem(
        id: rightId,
        start: t,
        duration: item.end - t,
        link: rightLink,
        label: item.label,
        text: item.text,
        style: item.style,
        animation: a.copyWith(inKind: TextAnimKind.none, inDuration: 0),
        transform: item.transform,
        keyframes: keys.right,
      );
      return (left, right);
    case SubtitleCue():
      throw StateError('cues are split by SplitCue');
  }
}

// -------------------------------------------------------------------------------------------
// DeleteItems, DeleteGap
// -------------------------------------------------------------------------------------------

/// Removes items (plus link partners) and their transitions. [ripple] closes the removed spans on
/// each lane (merged per lane) and shifts later items left; partners follow (D-10).
final class DeleteItems extends EditCommand {
  /// Creates the command.
  DeleteItems(Set<ItemId> ids, {this.ripple = false}) : ids = Set.unmodifiable(ids);

  /// Items to delete.
  final Set<ItemId> ids;

  /// Ripple delete.
  final bool ripple;

  @override
  String get label => ripple ? 'Ripple delete' : 'Delete';

  @override
  void _apply(_Draft d) {
    if (ids.isEmpty) d.reject(const InvalidValue('ids'));
    final all = d.withPartners(ids);
    for (final id in all) {
      final l = d.locate(id);
      if (l.track.locked) d.reject(TrackLocked(l.track.id));
    }
    final removed = d.removeItems(all);
    if (ripple) d.ripple(d.closingPoints(removed));
    d.selection = SelectionHint(const {});
  }

  @override
  String toString() => 'DeleteItems($ids, ripple: $ripple)';
}

/// Removes an empty span of a lane: the lane's items after it shift left by its length (link
/// partners follow, D-10). The span must not overlap any item (`InvalidValue('gap')`).
final class DeleteGap extends EditCommand {
  /// Creates the command.
  const DeleteGap(this.gap);

  /// The gap.
  final GapRef gap;

  @override
  String get label => 'Delete gap';

  @override
  void _apply(_Draft d) {
    final lane = d.editableTrack(gap.track);
    final s = d.rate.quantizeNearest(gap.range.start);
    final e = d.rate.quantizeNearest(gap.range.end);
    if (s < 0 || e <= s) d.reject(const InvalidValue('gap'));
    final r = TimeRange(s, e);
    if (LanePlacement.firstOverlap(lane, r) != null) d.reject(const InvalidValue('gap'));
    d.ripple([(lane: lane.id, at: e, frames: -(d.frameOf(e) - d.frameOf(s)))]);
  }

  @override
  String toString() => 'DeleteGap($gap)';
}
