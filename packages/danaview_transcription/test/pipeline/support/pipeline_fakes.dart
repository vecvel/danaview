// OWNER: AI-13
//
// Fakes for the orchestration tests: whisper runtime/model/jobs, model store, audio extractor,
// device resources, export activity, background leases, and a harness that wires a real
// TranscriptionServiceImpl over a temp folder and a DomainTimelineView of a small project.

import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

import '../../timeline/timeline_fixtures.dart';

// ---------------------------------------------------------------------------------------------
// whisper
// ---------------------------------------------------------------------------------------------

/// A scripted native job.
final class FakeWhisperJob implements WhisperJob {
  FakeWhisperJob(this.kind, {this.transcribe, this.detect});

  final String kind;
  final WhisperTranscribeRequest? transcribe;
  final WhisperDetectRequest? detect;
  final StreamController<WhisperJobUpdate> _updates = StreamController<WhisperJobUpdate>.broadcast(sync: true);
  final Completer<WhisperJobResult> _result = Completer<WhisperJobResult>();
  final List<String> calls = [];
  int? threadsSet;
  bool cancelled = false;

  @override
  Stream<WhisperJobUpdate> get updates => _updates.stream;

  @override
  Future<WhisperJobResult> get result => _result.future;

  bool get isDone => _result.isCompleted;

  void status({double fraction = 0, int chunksCompleted = 0, Duration processed = Duration.zero, Duration compute = Duration.zero}) =>
      _updates.add(WhisperJobStatus(
        state: WhisperJobState.running,
        phase: WhisperPhase.decoding,
        fraction: fraction,
        chunksCompleted: chunksCompleted,
        processed: processed,
        computeTime: compute,
      ));

  void chunk(int index, List<RawSegment> segments) =>
      _updates.add(WhisperSegmentsAdded(segments: segments, chunk: index, chunkFinal: true));

  void succeed({List<RawSegment> segments = const [], List<WhisperLanguageProbability> languages = const []}) {
    if (_result.isCompleted) return;
    _result.complete(WhisperJobResult(segments: segments, languages: languages));
    unawaited(_updates.close());
  }

  void fail(WhisperErrorKind kind) {
    if (_result.isCompleted) return;
    _result.completeError(WhisperException(kind));
    unawaited(_updates.close());
  }

  @override
  void cancel() {
    calls.add('cancel');
    cancelled = true;
    fail(WhisperErrorKind.cancelled);
  }

  @override
  void pause({bool abortCurrentChunk = false}) => calls.add(abortCurrentChunk ? 'pause(abort)' : 'pause');

  @override
  void resume() => calls.add('resume');

  @override
  set threads(int value) {
    threadsSet = value;
    calls.add('threads=$value');
  }
}

/// Plays a job: called right after the job is created.
typedef JobScript = FutureOr<void> Function(FakeWhisperJob job);

final class FakeWhisperModel implements WhisperModel {
  FakeWhisperModel(this.runtime, {required this.usesGpu});

  final FakeWhisperRuntime runtime;
  final bool usesGpu;
  bool released = false;

  @override
  WhisperModelInfo get info => WhisperModelInfo(multilingual: true, usesGpu: usesGpu);

  @override
  bool get isBusy => false;

  @override
  WhisperJob detectLanguage(WhisperDetectRequest request) {
    final job = FakeWhisperJob('detect', detect: request);
    runtime.jobs.add(job);
    scheduleMicrotask(() => runtime.detectScript(job));
    return job;
  }

  @override
  WhisperJob transcribe(WhisperTranscribeRequest request) {
    final job = FakeWhisperJob('transcribe', transcribe: request);
    runtime.jobs.add(job);
    scheduleMicrotask(() => runtime.transcribeScript(job));
    return job;
  }

  @override
  Future<void> release() async => released = true;
}

final class FakeWhisperRuntime implements WhisperRuntime {
  FakeWhisperRuntime({this.support = const WhisperSupported(), this.engineVersion = '1.9.4'});

  @override
  final WhisperSupport support;

  @override
  final String engineVersion;

  @override
  final WhisperDeviceChannel device = WhisperDeviceChannel(enabled: false);

  final List<FakeWhisperJob> jobs = [];
  final List<FakeWhisperModel> models = [];
  final List<bool> loadGpu = [];
  int releaseIdleCalls = 0;
  WhisperErrorKind? loadFailure;
  bool modelUsesGpu = false;
  Completer<void>? loadGate;

