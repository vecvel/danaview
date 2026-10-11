// OWNER: UX-24
//
// Copy of the Adjust and Filters panels and the colour actions (ux.md §10.6, §10.7): plain and
// specific, with a next step where one exists (ARCH §19). No ids or paths appear in the text.

/// Copy of the Adjust and Filters panels.
abstract final class ColorStrings {
  // ---- Adjust ----------------------------------------------------------------------------------

  /// Section: exposure, brightness, contrast, highlights, shadows.
  static const String sectionLight = 'Light';

  /// Section: saturation, temperature, tint.
  static const String sectionColor = 'Color';

  /// Section: sharpness, blur, vignette, opacity.
  static const String sectionDetail = 'Detail';

  /// Label of the segmented control.
  static const String sectionsLabel = 'Adjust section';

  /// Tooltip and semantics label of the before/after button.
  static const String compare = 'Hold to compare with the original';

  /// Semantics hint of the before/after button (assistive technology toggles it).
  static const String compareHint = 'Double tap to show or hide the original';

  /// Footer button: copies the values to every clip of the lane.
  static const String applyToAll = 'Apply to all clips';

  /// Footer button: neutral values.
  static const String resetAll = 'Reset all';

  /// Why "Apply to all clips" is disabled with a single clip.
  static const String applyToAllSingle = 'There is only one clip on this track';

  /// Toast after "Apply to all clips".
  static String appliedToClips(int count) => count == 1 ? 'Applied to 1 clip' : 'Applied to $count clips';

  /// The adjust values on every clip of the lane become the selected clip's, in one step.
  static const String applyToAllHint = 'Copies these values to every clip on this track';

  /// The selected item's track is locked.
  static const String trackLocked = 'This track is locked';

  /// The panel cannot edit the item (a text, audio or caption).
  static const String notEditable = 'This item has no picture to adjust';

  // ---- Actions ---------------------------------------------------------------------------------

  /// Toast when the Effects or Filters tool picked the clip under the playhead (ux.md §9.1).
  static const String editingClipAtPlayhead = 'Editing clip at playhead';

  /// Disabled reason: nothing to adjust.
  static const String noClip = 'Add a clip to the timeline first';

  /// Disabled reason while the project is still opening.
  static const String notOpen = 'The project is still opening';

  // ---- Filters ---------------------------------------------------------------------------------

  /// Section title of the built-in looks.
  static const String looks = 'Looks';

  /// The tile that removes the look.
  static const String none = 'None';

  /// Intensity slider label.
  static const String intensity = 'Intensity';

  /// Section title of the imported LUTs.
  static const String myLuts = 'My LUTs';

  /// Import button.
  static const String importCube = 'Import .cube';

  /// Shown under "My LUTs" before the first import.
  static const String noLuts = 'Import a .cube file to use your own look.';

  /// The importer is running.
  static const String importing = 'Importing…';

  /// Semantics label of the looks carousel.
  static const String looksLabel = 'Looks';

  /// Semantics label of the LUT carousel.
  static const String lutsLabel = 'My LUTs';

  /// Long-press menu: rename.
  static const String rename = 'Rename';

  /// Long-press menu: remove.
  static const String removeFromProject = 'Remove from project';

  /// Semantics hint of a LUT tile.
  static const String lutHint = 'Long press for rename and remove';

  /// Title of the rename dialog.
  static const String renameTitle = 'Rename LUT';

  /// Hint of the rename field.
  static const String renameHint = 'LUT name';

  /// Rename confirm button.
  static const String renameConfirm = 'Rename';

  /// Empty name.
  static const String nameRequired = 'Enter a name';

  /// Title of the remove confirmation.
  static String removeTitle(String name) => 'Remove "$name"?';

  /// Message of the remove confirmation.
  static String removeMessage(int clips) => switch (clips) {
        0 => 'This removes the LUT from the project.',
        1 => '1 clip uses this look and will lose it.',
        _ => '$clips clips use this look and will lose it.',
      };

  /// Remove confirm button.
  static const String removeConfirm = 'Remove';

  /// Toast after an import.
  static String lutAdded(String name) => '"$name" added to My LUTs';

  /// Toast after a removal.
  static String lutRemoved(String name) => '"$name" removed';

  /// A LUT the file reader or the parser refused, with the parser's line when it has one
  /// ("This LUT couldn't be read (line 14: expected 3 numbers).").
  static String lutUnreadable({int? line, String? detail}) {
    if (detail == null || detail.isEmpty) return 'This LUT couldn\'t be read.';
    return line == null
        ? 'This LUT couldn\'t be read ($detail).'
        : 'This LUT couldn\'t be read (line $line: $detail).';
  }

  /// The LUT is bigger than the supported 65x65x65.
  static const String lutTooLarge = 'LUTs up to 65×65×65 are supported.';

  /// The picked file could not be opened.
  static const String lutCannotOpen = 'Couldn\'t open that file. Pick it again.';

  /// The device is out of space.
  static const String lutDiskFull = 'There isn\'t enough space to add this LUT. Free up some storage and try again.';

  /// Any other import failure.
  static const String lutFailed = 'Couldn\'t add this LUT. Try again.';

  /// "Remove from project" failed because the LUT is in use somewhere the panel could not clear.
  static const String lutInUse = 'This LUT is still in use. Remove it from the clips first.';

  /// Semantics label of a look tile.
  static String lookTile(String name, {required bool selected}) => selected ? '$name, selected' : name;

  // ---- Looks -----------------------------------------------------------------------------------

  /// Display name of the built-in look [presetId] (the id itself for an unknown one).
  static String lookName(String presetId) => _lookNames[presetId] ?? presetId;

  static const Map<String, String> _lookNames = <String, String>{
    'teal_orange': 'Teal & Orange',
    'warm': 'Warm',
    'cool': 'Cool',
    'vivid': 'Vivid',
    'matte': 'Matte',
    'fade': 'Fade',
    'mono': 'Mono',
    'noir': 'Noir',
    'sepia': 'Sepia',
    'vintage': 'Vintage',
    'cinematic': 'Cinematic',
    'pastel': 'Pastel',
  };

  // ---- History labels --------------------------------------------------------------------------

  /// "Apply to all clips".
  static const String historyApplyToAll = 'Apply adjustments to all clips';

  /// "Reset all".
  static const String historyResetAll = 'Reset adjustments';

  /// Keyframing every row of a section at once.
  static const String historyKeyframeAll = 'Add keyframes';

  /// Removing the keys of every row of a section at the playhead.
  static const String historyRemoveKeys = 'Remove keyframes';

  /// Removing a LUT's look from clips before the LUT goes.
  static const String historyRemoveLook = 'Remove look';
}
