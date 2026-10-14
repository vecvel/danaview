// OWNER: AI-13
//
// One Auto captions job (ARCH §16.4-16.5, ai.md §8.2): plan -> cache lookup -> model (wait for a
// running consented download) -> load -> extract units through the SpeechAudioExtractor port
// (pipeline depth 1: unit k+1 extracts while unit k transcribes) -> language (explicit, or DETECT
// on <= 30 s of speech: top-1 p >= 0.6, else needsLanguage with the top 3) -> ~180 s chunks cut at
// the quietest point with VAD (native) -> per-chunk checkpoints -> normalize -> transcript file
// -> map on a fresh timeline -> segment -> result (drafts + CaptionProvenance; the editor applies
// them as one history entry).
//
// Resource rules come from the [ResourceGovernor]: the job waits while an export runs or the
// device is critical, pauses the native job at a chunk boundary when one starts, aborts the
// running chunk when iOS goes to the background, follows thread changes and cools down between
// chunks at thermal `serious`. On Android a background lease is held while the job runs.
//
// Cancel stops the native work, deletes the WAVs and keeps checkpoints and the job record, so the
// same request resumes (completed units are cache hits, the unit in progress continues at its
// last checkpointed chunk). Logs carry codes and numbers only.

import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

import '../catalog/speech_model_catalog.dart';
import '../catalog/tuning.dart';
import '../contracts/failures.dart';
import '../contracts/ports.dart';
import '../contracts/timeline_view.dart';
import '../contracts/transcription_service.dart';
import '../governor/resource_governor.dart';
import '../languages/languages.dart';
import '../models_store/speech_model_store.dart';
import '../timeline/transcription_planner.dart';
import '../timeline/transcription_unit.dart';
import '../timeline/word_mapper.dart';
import '../transcript/job_records.dart';
import '../transcript/transcript_cache.dart';
import '../transcript/transcript_checkpoints.dart';
import '../transcript/transcript_key.dart';
import '../transcript/transcript_models.dart';
import '../transcript/transcript_normalizer.dart';
import 'caption_assembly.dart';
import 'job_progress.dart';
import 'pipeline_support.dart';

/// Everything a job needs; built once by `TranscriptionServiceImpl`.
@internal
final class PipelineEnv {
  /// Creates the environment.
  PipelineEnv({
    required this.runtime,
    required this.store,
    required this.extractor,
    required this.governor,
    required this.paths,
    required this.cache,
    required this.checkpoints,
    required this.records,
    required this.leases,
    required this.clock,
    required this.delay,
    required this.log,
    required this.planner,
    required this.assembler,
    required this.progressInterval,
    required this.leaseTitle,
  });

  /// Opens (once) the whisper runtime.
  final Future<WhisperRuntime> Function() runtime;

  /// Model store.
  final SpeechModelStore store;

  /// Audio extraction port.
  final SpeechAudioExtractor extractor;

  /// Resource governor (started).
  final ResourceGovernor governor;

  /// Folder layout.
  final SpeechPaths paths;

  /// Transcript cache.
  final TranscriptCache cache;

  /// Checkpoints.
  final TranscriptCheckpoints checkpoints;

  /// Job records.
  final JobRecordStore records;

  /// Background leases (Android), or null.
  final BackgroundLeaseProvider? leases;

  /// Clock.
  final DateTime Function() clock;

  /// Waits (cooldowns).
  final Future<void> Function(Duration) delay;

  /// Log sink.
  final TranscriptionLogSink log;

  /// Planner.
  final TranscriptionPlanner planner;

  /// Mapper and segmenter.
  final CaptionAssembler assembler;

  /// Minimum interval between progress samples (4 Hz).
  final Duration progressInterval;

  /// Title of the Android foreground-service notification.
  final String leaseTitle;
}

/// Mutable state of one planned unit.
final class _Unit {
  _Unit(this.index, this.unit);

  final int index;
  final TranscriptionUnit unit;
  String? key;
  TranscriptFile? transcript;
  String? skipReason;
  Future<String?>? wav;
  SpeechAudioExtraction? extraction;

  bool get needsWork => transcript == null && skipReason == null;
}

/// A running job ([TranscriptionJob]).
@internal
final class PipelineJob implements TranscriptionJob {
  /// Creates a job; [start] runs it.
  PipelineJob({required this.id, required this.request, required PipelineEnv env}) : _env = env {
    _cancelSignal.future.ignore();
    _result.future.ignore();
  }

  @override
  final String id;

  /// The request.
  final TranscriptionRequest request;