  /// Default: one chunk with [defaultSegments] relative to the requested range start.
  late JobScript transcribeScript = (job) {
    final req = job.transcribe!;
    final segs = shiftSegments(defaultSegments, req.rangeStart);
    job.status(fraction: 0.5, compute: const Duration(seconds: 1), processed: const Duration(seconds: 5));
    job.chunk(0, segs);
    job.status(fraction: 1, chunksCompleted: 1, processed: const Duration(seconds: 10), compute: const Duration(seconds: 2));
    job.succeed(segments: segs);
  };

  /// Default: English with p 0.97.
  late JobScript detectScript = (job) => job.succeed(languages: const [WhisperLanguageProbability('en', 0.97)]);

  List<RawSegment> defaultSegments = fixtureSegments;

  List<FakeWhisperJob> get transcribeJobs => [for (final j in jobs) if (j.kind == 'transcribe') j];
  List<FakeWhisperJob> get detectJobs => [for (final j in jobs) if (j.kind == 'detect') j];

  @override
  Future<WhisperModel> loadModel(String modelPath, {WhisperModelOptions options = const WhisperModelOptions(), WhisperCancelToken? cancel}) async {
    loadGpu.add(options.preferGpu);
    final gate = loadGate;
    if (gate != null) await gate.future;
    final failure = loadFailure;
    if (failure != null) throw WhisperException(failure);
    final m = FakeWhisperModel(this, usesGpu: options.preferGpu && modelUsesGpu);
    models.add(m);
    return m;
  }

  @override
  Future<void> releaseIdleModels() async => releaseIdleCalls++;
}

RawSegment rawSeg(int chunk, List<(String, double, double)> words, {int index = 0}) => RawSegment(
      index: index,
      chunk: chunk,
      start: _d(words.first.$2),
      end: _d(words.last.$3),
      text: words.map((w) => w.$1).join(' '),
      words: [for (final w in words) RawWord(text: w.$1, start: _d(w.$2), end: _d(w.$3), probability: 0.9)],
    );

Duration _d(double seconds) => Duration(microseconds: (seconds * 1000000).round());

List<RawSegment> shiftSegments(List<RawSegment> segs, Duration by) => [
      for (final s in segs)
        RawSegment(
          index: s.index,
          chunk: s.chunk,
          start: s.start + by,
          end: s.end + by,
          text: s.text,
          words: [for (final w in s.words) RawWord(text: w.text, start: w.start + by, end: w.end + by, probability: w.probability)],
        ),
    ];

/// The fixture transcript of a 10 s English clip (relative to the WAV start).
final List<RawSegment> fixtureSegments = [
  rawSeg(0, [('Welcome', 1.0, 1.4), ('to', 1.4, 1.6), ('the', 1.6, 1.8), ('harbour', 1.8, 2.4), ('tour.', 2.4, 2.9)]),
  rawSeg(0, [('We', 4.0, 4.2), ('start', 4.2, 4.6), ('at', 4.6, 4.8), ('the', 4.8, 5.0), ('lighthouse.', 5.0, 5.8)], index: 1),
];

// ---------------------------------------------------------------------------------------------
// store
// ---------------------------------------------------------------------------------------------

final class FakeDownload implements ModelDownload {
  final StreamController<ModelDownloadProgress> controller = StreamController<ModelDownloadProgress>.broadcast(sync: true);
  final Completer<InstalledSpeechModel> completer = Completer<InstalledSpeechModel>();
  bool cancelled = false;

  @override
  Stream<ModelDownloadProgress> get progress => controller.stream;

  @override
  Future<InstalledSpeechModel> get done => completer.future;

  @override
  void cancel({bool keepPartial = true}) {
    cancelled = true;
    if (!completer.isCompleted) completer.completeError(const ModelDownloadFailure(ModelDownloadFailureKind.cancelled));
  }
}

final class FakeModelStore implements SpeechModelStore {
  FakeModelStore({Set<String>? ready}) : ready = ready ?? {SpeechModelCatalog.balanced.id, SpeechModelCatalog.fast.id};

  final Set<String> ready;
  final Set<String> corrupt = {};
  final List<String> markedCorrupt = [];
  final List<String> used = [];
  final List<String> deleted = [];
  final List<UserConsent> consents = [];
  final StreamController<SpeechModelInventory> _watch = StreamController<SpeechModelInventory>.broadcast();
  FakeDownload? download_;
  String? downloadingId;
  FolderUsage usage = const FolderUsage(bytes: 1000, files: 2, partialBytes: 100);

