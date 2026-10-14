// OWNER: AI-13
//
// TranscriptionServiceImpl (ARCH §16.4-16.5, D-21, ai.md §8.1): the real Auto captions service.
// It never mutates the project: a job's result carries cue drafts and CaptionProvenance, which
// the editor applies as one history entry (`TranscriptionResult.toCommand`).
//
//   offers / defaultModel / support  tiers by RAM, availability per platform and ABI
//   preflight                        model present?, free space, memory >= 1.3 x tier peak
//   start                            one job at a time (PipelineJob)
//   resegment                        instant re-split from cached transcripts
//   activeJob / resumableFor         running job; job records (7-day expiry)
//   storage / events                 Settings > Storage contributor; model and job events
//
// Construct it, then `await initialize()` before use (INT-04): that starts the governor (device
// profile, signals) and sweeps stale records, temp files and work folders. No network request is
// made outside `downloadModel`, which needs a UserConsent.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

import '../catalog/speech_model_catalog.dart';
import '../contracts/consent.dart';
import '../contracts/failures.dart';
import '../contracts/ports.dart';
import '../contracts/timeline_view.dart';
import '../contracts/transcription_service.dart';
import '../governor/resource_governor.dart';
import '../languages/languages.dart';
import '../models_store/speech_model_store.dart';
import '../timeline/transcription_planner.dart';
import '../timeline/word_mapper.dart';
import '../transcript/job_records.dart';
import '../transcript/transcript_cache.dart';
import '../transcript/transcript_checkpoints.dart';
import '../transcript/transcript_key.dart';
import '../transcript/transcript_models.dart';
import 'caption_assembly.dart';
import 'job_progress.dart';
import 'pipeline_job.dart';
import 'pipeline_support.dart';

/// Bytes of 16 kHz mono s16 WAV per second of audio.
const int speechWavBytesPerSecond = 32000;

/// Free-space margin kept by every preflight (ai.md §6.1).
const int speechDiskMarginBytes = 64 * 1024 * 1024;

/// The Auto captions service.
final class TranscriptionServiceImpl implements TranscriptionService {
  /// Creates the service.
  ///
  /// [supportDirectory] is the app support directory (`<support>/danaview/speech/` lives inside).
  /// [openRuntime] opens the whisper runtime once ([WhisperRuntime.open] by default). [leases]
  /// keeps Android jobs alive in the background. Tests inject [clock], [delay], [newJobId] and
  /// [log].
  TranscriptionServiceImpl({
    required String supportDirectory,
    required SpeechModelStore store,
    required SpeechAudioExtractor extractor,
    required ResourceGovernor governor,
    Future<WhisperRuntime> Function()? openRuntime,
    BackgroundLeaseProvider? leases,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    String Function()? newJobId,
    TranscriptionLogSink log = developerTranscriptionLog,
    TranscriptionPlanner planner = const TranscriptionPlanner(),
    CaptionAssembler assembler = const CaptionAssembler(),
    Duration progressInterval = const Duration(milliseconds: 250),
    String leaseTitle = 'Creating captions',
    Duration workFolderMaxAge = const Duration(hours: 24),
  })  : paths = SpeechPaths(supportDirectory),
        _store = store,
        _governor = governor,
        _openRuntime = openRuntime ?? WhisperRuntime.open,
        _clock = clock ?? DateTime.now,
        _newJobId = newJobId ?? _randomJobId,
        _log = log,
        _planner = planner,
        _assembler = assembler,
        _workFolderMaxAge = workFolderMaxAge {
    final transcripts = Directory(paths.transcripts);
    cache = TranscriptCache(transcripts, clock: _clock);
    checkpoints = TranscriptCheckpoints(transcripts);
    records = JobRecordStore(Directory(paths.jobs), clock: _clock);
    _env = PipelineEnv(
      runtime: _runtime,
      store: store,
      extractor: extractor,
      governor: governor,
      paths: paths,
      cache: cache,
      checkpoints: checkpoints,
      records: records,
      leases: leases,
      clock: _clock,
      delay: delay ?? Future<void>.delayed,
      log: log,
      planner: planner,
      assembler: assembler,
      progressInterval: progressInterval,
      leaseTitle: leaseTitle,
    );
  }

  /// Folder layout.
  final SpeechPaths paths;

  /// Transcript cache (`<speech>/transcripts`).
  late final TranscriptCache cache;

  /// Checkpoints (next to the cache).
  late final TranscriptCheckpoints checkpoints;

  /// Job records (`<speech>/jobs`).
  late final JobRecordStore records;

