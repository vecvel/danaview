// OWNER: CORE-18
//
// The snapping index (ARCH §7.1, domain.md §6.8). The timeline UI snaps the *proposed* time of a
// drag to a nearby target and only then calls `dryRun`; commands never snap on their own.
//
// A [SnapIndex] is built once per drag gesture from a project snapshot:
//
// * item edges of every lane (start and end of every clip, text item and cue), minus the items
//   being dragged (`exclude`: callers pass `SelectionRules.expand` of the selection);
// * markers;
// * the playhead;
// * the boundaries of every transition window (`[cut − ⌊n/2⌋, cut + ⌈n/2⌉)` frames), unless a
//   transition touches an excluded item;
// * optionally the keyframes of one item (`keyframesOf`, at item start + key time);
// * optionally the cue edges of subtitle lanes (`cues`, default on).
//
// Build is O(n log n): every target becomes one `int64` sort key `time | priority | ordinal` and
// one native sort orders them. Targets sharing a time collapse to the one with the best priority
// (playhead, marker, item edge, transition boundary, keyframe), so queries are a binary search
// plus a look at two neighbours and allocate only the returned hit.
//
// Ties between a target before and one after the probe time go to the better priority, then to
// the earlier one.

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/items.dart';
import '../model/keyframes/keyframes.dart';
import '../model/marker.dart';
import '../model/project.dart';
import '../model/track.dart';
import '../time/time.dart';

/// What a snap target is (the UI picks the guide colour and the haptic from it).
enum SnapKind {
  /// The playhead.
  playhead,

  /// A marker.
  marker,

  /// An item edge (clip, text item or cue).
  itemEdge,

  /// An edge of a transition window.
  transition,

  /// A keyframe of the item named by `SnapIndex.build(keyframesOf:)`.
  keyframe,
}

/// Which side of an item or transition window a target is.
enum SnapSide {
  /// The start edge.
  start,

  /// The end edge.
  end,
}

/// A snap target close to a probed time.
@immutable
final class SnapHit {
  /// Creates a hit.
  const SnapHit({
    required this.time,
    required this.kind,
    required this.distance,
    this.item,
    this.track,
    this.marker,
    this.transition,
    this.side,
  });

  /// The target time (µs).
  final TimeUs time;

  /// What the target is.
  final SnapKind kind;

  /// Absolute distance to the probed time in µs.
  final TimeUs distance;

  /// The item whose edge or keyframe this is (`itemEdge`, `keyframe`).
  final ItemId? item;

  /// The lane of [item] or of the transition.
  final TrackId? track;

  /// The marker ([SnapKind.marker]).
  final MarkerId? marker;

  /// The transition ([SnapKind.transition]).
  final TransitionId? transition;

  /// The side of the item (`itemEdge`) or of the transition window (`transition`).
  final SnapSide? side;

  @override
  bool operator ==(Object other) =>
      other is SnapHit &&
      other.time == time &&
      other.kind == kind &&
      other.distance == distance &&
      other.item == item &&
      other.track == track &&
      other.marker == marker &&
      other.transition == transition &&
      other.side == side;

  @override
  int get hashCode => Object.hash(time, kind, distance, item, track, marker, transition, side);

  @override
  String toString() => 'SnapHit(${kind.name} @$time, distance $distance'
      '${item == null ? '' : ', $item'}${marker == null ? '' : ', $marker'}${transition == null ? '' : ', $transition'}'
      '${side == null ? '' : ', ${side!.name}'})';
}

/// The best snap of a dragged range: which of its edges snaps, onto what, and by how much.
@immutable
final class RangeSnap {
  /// Creates a range snap.
  const RangeSnap({required this.hit, required this.edge, required this.delta});

  /// The target.
  final SnapHit hit;

  /// The edge of the range that snaps.
  final SnapSide edge;

  /// What to add to the range so that [edge] lands on the target (`hit.time − edge time`).
  final TimeUs delta;

  @override
  bool operator ==(Object other) => other is RangeSnap && other.hit == hit && other.edge == edge && other.delta == delta;

  @override
  int get hashCode => Object.hash(hit, edge, delta);

  @override
  String toString() => 'RangeSnap(${edge.name} by $delta onto $hit)';
}

