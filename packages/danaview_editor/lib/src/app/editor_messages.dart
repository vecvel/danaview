// OWNER: UX-08
//
// Plain copy for every EditorFailure subtype and every EditRejection (ARCH §19, ux.md §18): what
// happened, then what to do next. Exhaustive switches, so a new subtype fails to compile until it
// has copy (and test/state/editor_messages_test.dart checks every case). Style follows the
// player's `playerErrorMessage`: short, specific, no codes or paths in the text; "Copy details"
// uses `EditorFailure.code` instead.
//
// The core rejection `MediaUnavailable` and the EditorFailure `MediaUnavailable` share a name, so
// core ops is imported with the `ops` prefix here.

import 'package:flutter/foundation.dart';
import 'package:danaview_editor_core/ops.dart' as ops;
import 'package:danaview_editor_core/store.dart' show StoreFailureKind;
import 'package:danaview_transcription/danaview_transcription.dart' show ModelDownloadFailureKind;

import '../editor/state/editor_state.dart';

/// The next step a message offers as a button (the UI wires each to its action).
enum EditorMessageAction {
  /// Unlock the track.
  unlock,

  /// Open the relink flow.
  relink,

  /// Retry the save.
  retry,

  /// Try the action again.
  tryAgain,

  /// Restart the preview session.
  restartPreview,

  /// Open the system settings for the app.
  openSettings,

  /// Open Settings › Storage.
  freeUpSpace,

  /// Export again with H.264.
  exportH264,

  /// Export again at a lower resolution.
  lowerResolution,

  /// Update the app (store page).
  updateApp,

  /// Leave for the Projects screen.
  goToProjects,
}

/// A user-facing message: what happened and what to do next (ARCH §19).
@immutable
class EditorMessage {
  /// Creates a message.
  const EditorMessage(this.title, {this.detail, this.action});

  /// One line: what happened.
  final String title;

  /// The next step, or null when the title already says it.
  final String? detail;

  /// The button for the next step, or null.
  final EditorMessageAction? action;

  @override
  bool operator ==(Object other) => other is EditorMessage && other.title == title && other.detail == detail && other.action == action;

  @override
  int get hashCode => Object.hash(title, detail, action);

  @override
  String toString() => 'EditorMessage("$title"${detail == null ? '' : ', "$detail"'}${action == null ? '' : ', ${action!.name}'})';
}

/// The message for [failure] (ux.md §18 rule 2).
EditorMessage editorFailureMessage(EditorFailure failure) => EditorMessages.forFailure(failure);

/// The message for [rejection] (ux.md §18 rule 2).
EditorMessage editRejectionMessage(ops.EditRejection rejection) => EditorMessages.forRejection(rejection);

/// Copy for failures, rejections and editor notices (ARCH §19).
abstract final class EditorMessages {
  // ---- Fixed messages ----

  /// After ⌘S / Project › Save.
  static const EditorMessage saved = EditorMessage('Saved');

  /// A project saved by a newer app opened read-only (D-12).
  static const EditorMessage openedReadOnly = EditorMessage(
    'Opened read-only',
    detail: 'This project was made with a newer version of Danaview. You can view and export it. Update Danaview to save changes.',
    action: EditorMessageAction.updateApp,
  );

  /// The project was migrated from an older format on open (one-time).
  static const EditorMessage migrated = EditorMessage(
    'Project updated',
    detail: 'This project now works with this version of Danaview. A copy of the old version is kept.',
  );

  /// Opening repaired parts of the project.
  static const EditorMessage repaired = EditorMessage(
    'Some parts of this project were repaired',
    detail: 'Check your edits before you export.',
  );

  /// "Undid Split clip" (touch only, ux.md §14.1).
  static EditorMessage undid(String label) => EditorMessage('Undid $label');

  /// "Redid Split clip".
  static EditorMessage redid(String label) => EditorMessage('Redid $label');

  // ---- Failures ----

