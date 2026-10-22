// OWNER: API-01
//
// Export contract (ARCH §12.4, §14, D-22, D-39). Pigeon `ExportHostApi` mirrors it:
// preflight, start(…, whenDetached, texts), resume, cancel, activeJobs, consumeJobRecord.
// INT-07 added the localized notification texts ([ExportNotificationTexts]): engine-wide through
// `EditorEngineConfig.exportNotificationTexts`, per job through `ExportService.start`.

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

/// What the engine does with a finished export when no Dart listener is attached (D-39).
///
/// See ARCH §12.4, D-39.
enum ExportDetachedHandoff {
  /// Save natively to Photos / Gallery (default), then keep a one-shot record.
  saveToGallery,

  /// Keep the file (exempt from the `work/` wipe for 7 days) and a one-shot record.
  keepForLater,
}

/// Localized texts of the Android export and background-work notifications (INT-07).
///
/// Dart owns all user-facing copy, so the app passes these engine-wide in
/// `EditorEngineConfig.exportNotificationTexts` and, optionally, per job in
/// [ExportService.start] (a later language change). The engine falls back to the English
/// defaults below. iOS shows no export notification and ignores them. `{percent}` in
/// [exportingProgress] / [workingProgress] and `{count}` in [more] are replaced natively.
///
/// See ARCH §12.4, §14.3.
@immutable
final class ExportNotificationTexts {
  /// Creates the texts; every field defaults to the engine's English text.
  const ExportNotificationTexts({
    this.exportTitle = 'Exporting video',
    this.workTitle = 'Working in the background',
    this.exporting = 'Exporting',
    this.exportingProgress = 'Exporting · {percent}%',
    this.working = 'Working',
    this.workingProgress = 'Working · {percent}%',
    this.cancel = 'Cancel',
    this.savedToGallery = 'Saved to Gallery',
    this.exportFinished = 'Export finished',
    this.more = '+{count} more',
    this.progressChannelName = 'Video export',
    this.progressChannelDescription = 'Progress of video exports and background work',
    this.doneChannelName = 'Finished exports',
    this.doneChannelDescription = 'Exports that finished while the app was closed',
  });

  /// Title when the job has none.
  final String exportTitle;

  /// Title of a background-work lease without one.
  final String workTitle;

  /// Text of an export without a known progress.
  final String exporting;

  /// Text of an export with progress (`{percent}` = 0..100).
  final String exportingProgress;

  /// Text of a background-work lease without progress.
  final String working;

  /// Text of a background-work lease with progress (`{percent}` = 0..100).
  final String workingProgress;

  /// Label of the Cancel action.
  final String cancel;

  /// Title of the completion notification after a detached save to the gallery (D-39).
  final String savedToGallery;

  /// Title of the completion notification otherwise.
  final String exportFinished;

  /// Sub text for further jobs not shown (`{count}`).
  final String more;

  /// Name of the progress notification channel (Android system settings).
  final String progressChannelName;

  /// Description of the progress channel.
  final String progressChannelDescription;

  /// Name of the completion notification channel.
  final String doneChannelName;

  /// Description of the completion channel.
  final String doneChannelDescription;

  /// Every text in declaration order (equality, validation and tests).
  List<String> get all => [
        exportTitle, workTitle, exporting, exportingProgress, working, workingProgress, cancel, savedToGallery, exportFinished, //
        more, progressChannelName, progressChannelDescription, doneChannelName, doneChannelDescription,
      ];

  @override
  bool operator ==(Object other) {
    if (other is! ExportNotificationTexts) return false;
    final a = all, b = other.all;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(all);
}

/// Export phases.
///
/// See ARCH §12.4, §14.
enum ExportPhase {
  /// Sprite pre-pass, reader/writer setup.
  preparing,

  /// Encoding frames.
  rendering,

  /// Concat (iOS segments), muxing, moving the file.
  finishing,
}

/// A non-fatal note shown with progress or preflight.
///
/// See ARCH §12.4, §14.
@immutable
final class ExportWarning {
  /// Creates a warning.
  const ExportWarning(this.code, [this.message = '']);

  /// `softwareEncoder`, `hevcUnavailable`, `backgroundPauses`, `layersVsResolution`,
  /// `portraitRetried`, `fallbackApplied`, …
  final String code;

  /// Detail without paths.
  final String message;
}

/// Result of [ExportService.preflight].
///
/// See ARCH §12.4, §14.
@immutable
final class ExportPreflight {
  /// Creates a preflight result.
  const ExportPreflight({required this.ok, this.maxHeightForPlan, this.warnings = const []});

  /// Whether the export can start with these settings.
  final bool ok;

  /// Largest output short side this plan can encode on this device.
  final int? maxHeightForPlan;

