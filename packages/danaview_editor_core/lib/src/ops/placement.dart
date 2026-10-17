// OWNER: CORE-09
//
// Where items land (ARCH §7.1, D-11, domain.md §6.3): `Placement` and `NewTrack` (reported by
// `dryRun` so drag ghosts are exact) and the lane-search helpers commands use.
//
// **Overlap resolution (D-11, `OverlapPolicy.newLane`).** A moved, pasted or inserted group of
// items from one source lane tries its target lane, then the other lanes of the same kind by
// distance from the target (the lane above first on a tie: higher canonical index = higher in the
// composite), skipping locked lanes, then a new lane at the top of the kind's group
// (`TrackOrder.insertIndexFor`). Never overwrite.
//
// **Clamp support.** Gesture commands with `clamp: true` use [LanePlacement.nearestFreeShift] to
// find the nearest frame shift at which a group fits on its lane.

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/items.dart';
import '../model/track.dart';
import '../time/time.dart';

/// A lane that a command will create (reported in `EditPreview.createsTracks`).
@immutable
final class NewTrack {
  /// Creates the description of a new lane.
  const NewTrack({required this.id, required this.kind, required this.index});

  /// The id the lane gets in this run (ids come from `EditContext.ids`, so a later apply with
  /// another generator state mints another id; ghosts should key on [kind] and [index]).
  final TrackId id;

  /// Lane kind.
  final TrackKind kind;

  /// Index of the lane in the resulting `Timeline.tracks`.
  final int index;

  @override
  bool operator ==(Object other) => other is NewTrack && other.id == id && other.kind == kind && other.index == index;

  @override
  int get hashCode => Object.hash(id, kind, index);

  @override
  String toString() => 'NewTrack($id, ${kind.name}, $index)';
}

/// Where an item ends up after a command: its lane and timeline range.
@immutable
final class Placement {
  /// Creates a placement on [track]; [newTrack] is set when the lane is created by the command.
  const Placement(this.track, this.range, {this.newTrack});

  /// The lane (an existing id, or the id of [newTrack]).
  final TrackId track;

  /// The item's resulting range.
  final TimeRange range;

  /// The created lane, when the item lands on a lane the command creates.
  final NewTrack? newTrack;

  /// Whether the item lands on a lane the command creates.
  bool get onNewTrack => newTrack != null;

  @override
  bool operator ==(Object other) =>
      other is Placement && other.track == track && other.range == range && other.newTrack == newTrack;

  @override
  int get hashCode => Object.hash(track, range, newTrack);

  @override
  String toString() => 'Placement($track, $range${newTrack == null ? '' : ', new'})';
}

/// Lane-search helpers (pure).
abstract final class LanePlacement {
  /// Whether items of a lane of kind [from] may move to a lane of kind [to]: equal kinds, or video
  /// and overlay (both hold visual media clips).
  static bool compatibleKinds(TrackKind from, TrackKind to) =>
      from == to ||
      ((from == TrackKind.video || from == TrackKind.overlay) && (to == TrackKind.video || to == TrackKind.overlay));

  /// Whether every range of [ranges] is free on [track], ignoring the items in [ignore].
  /// Empty ranges are always free. Cost: O(r · log n).
  static bool isFree(Track track, Iterable<TimeRange> ranges, {Set<ItemId> ignore = const {}}) {
    for (final r in ranges) {
      if (r.isEmpty) continue;
      if (firstOverlap(track, r, ignore: ignore) != null) return false;
    }
    return true;
  }

  /// The first item of [track] (in time order) overlapping [range], ignoring [ignore], or null.
  static TimelineItem? firstOverlap(Track track, TimeRange range, {Set<ItemId> ignore = const {}}) {
    final items = track.items;
    // Items are sorted and non-overlapping, so their ends ascend: find the first end > start.
    var lo = 0;
    var hi = items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (items[mid].end <= range.start) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (var i = lo; i < items.length; i++) {
      final item = items[i];
      if (item.start >= range.end) return null;
      if (!ignore.contains(item.id)) return item;
    }
    return null;
  }