  final SpeechModelStore _store;
  final ResourceGovernor _governor;
  final Future<WhisperRuntime> Function() _openRuntime;
  final DateTime Function() _clock;
  final String Function() _newJobId;
  final TranscriptionLogSink _log;
  final TranscriptionPlanner _planner;
  final CaptionAssembler _assembler;
  final Duration _workFolderMaxAge;
  late final PipelineEnv _env;

  final StreamController<TranscriptionEvent> _events = StreamController<TranscriptionEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  Future<WhisperRuntime>? _runtimeFuture;
  Future<void>? _initialized;
  PipelineJob? _active;
  bool _releaseAfterJob = false;

  static String _randomJobId() {
    final r = Random.secure();
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return 'job_${List.generate(16, (_) => alphabet[r.nextInt(alphabet.length)]).join()}';
  }

  Future<WhisperRuntime> _runtime() => _runtimeFuture ??= _openRuntime();

  /// Starts the governor and sweeps stale files. Idempotent; call before using the service.
  Future<void> initialize() => _initialized ??= _initialize();

  Future<void> _initialize() async {
    await _governor.start();
    _subs
      ..add(_governor.memoryWarnings.listen((_) => _onMemoryWarning()))
      ..add(_store.watch().listen((_) => unawaited(_emitModelStatuses()), onError: (Object _) {}));
    await _quietly(records.sweep);
    await _quietly(cache.clear);
    await _quietly(cache.sweepPartials);
    await _quietly(_sweepWork);
  }

  /// Stops listening (the running job is cancelled).
  Future<void> dispose() async {
    _active?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _events.close();
  }

  Future<void> _sweepWork() async {
    final dir = Directory(paths.work);
    if (!await dir.exists()) return;
    final cutoff = _clock().subtract(_workFolderMaxAge);
    await for (final e in dir.list()) {
      if (_active != null && p.basename(e.path) == _active!.id) continue;
      try {
        if ((await e.stat()).modified.isBefore(cutoff)) await e.delete(recursive: true);
      } on FileSystemException {
        // Gone already.
      }
    }
  }

  void _onMemoryWarning() {
    _log('memory.warning', const {});
    if (_active == null) {
      unawaited(_releaseIdleModels());
    } else {
      _releaseAfterJob = true;
    }
  }

  Future<void> _releaseIdleModels() async {
    final rt = _runtimeFuture;
    if (rt == null) return;
    await _quietly(() async => (await rt).releaseIdleModels());
  }

  Future<void> _emitModelStatuses() async {
    for (final m in SpeechModelCatalog.models) {
      final status = await _store.statusOf(m.id);
      if (!_events.isClosed) _events.add(ModelStatusChanged(m.id, status));
    }
  }

  // -------------------------------------------------------------------------------------------
  // Support and offers
  // -------------------------------------------------------------------------------------------

  @override
  List<TranscriptionLanguage> get languages => whisperLanguages;

  /// Tiers this device offers. Unknown RAM (no plugin) offers Fast and Balanced.
  List<SpeechModelTier> get availableTiers {
    final profile = _governor.profile;
    if (profile.physicalRamBytes <= 0) {
      return profile.is64Bit ? const [SpeechModelTier.fast, SpeechModelTier.balanced] : const [];
    }
    return SpeechModelCatalog.availableTiers(
      physicalRamBytes: profile.physicalRamBytes,
      is64Bit: profile.is64Bit,
      isLowRamDevice: profile.isLowRam,
    );
  }

  SpeechModelTier get _recommendedTier {
    final tiers = availableTiers;
    final ram = _governor.profile.physicalRamBytes;
    final preferred = ram <= 0 ? SpeechModelTier.balanced : SpeechModelCatalog.recommendedTier(physicalRamBytes: ram);
    if (tiers.contains(preferred)) return preferred;
    return tiers.isEmpty ? SpeechModelTier.fast : tiers.first;
  }

  @override
  Future<TranscriptionSupport> support() async {
    final runtime = await _runtime();
    if (runtime.support case WhisperUnsupported(:final reason)) return TranscriptionUnsupported(reason.name);
    final tiers = availableTiers;
    if (tiers.isEmpty) {
      return TranscriptionUnsupported(_governor.profile.is64Bit ? 'insufficientMemory' : 'abi');
    }
    return TranscriptionSupported(tiers);
  }

  @override
  List<SpeechModelOffer> get offers {
    final tiers = availableTiers;
    final recommended = _recommendedTier;
    return [
      for (final m in SpeechModelCatalog.models)
        SpeechModelOffer(
          spec: m,
          available: tiers.contains(m.tier),
          recommended: m.tier == recommended && tiers.contains(m.tier),
          unavailableReason: tiers.contains(m.tier) ? null : 'Needs a device with more memory',
        ),
    ];
  }

