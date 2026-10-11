// OWNER: UX-05
//
// ProjectsController and ProjectsState (ux.md §5.4): a StateNotifier over
// `ProjectRepository.watchSummaries()` with sort (persisted in `editor.projects.sort`), search,
// recovery sessions, and the project actions. Every action reports a typed [ProjectsFailure]
// (mapped to copy by [ProjectsFailure.message]); deletion is deferred behind an undo window and
// committed when the window closes, when the controller is disposed or when the app is hidden.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/model.dart' show ProjectId;
import 'package:vwish_editor_core/store.dart';

import '../app/editor_messages.dart' show EditorMessage;
import '../app/editor_prefs.dart';
import '../app/editor_providers.dart';
import '../app/strings/projects_strings.dart';

/// The Projects sort order (ux.md §5.4; persisted as [ProjectSortPreference]).
typedef ProjectSort = ProjectSortPreference;

/// How long a deleted project can be brought back (ux.md §5.2).
const Duration projectUndoWindow = Duration(seconds: 5);

/// The current time for "Edited 2 h ago" (overridden in tests).
final projectsClockProvider = Provider<DateTime Function()>((ref) => DateTime.now, name: 'projectsClockProvider');

/// Why a project action failed (ux.md §5.4: typed failures mapped to copy).
@immutable
sealed class ProjectsFailure implements Exception {
  const ProjectsFailure();

  /// Maps a repository error to a typed failure.
  factory ProjectsFailure.from(Object error) => switch (error) {
        final ProjectsFailure failure => failure,
        StoreFailure(kind: StoreFailureKind.busy) => const ProjectBusyFailure(),
        StoreFailure(kind: StoreFailureKind.notFound) => const ProjectNotFoundFailure(),
        StoreFailure(kind: StoreFailureKind.diskFull) => const ProjectDiskFullFailure(),
        StoreFailure(kind: StoreFailureKind.newerSchema) => const ProjectNeedsNewerAppFailure(),
        StoreFailure(kind: StoreFailureKind.corrupt) => const ProjectCorruptFailure(),
        ArgumentError() => const ProjectInvalidNameFailure(),
        _ => const ProjectIoFailure(),
      };

  /// The message shown for this failure (title and next step).
  EditorMessage get message => switch (this) {
        ProjectBusyFailure() => const EditorMessage(ProjectsStrings.busyTitle, detail: ProjectsStrings.busyDetail),
        ProjectNotFoundFailure() => const EditorMessage(ProjectsStrings.notFoundTitle, detail: ProjectsStrings.notFoundDetail),
        ProjectInvalidNameFailure() => const EditorMessage(ProjectsStrings.invalidNameTitle, detail: ProjectsStrings.invalidNameDetail),
        ProjectDiskFullFailure() => const EditorMessage(ProjectsStrings.diskFullTitle, detail: ProjectsStrings.diskFullDetail),
        ProjectNeedsNewerAppFailure() => const EditorMessage(ProjectsStrings.newerTitle, detail: ProjectsStrings.newerDetail),
        ProjectCorruptFailure() => const EditorMessage(ProjectsStrings.corruptFailureTitle, detail: ProjectsStrings.corruptFailureDetail),
        ProjectIoFailure() => const EditorMessage(ProjectsStrings.ioTitle, detail: ProjectsStrings.ioDetail),
      };

  @override
  String toString() => runtimeType.toString();
}

/// The project is open in the editor (rename, duplicate and delete need it closed).
final class ProjectBusyFailure extends ProjectsFailure {
  /// Creates the failure.
  const ProjectBusyFailure();
}

/// The project no longer exists.
final class ProjectNotFoundFailure extends ProjectsFailure {
  /// Creates the failure.
  const ProjectNotFoundFailure();
}

/// The name is empty or longer than 80 characters.
final class ProjectInvalidNameFailure extends ProjectsFailure {
  /// Creates the failure.
  const ProjectInvalidNameFailure();
}

/// The device is out of space.
final class ProjectDiskFullFailure extends ProjectsFailure {
  /// Creates the failure.
  const ProjectDiskFullFailure();
}

/// The project was saved by a newer app (D-12).
final class ProjectNeedsNewerAppFailure extends ProjectsFailure {
  /// Creates the failure.
  const ProjectNeedsNewerAppFailure();
}

/// The project has no valid copy.
final class ProjectCorruptFailure extends ProjectsFailure {
  /// Creates the failure.
  const ProjectCorruptFailure();
}

/// Any other storage error.
final class ProjectIoFailure extends ProjectsFailure {
  /// Creates the failure.
  const ProjectIoFailure();
}

/// A failure of an action that finished after the screen moved on (a deferred delete).
@immutable
final class ProjectsNotice {
  /// Creates the notice.
  const ProjectsNotice({required this.action, required this.projectName, required this.failure});

  /// `delete`, `restore`, …
  final String action;

  /// The project's name.
  final String projectName;

