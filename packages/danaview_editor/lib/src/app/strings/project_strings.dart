// OWNER: UX-29
//
// Copy of the Format panel, the Project sheet, the History sheet and the project actions
// (ux.md §6.4, §10.14, §14.2-14.3): plain, specific and with a next step where one exists
// (ARCH §19).

import 'package:danaview_editor_core/model.dart' show AspectRatio, FrameRate;

/// Copy of the Format panel, the Project sheet and the History sheet (UX-29).
abstract final class ProjectStrings {
  // ---- Format panel: aspect -------------------------------------------------------------------

  /// Heading of the aspect chips.
  static const String aspectHeading = 'Aspect ratio';

  /// "16:9".
  static String aspect(AspectRatio aspect) => '${aspect.w}:${aspect.h}';

  /// The chip that matches the first clip ("Original · 4:3").
  static String aspectOriginal(AspectRatio aspect) => 'Original · ${ProjectStrings.aspect(aspect)}';

  /// Toast after the aspect changed (ux.md §10.14).
  static const String aspectChanged = 'Clips keep their size; adjust them with Transform.';

  // ---- Format panel: background ---------------------------------------------------------------

  /// Heading of the background controls.
  static const String backgroundHeading = 'Background';

  /// Segment: a solid colour.
  static const String backgroundColor = 'Colour';

  /// Segment: a blurred copy of the main video.
  static const String backgroundBlur = 'Blur';

  /// Label of the colour row and title of its picker.
  static const String backgroundColorLabel = 'Background colour';

  /// Label of the blur amount slider.
  static const String blurAmount = 'Blur amount';

  /// What the blur background does.
  static const String blurHint = 'Fills the empty space with a blurred copy of the video below.';

  // ---- Format panel: frame rate ---------------------------------------------------------------

  /// Heading of the frame-rate chips.
  static const String frameRateHeading = 'Frame rate';

  /// "30 fps".
  static String fps(FrameRate rate) => '${rate.num ~/ rate.den} fps';

  /// The chip that matches the first clip ("Match first clip · 25 fps").
  static String fpsMatch(FrameRate rate) => 'Match first clip · ${fps(rate)}';

  /// Title of the frame-rate confirmation (requantize warning).
  static String frameRateConfirmTitle(FrameRate rate) => 'Change the frame rate to ${fps(rate)}?';

  /// Body of the frame-rate confirmation.
  static const String frameRateConfirmMessage =
      'Cuts, keyframes and markers move to the nearest frame of the new rate, by at most one frame. You can undo this.';

  /// Confirm button of the frame-rate confirmation.
  static const String frameRateConfirm = 'Change';

  /// Cancel button.
  static const String cancel = 'Cancel';

  // ---- Format panel: resolution ---------------------------------------------------------------

  /// Heading of the resolution chips.
  static const String resolutionHeading = 'Resolution';

  /// "720p", "1080p", "4K".
  static String resolution(int shortSide) => shortSide >= 2160 ? '4K' : '${shortSide}p';

  /// "Canvas 1920 × 1080".
  static String canvasSize(int w, int h) => 'Canvas $w × $h';

  /// Why 4K is not offered.
  static const String resolution4kUnavailable = '4K isn\'t available on this device.';

  /// What the resolution base sets.
  static const String resolutionHint = 'Sets the size used for text and positions. Export can still choose its own size.';

  // ---- Format panel: state --------------------------------------------------------------------

  /// The project cannot be edited (opening, read-only).
  static const String notEditable = 'This project can\'t be edited right now.';

  // ---- Project sheet --------------------------------------------------------------------------

  /// Sheet title.
  static const String projectTitle = 'Project';

  /// Save status lines (ux.md §6.4).
  static const String statusSaved = 'Saved';

  /// Saving.
  static const String statusSaving = 'Saving…';

  /// Unsaved edits.
  static const String statusEdited = 'Edited';

  /// Saving failed.
  static const String statusFailed = 'Couldn\'t save';

  /// Read-only project.
  static const String statusReadOnly = 'Read-only';

  /// Opening.
  static const String statusOpening = 'Opening…';

  /// Semantics label of the status line.
  static String statusSemantics(String status) => 'Save status: $status';

  /// Row: rename.
  static const String rename = 'Rename';

  /// Row: Format panel.
  static const String format = 'Format';

  /// Subtitle of the Format row ("16:9 · 30 fps · 1080p").
  static String formatSummary(AspectRatio aspect, FrameRate rate, int shortSide) =>
      '${ProjectStrings.aspect(aspect)} · ${fps(rate)} · ${resolution(shortSide)}';

  /// Row: save now.
  static const String saveNow = 'Save now';

  /// Subtitle of Save now after a failure.
  static const String saveRetry = 'The last save failed. Try again.';

  /// Row: media in project.
  static const String media = 'Media in project';

  /// Subtitle of the media row ("3 files").
  static String mediaCount(int n) => n == 1 ? '1 file' : '$n files';

  /// Row: keyboard shortcuts.
  static const String shortcuts = 'Keyboard shortcuts';

  /// Row: background tasks.
  static const String tasks = 'Background tasks';

  /// Row: edit history.
  static const String history = 'Edit history';

  /// Subtitle of the history row ("12 edits").
  static String historyCount(int n) => n == 0 ? 'No edits yet' : (n == 1 ? '1 edit' : '$n edits');

  // ---- Rename ---------------------------------------------------------------------------------

  /// Title of the rename prompt.
  static const String renameTitle = 'Rename project';

  /// Hint of the rename field.
  static const String renameHint = 'Project name';

  /// Confirm button of the rename prompt.
  static const String renameConfirm = 'Rename';

  /// Toast after a rename.
  static String renamed(String name) => 'Renamed to "$name"';

  /// Toast when the store cannot rename the open project.
  static const String renameBusy = 'Couldn\'t rename the project while it\'s open. Rename it from Projects.';

  /// Toast when the rename failed otherwise.
  static const String renameFailed = 'Couldn\'t rename the project. Try again.';

  // ---- History sheet --------------------------------------------------------------------------

  /// Sheet title (ux.md §14.2).
  static const String historyTitle = 'Edit history';

  /// Shown when there is nothing in history.
  static const String historyEmpty = 'No edits yet. Your changes appear here, newest first.';

  /// The row of the state before every kept entry.
  static const String historyStart = 'Start';

  /// Subtitle of [historyStart].
  static const String historyStartHint = 'Before the edits listed here';

  /// Subtitle of the current entry.
  static const String historyCurrent = 'Current';

  /// Subtitle of an entry that was undone.
  static const String historyUndone = 'Undone · tap to redo';

  /// Note when older entries are not shown.
  static String historyOlder(int hidden) => hidden == 1 ? '1 older edit isn\'t shown.' : '$hidden older edits aren\'t shown.';

  /// Semantics of a row ("Split clip, current").
  static String historyRowSemantics(String label, {required bool current, required bool undone}) =>
      current ? '$label, current' : (undone ? '$label, undone' : label);

  /// Semantics hint of a row.
  static const String historyRowHint = 'Undoes or redoes to this point';

  // ---- Actions --------------------------------------------------------------------------------

  /// The project is still opening.
  static const String notOpen = 'The project is still opening';

  /// The Format action cannot run.
  static const String formatUnavailable = 'This project can\'t be edited right now';
}
