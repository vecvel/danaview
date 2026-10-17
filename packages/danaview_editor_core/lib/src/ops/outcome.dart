// OWNER: CORE-09
//
// Results of `applyCommand` and `dryRun` (ARCH §7.1, domain.md §6.1): `EditOutcome` (the new
// project plus what changed) and `EditPreview` (where items land, for drag ghosts). Both carry a
// rejection as data instead of throwing.

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/project.dart';
import '../time/time.dart';
import 'placement.dart';
import 'rejections.dart';

/// What the UI should select after a command (the session restores it after undo/redo too).
@immutable
final class SelectionHint {
  /// Creates a hint.
  SelectionHint(Set<ItemId> items, {this.primary, this.lane}) : items = Set.unmodifiable(items);

  /// Items to select.
  final Set<ItemId> items;

  /// The primary item (inspector target), if any.
  final ItemId? primary;

  /// The lane to focus, if any.
  final TrackId? lane;

  @override
  bool operator ==(Object other) =>
      other is SelectionHint &&
      other.primary == primary &&
      other.lane == lane &&
      const SetEquality<ItemId>().equals(other.items, items);

  @override
  int get hashCode => Object.hash(primary, lane, const SetEquality<ItemId>().hash(items));

  @override
  String toString() => 'SelectionHint($items, primary: $primary, lane: $lane)';
}

/// Stable notice codes of the commands in this package. Command groups may define more codes;
/// UX maps codes to copy.
abstract final class EditNoticeCodes {
  /// A clip was shortened to fit its new media (`ReplaceMedia`).
  static const String trimmedToFit = 'trimmedToFit';

  /// Transitions were removed because their clips no longer touch ([EditNotice.count]).
  static const String transitionsRemoved = 'transitionsRemoved';

  /// Transitions were shortened to their new limits ([EditNotice.count]).
  static const String transitionsShortened = 'transitionsShortened';

  /// Items went to another lane because their target was occupied (D-11).
  static const String placedOnOtherLane = 'placedOnOtherLane';

  /// A paste added media to this project's pool ([EditNotice.count] assets).
  static const String mediaImported = 'mediaImported';

  /// Some selected items were left out (e.g. a split that only applies to some of them).
  static const String itemsSkipped = 'itemsSkipped';
}

/// Something the user should be told about a successful command (a toast, an announcement).
@immutable
final class EditNotice {
  /// Creates a notice with a stable [code] (see [EditNoticeCodes]).
  EditNotice(this.code, {Set<ItemId> items = const {}, this.count = 0}) : items = Set.unmodifiable(items);

  /// Stable code.
  final String code;

  /// Items concerned.
  final Set<ItemId> items;

  /// A count when the notice reports one (removed transitions, imported assets…).
  final int count;

  @override
  bool operator ==(Object other) =>
      other is EditNotice && other.code == code && other.count == count && const SetEquality<ItemId>().equals(other.items, items);

  @override
  int get hashCode => Object.hash(code, count, const SetEquality<ItemId>().hash(items));

  @override
  String toString() => 'EditNotice($code${items.isEmpty ? '' : ' $items'}${count == 0 ? '' : ' x$count'})';
}

/// The result of applying one command (ARCH §7.1).
///
/// On rejection [project] is the input project unchanged, [rejection] is set and the sets are
/// empty. On a no-op (the command changed nothing) [project] is the identical input project and
/// [noop] is true: the session records no history entry.
@immutable
final class EditOutcome {
  /// Creates an outcome.
  EditOutcome({
    required this.project,
    Set<ItemId> affected = const {},
    Set<TrackId> changedTracks = const {},
    Set<TrackId> createdTracks = const {},
    this.selection,
    List<EditNotice> notices = const [],
    this.rejection,
    this.noop = false,
  })  : affected = Set.unmodifiable(affected),
        changedTracks = Set.unmodifiable(changedTracks),
        createdTracks = Set.unmodifiable(createdTracks),
        notices = List.unmodifiable(notices);

  /// A rejected outcome: [project] unchanged.
  factory EditOutcome.rejected(EditProject project, EditRejection rejection) =>
      EditOutcome(project: project, rejection: rejection);

  /// The resulting project (the input project when rejected or a no-op).
  final EditProject project;

  /// Items created, moved, trimmed, split, deleted or otherwise changed (deleted ids included).
  final Set<ItemId> affected;

  /// Lanes whose items or transitions changed, created lanes included (validation, plan diff and
  /// UI tile caches key on these).
  final Set<TrackId> changedTracks;

  /// Lanes the command created (a subset of [changedTracks]).
  final Set<TrackId> createdTracks;

  /// What to select afterwards, if the command suggests something.
  final SelectionHint? selection;

  /// Things to tell the user.
  final List<EditNotice> notices;

  /// Why the command was refused, or null.
  final EditRejection? rejection;

  /// Whether the command changed nothing.
  final bool noop;

  /// Whether the command was refused.
  bool get isRejected => rejection != null;

  /// Whether the command changed the project (neither rejected nor a no-op).
  bool get changed => rejection == null && !noop;

  @override
  String toString() => rejection != null
      ? 'EditOutcome(rejected: $rejection)'
      : noop
          ? 'EditOutcome(noop)'
          : 'EditOutcome(affected: ${affected.length}, tracks: $changedTracks, notices: $notices)';
}

/// The result of a dry run (ARCH §7.1): where every affected item lands, which lanes would be
/// created, the clamped range for gesture commands, and the rejection, if any. Produced by the
/// same code path as [EditOutcome].
@immutable
final class EditPreview {
  /// Creates a preview.
  EditPreview({
    Map<ItemId, Placement> placements = const {},
    List<NewTrack> createsTracks = const [],
    this.clampedTo,
    this.rejection,
  })  : placements = Map.unmodifiable(placements),
        createsTracks = List.unmodifiable(createsTracks);

  /// A rejected preview.
  factory EditPreview.rejected(EditRejection rejection) => EditPreview(rejection: rejection);

  /// Resulting lane and range of every affected item that exists afterwards.
  final Map<ItemId, Placement> placements;

  /// Lanes the command would create, in index order.
  final List<NewTrack> createsTracks;

  /// For `clamp: true` gestures: the range the edited item (or group) was clamped to, when the
  /// request had to be adjusted; null otherwise.
  final TimeRange? clampedTo;

  /// Why the command would be refused, or null.
  final EditRejection? rejection;

  /// Whether the command would be refused.
  bool get isRejected => rejection != null;

  @override
  String toString() => rejection != null
      ? 'EditPreview(rejected: $rejection)'
      : 'EditPreview(${placements.length} placements, creates: $createsTracks, clampedTo: $clampedTo)';
}
