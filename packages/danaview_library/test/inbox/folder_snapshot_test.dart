// OWNER: HOM-21
//
// The folder-list snapshot the Share Extension's picker reads (ARCH v1.2 §5.6): live folders only,
// in tree order with `Imported` first, depths and parents for indentation, the format and schema
// the extension checks, and nothing but folder names.

import 'dart:convert';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import '../import/import_harness.dart';
import '../support/sqlite_open.dart';

void main() {
  setUpAll(useHostSqlite);

  test('live folders in tree order with Imported first; trashed folders and their children left out', () async {
    final store = await openStore(tempDir('hom21_snap_').path);
    final work = await store.write((w, now) => w.createFolder('work', now: now));
    await store.write((w, now) => w.createFolder('Taxes', parent: work, now: now));
    await store.write((w, now) => w.createFolder('Archive', now: now));
    final old = await store.write((w, now) => w.createFolder('Old', now: now));
    await store.write((w, now) => w.createFolder('Inside old', parent: old, now: now));
    await store.write((w, now) => w.trashFolder(old, now: now));

    final json = jsonDecode(utf8.decode(buildFolderSnapshot(store.reader, now: t0))) as Map<String, Object?>;

    expect(json['format'], folderSnapshotFormat);
    expect(json['schema'], 1);
    expect(json['writtenAt'], t0.millisecondsSinceEpoch);
    final folders = (json['folders']! as List).cast<Map<String, Object?>>();
    final names = [for (final f in folders) f['name']];
    expect(names.first, 'Imported');
    expect(folders.first['imported'], isTrue);
    expect(names, containsAllInOrder(['Imported', 'Archive', 'work', 'Taxes']));
    expect(names, isNot(contains('Old')));
    expect(names, isNot(contains('Inside old')));
    final taxes = folders.firstWhere((f) => f['name'] == 'Taxes');
    expect(taxes['depth'], 1);
    expect(taxes['parentId'], work.value);
    expect(taxes['imported'], isFalse);
    expect(folders.firstWhere((f) => f['name'] == 'work')['parentId'], isNull);
  });

  test('cycles and orphans never loop or appear', () {
    final a = FolderId.random(), b = FolderId.random(), orphanParent = FolderId.random();
    LibraryFolder f(FolderId id, FolderId? parent, String name) =>
        LibraryFolder(id: id, parentId: parent, name: name, createdAt: t0, modifiedAt: t0);
    final json = folderSnapshotJson([f(a, b, 'A'), f(b, a, 'B'), f(FolderId.random(), orphanParent, 'Orphan'), f(FolderId.random(), null, 'Top')], now: t0);
    expect([for (final x in json['folders']! as List) (x as Map)['name']], ['Top']);
  });
}
