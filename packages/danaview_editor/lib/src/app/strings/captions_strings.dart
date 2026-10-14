// OWNER: UX-37
//
// Copy of the Auto captions flow (ai.md §11.3, ux.md §12, D-19/D-20): the configure step, the
// language picker, the speech-model consent and download, job progress, the low-confidence language
// choice, the result toast and plain copy for every `TranscriptionFailure` and every
// `ModelDownloadFailureKind` (ARCH §16.5). Sizes and hosts always come from the catalog or the
// consent disclosure, never from literals here. No copy contains transcript text or paths.

import 'package:danaview_editor_core/model.dart' show SegmentationPreset;
import 'package:danaview_transcription/danaview_transcription.dart';

/// A failure's copy: what happened, then what to do next.
final class CaptionsFailureCopy {
  /// Creates the copy.
  const CaptionsFailureCopy(this.title, this.message);

  /// One line: what happened.
  final String title;

  /// The next step.
  final String message;
}

/// Copy of the Auto captions flow.
abstract final class CaptionsStrings {
  // ---- Sheet ---------------------------------------------------------------------------------

  /// Sheet title (and the action label).
  static const String title = 'Auto captions';

  /// While support and models are checked.
  static const String checking = 'Checking this device…';

  /// Close button.
  static const String close = 'Close';

  /// Cancel button.
  static const String cancel = 'Cancel';

  /// Back button (from a failure to the configure step).
  static const String back = 'Back';

  /// Retry button.
  static const String tryAgain = 'Try again';

  /// Why the action is disabled before the project has opened.
  static const String notReady = 'Auto captions are available when the project has opened.';

  /// Why the action is disabled in a read-only project.
  static const String readOnly = "This project is read-only, so captions can't be added.";

  // ---- Configure step ------------------------------------------------------------------------

  /// Spoken label of the step indicator of the configure step.
  static const String stepConfigure = 'Step 1 of 2';

  /// Spoken label of the step indicator of the consent step.
  static const String stepConsent = 'Step 2 of 2';

  /// Language row label.
  static const String spokenLanguage = 'Spoken language';

  /// The secondary "Detect automatically" choice (D-19).
  static const String detectAutomatically = 'Detect automatically';

  /// Subtitle of "Detect automatically".
  static const String detectHint = 'Danaview listens first and asks you if it isn’t sure.';

  /// Quality label.
  static const String quality = 'Quality';

  /// Tier name.
  static String tierName(SpeechModelTier tier) => switch (tier) {
        SpeechModelTier.fast => 'Fast',
        SpeechModelTier.balanced => 'Balanced',
        SpeechModelTier.accurate => 'Accurate',
      };

  /// Tier chip label: "Balanced · 57 MB", or "Balanced · Ready" when installed.
  static String tierLabel(SpeechModelSpec spec, {required bool ready}) => '${tierName(spec.tier)} · ${ready ? 'Ready' : megabytes(spec.bytes)}';

  /// "Captions from" label.
  static const String captionsFrom = 'Captions from';

  /// Scope: the selected clip(s).
  static String selectionScope(int clips) => clips == 1 ? 'This clip' : 'Selected clips';

  /// Scope: the whole timeline.
  static const String wholeVideo = 'Whole video';

  /// Layout label.
  static const String layout = 'Layout';

  /// Layout preset name.
  static String presetName(SegmentationPreset preset) => switch (preset) {
        SegmentationPreset.standard => 'Standard (2 lines)',
        SegmentationPreset.singleLine => 'Single line',
        SegmentationPreset.shortPhrases => 'Short phrases',
      };

  /// Replace switch.
  static const String replacePrevious = 'Replace previous auto captions';

  /// Replace switch subtitle.
  static const String replacePreviousHint = 'Your edits to those captions will be replaced.';

  /// Advanced section toggle.
  static const String advanced = 'Advanced';

  /// Audio tracks heading inside Advanced.
  static const String audioTracks = 'Audio to listen to';

  /// Subtitle of a music track switch.
  static const String musicTrack = 'Music, off by default';

  /// Max characters per line.
  static const String maxCharsPerLine = 'Max characters per line';

  /// Reading speed.
  static const String readingSpeed = 'Reading speed';

  /// Reading speed unit.
  static const String charsPerSecond = 'chars/s';

