// OWNER: AI-08
//
// FakeTranscriptionService: scriptable phases, failures, download progress and resumable jobs
// for widget tests (UX-37, UX-38) and the INT-04 wiring tests. Behaves like the real service where
// the contract is observable: tier gating by RAM, a download only with a consent that equals the
// catalog disclosure, one active job, delete blocked while a job runs, 7-day job expiry.
//
// Two ways to drive a job: manually (`emit`, `finish`, `fail`, `waitForLanguage`) or by playing a
// script (`play`, or `FakeTranscriptionService.autoPlay`) built from [FakeJobScripts].

library;

import 'dart:async';

import 'package:danaview_editor_core/model.dart';

import 'danaview_transcription.dart';

// ---------------------------------------------------------------------------------------------
// Scripts
// ---------------------------------------------------------------------------------------------

/// One step of a scripted fake job.
sealed class FakeJobStep {
  const FakeJobStep();
}

/// Emits a progress sample.
final class FakeEmit extends FakeJobStep {
  /// Creates the step.
  const FakeEmit(this.progress);

  /// The sample.
  final TranscriptionProgress progress;
}

/// Waits (uses a real timer; wrap in `fakeAsync` or `tester.pump` as usual).
final class FakeWait extends FakeJobStep {
  /// Creates the step.
  const FakeWait(this.duration);

  /// How long.
  final Duration duration;
}

/// Emits the `needsLanguage` phase with [candidates] and waits for `provideLanguage`.
final class FakeAwaitLanguage extends FakeJobStep {
  /// Creates the step.
  const FakeAwaitLanguage(this.candidates);

  /// Top candidates shown by the picker.
  final List<LanguageProbability> candidates;
}

/// Ends the job with a failure.
final class FakeFail extends FakeJobStep {
  /// Creates the step.
  const FakeFail(this.failure);

  /// The failure.
  final TranscriptionFailure failure;
}

/// Ends the job successfully ([result] null = [FakeTranscriptionService.sampleResult]).
final class FakeFinish extends FakeJobStep {
  /// Creates the step.
  const FakeFinish([this.result]);

  /// The result, or null for the sample result of the request.
  final TranscriptionResult? result;
}

/// Ready-made scripts.
abstract final class FakeJobScripts {
  /// Every [TranscriptionPhase] in pipeline order. [download] adds `downloadingModel`, [detect]
  /// adds `detectingLanguage`, and [askLanguage] adds `needsLanguage` (low-confidence detection).
  /// Ends with `done` and a finish step.
  static List<FakeJobStep> fullRun({bool download = false, bool detect = false, bool askLanguage = false}) {
    FakeEmit phase(TranscriptionPhase p, double f, {int unit = 0, List<LanguageProbability>? candidates}) => FakeEmit(
          TranscriptionProgress(
            phase: p,
            fraction: f,
            unitIndex: unit,
            unitCount: 1,
            processed: (f * 60 * microsPerSecond).round(),
            total: 60 * microsPerSecond,
            eta: p == TranscriptionPhase.transcribing ? Duration(seconds: ((1 - f) * 30).round()) : null,
            languageCandidates: candidates,
          ),
        );
    return [
      phase(TranscriptionPhase.preparing, 0),
      if (download) phase(TranscriptionPhase.downloadingModel, 0.02),
      phase(TranscriptionPhase.extractingAudio, 0.05),
      phase(TranscriptionPhase.loadingModel, 0.08),
      if (detect) phase(TranscriptionPhase.detectingLanguage, 0.1),
      if (askLanguage) const FakeAwaitLanguage([LanguageProbability('hi', 0.45), LanguageProbability('ur', 0.4), LanguageProbability('en', 0.05)]),
      phase(TranscriptionPhase.transcribing, 0.25),
      phase(TranscriptionPhase.transcribing, 0.5),
      phase(TranscriptionPhase.transcribing, 1),
      phase(TranscriptionPhase.segmenting, 1),
      phase(TranscriptionPhase.done, 1),
      const FakeFinish(),
    ];
  }