  /// The message for [failure].
  static EditorMessage forFailure(EditorFailure failure) => switch (failure) {
        ProjectNotFound() => const EditorMessage(
            "This project isn't available",
            detail: 'It may have been deleted.',
            action: EditorMessageAction.goToProjects,
          ),
        ProjectNeedsNewerApp() => const EditorMessage(
            'This project was made with a newer version of Danaview',
            detail: 'Update Danaview to open it. The project is unchanged.',
            action: EditorMessageAction.updateApp,
          ),
        ProjectCorrupt() => const EditorMessage(
            "This project couldn't be opened",
            detail: 'Its file is damaged and no backup could be read. Your original videos are not affected.',
            action: EditorMessageAction.goToProjects,
          ),
        SaveFailed(:final kind) => _saveFailed(kind),
        MediaUnavailable() => const EditorMessage(
            'Some media is missing',
            detail: 'Relink the missing files to see them again.',
            action: EditorMessageAction.relink,
          ),
        MediaUnsupported(:final reason) => EditorMessage(
            "This media can't be edited on this device",
            detail: reason == 'notSupportedOnDevice'
                ? 'This device is missing a feature the editor needs for it. Try a different file.'
                : 'MP4, MOV and M4V videos work best.',
          ),
        ImportFailed(:final reason) => _importFailed(reason),
        PreviewFailed(:final recoverable) => recoverable
            ? const EditorMessage(
                'Preview stopped',
                detail: 'Your edits are safe. Restart the preview to keep watching them.',
                action: EditorMessageAction.restartPreview,
              )
            : const EditorMessage(
                'Preview stopped',
                detail: 'Your edits are safe. Close the project and open it again.',
                action: EditorMessageAction.goToProjects,
              ),
        ExportFailed(:final kind) => _exportFailed(kind),
        PermissionDenied(:final permission) => switch (permission) {
            EditorPermission.microphone => const EditorMessage(
                'Microphone access is off',
                detail: 'Turn it on in Settings to record a voiceover.',
                action: EditorMessageAction.openSettings,
              ),
            EditorPermission.photosAdd => const EditorMessage(
                "Danaview can't add videos to Photos",
                detail: 'Allow it in Settings, or save the export to Files.',
                action: EditorMessageAction.openSettings,
              ),
            EditorPermission.notifications => const EditorMessage(
                'Notifications are off',
                detail: 'Turn them on in Settings to see export progress while Danaview is in the background.',
                action: EditorMessageAction.openSettings,
              ),
          },
        ParseFailed(:final format, :final line) => _parseFailed(format, line),
        ModelDownloadFailed(:final kind) => _downloadFailed(kind),
        TranscriptionFailed(:final reason, :final retryable) => _transcriptionFailed(reason, retryable),
        UnknownFailure() => const EditorMessage(
            'Something went wrong',
            detail: 'Your edits are safe. Try again.',
            action: EditorMessageAction.tryAgain,
          ),
      };

  static EditorMessage _saveFailed(StoreFailureKind kind) => switch (kind) {
        StoreFailureKind.diskFull => const EditorMessage(
            "Couldn't save changes: your device is full",
            detail: 'Your changes are kept until you free up space.',
            action: EditorMessageAction.freeUpSpace,
          ),
        StoreFailureKind.permissionDenied => const EditorMessage(
            "Couldn't save changes: Danaview can't write to its storage",
            detail: 'Your changes are kept. Restart Danaview and try again.',
            action: EditorMessageAction.retry,
          ),
        StoreFailureKind.notFound => const EditorMessage(
            "Couldn't save changes: the project's folder is missing",
            detail: 'Your changes are kept. Try saving again.',
            action: EditorMessageAction.retry,
          ),
        StoreFailureKind.corrupt || StoreFailureKind.io => const EditorMessage(
            "Couldn't save changes",
            detail: 'Your changes are kept. Try saving again.',
            action: EditorMessageAction.retry,
          ),
        StoreFailureKind.newerSchema => const EditorMessage(
            'This project is read-only',
            detail: 'It was made with a newer version of Danaview. Update Danaview to save changes.',
            action: EditorMessageAction.updateApp,
          ),
        StoreFailureKind.busy => const EditorMessage(
            "Couldn't save changes yet",
            detail: 'Another save is still running. Try again in a moment.',
            action: EditorMessageAction.retry,
          ),
      };

