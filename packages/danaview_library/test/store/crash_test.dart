// OWNER: HOM-17
//
// BUILD_PLAN HOM-17: "a crash injected at every step of move, delete and import leaves the
// database and files consistent". For each operation the steps are counted, then for every step a
// fresh library runs the setup, crashes there (LibraryCrash; the connection is dropped without a
// rollback, like a dying process), and is reopened as a new launch. After the reopen the invariants
// hold and the library equals either the state before the operation or the state after it, files
// included (atomicity).

import 'dart:io';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import 'store_harness.dart';

typedef _Setup = Future<Map<String, String>> Function(LibraryStore store);
typedef _Op = Future<Object?> Function(LibraryStore store, Map<String, String> ctx);

/// Rows, jobs and file contents, comparable across runs (ids are seeded).
String _snapshot(LibraryStore store) {
  final lines = <String>[];
  for (final f in store.reader.allFolders(includeTrashed: true)) {
    lines.add('F ${f.id.value} ${f.parentId?.value} ${f.name} ${f.trashedAt?.millisecondsSinceEpoch}');
  }
  for (final e in store.reader.allEntries(includeTrashed: true)) {
    final file = File(store.paths.entryFile(e.id, e.displayName));
    lines.add('E ${e.id.value} ${e.folderId.value} ${e.displayName} ${e.trashedAt?.millisecondsSinceEpoch} '
        '${file.existsSync() ? file.readAsStringSync() : '<missing>'}');
  }
  for (final j in store.reader.importJobs()) {
    lines.add('J ${j.id} ${j.state.code} ${File(store.paths.resolve(j.partPath)).existsSync()}');
  }
  for (final d in Directory(store.paths.filesDir).listSync()) {
    lines.add('D ${d.path.split(Platform.pathSeparator).last}');
  }
  return (lines..sort()).join('\n');
}

Future<void> _crashEverywhere(String name, _Setup setup, _Op op) async {
  // Count the steps and record the "after" state.
  final recorder = RecordingFaults();
  final clock = FakeLibraryClock(t0);
  var store = await openStore(tempRoot(), clock, faults: recorder, seed: 42);
  var ctx = await setup(store);
  final before = _snapshot(store);
  recorder.steps.clear();
  await op(store, ctx);
  final after = _snapshot(store);
  final steps = List.of(recorder.steps);
  await store.close();
  expect(steps, isNotEmpty, reason: name);
  expect(after, isNot(before), reason: '$name changes something');

  for (var i = 0; i < steps.length; i++) {
    final root = tempRoot();
    final faults = CrashAtStep(i);
    store = await openStore(root, FakeLibraryClock(t0), faults: faults, seed: 42);
    ctx = await setup(store);
    expect(_snapshot(store), before);
    faults.armed = true;
    await expectLater(op(store, ctx), throwsA(isA<LibraryCrash>()), reason: '$name step $i (${steps[i]})');
    store.abandon();

    final reopened = await openStore(root, FakeLibraryClock(t0));
    expect(reopened.openReport.violations, isEmpty, reason: '$name crash at ${steps[i]}');
    expect(await reopened.checkInvariants(), isEmpty, reason: '$name crash at ${steps[i]}');
    expect(reopened.openReport.reconcile!.unavailable, isEmpty, reason: '$name crash at ${steps[i]}');
    final state = _snapshot(reopened);
    // An import interrupted before its row is a third consistent state: the library as before plus
    // a resumable job whose part file is intact (the import pipeline resumes or abandons it).
    final lines = state.split('\n');
    final resumable = lines.where((l) => l.startsWith('J ')).every((l) => l.endsWith(' copying true')) &&
        lines.where((l) => !l.startsWith('J ')).join('\n') == before;
    expect(state == before || state == after || resumable, isTrue,
        reason: '$name crash at step $i (${steps[i]}) left neither the before nor the after state:\n$state\n--- before\n$before\n--- after\n$after');
    await reopened.close();
  }
}