  InstalledSpeechModel _installed(String id) => InstalledSpeechModel(spec: SpeechModelCatalog.byId(id)!, installedAt: when);

  @override
  Future<SpeechModelInventory> inventory() async => SpeechModelInventory(
        installed: [for (final id in ready) _installed(id), if (ready.isNotEmpty) _installed(SpeechModelCatalog.vad.id)],
      );

  @override
  Stream<SpeechModelInventory> watch() => _watch.stream;

  @override
  Future<InstalledSpeechModel?> installed(String modelId) async => ready.contains(modelId) ? _installed(modelId) : null;

  @override
  Future<SpeechModelFiles?> filesFor(String modelId) async => ready.contains(modelId)
      ? SpeechModelFiles(model: _installed(modelId), modelPath: '/models/$modelId.bin', vadPath: '/models/vad.bin')
      : null;

  @override
  Future<SpeechModelStatus> statusOf(String modelId) async {
    if (downloadingId == modelId) return const SpeechModelDownloading(ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: 1, total: 2));
    if (corrupt.contains(modelId)) return const SpeechModelCorrupt();
    if (ready.contains(modelId)) return SpeechModelReady(_installed(modelId));
    return const SpeechModelMissing();
  }

  /// Starts a download of [modelId] that the test finishes with [finishDownload].
  FakeDownload beginDownload(String modelId) {
    downloadingId = modelId;
    return download_ = FakeDownload();
  }

  void finishDownload() {
    final id = downloadingId!;
    downloadingId = null;
    ready.add(id);
    download_!.completer.complete(_installed(id));
    _watch.add(SpeechModelInventory());
  }

  @override
  ModelDownload download(UserConsent consent) {
    consents.add(consent);
    return beginDownload(consent.disclosure.modelId);
  }

  @override
  ModelDownload? get activeDownload => downloadingId == null ? null : download_;

  @override
  Future<void> delete(String modelId) async {
    deleted.add(modelId);
    ready.remove(modelId);
  }

  @override
  Future<void> deleteAll() async {
    deleted.add('*');
    ready.clear();
  }

  @override
  Future<void> markCorrupt(String modelId) async {
    markedCorrupt.add(modelId);
    ready.remove(modelId);
    corrupt.add(modelId);
  }

  @override
  Future<void> markUsed(String modelId) async => used.add(modelId);

  @override
  Future<FolderUsage> measure() async => usage;
}

// ---------------------------------------------------------------------------------------------
// extractor
// ---------------------------------------------------------------------------------------------

final class FakeExtraction implements SpeechAudioExtraction {
  FakeExtraction(this.request, this.owner);

  final SpeechAudioRequest request;
  final FakeExtractor owner;
  final StreamController<double> _progress = StreamController<double>.broadcast(sync: true);
  final Completer<SpeechAudioResult> _result = Completer<SpeechAudioResult>();
  bool cancelled = false;

  @override
  Stream<double> get progress => _progress.stream;

  @override
  Future<SpeechAudioResult> get result => _result.future;

  Future<void> complete() async {
    if (_result.isCompleted) return;
    _progress.add(0.5);
    final failure = owner.failures[request.media.uri];
    owner.active--;
    if (failure != null) {
      _result.completeError(SpeechAudioFailure(failure));
      return;
    }
    final file = File(request.outputPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(44, 0));
    owner.written.add(request.outputPath);
    _result.complete(SpeechAudioResult(
      path: request.outputPath,
      frames: request.range.duration * 16 ~/ 1000,
      duration: request.range.duration,
      sourceChannels: 2,
      sourceSampleRate: 48000,
      codec: 'aac',
    ));
  }

  @override
  void cancel() {
    cancelled = true;
    if (_result.isCompleted) return;
    owner.active--;
    _result.completeError(const SpeechAudioFailure(SpeechAudioFailureKind.cancelled));
  }
}

final class FakeExtractor implements SpeechAudioExtractor {
  /// Failures by media uri.
  final Map<String, SpeechAudioFailureKind> failures = {};
  final List<FakeExtraction> extractions = [];
  final List<String> written = [];
  int active = 0;
  int maxActive = 0;

  /// When true, extractions wait for [release].
  bool hold = false;

  @override
  SpeechAudioExtraction extract(SpeechAudioRequest request) {
    final e = FakeExtraction(request, this);
    extractions.add(e);
    active++;
    if (active > maxActive) maxActive = active;
    if (!hold) scheduleMicrotask(() => unawaited(e.complete()));
    return e;
  }

