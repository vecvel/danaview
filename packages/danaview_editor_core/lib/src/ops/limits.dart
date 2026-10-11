// OWNER: CORE-09
//
// Project and device limits checked generically after every command (ARCH §7.1, D-14):
//
// * items ≤ `EditPolicy.maxItems` (5,000);
// * project duration ≤ 24 h;
// * peak concurrent decoder-backed video layers ≤ `EditPolicy.maxConcurrentVideoLayers`;
// * packed visual sequences ≤ `EditPolicy.maxVisualSequences`.
//
// The two layer counts come from CORE-36's `eval/visual_packing.dart` (one implementation shared
// with the compiler and both engines), derived from the model without compiling and incrementally:
// a per-session [PackingInputCache] re-derives only the lanes a command replaced, and commands
// that leave every visual lane, the pool and the settings untouched skip packing entirely.
//
// **Never lock users out (D-14).** A project that already exceeds a cap (opened from another
// device) stays editable: a command is refused only when it makes a count that is over its cap
// larger than it was before the command. Reducing edits are always allowed.

import 'package:meta/meta.dart';

import '../eval/visual_packing.dart';
import '../model/project.dart';
import '../model/track.dart';
import '../time/time.dart';
import 'edit_context.dart';
import 'rejections.dart';

/// The counts that [LayerLimits] checks, for one project.
@immutable
final class LimitCounts {
  /// Creates counts.
  const LimitCounts({
    required this.items,
    required this.duration,
    required this.peakConcurrentVideoLayers,
    required this.visualSequences,
  });

  /// Timeline items over all lanes.
  final int items;

  /// End of the last item.
  final TimeUs duration;

  /// Most decoder-backed video layers active at one instant.
  final int peakConcurrentVideoLayers;

  /// Packed visual sequences.
  final int visualSequences;

  /// The limits that [policy] says these counts exceed, as `LimitExceeded` rejections (empty
  /// when within every limit). The editor shows a banner and export preflight refuses while this
  /// is non-empty (D-14).
  List<LimitExceeded> exceeded(EditPolicy policy) => [
        if (items > policy.maxItems) LimitExceeded(LimitExceeded.items, policy.maxItems),
        if (duration > maxProjectDurationUs) const LimitExceeded(LimitExceeded.duration, maxProjectDurationUs),
        if (peakConcurrentVideoLayers > policy.maxConcurrentVideoLayers)
          LimitExceeded(LimitExceeded.concurrentVideoLayers, policy.maxConcurrentVideoLayers),
        if (visualSequences > policy.maxVisualSequences)
          LimitExceeded(LimitExceeded.visualSequences, policy.maxVisualSequences),
      ];

  @override
  bool operator ==(Object other) =>
      other is LimitCounts &&
      other.items == items &&
      other.duration == duration &&
      other.peakConcurrentVideoLayers == peakConcurrentVideoLayers &&
      other.visualSequences == visualSequences;

  @override
  int get hashCode => Object.hash(items, duration, peakConcurrentVideoLayers, visualSequences);

  @override
  String toString() =>
      'LimitCounts(items: $items, duration: $duration, peak: $peakConcurrentVideoLayers, sequences: $visualSequences)';
}

/// Checks the D-14, item and duration limits after a command (ARCH §7.1). Keep one instance per
/// editing session (it lives in `EditContext.limits`) so packing stays incremental.
final class LayerLimits {
  /// Creates a checker. [holdFrame] says whether the engine holds frames for pending stills (then
  /// they count as decoder-backed layers, as the compiler lowers them).
  LayerLimits({this.holdFrame = true}) : _cache = PackingInputCache(holdFrame: holdFrame);

  /// Whether pending stills lower to decoder-backed `hold` layers.
  final bool holdFrame;

  final PackingInputCache _cache;

  // Memo of the last two packed (timeline, pool) pairs: the base of a command is usually the
  // result the previous check packed.
  final List<_Packed> _memo = [];

  /// Number of packings computed (tests and benchmarks: 0 when a check took the fast path).
  int packCount = 0;

  /// Packs the visual layers of [project] ([packVisualLayers] of [packingInputsOf]), incrementally.
  PackResult pack(EditProject project) {
    for (final m in _memo) {
      if (identical(m.timeline, project.timeline) && identical(m.pool, project.pool)) return m.result;
    }
    packCount++;
    final result = _cache.pack(project);
    _memo.insert(0, _Packed(project.timeline, project.pool, result));
    if (_memo.length > 2) _memo.removeLast();
    return result;
  }

  /// Every count of [project].
  LimitCounts countsOf(EditProject project) {
    final packed = pack(project);
    return LimitCounts(
      items: itemCount(project),
      duration: project.duration,
      peakConcurrentVideoLayers: packed.peakConcurrentDecoders,
      visualSequences: packed.slotCount,
    );
  }

  /// The rejection for [after] (the result of a command applied to [before]) under [policy], or
  /// null when it is within the limits or does not make any exceeded count worse.
  EditRejection? check(EditProject before, EditProject after, EditPolicy policy) {
    final items = itemCount(after);
    if (items > policy.maxItems && items > itemCount(before)) {
      return LimitExceeded(LimitExceeded.items, policy.maxItems);
    }
    final duration = after.duration;
    if (duration > maxProjectDurationUs && duration > before.duration) {
      return const LimitExceeded(LimitExceeded.duration, maxProjectDurationUs);
    }
    if (visualLayersUnchanged(before, after)) return null;
    final a = pack(after);
    final peakOver = a.peakConcurrentDecoders > policy.maxConcurrentVideoLayers;
    final seqOver = a.slotCount > policy.maxVisualSequences;
    if (!peakOver && !seqOver) return null;
    final b = pack(before);
    if (peakOver && a.peakConcurrentDecoders > b.peakConcurrentDecoders) {
      return LimitExceeded(LimitExceeded.concurrentVideoLayers, policy.maxConcurrentVideoLayers);
    }
    if (seqOver && a.slotCount > b.slotCount) {
      return LimitExceeded(LimitExceeded.visualSequences, policy.maxVisualSequences);
    }
    return null;
  }

  /// Whether [after] has exactly the visual lanes (identical objects, same order), pool and
  /// layer-relevant settings of [before], so the packing counts cannot differ.
  static bool visualLayersUnchanged(EditProject before, EditProject after) {
    if (!identical(before.pool, after.pool)) return false;
    final sb = before.settings;
    final sa = after.settings;
    if (!identical(sb, sa) && (sb.frameRate != sa.frameRate || sb.background.runtimeType != sa.background.runtimeType)) {
      return false;
    }
    final tb = before.tracks;
    final ta = after.tracks;
    var i = 0;
    var j = 0;
    while (true) {
      while (i < tb.length && !_packed(tb[i].kind)) {
        i++;
      }
      while (j < ta.length && !_packed(ta[j].kind)) {
        j++;
      }
      if (i == tb.length || j == ta.length) return i == tb.length && j == ta.length;
      if (!identical(tb[i], ta[j])) return false;
      i++;
      j++;
    }
  }

  static bool _packed(TrackKind kind) => kind == TrackKind.video || kind == TrackKind.overlay;

  /// Timeline items over all lanes of [project].
  static int itemCount(EditProject project) {
    var n = 0;
    for (final t in project.tracks) {
      n += t.items.length;
    }
    return n;
  }
}

final class _Packed {
  _Packed(this.timeline, this.pool, this.result);
  final Object timeline;
  final Object pool;
  final PackResult result;
}
