// OWNER: AI-08
//
// The Auto captions service contract (ARCH §16, D-21; ai.md §8.1). Implemented by
// `TranscriptionServiceImpl` (AI-13) and `FakeTranscriptionService` (lib/testing.dart). The
// service never mutates the project: the editor applies results with the core commands
// `AddGeneratedCaptionTrack` / `ReplaceGeneratedCaptions` (CORE-15) as one history entry.

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

import '../catalog/speech_model_catalog.dart';
import '../languages/languages.dart';
import 'consent.dart';
import 'failures.dart';
import 'timeline_view.dart';

/// Whether Auto captions can run on this device.
@immutable
sealed class TranscriptionSupport {
  const TranscriptionSupport();
}

/// Supported with the listed tiers available.
final class TranscriptionSupported extends TranscriptionSupport {
  /// Creates the state.
  const TranscriptionSupported(this.tiers);

  /// Tiers this device may use.
  final List<SpeechModelTier> tiers;
}

/// Not supported ("Auto captions aren't available on this device").
final class TranscriptionUnsupported extends TranscriptionSupport {
  /// Creates the state.
  const TranscriptionUnsupported(this.reason);

  /// `platform`, `abi`, `osVersion`, `insufficientMemory`, `libraryUnavailable`.
  final String reason;
}

/// One tier as offered on this device.
@immutable
final class SpeechModelOffer {
  /// Creates an offer.
  const SpeechModelOffer({required this.spec, required this.available, this.recommended = false, this.unavailableReason});

  /// The model.
  final SpeechModelSpec spec;

  /// Whether the device qualifies.
  final bool available;

  /// The recommended tier.
  final bool recommended;

  /// Why not ("Needs a device with more memory").
  final String? unavailableReason;
}

/// A verified installed model.
@immutable
final class InstalledSpeechModel {
  /// Creates the record.
  const InstalledSpeechModel({required this.spec, required this.installedAt, this.lastUsedAt});

  /// The model.
  final SpeechModelSpec spec;

  /// Install time.
  final DateTime installedAt;

  /// Last use.
  final DateTime? lastUsedAt;
}

/// Model download phases.
enum ModelDownloadPhase {
  /// Preflight and redirect check.
  preparing,

  /// Receiving bytes.
  downloading,

  /// SHA-256 and magic check.
  verifying,

  /// Atomic rename and manifest update.
  finishing,
}

/// Download progress (≤ 4 Hz).
@immutable
final class ModelDownloadProgress {
  /// Creates a sample.
  const ModelDownloadProgress({required this.phase, required this.received, required this.total, this.bytesPerSecond = 0});

  /// Phase.
  final ModelDownloadPhase phase;

  /// Bytes received.
  final int received;

  /// Bytes in total (model + VAD).
  final int total;

  /// Current rate.
  final double bytesPerSecond;
}

/// State of one model.
@immutable
sealed class SpeechModelStatus {
  const SpeechModelStatus();
}

/// Not installed (consent needed to download).
final class SpeechModelMissing extends SpeechModelStatus {
  /// Creates the state.
  const SpeechModelMissing();
}

/// Downloading.
final class SpeechModelDownloading extends SpeechModelStatus {
  /// Creates the state.
  const SpeechModelDownloading(this.progress);

  /// Latest progress.
  final ModelDownloadProgress progress;
}

/// Installed and verified.
final class SpeechModelReady extends SpeechModelStatus {
  /// Creates the state.
  const SpeechModelReady(this.model);

  /// The model.
  final InstalledSpeechModel model;
}

/// Installed but failed to load or verify ("download again").
final class SpeechModelCorrupt extends SpeechModelStatus {
  /// Creates the state.
  const SpeechModelCorrupt();
}

/// What to transcribe.
@immutable
sealed class TranscriptionScope {
  const TranscriptionScope();
}

/// One clip.
final class ClipScope extends TranscriptionScope {
  /// Creates the scope.
  const ClipScope(this.item);

  /// Clip.
  final ItemId item;
}

/// Several clips.
final class ItemsScope extends TranscriptionScope {
  /// Creates the scope.
  const ItemsScope(this.items);

  /// Clips.
  final Set<ItemId> items;
}

/// The timeline (optionally limited to tracks and a range).
final class TimelineScope extends TranscriptionScope {
  /// Creates the scope.
  const TimelineScope({this.tracks, this.range});

  /// Tracks, or null for every audible track (music unchecked by default).
  final Set<TrackId>? tracks;

  /// Range, or null for the whole timeline.
  final TimeRange? range;
}

/// The spoken language: chosen by the user (device locale preselected) or detected (D-19).
@immutable
sealed class SpokenLanguage {
  const SpokenLanguage();
}

/// "Detect automatically" (secondary row; < 0.6 confidence asks the user, D-19).
final class AutoLanguage extends SpokenLanguage {
  /// Creates the choice.
  const AutoLanguage();
}

/// A fixed whisper language code.
final class FixedLanguage extends SpokenLanguage {
  /// Creates the choice.
  const FixedLanguage(this.code);