  final PipelineEnv _env;
  final Completer<TranscriptionResult> _result = Completer<TranscriptionResult>();
  final Completer<Never> _cancelSignal = Completer<Never>();
  final StreamController<TranscriptionProgress> _progress = StreamController<TranscriptionProgress>.broadcast(sync: true);

  bool _cancelled = false;
  bool _finished = false;
  TranscriptionPhase _phase = TranscriptionPhase.preparing;
  JobProgressModel? _model;
  DateTime? _lastEmit;
  String? _partialText;
  int _unitIndex = 0;
  List<LanguageProbability>? _candidates;
  PauseReason? _gatePause;
  PauseReason? _whisperPause;
  bool _cooling = false;
  bool _transcriptionStarted = false;
  int? _lastThreads;
  Completer<String>? _languageAnswer;

  SpeechModelSpec? _spec;
  TimelineView? _planView;
  List<_Unit> _units = const [];
  final List<SkippedClip> _skipped = [];
  String? _language;
  bool _languageDetected = false;
  double? _languageP;
  String _engineVersion = '';
  WhisperRuntime? _runtime;
  WhisperModel? _whisperModel;
  WhisperJob? _currentWhisper;
  String? _vadPath;
  JobRecord? _record;
  SpeechBackgroundLease? _lease;
  StreamSubscription<void>? _governorSub;

  @override
  Stream<TranscriptionProgress> get progress => _progress.stream;

  @override
  Future<TranscriptionResult> get result => _result.future;

  /// Whether the job ended.
  bool get isFinished => _finished;

  @override
  void cancel() {
    if (_finished || _cancelled) return;
    _cancelled = true;
    _log('job.cancel');
    _currentWhisper?.cancel();
    for (final u in _units) {
      u.extraction?.cancel();
    }
    _cancelSignal.completeError(const TranscriptionCancelled());
  }

  @override
  void provideLanguage(String code) {
    final answer = _languageAnswer;
    if (answer == null || answer.isCompleted) return;
    if (languageForWhisperCode(code) == null) return;
    answer.complete(code);
  }

  /// Runs the job; [result] completes when it ends.
  void start() {
    unawaited(_run().then(_succeed, onError: _fail));
  }

  // -------------------------------------------------------------------------------------------
  // Pipeline
  // -------------------------------------------------------------------------------------------

