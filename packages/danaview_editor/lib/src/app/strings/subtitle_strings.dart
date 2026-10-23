// OWNER: UX-31
// EXTENDED: AIS-01 (labels of the 1.2.0 panel sections)
//
// Copy of the captions panel and the caption actions (ux.md §10.9): plain, specific and with a
// next step where one exists (ARCH §19). Glyphs never carry meaning alone; every icon-only control
// has a semantics label here.

import 'package:danaview_editor_core/model.dart' show TextAlignH;

import '../../editor/contracts/inspector_routes.dart' show SubtitlesPanelSection;

/// Copy of the captions panel (ux.md §10.9).
abstract final class SubtitleStrings {
  // ---- Start state -----------------------------------------------------------------------------

  /// Shown when the project has no subtitle track yet.
  static const String emptyTitle = 'No captions yet';

  /// The next step of the empty state.
  static const String emptyMessage = 'Add a subtitle track and type captions, or import an SRT or VTT file.';

  /// Adds a subtitle track.
  static const String addTrack = 'Add subtitle track';

  /// Heading of the list of subtitle tracks in the start state.
  static const String tracksHeading = 'Subtitle tracks';

  /// The number of captions on a track ("312 captions").
  static String cueCount(int n) => n == 1 ? '1 caption' : '$n captions';

  /// Name of an unnamed subtitle track ("Subtitles 2").
  static String laneName(int ordinal) => ordinal <= 1 ? 'Subtitles' : 'Subtitles $ordinal';

  // ---- Header ----------------------------------------------------------------------------------

  /// Adds a caption at the playhead.
  static const String add = 'Add';

  /// Semantics label of the Add button.
  static const String addSemantics = 'Add a caption at the playhead';

  /// Text of a new caption.
  static const String newCueText = 'New caption';

  /// Semantics label of the track menu button.
  static const String menu = 'Caption track options';

  /// The section switcher.
  static const String sections = 'Captions panel sections';

  /// The label of a section.
  static String section(SubtitlesPanelSection s) => switch (s) {
        SubtitlesPanelSection.cues => 'Captions',
        SubtitlesPanelSection.style => 'Style',
        SubtitlesPanelSection.position => 'Position',
        // 1.2.0 (AIS-01; AIS-17, AIS-33 and AIS-18 own the sections).
        SubtitlesPanelSection.transcript => 'Transcript',
        SubtitlesPanelSection.review => 'Review',
        SubtitlesPanelSection.cue => 'Cue',
      };

  /// Shown when the track is locked.
  static const String locked = 'This track is locked. Unlock it in the track menu to edit captions.';

  /// Shown when the track of the panel no longer exists.
  static const String trackGone = 'This subtitle track was deleted.';

  /// Shown when a track has no captions.
  static const String noCues = 'No captions on this track. Tap Add to type one at the playhead.';

  // ---- Track menu ------------------------------------------------------------------------------

  /// Menu heading above the track choices.
  static const String showTrack = 'Show track';

  /// Auto captions entry.
  static const String autoCaptions = 'Auto captions';

  /// Import entry.
  static const String importFile = 'Import SRT or VTT';

  /// Export entry.
  static const String exportFile = 'Export SRT or VTT';

  /// Shift entry.
  static const String shiftAll = 'Shift all captions…';

  /// Shift entry when a range of captions is selected.
  static const String shiftSelected = 'Shift selected captions…';

  /// Select-all entry.
  static const String selectAll = 'Select all on this lane';

  /// Burn-in switch (menu and style section).
  static const String burnIn = 'Burn into video';

  /// Second line of the burn-in switch.
  static const String burnInHint = 'Draw these captions into the exported video. Off keeps them in the preview only.';

  /// Delete-track entry.
  static const String deleteTrack = 'Delete track';

  /// Delete-track confirmation title.
  static String deleteTitle(String name) => 'Delete $name?';

  /// Delete-track confirmation message.
  static String deleteMessage(int cues) => cues == 0
      ? 'The empty track is removed. You can undo this.'
      : 'Its ${cueCount(cues)} are removed with it. You can undo this.';

  /// Delete-track confirmation button.
  static const String deleteConfirm = 'Delete';

  /// Cancel.
  static const String cancel = 'Cancel';

  /// Reason shown on a menu row whose feature is not available.
  static const String notAvailable = 'Not available yet';

  // ---- Shift -----------------------------------------------------------------------------------

  /// Title of the shift dialog.
  static const String shiftTitle = 'Shift captions';

  /// Message of the shift dialog for a whole track.
  static String shiftAllMessage(int cues) => 'Moves all ${cueCount(cues)} on this track. Type an amount like +2.5s or -10f.';

  /// Message of the shift dialog for a selected range.
  static String shiftRangeMessage(int cues) => 'Moves the ${cueCount(cues)} in the selected range. Type an amount like +2.5s or -10f.';

  /// Hint of the shift field.
  static const String shiftHint = '+2.5s';

  /// Confirm button of the shift dialog.
  static const String shiftConfirm = 'Shift';

  /// The amount could not be read.
  static const String shiftInvalid = 'Type seconds or frames, for example +2.5s, -1s or +10f.';