  /// What went wrong.
  final ProjectsFailure failure;

  /// One line for a toast: `Couldn't delete "Trip". Close it in the editor, then try again.`
  String get text {
    final detail = failure.message.detail;
    final head = ProjectsStrings.actionFailed(action, projectName);
    return detail == null ? '$head.' : '$head. $detail';
  }
}

/// State of the Projects screen (ux.md §5.4).
@immutable
class ProjectsState {
  /// Creates the state.
  const ProjectsState({
    this.projects = const AsyncValue.loading(),
    this.recoverable = const [],
    this.sort = ProjectSort.recent,
    this.query = '',
    this.pendingDelete = const {},
  });

  /// Every project the repository lists (including ones waiting to be deleted).
  final AsyncValue<List<ProjectSummary>> projects;

  /// Projects with a recoverable journal (recovery banner).
  final List<RecoverableSession> recoverable;

  /// Sort order.
  final ProjectSort sort;

  /// Search text (trimmed when matching).
  final String query;

  /// Projects hidden while their undo window is open, oldest first.
  final Set<ProjectId> pendingDelete;

  /// Projects not waiting to be deleted, in repository order.
  List<ProjectSummary> get kept => [
        for (final s in projects.valueOrNull ?? const <ProjectSummary>[])
          if (!pendingDelete.contains(s.id)) s,
      ];

  /// Number of projects not waiting to be deleted.
  int get count => kept.length;

  /// Bytes owned by the projects not waiting to be deleted.
  int get totalBytes => kept.fold(0, (sum, s) => sum + s.bytesOwned);

  /// Whether the search field is offered (more than 8 projects, or a search is active).
  bool get searchable => count > 8 || query.trim().isNotEmpty;