  static EditorMessage _importFailed(String reason) => switch (reason) {
        'unsupported' || 'containerUnsupportedIos' || 'codecUnsupported' => const EditorMessage(
            "This file can't be edited on this device",
            detail: 'MP4, MOV and M4V videos work best.',
          ),
        'diskFull' => const EditorMessage(
            'Not enough space to add this file',
            detail: 'Free up space and try again.',
            action: EditorMessageAction.freeUpSpace,
          ),
        'notFound' => const EditorMessage(
            "This file couldn't be found",
            detail: 'It may have been moved or deleted.',
          ),
        'accessDenied' || 'notPersistable' => const EditorMessage(
            "Danaview can't keep access to this file",
            detail: 'Pick it again from Files or Photos.',
          ),
        'empty' => const EditorMessage(
            'This file is empty',
            detail: 'Pick a different file.',
          ),
        'lutInvalid' => const EditorMessage(
            "This LUT couldn't be read",
            detail: 'Use a .cube file up to 65×65×65.',
          ),
        'cancelled' => const EditorMessage(
            'Adding media was cancelled',
            detail: "Add it again when you're ready.",
          ),
        _ => const EditorMessage(
            "This file couldn't be added",
            detail: 'Try again, or pick a different file.',
            action: EditorMessageAction.tryAgain,
          ),
      };

  static EditorMessage _exportFailed(ExportFailureKind kind) => switch (kind) {
        ExportFailureKind.encoderUnavailable => const EditorMessage(
            "This device couldn't encode H.265 right now",
            detail: 'Export with H.264 instead.',
            action: EditorMessageAction.exportH264,
          ),
        ExportFailureKind.encoderSizeLimit => const EditorMessage(
            "This size is too large for this device's encoder",
            detail: 'Lower the resolution and export again.',
            action: EditorMessageAction.lowerResolution,
          ),
        ExportFailureKind.diskFull => const EditorMessage(
            'Not enough space to export',
            detail: 'Free up space and try again.',
            action: EditorMessageAction.freeUpSpace,
          ),
        ExportFailureKind.interrupted => const EditorMessage(
            'The export was interrupted',
            detail: 'Try again and keep Danaview open until it finishes.',
            action: EditorMessageAction.tryAgain,
          ),
        ExportFailureKind.destinationDenied => const EditorMessage(
            "Danaview couldn't save the video there",
            detail: 'Allow access in Settings, or choose a different place.',
            action: EditorMessageAction.openSettings,
          ),
        ExportFailureKind.unknown => const EditorMessage(
            "The export didn't finish",
            detail: 'Try again. If it keeps failing, lower the resolution.',
            action: EditorMessageAction.tryAgain,
          ),
      };

  static EditorMessage _parseFailed(EditorParseFormat format, int? line) {
    final at = line == null ? '' : ' (line $line)';
    return switch (format) {
      EditorParseFormat.srt => EditorMessage(
          "This subtitle file couldn't be read$at",
          detail: "Check that it's a valid SRT file and try again.",
        ),
      EditorParseFormat.vtt => EditorMessage(
          "This subtitle file couldn't be read$at",
          detail: "Check that it's a valid WebVTT file and try again.",
        ),
      EditorParseFormat.cube => EditorMessage(
          "This LUT couldn't be read$at",
          detail: 'Use a valid .cube file up to 65×65×65.',
        ),
    };
  }