  Future<void> release() async {
    hold = false;
    for (final e in [...extractions]) {
      await e.complete();
    }
  }
}

// ---------------------------------------------------------------------------------------------
// device, export, leases
// ---------------------------------------------------------------------------------------------

final class FakeDevice implements DeviceResources {
  FakeDevice({WhisperDeviceProfile? profile, this.memory, this.freeDisk}) : profileValue = profile ?? androidProfile();

  WhisperDeviceProfile profileValue;
  int? memory;
  int? freeDisk;
  final StreamController<WhisperDeviceEvent> controller = StreamController<WhisperDeviceEvent>.broadcast(sync: true);

  @override
  Future<WhisperDeviceProfile> profile() async => profileValue;

  @override
  Future<int?> availableMemory() async => memory;

  @override
  Future<int?> freeDiskBytes(String path) async => freeDisk;

  @override
  Stream<WhisperDeviceEvent> get events => controller.stream;

  void emit(WhisperDeviceEvent e) => controller.add(e);
}

const int gib = 1024 * 1024 * 1024;
const int mib = 1024 * 1024;

WhisperDeviceProfile androidProfile({int ram = 6 * gib, int perf = 4, bool lowRam = false, bool is64 = true}) =>
    WhisperDeviceProfile(os: 'android', osVersion: '14', physicalRamBytes: ram, perfCores: perf, totalCores: 8, isLowRam: lowRam, is64Bit: is64, apiLevel: 34);

WhisperDeviceProfile iosProfile({int ram = 6 * gib, int perf = 2}) =>
    WhisperDeviceProfile(os: 'ios', osVersion: '18.2', physicalRamBytes: ram, perfCores: perf, totalCores: 6, gpuFamily: 8);

final class FakeExports implements ExportActivity {
  final StreamController<bool> controller = StreamController<bool>.broadcast(sync: true);
  bool active = false;

  @override
  bool get isActive => active;

  @override
  Stream<bool> get changes => controller.stream;

  void set(bool value) {
    active = value;
    controller.add(value);
  }
}

final class FakeLease implements SpeechBackgroundLease {
  bool released = false;

  @override
  Stream<void> get expiring => const Stream<void>.empty();

  @override
  Future<void> release() async => released = true;
}

final class FakeLeases implements BackgroundLeaseProvider {
  final List<FakeLease> leases = [];
  final List<String> titles = [];

  @override
  Future<SpeechBackgroundLease?> acquire({required String title, required Stream<double> progress}) async {
    titles.add(title);
    final l = FakeLease();
    leases.add(l);
    return l;
  }
}

/// A manual timer for the governor's critical recovery.
final class ManualTimers {
  final List<(Duration, void Function(), _ManualTimer)> pending = [];

  Timer start(Duration d, void Function() cb) {
    final t = _ManualTimer();
    pending.add((d, cb, t));
    return t;
  }

  void fireAll() {
    final list = [...pending];
    pending.clear();
    for (final (_, cb, t) in list) {
      if (t.isActive) {
        t._active = false;
        cb();
      }
    }
  }
}

final class _ManualTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

// ---------------------------------------------------------------------------------------------
// timeline
// ---------------------------------------------------------------------------------------------

/// A [TimelineView] over a project whose media resolve to `file:///media/<id>.mp4` (unless offline).
final class ResolvingView implements TimelineView, TimelineMediaInfo {
  ResolvingView(EditProject project, {this.offline = const {}}) : _inner = DomainTimelineView(project);

  final DomainTimelineView _inner;
  final Set<String> offline;

  @override
  ProjectId get project => _inner.project;

  @override
  FrameRate get frameRate => _inner.frameRate;

  @override
  Size get canvasSize => _inner.canvasSize;

  @override
  TimeUs get duration => _inner.duration;

  @override
  Iterable<TrackView> get tracks => _inner.tracks;

  @override
  Iterable<AudibleClipView> audibleClips() => _inner.audibleClips();

  @override
  Iterable<SubtitleTrackView> get subtitleTracks => _inner.subtitleTracks;

  @override
  List<TimeUs> get cutPoints => _inner.cutPoints;

  @override
  MediaAudioInfo? audioInfo(MediaId media) => _inner.audioInfo(media);

  @override
  Future<ResolvedMedia?> resolveMedia(MediaId media) async =>
      offline.contains(media.value) ? null : ResolvedMedia(uri: 'file:///media/${media.value}.mp4', fingerprint: 'qh_${media.value}');
}