  /// A run that fails with [failure] after preparing.
  static List<FakeJobStep> failing(TranscriptionFailure failure) => [
        const FakeEmit(TranscriptionProgress(phase: TranscriptionPhase.preparing, fraction: 0)),
        FakeFail(failure),
      ];
}

// ---------------------------------------------------------------------------------------------
// Job
// ---------------------------------------------------------------------------------------------

/// A job the test drives with [emit], [finish] and [fail], or plays from a script.
final class FakeTranscriptionJob implements TranscriptionJob {
  /// Creates a job.
  FakeTranscriptionJob(this.id, this.request, {this.resumedFromFraction});

  @override
  final String id;

  /// The request it was started with.
  final TranscriptionRequest request;

  /// Fraction a resumed job continues from (null for a fresh job).
  final double? resumedFromFraction;

  final StreamController<TranscriptionProgress> _progress = StreamController<TranscriptionProgress>.broadcast();
  final Completer<TranscriptionResult> _result = Completer<TranscriptionResult>();
  Completer<String>? _language;

  /// Language codes provided by the UI.
  final List<String> providedLanguages = [];

  /// Samples emitted so far (for assertions on phase order).
  final List<TranscriptionProgress> emitted = [];

  /// Whether [cancel] was called.
  bool cancelled = false;

  /// Result producer for [FakeFinish] with a null result (set by the service).
  TranscriptionResult Function()? sampleResult;

  /// Whether the job has ended (finished, failed or cancelled).
  bool get isDone => _result.isCompleted;

  @override
  Stream<TranscriptionProgress> get progress => _progress.stream;

  @override
  Future<TranscriptionResult> get result => _result.future;

  /// Emits a progress sample.
  void emit(TranscriptionProgress p) {
    if (isDone) return;
    emitted.add(p);
    _progress.add(p);
  }

  /// Completes with [result].
  void finish(TranscriptionResult result) {
    if (!_result.isCompleted) _result.complete(result);
    unawaited(_progress.close());
  }

  /// Fails with [failure].
  void fail(TranscriptionFailure failure) {
    if (!_result.isCompleted) _result.completeError(failure);
    unawaited(_progress.close());
  }

  /// Emits `needsLanguage` with [candidates] and completes with the code the UI provides.
  Future<String> waitForLanguage(List<LanguageProbability> candidates) {
    final c = _language = Completer<String>();
    emit(TranscriptionProgress(phase: TranscriptionPhase.needsLanguage, fraction: 0.1, languageCandidates: candidates));
    return c.future;
  }

