// OWNER: CORE-36
//
// Visual packing (ARCH §13.5, D-14, review issue 3): assigns every decoder-backed media layer a
// visual sequence / composition-track slot `seq` and counts what the platforms need:
//
// * `visualSequences` = the slot count — Android builds one `EditedMediaItemSequence` per slot,
//   iOS one composition video track per slot (cap `maxVisualSequences`);
// * `peakConcurrentDecoders` = the most decoder-backed layers active at one instant (cap
//   `maxConcurrentVideoLayers`).
//
// One implementation serves `LayerLimits` (CORE-09, after every command, from the model through
// [packingInputsOf] without compiling), the compiler (CORE-30 assigns the plan's `seq` with
// [packVisualLayers]) and both engines (IOS-08/AND-08 read `seq` as-is and check the shared
// vectors in `test/fixtures/vectors/packing.json`).
//
// Rules (ARCH §13.5):
// 1. layers in one slot never overlap in time (half-open ranges);
// 2. slots have a fixed stacking order (seq 0 is the bottom); two layers may share a slot only if
//    no layer of another slot that overlaps either of them in time lies between them in draw
//    order (`z`, then `t0`) during that overlap — equivalently, every pair of time-overlapping
//    layers in different slots is stacked in draw order;
// 3. deterministic greedy first-fit in draw order (ascending `z`, then `t0`, then `id`): a layer
//    goes to the lowest slot above every slot holding a layer that overlaps it in time
//    (`seq = 1 + max seq of the overlapping layers placed so far`, 0 when none). Transition A/B
//    windows on one lane therefore take a second slot only for the overlapping layers.

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/items.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/project.dart';
import '../model/settings.dart';
import '../model/track.dart';
import '../plan/render_plan.dart';
import '../time/time.dart';

/// One visual layer to pack: its plan layer id, opaque sort key `z` (ARCH §11.4), half-open
/// timeline range `[t0, t1)` and whether it needs a decoder (video media, including `hold`
/// layers). Images, solids and sprites are not decoder-backed and do not count (D-14).
@immutable
final class PackInput {
  /// Creates an input; [t1] must be after [t0].
  const PackInput(this.id, this.z, this.t0, this.t1, {this.decoderBacked = true}) : assert(t1 > t0);

  /// Plan layer id (`<itemId>#v`, `<itemId>#bd`).
  final String id;

  /// Sort key of the layer's lane (ARCH §11.4).
  final int z;

  /// Range start (inclusive).
  final TimeUs t0;

  /// Range end (exclusive).
  final TimeUs t1;

  /// Whether the layer needs a video decoder.
  final bool decoderBacked;

  /// Canonical JSON (the `packing.json` vector format).
  Map<String, Object?> toJson() => {'id': id, 'z': z, 't0': t0, 't1': t1, 'decoderBacked': decoderBacked};

  /// Decodes [toJson].
  factory PackInput.fromJson(Map<String, Object?> j) => PackInput(
        j['id']! as String,
        j['z']! as int,
        j['t0']! as int,
        j['t1']! as int,
        decoderBacked: (j['decoderBacked'] as bool?) ?? true,
      );

  @override
  bool operator ==(Object other) =>
      other is PackInput &&
      other.id == id &&
      other.z == z &&
      other.t0 == t0 &&
      other.t1 == t1 &&
      other.decoderBacked == decoderBacked;

  @override
  int get hashCode => Object.hash(id, z, t0, t1, decoderBacked);

  @override
  String toString() => 'PackInput($id, z: $z, [$t0, $t1)${decoderBacked ? '' : ', image'})';
}

/// The result of [packVisualLayers].
@immutable
final class PackResult {
  PackResult._(this._seq, this.slotCount, this.peakConcurrentDecoders, this.decoderSlotCount);

  /// No layers.
  static final PackResult empty = PackResult._(const {}, 0, 0, 0);

  final Map<String, int> _seq;

  /// Number of slots used (`visualSequences`, D-14 cap `maxVisualSequences`).
  final int slotCount;

  /// The most decoder-backed layers active at one instant (D-14 cap `maxConcurrentVideoLayers`).
  final int peakConcurrentDecoders;

  /// Number of slots holding at least one decoder-backed layer (equals [slotCount] when only
  /// media layers are packed, as the compiler and [packingInputsOf] do).
  final int decoderSlotCount;

  /// Alias of [slotCount] (ARCH §13.5 `visualSequences`).
  int get visualSequences => slotCount;

  /// The slot of layer [id]. Throws [ArgumentError] for an id that was not packed.
  int seqOf(String id) {
    final s = _seq[id];
    if (s == null) throw ArgumentError.value(id, 'id', 'was not packed');
    return s;
  }

