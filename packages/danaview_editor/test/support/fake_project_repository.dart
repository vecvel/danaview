// OWNER: UX-01
//
// FakeProjectRepository for danaview_editor widget tests (ux.md §21.2).
//
// CORE-25's `InMemoryProjectRepository` (danaview_editor_core `testing.dart`) is still a placeholder,
// so this is the stub the ticket allows: an in-memory store with seedable projects, a call log and
// one-shot failure injection. When CORE-25 lands, this class keeps its API and may delegate to
// `InMemoryProjectRepository` (BUILD_PLAN UX-01).
//
// Projects created through [create] are empty timelines (media import is CORE-27's job) with the
// spec's origin and quantized initial playhead; `save` needs core's `EditSession` (CORE-19).

import 'dart:async';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditSession;
import 'package:danaview_editor_core/store.dart';

/// An in-memory [ProjectRepository] for widget tests.
class FakeProjectRepository implements ProjectRepository {
  /// Creates an empty repository. [clock] defaults to a fixed UTC time so tests are deterministic.
  FakeProjectRepository({DateTime Function()? clock, IdGenerator? ids})
      : _clock = clock ?? (() => DateTime.utc(2026, 10, 8, 12)),
        _ids = ids ?? SeededIdGenerator(7);

  final DateTime Function() _clock;
  final IdGenerator _ids;

  /// Stored projects by id.
  final Map<ProjectId, EditProject> projects = <ProjectId, EditProject>{};

  /// Open projects (a second `open` fails with `busy`, like the real store).
  final Set<ProjectId> openProjects = <ProjectId>{};

  /// Every call, as `method` or `method:<id>`.
  final List<String> calls = <String>[];

  /// One-shot failures: the next call of the named method throws this value (then it is removed).
  /// Keys are method names (`open`, `save`, `create`, `rename`, `duplicate`, `delete`, …).
  final Map<String, Object> failNext = <String, Object>{};

  /// Sessions offered by [recoverable].
  final List<RecoverableSession> recoverableSessions = <RecoverableSession>[];

  /// Per-project results of [open] beyond the project itself (health, warnings, recovery).
  final Map<ProjectId, LoadedProject Function(EditProject project)> openResults = {};

  /// Results of [findUntouchedProjectFor] by path or URI.
  final Map<String, ProjectId> untouchedByPath = <String, ProjectId>{};

  /// What [storageReport] returns.
  ProjectStorageReport report = const ProjectStorageReport();

  /// Every spec passed to [create], in order.
  final List<NewProjectSpec> createdSpecs = <NewProjectSpec>[];

  /// Number of [requestAutosave] calls.
  int autosaveRequests = 0;

  final StreamController<List<ProjectSummary>> _summaries = StreamController<List<ProjectSummary>>.broadcast();

  /// Adds [project] (replacing one with the same id) and returns its id.
  ProjectId seed(EditProject project) {
    projects[project.id] = project;
    _emit();
    return project.id;
  }

  /// Adds an empty project named [name] and returns it.
  EditProject seedEmpty(String name, {ProjectId? id, ProjectSettings settings = const ProjectSettings()}) {
    final now = _clock();
    final project = EditProject(
      id: id ?? _ids.projectId(),
      meta: ProjectMeta(name: name, createdAt: now, updatedAt: now),
      timeline: Timeline(settings: settings),
    );
    seed(project);
    return project;
  }

  /// The current summaries, newest first.
  List<ProjectSummary> get summaries {
    final list = projects.values.map(summaryOf).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(list);
  }

  /// The summary the fake reports for [project].
  ProjectSummary summaryOf(EditProject project) => ProjectSummary(
        id: project.id,
        name: project.name,
        updatedAt: project.meta.updatedAt,
        duration: project.duration,
        aspect: project.settings.canvas.aspect,
        hasRecovery: recoverableSessions.any((s) => s.projectId == project.id),
      );

  /// Closes the summaries stream.
  Future<void> dispose() => _summaries.close();

  void _emit() {
    if (!_summaries.isClosed) _summaries.add(summaries);
  }

  void _call(String method, [ProjectId? id]) {
    calls.add(id == null ? method : '$method:$id');
    final failure = failNext.remove(method);
    if (failure != null) throw failure;
  }