  /// Warnings to show before starting.
  final List<ExportWarning> warnings;
}

/// Progress (≤ 4 Hz).
///
/// See ARCH §12.4, §14.
@immutable
final class ExportProgress {
  /// Creates a progress sample.
  const ExportProgress({
    required this.phase,
    required this.fraction,
    this.framesDone = 0,
    this.framesTotal = 0,
    this.backgrounded = false,
    this.pausedInBackground = false,
    this.warnings = const [],
  });

  /// Phase.
  final ExportPhase phase;

  /// 0..1 overall.
  final double fraction;

  /// Frames encoded.
  final int framesDone;

  /// Frames to encode.
  final int framesTotal;

  /// The app is in the background.
  final bool backgrounded;

  /// iOS: stopped at background; resumes from the last complete segment on return (D-22).
  final bool pausedInBackground;

  /// Warnings so far.
  final List<ExportWarning> warnings;
}

/// A finished export.
///
/// See ARCH §12.4, §14.
@immutable
final class ExportResult {
  /// Creates a result.
  const ExportResult({
    required this.path,
    required this.bytes,
    required this.duration,
    required this.videoEncoderName,
    required this.hardwareEncoder,
  });

  /// Output path under `<cache>/danaview/editor/work/`.
  final String path;

  /// Size in bytes.
  final int bytes;

  /// Duration.
  final TimeUs duration;

  /// Encoder name (diagnostics).
  final String videoEncoderName;

  /// Whether the video encoder was hardware.
  final bool hardwareEncoder;
}

/// A running export.
///
/// See ARCH §12.4, §14.
abstract interface class ExportJob {
  /// Job id (stable across process death for resumable and detached records).
  String get id;

  /// Progress samples.
  Stream<ExportProgress> get progress;

  /// Result (throws `EngineFailure`; `EngineCancelled` after [cancel]).
  Future<ExportResult> get result;

  /// Cancels (after the UI confirmed) and deletes the partial file and segments.
  Future<void> cancel();
}

/// Export jobs known to the engine when the editor (re)opens.
///
/// See ARCH §12.4, D-22, D-39.
@immutable
sealed class ExportJobState {
  const ExportJobState(this.jobId);

  /// Job id.
  final String jobId;
}

/// Still running: reattach to [job].
///
/// See ARCH §12.4, §14.
final class ExportRunning extends ExportJobState {
  /// Creates the state.
  ExportRunning(this.job) : super(job.id);

  /// The live job.
  final ExportJob job;
}

/// iOS segment-resumable job with complete segments (UX offers "Resume export", D-22).
///
/// See ARCH §12.4, D-22.
final class ExportResumable extends ExportJobState {
  /// Creates the state.
  const ExportResumable(super.jobId, {required this.doneFraction});

  /// Fraction already encoded.
  final double doneFraction;
}

/// Ended by process death or an unrecoverable interruption (reported once).
///
/// See ARCH §12.4, D-22.
final class ExportInterrupted extends ExportJobState {
  /// Creates the state.
  const ExportInterrupted(super.jobId);
}

/// Finished while no Dart listener was attached (reported once until consumed, D-39).
///
/// See ARCH §12.4, D-39.
final class ExportCompletedWhileDetached extends ExportJobState {
  /// Creates the state.
  const ExportCompletedWhileDetached(super.jobId, {this.result, this.savedToGallery = false, this.savedUri, this.settings});

  /// The output file when it was kept (null when only the gallery copy exists).
  final ExportResult? result;

  /// Whether the engine saved it to Photos / Gallery.
  final bool savedToGallery;

  /// Gallery URI / local identifier, when saved.
  final String? savedUri;

  /// Settings used.
  final EncodeSettings? settings;
}

/// Native export (iOS AVAssetReader/Writer with segmented resumable video; Android Transformer).
///
/// See ARCH §12.4, §14, D-22, D-39.
abstract interface class ExportService {
  /// Checks the plan and settings on this device.
  Future<ExportPreflight> preflight(RenderPlan plan, EncodeSettings settings);

  /// Starts an export to [outputPath] (`<support>/danaview/editor/exports/export-<token>.<ext>`, QA-05 D8).
  /// [notificationTexts] (INT-07) replace the engine-wide notification texts from this job on;
  /// null keeps them.
  Future<ExportJob> start(
    RenderPlan plan,
    EncodeSettings settings, {
    required String outputPath,
    required String title,
    ExportDetachedHandoff whenDetached = ExportDetachedHandoff.saveToGallery,
    ExportNotificationTexts? notificationTexts,
  });

  /// Resumes an iOS segment-resumable job; `notSupportedOnDevice` elsewhere.
  Future<ExportJob> resume(String jobId);

  /// Running, resumable, interrupted and completed-while-detached jobs. One-shot states are
  /// returned until [consumeJobRecord] is called.
  Future<List<ExportJobState>> activeJobs();

  /// Marks a one-shot record (interrupted / completedWhileDetached) as seen; its kept output
  /// loses the `work/` wipe exemption.
  Future<void> consumeJobRecord(String jobId);
}