  /// The cards to show: kept projects matching [query], in [sort] order.
  List<ProjectSummary> get visible {
    final needle = query.trim().toLowerCase();
    final list = [
      for (final s in kept)
        if (needle.isEmpty || s.name.toLowerCase().contains(needle)) s,
    ];
    int byRecent(ProjectSummary a, ProjectSummary b) {
      final c = b.updatedAt.compareTo(a.updatedAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    }

    switch (sort) {
      case ProjectSort.recent:
        list.sort(byRecent);
      case ProjectSort.name:
        list.sort((a, b) {
          final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          return c != 0 ? c : byRecent(a, b);
        });
    }
    return list;
  }

  /// The summary of [id] (including pending deletions), or null.
  ProjectSummary? summaryOf(ProjectId id) {
    for (final s in projects.valueOrNull ?? const <ProjectSummary>[]) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// A copy with the given fields replaced.
  ProjectsState copyWith({
    AsyncValue<List<ProjectSummary>>? projects,
    List<RecoverableSession>? recoverable,
    ProjectSort? sort,
    String? query,
    Set<ProjectId>? pendingDelete,
  }) =>
      ProjectsState(
        projects: projects ?? this.projects,
        recoverable: recoverable ?? this.recoverable,
        sort: sort ?? this.sort,
        query: query ?? this.query,
        pendingDelete: pendingDelete ?? this.pendingDelete,
      );
}

/// Projects list, sort, search and actions (ux.md §5.4).
class ProjectsController extends StateNotifier<ProjectsState> {
  /// Creates the controller over [repository] and [prefs] and starts watching the project list.
  /// [undoWindow] is how long a deleted project can be brought back.
  ProjectsController(this._repo, this._prefs, {this.undoWindow = projectUndoWindow}) : super(ProjectsState(sort: _prefs.projectsSort)) {
    _watch();
    unawaited(_loadRecoverable());
  }

  final ProjectRepository _repo;
  final EditorPrefs _prefs;

  /// How long a deleted project can be brought back.
  final Duration undoWindow;

  StreamSubscription<List<ProjectSummary>>? _summaries;
  final Map<ProjectId, Timer> _deleteTimers = {};
  final Map<ProjectId, String> _pendingNames = {};
  final StreamController<ProjectsNotice> _notices = StreamController<ProjectsNotice>.broadcast();

  /// The summary of [id] as last listed (including pending deletions), or null.
  ProjectSummary? summaryOf(ProjectId id) => state.summaryOf(id);

  /// Failures of actions that finish after the screen moved on (deferred deletes).
  Stream<ProjectsNotice> get notices => _notices.stream;

  void _watch() {
    unawaited(_summaries?.cancel());
    _summaries = _repo.watchSummaries().listen(
      (list) {
        if (!mounted) return;
        state = state.copyWith(projects: AsyncValue.data(List.unmodifiable(list)));
      },
      onError: (Object e, StackTrace st) {
        debugPrint('[Projects] Listing failed: ${e.runtimeType}');
        if (mounted) state = state.copyWith(projects: AsyncValue<List<ProjectSummary>>.error(e, st));
      },
    );
  }

  Future<void> _loadRecoverable() async {
    try {
      final sessions = await _repo.recoverable();
      if (mounted) state = state.copyWith(recoverable: List.unmodifiable(sessions));
    } on Object catch (e) {
      debugPrint('[Projects] Recovery check failed: ${e.runtimeType}');
    }
  }

  /// Lists the projects again (after an error) and re-checks recovery.
  Future<void> refresh() async {
    state = state.copyWith(projects: const AsyncValue<List<ProjectSummary>>.loading());
    _watch();
    await _loadRecoverable();
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (e) {
      if (e is Error && e is! ArgumentError) rethrow;
      throw ProjectsFailure.from(e);
    }
  }

  /// Creates a project and returns its id.
  Future<ProjectId> create(NewProjectSpec spec) => _guard(() => _repo.create(spec));

  /// Renames [id] to [name] (1–80 characters after trim).
  Future<void> rename(ProjectId id, String name) {
    if (ProjectsStrings.validateName(name) != null) return Future.error(const ProjectInvalidNameFailure());
    return _guard(() => _repo.rename(id, name.trim()));
  }

  /// Duplicates [id] (`"<name> copy"`, `"<name> copy 2"`, …) and returns the new id.
  Future<ProjectId> duplicate(ProjectId id) => _guard(() => _repo.duplicate(id));

  /// Hides [id] at once and deletes it when [undoWindow] ends, unless [undoDelete] runs first.
  void requestDelete(ProjectId id) {
    if (state.pendingDelete.contains(id)) return;
    _pendingNames[id] = state.summaryOf(id)?.name ?? '';
    state = state.copyWith(pendingDelete: {...state.pendingDelete, id});
    _deleteTimers[id] = Timer(undoWindow, () => unawaited(_commitDelete(id)));
  }

  /// Brings [id] back while its undo window is open.
  void undoDelete(ProjectId id) {
    final timer = _deleteTimers.remove(id);
    if (timer == null) return;
    timer.cancel();
    _pendingNames.remove(id);
    state = state.copyWith(pendingDelete: {...state.pendingDelete}..remove(id));
  }

  /// Brings back the most recent pending deletion (the undo bar's button).
  void undoLatestDelete() {
    if (state.pendingDelete.isEmpty) return;
    undoDelete(state.pendingDelete.last);
  }

  /// Deletes every project waiting in its undo window now (dispose, app hidden).
  Future<void> commitPendingDeletes() async {
    final ids = _deleteTimers.keys.toList();
    await Future.wait([for (final id in ids) _commitDelete(id)]);
  }

  Future<void> _commitDelete(ProjectId id) async {
    final timer = _deleteTimers.remove(id);
    if (timer == null) return;
    timer.cancel();
    final name = _pendingNames.remove(id) ?? '';
    try {
      await _repo.delete(id);
    } on Object catch (e) {
      if (e is Error && e is! ArgumentError) rethrow;
      final failure = ProjectsFailure.from(e);
      // A project that is already gone is what the user wanted.
      if (failure is! ProjectNotFoundFailure && !_notices.isClosed) {
        _notices.add(ProjectsNotice(action: 'delete', projectName: name, failure: failure));
      }
    } finally {
      if (mounted) state = state.copyWith(pendingDelete: {...state.pendingDelete}..remove(id));
    }
  }

  /// Restores [session]'s journal and returns the project id (closed again, so the editor can open
  /// it).
  Future<ProjectId> restore(RecoverableSession session) => _guard(() async {
        await _repo.restore(session);
        await _repo.close(session.projectId);
        await _loadRecoverable();
        return session.projectId;
      });

  /// Discards [session]'s journal (the last saved version stays).
  Future<void> discard(RecoverableSession session) => _guard(() async {
        await _repo.discard(session);
        await _loadRecoverable();
      });

  /// Sets the sort order and remembers it.
  void setSort(ProjectSort sort) {
    if (sort == state.sort) return;
    state = state.copyWith(sort: sort);
    unawaited(_prefs.setProjectsSort(sort));
  }

  /// Sets the search text.
  void setQuery(String query) {
    if (query == state.query) return;
    state = state.copyWith(query: query);
  }

  @override
  void dispose() {
    unawaited(_summaries?.cancel());
    // Deletions the user did not undo still happen.
    final ids = _deleteTimers.keys.toList();
    for (final timer in _deleteTimers.values) {
      timer.cancel();
    }
    _deleteTimers.clear();
    for (final id in ids) {
      unawaited(_repo.delete(id).then<void>((_) {}, onError: (Object e) {
        debugPrint('[Projects] Deferred delete failed: ${e.runtimeType}');
      }));
    }
    unawaited(_notices.close());
    super.dispose();
  }
}

/// The Projects screen controller (autoDispose: pending deletions are committed on dispose).
final projectsControllerProvider = StateNotifierProvider.autoDispose<ProjectsController, ProjectsState>(
  (ref) => ProjectsController(ref.watch(projectRepositoryProvider), ref.watch(editorPrefsProvider)),
  name: 'projectsControllerProvider',
);
