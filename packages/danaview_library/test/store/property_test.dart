// OWNER: HOM-17
//
// BUILD_PLAN HOM-17: "1,000 seeded random operation sequences keep every invariant and match an
// in-memory model". Each sequence runs ~24 random folder, entry, Recently deleted, clock and purge
// operations (valid and invalid) against a real store in a temp root and the same operations
// against a plain-Dart model of V2-06 / V2-08 / §5.4; after every operation the rows must equal the
// model, and the invariants are checked every few operations and at the end.

import 'dart:math';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import 'store_harness.dart';

final class _F {
  _F(this.parent, this.name, {this.system = false});
  FolderId? parent;
  String name;
  final bool system;
  DateTime? trashedAt, expiresAt;
  bool get live => trashedAt == null;
}

final class _E {
  _E(this.folder, this.name);
  FolderId folder;
  String name;
  bool fav = false;
  DateTime? trashedAt, expiresAt, openedAt;
  bool get live => trashedAt == null;
}

final class _Model {
  final Map<FolderId, _F> folders = {};
  final Map<EntryId, _E> entries = {};
  late FolderId imported;

  Set<String> entryNames(FolderId folder, {EntryId? except}) => {
        for (final MapEntry(:key, :value) in entries.entries)
          if (value.live && value.folder == folder && key != except) value.name.toLowerCase(),
      };

  Set<String> folderNames(FolderId? parent, {FolderId? except}) => {
        for (final MapEntry(:key, :value) in folders.entries)
          if (value.live && value.parent == parent && key != except) value.name.toLowerCase(),
      };

  bool isLiveFolder(FolderId? id) => id == null || (folders[id]?.live ?? false);

  List<FolderId> subtree(FolderId root, {DateTime? trashedAt}) {
    final out = [root];
    for (var i = 0; i < out.length; i++) {
      for (final MapEntry(:key, :value) in folders.entries) {
        if (value.parent == out[i] && (trashedAt == null || value.trashedAt == trashedAt) && !out.contains(key)) out.add(key);
      }
    }
    return out;
  }

  FolderId restoreFolderFor(FolderId folder) {
    FolderId? next = folder;
    while (next != null) {
      final f = folders[next];
      if (f == null) break;
      if (f.live) return next;
      next = f.parent;
    }
    return imported;
  }

  FolderId? restoreParentFor(FolderId? parent) {
    var next = parent;
    while (next != null) {
      final f = folders[next];
      if (f == null) return imported;
      if (f.live) return next;
      next = f.parent;
    }
    return null;
  }
}

const _fileNames = ['a.txt', 'A.txt', 'b.jpg', 'c.pdf', 'd.mp4'];
const _folderNames = ['X', 'x', 'Y', 'Trips'];

