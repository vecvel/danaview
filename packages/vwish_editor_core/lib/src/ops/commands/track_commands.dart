// OWNER: CORE-17
//
// Track commands (ARCH §7.2, domain.md §6.2): `AddTrack`, `DeleteTrack`, `MoveTrack`,
// `RenameTrack`, `SetTrackFlags`, `SetAudioRole`.
//
// * Canonical order is `[video…, overlay…, text…, subtitle…, audio…]` and a higher index is
//   higher in the composite (D-09). A new lane goes on top of its kind's group; the first video
//   lane becomes the main lane.
// * The main lane (the first video lane) can be neither deleted nor moved, and nothing moves
//   below it (`CannotDeleteMainTrack`).
// * `MoveTrack` stays inside its kind's group (the compositing band, or the audio group):
//   `IncompatibleTrack` otherwise.
// * Locked lanes refuse every command that targets them (`TrackLocked`) except `SetTrackFlags`,
//   which is how they are unlocked.

part of '../edit_command.dart';

/// Longest lane name, in graphemes.
const int maxTrackNameLength = 60;

/// Adds an empty lane of [kind] on top of that kind's lanes (the first video lane is the main
/// lane). [name] is optional (the UI derives "Video 2" etc.); [audioRole] applies to audio lanes
/// (default music); [language] to subtitle lanes. Suggests selecting the new lane.
///
/// Rejections: `InvalidValue('name')` (longer than [maxTrackNameLength] graphemes).
final class AddTrack extends EditCommand {
  /// Creates the command.
  const AddTrack(this.kind, {this.name = '', this.audioRole, this.language});

  /// The lane kind.
  final TrackKind kind;

  /// The lane name (trimmed; may be empty).
  final String name;

  /// The role of an audio lane (ignored for other kinds).
  final AudioRole? audioRole;

  /// The language tag of a subtitle lane (ignored for other kinds).
  final String? language;

  @override
  String get label => 'Add track';

  @override
  void _apply(_Draft d) {
    final clean = name.trim();
    if (clean.characters.length > maxTrackNameLength) d.reject(const InvalidValue('name'));
    final id = d.createTrack(
      kind,
      name: clean,
      role: kind == TrackKind.audio ? (audioRole ?? AudioRole.music) : null,
      subtitle: kind == TrackKind.subtitle ? SubtitleTrackData(language: language) : null,
    );
    d.selection = SelectionHint(const {}, lane: id);
  }

  @override
  String toString() => 'AddTrack(${kind.name}, "$name")';
}

/// Deletes a lane with all its items (the UI confirms when the lane is not empty). Link partners
/// on other lanes stay and, when left alone, lose their link.
///
/// Rejections: `ItemNotFound`, `CannotDeleteMainTrack`, `TrackLocked`.
final class DeleteTrack extends EditCommand {
  /// Creates the command.
  const DeleteTrack(this.track);

  /// The lane.
  final TrackId track;

  @override
  String get label => 'Delete track';

  @override
  void _apply(_Draft d) {
    final lane = d.track(track);
    if (lane.isMain) d.reject(const CannotDeleteMainTrack());
    if (lane.locked) d.reject(TrackLocked(track));
    for (final item in lane.items) {
      d.noteLink(item.link);
      d.affected.add(item.id);
    }
    d.tracks.removeAt(d.indexOfTrack(track));
    d.changed.add(track);
    d._invalidate();
  }

  @override
  String toString() => 'DeleteTrack($track)';
}

/// Moves a lane so that it ends at index [toIndex] of the lane list (canonical order; a higher
/// index is higher in the composite), staying inside its kind's group. Moving to the lane's own
/// index is a no-op.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `InvalidValue('toIndex')` (outside the list),
/// `IncompatibleTrack` (outside the group of its kind), `CannotDeleteMainTrack` (the main lane
/// cannot move, and no lane may go below it).
final class MoveTrack extends EditCommand {
  /// Creates the command.
  const MoveTrack(this.track, this.toIndex);

  /// The lane.
  final TrackId track;

  /// The target index in `Timeline.tracks`.
  final int toIndex;

  @override
  String get label => 'Move track';

