// OWNER: CORE-09
//
// Why a command was refused (ARCH §7.1, domain.md §6.1). Rejections are **data**: `applyCommand`
// and `dryRun` return them in `EditOutcome.rejection` / `EditPreview.rejection` and never throw
// them. The set is sealed and exactly the one of ARCH §7.1. Fields hold ids and numbers only,
// never media paths or user text.

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../time/time.dart';
import '../validate/violation.dart';

/// Why a command was refused. Sealed; see ARCH §7.1 for the list.
@immutable
sealed class EditRejection {
  const EditRejection();

  /// Stable machine-readable code (the class name in lower camel case), used by UX copy tables
  /// and logs.
  String get code;
}

/// A command targets an item or lane on a locked track.
final class TrackLocked extends EditRejection {
  /// Creates the rejection for [track].
  const TrackLocked(this.track);

  /// The locked track.
  final TrackId track;

  @override
  String get code => 'trackLocked';

  @override
  bool operator ==(Object other) => other is TrackLocked && other.track == track;

  @override
  int get hashCode => Object.hash(code, track);

  @override
  String toString() => 'TrackLocked($track)';
}

/// An item, track or other id named by the command does not exist.
final class ItemNotFound extends EditRejection {
  /// Creates the rejection for [id] (an item, track, transition or marker id).
  const ItemNotFound(this.id);

  /// The missing id.
  final String id;

  @override
  String get code => 'itemNotFound';

  @override
  bool operator ==(Object other) => other is ItemNotFound && other.id == id;

  @override
  int get hashCode => Object.hash(code, id);

  @override
  String toString() => 'ItemNotFound($id)';
}

/// The result would overlap another item on [track] in [range] and the policy cannot resolve it.
final class WouldOverlap extends EditRejection {
  /// Creates the rejection.
  const WouldOverlap(this.track, this.range);

  /// The lane where the overlap happens.
  final TrackId track;

  /// The overlapping range.
  final TimeRange range;

  @override
  String get code => 'wouldOverlap';

  @override
  bool operator ==(Object other) => other is WouldOverlap && other.track == track && other.range == range;

  @override
  int get hashCode => Object.hash(code, track, range);

  @override
  String toString() => 'WouldOverlap($track, $range)';
}

/// A trim or retime would play source outside the media. [limit] is the nearest valid timeline
/// edge for the requested edge (the UI can show it), or null when nothing fits.
final class OutOfSourceRange extends EditRejection {
  /// Creates the rejection.
  const OutOfSourceRange([this.limit]);

  /// The nearest valid timeline time for the edited edge, if any.
  final TimeUs? limit;

  @override
  String get code => 'outOfSourceRange';

  @override
  bool operator ==(Object other) => other is OutOfSourceRange && other.limit == limit;

  @override
  int get hashCode => Object.hash(code, limit);

  @override
  String toString() => 'OutOfSourceRange($limit)';
}

/// The result would be shorter than one frame.
final class BelowMinDuration extends EditRejection {
  /// Creates the rejection.
  const BelowMinDuration();

  @override
  String get code => 'belowMinDuration';

  @override
  bool operator ==(Object other) => other is BelowMinDuration;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'BelowMinDuration()';
}

/// Nothing the command can act on lies at [time] (e.g. split with no clip under the playhead).
final class NothingAtTime extends EditRejection {
  /// Creates the rejection.
  const NothingAtTime(this.time);

  /// The time that was probed.
  final TimeUs time;

  @override
  String get code => 'nothingAtTime';

  @override
  bool operator ==(Object other) => other is NothingAtTime && other.time == time;

  @override
  int get hashCode => Object.hash(code, time);

  @override
  String toString() => 'NothingAtTime($time)';
}

/// The command does not apply to this kind of item or media ([kind] names it, e.g. `image`,
/// `subtitle`, `noAudio`).
final class UnsupportedForKind extends EditRejection {
  /// Creates the rejection.
  const UnsupportedForKind(this.kind);

  /// What was unsupported.
  final String kind;

  @override
  String get code => 'unsupportedForKind';

  @override
  bool operator ==(Object other) => other is UnsupportedForKind && other.kind == kind;

  @override
  int get hashCode => Object.hash(code, kind);

  @override
  String toString() => 'UnsupportedForKind($kind)';
}

/// The item or media cannot go on the requested lane (wrong lane kind), or a group would put two
/// linked items on one lane.
final class IncompatibleTrack extends EditRejection {
  /// Creates the rejection; [track] is the offending lane when there is one.
  const IncompatibleTrack([this.track]);

  /// The lane, if any.
  final TrackId? track;

  @override
  String get code => 'incompatibleTrack';

  @override
  bool operator ==(Object other) => other is IncompatibleTrack && other.track == track;

  @override
  int get hashCode => Object.hash(code, track);

  @override
  String toString() => 'IncompatibleTrack($track)';
}

/// Two items that must touch (transition, cue merge) do not.
final class NotAdjacent extends EditRejection {
  /// Creates the rejection.
  const NotAdjacent();

  @override
  String get code => 'notAdjacent';

  @override
  bool operator ==(Object other) => other is NotAdjacent;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'NotAdjacent()';
}

/// A transition longer than the clips and handles allow; [maxFrames] is the limit.
final class TransitionTooLong extends EditRejection {
  /// Creates the rejection.
  const TransitionTooLong(this.maxFrames);

  /// The longest allowed transition, in frames (0 when none fits).
  final int maxFrames;