void main() {
  Future<Map<String, String>> twoFoldersThreeFiles(LibraryStore s) async {
    final a = await s.write((w, now) => w.createFolder('A', now: now));
    final b = await s.write((w, now) => w.createFolder('B', parent: a, now: now));
    final x = await importInto(s, 'x.txt', folder: a);
    final y = await importInto(s, 'y.txt', folder: b);
    final clash = await importInto(s, 'x.txt', folder: b);
    return {'a': a.value, 'b': b.value, 'x': x.id.value, 'y': y.id.value, 'clash': clash.id.value};
  }

  test('move entries (with a rename for the name clash)', () async {
    await _crashEverywhere('move', twoFoldersThreeFiles,
        (s, c) => s.write((w, now) => w.moveEntries([EntryId.parse(c['x']!), EntryId.parse(c['y']!)], FolderId.parse(c['b']!), now: now)));
  });

  test('a move that fails partway (not a crash) undoes the renames it did', () async {
    final faults = _ThrowAt('move.row');
    final root = tempRoot();
    final store = await openStore(root, FakeLibraryClock(t0), faults: faults, seed: 42);
    final c = await twoFoldersThreeFiles(store);
    final before = _snapshot(store);
    faults.armed = true;
    await expectLater(
      store.write((w, now) => w.moveEntries([EntryId.parse(c['x']!), EntryId.parse(c['y']!)], FolderId.parse(c['b']!), now: now)),
      throwsA(isA<StateError>()),
    );
    faults.armed = false;
    expect(_snapshot(store), before);
    expect(await store.checkInvariants(), isEmpty);
    await store.close();
  });

  test('move folder', () async {
    await _crashEverywhere('move folder', twoFoldersThreeFiles, (s, c) => s.write((w, now) => w.moveFolder(FolderId.parse(c['b']!), null, now: now)));
  });

  test('rename', () async {
    await _crashEverywhere('rename', twoFoldersThreeFiles, (s, c) => s.write((w, now) => w.renameEntry(EntryId.parse(c['x']!), 'z.txt', now: now)));
  });

  test('delete a file and a folder subtree', () async {
    await _crashEverywhere('delete file', twoFoldersThreeFiles, (s, c) => s.write((w, now) => w.trashEntries([EntryId.parse(c['x']!)], now: now)));
    await _crashEverywhere('delete folder', twoFoldersThreeFiles, (s, c) => s.write((w, now) => w.trashFolder(FolderId.parse(c['a']!), now: now)));
  });

  test('restore', () async {
    await _crashEverywhere('restore', (s) async {
      final ctx = await twoFoldersThreeFiles(s);
      await s.write((w, now) => w.trashFolder(FolderId.parse(ctx['a']!), now: now));
      return ctx;
    }, (s, c) => s.write((w, now) => w.restore(FolderId.parse(c['a']!), now: now)));
  });

  test('purge: Empty now and the expiry sweep', () async {
    Future<Map<String, String>> trashed(LibraryStore s) async {
      final ctx = await twoFoldersThreeFiles(s);
      await s.write((w, now) => w.trashFolder(FolderId.parse(ctx['a']!), now: now));
      return ctx;
    }

    await _crashEverywhere('empty now', trashed, (s, c) => s.write((w, _) => w.emptyTrash()));
    await _crashEverywhere('sweep', trashed, (s, c) => s.write((w, now) => w.purgeExpired(now: now.add(const Duration(days: 31)))));
  });

  test('import and copy', () async {
    await _crashEverywhere('import', twoFoldersThreeFiles, (s, c) => importInto(s, 'y.txt', folder: FolderId.parse(c['b']!), bytes: 'new'.codeUnits));
    await _crashEverywhere('copy', twoFoldersThreeFiles, (s, c) => s.write((w, now) => w.copyEntry(EntryId.parse(c['y']!), FolderId.parse(c['a']!), now: now)));
  });

  test('an import that crashed before its row stays a resumable job', () async {
    final root = tempRoot();
    final faults = CrashAtStep(0);
    final store = await openStore(root, FakeLibraryClock(t0), faults: faults);
    final job = await store.write((w, now) => w.beginImport(now: now));
    await store.write((w, _) => (w.fs.openPart(job.id)..writeFromSync('hello'.codeUnits)).closeSync());
    faults.armed = true;
    await expectLater(
      store.write((w, now) => w.commitImport(job.id, const ImportedFileInfo(displayName: 'h.txt', kind: FileKind.document), now: now)),
      throwsA(isA<LibraryCrash>()),
    );
    store.abandon();
    final reopened = await openStore(root, FakeLibraryClock(t0));
    expect(reopened.openReport.violations, isEmpty);
    // Crashed at fs.mkdir: nothing committed, the job stays for the import pipeline to resume.
    expect(reopened.reader.importJobs().single.id, job.id);
    expect(reopened.reader.allEntries(), isEmpty);
    await reopened.close();
  });
}

/// Throws a plain error (not a [LibraryCrash]) the first time [step] is reached while armed.
final class _ThrowAt implements LibraryFaults {
  _ThrowAt(this.step);
  final String step;
  bool armed = false;

  @override
  void hit(String s) {
    if (armed && s == step) {
      armed = false;
      throw StateError('injected failure at $s');
    }
  }
}