  Future<TranscriptionResult> _run() async {
    _setPhase(TranscriptionPhase.preparing);
    final runtime = _runtime = await _guard(_env.runtime());
    if (runtime.support case WhisperUnsupported(:final reason)) throw UnsupportedDeviceFailure(reason.name);
    _engineVersion = runtime.engineVersion;
    final spec = SpeechModelCatalog.byId(request.modelId);
    if (spec == null || spec.id == SpeechModelCatalog.vad.id) throw const ModelMissingFailure();
    _spec = spec;

    // 1. Plan.
    final view = _planView = request.timeline();
    final plan = _env.planner.plan(view, request.scope);
    _skipped.addAll(plan.skipped);
    if (plan.isEmpty) throw const NoAudioFailure();
    _units = [for (var i = 0; i < plan.units.length; i++) _Unit(i, plan.units[i])];
    final model = _model = JobProgressModel(
      unitDurations: [for (final u in plan.units) u.duration],
      priorRtf: priorRealTimeFactor(spec.tier),
    );
    _log('job.plan', {'units': _units.length, 'skipped': plan.skipped.length, 'audioMs': plan.totalDuration ~/ 1000});

    // Resume: a record of the same request keeps its detected language.
    final requestJson = encodeTranscriptionRequest(request);
    final previous = await _previousRecord(requestJson);
    switch (request.language) {
      case FixedLanguage(:final code):
        _language = code;
        _languageDetected = false;
      case AutoLanguage():
        _language = previous?.detectedLanguage;
        _languageP = previous?.detectedLanguageP;
        _languageDetected = true;
    }

    // 2. Cache.
    if (_language != null) await _lookupCache(_language!);

    if (_units.any((u) => u.needsWork)) {
      await _waitRunnable();
      // 3. Model.
      final files = await _ensureModel(spec);
      _vadPath = files.vadPath;
      await _acquireLease();
      _governorSub = _env.governor.changes.listen((_) => _applyGovernor());
      await _loadModel(files.modelPath, preferGpu: true);
      // 5. Language.
      if (_language == null) {
        await _detectLanguage();
        await _lookupCache(_language!);
      }
      model.detected();
      _emit(force: true);
      await _writeRecord(requestJson);
      // 4 + 6. Extract and transcribe.
      await _transcribeAll();
    } else {
      model
        ..loaded()
        ..detected();
    }

    final transcribed = _units.where((u) => u.transcript != null).toList();
    if (transcribed.isEmpty) {
      if (_units.any((u) => u.skipReason == 'unsupportedCodec')) throw const UnsupportedAudioFailure('unknown');
      throw const NoAudioFailure();
    }

    // 7 + 8. Map on a fresh timeline and segment.
    _setPhase(TranscriptionPhase.segmenting);
    final language = _language!;
    final fresh = request.timeline();
    final assembled = await _env.assembler.assemble(
      timeline: fresh,
      transcripts: [for (final u in transcribed) UnitWords.fromTranscript(u.unit, u.transcript!)],
      languageCode: language,
      settings: request.segmentation,
      window: scopeWindow(request.scope),
    );
    _check();
    if (assembled.drafts.isEmpty) throw const NoSpeechFailure();
    model.finishing(1);

    final bcp47 = bcp47OfWhisperCode(language);
    final keys = <String>[];
    for (final u in transcribed) {
      if (!keys.contains(u.transcript!.key)) keys.add(u.transcript!.key);
    }
    final engineVersion = _engineVersion.isNotEmpty ? _engineVersion : transcribed.first.transcript!.engine.version;
    final provenance = CaptionProvenance(
      generator: 'whisper.cpp',
      engineVersion: engineVersion,
      modelId: spec.id,
      modelSha256: spec.sha256,
      language: bcp47,
      languageDetected: _languageDetected,
      languageConfidence: _languageDetected ? _languageP : null,
      segmentation: request.segmentation,
      scope: captionScopeDataOf(request.scope),
      transcriptKeys: keys,
      generatedAt: _env.clock().toUtc(),
    );
    await _deleteRecord();
    _log('job.done', {'cues': assembled.drafts.length, 'words': assembled.words, 'skipped': _skipped.length});
    return TranscriptionResult(
      drafts: assembled.drafts,
      provenance: provenance,
      target: request.target,
      summary: TranscriptionSummary(cues: assembled.drafts.length, words: assembled.words, language: bcp47, skipped: List.of(_skipped)),
    );
  }

  Future<JobRecord?> _previousRecord(Map<String, Object?> requestJson) async {
    JobRecord? previous;
    try {
      previous = await _env.records.forProject(request.project);
    } on Object {
      previous = null;
    }
    if (previous == null || previous.jobId == id) return null;
    final same = const DeepCollectionEquality().equals(previous.request, requestJson);
    // A different request of the same project supersedes the old record (one per project).
    await _quietly(() => _env.records.delete(previous!.jobId));
    if (same) _log('job.resume', {'doneUnits': previous.units.where((u) => u.state == JobUnitState.done).length});
    return same ? previous : null;
  }

  Future<void> _lookupCache(String language) async {
    final spec = _spec!;
    for (final u in _units) {
      if (u.skipReason != null) continue;
      final key = u.key = TranscriptKey.compute(
        quickHash: u.unit.mediaQuickHash,
        audioStream: u.unit.audioStream,
        modelSha256: spec.sha256,
        language: language,
        vad: true,
      );
      if (u.transcript != null) continue;
      TranscriptFile? hit;
      try {
        hit = await _env.cache.lookup(key, u.unit.sourceRange);
      } on Object {
        hit = null;
      }
      _check();
      if (hit != null && hit.params.suppressNst == !request.includeSoundDescriptions) {
        u.transcript = hit;
        _model!.markUnitDone(u.index);
        _log('unit.cacheHit', {'unit': u.index});
      }
    }
  }

  Future<SpeechModelFiles> _ensureModel(SpeechModelSpec spec) async {
    var status = await _guard(_env.store.statusOf(spec.id));
    if (status is SpeechModelDownloading) {
      final download = _env.store.activeDownload;
      if (download != null) {
        _setPhase(TranscriptionPhase.downloadingModel);
        final sub = download.progress.listen((_) => _emit());
        try {
          await _guard(download.done);
        } finally {
          await sub.cancel();
        }
        status = await _guard(_env.store.statusOf(spec.id));
      }
    }
    if (status is SpeechModelCorrupt) throw const ModelCorruptFailure();
    final files = await _guard(_env.store.filesFor(spec.id));
    if (files == null) throw const ModelMissingFailure();
    return files;
  }