  /// Sound descriptions switch.
  static const String includeSoundDescriptions = 'Include sound descriptions';

  /// Sound descriptions subtitle.
  static const String soundDescriptionsHint = 'Adds things like [music] and [laughter].';

  /// Footer note.
  static const String onDeviceNote = 'Captions are created on this device. Your video and audio are never uploaded.';

  /// Primary button.
  static const String createCaptions = 'Create captions';

  /// Shown on the primary button while the checks before starting run.
  static const String starting = 'Starting…';

  // ---- Language picker -----------------------------------------------------------------------

  /// Picker heading.
  static const String chooseLanguage = 'Choose the spoken language';

  /// Search hint.
  static const String searchLanguages = 'Search languages';

  /// Recent section.
  static const String recent = 'Recent';

  /// Device language section.
  static const String deviceLanguage = 'Your device language';

  /// All languages section.
  static const String allLanguages = 'All languages';

  /// No search result.
  static const String noLanguageFound = 'No language matches your search.';

  // ---- Consent -------------------------------------------------------------------------------

  /// Consent title.
  static const String consentTitle = 'Download the speech model?';

  /// Consent title when the installed model is damaged.
  static const String consentTitleCorrupt = 'The speech model is damaged. Download it again?';

  /// Consent body with the size and host from the disclosure.
  static String consentBody(ConsentDisclosure d) =>
      "Auto captions use a speech-recognition model that runs on this device. It's a one-time download of "
      '${megabytes(d.totalBytes)} from Hugging Face (${d.host}). Your video, audio and captions stay on this device.';

  /// Details heading.
  static const String details = 'Download details';

  /// File row label.
  static const String fileLabel = 'File';

  /// File row value.
  static String fileValue(ConsentDisclosure d) => d.includesVad ? '${d.fileName} and a voice-detection model' : d.fileName;

  /// Size row label.
  static const String sizeLabel = 'Size';

  /// Size row value (exact bytes in the spoken text).
  static String sizeValue(ConsentDisclosure d) => megabytes(d.totalBytes);

  /// Host row label.
  static const String hostLabel = 'From';

  /// Host row value.
  static String hostValue(ConsentDisclosure d) => '${d.host} (downloads come from ${d.cdnHost})';

  /// Checksum row label.
  static const String checksumLabel = 'SHA-256';

  /// Free-space problem.
  static String notEnoughSpace(int bytes) => 'Not enough space: you need ${megabytes(bytes)} free.';

  /// Privacy link.
  static const String privacyPolicy = 'Privacy Policy';

  /// Secondary consent button.
  static const String notNow = 'Not now';

  /// Primary consent button with the exact size of the disclosure.
  static String download(ConsentDisclosure d) => 'Download ${megabytes(d.totalBytes)}';

  /// Primary consent button when the model is damaged.
  static String downloadAgain(ConsentDisclosure d) => 'Download again · ${megabytes(d.totalBytes)}';

  // ---- Download ------------------------------------------------------------------------------

  /// Download phase line.
  static String downloadLine(ModelDownloadProgress p, {required bool resumed}) => switch (p.phase) {
        ModelDownloadPhase.preparing => resumed ? resumingDownload : preparingDownload,
        ModelDownloadPhase.downloading => 'Downloading speech model… ${ofMegabytes(p.received, p.total)}',
        ModelDownloadPhase.verifying => 'Checking the download…',
        ModelDownloadPhase.finishing => 'Finishing up…',
      };

  /// Before the first byte.
  static const String preparingDownload = 'Preparing the download…';

  /// Before the first byte of a resumed download.
  static const String resumingDownload = 'Resuming the download…';

  /// Spoken label of the download bar.
  static const String downloadingLabel = 'Downloading speech model';

  /// "23 of 57 MB".
  static String ofMegabytes(int received, int total) => '${(received / _mib).floor()} of ${megabytes(total)}';

  /// Rate under the bar.
  static String rate(double bytesPerSecond) =>
      bytesPerSecond >= _mib ? '${(bytesPerSecond / _mib).toStringAsFixed(1)} MB/s' : '${(bytesPerSecond / 1024).round()} KB/s';

  /// Background note under the download.
  static const String downloadContinues = 'You can close this sheet. The download continues while Danaview is open.';