  /// The slot of layer [id], or null when it was not packed.
  int? trySeqOf(String id) => _seq[id];

  /// Slots by layer id (unmodifiable).
  Map<String, int> get seqById => Map.unmodifiable(_seq);

  /// Whether both D-14 counts are within the given caps.
  bool withinCaps({required int maxConcurrentVideoLayers, required int maxVisualSequences}) =>
      peakConcurrentDecoders <= maxConcurrentVideoLayers && slotCount <= maxVisualSequences;

  @override
  bool operator ==(Object other) =>
      other is PackResult &&
      other.slotCount == slotCount &&
      other.peakConcurrentDecoders == peakConcurrentDecoders &&
      other.decoderSlotCount == decoderSlotCount &&
      _mapEquals(other._seq, _seq);

  @override
  int get hashCode => Object.hash(slotCount, peakConcurrentDecoders, decoderSlotCount, _seq.length);

  static bool _mapEquals(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }
}

/// Draw order of two inputs: ascending `z`, then `t0`, then `id` (ARCH §11.2 layer order).
int comparePackInputs(PackInput a, PackInput b) {
  if (a.z != b.z) return a.z < b.z ? -1 : 1;
  if (a.t0 != b.t0) return a.t0 < b.t0 ? -1 : 1;
  return a.id.compareTo(b.id);
}

/// Packs [inputs] into slots (ARCH §13.5; rules in the file header). Deterministic: the result
/// depends only on the set of inputs, not their order. Throws [ArgumentError] on duplicate ids.
///
/// Cost: O(n·(log n + slots·log m)) — a sort (skipped when the inputs are already in draw order)
/// and, per layer, a binary search in each slot from the top down.
PackResult packVisualLayers(List<PackInput> inputs) {
  if (inputs.isEmpty) return PackResult.empty;
  var sorted = inputs;
  for (var i = 1; i < inputs.length; i++) {
    if (comparePackInputs(inputs[i - 1], inputs[i]) > 0) {
      sorted = List.of(inputs)..sort(comparePackInputs);
      break;
    }
  }
  final slots = <_Slot>[];
  final seq = <String, int>{};
  for (final l in sorted) {
    // Highest slot holding a layer that overlaps l in time: l must go right above it.
    var target = 0;
    for (var s = slots.length - 1; s >= 0; s--) {
      if (slots[s].overlaps(l.t0, l.t1)) {
        target = s + 1;
        break;
      }
    }
    if (target == slots.length) slots.add(_Slot());
    slots[target].insert(l.t0, l.t1, l.decoderBacked);
    if (seq.containsKey(l.id)) throw ArgumentError.value(l.id, 'inputs', 'duplicate layer id');
    seq[l.id] = target;
  }
  return PackResult._(
    seq,
    slots.length,
    _peakFromSlots(slots),
    slots.where((s) => s.decoderBacked).length,
  );
}

/// [peakConcurrentDecoders] from packed slots: a slot holds disjoint ranges sorted by start (so
/// its ends are sorted too), so the decoder starts and ends of all slots merge in O(n·slots)
/// without a comparison sort.
int _peakFromSlots(List<_Slot> slots) {
  var starts = <int>[];
  var ends = <int>[];
  for (final slot in slots) {
    if (!slot.decoderBacked) continue;
    final s = <int>[];
    final e = <int>[];
    for (var i = 0; i < slot._starts.length; i++) {
      if (!slot._decoder[i]) continue;
      s.add(slot._starts[i]);
      e.add(slot._ends[i]);
    }
    starts = _merge(starts, s);
    ends = _merge(ends, e);
  }
  var cur = 0;
  var peak = 0;
  var j = 0;
  for (var i = 0; i < starts.length; i++) {
    // Ends at or before this start come first (half-open ranges).
    while (j < ends.length && ends[j] <= starts[i]) {
      cur--;
      j++;
    }
    cur++;
    if (cur > peak) peak = cur;
  }
  return peak;
}

List<int> _merge(List<int> a, List<int> b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final out = List<int>.filled(a.length + b.length, 0);
  var i = 0, j = 0, k = 0;
  while (i < a.length && j < b.length) {
    out[k++] = a[i] <= b[j] ? a[i++] : b[j++];
  }
  while (i < a.length) {
    out[k++] = a[i++];
  }
  while (j < b.length) {
    out[k++] = b[j++];
  }
  return out;
}

