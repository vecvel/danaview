// OWNER: UX-35
//
// Copy of freeze frame, reverse, replace media, the clip info panel and the background tasks sheet
// (ux.md §10.15, §16.2, ARCH §19): plain, specific, with a next step where one exists. Task labels
// never name files ("Reversing a clip", not "Reversing beach.mp4").

import 'package:danaview_editor_core/model.dart' show MediaKind, MediaOwnership;

import '../../editor/state/editor_state.dart' show EditorTaskKind;

/// Copy of the clip actions, the clip info panel and the tasks sheet (ux.md §10.15).
abstract final class ClipStrings {
  // ---- Action reasons -------------------------------------------------------------------------

  /// The project is opening, closing or read-only.
  static const String notEditable = 'Editing is not available right now.';

  /// Nothing (or not a clip) is selected.
  static const String selectClip = 'Select a clip first.';

  /// Reverse and freeze need a video clip.
  static const String selectVideo = 'Select a video clip first.';

  /// The clip's track is locked.
  static const String trackLocked = 'This track is locked. Unlock it to change the clip.';

  /// Freeze frame needs the playhead over the clip.
  static const String playheadOutside = 'Move the playhead over the clip to freeze that frame.';

  /// Replace is not offered for read-only projects (imports copy files).
  static const String readOnly = 'This project is open read-only, so media can\'t be added.';

  /// The clip's media is missing.
  static const String mediaMissing = 'This clip\'s media is missing. Relink it first.';

  // ---- Freeze frame ---------------------------------------------------------------------------

  /// Title of the freeze frame sheet.
  static const String freezeTitle = 'Freeze frame';

  /// Explanation in the freeze frame sheet.
  static const String freezeBody = 'Splits the clip at the playhead and holds this frame as a still.';

  /// Label of the duration field.
  static const String freezeDuration = 'Duration';

  /// Unit of the duration field.
  static const String secondsUnit = 's';

  /// Confirm button of the freeze sheet.
  static const String freezeConfirm = 'Freeze';

  /// Cancel button of sheets.
  static const String cancel = 'Cancel';

  /// Announced when the freeze frame was inserted.
  static const String freezeInserted = 'Freeze frame added. The still is being made.';

  /// Announced when reverse was turned on.
  static const String reverseOn = 'Reversing the clip. It switches over when ready.';

  /// Announced when reverse was turned off.
  static const String reverseOff = 'The clip plays forward again.';

  // ---- Replace --------------------------------------------------------------------------------

  /// Title of the import sheet of a replacement.
  static const String replaceImportTitle = 'Replace media';

  /// The picker failed.
  static const String pickerFailed = 'Couldn\'t open the picker. Try again.';

  /// Nothing usable was imported.
  static const String replaceNothing = 'Nothing was replaced.';

  /// Announced after a replacement.
  static const String replaced = 'Media replaced.';

  /// The trim notice after a replacement with shorter media.
  static String replaceTrimmed(MediaKind kind, String length) =>
      'The new ${_kindWord(kind)} is shorter, so the clip was trimmed to $length.';

  static String _kindWord(MediaKind kind) => switch (kind) {
        MediaKind.audio || MediaKind.recording => 'audio',
        MediaKind.image || MediaKind.still => 'image',
        _ => 'video',
      };

  // ---- Clip info ------------------------------------------------------------------------------

  /// The clip was deleted while the panel was open.
  static const String clipGone = 'This clip is no longer on the timeline.';

  /// Row labels.
  static const String infoName = 'Name';

  /// Row label: the source file's display name.
  static const String infoSource = 'Source';

  /// Row label: clip length.
  static const String infoDuration = 'Duration';

  /// Row label: source in point.
  static const String infoSourceIn = 'Source in';

  /// Row label: source out point.
  static const String infoSourceOut = 'Source out';

  /// Row label: speed.
  static const String infoSpeed = 'Speed';

  /// Row label: direction.
  static const String infoDirection = 'Direction';

  /// Row label: resolution.
  static const String infoResolution = 'Resolution';

  /// Row label: frame rate.
  static const String infoFrameRate = 'Frame rate';

  /// Row label: codec.
  static const String infoCodec = 'Codec';

  /// Row label: audio.
  static const String infoAudio = 'Audio';

  /// Row label: file size.
  static const String infoSize = 'Size';

  /// Row label: where the file is stored.
  static const String infoLocation = 'Stored';

