// OWNER: API-01
//
// Deterministic in-memory engine for widget and unit tests (BUILD_PLAN API-01). No timers run
// unless a test drives them; every call is logged in [FakeEditorEngine.calls].
//
// D-45 render-preview additions (INT-06): `FakeMediaJobs.renderPreview` renders instantly (next
// microtask) to a stub file recorded in `FakeMediaJobs.files` and honours cancel (the stub is
// deleted); `FakePreviewSession.renderedRanges` records `setRenderedRanges` and drops the ranges a
// patch touches ([patchTouchesRange]) or a `setPlan` replaces; `FakeBackgroundWorkGuard` reports a
// scripted power state (`setPowerState`).
//
// INT-07 additions: `FakeExportService` records the notification texts of each start;
// `FakeVoiceRecorder` reports `isRecording` / `recordingChanged`, and the engine mutes every preview
// session while a recording captures (`FakePreviewSession.audioMuted`, also for sessions opened
// meanwhile); `FakeMediaAccess.materializePick` "copies" a pick into a `work/` directory (paths
// only, recorded in `materialized`) with the native refusals.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Size;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import '../capabilities.dart';
import '../engine.dart';
import '../export.dart';
import '../failures.dart';
import '../media_services.dart';
import '../platform_services.dart';
import '../preview.dart';
import '../recorder.dart';

/// Capabilities the fake reports by default (a supported mid-tier device).
const EditorCapabilities fakeDefaultCapabilities = EditorCapabilities(
  supported: true,
  tier: DeviceTier.mid,
  hevcEncode: true,
  hardwareHevc: true,
  maxConcurrentVideoLayers: 4,
  maxVisualSequences: 6,
  backgroundKind: BackgroundExportKind.foregroundService,
  externalDrop: true,
);

/// Call log and failure injection shared by a [FakeEditorEngine] and every service it owns.
///
/// Every engine, preview, job, export, recorder, picker and handoff method records its name
/// (`'capabilities'`, `'preview.seek'`, `'exporter.start'`, …) in [calls]; a failure registered in
/// [failNext] under that name is thrown (or, for jobs, delivered as the job's error) exactly once.
///
/// See ARCH §12 (BUILD_PLAN API-01).
final class FakeCallLog {
  /// Every call, in order.
  final List<String> calls = [];

  /// Failures to deliver from the next call of a method name (consumed when hit).
  final Map<String, EngineFailure> failNext = {};

  /// Records [name]; throws the registered failure, if any.
  void hit(String name) {
    calls.add(name);
    final f = failNext.remove(name);
    if (f != null) throw f;
  }

  /// Records [name] and returns the registered failure instead of throwing (for jobs).
  EngineFailure? record(String name) {
    calls.add(name);
    return failNext.remove(name);
  }
}

/// A deterministic fake [EditorEngine] (ARCH §12; BUILD_PLAN API-01).
///
/// Time never advances by itself: the preview clock moves only when a test calls
/// [FakePreviewSession.advanceFrames]; jobs and exports progress only when a test drives them.
final class FakeEditorEngine implements EditorEngine {
  /// Creates the fake.
  FakeEditorEngine({
    this.caps = fakeDefaultCapabilities,
    Map<String, MediaProbe>? probes,
    Map<String, EditCompatibility>? compatibilityByPath,
    List<String> editorRoots = const ['/fake/support/danaview/editor', '/fake/cache/danaview/editor', '/fake/support/danaview/speech'],
    this.validatePlans = true,
  })  : probes = probes ?? {},
        compatibilityByPath = compatibilityByPath ?? {},
        access = FakeMediaAccess(editorRoots: editorRoots) {
    thumbnails = FakeThumbnailSource(log);
    waveforms = FakeWaveformSource(log);
    jobs = FakeMediaJobs(log, validatePlans);
    exporter = FakeExportService(log);
    recorder = FakeVoiceRecorder(log).._onChanged = _recordingChanged;
    picker = FakeMediaPicker(log);
    files = FakeFileHandoff(log);
  }

  /// Shared call log and failure injection.
  final FakeCallLog log = FakeCallLog();

  /// Whether sessions run `PlanValidator` on every plan and throw `planInvalid` like a native
  /// engine would (ARCH §11.3).
  final bool validatePlans;

  /// Reported capabilities (tests may replace it).
  EditorCapabilities caps;

  /// Probe results by `ResolvedMedia.uri`.
  final Map<String, MediaProbe> probes;

  /// Compatibility by path (default [Editable]).
  final Map<String, EditCompatibility> compatibilityByPath;

  /// Every call, in order (`'openPreview'`, `'preview.seek'`, …).
  List<String> get calls => log.calls;

  /// Failures to throw from the next call of a method name (see [FakeCallLog]).
  Map<String, EngineFailure> get failNext => log.failNext;

  /// Open preview sessions.
  final List<FakePreviewSession> sessions = [];

  final StreamController<EngineSignal> _signals = StreamController<EngineSignal>.broadcast();

  void _call(String name) => log.hit(name);

  void _recordingChanged(bool recording) {
    for (final s in sessions) {
      s.audioMuted = recording;
    }
  }

  /// Emits an engine signal.
  void emitSignal(EngineSignal signal) => _signals.add(signal);

  @override
  Future<EditorCapabilities> capabilities() async {
    _call('capabilities');
    return caps;
  }

  @override
  Future<EditCompatibility> compatibility(String pathOrUri) async {
    _call('compatibility');
    return compatibilityByPath[pathOrUri] ?? const Editable();
  }

  @override
  Future<MediaProbe> probe(EngineMedia media) async {
    _call('probe');
    final p = probes[media.uri];
    if (p == null) throw EngineFailure.of(EngineErrorCode.mediaOffline, debugDetail: 'no fake probe');
    return p;
  }

