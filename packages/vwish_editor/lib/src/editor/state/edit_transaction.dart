// OWNER: UX-08
//
// EditTransaction for continuous gestures (ARCH §7.3, ux.md §16.4) and the EditResult every
// mutation returns (ux.md §16.3).
//
// * `update(cmd)` runs `cmd` on the base project captured at `beginTransaction`, never on top of
//   the previous update (dragging back to the start yields exactly the base).
// * State emission is coalesced to one per frame; property-only changes are previewed natively
//   with transients (core `transientFor` + `PlanSync.sendTransient`, ≤ 60 Hz); structural changes
//   (a ripple drag) are shown by the timeline ghosts and reach the preview on commit.
// * `commit()` records exactly one history entry, schedules one plan patch and one autosave
//   request; `cancel()` restores the base and clears the transients.
// * Only one transaction is open at a time: a new one, any `apply`, undo/redo, or the app going
//   inactive cancels the open one. Calls on a closed transaction are no-ops.

import 'package:flutter/foundation.dart';
import 'package:vwish_editor_core/model.dart' show EditProject, ItemId, TrackId;
import 'package:vwish_editor_core/ops.dart' show EditCommand, EditNotice, EditPreview, EditRejection;

/// The result of a mutation (ux.md §16.3).
@immutable
sealed class EditResult {
  /// Creates a result.
  const EditResult();

  /// Whether the project changed.
  bool get applied => this is EditApplied;
}

/// The command was committed as one history entry (or, for a transaction update, shown as the
/// working copy).
final class EditApplied extends EditResult {
  /// Creates the result.
  EditApplied({required this.label, Set<ItemId> affected = const {}, Set<TrackId> changedTracks = const {}, this.notices = const []})
      : affected = Set.unmodifiable(affected),
        changedTracks = Set.unmodifiable(changedTracks);

  /// History label.
  final String label;

  /// Items the command touched.
  final Set<ItemId> affected;

  /// Lanes that changed.
  final Set<TrackId> changedTracks;

  /// Notices (trimmed to fit, placed on another lane, …).
  final List<EditNotice> notices;

  @override
  String toString() => 'EditApplied("$label", ${affected.length} items)';
}

/// The command was refused; an info toast with `editor_messages` copy was emitted (ARCH §19).
final class EditRejected extends EditResult {
  /// Creates the result.
  const EditRejected(this.reason);

  /// Why.
  final EditRejection reason;

  @override
  String toString() => 'EditRejected($reason)';
}

/// Nothing changed (a no-op command, or the editor isn't open).
final class EditUnchanged extends EditResult {
  /// Creates the result.
  const EditUnchanged();

  @override
  String toString() => 'EditUnchanged()';
}

/// A continuous edit committed as one history entry (ux.md §16.4).
abstract interface class EditTransaction {
  /// History label of the entry [commit] records.
  String get label;

  /// Whether [update], [commit] and [cancel] still do something.
  bool get isOpen;

  /// Runs [command] on the base project (replacing the previous update) and shows the result as
  /// the working copy. A refused update shows the base and returns [EditRejected] (no toast: the
  /// gesture shows why, e.g. a red ghost).
  EditResult update(EditCommand command);

  /// Where items of the latest update land (drag ghosts), or null before the first update.
  EditPreview? get preview;

  /// The working copy (the base when the latest update was refused or nothing was updated).
  EditProject get working;

  /// Records one history entry (none when nothing changed), schedules one plan patch and one
  /// autosave request.
  EditResult commit();

  /// Restores the base project and clears the gesture's transients.
  void cancel();
}
