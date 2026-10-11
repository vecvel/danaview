// OWNER: UX-40
//
// Copy of the missing media, relink, recovery and migration UX (ux.md §13): the editor's banner, the
// Missing media sheet (rows, outcomes, "Relink several"), the recovery dialog and the Projects
// screen's recovery banner. Plain, specific, with a next step (ARCH §19). Never includes full file
// paths: a row shows the file's name and at most its last known folder, middle-ellipsized.

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:vwish_editor_core/model.dart' show MediaKind, TimeUs;

import 'import_strings.dart' show ImportStrings;

/// Copy of the editor's missing media surfaces (ux.md §13.1, §13.2).
abstract final class RelinkStrings {
  // ---- Banner --------------------------------------------------------------------------------

  /// `1 file is missing`, `2 files are missing`; `needAttention` when some files changed or lost
  /// access instead of going missing.
  static String banner(int count, {required bool onlyMissing}) {
    if (onlyMissing) return count == 1 ? '1 file is missing' : '$count files are missing';
    return count == 1 ? '1 file needs attention' : '$count files need attention';
  }

  /// The banner's button.
  static const String relink = 'Relink';

  /// Spoken label of the banner as a whole.
  static String bannerSemantics(String text) => '$text. Relink to fix it.';

  /// Tooltip and spoken label of the dismiss button.
  static const String dismissBanner = 'Dismiss for now';

  // ---- Sheet ---------------------------------------------------------------------------------

  /// Sheet title.
  static const String sheetTitle = 'Missing media';

  /// What the sheet is for.
  static const String sheetIntro = 'Your original files are never moved or changed. Pick each file again, or let Vwish match several at once.';

  /// `1 file`, `3 files` (sheet summary).
  static String files(int count) => count == 1 ? '1 file' : '$count files';

  /// Nothing is missing any more.
  static const String allGoodTitle = 'Everything is back';

  /// Next step when nothing is missing.
  static const String allGoodMessage = 'All the media in this project can be found again.';

  /// Checking availability.
  static const String checking = 'Checking your media…';

  /// Close button once nothing is missing.
  static const String done = 'Done';

  /// Close button.
  static const String close = 'Close';

  /// Relinking in progress.
  static const String relinking = 'Relinking your files…';

  /// Availability: missing.
  static const String statusMissing = 'Missing';

  /// Availability: access lost.
  static const String statusAccessLost = "Vwish can't open it any more";

  /// Availability: changed since it was added.
  static const String statusChanged = 'Changed since you added it';

  /// `Last seen in Camera Roll`.
  static String lastSeenIn(String folder) => 'Last seen in $folder';

  /// `Used in 3 clips`.
  static String usedIn(int clips) => switch (clips) {
        0 => 'Not used on the timeline',
        1 => 'Used in 1 clip',
        _ => 'Used in $clips clips',
      };

  /// The row's details line: kind, length and size when known.
  static String details({required MediaKind kind, TimeUs? duration, String? size}) {
    final parts = <String>[
      switch (kind) {
        MediaKind.video => 'Video',
        MediaKind.image || MediaKind.still => 'Photo',
        MediaKind.audio => 'Audio',
        MediaKind.recording => 'Recording',
        MediaKind.lut => 'LUT',
      },
      if (duration != null && duration > 0) clock(duration),
      if (size != null) size,
    ];
    return parts.join(' · ');
  }

