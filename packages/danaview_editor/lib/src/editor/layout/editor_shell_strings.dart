// OWNER: UX-07
//
// Copy of the editor shell (ux.md §4.7, §6.4, §14.3): top bar, save status, close flow, splitter
// semantics, unknown project and failure states. One place, so tests and the semantics labels use
// the same strings.

/// Copy of the editor screen shell.
abstract final class EditorShellStrings {
  /// Tooltip and label of the close button.
  static const String closeEditor = 'Close editor';

  /// Title while the project is opening.
  static const String opening = 'Opening…';

  /// Save status: everything is saved.
  static const String saved = 'Saved';

  /// Save status: a save is running (also while closing).
  static const String saving = 'Saving…';

  /// Save status: unsaved edits.
  static const String edited = 'Edited';

  /// Save status: the last save failed (tap to retry).
  static const String saveFailed = 'Couldn\'t save · Retry';

  /// Hint of the title button (opens the project sheet).
  static const String titleHint = 'Opens project options';

  /// Hint of the title button when the last save failed.
  static const String retryHint = 'Tries to save again';

  /// Export button.
  static const String export = 'Export';

  /// Undo without a label.
  static const String undo = 'Undo';

  /// Redo without a label.
  static const String redo = 'Redo';

  /// Undo tooltip with the history label and the shortcut ("Undo Split clip (⌘Z)").
  static String undoTooltip(String? label, {required bool apple}) => '${_join(undo, label)} (${apple ? '⌘Z' : 'Ctrl+Z'})';

  /// Redo tooltip with the history label and the shortcut ("Redo Split clip (⇧⌘Z)").
  static String redoTooltip(String? label, {required bool apple}) => '${_join(redo, label)} (${apple ? '⇧⌘Z' : 'Ctrl+Y'})';

  /// Semantics label of the splitter.
  static const String splitter = 'Preview size';

  /// Semantics value of the splitter ("50 percent").
  static String splitterValue(double ratio) => '${(ratio * 100).round()} percent';

  /// Title of the confirmation when the close flush failed.
  static const String leaveTitle = 'Couldn\'t save your latest changes';

  /// Message of that confirmation.
  static const String leaveMessage = 'Leave anyway? Your last autosave is kept.';

  /// Leave button of that confirmation.
  static const String leave = 'Leave';

  /// Stay button of that confirmation.
  static const String stay = 'Stay';

  /// Empty state of an unknown project id (ARCH §17.1).
  static const String unavailableTitle = 'This project isn\'t available';

  /// Message of that empty state.
  static const String unavailableMessage = 'It may have been deleted, or it was created on another device.';

  /// Action of that empty state.
  static const String goToProjects = 'Go to Projects';

  /// Close action when there is no Projects route.
  static const String close = 'Close';

  /// Title of a project that failed to open, when the controller gives none.
  static const String failedTitle = 'Couldn\'t open this project';

  static String _join(String verb, String? label) => label == null || label.trim().isEmpty ? verb : '$verb ${label.trim()}';
}