// Target kinds as stored (the position in the sort key's priority bits is `_priority`).
const int _kPlayhead = 0;
const int _kMarker = 1;
const int _kEdgeStart = 2;
const int _kEdgeEnd = 3;
const int _kTransitionStart = 4;
const int _kTransitionEnd = 5;
const int _kKeyframe = 6;

const List<int> _priority = [0, 1, 2, 2, 3, 3, 4];

const int _timeBits = 37;
const int _prioBits = 3;
const int _ordBits = 22;
const int _maxTime = (1 << _timeBits) - 1;
const int _maxOrdinal = (1 << _ordBits) - 1;
const int _ordMask = _maxOrdinal;

/// An immutable index of snap targets (see the file header).
final class SnapIndex {
  SnapIndex._(this._tracks, this._markers, this._times, this._ordinals, this._kind, this._a, this._b, this.length, this.playhead);

  /// An index without targets.
  static final SnapIndex empty = SnapIndex._(const [], const [], Int64List(0), Int32List(0), Uint8List(0), Int32List(0), Int32List(0), 0, null);

  /// Builds the index of [project].
  ///
  /// * [exclude]: items that are being dragged; neither their edges, nor their keyframes, nor the
  ///   transitions touching them are targets;
  /// * [playhead]: the playhead time, if it is a target;
  /// * [markers]: include the markers;
  /// * [keyframesOf]: include the keyframes of this item (at its start + key time);
  /// * [cues]: include the edges of subtitle cues;
  /// * [transitions]: include the boundaries of transition windows.
  static SnapIndex build(
    EditProject project, {
    Set<ItemId> exclude = const {},
    TimeUs? playhead,
    bool markers = true,
    ItemId? keyframesOf,
    bool cues = true,
    bool transitions = true,
  }) {
    final tracks = project.tracks;
    final marks = project.markers;
    final rate = project.settings.frameRate;
    final noExclusions = exclude.isEmpty;

    // Count the targets to size the arrays once.
    var count = playhead == null ? 0 : 1;
    if (markers) count += marks.length;
    for (final t in tracks) {
      if (!cues && t.kind == TrackKind.subtitle) continue;
      count += 2 * t.items.length;
      if (transitions) count += 2 * t.transitions.length;
    }
    if (keyframesOf != null) {
      final loc = project.index.locate(keyframesOf);
      final item = loc?.item;
      if (item is MediaClip) {
        for (final tr in item.keyframes.byChannel.values) {
          count += tr.keys.length;
        }
      } else if (item is TextItem) {
        for (final tr in item.keyframes.byChannel.values) {
          count += tr.keys.length;
        }
      }
    }
    if (count > _maxOrdinal) count = _maxOrdinal;

    final keys = Int64List(count);
    final kind = Uint8List(count);
    final a = Int32List(count);
    final b = Int32List(count);
    var n = 0;

    void add(int time, int k, int ta, int tb) {
      if (n >= count) return;
      final clamped = time < 0 ? 0 : (time > _maxTime ? _maxTime : time);
      keys[n] = (clamped << (_prioBits + _ordBits)) | (_priority[k] << _ordBits) | n;
      kind[n] = k;
      a[n] = ta;
      b[n] = tb;
      n++;
    }

    // The keys go in as sorted runs (the edges of one lane, the markers, ...): items of a lane do
    // not overlap, so their edges already ascend, and merging runs is much cheaper than sorting
    // everything. A run that is not sorted (an invalid project) is sorted on its own.
    final bounds = <int>[0];
    void endRun() {
      if (n == bounds.last) return;
      var sorted = true;
      for (var i = bounds.last + 1; i < n; i++) {
        if (keys[i - 1] > keys[i]) {
          sorted = false;
          break;
        }
      }
      if (!sorted) Int64List.sublistView(keys, bounds.last, n).sort();
      bounds.add(n);
    }

    if (playhead != null) {
      add(playhead, _kPlayhead, -1, -1);
      endRun();
    }
    if (markers) {
      for (var i = 0; i < marks.length; i++) {
        add(marks[i].time, _kMarker, -1, i);
      }
      endRun();
    }
    for (var ti = 0; ti < tracks.length; ti++) {
      final t = tracks[ti];
      if (!cues && t.kind == TrackKind.subtitle) continue;
      final items = t.items;
      for (var ii = 0; ii < items.length; ii++) {
        final item = items[ii];
        if (!noExclusions && exclude.contains(item.id)) continue;
        add(item.start, _kEdgeStart, ti, ii);
        add(item.end, _kEdgeEnd, ti, ii);
      }
      endRun();
    }
    if (transitions) {
      for (var ti = 0; ti < tracks.length; ti++) {
        final t = tracks[ti];
        if (t.transitions.isEmpty || (!cues && t.kind == TrackKind.subtitle)) continue;
        final byId = <ItemId, TimelineItem>{for (final item in t.items) item.id: item};
        for (var xi = 0; xi < t.transitions.length; xi++) {
          final tr = t.transitions[xi];
          if (!noExclusions && (exclude.contains(tr.left) || exclude.contains(tr.right))) continue;
          final right = byId[tr.right];
          if (right == null) continue;
          final cutFrame = rate.frameIndexOf(right.start);
          final n0 = tr.durationFrames;
          add(rate.timeOfFrame(cutFrame - n0 ~/ 2), _kTransitionStart, ti, xi);
          add(rate.timeOfFrame(cutFrame + (n0 + 1) ~/ 2), _kTransitionEnd, ti, xi);
        }
      }
    }
    if (keyframesOf != null) {
      final loc = project.index.locate(keyframesOf);
      if (loc != null && !exclude.contains(keyframesOf)) {
        final item = loc.item;
        final set = item is MediaClip ? item.keyframes : (item is TextItem ? item.keyframes : KeyframeSet.empty);
        final seen = <TimeUs>{};
        for (final tr in set.byChannel.values) {
          for (final k in tr.keys) {
            if (seen.add(k.t)) add(item.start + k.t, _kKeyframe, loc.trackIndex, loc.itemIndex);
          }
        }
      }
    }
    endRun();

    final sorted = _mergeRuns(n == keys.length ? keys : Int64List.sublistView(keys, 0, n), bounds);

    // Collapse equal times to the best-priority target (first in the sort order).
    final times = Int64List(n);
    final ordinals = Int32List(n);
    var u = 0;
    var last = -1;
    for (var i = 0; i < n; i++) {
      final key = sorted[i];
      final time = key >> (_prioBits + _ordBits);
      if (time == last) continue;
      last = time;
      times[u] = time;
      ordinals[u] = key & _ordMask;
      u++;
    }
    return SnapIndex._(
      tracks,
      marks,
      u == n ? times : Int64List.sublistView(times, 0, u),
      u == n ? ordinals : Int32List.sublistView(ordinals, 0, u),
      kind,
      a,
      b,
      u,
      playhead,
    );
  }

