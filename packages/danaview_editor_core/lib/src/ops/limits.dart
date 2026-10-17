// OWNER: CORE-09
// (shared with CORE-38, which made the two layer caps informational: BUILD_PLAN §7)
//
// Project and device limits checked generically after every command (ARCH §7.1, D-14):
//
// * items ≤ `EditPolicy.maxItems` (5,000): hard limit;
// * project duration ≤ 24 h: hard limit;
// * peak concurrent decoder-backed video layers vs `EditPolicy.maxConcurrentVideoLayers` and
//   packed visual sequences vs `EditPolicy.maxVisualSequences`: **live preview only** (CORE-38,
//   D-14, D-45(B), owner decision 2026-10-11, D-43(e) point 7). A command is never refused for
//   either layer cap; [LimitCounts.previewCap] reports the informational [PreviewCapStatus] that
//   the preview layer (proxies, paused-exact still frames, the render-preview cache) and the
//   export layer (multi-pass precompose) use. It is never a rejection, an exception or a banner.
//   `LimitExceeded.visualSequences` / `.concurrentVideoLayers` stay declared (rejections.dart) so
//   existing message mappings compile, but core no longer produces them.
//
// The two layer counts come from CORE-36's `eval/visual_packing.dart` (one implementation shared
// with the compiler and both engines), derived from the model without compiling and incrementally:
// a per-session [PackingInputCache] re-derives only the lanes a command replaced, and commands
// that leave every visual lane, the pool and the settings untouched skip packing entirely.
//
// **Never lock users out (D-14).** A project that already exceeds a hard limit (opened from
// another device) stays editable: a command is refused only when it makes a count that is over its
// limit larger than it was before the command. Reducing edits are always allowed.

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

  /// The hard limits (items, duration) that [policy] says these counts exceed, as
  /// `LimitExceeded` rejections (empty when within them). The layer caps are never listed here:
  /// they limit live preview only and are reported by [previewCap] (CORE-38, D-45(B)).
  List<LimitExceeded> exceeded(EditPolicy policy) => [
        if (items > policy.maxItems) LimitExceeded(LimitExceeded.items, policy.maxItems),
        if (duration > maxProjectDurationUs) const LimitExceeded(LimitExceeded.duration, maxProjectDurationUs),
      ];

  /// The informational live-preview state of these counts under [policy] (CORE-38): data for the
  /// preview and export layers, never a rejection.
  PreviewCapStatus previewCap(EditPolicy policy) => PreviewCapStatus(
        visualSequences: visualSequences,
        maxVisualSequences: policy.maxVisualSequences,
        peakConcurrentVideoLayers: peakConcurrentVideoLayers,
        maxConcurrentVideoLayers: policy.maxConcurrentVideoLayers,
      );

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

/// Whether a project is above the live-preview layer caps (ARCH D-14, D-45(B); CORE-38).
///
/// Above either cap, live preview uses proxies, paused-exact still frames during playback and the
/// render-preview cache (CORE-37's `heavyRanges`), and export runs the multi-pass precompose
/// (IOS-20, AND-19). Editing is never blocked and export never refuses because of it.
@immutable
final class PreviewCapStatus {
  /// Creates a status from the counts and the caps.
  const PreviewCapStatus({
    required this.visualSequences,
    required this.maxVisualSequences,
    required this.peakConcurrentVideoLayers,
    required this.maxConcurrentVideoLayers,
  });

  /// Packed visual sequences of the project.
  final int visualSequences;

  /// The live-preview cap on [visualSequences] (`EditPolicy.maxVisualSequences`).
  final int maxVisualSequences;

  /// Most decoder-backed video layers active at one instant.
  final int peakConcurrentVideoLayers;

  /// The live-preview cap on [peakConcurrentVideoLayers] (`EditPolicy.maxConcurrentVideoLayers`).
  final int maxConcurrentVideoLayers;

  /// Whether [visualSequences] is over its cap.
  bool get aboveSequenceCap => visualSequences > maxVisualSequences;

  /// Whether [peakConcurrentVideoLayers] is over its cap.
  bool get aboveConcurrentLayerCap => peakConcurrentVideoLayers > maxConcurrentVideoLayers;

  /// Whether either layer count is over its cap.
  bool get aboveLivePreviewCap => aboveSequenceCap || aboveConcurrentLayerCap;

  @override
  bool operator ==(Object other) =>
      other is PreviewCapStatus &&
      other.visualSequences == visualSequences &&
      other.maxVisualSequences == maxVisualSequences &&
      other.peakConcurrentVideoLayers == peakConcurrentVideoLayers &&
      other.maxConcurrentVideoLayers == maxConcurrentVideoLayers;

  @override
  int get hashCode => Object.hash(visualSequences, maxVisualSequences, peakConcurrentVideoLayers, maxConcurrentVideoLayers);

  @override
  String toString() => 'PreviewCapStatus(aboveLivePreviewCap: $aboveLivePreviewCap, sequences: $visualSequences/$maxVisualSequences, '
      'peak: $peakConcurrentVideoLayers/$maxConcurrentVideoLayers)';
}

/// Checks the D-14 item and duration limits after a command (ARCH §7.1). Keep one instance per
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

  // The project and policy of the last [check] (the command's result, or its base when the visual
  // layers are unchanged and the counts therefore equal), resolved lazily by [lastPreviewCap].
  EditProject? _lastChecked;
  EditPolicy? _lastPolicy;
  PreviewCapStatus? _lastStatus;

  /// The live-preview state of the result of the last command [check]ed (by `applyCommand` or
  /// `dryRun`, which share this path; for a command refused by a hard limit, of its unchanged
  /// base), or null before any check (CORE-38). Commands that leave
  /// the visual lanes alone reuse the base's packing, so reading this never re-packs for them.
  PreviewCapStatus? get lastPreviewCap {
    final p = _lastChecked;
    if (p == null) return null;
    return _lastStatus ??= countsOf(p).previewCap(_lastPolicy!);
  }

  /// The live-preview state of [project] under [policy] (CORE-38).
  PreviewCapStatus previewCapOf(EditProject project, EditPolicy policy) => countsOf(project).previewCap(policy);

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
  /// null when it is within the hard limits or does not make any exceeded count worse.
  ///
  /// Only the item and duration limits reject. The layer caps never do (CORE-38): the check packs
  /// [after] when its visual layers changed (incrementally, keeping the session cache warm) and
  /// records the informational state for [lastPreviewCap].
  EditRejection? check(EditProject before, EditProject after, EditPolicy policy) {
    _lastPolicy = policy;
    _lastStatus = null;
    // A refused command leaves [before] in place: its state is the one to report.
    _lastChecked = before;
    final items = itemCount(after);
    if (items > policy.maxItems && items > itemCount(before)) {
      return LimitExceeded(LimitExceeded.items, policy.maxItems);
    }
    final duration = after.duration;
    if (duration > maxProjectDurationUs && duration > before.duration) {
      return const LimitExceeded(LimitExceeded.duration, maxProjectDurationUs);
    }
    if (!visualLayersUnchanged(before, after)) {
      _lastChecked = after;
      pack(after);
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