/// One 10 s clip of m1 on the main track.
EditProject oneClipProject({int startMs = 0}) => project([
      mainTrack([clip('c1', startMs, startMs + 10000, 'm1')]),
    ], [
      asset('m1'),
    ]);

/// Two clips of different media.
EditProject twoClipProject() => project([
      mainTrack([clip('c1', 0, 10000, 'm1'), clip('c2', 10000, 20000, 'm2')]),
    ], [
      asset('m1'),
      asset('m2'),
    ]);

// ---------------------------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------------------------

final class Harness {
  Harness._(this.dir, this.service, this.runtime, this.store, this.extractor, this.device, this.exports, this.governor, this.leases,
      this.logs, this.timers, this.delays);

  static Future<Harness> create({
    WhisperDeviceProfile? profile,
    SpeechPlatform? platform,
    FakeWhisperRuntime? runtime,
    FakeModelStore? store,
    int? memory,
    int? freeDisk,
  }) async {
    final dir = await Directory.systemTemp.createTemp('ai13_');
    final rt = runtime ?? FakeWhisperRuntime();
    final st = store ?? FakeModelStore();
    final ex = FakeExtractor();
    final device = FakeDevice(profile: profile, memory: memory, freeDisk: freeDisk);
    final exports = FakeExports();
    final timers = ManualTimers();
    final governor = ResourceGovernor(device: device, exports: exports, platform: platform, timer: timers.start);
    final leases = FakeLeases();
    final logs = <(String, Map<String, Object>)>[];
    final delays = <Duration>[];
    var n = 0;
    final service = TranscriptionServiceImpl(
      supportDirectory: dir.path,
      store: st,
      extractor: ex,
      governor: governor,
      openRuntime: () async => rt,
      leases: leases,
      clock: () => DateTime.utc(2026, 10, 14, 12),
      delay: (d) async => delays.add(d),
      newJobId: () => 'job_${++n}',
      log: (e, f) => logs.add((e, f)),
    );
    await service.initialize();
    return Harness._(dir, service, rt, st, ex, device, exports, governor, leases, logs, timers, delays);
  }

  final Directory dir;
  final TranscriptionServiceImpl service;
  final FakeWhisperRuntime runtime;
  final FakeModelStore store;
  final FakeExtractor extractor;
  final FakeDevice device;
  final FakeExports exports;
  final ResourceGovernor governor;
  final FakeLeases leases;
  final List<(String, Map<String, Object>)> logs;
  final ManualTimers timers;
  final List<Duration> delays;

  /// The project the timeline callback reads (tests swap it mid-job).
  EditProject project = oneClipProject();
  Set<String> offline = {};

  TimelineView view() => ResolvingView(project, offline: offline);

  TranscriptionRequest request({
    TranscriptionScope scope = const TimelineScope(),
    SpokenLanguage language = const FixedLanguage('en'),
    String? modelId,
    CaptionTarget target = const NewTrackTarget(),
    bool sounds = false,
  }) =>
      TranscriptionRequest(
        project: project.id,
        scope: scope,
        language: language,
        modelId: modelId ?? SpeechModelCatalog.balanced.id,
        segmentation: const SegmentationSettings(),
        target: target,
        timeline: view,
        includeSoundDescriptions: sounds,
      );

  /// Starts a job and records its progress.
  (TranscriptionJob, List<TranscriptionProgress>) start([TranscriptionRequest? r]) {
    final job = service.start(r ?? request());
    final samples = <TranscriptionProgress>[];
    job.progress.listen(samples.add);
    return (job, samples);
  }

  String key({String media = 'm1', String language = 'en', SpeechModelSpec? spec}) => TranscriptKey.compute(
        quickHash: 'qh_$media',
        modelSha256: (spec ?? SpeechModelCatalog.balanced).sha256,
        language: language,
        vad: true,
      );

  Directory get workDir => Directory(service.paths.work);

  Future<void> dispose() async {
    await service.dispose();
    await governor.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// Phases in order of first appearance.
List<TranscriptionPhase> phasesOf(List<TranscriptionProgress> samples) {
  final out = <TranscriptionPhase>[];
  for (final s in samples) {
    if (out.isEmpty || out.last != s.phase) out.add(s.phase);
  }
  return out;
}

/// Lets queued microtasks and timers run.
Future<void> settle([int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Waits until [condition] holds (real async; bounded).
Future<void> until(bool Function() condition, {int rounds = 400}) async {
  for (var i = 0; i < rounds; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw StateError('condition not met');
}