  @override
  String get code => 'transitionTooLong';

  @override
  bool operator ==(Object other) => other is TransitionTooLong && other.maxFrames == maxFrames;

  @override
  int get hashCode => Object.hash(code, maxFrames);

  @override
  String toString() => 'TransitionTooLong($maxFrames)';
}

/// A keyframe already exists at item-local time [t].
final class KeyframeExists extends EditRejection {
  /// Creates the rejection.
  const KeyframeExists(this.t);

  /// Item-local time of the existing key.
  final TimeUs t;

  @override
  String get code => 'keyframeExists';

  @override
  bool operator ==(Object other) => other is KeyframeExists && other.t == t;

  @override
  int get hashCode => Object.hash(code, t);

  @override
  String toString() => 'KeyframeExists($t)';
}

/// Text or cue text would be empty after trimming.
final class EmptyText extends EditRejection {
  /// Creates the rejection.
  const EmptyText();

  @override
  String get code => 'emptyText';

  @override
  bool operator ==(Object other) => other is EmptyText;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'EmptyText()';
}

/// There is no free space for the result and the policy may not create a lane.
final class NoRoom extends EditRejection {
  /// Creates the rejection.
  const NoRoom();

  @override
  String get code => 'noRoom';

  @override
  bool operator ==(Object other) => other is NoRoom;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'NoRoom()';
}

/// A ripple would move the linked partner [item] onto another item of its lane (D-10).
final class RippleBlockedByLinkedItem extends EditRejection {
  /// Creates the rejection.
  const RippleBlockedByLinkedItem(this.item);

  /// The partner that would collide.
  final ItemId item;

  @override
  String get code => 'rippleBlockedByLinkedItem';

  @override
  bool operator ==(Object other) => other is RippleBlockedByLinkedItem && other.item == item;

  @override
  int get hashCode => Object.hash(code, item);

  @override
  String toString() => 'RippleBlockedByLinkedItem($item)';
}

/// The result would exceed a project or device limit (D-14). [what] is one of the constants
/// below; [limit] is the cap that would be exceeded.
final class LimitExceeded extends EditRejection {
  /// Creates the rejection.
  const LimitExceeded(this.what, this.limit);

  /// Concurrent decoder-backed video layers at one instant (`EditPolicy.maxConcurrentVideoLayers`).
  static const String concurrentVideoLayers = 'concurrentVideoLayers';

  /// Packed visual sequences for the whole project (`EditPolicy.maxVisualSequences`).
  static const String visualSequences = 'visualSequences';

  /// Timeline items in the project (`EditPolicy.maxItems`, 5,000).
  static const String items = 'items';

  /// Project duration in µs (24 h).
  static const String duration = 'duration';

  /// What would be exceeded.
  final String what;

  /// The cap.
  final int limit;

  @override
  String get code => 'limitExceeded';

  @override
  bool operator ==(Object other) => other is LimitExceeded && other.what == what && other.limit == limit;

  @override
  int get hashCode => Object.hash(code, what, limit);

  @override
  String toString() => 'LimitExceeded($what, $limit)';
}

/// The media named by the command is not in the pool or failed (cannot be placed).
final class MediaUnavailable extends EditRejection {
  /// Creates the rejection.
  const MediaUnavailable(this.media);

  /// The media id.
  final MediaId media;

  @override
  String get code => 'mediaUnavailable';

  @override
  bool operator ==(Object other) => other is MediaUnavailable && other.media == media;

  @override
  int get hashCode => Object.hash(code, media);

  @override
  String toString() => 'MediaUnavailable($media)';
}

/// The main track cannot be deleted or moved.
final class CannotDeleteMainTrack extends EditRejection {
  /// Creates the rejection.
  const CannotDeleteMainTrack();

  @override
  String get code => 'cannotDeleteMainTrack';

  @override
  bool operator ==(Object other) => other is CannotDeleteMainTrack;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'CannotDeleteMainTrack()';
}

/// A value outside its allowed range, or an argument that makes no sense ([property] names it).
final class InvalidValue extends EditRejection {
  /// Creates the rejection.
  const InvalidValue(this.property);

  /// The property or argument name (e.g. `speed`, `delta`, `gap`).
  final String property;

  @override
  String get code => 'invalidValue';

  @override
  bool operator ==(Object other) => other is InvalidValue && other.property == property;

  @override
  int get hashCode => Object.hash(code, property);

  @override
  String toString() => 'InvalidValue($property)';
}

/// The command produced a project that breaks an invariant, or threw. The project is left
/// unchanged. [violations] lists the new invariant violations (empty when the command threw);
/// [detail] names the exception type for diagnostics (never user content).
final class InternalInconsistency extends EditRejection {
  /// Creates the rejection.
  InternalInconsistency(List<Violation> violations, {this.detail = ''}) : violations = List.unmodifiable(violations);

  /// The invariant violations the result would have introduced.
  final List<Violation> violations;

  /// Diagnostic detail (exception type), empty for validation failures.
  final String detail;

  @override
  String get code => 'internalInconsistency';

  @override
  bool operator ==(Object other) =>
      other is InternalInconsistency &&
      other.detail == detail &&
      const ListEquality<Violation>().equals(other.violations, violations);

  @override
  int get hashCode => Object.hash(code, detail, Object.hashAll(violations));

  @override
  String toString() => 'InternalInconsistency(${violations.join(', ')}${detail.isEmpty ? '' : ' $detail'})';
}