Future<void> _runSequence(int seed) async {
  final rnd = Random(seed);
  final root = tempRoot();
  final clock = FakeLibraryClock(t0);
  final store = await openStore(root, clock, seed: seed);
  final m = _Model()..imported = store.reader.systemFolder(FolderSystemRole.imported)!.id;
  m.folders[m.imported] = _F(null, 'Imported', system: true);

  T pick<T>(List<T> list) => list[rnd.nextInt(list.length)];
  FolderId? anyFolderOrNull() => m.folders.isEmpty || rnd.nextInt(5) == 0 ? null : pick(m.folders.keys.toList());

  Future<bool> attempt(Future<Object?> Function() op, {required bool valid, required String what}) async {
    try {
      await op();
    } on LibraryWriteException {
      expect(valid, isFalse, reason: 'seed $seed: $what was refused but the model allows it');
      return false;
    }
    expect(valid, isTrue, reason: 'seed $seed: $what succeeded but the model refuses it');
    return true;
  }

  void compare(String after) {
    final folders = {for (final f in store.reader.allFolders(includeTrashed: true)) f.id: f};
    expect(folders.keys.toSet(), m.folders.keys.toSet(), reason: 'seed $seed after $after: folder ids');
    for (final MapEntry(:key, :value) in m.folders.entries) {
      final f = folders[key]!;
      expect((f.parentId, f.name, f.trashedAt, f.expiresAt), (value.parent, value.name, value.trashedAt, value.expiresAt),
          reason: 'seed $seed after $after: folder ${key.value}');
    }
    final entries = {for (final e in store.reader.allEntries(includeTrashed: true)) e.id: e};
    expect(entries.keys.toSet(), m.entries.keys.toSet(), reason: 'seed $seed after $after: entry ids');
    for (final MapEntry(:key, :value) in m.entries.entries) {
      final e = entries[key]!;
      expect((e.folderId, e.displayName, e.isFavourite, e.trashedAt, e.expiresAt), (value.folder, value.name, value.fav, value.trashedAt, value.expiresAt),
          reason: 'seed $seed after $after: entry ${key.value}');
    }
    final recents = [
      for (final MapEntry(:key, :value) in m.entries.entries)
        if (value.live && value.openedAt != null) (key, value.openedAt!),
    ]..sort((a, b) {
        final t = b.$2.compareTo(a.$2);
        return t != 0 ? t : a.$1.value.compareTo(b.$1.value);
      });
    expect(store.reader.recents().map((e) => e.id).toList(), recents.map((r) => r.$1).toList(), reason: 'seed $seed after $after: recents');
  }

  final steps = 20 + rnd.nextInt(10);
  for (var step = 0; step < steps; step++) {
    final op = rnd.nextInt(14);
    final now = clock();
    var what = 'op $op';
    switch (op) {
      case 0 || 1:
        final name = pick(_folderNames);
        final parent = anyFolderOrNull();
        what = 'createFolder';
        final valid = m.isLiveFolder(parent);
        FolderId? id;
        if (await attempt(() async => id = await store.write((w, now) => w.createFolder(name, parent: parent, now: now)), valid: valid, what: what)) {
          m.folders[id!] = _F(parent, uniqueName(name, m.folderNames(parent), splitExtension: false));
        }
      case 2:
        if (m.folders.isEmpty) break;
        final id = pick(m.folders.keys.toList());
        final name = pick(_folderNames);
        final f = m.folders[id]!;
        what = 'renameFolder';
        if (await attempt(() => store.write((w, now) => w.renameFolder(id, name, now: now)), valid: f.live && !f.system, what: what)) {
          f.name = uniqueName(name, m.folderNames(f.parent, except: id), splitExtension: false);
        }
      case 3:
        final id = pick(m.folders.keys.toList());
        final target = anyFolderOrNull();
        final f = m.folders[id]!;
        what = 'moveFolder';
        final valid = f.live && !f.system && m.isLiveFolder(target) && (target == null || !m.subtree(id).contains(target));
        if (await attempt(() => store.write((w, now) => w.moveFolder(id, target, now: now)), valid: valid, what: what) && f.parent != target) {
          f.name = uniqueName(f.name, m.folderNames(target, except: id), splitExtension: false);
          f.parent = target;
        }
      case 4 || 5 || 6:
        final name = pick(_fileNames);
        final target = rnd.nextBool() ? null : anyFolderOrNull();
        what = 'import';
        final dest = target ?? m.imported;
        final valid = m.isLiveFolder(dest);
        FileEntry? e;
        if (await attempt(() async => e = await importInto(store, name, folder: target), valid: valid, what: what)) {
          m.entries[e!.id] = _E(dest, uniqueName(name, m.entryNames(dest)));
        }
      case 7:
        if (m.entries.isEmpty) break;
        final id = pick(m.entries.keys.toList());
        final e = m.entries[id]!;
        final name = pick(_fileNames);
        what = 'renameEntry';
        if (await attempt(() => store.write((w, now) => w.renameEntry(id, name, now: now)), valid: e.live, what: what)) {
          e.name = uniqueName(name, m.entryNames(e.folder, except: id));
        }
      case 8:
        if (m.entries.isEmpty) break;
        final id = pick(m.entries.keys.toList());
        final target = pick(m.folders.keys.toList());
        final e = m.entries[id]!;
        what = 'moveEntries';
        if (await attempt(() => store.write((w, now) => w.moveEntries([id], target, now: now)), valid: e.live && m.isLiveFolder(target), what: what) &&
            e.folder != target) {
          e.name = uniqueName(e.name, m.entryNames(target));
          e.folder = target;
        }
      case 9:
        if (m.entries.isEmpty) break;
        final id = pick(m.entries.keys.toList());
        final e = m.entries[id]!;
        what = rnd.nextBool() ? 'trashEntry' : 'markOpened';
        if (what == 'trashEntry') {
          if (await attempt(() => store.write((w, now) => w.trashEntries([id], now: now)), valid: e.live, what: what)) {
            e
              ..trashedAt = now
              ..expiresAt = now.add(recentlyDeletedRetention);
          }
        } else if (await attempt(() => store.write((w, now) => w.markOpened(id, now: now)), valid: e.live, what: what)) {
          e.openedAt = now;
          if (rnd.nextBool()) {
            final fav = !e.fav;
            await store.write((w, _) => w.setEntryFavourite(id, fav));
            e.fav = fav;
          }
        }
      case 10:
        final id = pick(m.folders.keys.toList());
        final f = m.folders[id]!;
        what = 'trashFolder';
        if (await attempt(() => store.write((w, now) => w.trashFolder(id, now: now)), valid: f.live && !f.system, what: what)) {
          for (final sub in m.subtree(id)) {
            final s = m.folders[sub]!;
            if (s.live) {
              s
                ..trashedAt = now
                ..expiresAt = now.add(recentlyDeletedRetention);
            }
            for (final e in m.entries.values.where((e) => e.folder == sub && e.live)) {
              e
                ..trashedAt = now
                ..expiresAt = now.add(recentlyDeletedRetention);
            }
          }
        }
      case 11:
        final trashed = <ItemId>[
          for (final MapEntry(:key, :value) in m.entries.entries)
            if (!value.live) key,
          for (final MapEntry(:key, :value) in m.folders.entries)
            if (!value.live) key,
        ];
        if (trashed.isEmpty) break;
        final id = pick(trashed);
        what = 'restore';
        expect(await attempt(() => store.write((w, now) => w.restore(id, now: now)), valid: true, what: what), isTrue);
        if (id.asEntry case final eid?) {
          final e = m.entries[eid]!;
          final dest = m.restoreFolderFor(e.folder);
          e
            ..name = uniqueName(e.name, m.entryNames(dest))
            ..folder = dest
            ..trashedAt = null
            ..expiresAt = null;
        } else {
          final fid = id.asFolder!;
          final f = m.folders[fid]!;
          final t = f.trashedAt;
          final parent = m.restoreParentFor(f.parent);
          for (final sub in m.subtree(fid, trashedAt: t)) {
            final s = m.folders[sub]!;
            if (s.trashedAt == t) {
              s
                ..trashedAt = null
                ..expiresAt = null;
            }
            for (final e in m.entries.values.where((e) => e.folder == sub && e.trashedAt == t)) {
              e
                ..trashedAt = null
                ..expiresAt = null;
            }
          }
          f
            ..name = uniqueName(f.name, m.folderNames(parent, except: fid), splitExtension: false)
            ..parent = parent;
        }
      case 12:
        final days = rnd.nextInt(20) - 3;
        clock.advance(Duration(days: days, minutes: rnd.nextInt(600)));
        what = 'sweep';
        await store.sweepNow();
        final at = clock();
        m.entries.removeWhere((_, e) => e.expiresAt != null && !e.expiresAt!.isAfter(at));
        m.folders.removeWhere((_, f) => f.expiresAt != null && !f.expiresAt!.isAfter(at));
      case 13:
        if (rnd.nextInt(4) != 0) break;
        what = 'emptyTrash';
        await store.write((w, _) => w.emptyTrash());
        m.entries.removeWhere((_, e) => !e.live);
        m.folders.removeWhere((_, f) => !f.live);
    }
    compare(what);
    if (step % 6 == 5) expect(await store.checkInvariants(), isEmpty, reason: 'seed $seed after $what');
  }
  expect(await store.checkInvariants(), isEmpty, reason: 'seed $seed at the end');
  await store.close();
  // A relaunch changes nothing and finds nothing to repair.
  final again = await openStore(root, clock);
  expect(again.openReport.violations, isEmpty, reason: 'seed $seed on reopen');
  expect(again.openReport.reconcile!.recovered + again.openReport.reconcile!.repaired, 0, reason: 'seed $seed on reopen');
  await again.close();
}

void main() {
  test('1,000 seeded random operation sequences keep every invariant and match the model', () async {
    for (var seed = 0; seed < 1000; seed++) {
      await _runSequence(seed);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