  /// The amount rounds to zero frames.
  static const String shiftZero = 'That moves the captions by less than one frame.';

  /// The shift stopped at the start of the project.
  static const String shiftClamped = 'Stopped at the start of the project';

  /// The shift was applied ("Captions shifted by +2.50 s").
  static String shifted(String amount) => 'Captions shifted by $amount';

  // ---- Cue rows --------------------------------------------------------------------------------

  /// The timing line of a row ("00:01:05 – 00:03:12").
  static String timing(String start, String end) => '$start – $end';

  /// Semantics label of a row.
  static String rowLabel(String start, String end, String text) => 'Caption $start to $end: $text';

  /// Semantics hint of a collapsed row.
  static const String rowHint = 'Selects the caption and moves the playhead to it';

  /// Semantics value of the caption under the playhead.
  static const String current = 'At the playhead';

  /// Label of the text field.
  static const String textField = 'Caption text';

  /// Hint of the text field.
  static const String textHint = 'Type the caption. Return starts a new line.';

  /// The text field is empty.
  static const String emptyText = 'A caption needs text. Use Delete to remove it.';

  /// Commits the text.
  static const String done = 'Done';

  /// Start field.
  static const String start = 'Start';

  /// End field.
  static const String end = 'End';

  /// −100 ms step.
  static const String minus100 = '−0.1 s';

  /// +100 ms step.
  static const String plus100 = '+0.1 s';

  /// Semantics label of the −100 ms step.
  static String minus100Semantics(String field) => '$field 0.1 seconds earlier';

  /// Semantics label of the +100 ms step.
  static String plus100Semantics(String field) => '$field 0.1 seconds later';

  /// Sets an edge to the playhead.
  static const String toPlayhead = 'To playhead';

  /// Semantics label of the "to playhead" button.
  static String toPlayheadSemantics(String field) => 'Set $field to the playhead';

  /// Split action.
  static const String split = 'Split';

  /// Why split is disabled.
  static const String splitNeedsPlayhead = 'Move the playhead inside this caption to split it.';

  /// Merge action.
  static const String merge = 'Merge with next';

  /// Why merge is disabled.
  static const String mergeNeedsNext = 'This is the last caption on the track.';

  /// Delete action.
  static const String delete = 'Delete';

  /// Jump action.
  static const String jump = 'Go to start';

  // ---- Style -----------------------------------------------------------------------------------

  /// Font row.
  static const String font = 'Font';

  /// Opens the font list.
  static const String changeFont = 'Change';

  /// Closes the font list.
  static const String closeFonts = 'Close';

  /// Size row.
  static const String size = 'Size';

  /// Size unit.
  static const String pt = 'pt';

  /// Bold row.
  static const String bold = 'Bold';

  /// Italic row.
  static const String italic = 'Italic';

  /// Text colour row.
  static const String color = 'Text colour';

  /// Box switch.
  static const String box = 'Background box';

  /// Box colour row.
  static const String boxColor = 'Box colour';

  /// Box opacity row.
  static const String boxOpacity = 'Box opacity';

  /// Outline switch.
  static const String outline = 'Outline';

  /// Outline colour row.
  static const String outlineColor = 'Outline colour';

  /// Outline width row.
  static const String outlineWidth = 'Outline width';

  /// Shadow switch.
  static const String shadow = 'Shadow';

  /// Shadow colour row.
  static const String shadowColor = 'Shadow colour';

  /// Shadow blur row.
  static const String shadowBlur = 'Shadow blur';

  /// Max lines row.
  static const String maxLines = 'Lines per caption';

  /// Max width row.
  static const String maxWidth = 'Line width';

  /// Alignment row.
  static const String alignment = 'Alignment';

  /// The label of an alignment.
  static String align(TextAlignH a) => switch (a) {
        TextAlignH.left => 'Left',
        TextAlignH.center => 'Centre',
        TextAlignH.right => 'Right',
      };

  /// Heading of the track settings.
  static const String trackHeading = 'Track';

  /// Language field.
  static const String language = 'Language';

  /// Hint of the language field.
  static const String languageHint = 'en, pt-BR, zh-Hant';

  /// The language tag is not valid.
  static const String languageInvalid = 'Use a language tag like en, pt-BR or zh-Hant.';

  /// Percent unit.
  static const String percent = '%';

  // ---- Position --------------------------------------------------------------------------------

  /// Placement row.
  static const String placement = 'Placement';

  /// Bottom placement.
  static const String bottom = 'Bottom';

  /// Top placement.
  static const String top = 'Top';

  /// Custom placement.
  static const String custom = 'Custom';

  /// Vertical offset row.
  static const String offset = 'Vertical position';

  /// Shown with the custom placement.
  static const String dragHint = 'You can also drag the captions up or down on the preview.';

  // ---- History labels (gestures) ---------------------------------------------------------------

  /// History label of style gestures.
  static const String historyStyle = 'Caption style';

  /// History label of position gestures.
  static const String historyPosition = 'Caption position';

  // ---- Actions ---------------------------------------------------------------------------------

  /// Why the caption actions are disabled.
  static const String notEditable = 'Captions can be edited once the project is open';

  /// Why Add is disabled on a locked track.
  static const String trackLocked = 'Unlock the subtitle track to add captions';
}