  /// Task row label of the download.
  static const String downloadTask = 'Downloading speech model';

  // ---- Running -------------------------------------------------------------------------------

  /// Task row label of the job.
  static const String jobTask = 'Auto captions';

  /// Phase line of a progress sample.
  static String phaseLine(TranscriptionProgress p) => switch (p.phase) {
        TranscriptionPhase.preparing => 'Preparing audio',
        TranscriptionPhase.downloadingModel => 'Downloading speech model',
        TranscriptionPhase.extractingAudio =>
          p.unitCount > 1 ? 'Preparing audio (${p.unitIndex + 1} of ${p.unitCount})' : 'Preparing audio',
        TranscriptionPhase.loadingModel => 'Loading speech model',
        TranscriptionPhase.detectingLanguage => 'Detecting language',
        TranscriptionPhase.needsLanguage => 'Waiting for your choice',
        TranscriptionPhase.transcribing => _creating(p),
        TranscriptionPhase.segmenting || TranscriptionPhase.done => 'Finishing up',
      };

  static String _creating(TranscriptionProgress p) {
    final percent = '${(p.fraction.clamp(0, 1) * 100).round()}%';
    final eta = p.eta;
    return eta == null ? 'Creating captions · $percent' : 'Creating captions · $percent · ${timeLeft(eta)}';
  }

  /// "about 2 min left".
  static String timeLeft(Duration d) {
    if (d.inSeconds < 60) return 'less than a minute left';
    final minutes = (d.inSeconds / 60).round();
    return 'about $minutes min left';
  }

  /// Spoken progress: "Creating captions, 42 percent".
  static String spokenProgress(double fraction) => 'Creating captions, ${(fraction.clamp(0, 1) * 100).round()} percent';

  /// Paused line.
  static String pausedLine(PauseReason reason) => switch (reason) {
        PauseReason.background => 'Paused while Danaview is in the background',
        PauseReason.thermal => 'Paused while your device cools down',
        PauseReason.exportRunning || PauseReason.waitingForExport => 'Waiting for the export to finish',
      };

  /// Hide button (keeps running).
  static const String hide = 'Hide';

  /// Note under the running job.
  static const String keepsRunning = 'Hide keeps Auto captions running. Find it under Tasks.';

  /// Confirm cancelling after more than 30 s of work.
  static const String cancelConfirmTitle = 'Stop Auto captions?';

  /// Confirm message.
  static const String cancelConfirmMessage = 'No captions are added. The work done so far is kept, so starting again is faster.';

  /// Confirm button.
  static const String stop = 'Stop';

  /// Keep going button.
  static const String keepGoing = 'Keep going';

  // ---- Needs language ------------------------------------------------------------------------

  /// Question.
  static const String whichLanguage = 'Which language is spoken?';

  /// Explanation.
  static const String notSure = "Danaview isn't sure. Choose the language you hear.";

  /// Candidate chip label: "Hindi 62%".
  static String candidate(LanguageProbability c) => '${languageName(c.code)} ${(c.p.clamp(0, 1) * 100).round()}%';

  /// Opens the full picker.
  static const String otherLanguage = 'Other language…';

  /// Continue button.
  static const String continueLabel = 'Continue';

  // ---- Done ----------------------------------------------------------------------------------

  /// Result toast.
  static String added(TranscriptionSummary s) {
    final n = s.cues == 1 ? '1 caption' : '${s.cues} captions';
    final skipped = s.skipped.length;
    if (skipped > 0) return 'Added $n. ${skipped == 1 ? '1 clip was' : '$skipped clips were'} skipped';
    return 'Added $n (${languageName(s.language)})';
  }

  /// Name of a generated lane: "Captions (Spanish) · Auto".
  static String trackName(String language) => 'Captions (${languageName(language)}) · Auto';

  /// The English name of a whisper code or BCP-47 tag, or the tag itself.
  static String languageName(String codeOrTag) =>
      languageForWhisperCode(codeOrTag)?.englishName ?? languageForLocale(codeOrTag)?.englishName ?? codeOrTag;

  // ---- Failures ------------------------------------------------------------------------------

  /// Unsupported device (also [TranscriptionUnsupported]).
  static const CaptionsFailureCopy unsupported =
      CaptionsFailureCopy("Auto captions aren't available on this device", 'You can still add captions yourself in the Captions panel.');

