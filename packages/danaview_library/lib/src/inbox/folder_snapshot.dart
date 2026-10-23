// OWNER: HOM-21
//
// The folder-list snapshot the Share Extension's folder picker reads (ARCH v1.2 §5.6): the
// extension never opens library.db, so the app writes the live Danaview folders into the App Group
// as a small JSON file on launch, on every foreground and after folder changes. Format
// (`danaview.folderSnapshot`, schema 1), folders in tree order (parents before their children,
// `Imported` first, then by name):
//
//   {"format":"danaview.folderSnapshot","schema":1,"writtenAt":<ms>,
//    "folders":[{"id":"fd_…","name":"…","parentId":"fd_…"|null,"depth":0,"imported":true}, …]}
//
// The snapshot holds folder names only (no file names, no paths) and stays on the device.

import 'dart:convert';

import '../db/library_folder.dart';
import '../db/library_reader.dart';
import '../model/ids.dart';

/// The `format` string of the snapshot.
const String folderSnapshotFormat = 'danaview.folderSnapshot';

/// The snapshot schema this build writes.
const int folderSnapshotSchema = 1;

/// Folders deeper than this are left out of the snapshot (the picker indents by depth).
const int folderSnapshotMaxDepth = 32;

/// Folders kept in one snapshot (the extension lists them in one scroll view).
const int folderSnapshotMaxFolders = 2000;

/// The snapshot of the live folders [reader] holds, as UTF-8 JSON, written at [now].
List<int> buildFolderSnapshot(LibraryReader reader, {required DateTime now}) =>
    utf8.encode(jsonEncode(folderSnapshotJson(reader.allFolders(), now: now)));

/// The snapshot object of [folders] (trashed ones are skipped; orphans whose parent is not live are
/// left out, as the picker could not place them).
Map<String, Object?> folderSnapshotJson(Iterable<LibraryFolder> folders, {required DateTime now}) {
  final live = [for (final f in folders) if (!f.isTrashed) f];
  final children = <FolderId?, List<LibraryFolder>>{};
  for (final f in live) {
    (children[f.parentId] ??= []).add(f);
  }
  int order(LibraryFolder a, LibraryFolder b) {
    final ai = a.systemRole == FolderSystemRole.imported, bi = b.systemRole == FolderSystemRole.imported;
    if (ai != bi) return ai ? -1 : 1;
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.value.compareTo(b.id.value);
  }

  for (final list in children.values) {
    list.sort(order);
  }
  final out = <Map<String, Object?>>[];
  final seen = <FolderId>{};
  void walk(FolderId? parent, int depth) {
    if (depth > folderSnapshotMaxDepth) return;
    for (final f in children[parent] ?? const <LibraryFolder>[]) {
      if (out.length >= folderSnapshotMaxFolders || !seen.add(f.id)) continue;
      out.add({
        'id': f.id.value,
        'name': f.name,
        'parentId': f.parentId?.value,
        'depth': depth,
        'imported': f.systemRole == FolderSystemRole.imported,
      });
      walk(f.id, depth + 1);
    }
  }

  walk(null, 0);
  return {
    'format': folderSnapshotFormat,
    'schema': folderSnapshotSchema,
    'writtenAt': now.toUtc().millisecondsSinceEpoch,
    'folders': out,
  };
}
