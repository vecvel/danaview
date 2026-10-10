// OWNER: CORE-25
//
// Every repository method on FaultInjectingFs: a crash at every filesystem step (clean, torn-empty
// and torn-half writes) leaves a store that a fresh app start reads consistently: the project
// opens with the state before or after the operation, or (create/delete) is absent; nothing that
// was not part of the operation changes.

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/store.dart';
import 'package:vwish_editor_core/testing.dart';

import 'support/repo_support.dart';

/// A fresh app start over the same (in-memory) files.
FileProjectRepository restart(InMemoryProjectRepository r, FakeTimers timers) {
  r.fs.restart();
  return FileProjectRepository(
    roots: r.inner.roots,
    fs: r.fs,
    deleter: r.inner.deleter,
    useIsolates: false,
    ids: SeededIdGenerator(1234),
    clock: timers.clock,
    timer: timers.call,
  );
}

/// Runs [body] with a crash at operation step `base + n` for n = 1, 2, … until [body] completes
/// without reaching the crash; [check] verifies the state after every crash.
Future<int> crashEverywhere(
  Future<InMemoryProjectRepository> Function() setUp,
  Future<void> Function(InMemoryProjectRepository r) body,
  Future<void> Function(InMemoryProjectRepository r, FileProjectRepository fresh) check, {
  TornWrite torn = TornWrite.none,
}) async {
  final timers = FakeTimers();
  for (var n = 1;; n++) {
    final r = await setUp();
    r.fs.crashAtStep(r.fs.steps + n, torn: torn);
    var crashed = false;
    try {
      await body(r);
    } on SimulatedCrash {
      crashed = true;
    }
    if (!crashed && !r.fs.crashed) return n - 1;
    await check(r, restart(r, timers));
    expect(n, lessThan(200), reason: 'runaway');
  }
}

void main() {
  for (final torn in [TornWrite.none, TornWrite.empty, TornWrite.half]) {
    group('crash at every step (${torn.name})', () {
      late FakeTimers timers;
      setUp(() => timers = FakeTimers());

      test('save(manual)', () async {
        late EditProject before, after;
        final steps = await crashEverywhere(
          () async {
            final r = memRepo(timers);
            await r.seed(smallProject());
            return r;
          },
          (r) async {
            final (loaded, s) = await openSession(r, const ProjectId('pr_small0000001'), timers);
            before = loaded.project;
            edit(s);
            after = s.project;
            await r.save(s, reason: SaveReason.manual);
          },
          (r, fresh) async {
            final got = (await fresh.open(const ProjectId('pr_small0000001'))).project;
            expect(got == before || got == after, isTrue);
            expect(await fresh.recoverable(), isEmpty);
            final sums = await fresh.summaries();
            expect(sums.single.health, ProjectHealth.ok);
          },
          torn: torn,
        );
        expect(steps, greaterThan(4));
      });

      test('create(empty)', () async {
        await crashEverywhere(
          () async => memRepo(timers),
          (r) => r.create(const EmptyProjectSpec(name: 'New')),
          (r, fresh) async {
            final sums = await fresh.summaries();
            for (final s in sums) {
              final loaded = await fresh.open(s.id);
              expect(loaded.project.name, 'New');
              await fresh.close(s.id);
            }
          },
          torn: torn,
        );
      });

      test('rename', () async {
        await crashEverywhere(
          () async {
            final r = memRepo(timers);
            await r.seed(smallProject(name: 'Old'));
            return r;
          },
          (r) => r.rename(const ProjectId('pr_small0000001'), 'New'),
          (r, fresh) async {
            final got = (await fresh.open(const ProjectId('pr_small0000001'))).project;
            expect(got.name, anyOf('Old', 'New'));
            expect(got.timeline, smallProject().timeline);
          },
          torn: torn,
        );
      });

      test('duplicate', () async {
        await crashEverywhere(
          () async {
            final r = memRepo(timers);
            await r.seed(smallProject(name: 'Src'));
            return r;
          },
          (r) => r.duplicate(const ProjectId('pr_small0000001')),
          (r, fresh) async {
            final src = (await fresh.open(const ProjectId('pr_small0000001'))).project;
            expect(src.name, 'Src');
            await fresh.close(const ProjectId('pr_small0000001'));
            for (final s in await fresh.summaries()) {
              if (s.id == const ProjectId('pr_small0000001')) continue;
              final copy = (await fresh.open(s.id)).project;
              expect(copy.name, 'Src copy');
              expect(copy.pool, src.pool);
            }
          },
          torn: torn,
        );
      });

      test('delete', () async {
        await crashEverywhere(
          () async {
            final r = memRepo(timers);
            await r.seed(smallProject());
            await r.seed(smallProject(id: 'pr_keep', name: 'Keep'));
            return r;
          },
          (r) => r.delete(const ProjectId('pr_small0000001')),
          (r, fresh) async {
            final ids = {for (final s in await fresh.summaries()) s.id};
            expect(ids, contains(const ProjectId('pr_keep')));
            if (ids.contains(const ProjectId('pr_small0000001'))) {
              expect((await fresh.open(const ProjectId('pr_small0000001'))).project.name, 'Small');
            }
            expect((await fresh.open(const ProjectId('pr_keep'))).project.name, 'Keep');
          },
          torn: torn,
        );
      });
    });
  }

  test('restore on FaultInjectingFs: a failed promote changes nothing and can be retried', () async {
    final timers = FakeTimers();
    final r = memRepo(timers);
    await r.seed(smallProject());
    final (_, s) = await openSession(r, const ProjectId('pr_small0000001'), timers);
    edit(s);
    await r.save(s, reason: SaveReason.autosave);
    final edited = s.project;
    // Simulated kill: the app goes away without closing.
    final fresh = restart(r, timers);
    final rec = await fresh.recoverable();
    expect(rec.single.journalRevision, edited.docRevision);
    r.fs.failWhere((op) => op.kind == FsOpKind.rename, StoreFailureKind.io, times: 1);
    await expectLater(fresh.restore(rec.single), throwsA(isA<StoreFailure>()));
    final restored = await fresh.restore(rec.single);
    expect(restored.project, edited);
  });
}
