// OWNER: UX-32
//
// Copy of the SRT/VTT import and export flows (ux.md §10.9): plain, specific and with a next step
// where one exists (ARCH §19). Every icon-only control has a semantics label here.

import 'package:danaview_editor_core/formats.dart' show SubtitleIssueKind, TextEncoding;

/// Copy of the subtitle import and export flows (ux.md §10.9).
abstract final class SubtitleIoStrings {
  // ---- Import: reading -------------------------------------------------------------------------

  /// Title of the import result sheet.
  static const String importTitle = 'Import captions';

  /// "Imported 312 captions from movie.srt" (the sheet's headline before importing).
  static String found(int n, String fileName) => n == 1 ? 'Found 1 caption in $fileName' : 'Found $n captions in $fileName';

  /// Toast after an import ("Imported 312 captions from movie.srt").
  static String imported(int n, String fileName) =>
      n == 1 ? 'Imported 1 caption from $fileName' : 'Imported $n captions from $fileName';

  /// The file had no caption that could be imported.
  static String nothingFound(String fileName) => 'No captions could be read from $fileName.';

  /// The next step when nothing could be read.
  static const String nothingNextStep = 'Check that it is an SRT or VTT file, fix the line below in a text editor and try again.';

  /// The file could not be opened at all.
  static const String cannotOpen = "The file couldn't be opened. Save it to Files on this device and try again.";

  /// The picker failed.
  static const String pickerFailed = "The file picker couldn't open. Try again.";

  /// The file is larger than a subtitle file can be.
  static String tooLarge(int maxMb) => 'This file is larger than $maxMb MB, so it is probably not a subtitle file.';

  /// The file is not .srt or .vtt.
  static const String notSubtitle = 'Choose an .srt or .vtt file.';

  /// Reading failed unexpectedly.
  static const String readFailed = "The file couldn't be read. Try again.";

  /// Format line ("SubRip (SRT)").
  static const String formatSrt = 'SubRip (SRT)';

  /// Format line ("WebVTT").
  static const String formatVtt = 'WebVTT';

  /// The encoding the file was read with, when it is worth telling; null for UTF-8.
  static String? encodingNote(TextEncoding e) => switch (e) {
        TextEncoding.utf8 => null,
        TextEncoding.utf16le || TextEncoding.utf16be => 'Read as UTF-16 text.',
        TextEncoding.windows1252 =>
          "The file isn't UTF-8, so it was read as Western (Windows-1252). If letters look wrong, save it as UTF-8 and import again.",
        TextEncoding.latin1 =>
          "The file isn't UTF-8, so it was read as Latin-1. If letters look wrong, save it as UTF-8 and import again.",
      };

  /// Whether [e] is a fallback the user should check (shown as a warning).
  static bool isFallback(TextEncoding e) => e == TextEncoding.windows1252 || e == TextEncoding.latin1;

  /// Summary of stripped formatting ("Removed 12 formatting tags. Italic and bold were kept.").
  static String strippedTags(int n) => n == 1
      ? 'Removed 1 formatting tag (colour, font or position). Italic and bold were kept.'
      : 'Removed $n formatting tags (colour, font or position). Italic and bold were kept.';

  /// Summary of ignored cue settings.
  static String ignoredSettings(int n) =>
      n == 1 ? 'Ignored the placement settings of 1 caption.' : 'Ignored the placement settings of $n captions.';

  /// Heading of the problems list ("3 lines were skipped").
  static String problemsHeading(int n) => n == 1 ? '1 part of the file was skipped' : '$n parts of the file were skipped';

  /// "Line 88: the timing isn't valid".
  static String issue(int line, SubtitleIssueKind kind) => 'Line $line: ${issueDetail(kind)}';

  /// What went wrong, in words.
  static String issueDetail(SubtitleIssueKind kind) => switch (kind) {
        SubtitleIssueKind.missingHeader => 'a VTT file must start with WEBVTT',
        SubtitleIssueKind.invalidTiming => "the timing isn't valid",
        SubtitleIssueKind.endBeforeStart => 'the caption ends before it starts',
        SubtitleIssueKind.emptyText => 'the caption has no text',
        SubtitleIssueKind.strayText => 'text outside any caption',
        SubtitleIssueKind.noTiming => 'the caption has no timing line',
      };