  /// `0:42`, `1:05:09`.
  static String clock(TimeUs us) {
    final total = (us / 1000000).round();
    final h = total ~/ 3600, m = (total ~/ 60) % 60, s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  /// A path or name shortened to [max] characters with the middle replaced by an ellipsis.
  static String middleEllipsis(String text, {int max = 36}) {
    if (text.length <= max || max < 5) return text;
    final keep = max - 1;
    final head = (keep / 2).ceil();
    return '${text.substring(0, head)}…${text.substring(text.length - (keep - head))}';
  }

  // ---- Row actions ---------------------------------------------------------------------------

  /// Pick a replacement file.
  static const String locate = 'Locate…';

  /// Pick another file for a row that already has one.
  static const String locateAgain = 'Pick another…';

  /// Where to pick from: Photos on iOS, Gallery elsewhere.
  static String fromPhotos(TargetPlatform platform) => platform == TargetPlatform.iOS ? 'From Photos' : 'From Gallery';

  /// Where to pick from: the document picker.
  static const String fromFiles = 'From Files';

  /// Look for the other missing files next to the one just picked.
  static const String findInFolder = 'Find in same folder';

  /// `Found 3 of 4`.
  static String foundInFolder(int found, int missing) => 'Found $found of $missing in the same folder';

  /// Nothing else lives next to the picked file.
  static const String foundNothingInFolder = 'No other missing files are in that folder.';

  /// Accept the file that changed in place.
  static const String useUpdated = 'Use updated file';

  /// Menu: remove the clips that use a missing file.
  static const String removeClips = 'Remove clips that use it';

  /// Menu: replace a missing file with other media.
  static const String replaceWith = 'Replace with other media…';

  /// Menu button label.
  static const String moreActions = 'More actions';

  /// Confirm title: `Remove 3 clips?`.
  static String removeClipsTitle(int count) => count == 1 ? 'Remove 1 clip?' : 'Remove $count clips?';

  /// Confirm message.
  static const String removeClipsMessage = 'The clips that use this missing file are taken off the timeline. You can undo it.';

  /// Confirm button.
  static const String removeClipsConfirm = 'Remove clips';

  /// `Removed 3 clips`.
  static String removedClips(int count) => count == 1 ? 'Removed 1 clip' : 'Removed $count clips';

  /// `Replaced 3 clips`.
  static String replacedClips(int count) => count == 1 ? 'Replaced 1 clip' : 'Replaced $count clips';

  /// The row's staged file is dropped.
  static const String clearPick = 'Remove the picked file';

  /// Confirm the shorter/longer file.
  static const String useAnyway = 'Use it anyway';

  /// Reject the file.
  static const String pickOther = 'Pick another';

  // ---- Outcomes ------------------------------------------------------------------------------

  /// A file is being checked.
  static const String checkingFile = 'Checking the file…';

  /// The file matches.
  static const String matches = 'Matches · ready to relink';

  /// The file is the same content.
  static const String matchesExactly = 'Same file · ready to relink';

  /// The file has been relinked.
  static const String relinked = 'Relinked';

  /// The file differs in length: the question.
  static String durationQuestion(TimeUs expected, TimeUs actual) {
    final e = clock(expected), a = clock(actual);
    return actual < expected
        ? 'This file is $a but the original was $e. Clips past $a will be shortened. Use it anyway?'
        : 'This file is $a but the original was $e. Your clips keep their length. Use it anyway?';
  }

  /// The user accepted the length difference.
  static const String durationAccepted = 'Different length · will be used anyway';

  /// A file of the wrong kind.
  static String differentKind(MediaKind expected) => switch (expected) {
        MediaKind.video => 'Pick a video file to replace a video.',
        MediaKind.image || MediaKind.still => 'Pick a photo to replace a photo.',
        MediaKind.audio || MediaKind.recording => 'Pick an audio file to replace audio.',
        MediaKind.lut => 'Pick a LUT file (.cube) to replace a LUT.',
      };

  /// An unsupported or unreadable file: the compatibility reason.
  static String unsupported(String reason) => switch (reason) {
        'dimensionsDiffer' => 'This file has a different picture size than the original. Pick the file that was used originally.',
        'ambiguous' => 'Several files could replace this one. Pick it yourself.',
        'noMatch' || 'unassigned' => 'No missing file matches this one.',
        'io' => "Couldn't read this file. Pick it again.",
        _ => ImportStrings.reason(reason),
      };

  /// Applying the relinks failed.
  static const String applyFailedTitle = "Couldn't relink these files";

  /// Next step after a failed relink.
  static const String applyFailedDetail = 'Nothing was changed. Pick the files again, then try again.';

  /// The primary button of the sheet: `Relink 3 files`.
  static String relinkFiles(int count) => count == 1 ? 'Relink 1 file' : 'Relink $count files';

  /// Toast after relinking.
  static String relinkedToast(int count) => count == 1 ? 'Relinked 1 file' : 'Relinked $count files';

  /// Toast when some clips were shortened by the relink.
  static const String clipsShortened = 'Some clips were shortened to fit the new files.';

  // ---- Relink several ------------------------------------------------------------------------

  /// The button that picks many files at once.
  static const String relinkSeveral = 'Relink several';

  /// Why it exists.
  static const String relinkSeveralHint = 'Pick all the files at once and Vwish matches them to what is missing.';

  /// Matching in progress.
  static const String matching = 'Matching your files…';

  /// Confirm view title.
  static const String confirmTitle = 'Confirm matches';

  /// `Matched 8 of 10 files`.
  static String matched(int matched, int picked) => 'Matched $matched of $picked picked files';

  /// Header of the matched list.
  static const String matchedHeader = 'Will be relinked';

  /// Header of the picks that matched nothing.
  static const String unassignedPicksHeader = 'Not matched';

  /// A pick that matched nothing.
  static const String notMatched = "Didn't match a missing file";

  /// Header of the assets that stay missing.
  static const String stillMissingHeader = 'Still missing';

  /// Matches and a missing name.
  static String replacesName(String name) => 'Replaces $name';

  /// Confirm button: `Relink 8 files`.
  static String confirmRelink(int count) => relinkFiles(count);

  /// Nothing was matched at all.
  static const String nothingMatched = "None of the picked files matched a missing file. Pick the original files, or locate them one at a time.";

  /// Back from the confirm view.
  static const String back = 'Back';

  /// Spoken label of a match's include switch.
  static String includeMatch(String pick, String asset) => 'Relink $asset with $pick';

  // ---- Picker --------------------------------------------------------------------------------

  /// The picker could not be shown.
  static const String pickerFailed = "Couldn't open the picker. Check that Vwish may access your media in Settings, then try again.";

  // ---- Recovery dialog (editor) --------------------------------------------------------------

  /// Dialog title.
  static const String recoveryTitle = 'Restore unsaved changes?';

  /// Dialog message: `Vwish closed before your last changes to "Goa trip" were saved (changes from 14:32).`
  static String recoveryMessage(String project, String when) =>
      'Vwish closed before your last changes to "$project" were saved (changes from $when).';

  /// The dialog's primary action.
  static const String restore = 'Restore';

  /// The dialog's secondary action.
  static const String openLastSaved = 'Open last saved';

  /// What "Open last saved" leaves behind.
  static const String openLastSavedNote = 'You can still restore them from Projects until you save.';

  /// Restoring failed.
  static const String restoreFailed = "Couldn't restore the unsaved changes. The last saved version is unchanged.";

  /// Restored in the editor.
  static const String restored = 'Unsaved changes restored';

  // ---- Recovery banner (Projects) ------------------------------------------------------------

  /// Banner title for one project.
  static const String bannerTitleOne = 'Unsaved changes found';

  /// Banner title for several projects.
  static String bannerTitleMany(int count) => '$count projects have unsaved changes';

  /// Banner message for one project.
  static String bannerOne(String project, String when) => 'Vwish closed before "$project" was saved. Changes from $when.';

  /// Banner message for several projects.
  static const String bannerMany = 'Vwish closed before these projects were saved.';

  /// One row: the changes' time.
  static String changesFrom(String when) => 'Changes from $when';

  /// The banner's restore button.
  static const String bannerRestore = 'Restore';

  /// The banner's discard button.
  static const String bannerDiscard = 'Discard';

  /// Spoken label of a row's restore button.
  static String restoreSemantics(String project) => 'Restore unsaved changes to $project';

  /// Spoken label of a row's discard button.
  static String discardSemantics(String project) => 'Discard unsaved changes to $project';

  /// Discard confirmation title.
  static String discardTitle(String project) => 'Discard changes to "$project"?';

  /// Discard confirmation message.
  static const String discardMessage = 'The unsaved changes are deleted. The last saved version of the project is kept.';

  /// Discard confirmation button.
  static const String discardConfirm = 'Discard changes';

  /// Toast after a restore from the banner.
  static String restoredProject(String project) => 'Restored "$project". Open it from your projects.';

  /// Toast after a discard.
  static String discardedProject(String project) => 'Discarded the unsaved changes to "$project"';

  /// A recovery action failed.
  static const String recoveryActionFailed = "That didn't work. Nothing was changed. Try again.";

  /// `today at 14:32` / `11 Oct, 14:32`.
  static String when(DateTime savedAt, DateTime clock) {
    final saved = savedAt.toLocal(), now = clock.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(saved.hour)}:${two(saved.minute)}';
    final sameDay = saved.year == now.year && saved.month == now.month && saved.day == now.day;
    if (sameDay) return time;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${saved.day} ${months[saved.month - 1]}, $time';
  }

  // ---- Read-only (newer schema) --------------------------------------------------------------

  /// Banner: a project saved by a newer app opened read-only (D-12).
  static const String readOnlyBannerTitle = 'Read-only: made with a newer Vwish';

  /// Banner detail.
  static const String readOnlyBannerDetail = 'You can look at it and export it. Update Vwish to save changes.';

  /// The banner's button.
  static const String updateVwish = 'Update Vwish';

  // ---- Damaged project (ux.md §13.4) ---------------------------------------------------------

  /// Banner: the newest copy was damaged and the last good one opened.
  static const String backupRestoredTitle = 'Opened the last good version';

  /// Banner detail.
  static const String backupRestoredDetail = "This project's newest copy was damaged. Changes from your last session may be missing.";

  /// The banner's dismiss button.
  static const String dismissNotice = 'Dismiss';
}
