// OWNER: UX-39
//
// Copy of the export flow (ux.md §11, ARCH §14.1, D-22, D-39): pre-checks, presets and custom
// settings, notices, progress and background copy per `BackgroundExportKind`, completion and
// handoff, failure fallbacks, and the reattach cards. Plain, specific, with a next step (ARCH §19).
// Never includes media paths; failure copy itself comes from `EditorMessages` (editor_messages.dart).

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:danaview_editor_core/model.dart' show AspectRatio;
import 'package:danaview_editor_core/plan.dart' show ExportContainer, ExportPresetId, ExportQuality, SideFileFormat, VideoCodec;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show BackgroundExportKind, ExportNotificationTexts, ExportPhase;
import 'package:danaview_features/storage.dart' show formatDataSize;

/// Copy of the export sheet and its controller.
abstract final class ExportStrings {
  // ---- Sheet and pre-checks -----------------------------------------------------------------

  /// Sheet title.
  static const String sheetTitle = 'Export';

  /// Why Export is disabled before the project has opened.
  static const String notReady = 'Export is available when the project has opened.';

  /// Spoken label of the sheet.
  static const String sheetLabel = 'Export video';

  /// While the pre-checks run.
  static const String checking = 'Checking your project…';

  /// Toast: nothing to export (ux.md §11.1 check 3).
  static const String emptyTimeline = 'Add a clip before exporting.';

  /// Headline of the missing-media pre-check (ux.md §11.1 check 1).
  static String relinkHeadline(int count) => count == 1 ? 'Relink 1 missing file to export' : 'Relink $count missing files to export';

  /// What to do about missing media.
  static const String relinkDetail = "Some media can't be found, so it can't be exported. Relink it, then export again.";

  /// The relink button.
  static const String relinkButton = 'Relink files';

  /// Headline while reverse and freeze jobs finish (ux.md §11.1 check 2).
  static String waitingHeadline(int count) => count == 1 ? 'Finishing 1 clip…' : 'Finishing $count clips…';

  /// Detail while waiting.
  static const String waitingDetail = 'The export starts by itself when they are ready.';

  // ---- Presets and summary ------------------------------------------------------------------

  /// Section: presets.
  static const String presetsSection = 'Preset';

  /// Preset chip label.
  static String presetLabel(ExportPresetId id) => switch (id) {
        ExportPresetId.youtube => 'YouTube',
        ExportPresetId.youtube4k => 'YouTube 4K',
        ExportPresetId.youtubeShorts => 'Shorts',
        ExportPresetId.instagramReels => 'Reels',
        ExportPresetId.instagramFeed => 'Instagram Feed',
        ExportPresetId.tiktok => 'TikTok',
        ExportPresetId.custom => 'Custom',
      };

  /// The name used inside sentences ("TikTok videos are 9:16").
  static String presetName(ExportPresetId id) => switch (id) {
        ExportPresetId.youtube => 'YouTube',
        ExportPresetId.youtube4k => 'YouTube 4K',
        ExportPresetId.youtubeShorts => 'YouTube Shorts',
        ExportPresetId.instagramReels => 'Instagram Reels',
        ExportPresetId.instagramFeed => 'Instagram Feed',
        ExportPresetId.tiktok => 'TikTok',
        ExportPresetId.custom => 'This size',
      };

  /// `1920×1080 · 30 fps · H.264 · ≈ 210 MB`.
  static String summary({required int width, required int height, required int fps, required VideoCodec codec, required int estimatedBytes}) =>
      '$width×$height · $fps fps · ${codecLabel(codec)} · ≈ ${formatDataSize(roundedBytes(estimatedBytes))}';

  /// The size estimate rounded to two significant figures (ux.md §11.3).
  static int roundedBytes(int bytes) {
    if (bytes < 100) return bytes;
    var scale = 1;
    var v = bytes;
    while (v >= 100) {
      v = (v / 10).round();
      scale *= 10;
    }
    return v * scale;
  }

  /// Tap target of the summary that expands the custom settings.
  static const String editSettings = 'Edit';

  /// Hardware encoder info row (ux.md §11.6).
  static const String hardwareEncoder = "Uses your device's hardware video encoder.";

  /// Software encoder info row.
  static const String softwareEncoder = 'Software encoding (slower).';

  // ---- Custom settings ----------------------------------------------------------------------

  /// Section: custom settings.
  static const String customSection = 'Custom settings';

  /// Row: container.
  static const String formatRow = 'Format';

  /// Row: codec.
  static const String codecRow = 'Codec';