  /// "and 12 more".
  static String moreProblems(int n) => 'and $n more';

  // ---- Import: where -------------------------------------------------------------------------

  /// Heading of the destination choice.
  static const String destination = 'Put the captions on';

  /// A new subtitle track (default).
  static const String newTrack = 'New track';

  /// Replace an existing track's captions.
  static const String replaceTrack = 'Replace track';

  /// Heading of the track list when replacing.
  static const String replaceWhich = 'Track to replace';

  /// What replacing does ("Replaces the 4 captions on English. Style and position stay.").
  static String replaceNote(int n, String track) => n == 1
      ? 'Replaces the 1 caption on $track. Its style, position and language stay.'
      : 'Replaces the $n captions on $track. Its style, position and language stay.';

  /// Replace is not possible: no unlocked subtitle track.
  static const String noReplaceTarget = 'There is no unlocked subtitle track to replace.';

  /// Name and language of the new track ("A new track named movie (en)").
  static String newTrackNote(String name, String? language) =>
      language == null ? 'Adds a new subtitle track named $name.' : 'Adds a new subtitle track named $name ($language).';

  /// Imports.
  static const String importAction = 'Import';

  /// Closes the sheet without importing.
  static const String cancel = 'Cancel';

  /// Closes a sheet that has nothing to import.
  static const String close = 'Close';

  /// "Locked" suffix of a locked track row.
  static const String locked = 'Locked';

  /// The number of captions on a track ("312 captions").
  static String cueCount(int n) => n == 1 ? '1 caption' : '$n captions';

  /// Overlapping captions went to extra tracks.
  static String spilled(int n) =>
      n == 1 ? '1 overlapping caption went to an extra track.' : '$n overlapping captions went to extra tracks.';

  /// Captions left out on import.
  static String skipped(int n) => n == 1 ? '1 empty caption was left out.' : '$n empty captions were left out.';

  /// The project cannot be edited right now.
  static const String notEditable = 'Captions can be imported once the project is open';

  /// Import is not possible in a read-only project.
  static const String readOnly = 'This project is open read-only';

  // ---- Export --------------------------------------------------------------------------------

  /// Title of the export sheet.
  static const String exportTitle = 'Export captions';

  /// Heading of the track choice.
  static const String exportTrack = 'Track';

  /// Heading of the format choice.
  static const String exportFormat = 'Format';

  /// SRT segment.
  static const String srt = 'SRT';

  /// VTT segment.
  static const String vtt = 'VTT';

  /// What SRT is for.
  static const String srtHint = 'SRT works almost everywhere: players, YouTube and most editors.';

  /// What VTT is for.
  static const String vttHint = 'VTT is the format web players use.';

  /// Heading of the file name preview.
  static const String fileName = 'File name';

  /// Saves through the system's Files / document picker.
  static const String saveToFiles = 'Save to Files';

  /// Opens the share sheet.
  static const String share = 'Share';

  /// Marks generated captions in the track list.
  static const String generated = 'Auto captions';

  /// Toast after Save to Files.
  static String saved(String name) => 'Saved $name';

  /// Toast after sharing.
  static String shared(String name) => 'Shared $name';

  /// Writing the temporary file failed.
  static const String writeFailed = "The caption file couldn't be written. Free up some space and try again.";

  /// The handoff failed.
  static const String handoffFailed = "The caption file couldn't be handed over. Try again.";

  /// Saving was not allowed.
  static const String handoffDenied = "Danaview isn't allowed to save there. Choose another place.";

  /// Export is disabled: no captions in the project.
  static const String nothingToExport = 'Add captions first: there is nothing to export yet';

  /// Export is disabled while the project opens.
  static const String exportNotReady = 'Captions can be exported once the project is open';
}