  @override
  Future<PreviewSession> openPreview(PreviewConfig config) async {
    _call('openPreview');
    final s = FakePreviewSession(textureId: 100 + sessions.length, config: config, log: log, validatePlans: validatePlans)
      ..audioMuted = recorder.recording;
    sessions.add(s);
    return s;
  }

  @override
  late final FakeThumbnailSource thumbnails;

  @override
  late final FakeWaveformSource waveforms;

  @override
  late final FakeMediaJobs jobs;

  @override
  late final FakeExportService exporter;

  @override
  VoiceRecorder? get voiceRecorder => caps.voiceRecording ? recorder : null;

  /// The fake recorder (returned by [voiceRecorder] when supported).
  late final FakeVoiceRecorder recorder;

  @override
  late final FakeMediaPicker picker;

  @override
  late final FakeFileHandoff files;

  @override
  final FakeMediaAccess access;

  @override
  late final FakeBackgroundWorkGuard background = FakeBackgroundWorkGuard(log);

  @override
  final FakeExternalDropTarget drops = FakeExternalDropTarget();

  /// Value returned by [freeBytes].
  int freeBytesValue = 64 * 1024 * 1024 * 1024;

  @override
  Future<int> freeBytes(String path) async {
    _call('freeBytes');
    return freeBytesValue;
  }

  @override
  Stream<EngineSignal> get signals => _signals.stream;

  @override
  Future<void> trimCaches(CacheTrimLevel level) async => _call('trimCaches.${level.name}');
}

/// Fake preview: tracks the plan revision, applies patches, acks seeks on the frame grid.
///
/// Implements the normative semantics of ARCH §12.2: `seq` increases with every seek, play and
/// pause and each clock sample carries the `seq` of the last command it reflects; exact seeks ack
/// `timeOfFrame(frameIndexOf(t))`; patches apply only on a matching `from` revision; transients
/// never touch the revision.
final class FakePreviewSession implements PreviewSession {
  /// Creates a session.
  FakePreviewSession({required this.textureId, required this.config, FakeCallLog? log, this.validatePlans = true})
      : _log = log ?? FakeCallLog();

  @override
  final int textureId;

  /// Config it was opened with.
  final PreviewConfig config;

  /// Whether plans are validated with `PlanValidator` (throws `planInvalid`).
  final bool validatePlans;

  final FakeCallLog _log;
  final ValueNotifier<Size?> _frameSize = ValueNotifier<Size?>(null);
  final StreamController<PreviewClock> _clock = StreamController<PreviewClock>.broadcast();
  final StreamController<PreviewEvent> _events = StreamController<PreviewEvent>.broadcast();

  /// Current plan (null before [setPlan]).
  RenderPlan? plan;

  /// Active transients by item.
  final Map<String, PlanTransient> transients = {};

  /// Current editing mode.
  PreviewEditingMode mode = PreviewEditingMode.normal;

  /// Current quality.
  PreviewQuality quality = PreviewQuality.auto;

  /// Whether proxies are used.
  late bool useProxies = config.useProxies;

  /// Whether the session's audio is muted because a voice recording captures (INT-07; set by
  /// [FakeEditorEngine]).
  bool audioMuted = false;

  /// Whether playing.
  bool playing = false;

  /// Loop range of the current [play], if any.
  TimeRange? loop;

  /// Displayed plan time.
  TimeUs time = 0;

  /// Command sequence number.
  int seq = 0;

  /// Source frame shown by [showSourceFrame] until the next seek or play, as (media, time).
  (EngineMedia, TimeUs)? sourceFrame;

  /// Colour returned by [sampleColor].
  Color sampledColor = const Color(0xFF00FF00);

  /// Whether [dispose] was called.
  bool disposed = false;

  /// Frames a scrub seek may be off by (0 = exact; ARCH §12.2 allows ±1 GOP).
  int scrubOffsetFrames = 0;

  /// Whether seeks clamp to the last frame of the plan the session holds, as the production
  /// engines do (ENG-02). Off by default so tests that seek without a plan keep their frames; a
  /// test of "seek after a lengthening edit" turns it on.
  bool clampSeeksToPlan = false;

  /// Rendered ranges the engine would play from their files (D-45): set by [setRenderedRanges],
  /// pruned by every patch that touches a range ([patchTouchesRange]) and cleared by [setPlan].
  List<RenderedRange> renderedRanges = const [];

  /// Ranges dropped by patches and plans since the last [setRenderedRanges], in order.
  final List<RenderedRange> droppedRanges = [];

  FrameRate get _grid => FrameRate(plan?.canvas.gridFps ?? config.fps, 1);

  void _emitClock() {
    if (!_clock.isClosed) _clock.add(PreviewClock(time: time, playing: playing, rate: playing ? 1 : 0, seq: seq));
  }