  /// whisper code (`en`, `ja`, …).
  final String code;
}

/// Where generated cues go.
@immutable
sealed class CaptionTarget {
  const CaptionTarget();
}

/// A new subtitle track at the top of the subtitle tracks.
final class NewTrackTarget extends CaptionTarget {
  /// Creates the target.
  const NewTrackTarget();
}

/// Replace the generated cues of [track].
final class ReplaceTrackTarget extends CaptionTarget {
  /// Creates the target.
  const ReplaceTrackTarget(this.track);

  /// Track.
  final TrackId track;
}

/// Replace the cues of [track] inside [range].
final class ReplaceInRangeTarget extends CaptionTarget {
  /// Creates the target.
  const ReplaceInRangeTarget(this.track, this.range);

  /// Track.
  final TrackId track;

  /// Range.
  final TimeRange range;
}

/// A transcription request.
@immutable
final class TranscriptionRequest {
  /// Creates a request.
  const TranscriptionRequest({
    required this.project,
    required this.scope,
    required this.language,
    required this.modelId,
    required this.segmentation,
    required this.target,
    required this.timeline,
    this.includeSoundDescriptions = false,
  });

  /// Project.
  final ProjectId project;

  /// Scope.
  final TranscriptionScope scope;

  /// Language.
  final SpokenLanguage language;

  /// Catalog model id.
  final String modelId;

  /// Segmentation preset and limits.
  final SegmentationSettings segmentation;

  /// Destination.
  final CaptionTarget target;

  /// Read at the start (plan) and again at the end (mapping).
  final TimelineView Function() timeline;

  /// Keep `[music]`-style annotations (suppress_nst off).
  final bool includeSoundDescriptions;
}

/// Job phases.
enum TranscriptionPhase {
  /// Planning units.
  preparing,

  /// Downloading the model (after consent).
  downloadingModel,

  /// Extracting audio.
  extractingAudio,

  /// Loading the model.
  loadingModel,

  /// Detecting the language.
  detectingLanguage,

  /// Waiting for the user to pick a language (low detection confidence).
  needsLanguage,

  /// Transcribing.
  transcribing,

  /// Splitting into cues.
  segmenting,

  /// Finished.
  done,
}

/// Why a job is paused.
enum PauseReason {
  /// App in the background (iOS).
  background,

  /// Thermal state critical.
  thermal,

  /// An export started (paused at a chunk boundary).
  exportRunning,

  /// Waiting for a running export to finish.
  waitingForExport,
}

/// A detected-language candidate.
@immutable
final class LanguageProbability {
  /// Creates a candidate.
  const LanguageProbability(this.code, this.p);

  /// whisper code.
  final String code;

  /// Probability.
  final double p;
}

/// Job progress (≤ 4 Hz).
@immutable
final class TranscriptionProgress {
  /// Creates a sample.
  const TranscriptionProgress({
    required this.phase,
    required this.fraction,
    this.eta,
    this.unitIndex = 0,
    this.unitCount = 0,
    this.processed = 0,
    this.total = 0,
    this.partialText,
    this.paused,
    this.languageCandidates,
  });

  /// Phase.
  final TranscriptionPhase phase;

  /// 0..1 overall.
  final double fraction;

  /// Estimated remaining time.
  final Duration? eta;

  /// Current unit.
  final int unitIndex;

  /// Units in total.
  final int unitCount;

  /// Audio processed.
  final TimeUs processed;

  /// Audio in total.
  final TimeUs total;

  /// Last ≤ 80 characters, shown in the panel, never logged.
  final String? partialText;

  /// Pause reason, when paused.
  final PauseReason? paused;

  /// Top-3 candidates when [phase] is [TranscriptionPhase.needsLanguage].
  final List<LanguageProbability>? languageCandidates;
}

/// A clip that was not transcribed, with a reason code (`reversed`, `noAudio`,
/// `unsupportedCodec`, `muted`, …).
@immutable
final class SkippedClip {
  /// Creates the record.
  const SkippedClip(this.item, this.reason);

  /// Clip.
  final ItemId item;

  /// Reason code.
  final String reason;
}

/// Summary shown when a job finishes.
@immutable
final class TranscriptionSummary {
  /// Creates a summary.
  const TranscriptionSummary({required this.cues, required this.words, required this.language, this.skipped = const []});

  /// Cues produced.
  final int cues;

  /// Words recognized.
  final int words;

  /// BCP-47 language used.
  final String language;

  /// Skipped clips.
  final List<SkippedClip> skipped;
}

/// A finished job.
@immutable
final class TranscriptionResult {
  /// Creates a result.
  const TranscriptionResult({required this.drafts, required this.provenance, required this.target, required this.summary});

  /// Timeline cues, frame-quantized, `\n` between lines.
  final List<SubtitleCueDraft> drafts;

  /// Stored on the subtitle track.
  final CaptionProvenance provenance;

  /// Destination.
  final CaptionTarget target;