  @override
  SpeechModelSpec get defaultModel => SpeechModelCatalog.specOf(_recommendedTier);

  // -------------------------------------------------------------------------------------------
  // Models
  // -------------------------------------------------------------------------------------------

  @override
  Future<SpeechModelStatus> modelStatus() => modelStatusOf(defaultModel.id);

  @override
  Future<SpeechModelStatus> modelStatusOf(String modelId) => _store.statusOf(modelId);

  @override
  Stream<ModelDownloadProgress> downloadModel({required UserConsent consent}) {
    final download = _store.download(consent);
    final controller = StreamController<ModelDownloadProgress>();
    StreamSubscription<ModelDownloadProgress>? sub;
    controller.onListen = () {
      sub = download.progress.listen(controller.add, onError: (Object _) {});
      download.done.then((_) async {
        await sub?.cancel();
        await controller.close();
      }, onError: (Object e, StackTrace s) async {
        await sub?.cancel();
        controller.addError(e is ModelDownloadFailure ? e : const ModelDownloadFailure(ModelDownloadFailureKind.server), s);
        await controller.close();
      });
    };
    controller.onCancel = () => sub?.cancel();
    return controller.stream;
  }

  @override
  Future<void> cancelDownload() async => _store.activeDownload?.cancel();

  @override
  Future<void> deleteModel() async {
    if (_active != null) throw StateError('A transcription job is running');
    await _store.deleteAll();
    await _releaseIdleModels();
    await _emitModelStatuses();
  }

  @override
  Future<void> deleteModelById(String modelId) async {
    if (_active != null) throw StateError('A transcription job is running');
    await _store.delete(modelId);
    await _releaseIdleModels();
    await _emitModelStatuses();
  }

  // -------------------------------------------------------------------------------------------
  // Preflight
  // -------------------------------------------------------------------------------------------

  @override
  Future<TranscriptionPreflight> preflight(TranscriptionRequest request) async {
    final s = await support();
    if (s is TranscriptionUnsupported) return TranscriptionPreflight(ok: false, failure: UnsupportedDeviceFailure(s.reason));
    final tiers = (s as TranscriptionSupported).tiers;
    final spec = SpeechModelCatalog.byId(request.modelId);
    if (spec == null || spec.id == SpeechModelCatalog.vad.id) {
      return const TranscriptionPreflight(ok: false, failure: ModelMissingFailure());
    }
    if (!tiers.contains(spec.tier)) {
      return TranscriptionPreflight(
        ok: false,
        failure: InsufficientMemoryFailure(suggestedTier: ResourceGovernor.suggestSmallerTier(spec.tier, available: tiers)),
      );
    }

    final plan = _planner.plan(request.timeline(), request.scope);
    if (plan.isEmpty) return const TranscriptionPreflight(ok: false, failure: NoAudioFailure());

    final status = await _store.statusOf(spec.id);
    var downloadBytes = 0;
    if (status is! SpeechModelReady) {
      final inventory = await _store.inventory();
      downloadBytes = spec.bytes + (inventory.has(SpeechModelCatalog.vad.id) ? 0 : SpeechModelCatalog.vad.bytes);
    }

    final memory = await _governor.checkMemory(spec, available: tiers);
    if (memory != null) return TranscriptionPreflight(ok: false, failure: memory, downloadBytes: downloadBytes);

    // Audio still to transcribe (cache hits are free when the language is known).
    var missingUs = 0;
    for (final u in plan.units) {
      if (request.language case FixedLanguage(:final code)) {
        final key = TranscriptKey.compute(
          quickHash: u.mediaQuickHash,
          audioStream: u.audioStream,
          modelSha256: spec.sha256,
          language: code,
          vad: true,
        );
        TranscriptFile? hit;
        try {
          hit = await cache.lookup(key, u.sourceRange);
        } on Object {
          hit = null;
        }
        if (hit != null) continue;
      }
      missingUs += u.duration;
    }
    final wavBytes = (missingUs / 1000000 * speechWavBytesPerSecond).ceil();
    final needed = wavBytes + speechDiskMarginBytes + downloadBytes;
    if (!await _governor.hasDisk(paths.root, needed)) {
      return TranscriptionPreflight(ok: false, failure: const DiskFullFailure(), downloadBytes: downloadBytes);
    }
    final estimateUs = missingUs * priorRealTimeFactor(spec.tier) + (missingUs > 0 ? 2000000 : 0);
    return TranscriptionPreflight(
      ok: true,
      downloadBytes: downloadBytes,
      estimatedDuration: Duration(microseconds: estimateUs.round()),
    );
  }