  Future<void> _loadModel(String path, {required bool preferGpu}) async {
    _setPhase(TranscriptionPhase.loadingModel);
    final token = WhisperCancelToken();
    final loading = _runtime!.loadModel(path, options: WhisperModelOptions(preferGpu: preferGpu), cancel: token);
    try {
      _whisperModel = await _guard(loading);
    } on TranscriptionCancelled {
      token.cancel();
      unawaited(loading.then((m) => m.release(), onError: (Object _) {}));
      rethrow;
    } on WhisperException catch (e) {
      _log('model.loadFailed', {'kind': e.kind.name});
      if (e.kind == WhisperErrorKind.modelLoadFailed) {
        await _quietly(() => _env.store.markCorrupt(_spec!.id));
        throw const ModelCorruptFailure();
      }
      throw _mapWhisper(e);
    }
    _log('model.loaded', {'gpu': _whisperModel!.info.usesGpu ? 1 : 0});
    await _quietly(() => _env.store.markUsed(_spec!.id));
    _model!.loaded();
    _emit(force: true);
  }

  Future<void> _detectLanguage() async {
    _setPhase(TranscriptionPhase.detectingLanguage);
    final order = [..._units]..sort((a, b) {
        if (a.unit.priority != b.unit.priority) return b.unit.priority.compareTo(a.unit.priority);
        if (a.unit.duration != b.unit.duration) return b.unit.duration.compareTo(a.unit.duration);
        return a.index.compareTo(b.index);
      });
    List<WhisperLanguageProbability>? top;
    for (final u in order) {
      if (u.skipReason != null) continue;
      final wav = await _wavFor(u);
      if (wav == null) continue;
      _setPhase(TranscriptionPhase.detectingLanguage);
      await _waitRunnable();
      final job = _whisperModel!.detectLanguage(WhisperDetectRequest(wavPath: wav, threads: _env.governor.threads, vad: _vad));
      final WhisperJobResult r;
      try {
        r = await _runWhisper(job);
      } on WhisperException catch (e) {
        if (e.kind == WhisperErrorKind.noSpeech) continue;
        throw _mapWhisper(e);
      }
      final found = r.languages.isNotEmpty
          ? r.languages
          : [if (r.language.isNotEmpty) WhisperLanguageProbability(r.language, r.languageP)];
      if (found.isEmpty) continue;
      top = found;
      break;
    }
    if (top == null) throw const NoSpeechFailure();
    final best = top.first;
    _log('language.detected', {'p': (best.p * 100).round()});
    if (best.p >= SpeechTuning.autoDetectMinProbability && languageForWhisperCode(best.code) != null) {
      _language = best.code;
      _languageP = best.p;
      _languageDetected = true;
      return;
    }
    _candidates = [
      for (final c in top.where((c) => languageForWhisperCode(c.code) != null).take(3)) LanguageProbability(c.code, c.p),
    ];
    final answer = _languageAnswer = Completer<String>();
    _setPhase(TranscriptionPhase.needsLanguage);
    final code = await _guard(answer.future);
    _candidates = null;
    _language = code;
    _languageDetected = false;
    _languageP = null;
  }

  Future<void> _transcribeAll() async {
    for (final u in _units) {
      if (!u.needsWork) continue;
      _check();
      await _transcribeUnit(u);
      final cooldown = _env.governor.chunkCooldown;
      if (cooldown > Duration.zero && _units.any((o) => o.index > u.index && o.needsWork)) {
        await _guard(_env.delay(cooldown));
      }
    }
  }