  /// Summary.
  final TranscriptionSummary summary;
}

/// Preflight of a request (memory, disk, download size, estimate).
@immutable
final class TranscriptionPreflight {
  /// Creates a preflight result.
  const TranscriptionPreflight({required this.ok, this.failure, this.downloadBytes = 0, this.estimatedDuration});

  /// Whether the job can start.
  final bool ok;

  /// Why not.
  final TranscriptionFailure? failure;

  /// Bytes to download first (0 when installed).
  final int downloadBytes;

  /// Processing-time estimate.
  final Duration? estimatedDuration;
}

/// A job that can be resumed after the app was killed (7-day expiry).
@immutable
final class ResumableTranscription {
  /// Creates the record.
  const ResumableTranscription({required this.jobId, required this.project, required this.doneFraction, required this.createdAt});

  /// Job id.
  final String jobId;

  /// Project.
  final ProjectId project;

  /// Fraction done.
  final double doneFraction;

  /// Start time.
  final DateTime createdAt;
}

/// Storage used by Auto captions (Settings › Storage "Speech model" contributor).
@immutable
final class SpeechStorageUsage {
  /// Creates the record.
  const SpeechStorageUsage({this.modelBytes = 0, this.transcriptBytes = 0, this.partialBytes = 0});

  /// Installed models + VAD.
  final int modelBytes;

  /// Cached transcripts.
  final int transcriptBytes;

  /// Partial downloads and work files.
  final int partialBytes;
}

/// A running transcription.
abstract interface class TranscriptionJob {
  /// Job id.
  String get id;

  /// Progress (≤ 4 Hz).
  Stream<TranscriptionProgress> get progress;

  /// Result (throws [TranscriptionFailure]; [TranscriptionCancelled] after [cancel]).
  Future<TranscriptionResult> get result;

  /// Cancels and keeps the checkpoint.
  void cancel();

  /// Answers [TranscriptionPhase.needsLanguage].
  void provideLanguage(String code);
}

/// Service-level events (model status changes, job start/end).
@immutable
sealed class TranscriptionEvent {
  const TranscriptionEvent();
}

/// A model's status changed.
final class ModelStatusChanged extends TranscriptionEvent {
  /// Creates the event.
  const ModelStatusChanged(this.modelId, this.status);

  /// Model.
  final String modelId;

  /// New status.
  final SpeechModelStatus status;
}

/// A job started.
final class JobStarted extends TranscriptionEvent {
  /// Creates the event.
  const JobStarted(this.job);

  /// The job.
  final TranscriptionJob job;
}

/// A job ended (done, failed or cancelled).
final class JobEnded extends TranscriptionEvent {
  /// Creates the event.
  const JobEnded(this.jobId);

  /// Job id.
  final String jobId;
}

/// Auto captions (D-21 extended interface).
abstract interface class TranscriptionService {
  /// The 99 whisper languages ("Detect automatically" is added by the UI).
  List<TranscriptionLanguage> get languages;

  /// Device support.
  Future<TranscriptionSupport> support();

  /// Every tier with its availability on this device.
  List<SpeechModelOffer> get offers;

  /// The device-recommended model.
  SpeechModelSpec get defaultModel;

  /// Status of [defaultModel].
  Future<SpeechModelStatus> modelStatus();

  /// Status of one model.
  Future<SpeechModelStatus> modelStatusOf(String modelId);

  /// Downloads the model named by [consent] (and the VAD model when needed). Nothing is
  /// downloaded without a [UserConsent] built from the exact disclosure shown.
  Stream<ModelDownloadProgress> downloadModel({required UserConsent consent});

  /// Cancels the running download (keeps the partial file).
  Future<void> cancelDownload();

  /// Deletes every model. Blocked while a job runs: throws [StateError] (the UI disables the
  /// action while [activeJob] is non-null). The next use asks for consent again.
  Future<void> deleteModel();

  /// Deletes one model; blocked while a job runs like [deleteModel].
  Future<void> deleteModelById(String modelId);

  /// Memory, disk and download checks before starting.
  Future<TranscriptionPreflight> preflight(TranscriptionRequest request);

  /// Starts a job. One job at a time (a second call while [activeJob] is non-null throws
  /// [StateError]); the job waits while an export runs ([PauseReason.waitingForExport]). Failures
  /// surface on [TranscriptionJob.result], never synchronously.
  TranscriptionJob start(TranscriptionRequest request);

  /// Instant "Regenerate → re-split" from cached transcripts.
  Future<List<SubtitleCueDraft>> resegment(CaptionProvenance provenance, SegmentationSettings settings, TimelineView timeline);

  /// The running job (tasks sheet, leave-editor guard).
  TranscriptionJob? get activeJob;

  /// A job of [project] that can resume after the app was killed.
  Future<ResumableTranscription?> resumableFor(ProjectId project);

  /// Storage used (Settings › Storage).
  Future<SpeechStorageUsage> storage();

  /// Model status and job events.
  Stream<TranscriptionEvent> get events;
}
