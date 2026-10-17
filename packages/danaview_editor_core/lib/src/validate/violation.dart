// OWNER: CORE-08
//
// Validation results (ARCH §6.9, domain.md §5): which invariant failed, a stable code, and where.
// Messages hold ids and numbers only — never media paths, text content or other user content.

import 'package:meta/meta.dart';

import '../ids/ids.dart';

/// The project invariants of ARCH §6.9.
enum Invariant {
  /// I1 grid: item edges, keys, markers, transitions and fades on the frame grid; durations ≥ 1
  /// frame; project ≤ 24 h.
  i1Grid,

  /// I2 order: items per track sorted and non-overlapping; ids unique.
  i2Order,

  /// I3 kinds: item kind vs track kind; exactly one main track (the first video track); band
  /// order.
  i3Kinds,

  /// I4 media: media exists with a compatible kind; `0 ≤ sourceIn`, `sourceOut ≤ probe.duration`;
  /// speed bounds.
  i4Media,

  /// I5 transitions: touching neighbours on their own visual track, one per cut, within the
  /// transition limits.
  i5Transitions,

  /// I6 keyframes and values: tracks sorted, unique, non-empty, keyframable only, within bounds;
  /// static property values within bounds.
  i6Keyframes,

  /// I7 links: groups of ≥ 2 members on different tracks.
  i7Links,

  /// I8 subtitles and text: non-empty cue (and text item) text; `SubtitleTrackData` exactly on
  /// subtitle tracks.
  i8Subtitles,

  /// I9 settings: canvas even and ≥ 16 px; supported frame rate; fades fit.
  i9Settings;

  /// `I1` … `I9`.
  String get label => 'I${index + 1}';
}

/// Stable violation codes (tests and logs key on these).
enum ViolationCode {
  // I1
  /// An item start or end is not on the frame grid.
  itemOffGrid(Invariant.i1Grid),

  /// An item has a duration below one frame or a negative start.
  itemTooShort(Invariant.i1Grid),

  /// An item ends after 24 h.
  beyondMaxDuration(Invariant.i1Grid),

  /// A keyframe time is not on the frame grid.
  keyOffGrid(Invariant.i1Grid),

  /// A marker is off the grid, negative or after 24 h.
  markerOffGrid(Invariant.i1Grid),

  /// An audio fade or text animation length is negative or not on the grid.
  lengthOffGrid(Invariant.i1Grid),

  // I2
  /// Items of a track are not sorted by start.
  itemsUnsorted(Invariant.i2Order),

  /// Two items of a track overlap.
  itemsOverlap(Invariant.i2Order),

  /// An item id occurs more than once in the project.
  duplicateItemId(Invariant.i2Order),

  /// A track id occurs more than once.
  duplicateTrackId(Invariant.i2Order),

  /// A transition id occurs more than once.
  duplicateTransitionId(Invariant.i2Order),

  /// A marker id occurs more than once.
  duplicateMarkerId(Invariant.i2Order),

  /// Markers are not sorted by time.
  markersUnsorted(Invariant.i2Order),

  // I3
  /// An item kind is not allowed on its track kind (or a clip's visual props do not match its lane).
  itemKindMismatch(Invariant.i3Kinds),

  /// No main track, more than one, or the main track is not the first video track.
  mainTrack(Invariant.i3Kinds),

  /// Tracks are not in canonical band order.
  bandOrder(Invariant.i3Kinds),

  // I4
  /// A clip references media that is not in the pool (or a LUT look references a missing LUT).
  mediaMissing(Invariant.i4Media),

  /// A clip's media kind is not allowed on its lane (or a look references a non-LUT asset).
  mediaKindMismatch(Invariant.i4Media),

  /// `sourceIn < 0` or `sourceOut > probe.duration`.
  sourceOutOfRange(Invariant.i4Media),

  /// A constant speed outside [0.1, 10] or an invalid ramp.
  speedOutOfRange(Invariant.i4Media),

  /// A negative audio stream index.
  audioStreamInvalid(Invariant.i4Media),

  // I5
  /// A transition on a non-visual track, or referencing items that are not touching neighbours.
  transitionNotAdjacent(Invariant.i5Transitions),

  /// More than one transition on one cut.
  transitionDuplicateCut(Invariant.i5Transitions),

  /// A transition shorter than 1 frame or longer than its limit.
  transitionTooLong(Invariant.i5Transitions),

  /// Transitions of a track are not sorted by cut time.
  transitionsUnsorted(Invariant.i5Transitions),

  // I6
  /// A keyframe channel that is unknown, not keyframable or does not apply to the item.
  keyChannelInvalid(Invariant.i6Keyframes),

  /// A keyframe track that is empty, unsorted or has duplicate times.
  keyTrackInvalid(Invariant.i6Keyframes),

  /// A keyframe value outside its property's range (or not finite).
  keyValueOutOfRange(Invariant.i6Keyframes),

  /// A static property value outside its range.
  valueOutOfRange(Invariant.i6Keyframes),

  // I7
  /// A link group with fewer than 2 members, or two members on one track.
  linkInvalid(Invariant.i7Links),

  // I8
  /// A cue or text item whose text is empty after trimming.
  emptyText(Invariant.i8Subtitles),

  /// `SubtitleTrackData` missing on a subtitle track, present elsewhere, or out of range.
  subtitleData(Invariant.i8Subtitles),

  // I9
  /// Canvas dimensions odd or below 16 px.
  canvasInvalid(Invariant.i9Settings),

  /// Unsupported project frame rate.
  frameRateUnsupported(Invariant.i9Settings),

  /// An audio fade longer than half the clip.
  fadeTooLong(Invariant.i9Settings);

  const ViolationCode(this.invariant);

  /// The invariant this code belongs to.
  final Invariant invariant;
}

/// One broken invariant.
@immutable
final class Violation {
  /// Creates a violation.
  const Violation(this.code, {this.track, this.subject, this.message = ''});

  /// What is wrong.
  final ViolationCode code;

  /// The track the violation belongs to, or null for project-level violations (settings, track
  /// structure, markers). `validate(only: S)` returns exactly the full result's violations whose
  /// [track] is null or in S.
  final TrackId? track;

  /// The id of the offending item, transition, marker or track, when there is one.
  final String? subject;

  /// Diagnostic detail (ids and numbers only).
  final String message;

  /// The invariant.
  Invariant get invariant => code.invariant;

  @override
  bool operator ==(Object other) =>
      other is Violation &&
      other.code == code &&
      other.track == track &&
      other.subject == subject &&
      other.message == message;

  @override
  int get hashCode => Object.hash(code, track, subject, message);

  @override
  String toString() =>
      'Violation(${code.invariant.label} ${code.name}${track == null ? '' : ' track $track'}'
      '${subject == null ? '' : ' $subject'}${message.isEmpty ? '' : ': $message'})';
}