  /// Runs [steps] in order; stops early when the job ends or is cancelled. Completes when the
  /// script is exhausted or the job ended.
  Future<void> play(List<FakeJobStep> steps) async {
    for (final step in steps) {
      if (isDone) return;
      switch (step) {
        case FakeEmit(:final progress):
          emit(progress);
        case FakeWait(:final duration):
          await Future<void>.delayed(duration);
        case FakeAwaitLanguage(:final candidates):
          await Future.any<Object?>([waitForLanguage(candidates), _result.future.then<Object?>((_) => null, onError: (_) => null)]);
        case FakeFail(:final failure):
          fail(failure);
        case FakeFinish(:final result):
          final r = result ?? sampleResult?.call();
          if (r == null) throw StateError('FakeFinish without a result and no sampleResult');
          finish(r);
      }
      // Let listeners see each step before the next one.
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  void cancel() {
    if (isDone) return;
    cancelled = true;
    fail(const TranscriptionCancelled());
  }

  @override
  void provideLanguage(String code) {
    providedLanguages.add(code);
    final c = _language;
    if (c != null && !c.isCompleted) c.complete(code);
  }
}

// ---------------------------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------------------------

/// A scriptable [TranscriptionService].
final class FakeTranscriptionService implements TranscriptionService {
  /// Creates the fake: supported, [physicalRamBytes] of RAM (8 GiB: every tier), nothing installed.
  FakeTranscriptionService({
    this.physicalRamBytes = 8 * 1024 * 1024 * 1024,
    this.is64Bit = true,
    this.isLowRamDevice = false,
    this.supportState,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Device RAM driving tier gating (`offers`, `defaultModel`).
  int physicalRamBytes;

  /// 64-bit process (32-bit has no tiers).
  bool is64Bit;

  /// Android `isLowRamDevice` (Fast only).
  bool isLowRamDevice;

  /// Reported support; null = supported with the tiers [physicalRamBytes] allows.
  TranscriptionSupport? supportState;

  final DateTime Function() _clock;

  /// Status per model id (missing when absent).
  final Map<String, SpeechModelStatus> statuses = {};

  /// Progress samples [downloadModel] emits before marking the model ready.
  List<ModelDownloadProgress> scriptedDownload = const [];

  /// Failure [downloadModel] ends with instead of succeeding (after the scripted samples).
  TranscriptionFailure? downloadFailure;

  /// Consents received (the call site is restricted in production code).
  final List<UserConsent> consents = [];

  /// Jobs started.
  final List<FakeTranscriptionJob> jobs = [];

  /// Resumable jobs by project (expire after 7 days, ARCH §16.5).
  final Map<ProjectId, ResumableTranscription> resumable = {};

  /// Drafts [resegment] returns.
  List<SubtitleCueDraft> resegmentDrafts = const [];

  /// Arguments of every [resegment] call.
  final List<(CaptionProvenance, SegmentationSettings)> resegmentCalls = [];

  /// Overrides [preflight] when set.
  TranscriptionPreflight? preflightOverride;

  /// Failure every started job ends with, as `start` would report a missing model or a bad scope.
  TranscriptionFailure? startFailure;

  /// Play a script on every started job: [scriptFor] when set, else [FakeJobScripts.fullRun].
  bool autoPlay = false;

  /// Script builder for [autoPlay].
  List<FakeJobStep> Function(TranscriptionRequest request)? scriptFor;

  /// Bytes the storage report returns besides installed models.
  SpeechStorageUsage extraStorage = const SpeechStorageUsage();

  /// Whether [cancelDownload] was called during the last download.
  bool downloadCancelled = false;

  final StreamController<TranscriptionEvent> _events = StreamController<TranscriptionEvent>.broadcast();
  var _n = 0;

  // -- support, offers ---------------------------------------------------------------------

  @override
  List<TranscriptionLanguage> get languages => whisperLanguages;

  @override
  Future<TranscriptionSupport> support() async =>
      supportState ?? TranscriptionSupported(SpeechModelCatalog.availableTiers(physicalRamBytes: physicalRamBytes, is64Bit: is64Bit, isLowRamDevice: isLowRamDevice));

  @override
  List<SpeechModelOffer> get offers {
    final tiers = SpeechModelCatalog.availableTiers(physicalRamBytes: physicalRamBytes, is64Bit: is64Bit, isLowRamDevice: isLowRamDevice);
    final recommended = _recommended(tiers);
    return [
      for (final m in SpeechModelCatalog.models)
        SpeechModelOffer(
          spec: m,
          available: tiers.contains(m.tier),
          recommended: m.tier == recommended,
          unavailableReason: tiers.contains(m.tier) ? null : 'Needs a device with more memory',
        ),
    ];
  }

  SpeechModelTier _recommended(List<SpeechModelTier> tiers) {
    final wanted = SpeechModelCatalog.recommendedTier(physicalRamBytes: physicalRamBytes, minimalDevice: isLowRamDevice);
    if (tiers.isEmpty || tiers.contains(wanted)) return wanted;
    return tiers.first;
  }

  @override
  SpeechModelSpec get defaultModel =>
      SpeechModelCatalog.specOf(_recommended(SpeechModelCatalog.availableTiers(physicalRamBytes: physicalRamBytes, is64Bit: is64Bit, isLowRamDevice: isLowRamDevice)));

  // -- models --------------------------------------------------------------------------------

  @override
  Future<SpeechModelStatus> modelStatus() => modelStatusOf(defaultModel.id);

  @override
  Future<SpeechModelStatus> modelStatusOf(String modelId) async => statuses[modelId] ?? const SpeechModelMissing();

  @override
  Stream<ModelDownloadProgress> downloadModel({required UserConsent consent}) async* {
    consents.add(consent);
    downloadCancelled = false;
    if (!consent.disclosure.matchesCatalog) throw const ModelDownloadFailure(ModelDownloadFailureKind.consentMismatch);
    final spec = SpeechModelCatalog.byId(consent.disclosure.modelId)!;
    for (final p in scriptedDownload) {
      if (downloadCancelled) {
        statuses.remove(spec.id);
        _events.add(ModelStatusChanged(spec.id, const SpeechModelMissing()));
        throw const ModelDownloadFailure(ModelDownloadFailureKind.cancelled);
      }
      final status = SpeechModelDownloading(p);
      statuses[spec.id] = status;
      _events.add(ModelStatusChanged(spec.id, status));
      yield p;
    }
    final failure = downloadFailure;
    if (failure != null) {
      statuses.remove(spec.id);
      _events.add(ModelStatusChanged(spec.id, const SpeechModelMissing()));
      throw failure;
    }
    final ready = SpeechModelReady(InstalledSpeechModel(spec: spec, installedAt: _clock().toUtc()));
    statuses[spec.id] = ready;
    _events.add(ModelStatusChanged(spec.id, ready));
  }

  @override
  Future<void> cancelDownload() async {
    downloadCancelled = true;
  }

  @override
  Future<void> deleteModel() async {
    _requireNoJob();
    final ids = statuses.keys.toList();
    statuses.clear();
    for (final id in ids) {
      _events.add(ModelStatusChanged(id, const SpeechModelMissing()));
    }
  }

  @override
  Future<void> deleteModelById(String modelId) async {
    _requireNoJob();
    if (statuses.remove(modelId) != null) _events.add(ModelStatusChanged(modelId, const SpeechModelMissing()));
  }

  void _requireNoJob() {
    if (activeJob != null) throw StateError('A model cannot be deleted while a transcription job runs');
  }

  // -- jobs ----------------------------------------------------------------------------------

  @override
  Future<TranscriptionPreflight> preflight(TranscriptionRequest request) async {
    final override = preflightOverride;
    if (override != null) return override;
    final s = await support();
    if (s is TranscriptionUnsupported) return TranscriptionPreflight(ok: false, failure: UnsupportedDeviceFailure(s.reason));
    final spec = SpeechModelCatalog.byId(request.modelId);
    if (spec == null || !spec.isAvailableOn(physicalRamBytes)) {
      return TranscriptionPreflight(ok: false, failure: InsufficientMemoryFailure(suggestedTier: SpeechModelTier.fast));
    }
    final installed = statuses[request.modelId] is SpeechModelReady;
    return TranscriptionPreflight(
      ok: true,
      downloadBytes: installed ? 0 : spec.bytes + SpeechModelCatalog.vad.bytes,
      estimatedDuration: const Duration(seconds: 30),
    );
  }

  @override
  TranscriptionJob start(TranscriptionRequest request) {
    if (activeJob != null) throw StateError('One transcription job at a time');
    final record = resumableForSync(request.project);
    final job = FakeTranscriptionJob('tj-${_n++}', request, resumedFromFraction: record?.doneFraction)..sampleResult = () => sampleResult(request);
    jobs.add(job);
    _events.add(JobStarted(job));
    unawaited(job.result.then<void>((_) => resumable.remove(request.project), onError: (Object _) {}).whenComplete(() => _events.add(JobEnded(job.id))));
    final failure = startFailure;
    if (failure != null) {
      scheduleMicrotask(() => job.fail(failure));
    } else if (autoPlay) {
      final steps = scriptFor?.call(request) ?? FakeJobScripts.fullRun(detect: request.language is AutoLanguage);
      unawaited(job.play(steps));
    }
    return job;
  }

  /// Marks [job] interrupted (app killed): the job fails with [TranscriptionInterrupted] and a
  /// resumable record at [doneFraction] is kept for 7 days.
  void interrupt(FakeTranscriptionJob job, {double doneFraction = 0.4}) {
    resumable[job.request.project] = ResumableTranscription(
      jobId: job.id,
      project: job.request.project,
      doneFraction: doneFraction,
      createdAt: _clock().toUtc(),
    );
    job.fail(const TranscriptionInterrupted());
  }

  /// The resumable record of [project] unless it is older than 7 days.
  ResumableTranscription? resumableForSync(ProjectId project) {
    final r = resumable[project];
    if (r == null) return null;
    if (_clock().toUtc().difference(r.createdAt) > const Duration(days: 7)) {
      resumable.remove(project);
      return null;
    }
    return r;
  }

  @override
  Future<ResumableTranscription?> resumableFor(ProjectId project) async => resumableForSync(project);

  @override
  Future<List<SubtitleCueDraft>> resegment(CaptionProvenance provenance, SegmentationSettings settings, TimelineView timeline) async {
    resegmentCalls.add((provenance, settings));
    return resegmentDrafts;
  }

  @override
  TranscriptionJob? get activeJob {
    for (final j in jobs.reversed) {
      if (!j.isDone) return j;
    }
    return null;
  }

  @override
  Future<SpeechStorageUsage> storage() async => SpeechStorageUsage(
        modelBytes: statuses.values.whereType<SpeechModelReady>().fold(0, (a, s) => a + s.model.spec.bytes) + extraStorage.modelBytes,
        transcriptBytes: extraStorage.transcriptBytes,
        partialBytes: extraStorage.partialBytes,
      );

  @override
  Stream<TranscriptionEvent> get events => _events.stream;

  /// A plausible finished result for [request]: three cues on a 30 fps grid, provenance naming the
  /// request's model, language and segmentation.
  TranscriptionResult sampleResult(TranscriptionRequest request) {
    final spec = SpeechModelCatalog.byId(request.modelId) ?? SpeechModelCatalog.balanced;
    final code = switch (request.language) {
      FixedLanguage(:final code) => code,
      AutoLanguage() => 'en',
    };
    final bcp47 = languageForWhisperCode(code)?.bcp47 ?? code;
    const frame = 33333; // 1/30 s, rounded; the fake does not need the exact grid
    final drafts = [
      const SubtitleCueDraft(TimeRange(15 * frame, 75 * frame), 'Hello and welcome.'),
      const SubtitleCueDraft(TimeRange(78 * frame, 150 * frame), 'Today we are making\na short video.'),
      const SubtitleCueDraft(TimeRange(153 * frame, 210 * frame), 'Let us begin.'),
    ];
    final scope = request.scope;
    final provenance = CaptionProvenance(
      generator: 'whisper.cpp',
      engineVersion: '1.9.4',
      modelId: spec.id,
      modelSha256: spec.sha256,
      language: bcp47,
      languageDetected: request.language is AutoLanguage,
      languageConfidence: request.language is AutoLanguage ? 0.93 : null,
      segmentation: request.segmentation,
      scope: switch (scope) {
        ClipScope(:final item) => CaptionScopeData(clips: [item]),
        ItemsScope(:final items) => CaptionScopeData(clips: items.toList()),
        TimelineScope(:final tracks, :final range) => CaptionScopeData(tracks: tracks?.toList() ?? const [], range: range),
      },
      transcriptKeys: const ['fake-transcript-key'],
      generatedAt: _clock().toUtc(),
    );
    return TranscriptionResult(
      drafts: drafts,
      provenance: provenance,
      target: request.target,
      summary: TranscriptionSummary(cues: drafts.length, words: 11, language: bcp47),
    );
  }
}
