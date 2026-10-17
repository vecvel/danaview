// OWNER: AI-07
//
// Scriptable in-memory DvBindings (ai.md §16.1 "FakeDvBindings"): tests drive model and job state
// by mutating FakeModel / FakeJob and read back every call the runtime made.

import 'dart:convert';

import 'package:danaview_whisper/src/runtime/dv_bindings.dart';

/// A fake native model.
final class FakeModel {
  FakeModel(this.path, this.params);

  final String path;
  final DvModelParams params;
  int state = DvModelState.loading;
  DvModelInfoData info = const DvModelInfoData(multilingual: true, nVocab: 51865);
  DvModelErrorData error = const DvModelErrorData(DvStatus.modelLoad, 'bad ggml magic');
  bool released = false;
}

/// A fake native job.
final class FakeJob {
  FakeJob(this.model, this.params);

  final int model;
  final DvJobParams params;
  int state = DvJobState.running;
  int error = DvStatus.ok;
  int phase = 0;
  int permille = 0;
  int chunkIndex = 0;
  int chunkCount = 0;
  int chunksCompleted = 0;
  int processedMs = 0;
  int computeMs = 0;
  late int threads = params.nThreads;
  String language = '';
  double languageP = 0;
  final List<String> segments = [];
  String? languageJson;
  int cancels = 0;
  final List<bool> pauses = [];
  int resumes = 0;
  final List<int> threadCalls = [];
  int frees = 0;
  int statusReads = 0;
  final List<(int, int)> takes = [];

  /// Publishes [n] segments of [chunk] (text "s<i>") as the shim does when a chunk completes.
  void addChunk(int chunk, int n, {int startMs = 0}) {
    for (var k = 0; k < n; k++) {
      final i = segments.length;
      segments.add(segmentJson(i: i, c: chunk, t0: startMs + k * 1000, t1: startMs + k * 1000 + 900, text: 's$i'));
    }
    chunksCompleted = chunk + 1;
  }
}

/// A schema-1 segment document.
String segmentJson({
  required int i,
  required int c,
  required int t0,
  required int t1,
  required String text,
  double nsp = 0.01,
  double lp = -0.2,
  List<Map<String, Object?>>? words,
}) =>
    jsonEncode({
      'i': i,
      'c': c,
      't0': t0,
      't1': t1,
      'text': text,
      'nsp': nsp,
      'lp': lp,
      'w': words ?? [
            {'t': text, 't0': t0, 't1': t1, 'p': 0.9},
          ],
    });

/// The fake bindings.
class FakeDvBindings implements DvBindings {
  int abi = 1;
  String engine = '1.9.4';
  int hwcap = 0;
  int logLevel = 2;
  int shutdownCalls = 0;
  int startStatus = DvStatus.ok;
  bool throwOnStart = false;

  /// Overrides `take_segments_json` (malformed-JSON tests).
  String? Function(FakeJob job, int from, int max)? takeOverride;

  final Map<int, FakeModel> models = {};
  final Map<int, FakeJob> jobs = {};
  final List<String> calls = [];
  int _next = 0x1000;

  FakeModel get lastModel => models.values.last;
  FakeJob get lastJob => jobs.values.last;
  int get liveModels => models.values.where((m) => !m.released).length;

  @override
  int abiVersion() => abi;

  @override
  String engineVersion() => engine;

  @override
  int cpuFeatures() => hwcap;

  @override
  void setLogLevel(int level) => logLevel = level;

  @override
  Future<void> shutdownAll() async {
    shutdownCalls++;
    calls.add('shutdownAll');
    for (final j in jobs.values) {
      if (!DvJobState.isTerminal(j.state)) j.state = DvJobState.cancelled;
    }
    for (final m in models.values) {
      m.released = true;
    }
  }

  @override
  int modelLoad(String path, DvModelParams params) {
    calls.add('modelLoad');
    if (path.isEmpty) return 0;
    final h = _next += 0x10;
    models[h] = FakeModel(path, params);
    return h;
  }

  @override
  int modelState(int model) => models[model]?.state ?? DvModelState.failed;

  @override
  DvModelErrorData modelError(int model) => models[model]?.error ?? const DvModelErrorData(DvStatus.invalidArg);

  @override
  DvModelInfoData? modelInfo(int model) {
    final m = models[model];
    return m != null && m.state == DvModelState.ready ? m.info : null;
  }

  @override
  Future<void> modelRelease(int model) async {
    calls.add('modelRelease');
    models[model]?.released = true;
  }

  @override
  Future<DvJobStartResult> jobStart(int model, DvJobParams params) async {
    calls.add('jobStart');
    if (throwOnStart) throw StateError('isolate failed');
    if (startStatus != DvStatus.ok) return DvJobStartResult(0, startStatus);
    final h = _next += 0x10;
    jobs[h] = FakeJob(model, params);
    return DvJobStartResult(h, DvStatus.ok);
  }

  @override
  DvJobStatusData jobStatus(int job) {
    final j = jobs[job];
    if (j == null || j.frees > 0) return const DvJobStatusData(state: DvJobState.failed, error: DvStatus.invalidArg);
    j.statusReads++;
    return DvJobStatusData(
      state: j.state,
      error: j.error,
      phase: j.phase,
      progressPermille: j.permille,
      chunkIndex: j.chunkIndex,
      chunkCount: j.chunkCount,
      chunksCompleted: j.chunksCompleted,
      segmentsReady: j.segments.length,
      processedMs: j.processedMs,
      computeMs: j.computeMs,
      threads: j.threads,
      language: j.language,
      languageP: j.languageP,
    );
  }

  @override
  String? jobTakeSegmentsJson(int job, int from, int max) {
    final j = jobs[job];
    if (j == null || j.frees > 0) return null;
    j.takes.add((from, max));
    final o = takeOverride;
    if (o != null) return o(j, from, max);
    if (max <= 0) return '[]';
    final end = (from + max).clamp(0, j.segments.length);
    return '[${j.segments.sublist(from.clamp(0, end), end).join(',')}]';
  }

  @override
  String? jobLanguageJson(int job, int topN) => jobs[job]?.languageJson;

  @override
  void jobCancel(int job) {
    calls.add('jobCancel');
    jobs[job]?.cancels++;
  }

  @override
  void jobPause(int job, {required bool abortCurrentChunk}) {
    calls.add('jobPause($abortCurrentChunk)');
    jobs[job]?.pauses.add(abortCurrentChunk);
  }

  @override
  void jobResume(int job) {
    calls.add('jobResume');
    jobs[job]?.resumes++;
  }

  @override
  void jobSetThreads(int job, int threads) {
    calls.add('jobSetThreads($threads)');
    jobs[job]?.threadCalls.add(threads);
  }

  @override
  Future<void> jobFree(int job) async {
    calls.add('jobFree');
    final j = jobs[job];
    if (j == null) return;
    j.frees++;
    if (!DvJobState.isTerminal(j.state)) j.state = DvJobState.cancelled;
  }
}