  /// Row: resolution.
  static const String resolutionRow = 'Resolution';

  /// Row: frame rate.
  static const String fpsRow = 'Frame rate';

  /// Row: quality.
  static const String qualityRow = 'Quality';

  /// Row: video bitrate.
  static const String videoBitrateRow = 'Video bitrate';

  /// Row: audio bitrate.
  static const String audioBitrateRow = 'Audio';

  /// Container label.
  static String containerLabel(ExportContainer c) => c == ExportContainer.mov ? 'MOV' : 'MP4';

  /// Codec label.
  static String codecLabel(VideoCodec c) => c == VideoCodec.hevc ? 'H.265' : 'H.264';

  /// Resolution label (`720p`, `4K`).
  static String resolutionLabel(int shortSide) => shortSide >= 2160 ? '4K' : '${shortSide}p';

  /// The actual output size of a resolution for the project aspect.
  static String resolutionSize(int width, int height) => '$width×$height';

  /// Frame rate: the project's.
  static const String fpsMatchProject = 'Match project';

  /// Frame rate label.
  static String fpsLabel(int fps) => '$fps';

  /// Quality label.
  static String qualityLabel(ExportQuality q) => switch (q) {
        ExportQuality.smaller => 'Smaller',
        ExportQuality.balanced => 'Balanced',
        ExportQuality.high => 'High',
        ExportQuality.maximum => 'Maximum',
      };

  /// Video bitrate: automatic.
  static String bitrateAuto(double mbps) => 'Auto (${_mbps(mbps)} Mbps)';

  /// Video bitrate: custom.
  static const String bitrateCustom = 'Custom';

  /// Video bitrate value.
  static String bitrateValue(double mbps) => '${_mbps(mbps)} Mbps';

  /// Spoken label of the bitrate slider.
  static const String bitrateSlider = 'Video bitrate';

  /// Audio bitrate label.
  static String audioLabel(int kbps) => '$kbps kbps';