  static EditorMessage _downloadFailed(ModelDownloadFailureKind kind) => switch (kind) {
        ModelDownloadFailureKind.offline => const EditorMessage(
            "You're offline",
            detail: 'Connect to the internet and try again. Downloaded data is kept.',
            action: EditorMessageAction.tryAgain,
          ),
        ModelDownloadFailureKind.timeout || ModelDownloadFailureKind.server || ModelDownloadFailureKind.interrupted => const EditorMessage(
            'The download stopped',
            detail: 'Check your connection and try again. Downloaded data is kept.',
            action: EditorMessageAction.tryAgain,
          ),
        ModelDownloadFailureKind.secureConnection => const EditorMessage(
            "A secure connection couldn't be made",
            detail: 'Some public Wi-Fi networks block downloads. Try another network.',
            action: EditorMessageAction.tryAgain,
          ),
        ModelDownloadFailureKind.diskFull => const EditorMessage(
            'Not enough space for the speech model',
            detail: 'Free up space and try again.',
            action: EditorMessageAction.freeUpSpace,
          ),
        ModelDownloadFailureKind.checksumMismatch || ModelDownloadFailureKind.sizeMismatch => const EditorMessage(
            'The download was damaged',
            detail: 'Try again. Danaview downloads the model again from the start.',
            action: EditorMessageAction.tryAgain,
          ),
        ModelDownloadFailureKind.cancelled => const EditorMessage(
            'Download cancelled',
            detail: "Start it again when you're ready.",
          ),
        ModelDownloadFailureKind.consentMismatch => const EditorMessage(
            'The speech model changed since you agreed',
            detail: 'Review the download details and try again.',
            action: EditorMessageAction.tryAgain,
          ),
      };

  static EditorMessage _transcriptionFailed(String reason, bool retryable) => switch (reason) {
        'noSpeech' => const EditorMessage(
            'No speech was found',
            detail: 'Try a clip with clear speech, or add captions yourself.',
          ),
        'noAudio' => const EditorMessage(
            'This clip has no audio',
            detail: 'Pick a clip with sound.',
          ),
        'insufficientMemory' => const EditorMessage(
            'Not enough memory for this model',
            detail: 'Close other apps, or choose a faster model.',
            action: EditorMessageAction.tryAgain,
          ),
        'unsupportedDevice' => const EditorMessage(
            "Auto captions aren't available on this device",
            detail: 'Add captions yourself instead.',
          ),
        'mediaOffline' => const EditorMessage(
            "The clip's media is missing",
            detail: 'Relink it, then try again.',
            action: EditorMessageAction.relink,
          ),
        'diskFull' => const EditorMessage(
            'Not enough space for Auto captions',
            detail: 'Free up space and try again.',
            action: EditorMessageAction.freeUpSpace,
          ),
        _ => retryable
            ? const EditorMessage("Auto captions didn't finish", detail: 'Try again.', action: EditorMessageAction.tryAgain)
            : const EditorMessage("Auto captions didn't finish", detail: 'Add captions yourself, or try a different clip.'),
      };

  // ---- Rejections (info toasts, ARCH §19 rule 4) ----