  Future<void> _transcribeUnit(_Unit u) async {
    _unitIndex = u.index;
    final unit = u.unit;
    final start = unit.sourceRange.start;
    final key = u.key!;
    await _setUnitState(u.index, JobUnitState.extracting);
    final wav = await _wavFor(u);
    if (wav == null) {
      await _setUnitState(u.index, JobUnitState.done);
      return;
    }
    _prefetchAfter(u.index);
    await _waitRunnable();
    await _setUnitState(u.index, JobUnitState.transcribing);
    _transcriptionStarted = true;
    _setPhase(TranscriptionPhase.transcribing);

    var gpuRetried = false;
    List<TranscriptSegment> segments;
    while (true) {
      var replay = await _replay(key, start);
      final resumeUs = replay?.resumeFromUs ?? start;
      final prior = replay?.segments ?? const <TranscriptSegment>[];
      replay = null;
      _model!.transcription(u.index, (resumeUs - start) / (unit.duration == 0 ? 1 : unit.duration));
      if (resumeUs >= unit.sourceRange.end - 100000) {
        segments = prior;
        break;
      }
      if (resumeUs > start) _log('unit.resume', {'unit': u.index, 'fromMs': (resumeUs - start) ~/ 1000});
      try {
        final raw = await _transcribeRange(u, wav, resumeUs);
        segments = [...prior, for (final s in raw) TranscriptSegment.fromRaw(s, offsetUs: start)];
        break;
      } on WhisperException catch (e) {
        if (e.kind == WhisperErrorKind.noSpeech) {
          segments = prior;
          break;
        }
        // Inference error with the GPU on: retry once on the CPU (ai.md §15).
        if (e.kind == WhisperErrorKind.inference && !gpuRetried && (_whisperModel?.info.usesGpu ?? false)) {
          gpuRetried = true;
          _log('unit.gpuRetry', {'unit': u.index});
          await _releaseModel();
          await _loadModel(_spec!.id == _spec!.id ? (await _env.store.filesFor(_spec!.id))?.modelPath ?? '' : '', preferGpu: false);
          _setPhase(TranscriptionPhase.transcribing);
          continue;
        }
        throw _mapWhisper(e);
      }
    }

    final language = _language!;
    final normalized = TranscriptNormalizer(NormalizerOptions(removeAnnotations: !request.includeSoundDescriptions))
        .normalize(segments, language: language, unitEndUs: unit.sourceRange.end);
    final transcript = TranscriptFile(
      key: key,
      engine: TranscriptEngineInfo(version: _engineVersion.isEmpty ? 'unknown' : _engineVersion),
      model: TranscriptModelInfo(id: _spec!.id, sha256: _spec!.sha256),
      source: TranscriptSource(mediaFingerprint: unit.mediaQuickHash, audioStream: unit.audioStreamIndex, covered: [unit.sourceRange]),
      language: TranscriptLanguageInfo(code: language, detected: _languageDetected, probability: _languageDetected ? _languageP : null),
      params: TranscriptParams(suppressNst: !request.includeSoundDescriptions),
      segments: normalized.segments,
      createdAt: _env.clock().toUtc(),
    );
    try {
      await _env.cache.write(transcript);
    } on FileSystemException {
      throw const DiskFullFailure();
    }
    await _quietly(() => _env.checkpoints.delete(key));
    await _quietly(() => File(wav).delete());
    u.transcript = transcript;
    _model!.transcription(u.index, 1);
    await _setUnitState(u.index, JobUnitState.done);
    _log('unit.done', {'unit': u.index, 'segments': normalized.segments.length});
    _emit(force: true);
  }

  Future<CheckpointReplay?> _replay(String key, TimeUs unitStart) async {
    CheckpointReplay? replay;
    try {
      replay = await _env.checkpoints.replay(key);
    } on Object {
      replay = null;
    }
    if (replay != null && replay.unitStartUs != unitStart) {
      // A checkpoint of another range of the same media: start this unit fresh.
      await _quietly(() => _env.checkpoints.delete(key));
      return null;
    }
    return replay;
  }