  @override
  void _apply(_Draft d) {
    final lane = d.editableTrack(track);
    if (toIndex < 0 || toIndex >= d.tracks.length) d.reject(const InvalidValue('toIndex'));
    final from = d.indexOfTrack(track);
    if (lane.isMain) {
      if (toIndex == from) return;
      d.reject(const CannotDeleteMainTrack());
    }
    var first = from;
    var last = from;
    while (first > 0 && d.tracks[first - 1].kind == lane.kind) {
      first--;
    }
    while (last + 1 < d.tracks.length && d.tracks[last + 1].kind == lane.kind) {
      last++;
    }
    if (toIndex < first || toIndex > last) d.reject(IncompatibleTrack(track));
    if (toIndex == from) return;
    if (lane.kind == TrackKind.video && d.tracks[toIndex].isMain) d.reject(const CannotDeleteMainTrack());
    final moved = d.tracks.removeAt(from);
    d.tracks.insert(toIndex, moved);
    d.changed.add(track);
    // The lanes between swap z positions: their composite order changed too.
    for (var i = from < toIndex ? from : toIndex; i <= (from < toIndex ? toIndex : from); i++) {
      d.changed.add(d.tracks[i].id);
    }
    d._invalidate();
  }

  @override
  String toString() => 'MoveTrack($track, $toIndex)';
}

/// Renames a lane (the name is trimmed; empty restores the derived default name).
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `InvalidValue('name')` (longer than
/// [maxTrackNameLength] graphemes).
final class RenameTrack extends EditCommand {
  /// Creates the command.
  const RenameTrack(this.track, this.name);

  /// The lane.
  final TrackId track;

  /// The new name.
  final String name;

  @override
  String get label => 'Rename track';

  @override
  void _apply(_Draft d) {
    final lane = d.editableTrack(track);
    final clean = name.trim();
    if (clean.characters.length > maxTrackNameLength) d.reject(const InvalidValue('name'));
    if (clean == lane.name) return;
    d.putTrack(lane.copyWith(name: clean));
  }

  @override
  String toString() => 'RenameTrack($track, "$name")';
}

/// Sets lane flags in one command; a null flag stays as it is. Works on locked lanes (it is how
/// they are unlocked).
///
/// * `hidden` applies to visual lanes (video, overlay, text, subtitle);
/// * `muted` and `solo` apply to lanes that can carry audio (video, overlay, audio) and only
///   their `true` value is refused elsewhere.
///
/// Rejections: `ItemNotFound`, `UnsupportedForKind('hidden' | 'audio')`.
final class SetTrackFlags extends EditCommand {
  /// Creates the command.
  const SetTrackFlags(this.track, {this.locked, this.hidden, this.muted, this.solo});

  /// The lane.
  final TrackId track;

  /// New `locked`, or null.
  final bool? locked;

  /// New `hidden`, or null.
  final bool? hidden;

  /// New `muted`, or null.
  final bool? muted;

  /// New `solo`, or null.
  final bool? solo;

  @override
  String get label {
    if (locked != null && hidden == null && muted == null && solo == null) return locked! ? 'Lock track' : 'Unlock track';
    if (hidden != null && locked == null && muted == null && solo == null) return hidden! ? 'Hide track' : 'Show track';
    if (muted != null && locked == null && hidden == null && solo == null) return muted! ? 'Mute track' : 'Unmute track';
    if (solo != null && locked == null && hidden == null && muted == null) return solo! ? 'Solo track' : 'Unsolo track';
    return 'Track settings';
  }

  @override
  void _apply(_Draft d) {
    final lane = d.track(track);
    final canHide = lane.kind.isVisual;
    final canSound = lane.kind == TrackKind.video || lane.kind == TrackKind.overlay || lane.kind == TrackKind.audio;
    if (hidden == true && !canHide) d.reject(const UnsupportedForKind('hidden'));
    if ((muted == true || solo == true) && !canSound) d.reject(const UnsupportedForKind('audio'));
    final next = lane.copyWith(
      locked: locked ?? lane.locked,
      hidden: hidden ?? lane.hidden,
      muted: muted ?? lane.muted,
      solo: solo ?? lane.solo,
    );
    if (next == lane) return;
    d.putTrack(next);
  }

  @override
  String toString() => 'SetTrackFlags($track, locked: $locked, hidden: $hidden, muted: $muted, solo: $solo)';
}

/// Sets the role of an audio lane (drives defaults, caption priority and music exclusion).
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `IncompatibleTrack` (not an audio lane).
final class SetAudioRole extends EditCommand {
  /// Creates the command.
  const SetAudioRole(this.track, this.role);

  /// The lane.
  final TrackId track;

  /// The role.
  final AudioRole role;

  @override
  String get label => 'Set audio role';

  @override
  void _apply(_Draft d) {
    final lane = d.editableTrack(track);
    if (lane.kind != TrackKind.audio) d.reject(IncompatibleTrack(track));
    if (lane.audioRole == role) return;
    d.putTrack(lane.copyWith(audioRole: role));
  }

  @override
  String toString() => 'SetAudioRole($track, ${role.name})';
}