/// The most decoder-backed inputs active at one instant (half-open ranges: a layer ending at `t`
/// and one starting at `t` are not concurrent).
int peakConcurrentDecoders(List<PackInput> inputs) {
  final n = inputs.where((l) => l.decoderBacked).length;
  if (n == 0) return 0;
  // Events encoded as time·2 + (0 for an end, 1 for a start): ends sort before starts at a tie.
  final events = List<int>.filled(2 * n, 0);
  var k = 0;
  for (final l in inputs) {
    if (!l.decoderBacked) continue;
    events[k++] = l.t0 * 2 + 1;
    events[k++] = l.t1 * 2;
  }
  events.sort();
  var cur = 0;
  var peak = 0;
  for (final e in events) {
    if (e.isOdd) {
      cur++;
      if (cur > peak) peak = cur;
    } else {
      cur--;
    }
  }
  return peak;
}

/// One slot: its layers' ranges, sorted by start and non-overlapping.
final class _Slot {
  final List<int> _starts = [];
  final List<int> _ends = [];
  final List<bool> _decoder = [];
  bool decoderBacked = false;

  /// Index of the first range whose start is ≥ [t].
  int _lowerBound(int t) {
    var lo = 0;
    var hi = _starts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_starts[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Whether a range of this slot intersects `[t0, t1)`.
  bool overlaps(int t0, int t1) {
    // The last range starting before t1 is the only candidate (ranges are disjoint and sorted).
    final i = _lowerBound(t1) - 1;
    return i >= 0 && _ends[i] > t0;
  }

  void insert(int t0, int t1, bool decoder) {
    final i = _lowerBound(t0);
    _starts.insert(i, t0);
    _ends.insert(i, t1);
    _decoder.insert(i, decoder);
    if (decoder) decoderBacked = true;
  }
}

// ---------------------------------------------------------------------------------------------
// Model-derived inputs.
// ---------------------------------------------------------------------------------------------

/// The z of a lane's clip layers (ARCH §11.4): `band·10000 + (laneIndexInBand + 1)·10`, where
/// `laneIndexInBand` counts the lanes of the same kind in canonical order (hidden lanes
/// included). Backdrops (`#bd`) use `z − 5`, transition helper solids `z + 5`.
int laneZ(TrackKind kind, int laneIndexInBand) => kind.band! * 10000 + (laneIndexInBand + 1) * 10;

/// Whether a clip of [asset] lowers to a decoder-backed `media` layer (ARCH §11.7): video media
/// (forward, reversed or pending reverse), and a still that is not ready yet when the engine can
/// hold frames ([holdFrame]; the compiler then emits a `hold` layer over the original video).
/// Images, ready stills and audio do not.
bool isDecoderBackedVisual(MediaAsset asset, {bool holdFrame = true}) => switch (asset.kind) {
      MediaKind.video => true,
      MediaKind.still => holdFrame && asset.status is! ReadyStatus && asset.derived is StillSpec,
      _ => false,
    };

/// The packing inputs of the visual lanes of [project], derived from the model with the
/// compiler's lowering rules (ARCH §11.7, §13.5) so `LayerLimits` can run after every command
/// without compiling:
///
/// * one `<itemId>#v` input per media clip on a visible video/overlay lane whose asset is
///   decoder-backed ([isDecoderBackedVisual]); clips whose asset is missing are skipped (the
///   compiler emits an offline solid);
/// * overlap transitions (cross dissolve, slide, wipe, zoom) of `n` frames at cut frame `c`
///   extend the outgoing clip to `c + ⌈n/2⌉` and the incoming clip back to `c − ⌊n/2⌋`
///   (window `[c − ⌊n/2⌋, c + ⌈n/2⌉)` frames); fades and dips do not extend;
/// * with a `BlurOfMain` background, every main-lane input gets a `<itemId>#bd` backdrop with the
///   same range at `z − 5`;
/// * z from [laneZ].
///
/// [laneFilter] limits the result to those lanes (incremental use: re-derive only the changed
/// lanes, see [PackingInputCache]). The result is in draw order.
List<PackInput> packingInputsOf(EditProject project, {Set<TrackId>? laneFilter, bool holdFrame = true}) {
  final out = <PackInput>[];
  final laneIndex = <TrackKind, int>{};
  final settings = project.settings;
  for (final track in project.tracks) {
    final kind = track.kind;
    if (kind != TrackKind.video && kind != TrackKind.overlay) continue;
    final index = laneIndex[kind] ?? 0;
    laneIndex[kind] = index + 1;
    if (laneFilter != null && !laneFilter.contains(track.id)) continue;
    out.addAll(laneInputsOf(track, laneZ(kind, index), settings, project.pool, holdFrame: holdFrame));
  }
  out.sort(comparePackInputs);
  return out;
}

/// The packing inputs of one visual [track] whose clip layers sit at [z] ([packingInputsOf]
/// rules), in draw order. Empty for hidden lanes and non-visual-media lanes.
List<PackInput> laneInputsOf(Track track, int z, ProjectSettings settings, MediaPool pool, {bool holdFrame = true}) {
  if (track.hidden) return const [];
  if (track.kind != TrackKind.video && track.kind != TrackKind.overlay) return const [];
  final rate = settings.frameRate;
  final items = track.items;
  // Transition extensions by item id.
  final extendEnd = <ItemId, TimeUs>{};
  final extendStart = <ItemId, TimeUs>{};
  if (track.transitions.isNotEmpty) {
    final byId = <ItemId, TimelineItem>{for (final i in items) i.id: i};
    for (final tr in track.transitions) {
      if (!tr.kind.needsHandles || tr.durationFrames <= 0) continue;
      final left = byId[tr.left];
      final right = byId[tr.right];
      if (left == null || right == null || left.end != right.start) continue;
      final c = rate.frameIndexOf(left.end);
      final n = tr.durationFrames;
      extendEnd[left.id] = rate.timeOfFrame(c + (n + 1) ~/ 2);
      extendStart[right.id] = rate.timeOfFrame(c - n ~/ 2);
    }
  }
  final backdrop = track.isMain && settings.background is BlurOfMainBackground;
  final out = <PackInput>[];
  final backdrops = <PackInput>[];
  for (final item in items) {
    if (item is! MediaClip) continue;
    final asset = pool[item.media];
    if (asset == null || !isDecoderBackedVisual(asset, holdFrame: holdFrame)) continue;
    final t0 = extendStart[item.id] ?? item.start;
    final t1 = extendEnd[item.id] ?? item.end;
    if (t1 <= t0) continue;
    out.add(PackInput(PlanIds.visual(item.id), z, t0, t1));
    if (backdrop) backdrops.add(PackInput(PlanIds.backdrop(item.id), z - 5, t0, t1));
  }
  out.sort(comparePackInputs);
  return backdrops.isEmpty ? out : [...backdrops, ...out];
}

/// Memoizes [laneInputsOf] per lane so `LayerLimits` re-derives only the lanes a command changed
/// (tracks are immutable and structurally shared, so an unchanged lane is the identical object).
///
/// An entry is reused when the track object, its z, the frame rate, the background kind, the pool
/// object and [holdFrame] are all unchanged; any other change re-derives that lane.
final class PackingInputCache {
  /// Creates an empty cache for engines that can ([holdFrame] true) or cannot hold frames.
  PackingInputCache({this.holdFrame = true});

  /// Whether pending stills lower to decoder-backed `hold` layers.
  final bool holdFrame;

  final Map<TrackId, _LaneEntry> _lanes = {};

  /// Number of lanes derived by the last [inputsOf] call (for tests and benchmarks).
  int lastDerived = 0;

  /// The packing inputs of [project] ([packingInputsOf]) in draw order, re-deriving only lanes
  /// whose inputs may have changed.
  List<PackInput> inputsOf(EditProject project) {
    final settings = project.settings;
    final blur = settings.background is BlurOfMainBackground;
    final pool = project.pool;
    final laneIndex = <TrackKind, int>{};
    final seen = <TrackId>{};
    final lists = <List<PackInput>>[];
    var derived = 0;
    for (final track in project.tracks) {
      final kind = track.kind;
      if (kind != TrackKind.video && kind != TrackKind.overlay) continue;
      final index = laneIndex[kind] ?? 0;
      laneIndex[kind] = index + 1;
      final z = laneZ(kind, index);
      seen.add(track.id);
      final e = _lanes[track.id];
      if (e != null &&
          identical(e.track, track) &&
          e.z == z &&
          e.rate == settings.frameRate &&
          e.blur == blur &&
          identical(e.pool, pool)) {
        lists.add(e.inputs);
        continue;
      }
      final inputs = laneInputsOf(track, z, settings, pool, holdFrame: holdFrame);
      derived++;
      _lanes[track.id] = _LaneEntry(track, z, settings.frameRate, blur, pool, inputs);
      lists.add(inputs);
    }
    _lanes.removeWhere((id, _) => !seen.contains(id));
    lastDerived = derived;
    // Lanes come in ascending z within a band and bands ascend, but the main lane's backdrops
    // (z − 5) precede its clips; concatenation is therefore already in draw order.
    return [for (final l in lists) ...l];
  }

  /// Packs [project] ([packVisualLayers] of [inputsOf]).
  PackResult pack(EditProject project) => packVisualLayers(inputsOf(project));

  /// Forgets every lane.
  void clear() => _lanes.clear();
}

final class _LaneEntry {
  _LaneEntry(this.track, this.z, this.rate, this.blur, this.pool, this.inputs);
  final Track track;
  final int z;
  final FrameRate rate;
  final bool blur;
  final MediaPool pool;
  final List<PackInput> inputs;
}
