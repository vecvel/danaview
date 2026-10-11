// OWNER: CORE-09
//
// The inputs of a command besides the project (ARCH §7.1): where new ids come from, the clock,
// and the editing policy (overlap resolution, default durations and the D-14 limits).

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/pool/media_pool.dart';
import '../time/time.dart';
import 'limits.dart';

/// What happens when a non-ripple move, paste or insert lands on occupied space.
enum OverlapPolicy {
  /// Go to the nearest free lane of the same kind, creating one if needed (D-11, the default).
  newLane,

  /// Refuse with `WouldOverlap` (or clamp to the nearest free position for `clamp: true`
  /// gestures).
  reject,
}

/// Editing policy: defaults and limits (ARCH §7.1, D-11, D-14).
@immutable
final class EditPolicy {
  /// Creates a policy. The layer caps default to the mid device tier (D-14); the session builds
  /// the policy from `EditorCapabilities`.
  const EditPolicy({
    this.overlap = OverlapPolicy.newLane,
    this.defaultImageUs = 3 * microsPerSecond,
    this.defaultTextUs = 3 * microsPerSecond,
    this.defaultCueUs = 2 * microsPerSecond,
    this.maxConcurrentVideoLayers = 4,
    this.maxVisualSequences = 6,
    this.maxItems = 5000,
  });

  /// Overlap resolution for non-ripple placement.
  final OverlapPolicy overlap;

  /// Duration of an inserted image or still (quantized to the nearest frame, ≥ 1 frame).
  final TimeUs defaultImageUs;

  /// Duration of a new text item.
  final TimeUs defaultTextUs;

  /// Duration of a new subtitle cue.
  final TimeUs defaultCueUs;

  /// D-14 cap (1): decoder-backed video layers active at one instant (2 minimal / 3 low / 4 mid /
  /// 6 high; Android ≤ codec instances − 1).
  final int maxConcurrentVideoLayers;

  /// D-14 cap (2): packed visual sequences for the whole project (ARCH §13.5; Android 3/4/6/8,
  /// iOS 16).
  final int maxVisualSequences;

  /// Most timeline items in a project (5,000).
  final int maxItems;

  /// A copy with the given fields replaced.
  EditPolicy copyWith({
    OverlapPolicy? overlap,
    TimeUs? defaultImageUs,
    TimeUs? defaultTextUs,
    TimeUs? defaultCueUs,
    int? maxConcurrentVideoLayers,
    int? maxVisualSequences,
    int? maxItems,
  }) =>
      EditPolicy(
        overlap: overlap ?? this.overlap,
        defaultImageUs: defaultImageUs ?? this.defaultImageUs,
        defaultTextUs: defaultTextUs ?? this.defaultTextUs,
        defaultCueUs: defaultCueUs ?? this.defaultCueUs,
        maxConcurrentVideoLayers: maxConcurrentVideoLayers ?? this.maxConcurrentVideoLayers,
        maxVisualSequences: maxVisualSequences ?? this.maxVisualSequences,
        maxItems: maxItems ?? this.maxItems,
      );

  @override
  bool operator ==(Object other) =>
      other is EditPolicy &&
      other.overlap == overlap &&
      other.defaultImageUs == defaultImageUs &&
      other.defaultTextUs == defaultTextUs &&
      other.defaultCueUs == defaultCueUs &&
      other.maxConcurrentVideoLayers == maxConcurrentVideoLayers &&
      other.maxVisualSequences == maxVisualSequences &&
      other.maxItems == maxItems;

  @override
  int get hashCode => Object.hash(
      overlap, defaultImageUs, defaultTextUs, defaultCueUs, maxConcurrentVideoLayers, maxVisualSequences, maxItems);
}

/// Everything a command needs besides the project (ARCH §7.1).
///
/// Commands are pure: the same project, command and context (with a [SeededIdGenerator] in the
/// same state) give an equal outcome. One context per editing session lets [limits] keep its
/// incremental packing cache between commands (a cache never changes results, only cost).
final class EditContext {
  /// Creates a context. [ids] defaults to a [SecureIdGenerator], [now] to the current UTC time,
  /// [limits] to a fresh [LayerLimits].
  EditContext({
    IdGenerator? ids,
    this.pool,
    DateTime? now,
    this.policy = const EditPolicy(),
    LayerLimits? limits,
    this.stamp,
  })  : ids = ids ?? SecureIdGenerator(),
        now = now ?? DateTime.now().toUtc(),
        limits = limits ?? LayerLimits();

  /// Mints ids for new items, lanes, links and transitions.
  final IdGenerator ids;

  /// The session's live media pool. When set (and not the project's pool), the command runs on
  /// the project with this pool, because the pool lives outside history snapshots (ARCH §7.3).
  final MediaPool? pool;

  /// The clock for anything a command timestamps (e.g. `addedAt` of assets a paste imports).
  final DateTime now;

  /// Defaults and limits.
  final EditPolicy policy;

  /// The D-14 / item / duration checks run after every command (keeps a per-session cache).
  final LayerLimits limits;

  /// Session-monotonic revision stamp (ARCH §7.3). When set, a changing command writes it into
  /// `Timeline.revision` and the `changedAt` of every changed lane; when null both are left as
  /// they were (the session may stamp later).
  final int? stamp;

  /// A copy with the given fields replaced (the [limits] cache is shared).
  EditContext copyWith({IdGenerator? ids, MediaPool? pool, DateTime? now, EditPolicy? policy, int? stamp}) =>
      EditContext(
        ids: ids ?? this.ids,
        pool: pool ?? this.pool,
        now: now ?? this.now,
        policy: policy ?? this.policy,
        limits: limits,
        stamp: stamp ?? this.stamp,
      );
}