  /// Row label: readiness.
  static const String infoStatus = 'Status';

  /// Direction values.
  static const String forward = 'Forward';

  /// Direction: reversed.
  static const String reversed = 'Reversed';

  /// Speed value for a speed curve.
  static const String speedCurve = 'Speed curve';

  /// Speed value of a constant speed.
  static String speedValue(double rate) => '${_trim(rate)}×';

  /// Frame rate value.
  static String fps(double fps) => '${_trim(fps)} fps';

  /// Audio value: no audio.
  static const String noAudio = 'No audio';

  /// Audio value: channels and sample rate.
  static String audioValue({String? codec, int? channels, int? sampleRate}) {
    final parts = <String>[
      if (codec != null && codec.isNotEmpty) codec.toUpperCase(),
      if (channels != null) channels == 1 ? 'Mono' : (channels == 2 ? 'Stereo' : '$channels channels'),
      if (sampleRate != null && sampleRate > 0) '${_trim(sampleRate / 1000)} kHz',
    ];
    return parts.isEmpty ? 'Yes' : parts.join(' · ');
  }

  /// Where an asset's file lives.
  static String location(MediaOwnership ownership) => switch (ownership) {
        MediaOwnership.external => 'Original file (not copied)',
        MediaOwnership.managedCopy => 'Copy kept by Danaview',
        MediaOwnership.projectOwned => 'Made in this project',
      };

  /// Status values.
  static const String statusReady = 'Ready';

  /// Status: the media file is offline.
  static const String statusMissing = 'Missing';

  /// Status: a reverse is running ("Reversing 45%").
  static String reversing(double? fraction) => fraction == null ? 'Reversing…' : 'Reversing ${(fraction * 100).round()}%';

  /// Status: a freeze still is being made.
  static String freezing(double? fraction) =>
      fraction == null ? 'Making the still…' : 'Making the still ${(fraction * 100).round()}%';

  /// Status: the reversed version failed.
  static const String reverseFailed = 'Couldn\'t reverse this clip.';

  /// Status: the still failed.
  static const String freezeFailed = 'Couldn\'t make the freeze frame.';

  /// Status: the job was cancelled.
  static const String cancelledStatus = 'Cancelled';

  /// Button: cancel the reverse.
  static const String cancelReverse = 'Cancel reverse';

  /// Button: cancel making the still.
  static const String cancelFreeze = 'Cancel freeze frame';

  /// Button: try a failed job again.
  static const String retry = 'Try again';

  /// History label of turning reverse off after a cancel.
  static const String cancelReverseLabel = 'Cancel reverse';

  /// History label of removing a cancelled freeze still.
  static const String cancelFreezeLabel = 'Cancel freeze frame';

  // ---- Tasks ----------------------------------------------------------------------------------

  /// Title of the tasks sheet.
  static const String tasksTitle = 'Background tasks';

  /// The empty tasks sheet.
  static const String tasksEmpty = 'Nothing is running in the background.';

  /// Explanation under the list.
  static const String tasksHint = 'Tasks keep running while you edit. Export waits for reversed clips and freeze frames.';

  /// Task label per kind (no file names).
  static String taskLabel(EditorTaskKind kind) => switch (kind) {
        EditorTaskKind.proxy => 'Optimizing a clip for editing',
        EditorTaskKind.reverse => 'Reversing a clip',
        EditorTaskKind.freeze => 'Making a freeze frame',
        EditorTaskKind.waveform => 'Drawing an audio waveform',
        EditorTaskKind.captions => 'Making captions',
        EditorTaskKind.download => 'Downloading the speech model',
      };

  /// Subtitle of a running task.
  static String taskProgress(double? fraction) => fraction == null ? 'Working…' : '${(fraction * 100).round()}% done';

  /// Subtitle of a failed task.
  static const String taskFailed = 'Failed. Try again, or dismiss it.';

  /// Button: cancel a task.
  static const String cancelTask = 'Cancel';

  /// Button: dismiss a failed task.
  static const String dismiss = 'Dismiss';

  /// Semantics of a task row.
  static String taskSemantics(String label, double? fraction, {required bool failed}) =>
      failed ? '$label, failed' : (fraction == null ? '$label, in progress' : '$label, ${(fraction * 100).round()} percent');

  /// Announced when a task was cancelled.
  static const String taskCancelled = 'Task cancelled.';

  static String _trim(num v) {
    final s = v.toStringAsFixed(2);
    return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  }
}