  /// Emits [event] to [events] (tests simulate stalls, degradations and surface loss).
  void emitEvent(PreviewEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Advances the deterministic clock by [frames] project frames while playing and emits one
  /// clock sample (the real engines emit at 10 Hz). Wraps inside [loop]; stops and pauses at the
  /// plan end.
  void advanceFrames(int frames) {
    if (!playing || frames <= 0) return;
    final g = _grid;
    var k = g.frameIndexOf(time) + frames;
    final loopRange = loop;
    final end = plan?.durUs ?? 0;
    if (loopRange != null && loopRange.duration > 0) {
      final k0 = g.frameIndexOf(loopRange.start);
      final k1 = g.frameIndexOf(loopRange.end);
      if (k >= k1 && k1 > k0) k = k0 + (k - k0) % (k1 - k0);
    } else if (end > 0 && g.timeOfFrame(k) >= end) {
      k = g.frameIndexOf(end - 1);
      playing = false;
      seq++;
    }
    time = g.timeOfFrame(k);
    _emitClock();
  }

  @override
  ValueListenable<Size?> get frameSize => _frameSize;

  @override
  Future<PlanAck> setPlan(RenderPlan plan) async {
    _log.hit('preview.setPlan');
    _check(plan);
    final first = this.plan == null;
    this.plan = plan;
    transients.clear();
    droppedRanges.addAll(renderedRanges);
    renderedRanges = const [];
    _frameSize.value = Size(plan.canvas.w.toDouble(), plan.canvas.h.toDouble());
    if (first) emitEvent(const PreviewFirstFrame());
    return PlanAck(rev: plan.rev, structural: true, applyMs: 0);
  }

  void _check(RenderPlan p) {
    if (!validatePlans) return;
    final violations = PlanValidator.validate(p);
    if (violations.isNotEmpty) {
      throw EngineFailure.of(EngineErrorCode.planInvalid, debugDetail: violations.first.toString());
    }
  }

  @override
  Future<PlanAck> applyPatch(RenderPlanPatch patch) async {
    _log.hit('preview.applyPatch');
    final current = plan;
    if (current == null || current.rev != patch.from) {
      throw EngineFailure.of(EngineErrorCode.planOutOfSync, debugDetail: 'from ${patch.from} != ${current?.rev}');
    }
    final (next, structural) = applyFakePatch(current, patch);
    _check(next);
    plan = next;
    if (renderedRanges.isNotEmpty) {
      final kept = <RenderedRange>[];
      for (final r in renderedRanges) {
        (patchTouchesRange(current, patch, r.range) ? droppedRanges : kept).add(r);
      }
      renderedRanges = List.unmodifiable(kept);
    }
    for (final id in [...patch.layers.remove, ...patch.layers.upsert.map((l) => l.id)]) {
      transients.remove(PlanIds.itemOf(id));
    }
    return PlanAck(rev: next.rev, structural: structural, applyMs: 0);
  }

  @override
  void setTransient(ItemId item, PlanTransient transient) {
    _log.calls.add('preview.setTransient');
    transients[item] = transient;
  }

  @override
  void clearTransient(ItemId item) {
    _log.calls.add('preview.clearTransient');
    transients.remove(item);
  }

  @override
  Future<void> play({TimeRange? loop}) async {
    _log.hit('preview.play');
    playing = true;
    this.loop = loop;
    sourceFrame = null;
    seq++;
    _emitClock();
  }

  @override
  Future<void> pause() async {
    _log.hit('preview.pause');
    playing = false;
    seq++;
    _emitClock();
  }

  @override
  Future<SeekAck> seek(TimeUs t, {SeekKind kind = SeekKind.exact}) async {
    _log.hit('preview.seek');
    var k = _grid.frameIndexOf(t < 0 ? 0 : t);
    if (kind == SeekKind.scrub && k + scrubOffsetFrames >= 0) k += scrubOffsetFrames;
    final end = plan?.durUs ?? 0;
    if (clampSeeksToPlan && end > 0 && k > _grid.frameIndexOf(end - 1)) k = _grid.frameIndexOf(end - 1);
    time = _grid.timeOfFrame(k);
    sourceFrame = null;
    seq++;
    _emitClock();
    return SeekAck(requested: t, displayedFrameTime: time, displayedFrame: k, seq: seq);
  }

  @override
  Future<void> setQuality(PreviewQuality quality) async {
    _log.hit('preview.setQuality');
    this.quality = quality;
  }

  @override
  Future<void> setUseProxies(bool on) async {
    _log.hit('preview.setUseProxies');
    useProxies = on;
  }

  @override
  Future<void> setRenderedRanges(List<RenderedRange> ranges) async {
    _log.hit('preview.setRenderedRanges');
    final problem = renderedRangesProblem(ranges);
    if (problem != null) throw EngineFailure.of(EngineErrorCode.planInvalid, debugDetail: problem);
    renderedRanges = List.unmodifiable(ranges);
    droppedRanges.clear();
  }

  @override
  Future<void> setEditingMode(PreviewEditingMode mode) async {
    _log.hit('preview.setEditingMode');
    this.mode = mode;
  }

  @override
  Future<void> showSourceFrame(EngineMedia media, TimeUs sourceTime) async {
    _log.hit('preview.showSourceFrame');
    sourceFrame = (media, sourceTime);
  }

  @override
  Future<Color?> sampleColor(ItemId item, Offset normalizedSourcePoint) async {
    _log.hit('preview.sampleColor');
    return sampledColor;
  }

  @override
  Future<List<Uint8List>> renderLookStills(ItemId item, List<LookSpec> looks, {required int heightPx}) async {
    _log.hit('preview.renderLookStills');
    return [for (final _ in looks) Uint8List(0)];
  }

  @override
  Future<void> refresh() async => _log.hit('preview.refresh');

  @override
  Future<Uint8List> debugCaptureFrame() async {
    _log.hit('preview.debugCaptureFrame');
    final c = plan?.canvas;
    return Uint8List((c?.w ?? 2) * (c?.h ?? 2) * 4);
  }

  @override
  Stream<PreviewClock> get clock => _clock.stream;

  @override
  Stream<PreviewEvent> get events => _events.stream;

  @override
  Future<void> dispose() async {
    _log.calls.add('preview.dispose');
    disposed = true;
    playing = false;
    await _clock.close();
    await _events.close();
  }
}

/// Applies [patch] to [plan] the way engines do (ARCH §11.2 Patch): upsert replaces whole
/// objects by id, removals drop ids, layers and audio are re-sorted. Returns the new plan and
/// whether the change was structural (ARCH §11.2 patch classification). API-02/CORE-32 provide
/// the production `applyPatch`; this copy keeps the fake self-contained.
(RenderPlan, bool) applyFakePatch(RenderPlan plan, RenderPlanPatch patch) {
  var structural = patch.canvas != null || patch.durUs != null || patch.assetUpserts.isNotEmpty || patch.assetRemovals.isNotEmpty;
  final layers = {for (final l in plan.layers) l.id: l};
  for (final id in patch.layers.remove) {
    structural |= layers.remove(id) != null;
  }
  for (final l in patch.layers.upsert) {
    final old = layers[l.id];
    if (old == null ||
        old.kind != l.kind ||
        old.z != l.z ||
        old.t0 != l.t0 ||
        old.t1 != l.t1 ||
        old.asset != l.asset ||
        old.hold != l.hold ||
        old.seq != l.seq ||
        !_sameMap(old.map, l.map)) {
      structural = true;
    }
    layers[l.id] = l;
  }
  final audio = {for (final a in plan.audio) a.id: a};
  for (final id in patch.audio.remove) {
    structural |= audio.remove(id) != null;
  }
  for (final a in patch.audio.upsert) {
    final old = audio[a.id];
    if (old == null ||
        old.t0 != a.t0 ||
        old.t1 != a.t1 ||
        old.asset != a.asset ||
        old.stream != a.stream ||
        old.pitch != a.pitch ||
        !_sameMap(old.map, a.map)) {
      structural = true;
    }
    audio[a.id] = a;
  }
  final assets = {...plan.assets}..removeWhere((k, _) => patch.assetRemovals.contains(k));
  assets.addAll(patch.assetUpserts);
  final sortedLayers = layers.values.toList()
    ..sort((a, b) => a.z != b.z ? a.z.compareTo(b.z) : (a.t0 != b.t0 ? a.t0.compareTo(b.t0) : a.id.compareTo(b.id)));
  final sortedAudio = audio.values.toList()..sort((a, b) => a.t0 != b.t0 ? a.t0.compareTo(b.t0) : a.id.compareTo(b.id));
  return (
    plan.copyWith(
      rev: patch.to,
      canvas: patch.canvas,
      durUs: patch.durUs,
      assets: assets,
      layers: sortedLayers,
      audio: sortedAudio,
    ),
    structural,
  );
}

/// Whether applying [patch] to [before] touches the rendered [range] (ARCH §12.2, D-45): a
/// removed or upserted layer whose old or new span overlaps it, a canvas change, a duration change
/// when the range ends after the shorter duration, or a change to (or removal of) an asset
/// [before] already had. Audio changes never touch a range. The reference rule IOS-19 and AND-18
/// mirror natively.
bool patchTouchesRange(RenderPlan before, RenderPlanPatch patch, TimeRange range) {
  if (patch.canvas != null) return true;
  final dur = patch.durUs;
  if (dur != null && dur != before.durUs && range.end > (dur < before.durUs ? dur : before.durUs)) return true;
  if (patch.assetRemovals.any(before.assets.containsKey)) return true;
  for (final MapEntry(:key, :value) in patch.assetUpserts.entries) {
    final old = before.assets[key];
    if (old != null && old != value) return true;
  }
  bool overlaps(TimeUs t0, TimeUs t1) => t0 < range.end && range.start < t1;
  final old = {for (final l in before.layers) l.id: l};
  for (final id in patch.layers.remove) {
    final l = old[id];
    if (l != null && overlaps(l.t0, l.t1)) return true;
  }
  for (final l in patch.layers.upsert) {
    if (overlaps(l.t0, l.t1)) return true;
    final o = old[l.id];
    if (o != null && overlaps(o.t0, o.t1)) return true;
  }
  return false;
}

bool _sameMap(List<MapSegment> a, List<MapSegment> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A scriptable job. Completes when the test calls [complete] or [fail] (or at once when created
/// with [FakeMediaJob.done]).
///
/// See ARCH §12.3.
final class FakeMediaJob<T> implements MediaJob<T> {
  /// Creates a pending job. [onComplete] runs when it completes successfully, [onCancel] when it
  /// is cancelled before that (the render-preview stub uses them to write and delete its file).
  FakeMediaJob(this.id, {void Function(T value)? onComplete, void Function()? onCancel})
      : _onComplete = onComplete,
        _onCancel = onCancel {
    _result.future.ignore();
  }

  /// Creates a job that completes with [value] on the next microtask.
  FakeMediaJob.done(this.id, T value)
      : _onComplete = null,
        _onCancel = null {
    _result.future.ignore();
    scheduleMicrotask(() => complete(value));
  }

  @override
  final String id;

  final void Function(T value)? _onComplete;
  final void Function()? _onCancel;
  final StreamController<double> _progress = StreamController<double>.broadcast();
  final Completer<T> _result = Completer<T>();

  /// Current priority.
  JobPriority priority = JobPriority.normal;

  /// Whether [cancel] was called.
  bool cancelled = false;

  @override
  Stream<double> get progress => _progress.stream;

  @override
  Future<T> get result => _result.future;

  /// Reports progress.
  void report(double fraction) => _progress.add(fraction);

  /// Completes successfully.
  void complete(T value) {
    if (_result.isCompleted) return;
    _onComplete?.call(value);
    _progress.add(1);
    _result.complete(value);
    unawaited(_progress.close());
  }

  /// Completes with [failure].
  void fail(EngineFailure failure) {
    if (_result.isCompleted) return;
    _result.completeError(failure);
    unawaited(_progress.close());
  }

  @override
  void cancel() {
    if (_result.isCompleted) {
      cancelled = true;
      return;
    }
    cancelled = true;
    _onCancel?.call();
    fail(const EngineCancelled());
  }

  @override
  void setPriority(JobPriority priority) => this.priority = priority;
}

/// Fake thumbnails: empty JPEG strips.
///
/// See ARCH §12.3.
final class FakeThumbnailSource implements ThumbnailSource {
  /// Creates the fake.
  FakeThumbnailSource([FakeCallLog? log]) : _log = log ?? FakeCallLog();

  final FakeCallLog _log;

  /// Requests received.
  final List<ThumbnailRequest> requests = [];

  /// Priorities of [requests], in order.
  final List<ThumbPriority> priorities = [];

  @override
  ThumbnailHandle request(ThumbnailRequest request, {required ThumbPriority priority}) {
    requests.add(request);
    priorities.add(priority);
    final failure = _log.record('thumbnails.request');
    final handle = FakeThumbnailHandle._();
    if (failure != null) {
      handle._complete(failure: failure);
    } else {
      handle._complete(tile: ThumbnailTile(encoded: Uint8List(0), frames: request.framesPerTile, frameWidthPx: request.heightPx * 16 ~/ 9));
    }
    return handle;
  }
}

/// Handle of a fake thumbnail request. Completes on the next microtask unless cancelled first;
/// [cancelled] tells whether [cancel] won the race.
///
/// See ARCH §12.3.
final class FakeThumbnailHandle implements ThumbnailHandle {
  FakeThumbnailHandle._() {
    _result.future.ignore();
  }

  final Completer<ThumbnailTile> _result = Completer<ThumbnailTile>();

  /// Whether [cancel] completed the request with `EngineCancelled`.
  bool cancelled = false;

  void _complete({ThumbnailTile? tile, EngineFailure? failure}) {
    scheduleMicrotask(() {
      if (_result.isCompleted) return;
      if (failure != null) {
        _result.completeError(failure);
      } else {
        _result.complete(tile);
      }
    });
  }

  @override
  Future<ThumbnailTile> get result => _result.future;

  @override
  void cancel() {
    if (_result.isCompleted) return;
    cancelled = true;
    _result.completeError(const EngineCancelled());
  }
}

/// Fake waveforms: flat peaks.
///
/// See ARCH §12.3.
final class FakeWaveformSource implements WaveformSource {
  /// Creates the fake.
  FakeWaveformSource([FakeCallLog? log]) : _log = log ?? FakeCallLog();

  final FakeCallLog _log;
  var _n = 0;

  @override
  MediaJob<WaveformPeaks> peaks(EngineMedia media, {int audioStream = 0}) {
    final failure = _log.record('waveforms.peaks');
    final id = 'wave-${_n++}';
    if (failure == null) return FakeMediaJob<WaveformPeaks>.done(id, WaveformPeaks(minMax: Int8List(400), duration: 1000000));
    return FakeMediaJob<WaveformPeaks>(id)..fail(failure);
  }
}

/// Fake media jobs; every job is pending until the test completes it via [created], except
/// render previews, which render instantly to a stub file unless [holdRenders] is set.
///
/// See ARCH §12.3, D-45.
final class FakeMediaJobs implements MediaJobs {
  /// Creates the fake. [validatePlans] makes [renderPreview] refuse invalid range plans with
  /// `planInvalid`, like a native engine.
  FakeMediaJobs([FakeCallLog? log, bool validatePlans = true])
      : _log = log ?? FakeCallLog(),
        _validatePlans = validatePlans;

  final FakeCallLog _log;
  final bool _validatePlans;
  var _n = 0;

  /// Stub files written by [renderPreview] (paths), deleted again when a render is cancelled.
  final Set<String> files = {};

  /// Range plans and output paths passed to [renderPreview], in order.
  final List<(RenderPlan, String)> renderRequests = [];

  /// When true, render previews stay pending until the test completes them (through [created])
  /// instead of rendering on the next microtask; completing one still writes its stub file.
  bool holdRenders = false;

  /// Jobs created, in order.
  final List<FakeMediaJob<Object?>> created = [];

  /// Proxy status by fingerprint.
  final Map<String, ProxyStatus> proxyStates = {};

  FakeMediaJob<T> _job<T>(String kind) {
    final failure = _log.record('jobs.$kind');
    final j = FakeMediaJob<T>('$kind-${_n++}');
    created.add(j as FakeMediaJob<Object?>);
    if (failure != null) j.fail(failure);
    return j;
  }

  @override
  MediaJob<GeneratedAsset> proxy(EngineMedia media) => _job<GeneratedAsset>('proxy');

  @override
  MediaJob<GeneratedAsset> reverse(EngineMedia media, TimeRange source, {required String outputPath}) => _job<GeneratedAsset>('reverse');

  @override
  MediaJob<GeneratedAsset> freezeFrame(EngineMedia media, TimeUs sourceTime, {required String outputPath}) =>
      _job<GeneratedAsset>('freezeFrame');

  @override
  MediaJob<ExtractedSpeechAudio> extractSpeechAudio(SpeechAudioJobRequest request) => _job<ExtractedSpeechAudio>('extractSpeechAudio');

  /// Renders instantly (next microtask) to a stub file at [outputPath] (recorded in [files]);
  /// cancel before that deletes it and fails with `EngineCancelled`. Refuses an export-target or
  /// invalid plan with `planInvalid` and an output outside a `renders/` directory with
  /// `permissionDenied`, like the native glue. Default priority `background`.
  @override
  MediaJob<GeneratedAsset> renderPreview(RenderPlan rangePlan, {required String outputPath}) {
    renderRequests.add((rangePlan, outputPath));
    final injected = _log.record('jobs.renderPreview');
    final j = FakeMediaJob<GeneratedAsset>(
      'renderPreview-${_n++}',
      onComplete: (a) => files.add(a.path),
      onCancel: () => files.remove(outputPath),
    )..priority = JobPriority.background;
    created.add(j as FakeMediaJob<Object?>);
    final failure = injected ?? _renderProblem(rangePlan, outputPath);
    if (failure != null) {
      j.fail(failure);
    } else if (!holdRenders) {
      scheduleMicrotask(() => j.complete(GeneratedAsset(path: outputPath, sizeBytes: 1024, duration: rangePlan.durUs)));
    }
    return j;
  }

  EngineFailure? _renderProblem(RenderPlan plan, String outputPath) {
    if (plan.target != PlanTarget.preview) {
      return EngineFailure.of(EngineErrorCode.planInvalid, debugDetail: 'renderPreview needs a preview plan');
    }
    if (_validatePlans) {
      final violations = PlanValidator.validate(plan);
      if (violations.isNotEmpty) return EngineFailure.of(EngineErrorCode.planInvalid, debugDetail: violations.first.toString());
    }
    final segments = outputPath.split('/');
    if (!outputPath.startsWith('/') || segments.length < 3 || segments[segments.length - 2] != renderPreviewDirName) {
      return EngineFailure.of(EngineErrorCode.permissionDenied, debugDetail: 'outputPath is not inside $renderPreviewDirName/');
    }
    return null;
  }

  @override
  ProxyStatus proxyStatus(EngineMedia media) => proxyStates[media.fingerprint] ?? ProxyStatus.none;
}

/// A scriptable export job.
///
/// See ARCH §12.4.
final class FakeExportJob implements ExportJob {
  /// Creates a job.
  FakeExportJob(this.id, this.outputPath, this.durationUs) {
    _result.future.ignore();
  }

  @override
  final String id;

  /// Output path.
  final String outputPath;

  /// Plan duration.
  final TimeUs durationUs;

  final StreamController<ExportProgress> _progress = StreamController<ExportProgress>.broadcast();
  final Completer<ExportResult> _result = Completer<ExportResult>();

  @override
  Stream<ExportProgress> get progress => _progress.stream;

  @override
  Future<ExportResult> get result => _result.future;

  /// Reports progress.
  void report(double fraction, {ExportPhase phase = ExportPhase.rendering, bool pausedInBackground = false, bool backgrounded = false}) {
    if (_progress.isClosed) return;
    _progress.add(ExportProgress(phase: phase, fraction: fraction, pausedInBackground: pausedInBackground, backgrounded: backgrounded));
  }

  /// Whether [cancel] was called.
  bool cancelled = false;

  /// Completes successfully.
  void finish() {
    if (_result.isCompleted) return;
    _result.complete(ExportResult(path: outputPath, bytes: 0, duration: durationUs, videoEncoderName: 'fake', hardwareEncoder: false));
    unawaited(_progress.close());
  }

  /// Fails.
  void fail(EngineFailure failure) {
    if (_result.isCompleted) return;
    _result.completeError(failure);
    unawaited(_progress.close());
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    fail(const EngineCancelled());
  }
}

/// Fake export service with scriptable job records.
///
/// See ARCH §12.4, D-22, D-39.
final class FakeExportService implements ExportService {
  /// Creates the fake.
  FakeExportService([FakeCallLog? log]) : _log = log ?? FakeCallLog();

  final FakeCallLog _log;
  var _n = 0;

  /// Records returned by [activeJobs] (one-shot ones until consumed).
  final List<ExportJobState> records = [];

  /// Jobs started or resumed.
  final List<FakeExportJob> started = [];

  /// Preflight result.
  ExportPreflight preflightResult = const ExportPreflight(ok: true);

  /// Last `whenDetached` passed to [start].
  ExportDetachedHandoff? lastWhenDetached;

  /// Notification texts passed to each [start], in order (null when the call passed none; INT-07).
  final List<ExportNotificationTexts?> notificationTexts = [];

  @override
  Future<ExportPreflight> preflight(RenderPlan plan, EncodeSettings settings) async {
    _log.hit('exporter.preflight');
    return preflightResult;
  }

  @override
  Future<ExportJob> start(RenderPlan plan, EncodeSettings settings,
      {required String outputPath,
      required String title,
      ExportDetachedHandoff whenDetached = ExportDetachedHandoff.saveToGallery,
      ExportNotificationTexts? notificationTexts}) async {
    _log.hit('exporter.start');
    lastWhenDetached = whenDetached;
    this.notificationTexts.add(notificationTexts);
    final job = FakeExportJob('export-${_n++}', outputPath, plan.durUs);
    started.add(job);
    records.add(ExportRunning(job));
    unawaited(
        job.result.then((_) {}, onError: (_) {}).whenComplete(() => records.removeWhere((r) => r is ExportRunning && r.jobId == job.id)));
    return job;
  }

  @override
  Future<ExportJob> resume(String jobId) async {
    _log.hit('exporter.resume');
    final i = records.indexWhere((r) => r is ExportResumable && r.jobId == jobId);
    if (i < 0) throw EngineFailure.of(EngineErrorCode.notSupportedOnDevice, debugDetail: 'not resumable');
    records.removeAt(i);
    final job = FakeExportJob(jobId, '/fake/cache/danaview/editor/work/export-$jobId.mp4', 0);
    started.add(job);
    records.add(ExportRunning(job));
    return job;
  }

  @override
  Future<List<ExportJobState>> activeJobs() async {
    _log.hit('exporter.activeJobs');
    return List.unmodifiable(records);
  }

  @override
  Future<void> consumeJobRecord(String jobId) async {
    _log.hit('exporter.consumeJobRecord');
    records.removeWhere((r) => r.jobId == jobId && (r is ExportInterrupted || r is ExportCompletedWhileDetached));
  }
}

/// Fake recorder: always granted, records nothing. It is recording from [start] until the
/// session stops, is cancelled or is interrupted (INT-07).
///
/// See ARCH §12.4, §15.
final class FakeVoiceRecorder implements VoiceRecorder {
  /// Creates the fake.
  FakeVoiceRecorder([FakeCallLog? log]) : _log = log ?? FakeCallLog();

  final FakeCallLog _log;
  final StreamController<bool> _changes = StreamController<bool>.broadcast(sync: true);
  void Function(bool recording)? _onChanged;
  final Set<FakeRecordingSession> _capturing = {};

  /// Whether a session is capturing now (synchronous view of [isRecording]).
  bool get recording => _capturing.isNotEmpty;

  void _setCapturing(FakeRecordingSession s, bool on) {
    final before = recording;
    if (on) {
      _capturing.add(s);
    } else {
      _capturing.remove(s);
    }
    if (recording != before) {
      _onChanged?.call(recording);
      _changes.add(recording);
    }
  }

  /// Permission reported.
  MicPermission permissionState = MicPermission.granted;

  /// Permission granted by [requestPermission] (null = unchanged).
  MicPermission? permissionAfterRequest;

  /// Sessions started, in order.
  final List<FakeRecordingSession> sessions = [];

  @override
  Future<MicPermission> permission() async {
    _log.hit('recorder.permission');
    return permissionState;
  }

  @override
  Future<MicPermission> requestPermission() async {
    _log.hit('recorder.requestPermission');
    return permissionState = permissionAfterRequest ?? permissionState;
  }

  @override
  Future<void> openSystemSettings() async => _log.hit('recorder.openSystemSettings');

  @override
  Future<RecordingSession> start({required String outputPath}) async {
    _log.hit('recorder.start');
    if (permissionState != MicPermission.granted) throw EngineFailure.of(EngineErrorCode.permissionDenied);
    if (recording) throw EngineFailure.of(EngineErrorCode.busy, debugDetail: 'one recording at a time');
    final s = FakeRecordingSession(outputPath, onEnded: (s) => _setCapturing(s, false));
    sessions.add(s);
    _setCapturing(s, true);
    return s;
  }

  @override
  Future<bool> isRecording() async {
    _log.hit('recorder.isRecording');
    return recording;
  }

  @override
  Stream<bool> get recordingChanged => _changes.stream;
}

/// A fake recording; tests push levels and interruptions.
///
/// See ARCH §12.4.
final class FakeRecordingSession implements RecordingSession {
  /// Creates a session writing (nominally) to [path]; [onEnded] runs once when it stops capturing.
  FakeRecordingSession(this.path, {void Function(FakeRecordingSession)? onEnded}) : _onEnded = onEnded;

  /// WAV path.
  final String path;

  void Function(FakeRecordingSession)? _onEnded;

  void _ended() {
    final f = _onEnded;
    _onEnded = null;
    f?.call(this);
  }

  final StreamController<double> _levels = StreamController<double>.broadcast();
  final StreamController<RecordingInterruption> _interruptions = StreamController<RecordingInterruption>.broadcast();

  /// Duration reported by [stop].
  TimeUs durationUs = 3000000;

  /// Whether [stop] was called.
  bool stopped = false;

  /// Whether [cancel] was called.
  bool cancelled = false;

  /// Emits an input level.
  void emitLevel(double level) => _levels.add(level);

  /// Emits an interruption and stops, keeping the file.
  void interrupt(RecordingInterruption why) {
    _interruptions.add(why);
    stopped = true;
    _ended();
  }

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Stream<RecordingInterruption> get interruptions => _interruptions.stream;

  @override
  Future<RecordedAsset> stop() async {
    stopped = true;
    _ended();
    await _levels.close();
    await _interruptions.close();
    return RecordedAsset(path: path, durationUs: durationUs, startLatencyUs: 20000);
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    _ended();
    await _levels.close();
    await _interruptions.close();
  }
}

/// Fake picker returning [nextPicks] once.
///
/// See ARCH §12.4.
final class FakeMediaPicker implements MediaPicker {
  /// Creates the fake.
  FakeMediaPicker([FakeCallLog? log]) : _log = log ?? FakeCallLog();

  final FakeCallLog _log;

  /// Items the next [pick] returns.
  List<PickedMedia> nextPicks = const [];

  /// Requests received.
  final List<MediaPickRequest> requests = [];

  @override
  Future<List<PickedMedia>> pick(MediaPickRequest request) async {
    _log.hit('picker.pick');
    requests.add(request);
    final out = nextPicks;
    nextPicks = const [];
    return out;
  }
}

/// Fake handoff (always succeeds).
///
/// See ARCH §12.4.
final class FakeFileHandoff implements FileHandoff {
  /// Creates the fake.
  FakeFileHandoff([FakeCallLog? log]) : _log = log ?? FakeCallLog();

  final FakeCallLog _log;

  /// Actions taken (`'photos'`, `'files'`, `'share'`).
  final List<String> log = [];

  @override
  Future<FileHandoffResult> saveToPhotos(String path) async {
    _log.hit('files.saveToPhotos');
    log.add('photos');
    return const FileHandoffResult(FileHandoffOutcome.done, savedUri: 'fake://photos/1');
  }

  @override
  Future<FileHandoffResult> saveToFiles(String path, String suggestedName) async {
    _log.hit('files.saveToFiles');
    log.add('files');
    return const FileHandoffResult(FileHandoffOutcome.done);
  }

  @override
  Future<FileHandoffResult> share(String path) async {
    _log.hit('files.share');
    log.add('share');
    return const FileHandoffResult(FileHandoffOutcome.done);
  }
}

/// Fake media access over fake paths. `excludeFromBackup` refuses paths outside [editorRoots]
/// exactly like the real implementations must (D-44); `materializePick` refuses directories
/// outside [workRoot] (INT-07).
///
/// See ARCH §9, §12.4, D-44.
final class FakeMediaAccess implements MediaAccess {
  /// Creates the fake.
  FakeMediaAccess({required this.editorRoots, this.workRoot = '/fake/cache/danaview/editor/work'});

  /// Roots where `excludeFromBackup` is allowed.
  final List<String> editorRoots;

  /// `<cache>/danaview/editor/work`: `materializePick` only writes below it.
  final String workRoot;

  /// Copies made by [materializePick] (absolute paths, in order).
  final List<String> materialized = [];

  /// Error the next [materializePick] throws (consumed when hit).
  Object? materializeFailure;

  var _copies = 0;

  /// URIs reported missing by [stat].
  final Set<String> missing = {};

  /// Directories excluded from backup.
  final List<String> excluded = [];

  /// Remaining persisted-grant budget.
  int grantBudget = 500;

  String _uriOf(MediaLocator l) => switch (l) {
        AppRelativeLocator(:final root, :final relPath) => 'file:///fake/${root.name}/$relPath',
        FileLocator(:final path) => Uri.file(path).toString(),
        ContentUriLocator(:final uri) => uri,
        BookmarkLocator(:final lastKnownPath) => Uri.file(lastKnownPath.isEmpty ? '/fake/bookmark' : lastKnownPath).toString(),
      };

  @override
  Future<ResolvedMedia> resolve(MediaLocator locator) async {
    final uri = _uriOf(locator);
    if (missing.contains(uri)) throw const MediaAccessFailure(MediaAccessFailureKind.notFound);
    return ResolvedMedia(uri: uri, fingerprint: 'fake-${uri.length}-${uri.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff)}');
  }

  @override
  Future<MediaStat?> stat(MediaLocator locator) async => missing.contains(_uriOf(locator)) ? null : const MediaStat(sizeBytes: 1024);

  @override
  Future<String> quickHash(MediaLocator locator) async => (await resolve(locator)).fingerprint;

  @override
  Future<MediaLocator> persist(PickedMediaHandle handle) async =>
      handle.uri.startsWith('content://') ? ContentUriLocator(handle.uri) : FileLocator(Uri.parse(handle.uri).toFilePath());

  @override
  Future<void> release(MediaLocator locator) async {}

  @override
  Future<void> excludeFromBackup(String dirPath) async {
    if (!editorRoots.any((r) => dirPath == r || dirPath.startsWith('$r/'))) {
      throw const MediaAccessFailure(MediaAccessFailureKind.outsideEditorRoots);
    }
    excluded.add(dirPath);
  }

  @override
  Future<int> remainingGrantBudget() async => grantBudget;

  @override
  Future<bool> requestNotificationPermission() async => true;

  bool _inWork(String path) => path.startsWith('$workRoot/') && !path.split('/').contains('..');

  @override
  Future<String> materializePick(PickedMedia picked, String intoDir) async {
    final f = materializeFailure;
    materializeFailure = null;
    if (f != null) throw f;
    final dir = intoDir.endsWith('/') ? intoDir.substring(0, intoDir.length - 1) : intoDir;
    if (!_inWork('$dir/x')) throw const MediaAccessFailure(MediaAccessFailureKind.outsideEditorRoots);
    if (missing.contains(picked.uri)) throw const MediaAccessFailure(MediaAccessFailureKind.notFound);
    final sourcePath = picked.uri.startsWith('file://') ? Uri.parse(picked.uri).toFilePath() : (picked.uri.startsWith('/') ? picked.uri : null);
    if (picked.isTemporaryCopy && sourcePath != null && _inWork(sourcePath)) return sourcePath;
    if (!picked.uri.startsWith('content://') && sourcePath == null) {
      throw const MediaAccessFailure(MediaAccessFailureKind.io, 'notSupportedOnDevice');
    }
    final safe = picked.displayName.replaceAll(RegExp(r'[/\\:\x00]'), '_').trim();
    final name = safe.isEmpty || safe == '.' || safe == '..' ? 'pick' : safe;
    final out = '$dir/m${_copies++}/$name';
    materialized.add(out);
    return out;
  }
}

/// Fake background guard (leases always granted) with a scripted power state.
///
/// See ARCH §12.4, D-45.
final class FakeBackgroundWorkGuard implements BackgroundWorkGuard {
  /// Creates the fake; `background.powerState` is logged in [log] (and can be failed through it).
  FakeBackgroundWorkGuard([FakeCallLog? log]) : _log = log ?? FakeCallLog();

  final FakeCallLog _log;
  var _n = 0;
  PowerState _power = const PowerState(charging: false, lowPowerMode: false);
  final StreamController<PowerState> _powerChanges = StreamController<PowerState>.broadcast();

  /// The power state [powerState] reports (not charging, no low-power mode by default).
  PowerState get power => _power;

  /// Changes the scripted power state and emits it on [powerStateChanged] when it differs.
  void setPowerState(PowerState state) {
    if (state == _power) return;
    _power = state;
    _powerChanges.add(state);
  }

  @override
  Future<PowerState> powerState() async {
    _log.hit('background.powerState');
    return _power;
  }

  @override
  Stream<PowerState> get powerStateChanged => _powerChanges.stream;

  /// Leases currently held.
  final Set<String> held = {};

  @override
  Future<BackgroundLease?> acquire({required String title, required Stream<double> progress}) async {
    final id = 'lease-${_n++}';
    held.add(id);
    return _FakeLease(id, held);
  }
}

final class _FakeLease implements BackgroundLease {
  _FakeLease(this.id, this._held);

  @override
  final String id;

  final Set<String> _held;

  @override
  Stream<void> get expiring => const Stream.empty();

  @override
  Future<void> release() async => _held.remove(id);
}

/// Fake drop target; tests push drops with [simulateDrop].
///
/// See ARCH §12.4, D-18.
final class FakeExternalDropTarget implements ExternalDropTarget {
  final StreamController<ExternalDrop> _drops = StreamController<ExternalDrop>.broadcast();

  /// Whether drops are enabled.
  bool enabled = false;

  /// Delivers [drop] when enabled.
  void simulateDrop(ExternalDrop drop) {
    if (enabled) _drops.add(drop);
  }

  @override
  Future<void> setEnabled(bool on) async => enabled = on;

  @override
  Stream<ExternalDrop> get drops => _drops.stream;
}