  static String _mbps(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  // ---- Notices ------------------------------------------------------------------------------

  /// Aspect mismatch: "Your project is 16:9. TikTok videos are 9:16, so yours will have black bars."
  static String aspectMismatch({required AspectRatio project, required AspectRatio output, required ExportPresetId preset}) {
    final who = preset == ExportPresetId.custom ? 'Videos at this size are' : '${presetName(preset)} videos are';
    return 'Your project is $project. $who $output, so yours will have black bars.';
  }

  /// The button of the aspect mismatch notice.
  static String changeProjectTo(AspectRatio aspect) => 'Change project to $aspect';

  /// The output size was reduced to the device limit.
  static String resolutionClamped(int shortSide) => 'This device exports up to ${shortSide}p, so the video is smaller than you chose.';

  /// The frame rate was reduced.
  static String fpsClamped(int fps) => 'This device exports at up to $fps fps at this size, so the frame rate is lower than you chose.';

  /// HEVC was asked for but is not available.
  static const String hevcUnavailable = "H.265 isn't available on this device, so H.264 is used.";

  /// MOV was asked for but is not available.
  static const String movUnavailable = "MOV isn't available on this device, so MP4 is used.";

  /// A bitrate was clamped.
  static const String bitrateClamped = 'The bitrate was adjusted to what the encoder supports.';

  // ---- Captions and destination -------------------------------------------------------------

  /// Section: captions.
  static const String captionsSection = 'Captions';

  /// One row per subtitle track.
  static String burnTrack(String trackName) => 'Burn "$trackName" into the video';

  /// The side files row.
  static const String sideFilesRow = 'Also save captions as';

  /// Side file format label.
  static String sideFileLabel(SideFileFormat f) => f == SideFileFormat.srt ? 'SRT' : 'VTT';

  /// Section: destination.
  static const String saveToSection = 'Save to';

  /// Photos (iOS) or Gallery (Android).
  static String photosDestination(TargetPlatform platform) => platform == TargetPlatform.iOS ? 'Photos' : 'Gallery';

  /// Files destination.
  static const String filesDestination = 'Files…';

  /// Share destination.
  static const String shareDestination = 'Share…';

  /// Keep a copy switch (D-44).
  static const String keepCopy = 'Keep a copy in Danaview';

  /// Keep a copy subtitle.
  static const String keepCopyHint = 'Shows up in On This Device, where you can play it.';

  /// The Export button.
  static const String exportButton = 'Export';

  // ---- Storage ------------------------------------------------------------------------------

  /// Not enough free space (ux.md §11.1 check 4).
  static String lowStorage(int neededBytes) =>
      'You need about ${formatDataSize(roundedBytes(neededBytes))} free to export. Free up space or lower the resolution.';

  /// What is free.
  static String lowStorageFree(int freeBytes) => '${formatDataSize(freeBytes)} free right now.';

  // ---- First export notice ------------------------------------------------------------------

  /// Title of the first-export background notice.
  static const String backgroundNoticeTitle = 'Before you start';

  /// The notice for Android: notifications explained in context (ux.md §11.5).
  static const String notificationExplainer =
      'Danaview shows export progress in a notification while it is in the background. Android may ask you to allow notifications.';

  /// The running export after the notification permission dialog went unanswered (UX-39).
  static const String notificationsUnanswered =
      "Exporting without notifications. Keep Danaview open to follow the progress here; you can allow notifications later in Settings.";

  /// The continue button of the notice.
  static const String noticeContinue = 'Start export';

  // ---- Android export notifications (INT-07) --------------------------------------------------

  /// The texts of the Android export and background-work notifications, from this copy. Handed to
  /// the engine at start-up (`EditorEngineConfig.exportNotificationTexts`) and with every export job
  /// (`ExportService.start(notificationTexts:)`), so the notification follows the app's language.
  /// `{percent}` and `{count}` are filled in natively.
  static const ExportNotificationTexts notificationTexts = ExportNotificationTexts(
    exportTitle: 'Exporting video',
    workTitle: 'Working in the background',
    exporting: 'Exporting',
    exportingProgress: 'Exporting · {percent}%',
    working: 'Working',
    workingProgress: 'Working · {percent}%',
    cancel: 'Cancel',
    savedToGallery: 'Saved to Gallery',
    exportFinished: 'Export finished',
    more: '+{count} more',
    progressChannelName: 'Video export',
    progressChannelDescription: 'Progress of video exports and background work',
    doneChannelName: 'Finished exports',
    doneChannelDescription: 'Exports that finished while the app was closed',
  );

  /// The back button of the notice.
  static const String noticeBack = 'Back';

  // ---- Preflight warnings -------------------------------------------------------------------

  /// Title of the warnings step.
  static const String warningsTitle = 'Heads up';

  /// A preflight warning's text by code.
  static String warning(String code) => switch (code) {
        'softwareEncoder' => "This device will encode in software, so the export can be slower and warmer than usual.",
        'hevcUnavailable' => "H.265 isn't available here, so H.264 is used.",
        'layersVsResolution' => 'This project has many layers for this resolution. The export may be slow. A lower resolution is faster.',
        'backgroundPauses' => 'The export pauses while Danaview is in the background.',
        'portraitRetried' => 'This size needed a different encoder setup. The video is rotated by metadata and plays upright.',
        'fallbackApplied' => 'The encoder used a fallback setting.',
        _ => 'The device reported a limitation for this export.',
      };

  /// Export anyway.
  static const String exportAnyway = 'Export anyway';

  /// Change settings.
  static const String changeSettings = 'Change settings';

  // ---- Progress -----------------------------------------------------------------------------

  /// While sprites are prepared.
  static const String preparing = 'Preparing…';

  /// Phase label.
  static String phaseLabel(ExportPhase phase) => switch (phase) {
        ExportPhase.preparing => 'Preparing…',
        ExportPhase.rendering => 'Rendering video',
        ExportPhase.finishing => 'Finishing',
      };

  /// Percent text.
  static String percent(double fraction) => '${(fraction.clamp(0.0, 1.0) * 100).floor()}%';

  /// Spoken label of the progress bar.
  static const String progressLabel = 'Exporting';

  /// ETA text (shown after enough samples).
  static String eta(Duration remaining) {
    final s = remaining.inSeconds;
    if (s < 10) return 'A few seconds left';
    if (s < 60) return 'About ${(s / 5).round() * 5} seconds left';
    final m = (s / 60).round();
    if (m < 60) return m == 1 ? 'About 1 min left' : 'About $m min left';
    final h = m ~/ 60;
    final rest = m % 60;
    return rest == 0 ? 'About $h h left' : 'About $h h $rest min left';
  }

  /// Cancel button.
  static const String cancel = 'Cancel';

  /// While cancelling.
  static const String cancelling = 'Cancelling…';

  /// Cancel confirmation title.
  static const String cancelConfirmTitle = 'Stop exporting?';

  /// Cancel confirmation message.
  static const String cancelConfirmMessage = 'The partial file is deleted.';

  /// Destructive confirm.
  static const String stopExport = 'Stop export';

  /// Keep going.
  static const String keepExporting = 'Keep exporting';

  /// Toast after a cancel.
  static const String cancelled = 'Export cancelled';

  /// Background copy for the running export, by what the device does when backgrounded (D-22).
  static String backgroundCopy(BackgroundExportKind kind) => switch (kind) {
        BackgroundExportKind.paused =>
          'Keep Danaview open while exporting. If you leave, the export pauses and continues from where it stopped when you come back.',
        BackgroundExportKind.foregroundService => "You can leave Danaview; you'll get a notification when it's done.",
        BackgroundExportKind.continued => 'You can leave Danaview. Progress shows in the system while the export continues.',
        BackgroundExportKind.none => 'Keep Danaview open while exporting. If you leave, the export stops.',
      };

  /// Shown while an iPhone export is paused in the background.
  static const String pausedInBackground =
      'Paused while Danaview is in the background. It continues from where it stopped when you come back.';

  /// Shown while the export runs in the background.
  static const String runningInBackground = 'Exporting in the background.';

  // ---- Interrupted and resume ---------------------------------------------------------------

  /// Title of the interrupted state.
  static const String interruptedTitle = 'The export was interrupted';

  /// Detail when it can be resumed.
  static String interruptedCanResume(double doneFraction) =>
      'Danaview kept the first ${percent(doneFraction)}. Resume to finish the rest.';

  /// Detail when it cannot.
  static const String interruptedStartAgain = 'Start it again. Your project is unchanged.';

  /// Resume button.
  static const String resume = 'Resume export';

  /// Start again button.
  static const String startAgain = 'Start again';

  // ---- Completion ---------------------------------------------------------------------------

  /// `Saved to Photos` / `Saved to Gallery`.
  static String savedToLibrary(TargetPlatform platform) => 'Saved to ${photosDestination(platform)}';

  /// Saved through the Files picker.
  static const String savedToFiles = 'Saved to Files';

  /// Shared.
  static const String shared = 'Shared';

  /// Waiting for the handoff.
  static String saving(TargetPlatform platform, {required bool toLibrary}) =>
      toLibrary ? 'Saving to ${photosDestination(platform)}…' : 'Saving…';

  /// The export is ready but not saved anywhere yet.
  static const String exportReady = 'Your video is ready';

  /// The user closed the Files / share sheet without finishing.
  static const String notSavedYet = "It isn't saved yet. Choose where to put it.";

  /// File size and duration under the title.
  static String fileInfo(int bytes, String duration) => '${formatDataSize(bytes)} · $duration';

  /// Kept copy done.
  static String keptCopy(String fileName) => 'Kept in Danaview as $fileName';

  /// Kept copy failed.
  static const String keepCopyFailed = "Couldn't keep a copy in Danaview. Your export is still saved.";

  /// Save to Photos / Gallery button.
  static String saveToLibraryButton(TargetPlatform platform) => 'Save to ${photosDestination(platform)}';

  /// Save to Files button.
  static const String saveToFilesButton = 'Save to Files';

  /// Share button.
  static const String shareButton = 'Share';

  /// Play in Danaview.
  static const String play = 'Play in Danaview';

  /// Done.
  static const String done = 'Done';

  /// Caption files section.
  static const String captionFiles = 'Caption files';

  /// One caption file's button.
  static String saveCaptionFile(String name) => 'Save $name';

  /// Close.
  static const String close = 'Close';

  // ---- Failure ------------------------------------------------------------------------------

  /// Try again.
  static const String tryAgain = 'Try again';

  /// Fallback: H.264.
  static const String exportH264 = 'Export with H.264';

  /// Fallback: lower resolution.
  static const String lowerResolution = 'Lower resolution';

  /// Fallback: free up space.
  static const String freeUpSpace = 'Free up space';

  /// Open settings.
  static const String openSettings = 'Open Settings';

  /// Copy details.
  static const String copyDetails = 'Copy details';

  /// Toast after copying.
  static const String detailsCopied = 'Details copied';

  /// Back to the settings.
  static const String backToSettings = 'Back to settings';

  // ---- Reattach (D-22, D-39) ----------------------------------------------------------------

  /// One-shot card title (D-39).
  static const String finishedTitle = 'Your export finished';

  /// Detail when the video was saved natively.
  static String finishedSaved(TargetPlatform platform) => 'Saved to ${photosDestination(platform)}.';

  /// Detail when it was kept in Danaview's temporary storage.
  static const String finishedKept = 'Share it, save it to Files, or delete it.';

  /// Delete the finished export.
  static const String deleteExport = 'Delete';
}