  /// Runs whisper over `[resumeUs, end)` of unit [u], checkpointing every finished chunk.
  Future<List<RawSegment>> _transcribeRange(_Unit u, String wav, TimeUs resumeUs) async {
    final unit = u.unit;
    final start = unit.sourceRange.start;
    final job = _whisperModel!.transcribe(WhisperTranscribeRequest(
      wavPath: wav,
      language: _language!,
      threads: _env.governor.threads,
      rangeStart: Duration(microseconds: resumeUs - start),
      vad: _vad,
      decode: WhisperDecodeOptions(
        noSpeechThreshold: SpeechTuning.noSpeechThreshold,
        entropyThreshold: SpeechTuning.entropyThreshold,
        logprobThreshold: SpeechTuning.logprobThreshold,
        suppressNonSpeech: !request.includeSoundDescriptions,
      ),
      chunkTarget: const Duration(milliseconds: SpeechTuning.chunkTargetMs),
      chunkSearch: const Duration(milliseconds: SpeechTuning.chunkSearchMs),
      carryPromptWords: SpeechTuning.carryPromptWords,
    ));
    final rangeOffset = resumeUs - start;
    final remaining = unit.sourceRange.end - resumeUs;
    final chunkEnds = <int, TimeUs>{};
    final pending = <int, List<RawSegment>>{};
    var chunkStart = resumeUs;
    var writes = Future<void>.value();
    final sub = job.updates.listen((update) {
      switch (update) {
        case WhisperJobStatus():
          if (update.chunksCompleted > 0) chunkEnds[update.chunksCompleted - 1] = resumeUs + update.processed.inMicroseconds;
          final done = rangeOffset + (update.fraction.clamp(0, 1) * remaining).round();
          _model!.transcription(u.index, done / (unit.duration == 0 ? 1 : unit.duration));
          _model!.measure(compute: update.computeTime, processed: update.processed);
          _emit();
        case WhisperSegmentsAdded(:final segments, :final chunk, :final chunkFinal):
          (pending[chunk] ??= []).addAll(segments);
          if (segments.isNotEmpty) {
            final text = segments.last.text.trim();
            _partialText = text.length <= 80 ? text : text.substring(text.length - 80);
          }
          if (!chunkFinal) break;
          final raw = pending.remove(chunk) ?? const <RawSegment>[];
          final converted = [for (final s in raw) TranscriptSegment.fromRaw(s, offsetUs: start)];
          var end = chunkEnds[chunk] ?? chunkStart;
          for (final s in converted) {
            if (s.endUs > end) end = s.endUs;
          }
          if (end > unit.sourceRange.end) end = unit.sourceRange.end;
          final c = CheckpointChunk(index: chunk, startUs: chunkStart, endUs: end, segments: converted);
          chunkStart = end;
          writes = writes.then((_) => _quietly(() => _env.checkpoints.append(u.key!, c, unitStartUs: start)));
          _cooldownAfterChunk(job);
          _emit(force: true);
        case WhisperLanguageResult():
        case WhisperJobStalled():
          break;
      }
    });
    try {
      final r = await _runWhisper(job);
      return r.segments;
    } finally {
      await sub.cancel();
      await writes;
    }
  }

  /// Runs [job] under the governor (pause, threads) and cancel.
  Future<WhisperJobResult> _runWhisper(WhisperJob job) async {
    _currentWhisper = job;
    _whisperPause = null;
    _cooling = false;
    _lastThreads = null;
    _applyGovernor();
    try {
      return await _guard(job.result);
    } on TranscriptionCancelled {
      job.cancel();
      rethrow;
    } finally {
      _currentWhisper = null;
      _whisperPause = null;
      _cooling = false;
    }
  }

  void _applyGovernor() {
    final job = _currentWhisper;
    if (job == null || _finished) {
      _emit(force: true);
      return;
    }
    final g = _env.governor;
    final threads = g.threads;
    if (threads != _lastThreads) {
      if (_lastThreads != null) job.threads = threads;
      _lastThreads = threads;
    }
    final reason = g.pauseReason;
    if (reason != null) {
      if (_whisperPause == null || (reason == PauseReason.background && _whisperPause != PauseReason.background)) {
        job.pause(abortCurrentChunk: reason == PauseReason.background);
        _log('job.pause', {'reason': reason.name});
      }
      _whisperPause = reason;
    } else if (_whisperPause != null) {
      _whisperPause = null;
      if (!_cooling) job.resume();
      _log('job.resume', const {});
    }
    _emit(force: true);
  }

  void _cooldownAfterChunk(WhisperJob job) {
    final cooldown = _env.governor.chunkCooldown;
    if (cooldown <= Duration.zero || _whisperPause != null || _cooling) return;
    _cooling = true;
    job.pause();
    unawaited(_env.delay(cooldown).then((_) {
      if (!_cooling || _currentWhisper != job) return;
      _cooling = false;
      if (_whisperPause == null && !_cancelled) job.resume();
    }));
  }

  /// Waits while the governor says generation must not run (export, thermal, iOS background).
  Future<void> _waitRunnable() async {
    while (true) {
      _check();
      final reason = _env.governor.pauseReason;
      if (reason == null) {
        if (_gatePause != null) {
          _gatePause = null;
          _emit(force: true);
        }
        return;
      }
      _gatePause = reason;
      _emit(force: true);
      await _guard(_env.governor.changes.first);
    }
  }

  // -------------------------------------------------------------------------------------------
  // Extraction (pipeline depth 1)
  // -------------------------------------------------------------------------------------------

  Future<String?> _wavFor(_Unit u) {
    final existing = u.wav;
    if (existing != null) {
      // Waiting for a prefetched extraction shows the extraction phase.
      if (u.extraction != null && _phase != TranscriptionPhase.detectingLanguage) _setPhase(TranscriptionPhase.extractingAudio);
      return _guard(existing);
    }
    if (_phase != TranscriptionPhase.detectingLanguage) _setPhase(TranscriptionPhase.extractingAudio);
    final f = u.wav = _extract(u);
    f.ignore();
    return _guard(f);
  }

