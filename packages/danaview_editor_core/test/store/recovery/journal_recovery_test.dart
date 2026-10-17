// OWNER: CORE-26
//
// Journal slots and crash recovery through the repository (ARCH §8.3): a/b alternation, main saves
// truncate the journal, recovery listing only for newer journals continuing the main document,
// restore / discard / "Open last saved" (recovered-<ts>), pendingRecovery on open, disk-full
// failure then retry, and a crash at every write step always leaving the newest completed state
// recoverable.

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart' show ProjectHeader;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';

import '../repository/support/repo_support.dart';

const _id = ProjectId('pr_small0000001');

FileProjectRepository _restart(InMemoryProjectRepository r, FakeTimers timers, {int seed = 77}) {
  r.fs.restart();
  return FileProjectRepository(
    roots: r.inner.roots,
    fs: r.fs,
    deleter: r.inner.deleter,
    useIsolates: false,
    ids: SeededIdGenerator(seed),
    clock: timers.clock,
    timer: timers.call,
  );
}

void main() {
  late FakeTimers timers;
  late InMemoryProjectRepository repo;
  String journalDir() => p.join(repo.inner.roots.projectDir(_id), 'journal');
  Future<ProjectHeader?> slot(String name) async {
    final b = repo.memory.peek(p.join(journalDir(), '$name.dnproj'));
    return b == null ? null : DnprojFormat.tryParse(b)?.header;
  }

  Future<ProjectHeader> mainHeader() => DnprojFiles(fs: repo.fs).readHeader(mainOf(repo.inner.roots, _id));

  setUp(() async {
    timers = FakeTimers();
    repo = memRepo(timers);
    await repo.seed(smallProject());
  });

  test('autosave is debounced through the repository and alternates slots a/b', () async {
    final (_, s) = await openSession(repo, _id, timers);
    final main = await mainHeader();
    edit(s, 1);
    repo.requestAutosave(s);
    await timers.elapse(const Duration(seconds: 1));
    expect(await slot('a'), isNull);
    await timers.elapse(const Duration(seconds: 1));
    expect((await slot('a'))!.docRevision, s.project.docRevision);
    expect((await slot('a'))!.baseSaveId, main.saveId);
    edit(s, 2);
    repo.requestAutosave(s);
    await timers.elapse(const Duration(seconds: 2));
    expect((await slot('b'))!.docRevision, s.project.docRevision);
    edit(s, 3);
    repo.requestAutosave(s);
    await timers.elapse(const Duration(seconds: 2));
    expect((await slot('a'))!.docRevision, s.project.docRevision);
    expect((await slot('b'))!.docRevision, s.project.docRevision - 1);
    // Nothing changed: no write.
    final writes = repo.fs.steps;
    repo.requestAutosave(s);
    await timers.elapse(const Duration(seconds: 2));
    expect(repo.fs.steps, writes);
  });

  test('autosave is skipped while a transaction is open', () async {
    final (_, s) = await openSession(repo, _id, timers);
    edit(s, 1);
    repo.requestAutosave(s);
    final tx = s.begin('Drag');
    await timers.elapse(const Duration(seconds: 5));
    expect(await slot('a'), isNull);
    tx.cancel();
    await timers.elapse(const Duration(seconds: 2));
    expect((await slot('a'))!.docRevision, s.project.docRevision);
  });

  test('a main save writes main + meta + refs and truncates the journal', () async {
    final (_, s) = await openSession(repo, _id, timers);
    edit(s, 1);
    await repo.save(s, reason: SaveReason.autosave);
    edit(s, 2);
    await repo.save(s, reason: SaveReason.autosave);
    expect(await slot('a'), isNotNull);
    expect(await slot('b'), isNotNull);
    edit(s, 3);
    final r = await repo.save(s, reason: SaveReason.manual);
    expect(await slot('a'), isNull);
    expect(await slot('b'), isNull);
    expect((await mainHeader()).saveId, r.saveId);
    expect(await repo.recoverable(), isEmpty);
  });

  group('recoverable()', () {
    test('lists only journals newer than main that continue its saveId', () async {
      final (_, s) = await openSession(repo, _id, timers);
      edit(s);
      await repo.save(s, reason: SaveReason.autosave);
      // Killed: the repository never closes. A fresh start sees the journal.
      final fresh = _restart(repo, timers);
      final list = await fresh.recoverable();
      expect(list.single.projectId, _id);
      expect(list.single.projectName, 'Small');
      expect(list.single.journalRevision, s.project.docRevision);
      expect(list.single.mainRevision, smallProject().docRevision);
      expect((await fresh.summaries()).single.hasRecovery, isTrue);

      // A journal that is not ahead of main is not offered.
      final m = await mainHeader();
      final body = DnprojFormat.parse(repo.memory.peek(mainOf(repo.inner.roots, _id))!).body;
      repo.memory.putFile(p.join(journalDir(), 'a.dnproj'),
          DnprojFormat.build(body, app: 'x', savedAt: when, docRevision: m.docRevision, saveId: 'sv_j', baseSaveId: m.saveId));
      expect(await _restart(repo, timers).recoverable(), isEmpty);
      // Ahead but continuing another main save: not offered.
      repo.memory.putFile(p.join(journalDir(), 'a.dnproj'),
          DnprojFormat.build(body, app: 'x', savedAt: when, docRevision: m.docRevision + 5, saveId: 'sv_j', baseSaveId: 'sv_other'));
      expect(await _restart(repo, timers).recoverable(), isEmpty);
      expect((await _restart(repo, timers).summaries()).single.hasRecovery, isFalse);
    });

    test('a torn newest slot falls back to the previous valid slot', () async {
      final (_, s) = await openSession(repo, _id, timers);
      edit(s, 1);
      await repo.save(s, reason: SaveReason.autosave); // a
      final first = s.project;
      edit(s, 2);
      await repo.save(s, reason: SaveReason.autosave); // b
      final b = repo.memory.peek(p.join(journalDir(), 'b.dnproj'))!;
      repo.memory.putFile(p.join(journalDir(), 'b.dnproj'), b.sublist(0, b.length ~/ 2));
      final fresh = _restart(repo, timers);
      final rec = (await fresh.recoverable()).single;
      expect(rec.journalRevision, first.docRevision);
      final restored = await fresh.restore(rec);
      expect(restored.project, first);
    });

    test('an open project is not listed (its journal is the live autosave)', () async {
      final (_, s) = await openSession(repo, _id, timers);
      edit(s);
      await repo.save(s, reason: SaveReason.autosave);
      expect(await repo.recoverable(), isEmpty);
    });
  });

  group('restore / discard / open last saved', () {
    late EditProject edited;
    late FileProjectRepository fresh;

    setUp(() async {
      final (_, s) = await openSession(repo, _id, timers);
      edit(s);
      await repo.save(s, reason: SaveReason.autosave);
      edited = s.project;
      fresh = _restart(repo, timers);
    });

    test('open returns pendingRecovery; restore promotes the journal atomically and opens it', () async {
      final opened = await fresh.open(_id);
      expect(opened.pendingRecovery, isNotNull);
      expect(opened.project, smallProject(), reason: 'open shows the last saved version');
      final restored = await fresh.restore(opened.pendingRecovery!);
      expect(restored.project, edited);
      expect(restored.pendingRecovery, isNull);
      await fresh.close(_id);
      expect(await fresh.recoverable(), isEmpty);
      expect((await fresh.open(_id)).project, edited);
      final meta = ProjectMetaFile.tryDecode(repo.memory.peek(p.join(repo.inner.roots.projectDir(_id), 'meta.json'))!)!;
      expect(meta.docRevision, edited.docRevision);
    });

    test('discard deletes the journal', () async {
      final rec = (await fresh.recoverable()).single;
      await fresh.discard(rec);
      expect(await fresh.recoverable(), isEmpty);
      expect(repo.memory.filePaths.where((f) => f.contains('/journal/')), isEmpty);
      expect((await fresh.open(_id)).project, smallProject());
    });

    test('"Open last saved" keeps the journal as recovered-<ts> until the next successful save', () async {
      final opened = await fresh.open(_id);
      expect(opened.pendingRecovery, isNotNull);
      final s = EditSession(opened.project, clock: timers.clock);
      edit(s, 7);
      await fresh.save(s, reason: SaveReason.autosave);
      final kept = repo.memory.filePaths.where((f) => p.basename(f).startsWith('recovered-')).toList();
      expect(kept, hasLength(1));
      expect(DnprojFormat.parse(repo.memory.peek(kept.single)!).header.docRevision, edited.docRevision);
      expect(await (await _openJournal(repo)).newest().then((e) => e!.docRevision), s.project.docRevision);
      // The new journal (from the older main) is what a crash would recover now.
      final again = _restart(repo, timers, seed: 78);
      expect((await again.recoverable()).single.journalRevision, s.project.docRevision);
      await fresh.save(s, reason: SaveReason.manual);
      expect(repo.memory.filePaths.where((f) => f.contains('/journal/')), isEmpty);
    });
  });

  test('disk full during autosave → failed, retried on the next trigger', () async {
    final (_, s) = await openSession(repo, _id, timers);
    final statuses = <AutosavePhase>[];
    repo.inner.watchAutosave(_id).listen((x) => statuses.add(x.phase));
    repo.fs.failWhere((op) => op.kind == FsOpKind.write && op.path.contains('/journal/'), StoreFailureKind.diskFull, times: 1);
    edit(s, 1);
    repo.requestAutosave(s);
    await timers.elapse(const Duration(seconds: 2));
    expect(statuses.last, AutosavePhase.failed);
    edit(s, 2);
    repo.requestAutosave(s);
    await timers.elapse(const Duration(seconds: 2));
    expect(statuses.last, AutosavePhase.saved);
    final fresh = _restart(repo, timers);
    expect((await fresh.recoverable()).single.journalRevision, s.project.docRevision);
  });

  for (final torn in [TornWrite.none, TornWrite.empty, TornWrite.half]) {
    test('crash at every write step of autosave and main save keeps the newest completed state (${torn.name})', () async {
      for (final mainSave in [false, true]) {
        for (var n = 1;; n++) {
          final t = FakeTimers();
          final r = memRepo(t);
          await r.seed(smallProject());
          final (_, s) = await openSession(r, _id, t);
          edit(s, 1);
          await r.save(s, reason: SaveReason.autosave);
          final completed = s.project;
          edit(s, 2);
          final attempted = s.project;
          r.fs.crashAtStep(r.fs.steps + n, torn: torn);
          var crashed = false;
          try {
            await r.save(s, reason: mainSave ? SaveReason.manual : SaveReason.autosave);
          } on SimulatedCrash {
            crashed = true;
          }
          if (!crashed) break;
          final fresh = _restart(r, t);
          final rec = await fresh.recoverable();
          final EditProject got;
          if (rec.isNotEmpty) {
            got = (await fresh.restore(rec.single)).project;
          } else {
            got = (await fresh.open(_id)).project;
          }
          expect(got == completed || got == attempted, isTrue, reason: 'step $n (${mainSave ? 'main' : 'journal'})');
          expect(n, lessThan(100));
        }
      }
    });
  }
}

Future<ProjectJournal> _openJournal(InMemoryProjectRepository r) async =>
    ProjectJournal(r.inner.roots.projectDir(_id), fs: r.fs, deleter: r.inner.deleter);