  /// The result could not be added to the project.
  static const CaptionsFailureCopy notApplied =
      CaptionsFailureCopy("The captions couldn't be added", "Your project didn't change. Try again.");

  /// Copy for [failure], or null for a cancellation (silent).
  static CaptionsFailureCopy? failure(TranscriptionFailure failure) => switch (failure) {
        UnsupportedDeviceFailure() => unsupported,
        ModelMissingFailure() => const CaptionsFailureCopy("The speech model isn't downloaded", 'Download it to create captions.'),
        ModelDownloadFailure(:final kind) => downloadFailed(kind),
        ModelCorruptFailure() => const CaptionsFailureCopy('The speech model is damaged', 'Download it again to create captions.'),
        InsufficientMemoryFailure(:final suggestedTier) => CaptionsFailureCopy(
            'Not enough memory for this quality',
            suggestedTier == null ? 'Close other apps and try again.' : 'Close other apps, or choose ${tierName(suggestedTier)}.',
          ),
        DiskFullFailure() => const CaptionsFailureCopy('Not enough free space', 'Free up space on this device, then try again.'),
        MediaOfflineFailure() => const CaptionsFailureCopy("A clip's media is missing", 'Relink the missing media, then try again.'),
        NoAudioFailure() => const CaptionsFailureCopy('No audio to caption', "There's no audio to caption in this part of the video."),
        UnsupportedAudioFailure() =>
          const CaptionsFailureCopy("This audio format isn't supported", 'Try a different clip, or add captions yourself.'),
        AudioDecodeFailure() => const CaptionsFailureCopy("The audio couldn't be read", 'Try again. If it keeps happening, try a different clip.'),
        NoSpeechFailure() => const CaptionsFailureCopy('No speech found', "We couldn't hear anyone speaking in the selected clips."),
        InferenceFailure() => const CaptionsFailureCopy('Auto captions stopped', 'Something went wrong while creating captions. Try again.'),
        TranscriptionInterrupted() => const CaptionsFailureCopy('Auto captions were interrupted', 'The work done so far is kept. Try again to continue.'),
        TranscriptionCancelled() => null,
      };

  /// Copy of a failed download (ai.md §11.3), sizes from the catalog.
  static CaptionsFailureCopy downloadFailed(ModelDownloadFailureKind kind) => switch (kind) {
        ModelDownloadFailureKind.offline =>
          const CaptionsFailureCopy("You're offline", 'Connect to the internet to download the speech model.'),
        ModelDownloadFailureKind.timeout ||
        ModelDownloadFailureKind.server =>
          const CaptionsFailureCopy('The download stopped', "The download server isn't responding. Try again later."),
        ModelDownloadFailureKind.interrupted =>
          const CaptionsFailureCopy('The download was interrupted', 'What was downloaded is kept. Try again to continue.'),
        ModelDownloadFailureKind.secureConnection => const CaptionsFailureCopy(
            "Couldn't open a secure connection",
            'On public Wi-Fi, sign in to the network first.',
          ),
        ModelDownloadFailureKind.diskFull => const CaptionsFailureCopy('Not enough free space', 'Free up space for the speech model, then try again.'),
        ModelDownloadFailureKind.checksumMismatch ||
        ModelDownloadFailureKind.sizeMismatch =>
          const CaptionsFailureCopy('The download was damaged', 'Try again.'),
        ModelDownloadFailureKind.cancelled => const CaptionsFailureCopy('Download cancelled', "Start it again when you're ready."),
        ModelDownloadFailureKind.consentMismatch =>
          const CaptionsFailureCopy('The speech model changed', 'Review the download details again before downloading.'),
      };

  /// Button that switches to a smaller tier after a memory failure.
  static String useTier(SpeechModelTier tier) => 'Use ${tierName(tier)}';

  /// Button that goes back to the consent step after a corrupt model or failed download.
  static const String reviewDownload = 'Download again';

  // ---- Sizes ---------------------------------------------------------------------------------

  static const int _mib = 1024 * 1024;

  /// Whole megabytes as the catalog sizes are shown ("57 MB").
  static String megabytes(int bytes) => '${(bytes / _mib).round()} MB';
}