  void _prefetchAfter(int index) {
    for (final next in _units) {
      if (next.index <= index || !next.needsWork) continue;
      if (next.wav == null) {
        final f = next.wav = _extract(next);
        f.ignore();
      }
      return;
    }
  }

  Future<String?> _extract(_Unit u) async {
    final unit = u.unit;
    final media = await _planView!.resolveMedia(unit.media);
    if (media == null) throw MediaOfflineFailure(unit.media);
    _check();
    final path = _env.paths.wavOf(id, u.index);
    await Directory(_env.paths.workOf(id)).create(recursive: true);
    final extraction = u.extraction = _env.extractor.extract(
      SpeechAudioRequest(media: media, range: unit.sourceRange, outputPath: path, audioStream: unit.audioStream),
    );
    if (_cancelled) extraction.cancel();
    final sub = extraction.progress.listen((f) {
      _model!.extraction(u.index, f);
      _emit();
    }, onError: (Object _) {});
    try {
      final r = await extraction.result;
      _model!.extraction(u.index, 1);
      _log('unit.extracted', {'unit': u.index, 'frames': r.frames});
      return r.path;
    } on SpeechAudioFailure catch (e) {
      _log('unit.extractFailed', {'unit': u.index, 'kind': e.kind.name});
      switch (e.kind) {
        case SpeechAudioFailureKind.mediaOffline:
        case SpeechAudioFailureKind.permissionDenied:
          throw MediaOfflineFailure(unit.media);
        case SpeechAudioFailureKind.noAudioTrack:
          _skip(u, 'noAudio');
          return null;
        case SpeechAudioFailureKind.unsupportedCodec:
          _skip(u, 'unsupportedCodec');
          return null;
        case SpeechAudioFailureKind.decodeFailed:
          throw const AudioDecodeFailure();
        case SpeechAudioFailureKind.diskFull:
          throw const DiskFullFailure();
        case SpeechAudioFailureKind.cancelled:
          throw const TranscriptionCancelled();
      }
    } finally {
      u.extraction = null;
      await sub.cancel();
    }
  }

  void _skip(_Unit u, String reason) {
    u.skipReason = reason;
    _model!.markUnitDone(u.index);
    for (final c in u.unit.clips) {
      _skipped.add(SkippedClip(c.id, reason));
    }
  }

  // -------------------------------------------------------------------------------------------
  // Records, leases, model
  // -------------------------------------------------------------------------------------------

  Future<void> _writeRecord(Map<String, Object?> requestJson) async {
    final now = _env.clock().toUtc();
    _record = JobRecord(
      jobId: id,
      project: request.project,
      request: requestJson,
      units: [
        for (final u in _units)
          JobUnitRecord(
            transcriptKey: u.key ?? '',
            mediaId: u.unit.media,
            audioStream: u.unit.audioStreamIndex,
            sourceRange: u.unit.sourceRange,
            state: u.needsWork ? JobUnitState.pending : JobUnitState.done,
          ),
      ],
      detectedLanguage: request.language is AutoLanguage ? _language : null,
      detectedLanguageP: request.language is AutoLanguage ? _languageP : null,
      startedAt: now,
    );
    await _quietly(() => _env.records.write(_record!));
  }

  Future<void> _setUnitState(int index, JobUnitState state) async {
    final r = _record;
    if (r == null || r.units[index].state == state) return;
    _record = r.withUnitState(index, state, at: _env.clock().toUtc());
    await _quietly(() => _env.records.write(_record!));
  }

  Future<void> _deleteRecord() async {
    _record = null;
    await _quietly(() => _env.records.delete(id));
  }

  Future<void> _acquireLease() async {
    final leases = _env.leases;
    if (leases == null || _env.governor.platform != SpeechPlatform.android) return;
    try {
      _lease = await leases.acquire(
        title: _env.leaseTitle,
        progress: _progress.stream.map((p) => p.fraction),
      );
    } on Object {
      _lease = null;
    }
  }

  Future<void> _releaseModel() async {
    final m = _whisperModel;
    _whisperModel = null;
    if (m != null) await _quietly(m.release);
  }

  WhisperVadOptions? get _vad => _vadPath == null ? null : WhisperVadOptions(modelPath: _vadPath!);