  /// The message for a refused command.
  static EditorMessage forRejection(ops.EditRejection rejection) => switch (rejection) {
        ops.TrackLocked() => const EditorMessage(
            'This track is locked',
            detail: 'Unlock it to edit its clips.',
            action: EditorMessageAction.unlock,
          ),
        ops.ItemNotFound() => const EditorMessage(
            "That item isn't in the project anymore",
            detail: 'Select another item and try again.',
          ),
        ops.WouldOverlap() => const EditorMessage(
            "There's no room there",
            detail: 'Move it to an empty spot, or turn on ripple editing.',
          ),
        ops.OutOfSourceRange() => const EditorMessage(
            "The clip can't go past the end of its media",
            detail: 'Trim it within the length of the original file.',
          ),
        ops.BelowMinDuration() => const EditorMessage(
            "Clips can't be shorter than one frame",
            detail: 'Make it a little longer.',
          ),
        ops.NothingAtTime() => const EditorMessage(
            "There's no clip at the playhead",
            detail: 'Move the playhead over a clip and try again.',
          ),
        ops.UnsupportedForKind(:final kind) => EditorMessage(
            "This isn't available for ${_kindLabel(kind)}",
            detail: 'Select a different clip to use it.',
          ),
        ops.IncompatibleTrack() => const EditorMessage(
            "That item can't go on this track",
            detail: 'Drop it on a track of the same kind, or on empty space for a new track.',
          ),
        ops.NotAdjacent() => const EditorMessage(
            'Transitions need two clips that touch',
            detail: 'Close the gap between the clips first.',
          ),
        ops.TransitionTooLong(:final maxFrames) => EditorMessage(
            'That transition is too long for these clips',
            detail: 'Use up to $maxFrames ${maxFrames == 1 ? 'frame' : 'frames'}, or make the clips longer.',
          ),
        ops.KeyframeExists() => const EditorMessage(
            "There's already a keyframe here",
            detail: 'Move the playhead to add another one.',
          ),
        ops.EmptyText() => const EditorMessage(
            "Text can't be empty",
            detail: 'Type something, or delete the text.',
          ),
        ops.NoRoom() => const EditorMessage(
            "There's no room for that here",
            detail: 'Make space on the timeline and try again.',
          ),
        ops.RippleBlockedByLinkedItem() => const EditorMessage(
            'A linked clip is in the way',
            detail: 'Unlink the clips, or turn off ripple editing for this change.',
          ),
        ops.LimitExceeded(:final what, :final limit) => _limit(what, limit),
        ops.MediaUnavailable() => const EditorMessage(
            'This media is missing',
            detail: 'Relink it to keep editing.',
            action: EditorMessageAction.relink,
          ),
        ops.CannotDeleteMainTrack() => const EditorMessage(
            "The main track can't be deleted",
            detail: 'Delete its clips instead.',
          ),
        ops.InvalidValue() => const EditorMessage(
            "That value isn't allowed",
            detail: 'Pick a value within the allowed range.',
          ),
        ops.InternalInconsistency() => const EditorMessage(
            'Something went wrong with that change',
            detail: 'Nothing was changed. Try again.',
            action: EditorMessageAction.tryAgain,
          ),
      };

  static EditorMessage _limit(String what, int limit) => switch (what) {
        ops.LimitExceeded.items => EditorMessage(
            'Projects can have up to $limit items',
            detail: 'Remove some items to add more.',
          ),
        ops.LimitExceeded.duration => const EditorMessage(
            'Projects can be up to 24 hours long',
            detail: 'Shorten the project to add more.',
          ),
        ops.LimitExceeded.concurrentVideoLayers => EditorMessage(
            'This device can play up to $limit videos at the same time',
            detail: 'Move a video so fewer overlap, or use an image instead.',
          ),
        ops.LimitExceeded.visualSequences => const EditorMessage(
            "This device can't handle more video tracks",
            detail: 'Put your videos on fewer tracks.',
          ),
        _ => const EditorMessage(
            'This project is at its limit',
            detail: 'Remove something to add more.',
          ),
      };

  static String _kindLabel(String kind) => switch (kind) {
        'text' => 'text',
        'subtitle' || 'cue' => 'captions',
        'audio' => 'audio clips',
        'image' => 'images',
        'video' => 'videos',
        'lut' => 'LUTs',
        _ => 'this item',
      };

  // ---- Notices ----

  /// The info toast for an outcome notice, or null when it needs none.
  static EditorMessage? forNotice(ops.EditNotice notice) => switch (notice.code) {
        ops.EditNoticeCodes.trimmedToFit => const EditorMessage('Trimmed to fit'),
        ops.EditNoticeCodes.transitionsRemoved => const EditorMessage('Transitions removed where clips no longer touch'),
        ops.EditNoticeCodes.transitionsShortened => const EditorMessage('Transitions shortened to fit'),
        ops.EditNoticeCodes.placedOnOtherLane => const EditorMessage('Placed on another track because this spot was taken'),
        ops.EditNoticeCodes.itemsSkipped => EditorMessage(
            notice.count == 1 ? '1 item was skipped' : '${notice.count} items were skipped',
            detail: "They didn't fit or aren't supported here.",
          ),
        _ => null,
      };
}
