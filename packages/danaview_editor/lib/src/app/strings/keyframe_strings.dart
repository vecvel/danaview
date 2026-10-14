// OWNER: UX-26
//
// Copy of the Keyframes panel and the keyframe actions (ux.md §9.4, §10.11): plain and specific,
// with a next step where one exists (ARCH §19). No ids or paths appear in the text.

/// Copy of the Keyframes panel and the keyframe actions.
abstract final class KeyframeStrings {
  // ---- Groups ----------------------------------------------------------------------------------

  /// Group: position, scale, rotation, opacity.
  static const String groupTransform = 'Transform';

  /// Group: the light, colour and detail values.
  static const String groupAdjust = 'Adjust';

  /// Group: the mask values.
  static const String groupMask = 'Mask';

  /// Group: volume.
  static const String groupAudio = 'Audio';

  // ---- Property rows ---------------------------------------------------------------------------

  /// "3 keyframes".
  static String count(int n) => n == 1 ? '1 keyframe' : '$n keyframes';

  /// Tooltip of the row menu.
  static const String rowMenu = 'More';

  /// Row menu entry: removes every key of the property (it stays at its current value).
  static const String removeAllOfProperty = 'Remove all keyframes';

  /// Semantics label of the key strip of a property ("Opacity keyframes").
  static String stripLabel(String property) => '$property keyframes';

  /// Semantics hint of the key strip.
  static const String stripHint = 'Drag a diamond to move a keyframe';

  /// Semantics label of one diamond ("Opacity keyframe at 00:01:15").
  static String diamondLabel(String property, String time) => '$property keyframe at $time';

  /// Semantics value of one diamond: its value ("75%").
  static String diamondValue(String value) => value;

  /// Semantics action: moves the selected key one frame earlier.
  static const String nudgeEarlier = 'Move one frame earlier';

  /// Semantics action: moves the selected key one frame later.
  static const String nudgeLater = 'Move one frame later';

  /// Semantics action of a diamond.
  static const String select = 'Select keyframe';

  // ---- Selected keyframe -----------------------------------------------------------------------

  /// Title of the selected keyframe card ("Opacity, keyframe 2 of 3").
  static String selectedTitle(String property, int index, int total) => '$property, keyframe $index of $total';

  /// Label of the time row.
  static const String time = 'Time';

  /// Tooltip of the -1 frame button.
  static const String frameBack = 'Back one frame';

  /// Tooltip of the +1 frame button.
  static const String frameForward = 'Forward one frame';

  /// Label of the value row.
  static const String value = 'Value';

  /// First value row of a position or mask centre key.
  static const String valueX = 'X';

  /// Second value row of a position or mask centre key.
  static const String valueY = 'Y';

  /// First value row of a mask size key.
  static const String valueWidth = 'Width';

  /// Second value row of a mask size key.
  static const String valueHeight = 'Height';

  /// Label of the interpolation row.
  static const String interpolation = 'Interpolation';

  /// The only interpolation of v1 (easing is out of scope).
  static const String linear = 'Linear';

  /// Button: moves the playhead onto the keyframe.
  static const String jumpHere = 'Jump here';

  /// Button: deletes the keyframe.
  static const String delete = 'Delete keyframe';

  // ---- Panel -----------------------------------------------------------------------------------

  /// Title of the empty state.
  static const String emptyTitle = 'No keyframes yet';

  /// Body of the empty state.
  static const String emptyBody = 'Move the playhead over the clip, then add a keyframe to a property to animate it.';

  /// Section header of the add area.
  static const String addTitle = 'Animate a property';

  /// Button that lists the properties that can be keyframed.
  static const String addButton = 'Add keyframe';

  /// Hint under the add area when the playhead is not over the item.
  static const String outsideItem = 'Move the playhead over the clip to add keyframes.';

  /// Footer button: removes the keys of every property.
  static const String removeAll = 'Remove all keyframes';

  /// The track is locked.
  static const String trackLocked = 'This track is locked';

  /// Toast after removing every key.
  static const String removedAll = 'Keyframes removed';

  // ---- History labels --------------------------------------------------------------------------

  /// One entry: keys of several properties added at the playhead.
  static const String historyKeyframeAll = 'Add keyframes';

  /// One entry: keys of several properties removed at the playhead.
  static const String historyRemoveKeys = 'Remove keyframes';

  /// One entry: the key at the playhead was added or removed.
  static const String historyAtPlayhead = 'Keyframe at playhead';

  /// One entry: a key moved by a frame.
  static const String historyNudge = 'Move keyframe';

  /// One entry: a key's value changed.
  static const String historyValue = 'Change keyframe';

  /// One entry: every key of an item removed.
  static const String historyRemoveAll = 'Remove all keyframes';

  // ---- Actions ---------------------------------------------------------------------------------

  /// The project is still opening.
  static const String notOpen = 'The project is still opening';

  /// Nothing animatable is selected.
  static const String selectItem = 'Select a clip or text to add keyframes';

  /// The selected item's track is locked.
  static const String actionTrackLocked = 'This track is locked. Unlock it to add keyframes.';

  /// The playhead is not over the item.
  static const String playheadOutside = 'Move the playhead over the selected item to add a keyframe';

  /// The project is read-only.
  static const String notEditable = 'This project can only be viewed right now';
}
