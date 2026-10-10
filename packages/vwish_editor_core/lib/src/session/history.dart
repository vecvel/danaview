// OWNER: CORE-19
//
// History value types of the editing session (ARCH §7.3, domain.md §7.2): the limits
// (`HistoryPolicy`), one recorded entry (`HistoryEntry`: Timeline snapshots before/after plus an
// optional `PoolDelta`), the status the UI shows (`HistoryStatus`) and the result of an undo, redo
// or jump (`HistoryStep`).

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/pool/media_pool.dart';
import '../model/project.dart';
import '../model/timeline.dart';
import '../ops/outcome.dart';

/// History limits (ARCH §7.3): at most [maxEntries] entries and about [maxApproxBytes] bytes;
/// the oldest entries are evicted first (the newest entry is always kept).
@immutable
final class HistoryPolicy {
  /// Creates a policy (defaults: 200 entries, 48 MB).
  const HistoryPolicy({this.maxEntries = 200, this.maxApproxBytes = 48 * 1024 * 1024})
      : assert(maxEntries >= 1),
        assert(maxApproxBytes >= 0);

  /// Most entries kept.
  final int maxEntries;

  /// Most approximate bytes kept (see [HistoryEntry.approxBytes]).
  final int maxApproxBytes;

  @override
  bool operator ==(Object other) =>
      other is HistoryPolicy && other.maxEntries == maxEntries && other.maxApproxBytes == maxApproxBytes;

  @override
  int get hashCode => Object.hash(maxEntries, maxApproxBytes);

  @override
  String toString() => 'HistoryPolicy($maxEntries entries, $maxApproxBytes B)';
}

/// One undoable step: the Timeline snapshots around it and, for relink/remove, the pool values.
///
/// Snapshots share structure with the live project (immutable model), so an entry only costs the
/// lanes and items that changed ([approxBytes]).
@immutable
final class HistoryEntry {
  /// Creates an entry.
  HistoryEntry({
    required this.label,
    required this.before,
    required this.after,
    required this.at,
    required this.approxBytes,
    this.poolDelta,
    Set<ItemId> affected = const {},
    this.selection,
    this.coalesceKey,
  }) : affected = Set.unmodifiable(affected);

  /// History label ("Split", "Move clip", "Relink media", …).
  final String label;

  /// The Timeline before the step (restored by undo, re-stamped).
  final Timeline before;

  /// The Timeline after the step (restored by redo, re-stamped).
  final Timeline after;

  /// Pool values to restore on undo ([PoolDelta.before]) and redo ([PoolDelta.after]), or null.
  /// Imports never get a delta: undo never empties the bin.
  final PoolDelta? poolDelta;

  /// Items the step touched (restored as the selection after undo/redo when they still exist).
  final Set<ItemId> affected;

  /// The selection the command suggested, if any.
  final SelectionHint? selection;

  /// The coalescing key of the apply that created it (typing), or null.
  final String? coalesceKey;

  /// When the step was last changed (the coalescing window counts from here).
  final DateTime at;

  /// Approximate retained size: 8 B per slot of every new item list, ~300 B per new item or
  /// marker, plus small per-entry and per-lane overheads (ARCH §7.3).
  final int approxBytes;

  @override
  String toString() => 'HistoryEntry($label, ${affected.length} items, $approxBytes B'
      '${poolDelta == null ? '' : ', pool'}${coalesceKey == null ? '' : ', key $coalesceKey'})';
}

/// What the undo/redo buttons and the history sheet show.
@immutable
final class HistoryStatus {
  /// Creates a status.
  const HistoryStatus({
    required this.position,
    required this.length,
    this.undoLabel,
    this.redoLabel,
  });

  /// Empty history.
  static const HistoryStatus empty = HistoryStatus(position: 0, length: 0);

  /// Number of entries that can be undone (the cursor: entries `[0, position)` are applied).
  final int position;

  /// Number of entries kept (undoable + redoable).
  final int length;

  /// Label of the entry undo would revert, or null.
  final String? undoLabel;

  /// Label of the entry redo would re-apply, or null.
  final String? redoLabel;

  /// Whether undo is possible.
  bool get canUndo => position > 0;

  /// Whether redo is possible.
  bool get canRedo => position < length;

  /// Number of entries redo could re-apply.
  int get redoable => length - position;

  @override
  bool operator ==(Object other) =>
      other is HistoryStatus &&
      other.position == position &&
      other.length == length &&
      other.undoLabel == undoLabel &&
      other.redoLabel == redoLabel;

  @override
  int get hashCode => Object.hash(position, length, undoLabel, redoLabel);

  @override
  String toString() => 'HistoryStatus($position/$length, undo: $undoLabel, redo: $redoLabel)';
}

/// Direction of a [HistoryStep].
enum HistoryDirection {
  /// Back in history.
  undo,

  /// Forward in history.
  redo,
}

/// The result of `undo`, `redo` or `jump`: one combined step (one new revision stamp).
@immutable
final class HistoryStep {
  /// Creates a step.
  HistoryStep({
    required this.direction,
    required List<String> labels,
    required this.project,
    Set<ItemId> affected = const {},
    Set<TrackId> changedTracks = const {},
    this.selection,
  })  : labels = List.unmodifiable(labels),
        affected = Set.unmodifiable(affected),
        changedTracks = Set.unmodifiable(changedTracks);

  /// Undo or redo.
  final HistoryDirection direction;

  /// Labels of the entries passed, in the order they were undone or redone.
  final List<String> labels;

  /// The project after the step.
  final EditProject project;

  /// Items touched by the entries passed (deleted ids included).
  final Set<ItemId> affected;

  /// Lanes whose objects differ from before the step (created and removed lanes included).
  final Set<TrackId> changedTracks;

  /// The affected items that still exist afterwards (the UI restores this selection), or null
  /// when none does.
  final SelectionHint? selection;

  /// Number of entries passed.
  int get steps => labels.length;

  /// Label of the first entry passed ("Undid Split clip").
  String get label => labels.first;

  @override
  bool operator ==(Object other) =>
      other is HistoryStep &&
      other.direction == direction &&
      identical(other.project, project) &&
      const ListEquality<String>().equals(other.labels, labels) &&
      const SetEquality<ItemId>().equals(other.affected, affected) &&
      const SetEquality<TrackId>().equals(other.changedTracks, changedTracks) &&
      other.selection == selection;

  @override
  int get hashCode => Object.hash(direction, identityHashCode(project), Object.hashAll(labels));

  @override
  String toString() => 'HistoryStep(${direction.name} x$steps: $labels)';
}