  /// Merges the ascending runs `[bounds[i], bounds[i + 1])` of [src] into one ascending list
  /// (bottom-up pairwise merges; keys are unique).
  static Int64List _mergeRuns(Int64List src, List<int> bounds) {
    if (bounds.length <= 2) return src;
    var from = src;
    var to = Int64List(src.length);
    var runs = bounds;
    while (runs.length > 2) {
      final next = <int>[0];
      for (var r = 0; r + 1 < runs.length; r += 2) {
        final lo = runs[r];
        final mid = runs[r + 1];
        if (r + 2 >= runs.length) {
          to.setRange(lo, mid, from, lo);
          next.add(mid);
          break;
        }
        final hi = runs[r + 2];
        var i = lo;
        var j = mid;
        var o = lo;
        while (i < mid && j < hi) {
          final x = from[i];
          final y = from[j];
          if (x <= y) {
            to[o++] = x;
            i++;
          } else {
            to[o++] = y;
            j++;
          }
        }
        while (i < mid) {
          to[o++] = from[i++];
        }
        while (j < hi) {
          to[o++] = from[j++];
        }
        next.add(hi);
      }
      final swap = from;
      from = to;
      to = swap;
      runs = next;
    }
    return from;
  }

  final List<Track> _tracks;
  final List<Marker> _markers;
  final Int64List _times;
  final Int32List _ordinals;
  final Uint8List _kind;
  final Int32List _a;
  final Int32List _b;

  /// Number of distinct target times.
  final int length;

  /// The playhead the index was built with.
  final TimeUs? playhead;

  /// Whether the index has no targets.
  bool get isEmpty => length == 0;

