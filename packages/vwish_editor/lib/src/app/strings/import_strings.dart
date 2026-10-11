// OWNER: UX-06
//
// Copy of the New project sheet and the import flow (ux.md §5.3, ARCH §9.1, D-13): picker
// buttons, formats, per-item status, inline errors per `ImportRejected.reason`, the free-space
// refusal, the result summary and the iOS Photos hint. Plain, specific, with a next step
// (ARCH §19). Never includes media paths.

import 'package:flutter/foundation.dart' show TargetPlatform;

/// Copy of the New project sheet (ux.md §5.3).
abstract final class NewProjectStrings {
  /// Sheet title.
  static const String title = 'New project';

  /// Section: media.
  static const String mediaSection = 'Add media';

  /// Media section hint while nothing is picked.
  static const String mediaHint = 'Pick videos, photos and music. They are added to the timeline in the order you pick them.';

  /// The photo-library picker button: `Photos` on iOS, `Gallery` elsewhere.
  static String photosButton(TargetPlatform platform) => platform == TargetPlatform.iOS ? 'Photos' : 'Gallery';

  /// The document picker button.
  static const String filesButton = 'Files';

  /// Spoken label of an item's remove button.
  static String removeItem(String name) => 'Remove $name';

  /// Section: format.
  static const String formatSection = 'Format';

  /// The "match the first video" format.
  static const String formatAuto = 'Auto';

  /// What Auto does.
  static const String formatAutoHint = 'Matches the first video. Without media, new projects are 16:9.';

  /// Section: name.
  static const String nameSection = 'Name';

  /// Name field hint (also the default name).
  static const String untitled = 'Untitled project';

  /// Primary button.
  static const String create = 'Create';

  /// Secondary button: a project with no media.
  static const String startEmpty = 'Start empty';

  /// The picker could not be shown.
  static const String pickerFailed = "Couldn't open the picker. Check that Vwish may access your media in Settings, then try again.";

  /// Creating an empty project failed.
  static const String createFailed = "Couldn't create the project. Free up some space and try again.";

  /// The name is too long.
  static const String nameTooLong = 'Use 80 characters or fewer.';
}

/// Copy of the import flow (ImportMediaSheet).
abstract final class ImportStrings {
  /// Default sheet title.
  static const String title = 'Import media';

  /// `Adding 3 items`.
  static String adding(int count) => count == 1 ? 'Adding 1 item' : 'Adding $count items';

  /// Checking free space before copying.
  static const String checkingSpace = 'Checking free space…';

  /// Item: waiting for its turn.
  static const String waiting = 'Waiting';

  /// Item: probing.
  static const String checking = 'Checking…';

  /// Item: copying.
  static const String copying = 'Copying into Vwish…';

  /// Item: copying with a known fraction.
  static String copyingPercent(int percent) => 'Copying into Vwish… $percent%';

  /// Item: done.
  static const String added = 'Added';

  /// Item: cancelled.
  static const String cancelled = 'Cancelled';

  /// Cancel button.
  static const String cancel = 'Cancel';

  /// Cancel pressed; waiting for the current file to stop.
  static const String cancelling = 'Cancelling…';

  /// The iOS Photos hint (D-13).
  static const String photosCopyHint = 'Videos from Photos are copied into Vwish so your project keeps working.';

  /// Inline error for an `ImportRejected.reason` (stable codes of CORE-27).
  static String reason(String code) => switch (code) {
        'containerUnsupportedIos' => "MKV, WebM and AVI videos can't be edited on iPhone and iPad. Convert it to MP4 or MOV first.",
        'unsupported' || 'codecUnsupported' || 'notScripted' => 'This format is not supported for editing.',
        'protected' || 'protectedContent' => 'This video is copy-protected, so it cannot be edited.',
        'empty' => 'This file is empty.',
        'notFound' => 'This file is no longer available. Pick it again.',
        'accessDenied' => 'Vwish is not allowed to read this file. Pick it again, or check permissions in Settings.',
        'notPersistable' => "Vwish couldn't keep access to this file. Try picking it from Files instead.",
        'diskFull' => 'Not enough storage space to copy this file. Free up some space and try again.',
        'lutInvalid' => "This LUT file couldn't be read.",
        'cancelled' => 'Cancelled',
        _ => "Couldn't add this file. Try again.",
      };

  /// `Couldn't add this file: <reason>` for the inline error on an item.
  static String itemError(String code) => code == 'cancelled' ? cancelled : reason(code);

  // ---- Free space ----------------------------------------------------------------------------

  /// Refusal title.
  static const String spaceTitle = 'Not enough space';

  /// Refusal message: what is needed and what is free.
  static String spaceMessage(String needed, String free) =>
      'Copying needs about $needed plus 64 MB to spare, and $free is free. Free up space or remove some items, then try again.';

  /// Retry button.
  static const String tryAgain = 'Try again';

  // ---- Summary -------------------------------------------------------------------------------

  /// Everything was added.
  static String allAdded(int count) => count == 1 ? '1 item added' : '$count items added';

  /// Part was added.
  static String someAdded(int added, int total) => '$added of $total added';

  /// `1 item couldn't be added.`
  static String failedCount(int failed) => failed == 1 ? "1 item couldn't be added." : "$failed items couldn't be added.";

  /// Nothing was added.
  static const String noneAdded = 'Nothing was added';

  /// Next step when nothing was added.
  static const String noneAddedMessage = 'Remove the items that failed or pick other files, then try again.';

  /// Cancelled.
  static const String cancelledTitle = 'Import cancelled';

  /// Cancelled before anything was kept.
  static const String cancelledNothingKept = 'Nothing was added and no copies were kept.';

  /// Cancelled after some items were added.
  static String cancelledKept(int added) =>
      added == 1 ? '1 item was added before you cancelled.' : '$added items were added before you cancelled.';

  /// The import job failed as a whole.
  static const String failedTitle = "Couldn't finish the import";

  /// Next step after a failed job.
  static const String failedMessage = 'Nothing was changed. Free up some space or pick the files again, then try again.';

  /// Done button.
  static const String done = 'Done';

  /// Open the created project.
  static const String openProject = 'Open project';

  /// Back to the selection.
  static const String back = 'Back';

  /// Close button.
  static const String close = 'Close';
}
