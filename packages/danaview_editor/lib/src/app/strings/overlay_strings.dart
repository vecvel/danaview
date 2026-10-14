// OWNER: UX-28
//
// Copy of the Overlay (picture-in-picture) and Chroma key panels and the overlay actions
// (ux.md §10.10, §10.13): plain and specific, with a next step where one exists (ARCH §19). History
// labels name what changed. No ids or paths appear in the text.

import 'package:danaview_editor_core/model.dart' show TimeUs, microsPerSecond;

/// Copy of the Overlay panel and the overlay actions.
abstract final class OverlayStrings {
  // ---- Add -------------------------------------------------------------------------------------

  /// Button: pick a video and add it as an overlay.
  static const String addVideo = 'Add video overlay';

  /// Button: pick a photo and add it as an overlay.
  static const String addImage = 'Add image overlay';

  /// What adding does.
  static const String addHint =
      'The overlay goes on its own track at the playhead, at 40 % size on the right. Move, resize and time it on its own.';

  /// The project can't take new media (opening, closed or read-only).
  static const String cannotAdd = 'Overlays can’t be added to this project right now.';

  /// Nothing picked could become an overlay.
  static const String nothingAdded = 'Nothing was added. Pick a video or a photo.';

  /// The picker failed.
  static const String pickerFailed = "Couldn't open the picker. Check that Danaview may access your media in Settings, then try again.";

  /// Title of the import sheet.
  static const String importTitle = 'Add overlay';

  /// Announcement after an overlay was added.
  static const String added = 'Overlay added';

  // ---- List ------------------------------------------------------------------------------------

  /// Section title of the overlay list ("Overlays · 3").
  static String listTitle(int count) => count == 0 ? 'Overlays' : 'Overlays · $count';

  /// Subtitle of the list: its order.
  static const String listOrder = 'Front to back';

  /// No overlays yet.
  static const String empty = 'No overlays yet. Add a video or photo to show it over the main video.';

  /// Fallback name of an overlay whose media is gone.
  static const String unnamed = 'Overlay';

  /// Lane name ("Overlay 2"): its own name when it has one.
  static String laneName(String name, int ordinal) => name.trim().isEmpty ? 'Overlay $ordinal' : name.trim();

  /// One list row's subtitle ("Overlay 2 · 0:01–0:03").
  static String rowSubtitle(String lane, TimeUs start, TimeUs end) => '$lane · ${clock(start)}–${clock(end)}';

  /// Semantics hint of a list row.
  static const String rowHint = 'Selects this overlay';

  /// A time as m:ss.
  static String clock(TimeUs t) {
    final seconds = (t < 0 ? 0 : t) ~/ microsPerSecond;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // ---- Selected overlay ------------------------------------------------------------------------

  /// Section title of the selected overlay's tools.
  static const String selectedTitle = 'Selected overlay';

  /// Hint shown when no overlay is selected.
  static const String selectHint = 'Select an overlay in the list or on the timeline to order and edit it.';

  /// Button: one step towards the front.
  static const String bringForward = 'Bring forward';

  /// Button: one step towards the back.
  static const String sendBackward = 'Send backward';

  /// Button: the Transform panel (position, size, rotation, opacity).
  static const String transform = 'Transform';

  /// Button: the Crop panel.
  static const String crop = 'Crop';

  /// Button: the Chroma key panel.
  static const String chroma = 'Chroma key';

  /// Button: the Mask panel.
  static const String mask = 'Mask';

  /// Hint under the tools: opacity lives in Transform.
  static const String toolsHint = 'Opacity is in Transform. Drag the overlay on the preview to move, resize or rotate it.';

  // ---- Bindings: reasons -----------------------------------------------------------------------

  /// The project is not open yet.
  static const String notOpen = 'The project is still opening';

  /// Nothing (or not an overlay) is selected.
  static const String selectOverlay = 'Select an overlay first';

  /// Nothing (or not a picture clip) is selected.
  static const String selectClip = 'Select a video or photo clip first';

  /// The overlay's track is locked.
  static const String trackLocked = 'This track is locked';

  /// Already the frontmost overlay.
  static const String alreadyFront = 'This overlay is already in front';

  /// Already the backmost overlay.
  static const String alreadyBack = 'This overlay is already at the back';

  /// The tracks it would move to are locked.
  static const String targetLocked = 'The tracks in that direction are locked';

  // ---- History ---------------------------------------------------------------------------------

  /// History label of a forward move.
  static const String historyForward = 'Bring overlay forward';

  /// History label of a backward move.
  static const String historyBackward = 'Send overlay backward';
}

/// Copy of the Chroma key panel.
abstract final class ChromaStrings {
  /// The enable switch.
  static const String enable = 'Chroma key';

  /// Its subtitle.
  static const String enableHint = 'Removes a green or blue background';

  /// Shown while keying is off.
  static const String offHint = 'Turn it on, or pick the background colour, to make that colour see-through.';

  /// Key colour row label.
  static const String keyColor = 'Key colour';

  /// The eyedropper button.
  static const String eyedropper = 'Pick the colour from the preview';

  /// Quick chip: green screen.
  static const String green = 'Green';

  /// Quick chip: blue screen.
  static const String blue = 'Blue';

  /// Row label of the similarity.
  static const String similarity = 'Similarity';

  /// Row label of the smoothness.
  static const String smoothness = 'Smoothness';

  /// Row label of the spill reduction.
  static const String spill = 'Spill reduction';

  /// The matte preview switch.
  static const String showMatte = 'Show matte';

  /// Its subtitle.
  static const String showMatteHint = 'White stays, black is removed';

  /// The matte needs keying on.
  static const String matteNeedsKey = 'Turn on chroma key to see the matte';

  /// The clip is not under the playhead, so the preview can't be sampled there.
  static const String pickMoved = 'Moved to the clip so you can pick its colour';

  /// Semantics value of a colour ("#00B140").
  static String hex(int rgb) => '#${(rgb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  // ---- History ---------------------------------------------------------------------------------

  /// History label of the switch.
  static String historyEnable(bool on) => on ? 'Turn on chroma key' : 'Turn off chroma key';

  /// History label of a quick chip ("Key colour green").
  static String historyPreset(String name) => 'Key colour ${name.toLowerCase()}';

  /// History label of the eyedropper.
  static const String historyPick = 'Pick key colour';

  /// History label of the colour field.
  static const String historyColor = 'Change key colour';

  /// History label of the header's reset.
  static const String historyReset = 'Reset chroma key';
}
