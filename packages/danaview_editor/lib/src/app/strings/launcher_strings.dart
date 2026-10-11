// OWNER: UX-41
//
// Copy of the player's Edit action (ARCH §17.1, ux.md §4.4): the "Preparing editor…" wait, the
// missing-file toast, the "This video can't be edited" explanations per `NotEditable.code` and
// platform (R7: MKV/WebM/AVI on iPhone and iPad), the device-gate explanations per
// `EditorCapabilities.unsupportedReason`, and the failure title. Plain, specific, with a next step
// (ARCH §19). Never includes media paths.

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show UnsupportedReasons;

/// `NotEditable.code` values the launcher has specific copy for (ARCH §12.1).
abstract final class EditCompatibilityCodes {
  /// MKV, WebM or AVI on iOS (R7).
  static const String containerUnsupportedIos = 'container_unsupported_ios';

  /// No decoder for the video's codec, profile or size.
  static const String codecUnsupported = 'codec_unsupported';

  /// DRM-protected content.
  static const String protectedContent = 'protected_content';

  /// The file is gone.
  static const String notFound = 'not_found';
}

/// Copy of the player's Edit action (ux.md §4.4).
abstract final class LauncherStrings {
  /// The wait shown when opening takes longer than 300 ms.
  static const String preparing = 'Preparing editor…';

  /// Title of the import sheet when the video must be copied first (managed copy).
  static const String copyTitle = 'Preparing editor';

  /// The single action of every explanation.
  static const String ok = 'OK';

  /// The file is gone (same copy as the player's own toast).
  static const String missing = "Couldn't find this video. It may have been moved or deleted.";

  /// Title of the "can't edit this file" explanation.
  static const String notEditableTitle = "This video can't be edited";

  /// Title of the device-gate explanation.
  static const String unsupportedDeviceTitle = "Video editing isn't available on this device";

  /// Title when the project couldn't be prepared.
  static const String failedTitle = "Couldn't open the editor";

  /// The upper-case container name of [fileName] (`MKV`), or null when it has no extension.
  static String? containerOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return null;
    final ext = fileName.substring(dot + 1);
    if (ext.length > 5 || ext.contains('/')) return null;
    return switch (ext.toLowerCase()) {
      'webm' => 'WebM',
      final e => e.toUpperCase(),
    };
  }

  static String _device(TargetPlatform platform) => switch (platform) {
        TargetPlatform.iOS => 'iPhone and iPad',
        TargetPlatform.android => 'this device',
        _ => 'this device',
      };

  /// Why [fileName] can't be edited, for a `NotEditable.code` on [platform].
  static String notEditableMessage(String code, {required TargetPlatform platform, required String fileName}) {
    final container = containerOf(fileName);
    switch (code) {
      case EditCompatibilityCodes.containerUnsupportedIos:
        final kind = container ?? 'these';
        return 'Danaview can play $kind files, but iPhone and iPad can only edit MP4, MOV and M4V videos. '
            'Convert it to MP4 to edit it.';
      case EditCompatibilityCodes.codecUnsupported:
        return platform == TargetPlatform.iOS
            ? "iPhone and iPad can't decode this video's format for editing. Convert it to an H.264 or HEVC MP4 to edit it."
            : "This device can't decode this video's format for editing. Convert it to an H.264 MP4 to edit it.";
      case EditCompatibilityCodes.protectedContent:
        return "This video is copy-protected, so it can't be edited. You can still play it.";
      case EditCompatibilityCodes.notFound:
        return missing;
      case UnsupportedReasons.engineNotAvailable:
        return "This version of Danaview can't edit videos on ${_device(platform)}. You can still play all your videos.";
      default:
        return "Danaview can't edit this video on ${_device(platform)}. Converting it to MP4 usually helps.";
    }
  }

  /// Why this device can't edit, for an `EditorCapabilities.unsupportedReason`.
  static String unsupportedDeviceMessage(String reason) => switch (reason) {
        UnsupportedReasons.androidTooOld => 'Video editing needs Android 10 or later. You can still play all your videos.',
        UnsupportedReasons.gles3Missing => "This device's graphics don't support OpenGL ES 3, which the video editor needs. "
            'You can still play all your videos.',
        UnsupportedReasons.metalMissing => "This device's graphics can't run the video editor. You can still play all your videos.",
        UnsupportedReasons.insufficientMemory =>
          'Video editing needs a device with at least 2 GB of memory. You can still play all your videos.',
        _ => "This version of Danaview can't edit videos on this device. You can still play all your videos.",
      };
}
