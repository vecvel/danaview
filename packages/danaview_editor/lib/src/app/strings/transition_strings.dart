// OWNER: UX-27
//
// Copy of the transitions panel and the transitions action (ux.md §10.12): plain, specific and with
// a next step where one exists (ARCH §19). Every tile has a text label; glyphs never carry meaning
// alone.

import 'package:danaview_editor_core/model.dart' show TransitionDirection, TransitionKind;

/// Copy of the transitions panel (ux.md §10.12).
abstract final class TransitionStrings {
  // ---- Tiles -----------------------------------------------------------------------------------

  /// Heading of the tile grid.
  static const String typeHeading = 'Type';

  /// The tile without a transition.
  static const String none = 'None';

  /// The name of [kind] ("Cross dissolve").
  static String kindName(TransitionKind kind) => switch (kind) {
        TransitionKind.fade => 'Fade',
        TransitionKind.crossDissolve => 'Cross dissolve',
        TransitionKind.dipToBlack => 'Dip to black',
        TransitionKind.dipToWhite => 'Dip to white',
        TransitionKind.slide => 'Slide',
        TransitionKind.wipe => 'Wipe',
        TransitionKind.zoom => 'Zoom',
      };

  /// Shown under the tiles when some kinds cannot be used at this cut.
  static const String needsHandles = 'Cross dissolve, Slide, Wipe and Zoom need unused video beyond the cut on both sides.';

  // ---- Duration --------------------------------------------------------------------------------

  /// Label of the duration slider.
  static const String duration = 'Duration';

  /// Unit of the duration value.
  static const String secondsUnit = 's';

  /// Copy when the duration is limited below the 2 s maximum (ux.md §10.12).
  static const String limited = 'Longer transitions need more video on both sides of the cut.';

  // ---- Direction -------------------------------------------------------------------------------

  /// Label of the direction control.
  static const String direction = 'Direction';

  /// The label of [direction] (its arrow or zoom glyph sits beside it).
  static String directionLabel(TransitionDirection direction) => switch (direction) {
        TransitionDirection.left => 'Left',
        TransitionDirection.right => 'Right',
        TransitionDirection.up => 'Up',
        TransitionDirection.down => 'Down',
        TransitionDirection.zoomIn => 'Zoom in',
        TransitionDirection.zoomOut => 'Zoom out',
      };

  // ---- Preview ---------------------------------------------------------------------------------

  /// The toggle while the loop preview runs.
  static const String stopPreview = 'Stop preview';

  /// The toggle while the loop preview is stopped.
  static const String playPreview = 'Play preview';

  // ---- Apply to all ----------------------------------------------------------------------------

  /// Applies the current transition to every cut of the lane (one history entry).
  static const String applyAll = 'Apply to all cuts';

  /// Removes every transition of the lane (the None tile is selected).
  static const String removeAll = 'Remove from all cuts';

  // ---- States ----------------------------------------------------------------------------------

  /// The cut no longer exists (an edit separated the clips).
  static const String noCut = 'These clips no longer touch, so there is no cut for a transition here.';

  /// The lane is locked.
  static const String trackLocked = 'This track is locked. Unlock it to change the transition.';

  /// No transition fits at this cut.
  static const String noneFits = 'These clips are too short for a transition.';

  // ---- History labels --------------------------------------------------------------------------

  /// History label of a duration drag.
  static const String historyDuration = 'Change transition duration';

  // ---- Action ----------------------------------------------------------------------------------

  /// Disabled reason of the Transitions tool when there is no cut (ux.md §9.1).
  static const String needTwoClips = 'Add at least two clips to use transitions';

  /// Disabled reason while the project does not accept edits.
  static const String notEditable = "The project can't be edited right now";

  /// Spoken summary of a transition ("Cross dissolve transition, 0.5 seconds").
  static String summary(TransitionKind kind, double seconds) =>
      '${kindName(kind)} transition, ${seconds.toStringAsFixed(seconds == seconds.roundToDouble() ? 0 : 1)} seconds';
}
