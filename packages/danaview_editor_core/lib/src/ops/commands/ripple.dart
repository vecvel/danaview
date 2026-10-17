// OWNER: CORE-10
//
// Ripple helpers (D-10, domain.md §6.3), shared by every command part that shifts lanes
// (structural commands here; speed, freeze-frame and caption commands may use them too).
//
// **Ripple scope.** A ripple is a list of points `(lane, at, frames)`: on each *edited* lane,
// every item with `start ≥ at` moves by the sum of the frames of the points at or before its start
// (so several points on one lane accumulate, all measured in the coordinates before the ripple).
// Linked partners of moved items that sit on other lanes move by the same amount; only the
// partners move there, never the rest of their lane, so a ripple never moves items on unrelated
// lanes. If a partner would then overlap another item of its lane (or start before 0) the edit is
// refused with `RippleBlockedByLinkedItem`; members of one link group that would need different
// shifts are refused the same way. Moved items keep their frame counts (edges stay on the grid).
//
// **Magnetic main lane.** With ripple on, inserts and moves onto the main lane snap to the nearest
// cut ([_RippleOps.nearestCut]); on other lanes a ripple insertion inside an item snaps to that
// item's nearer edge ([_RippleOps.cutAt]) so the insertion never splits it.

part of '../edit_command.dart';

/// On [lane], every item with `start ≥ at` moves by [frames] frames.
typedef _RipplePoint = ({TrackId lane, TimeUs at, int frames});

extension _RippleOps on _Draft {
  /// Applies [points] (see the file header) and returns the ids of the moved items.
  Set<ItemId> ripple(List<_RipplePoint> points) {
    final byLane = <TrackId, List<_RipplePoint>>{};
    for (final p in points) {
      if (p.frames != 0) (byLane[p.lane] ??= <_RipplePoint>[]).add(p);
    }
    if (byLane.isEmpty) return const {};
    final shifts = <ItemId, int>{};
    final laneOf = <ItemId, TrackId>{};
    for (final e in byLane.entries) {
      final t = track(e.key);
      for (final item in t.items) {
        laneOf[item.id] = t.id;
        var s = 0;
        for (final p in e.value) {
          if (p.at <= item.start) s += p.frames;
        }
        if (s != 0) shifts[item.id] = s;
      }
    }
    // Partners on lanes outside the scope follow their group.
    final followers = <ItemId>{};
    if (shifts.isNotEmpty) {
      for (final group in linkGroups.values) {
        if (group.length < 2) continue;
        final scoped = <int>{};
        final outside = <ItemId>[];
        for (final id in group) {
          if (laneOf.containsKey(id)) {
            scoped.add(shifts[id] ?? 0);
          } else {
            outside.add(id);
          }
        }
        if (outside.isEmpty || scoped.isEmpty || (scoped.length == 1 && scoped.first == 0)) continue;
        if (scoped.length > 1) reject(RippleBlockedByLinkedItem(outside.first));
        for (final id in outside) {
          shifts[id] = scoped.first;
          followers.add(id);
        }
      }
    }
    if (shifts.isEmpty) return const {};
    // Apply lane by lane and check the result.
    final lanes = <TrackId>{};
    for (final id in shifts.keys) {
      lanes.add(laneOf[id] ?? locate(id).track.id);
    }
    for (final laneId in lanes) {
      final t = track(laneId);
      if (t.locked) reject(TrackLocked(laneId));
      final items = [
        for (final i in t.items)
          if (shifts[i.id] case final s?) shiftFrames(i, s) else i,
      ]..sort(_byStart);
      for (var i = 0; i < items.length; i++) {
        final b = items[i];
        if (b.start < 0) {
          if (followers.contains(b.id)) reject(RippleBlockedByLinkedItem(b.id));
          reject(WouldOverlap(laneId, TimeRange(b.start, b.end < 0 ? b.end : 0)));
        }
        if (i == 0) continue;
        final a = items[i - 1];
        if (b.start < a.end) {
          final culprit = followers.contains(b.id) ? b.id : (followers.contains(a.id) ? a.id : null);
          if (culprit != null) reject(RippleBlockedByLinkedItem(culprit));
          reject(WouldOverlap(laneId, TimeRange(b.start, a.end < b.end ? a.end : b.end)));
        }
      }
      setItems(laneId, items);
    }
    affected.addAll(shifts.keys);
    return shifts.keys.toSet();
  }

  /// The ripple points that close the space left by [removed] items (per lane, merged intervals).
  List<_RipplePoint> closingPoints(Map<TrackId, List<TimelineItem>> removed) => [
        for (final e in removed.entries)
          for (final iv in mergedFrameIntervals(e.value)) (lane: e.key, at: timeOf(iv.$2), frames: -(iv.$2 - iv.$1)),
      ];

  /// The union of the frame ranges `[k0, k1)` of [items], sorted.
  List<(int, int)> mergedFrameIntervals(Iterable<TimelineItem> items) {
    final ivs = [for (final i in items) (frameOf(i.start), frameOf(i.end))]..sort((a, b) => a.$1.compareTo(b.$1));
    final out = <(int, int)>[];
    for (final iv in ivs) {
      if (out.isNotEmpty && iv.$1 <= out.last.$2) {
        final last = out.removeLast();
        out.add((last.$1, iv.$2 > last.$2 ? iv.$2 : last.$2));
      } else {
        out.add(iv);
      }
    }
    return out;
  }

  /// [frame] mapped through closing [intervals] (frames removed before it no longer count).
  int frameAfterClosing(int frame, List<(int, int)> intervals) {
    var removed = 0;
    for (final iv in intervals) {
      if (iv.$1 >= frame) break;
      removed += (iv.$2 < frame ? iv.$2 : frame) - iv.$1;
    }
    return frame - removed;
  }

  /// The cut of [lane] nearest to [t]: 0 or any item edge (ties go to the earlier cut). Used for
  /// the magnetic main lane.
  TimeUs nearestCut(Track lane, TimeUs t) {
    var best = 0;
    var bestDist = t.abs();
    void consider(TimeUs c) {
      final dist = (c - t).abs();
      if (dist < bestDist || (dist == bestDist && c < best)) {
        best = c;
        bestDist = dist;
      }
    }

    for (final i in lane.items) {
      consider(i.start);
      consider(i.end);
    }
    return best;
  }

  /// [t] when it does not lie strictly inside an item of [lane]; otherwise the nearer edge of that
  /// item (the start on a tie).
  TimeUs cutAt(Track lane, TimeUs t) {
    for (final i in lane.items) {
      if (i.start < t && t < i.end) return (t - i.start) <= (i.end - t) ? i.start : i.end;
      if (i.start >= t) break;
    }
    return t;
  }

  /// Ripple-insert space: opens [frames] frames at [at] on [lanes] (partners follow).
  Set<ItemId> openGap(Iterable<TrackId> lanes, TimeUs at, int frames) =>
      ripple([for (final l in lanes) (lane: l, at: at, frames: frames)]);
}
