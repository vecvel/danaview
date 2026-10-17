// OWNER: UX-05
//
// ProjectsController (ux.md §5.4) over the fake repository: listing, sort (persisted), search,
// rename/duplicate with typed failures, the delete undo window (commit on expiry, on demand and on
// dispose; failures reported), recovery restore/discard, and the failure → copy mapping.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/projects/projects_controller.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_core/store.dart';

import '../support/support.dart';
import 'projects_test_support.dart';

ProjectsController _controller(ProjectsRepository repo, {EditorPrefs? prefs}) {
  final c = ProjectsController(repo, prefs ?? EditorPrefs.memory());
  addTearDown(() {
    if (c.mounted) c.dispose();
  });
  return c;
}

List<String> _names(ProjectsState s) => [for (final p in s.visible) p.name];

void main() {
  group('listing, sort and search', () {
    test('starts loading, then lists the repository summaries newest first', () async {
      final repo = ProjectsRepository()
        ..add(projectNamed('Old', updatedAt: DateTime.utc(2026, 10, 1)))
        ..add(projectNamed('New', updatedAt: DateTime.utc(2026, 10, 8)));
      final c = _controller(repo);
      expect(c.state.projects.isLoading, isTrue);
      await pumpEventQueue();
      expect(_names(c.state), ['New', 'Old']);
      expect(c.state.count, 2);
      expect(repo.calls, contains('recoverable'));
    });

    test('follows repository changes', () async {
      final repo = ProjectsRepository()..add(projectNamed('A'));
      final c = _controller(repo);
      await pumpEventQueue();
      repo.add(projectNamed('B', updatedAt: DateTime.utc(2026, 10, 9)));
      await pumpEventQueue();
      expect(_names(c.state), ['B', 'A']);
    });

    test('sort by name is case-insensitive, remembered, and restored on the next start', () async {
      final prefs = EditorPrefs.memory();
      final repo = ProjectsRepository()
        ..add(projectNamed('beach', updatedAt: DateTime.utc(2026, 10, 1)))
        ..add(projectNamed('Alps', updatedAt: DateTime.utc(2026, 10, 2)))
        ..add(projectNamed('City', updatedAt: DateTime.utc(2026, 10, 3)));
      final c = _controller(repo, prefs: prefs);
      await pumpEventQueue();
      expect(_names(c.state), ['City', 'Alps', 'beach']);
      c.setSort(ProjectSort.name);
      expect(_names(c.state), ['Alps', 'beach', 'City']);
      await pumpEventQueue();
      expect(prefs.projectsSort, ProjectSortPreference.name);

      final again = _controller(repo, prefs: prefs);
      await pumpEventQueue();
      expect(again.state.sort, ProjectSort.name);
    });

    test('search matches names case-insensitively and is offered above 8 projects', () async {
      final repo = ProjectsRepository();
      for (var i = 1; i <= 8; i++) {
        repo.add(projectNamed('Clip $i', updatedAt: DateTime.utc(2026, 10, i)));
      }
      final c = _controller(repo);
      await pumpEventQueue();
      expect(c.state.searchable, isFalse);
      repo.add(projectNamed('Goa Trip', updatedAt: DateTime.utc(2026, 10, 9)));
      await pumpEventQueue();
      expect(c.state.searchable, isTrue);
      c.setQuery('  goa ');
      expect(_names(c.state), ['Goa Trip']);
      c.setQuery('nothing');
      expect(c.state.visible, isEmpty);
      expect(c.state.count, 9);
    });

    test('a listing failure is an error state that refresh recovers from', () async {
      final repo = ProjectsRepository()
        ..failListing = const StoreFailure(StoreFailureKind.io)
        ..add(projectNamed('A'));
      final c = _controller(repo);
      await pumpEventQueue();
      expect(c.state.projects.hasError, isTrue);
      await c.refresh();
      await pumpEventQueue();
      expect(_names(c.state), ['A']);
    });

    test('totalBytes adds what each project owns, leaving out pending deletions', () async {
      final repo = ProjectsRepository();
      final a = repo.add(projectNamed('A'), const SummaryExtras(bytes: 1000));
      repo.add(projectNamed('B'), const SummaryExtras(bytes: 500));
      final c = _controller(repo);
      await pumpEventQueue();
      expect(c.state.totalBytes, 1500);
      c.requestDelete(a);
      expect(c.state.totalBytes, 500);
    });
  });

  group('actions', () {
    test('rename trims and validates 1–80 characters before calling the repository', () async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Trip'));
      final c = _controller(repo);
      await pumpEventQueue();
      await c.rename(id, '  Goa  ');
      await pumpEventQueue();
      expect(c.summaryOf(id)!.name, 'Goa');
      await expectLater(c.rename(id, '   '), throwsA(isA<ProjectInvalidNameFailure>()));
      await expectLater(c.rename(id, 'x' * 81), throwsA(isA<ProjectInvalidNameFailure>()));
      expect(repo.calls.where((call) => call.startsWith('rename')), hasLength(1));
    });

    test('repository errors become typed failures', () async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Open one'));
      final c = _controller(repo);
      repo.failNext['rename'] = const StoreFailure(StoreFailureKind.busy);
      await expectLater(c.rename(id, 'New'), throwsA(isA<ProjectBusyFailure>()));
      repo.failNext['duplicate'] = const StoreFailure(StoreFailureKind.diskFull);
      await expectLater(c.duplicate(id), throwsA(isA<ProjectDiskFullFailure>()));
      await expectLater(c.duplicate(ProjectId('pr_missing')), throwsA(isA<ProjectNotFoundFailure>()));
      repo.failNext['create'] = ArgumentError('name');
      await expectLater(c.create(const EmptyProjectSpec(name: '')), throwsA(isA<ProjectInvalidNameFailure>()));
    });

    test('duplicate names copies "<name> copy", then "<name> copy 2"', () async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Reel'));
      final c = _controller(repo);
      final first = await c.duplicate(id);
      final second = await c.duplicate(id);
      await pumpEventQueue();
      expect(c.summaryOf(first)!.name, 'Reel copy');
      expect(c.summaryOf(second)!.name, 'Reel copy 2');
    });

    test('create returns the new project', () async {
      final repo = ProjectsRepository();
      final c = _controller(repo);
      final id = await c.create(const EmptyProjectSpec(name: 'Fresh'));
      expect(repo.projects[id]!.name, 'Fresh');
    });
  });

  group('delete with an undo window', () {
    test('hides at once and deletes when the window ends', () {
      fakeAsync((async) {
        final repo = ProjectsRepository();
        final id = repo.add(projectNamed('Gone'));
        repo.add(projectNamed('Kept'));
        final c = ProjectsController(repo, EditorPrefs.memory());
        async.flushMicrotasks();
        c.requestDelete(id);
        expect(_names(c.state), ['Kept']);
        expect(c.state.pendingDelete, {id});
        async.elapse(projectUndoWindow - const Duration(milliseconds: 1));
        expect(repo.calls, isNot(contains('delete:$id')));
        async.elapse(const Duration(milliseconds: 2));
        expect(repo.calls, contains('delete:$id'));
        expect(repo.projects.containsKey(id), isFalse);
        expect(c.state.pendingDelete, isEmpty);
        c.dispose();
      });
    });

    test('undo brings the project back and nothing is deleted', () {
      fakeAsync((async) {
        final repo = ProjectsRepository();
        final id = repo.add(projectNamed('Back'));
        final c = ProjectsController(repo, EditorPrefs.memory());
        async.flushMicrotasks();
        c.requestDelete(id);
        async.elapse(const Duration(seconds: 2));
        c.undoLatestDelete();
        expect(_names(c.state), ['Back']);
        async.elapse(const Duration(seconds: 10));
        expect(repo.calls, isNot(contains('delete:$id')));
        c.dispose();
      });
    });

    test('several pending deletions: undo restores the latest', () {
      fakeAsync((async) {
        final repo = ProjectsRepository();
        final a = repo.add(projectNamed('A'));
        final b = repo.add(projectNamed('B'));
        final c = ProjectsController(repo, EditorPrefs.memory());
        async.flushMicrotasks();
        c
          ..requestDelete(a)
          ..requestDelete(b)
          ..undoLatestDelete();
        expect(c.state.pendingDelete, {a});
        async.elapse(projectUndoWindow);
        expect(repo.calls, contains('delete:$a'));
        expect(repo.calls, isNot(contains('delete:$b')));
        c.dispose();
      });
    });

    test('commitPendingDeletes deletes now (app hidden)', () async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Now'));
      final c = _controller(repo);
      await pumpEventQueue();
      c.requestDelete(id);
      await c.commitPendingDeletes();
      expect(repo.projects.containsKey(id), isFalse);
      expect(c.state.pendingDelete, isEmpty);
    });

    test('disposing the controller still deletes what was not undone', () async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Leaving'));
      final c = ProjectsController(repo, EditorPrefs.memory());
      await pumpEventQueue();
      c
        ..requestDelete(id)
        ..dispose();
      await pumpEventQueue();
      expect(repo.projects.containsKey(id), isFalse);
    });

    test('a failed deletion brings the card back and reports why', () async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Open'));
      final c = _controller(repo);
      await pumpEventQueue();
      final notices = <ProjectsNotice>[];
      final sub = c.notices.listen(notices.add);
      repo.failNext['delete'] = const StoreFailure(StoreFailureKind.busy);
      c.requestDelete(id);
      await c.commitPendingDeletes();
      await pumpEventQueue();
      expect(_names(c.state), ['Open']);
      expect(notices.single.failure, isA<ProjectBusyFailure>());
      expect(notices.single.text, 'Couldn\'t delete "Open". Close it in the editor, then try again.');
      await sub.cancel();
    });

    test('the provider commits pending deletions when the screen goes away', () async {
      final h = EditorTestHarness(repository: ProjectsRepository());
      final id = (h.repository as ProjectsRepository).add(projectNamed('X'));
      final container = h.container();
      final sub = container.listen(projectsControllerProvider, (_, __) {});
      await pumpEventQueue();
      container.read(projectsControllerProvider.notifier).requestDelete(id);
      sub.close();
      await pumpEventQueue();
      expect(h.repository.projects.containsKey(id), isFalse);
    });
  });

  group('recovery', () {
    RecoverableSession sessionOf(ProjectId id, String name) => RecoverableSession(
          projectId: id,
          projectName: name,
          journalRevision: 4,
          mainRevision: 3,
          journalSavedAt: DateTime.utc(2026, 10, 8),
        );

    test('lists recoverable sessions; restore promotes the journal and closes the project for the editor', () async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Crashed'));
      repo.recoverableSessions.add(sessionOf(id, 'Crashed'));
      final c = _controller(repo);
      await pumpEventQueue();
      expect(c.state.recoverable, hasLength(1));
      expect(c.state.summaryOf(id)!.hasRecovery, isTrue);
      final restored = await c.restore(c.state.recoverable.single);
      expect(restored, id);
      expect(repo.calls, containsAllInOrder(['restore:$id', 'close:$id']));
      expect(repo.openProjects, isEmpty);
      expect(c.state.recoverable, isEmpty);
    });

    test('discard deletes the journal and refreshes the list', () async {
      final repo = ProjectsRepository();
      final id = repo.add(projectNamed('Crashed'));
      repo.recoverableSessions.add(sessionOf(id, 'Crashed'));
      final c = _controller(repo);
      await pumpEventQueue();
      await c.discard(c.state.recoverable.single);
      expect(repo.calls, contains('discard:$id'));
      expect(c.state.recoverable, isEmpty);
    });
  });

  test('every failure has a title and a next step', () {
    const kinds = {
      StoreFailureKind.busy: ProjectBusyFailure,
      StoreFailureKind.notFound: ProjectNotFoundFailure,
      StoreFailureKind.diskFull: ProjectDiskFullFailure,
      StoreFailureKind.newerSchema: ProjectNeedsNewerAppFailure,
      StoreFailureKind.corrupt: ProjectCorruptFailure,
      StoreFailureKind.io: ProjectIoFailure,
    };
    kinds.forEach((kind, type) {
      final failure = ProjectsFailure.from(StoreFailure(kind));
      expect(failure.runtimeType, type);
      expect(failure.message.title, isNotEmpty);
      expect(failure.message.detail, isNotEmpty);
    });
    expect(ProjectsFailure.from(ArgumentError('x')), isA<ProjectInvalidNameFailure>());
    expect(ProjectsFailure.from(const ProjectBusyFailure()), isA<ProjectBusyFailure>());
    expect(ProjectsFailure.from(Exception('x')), isA<ProjectIoFailure>());
  });

  test('the provider reads the repository and preferences of the harness', () async {
    final h = EditorTestHarness(prefs: EditorPrefs.memory({EditorPrefKeys.projectsSort: 'name'}));
    final c = h.container();
    final sub = c.listen(projectsControllerProvider, (_, __) {});
    addTearDown(sub.close);
    expect(c.read(projectsControllerProvider).sort, ProjectSort.name);
    expect(c.read(projectsClockProvider)(), isA<DateTime>());
  });
}
