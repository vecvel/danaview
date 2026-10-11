// OWNER: UX-13
//
// Copy of the timeline editing gestures and the edit actions (ux.md §8.9, §14.4): move, trim,
// split, delete, ripple, snapping and the in-app clipboard. Plain and specific, with a next step
// where one exists (ARCH §19). No ids or paths appear in the text.

import 'package:vwish_editor_core/model.dart' show FrameRate, TimeUs, Timecode;

/// Copy of the edit actions and the drag pills (ux.md §8.9).
abstract final class EditStrings {
  // ---- History labels (one entry per gesture) -------------------------------------------------

  /// A move of one clip.
  static const String moveClip = 'Move clip';

  /// A move of several clips.
  static const String moveClips = 'Move clips';

  /// A trim.
  static const String trimClip = 'Trim clip';

  /// A cue edge drag.
  static const String retimeCaption = 'Retime caption';

  /// A fade-in handle drag.
  static const String fadeIn = 'Fade in';

  /// A fade-out handle drag.
  static const String fadeOut = 'Fade out';

  /// A keyframe drag.
  static const String moveKeyframe = 'Move keyframe';

  /// A marker drag.
  static const String moveMarker = 'Move marker';

  /// Split of several kinds of items at once.
  static const String split = 'Split';

  // ---- Disabled reasons and toasts ------------------------------------------------------------

  /// Split found nothing under the playhead (ux.md §8.9).
  static const String splitNoTarget = 'Move the playhead over a clip to split it.';

  /// The action needs a selected clip.
  static const String selectClipFirst = 'Select a clip first.';

  /// Delete gap needs a selected gap.
  static const String selectGapFirst = 'Tap an empty space between clips first.';

  /// Paste with an empty clipboard.
  static const String clipboardEmpty = 'Copy or cut a clip first.';

  /// The project can't be edited (not open, read-only or closing).
  static const String notEditable = 'This project can’t be edited right now.';

  /// Select all with an empty timeline.
  static const String nothingToSelect = 'There’s nothing on the timeline yet.';

  /// Escape with nothing to dismiss.
  static const String nothingToCancel = 'Nothing to close.';

  /// Move to track with no compatible lane.
  static const String noOtherTrack = 'Select clips on one track. Another unlocked track of the same kind is needed.';

  /// Title of the "Move to track" sheet.
  static const String moveToTrackTitle = 'Move to track';

  /// Subtitle of a lane row in the "Move to track" sheet.
  static String clipsOnTrack(int n) => n == 1 ? '1 clip' : '$n clips';

  /// Toast after copy.
  static String copied(int n) => n == 1 ? 'Copied 1 clip' : 'Copied $n clips';

  /// Toast after cut.
  static String cut(int n) => n == 1 ? 'Cut 1 clip' : 'Cut $n clips';

  /// Toast and announcement of the snapping toggle.
  static String snapping(bool on) => on ? 'Snapping on' : 'Snapping off';

  /// Toast and announcement of the ripple toggle.
  static String ripple(bool on) => on ? 'Ripple editing on' : 'Ripple editing off';

  /// Announced when multi-select mode starts.
  static const String multiSelectOn = 'Select multiple. Tap clips to add or remove them.';

  /// Announced when multi-select mode ends.
  static const String multiSelectOff = 'Done selecting';

  // ---- Drag pills ------------------------------------------------------------------------------

  /// The pill over a ghost that lands on a lane the drop creates.
  static const String newTrack = 'New track';

  /// The pill of a trim: "In +00:01:05 · 00:04:12" (edge, signed change, new length).
  static String trimPill({required bool head, required TimeUs delta, required TimeUs duration, required FrameRate rate}) =>
      '${head ? 'In' : 'Out'} ${signed(delta, rate)} · ${Timecode.format(duration, rate)}';

  /// The pill of a fade drag: "Fade in 00:00:12".
  static String fadePill({required bool fadeIn, required TimeUs length, required FrameRate rate}) =>
      '${fadeIn ? EditStrings.fadeIn : EditStrings.fadeOut} ${Timecode.format(length, rate)}';

  /// The pill of a move: the new start and the change ("00:04:00 · +00:01:00").
  static String movePill({required TimeUs start, required TimeUs delta, required FrameRate rate}) =>
      '${Timecode.format(start, rate)} · ${signed(delta, rate)}';

  /// The pill of a snap guide or a dragged marker/keyframe: the time.
  static String timePill(TimeUs t, FrameRate rate) => Timecode.format(t, rate);

  /// A signed timecode ("+00:01:05", "-00:00:10").
  static String signed(TimeUs delta, FrameRate rate) => '${delta < 0 ? '-' : '+'}${Timecode.format(delta.abs(), rate)}';
}