  TranscriptionFailure _mapWhisper(WhisperException e) => switch (e.kind) {
        WhisperErrorKind.cancelled => const TranscriptionCancelled(),
        WhisperErrorKind.outOfMemory => InsufficientMemoryFailure(
            suggestedTier: ResourceGovernor.suggestSmallerTier(_spec?.tier ?? SpeechModelTier.fast, available: SpeechModelTier.values),
          ),
        WhisperErrorKind.modelLoadFailed => const ModelCorruptFailure(),
        WhisperErrorKind.vadModelMissing => const ModelMissingFailure(),
        WhisperErrorKind.libraryUnavailable || WhisperErrorKind.abiMismatch => const UnsupportedDeviceFailure('libraryUnavailable'),
        WhisperErrorKind.invalidAudio || WhisperErrorKind.io => const AudioDecodeFailure(),
        WhisperErrorKind.noSpeech => const NoSpeechFailure(),
        WhisperErrorKind.inference || WhisperErrorKind.busy || WhisperErrorKind.internal => InferenceFailure(e.kind.name),
      };

  // -------------------------------------------------------------------------------------------
  // Ending
  // -------------------------------------------------------------------------------------------

  Future<void> _succeed(TranscriptionResult r) async {
    _setPhase(TranscriptionPhase.done);
    await _cleanup();
    _finished = true;
    _result.complete(r);
    await _progress.close();
  }

  Future<void> _fail(Object error, StackTrace stack) async {
    final failure = switch (error) {
      TranscriptionFailure() => error,
      ModelDownloadFailure() => error,
      WhisperException() => _mapWhisper(error),
      _ => const InferenceFailure('internal'),
    };
    final effective = _cancelled ? const TranscriptionCancelled() : failure;
    _log('job.failed', {'code': effective.code});
    // Cancelled and retryable jobs keep their record and checkpoints for "Resume".
    if (effective is! TranscriptionCancelled && !effective.retryable) await _deleteRecord();
    await _cleanup();
    _finished = true;
    _result.completeError(effective, stack);
    await _progress.close();
  }

  Future<void> _cleanup() async {
    await _governorSub?.cancel();
    _governorSub = null;
    for (final u in _units) {
      u.extraction?.cancel();
      final pending = u.wav;
      if (pending != null) {
        try {
          await pending;
        } on Object {
          // Reported already (or irrelevant after the job ended).
        }
      }
    }
    await _releaseModel();
    final lease = _lease;
    _lease = null;
    if (lease != null) await _quietly(lease.release);
    await _quietly(() async {
      final dir = Directory(_env.paths.workOf(id));
      if (await dir.exists()) await dir.delete(recursive: true);
    });
  }

  // -------------------------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------------------------

  void _check() {
    if (_cancelled) throw const TranscriptionCancelled();
  }

  /// [f], or [TranscriptionCancelled] as soon as the job is cancelled.
  Future<T> _guard<T>(Future<T> f) {
    if (_cancelled) {
      f.ignore();
      return Future<T>.error(const TranscriptionCancelled());
    }
    return Future.any<T>([f, _cancelSignal.future]);
  }

  void _setPhase(TranscriptionPhase phase) {
    if (phase == _phase && _lastEmit != null) return;
    _phase = phase;
    _emit(force: true);
  }

  PauseReason? get _shownPause {
    final p = _whisperPause ?? _gatePause;
    if (p == PauseReason.exportRunning && !_transcriptionStarted) return PauseReason.waitingForExport;
    return p;
  }

  void _emit({bool force = false}) {
    if (_progress.isClosed) return;
    final now = _env.clock();
    final last = _lastEmit;
    if (!force && last != null && now.difference(last) < _env.progressInterval) return;
    _lastEmit = now;
    final m = _model;
    final paused = _shownPause;
    _progress.add(TranscriptionProgress(
      phase: _phase,
      fraction: _phase == TranscriptionPhase.done ? 1 : m?.fraction ?? 0,
      eta: _phase == TranscriptionPhase.transcribing ? m?.eta(paused: paused != null) : null,
      unitIndex: _unitIndex,
      unitCount: _units.length,
      processed: m?.processed ?? 0,
      total: m?.total ?? 0,
      partialText: _partialText,
      paused: paused,
      languageCandidates: _phase == TranscriptionPhase.needsLanguage ? _candidates : null,
    ));
  }

  void _log(String event, [Map<String, Object> fields = const {}]) {
    try {
      _env.log(event, fields);
    } on Object {
      // Logging never breaks a job.
    }
  }

  static Future<void> _quietly(FutureOr<void> Function() action) async {
    try {
      await action();
    } on Object {
      // Best effort (records, checkpoints, temp files).
    }
  }
}