  // -------------------------------------------------------------------------------------------
  // Jobs
  // -------------------------------------------------------------------------------------------

  @override
  TranscriptionJob start(TranscriptionRequest request) {
    if (_active != null) throw StateError('A transcription job is already running');
    final job = PipelineJob(id: _newJobId(), request: request, env: _env);
    _active = job;
    _log('job.start', {'model': request.modelId});
    if (!_events.isClosed) _events.add(JobStarted(job));
    job.result.then((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_active, job)) _active = null;
      if (!_events.isClosed) _events.add(JobEnded(job.id));
      if (_releaseAfterJob) {
        _releaseAfterJob = false;
        unawaited(_releaseIdleModels());
      }
    });
    job.start();
    return job;
  }

  @override
  TranscriptionJob? get activeJob => _active;

  /// Leaving the editor: cancels the running job; its checkpoint and record are kept so the same
  /// request resumes (ARCH §16.5).
  void onEditorClosed() => _active?.cancel();

  @override
  Future<ResumableTranscription?> resumableFor(ProjectId project) async {
    final records = await this.records.list();
    for (final r in records) {
      if (r.project != project || r.jobId == _active?.id) continue;
      return r.toResumable();
    }
    return null;
  }

  /// The request stored with a resumable job (JSON form), for the "Resume" action.
  Future<Map<String, Object?>?> resumableRequest(String jobId) async => (await records.read(jobId))?.request;

  /// Drops a resumable job ("Discard"): its record and checkpoints.
  Future<void> discardResumable(String jobId) async {
    final record = await records.read(jobId);
    if (record == null) return;
    for (final u in record.units) {
      if (TranscriptKey.isValid(u.transcriptKey)) await _quietly(() => checkpoints.delete(u.transcriptKey));
    }
    await records.delete(jobId);
  }

  // -------------------------------------------------------------------------------------------
  // Re-split
  // -------------------------------------------------------------------------------------------

  @override
  Future<List<SubtitleCueDraft>> resegment(CaptionProvenance provenance, SegmentationSettings settings, TimelineView timeline) async {
    final scope = transcriptionScopeOf(provenance.scope);
    final plan = _planner.plan(timeline, scope);
    if (plan.isEmpty) throw const NoAudioFailure();
    final language = whisperCodeOfBcp47(provenance.language);
    final words = <UnitWords>[];
    var missing = 0;
    for (final u in plan.units) {
      final key = TranscriptKey.compute(
        quickHash: u.mediaQuickHash,
        audioStream: u.audioStream,
        modelSha256: provenance.modelSha256,
        language: language,
        vad: true,
      );
      TranscriptFile? t;
      try {
        t = await cache.lookup(key, u.sourceRange) ?? await cache.lookup(key, u.coreRange);
      } on Object {
        t = null;
      }
      if (t == null) {
        missing++;
      } else {
        words.add(UnitWords.fromTranscript(u, t));
      }
    }
    if (missing > 0) throw CachedTranscriptsMissing(missing);
    final assembled = await _assembler.assemble(
      timeline: timeline,
      transcripts: words,
      languageCode: language,
      settings: settings,
      window: scopeWindow(scope),
    );
    _log('resegment.done', {'cues': assembled.drafts.length});
    return assembled.drafts;
  }

  // -------------------------------------------------------------------------------------------
  // Storage and events
  // -------------------------------------------------------------------------------------------

  @override
  Future<SpeechStorageUsage> storage() async {
    final models = await _store.measure();
    final transcripts = await cache.totalBytes();
    var partial = models.partialBytes;
    partial += await _folderBytes(Directory(paths.work), (_) => true);
    partial += await _folderBytes(Directory(paths.transcripts), (f) => f.endsWith('.partial.jsonl'));
    return SpeechStorageUsage(modelBytes: models.bytes - models.partialBytes, transcriptBytes: transcripts, partialBytes: partial);
  }

  static Future<int> _folderBytes(Directory dir, bool Function(String path) include) async {
    var n = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final e in dir.list(recursive: true)) {
        if (e is File && include(e.path)) n += await e.length();
      }
    } on FileSystemException {
      // Partial count.
    }
    return n;
  }

  @override
  Stream<TranscriptionEvent> get events => _events.stream;

  static Future<void> _quietly(FutureOr<void> Function() action) async {
    try {
      await action();
    } on Object {
      // Best effort.
    }
  }
}