  EditProject _require(ProjectId id) {
    final p = projects[id];
    if (p == null) throw const StoreFailure(StoreFailureKind.notFound);
    return p;
  }

  @override
  Stream<List<ProjectSummary>> watchSummaries() async* {
    calls.add('watchSummaries');
    yield summaries;
    yield* _summaries.stream;
  }

  @override
  Future<ProjectId> create(NewProjectSpec spec) async {
    _call('create');
    final name = switch (spec) {
      EmptyProjectSpec(:final name) => name,
      FromMediaProjectSpec(:final name) => name,
    };
    createdSpecs.add(spec);
    final canvas = spec is EmptyProjectSpec ? spec.canvas : null;
    var project = seedEmpty(name.trim(), settings: ProjectSettings(canvas: canvas ?? const CanvasSpec()));
    if (spec is FromMediaProjectSpec) {
      project = project.copyWith(
        meta: project.meta.copyWith(origin: spec.origin),
        view: project.view.copyWith(playhead: project.settings.frameRate.quantize(spec.initialPlayhead)),
      );
      seed(project);
    }
    return project.id;
  }

  @override
  Future<LoadedProject> open(ProjectId id) async {
    _call('open', id);
    final project = _require(id);
    if (!openProjects.add(id)) throw const StoreFailure(StoreFailureKind.busy);
    return openResults[id]?.call(project) ?? LoadedProject(project: project);
  }

  @override
  Future<SaveReceipt> save(EditSession session, {required SaveReason reason}) async {
    _call('save');
    final project = session.project;
    projects[project.id] = project;
    _emit();
    return SaveReceipt(
      projectId: project.id,
      docRevision: project.docRevision,
      saveId: _ids.next(IdKind.save),
      savedAt: _clock(),
      reason: reason,
    );
  }

  @override
  void requestAutosave(EditSession session) {
    calls.add('requestAutosave');
    autosaveRequests++;
  }

  @override
  Future<void> flush(ProjectId id) async => _call('flush', id);

  @override
  Future<void> close(ProjectId id) async {
    _call('close', id);
    openProjects.remove(id);
  }

  @override
  Future<void> rename(ProjectId id, String name) async {
    _call('rename', id);
    final p = _require(id);
    projects[id] = p.copyWith(meta: p.meta.copyWith(name: name.trim(), updatedAt: _clock()));
    _emit();
  }

  @override
  Future<ProjectId> duplicate(ProjectId id, {String? name}) async {
    _call('duplicate', id);
    final p = _require(id);
    final names = projects.values.map((e) => e.name).toSet();
    var candidate = name ?? '${p.name} copy';
    for (var n = 2; name == null && names.contains(candidate); n++) {
      candidate = '${p.name} copy $n';
    }
    final now = _clock();
    final copy = EditProject(
      id: _ids.projectId(),
      meta: ProjectMeta(name: candidate, createdAt: now, updatedAt: now),
      timeline: p.timeline,
      pool: p.pool,
      view: p.view,
    );
    return seed(copy);
  }

  @override
  Future<void> delete(ProjectId id) async {
    _call('delete', id);
    _require(id);
    projects.remove(id);
    openProjects.remove(id);
    recoverableSessions.removeWhere((s) => s.projectId == id);
    _emit();
  }

  @override
  Future<List<RecoverableSession>> recoverable() async {
    _call('recoverable');
    return List.unmodifiable(recoverableSessions);
  }

  @override
  Future<LoadedProject> restore(RecoverableSession session) async {
    _call('restore', session.projectId);
    recoverableSessions.removeWhere((s) => s.projectId == session.projectId);
    final project = _require(session.projectId);
    openProjects.add(session.projectId);
    _emit();
    return LoadedProject(project: project);
  }

  @override
  Future<void> discard(RecoverableSession session) async {
    _call('discard', session.projectId);
    recoverableSessions.removeWhere((s) => s.projectId == session.projectId);
    _emit();
  }

  @override
  Future<ProjectId?> findUntouchedProjectFor(String pathOrUri) async {
    _call('findUntouchedProjectFor');
    return untouchedByPath[pathOrUri];
  }

  @override
  Future<ProjectStorageReport> storageReport() async {
    _call('storageReport');
    return report;
  }
}