  /// Indexes of the lanes of [kind] in [tracks], ordered for D-11: [preferred] first (when it is
  /// such a lane), then by distance from it, the higher index first on a tie. Without [preferred],
  /// in canonical order.
  static List<int> candidates(List<Track> tracks, TrackKind kind, {int? preferred}) {
    final lanes = <int>[
      for (var i = 0; i < tracks.length; i++)
        if (tracks[i].kind == kind) i,
    ];
    if (preferred == null) return lanes;
    final p = preferred;
    lanes.sort((a, b) {
      final da = (a - p).abs();
      final db = (b - p).abs();
      if (da != db) return da.compareTo(db);
      return b.compareTo(a);
    });
    return lanes;
  }

  /// The index of the nearest unlocked lane of [kind] (order of [candidates]) on which every range
  /// of [ranges] is free, or null when none is (the caller then creates a lane).
  static int? nearestFree(
    List<Track> tracks, {
    required TrackKind kind,
    int? preferred,
    required List<TimeRange> ranges,
    Set<ItemId> ignore = const {},
    bool Function(Track track)? accept,
  }) {
    for (final i in candidates(tracks, kind, preferred: preferred)) {
      final t = tracks[i];
      if (t.locked) continue;
      if (accept != null && !accept(t)) continue;
      if (isFree(t, ranges, ignore: ignore)) return i;
    }
    return null;
  }

  /// The free span of [track] containing [t] (ignoring [ignore]): from the end of the item before
  /// it (or 0) to the start of the item after it (or [maxProjectDurationUs]). Null when [t] lies
  /// inside an item.
  static TimeRange? freeSpanAt(Track track, TimeUs t, {Set<ItemId> ignore = const {}}) {
    var lo = 0;
    var hi = maxProjectDurationUs;
    for (final item in track.items) {
      if (ignore.contains(item.id)) continue;
      if (item.start <= t && t < item.end) return null;
      if (item.end <= t && item.end > lo) lo = item.end;
      if (item.start > t && item.start < hi) hi = item.start;
    }
    return TimeRange(lo, hi);
  }

  /// The frame shift nearest to [desiredShift] (ties: the smaller shift) at which every frame range
  /// `[k0, k1)` of [frameRanges] is free on [track] (ignoring [ignore]) and starts at frame ≥ 0.
  /// Returns null when no shift fits within [maxProjectDurationUs].
  ///
  /// Candidates are [desiredShift] and every shift that makes a group range touch an obstacle edge,
  /// so the search is O((n·r)·r·log n) for n obstacles and r ranges — gesture-time only.
  static int? nearestFreeShift(
    Track track,
    List<(int, int)> frameRanges,
    int desiredShift,
    FrameRate rate, {
    Set<ItemId> ignore = const {},
  }) {
    if (frameRanges.isEmpty) return desiredShift;
    var minK0 = frameRanges.first.$1;
    for (final r in frameRanges) {
      if (r.$1 < minK0) minK0 = r.$1;
    }
    final lowest = -minK0;
    final candidateShifts = <int>{desiredShift < lowest ? lowest : desiredShift, lowest};
    for (final item in track.items) {
      if (ignore.contains(item.id)) continue;
      final s = rate.frameIndexOf(item.start);
      final e = rate.frameIndexOf(item.end);
      for (final r in frameRanges) {
        candidateShifts
          ..add(e - r.$1) // range starts where the obstacle ends
          ..add(s - r.$2); // range ends where the obstacle starts
      }
    }
    final sorted = candidateShifts.where((d) => d >= lowest).toList()
      ..sort((a, b) {
        final da = (a - desiredShift).abs();
        final db = (b - desiredShift).abs();
        return da != db ? da.compareTo(db) : a.compareTo(b);
      });
    final maxFrame = rate.frameIndexOf(maxProjectDurationUs);
    for (final d in sorted) {
      var ok = true;
      for (final r in frameRanges) {
        if (r.$2 + d > maxFrame) {
          ok = false;
          break;
        }
        final range = TimeRange(rate.timeOfFrame(r.$1 + d), rate.timeOfFrame(r.$2 + d));
        if (firstOverlap(track, range, ignore: ignore) != null) {
          ok = false;
          break;
        }
      }
      if (ok) return d;
    }
    return null;
  }
}