  /// The distinct target times, ascending (tests, snap guide rendering).
  List<TimeUs> get times => _times;

  /// The target nearest to [t] within [toleranceUs] (inclusive), or null. When two targets are
  /// equally near the better kind wins (playhead, marker, edge, transition, keyframe), then the
  /// earlier.
  SnapHit? nearest(TimeUs t, TimeUs toleranceUs) {
    final i = _nearestIndex(t, toleranceUs);
    return i < 0 ? null : _hit(i, t);
  }

  /// The best snap of the range [range] within [toleranceUs]: both its edges are probed and the
  /// smaller shift wins (ties: better kind, then the start edge). Null when neither edge has a
  /// target in reach.
  RangeSnap? nearestForRange(TimeRange range, TimeUs toleranceUs) {
    final si = _nearestIndex(range.start, toleranceUs);
    final ei = range.isEmpty ? -1 : _nearestIndex(range.end, toleranceUs);
    if (si < 0 && ei < 0) return null;
    if (ei < 0) return _rangeSnap(si, SnapSide.start, range.start);
    if (si < 0) return _rangeSnap(ei, SnapSide.end, range.end);
    final ds = (_times[si] - range.start).abs();
    final de = (_times[ei] - range.end).abs();
    if (ds != de) return ds < de ? _rangeSnap(si, SnapSide.start, range.start) : _rangeSnap(ei, SnapSide.end, range.end);
    final ps = _priority[_kind[_ordinals[si]]];
    final pe = _priority[_kind[_ordinals[ei]]];
    return pe < ps ? _rangeSnap(ei, SnapSide.end, range.end) : _rangeSnap(si, SnapSide.start, range.start);
  }

  RangeSnap _rangeSnap(int i, SnapSide edge, TimeUs edgeTime) {
    final hit = _hit(i, edgeTime);
    return RangeSnap(hit: hit, edge: edge, delta: hit.time - edgeTime);
  }

  /// Index of the nearest collapsed target within tolerance, or -1.
  int _nearestIndex(TimeUs t, TimeUs tolerance) {
    final n = length;
    if (n == 0 || tolerance < 0) return -1;
    var lo = 0;
    var hi = n;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_times[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    // _times[lo] is the first target ≥ t; lo − 1 the last target < t.
    final after = lo < n ? _times[lo] - t : -1;
    final before = lo > 0 ? t - _times[lo - 1] : -1;
    final okAfter = after >= 0 && after <= tolerance;
    final okBefore = before >= 0 && before <= tolerance;
    if (!okAfter && !okBefore) return -1;
    if (!okBefore) return lo;
    if (!okAfter) return lo - 1;
    if (before < after) return lo - 1;
    if (after < before) return lo;
    // Equal distance: the better kind, then the earlier.
    final pb = _priority[_kind[_ordinals[lo - 1]]];
    final pa = _priority[_kind[_ordinals[lo]]];
    return pa < pb ? lo : lo - 1;
  }

  SnapHit _hit(int i, TimeUs probe) {
    final o = _ordinals[i];
    final time = _times[i];
    final distance = (time - probe).abs();
    switch (_kind[o]) {
      case _kPlayhead:
        return SnapHit(time: time, kind: SnapKind.playhead, distance: distance);
      case _kMarker:
        return SnapHit(time: time, kind: SnapKind.marker, distance: distance, marker: _markers[_b[o]].id);
      case _kEdgeStart:
      case _kEdgeEnd:
        final track = _tracks[_a[o]];
        return SnapHit(
          time: time,
          kind: SnapKind.itemEdge,
          distance: distance,
          item: track.items[_b[o]].id,
          track: track.id,
          side: _kind[o] == _kEdgeStart ? SnapSide.start : SnapSide.end,
        );
      case _kTransitionStart:
      case _kTransitionEnd:
        final track = _tracks[_a[o]];
        return SnapHit(
          time: time,
          kind: SnapKind.transition,
          distance: distance,
          transition: track.transitions[_b[o]].id,
          track: track.id,
          side: _kind[o] == _kTransitionStart ? SnapSide.start : SnapSide.end,
        );
      default:
        final track = _tracks[_a[o]];
        return SnapHit(time: time, kind: SnapKind.keyframe, distance: distance, item: track.items[_b[o]].id, track: track.id);
    }
  }
}
