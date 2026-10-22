// OWNER: CORE-25
//
// MemoryStoreFs on a Windows host (FIX-S1Q-A3): the product joins its paths with the host's
// package:path context, so on Windows they carry backslashes; the in-memory fs must read them as
// separators or a created project never shows up in `list(projectsDir)`. Simulated with `p.windows`.

import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';

void main() {
  test('Windows-joined paths are folders: what is written under them is listed', () async {
    final fs = MemoryStoreFs(pathContext: p.windows);
    final projects = p.windows.join('/fake/support', 'danaview', 'editor', 'projects');
    expect(projects, r'/fake/support\danaview\editor\projects');
    final project = p.windows.join(projects, 'pr_trip0001');
    await fs.createDirectory(project);
    await fs.writeBytesSynced(p.windows.join(project, 'project.dnproj'), Uint8List.fromList([1, 2, 3]));

    final entries = await fs.list(projects);
    expect(entries, hasLength(1));
    expect(entries.single.type, StoreEntityType.directory);
    expect(p.windows.basename(entries.single.path), 'pr_trip0001');
    // A listed path goes back in as it came out.
    expect((await fs.list(entries.single.path)).map((e) => p.windows.basename(e.path)), ['project.dnproj']);
    expect((await fs.stat(p.windows.join(project, 'project.dnproj'))).size, 3);
    expect(fs.filePaths, ['/fake/support/danaview/editor/projects/pr_trip0001/project.dnproj']);
    expect(await fs.canonicalize(project), '/fake/support/danaview/editor/projects/pr_trip0001');
  });

  test('on a POSIX host a backslash stays part of the name', () async {
    final fs = MemoryStoreFs(pathContext: p.posix);
    await fs.writeBytesSynced(r'/a\b', Uint8List(0));
    expect(fs.filePaths, [r'/a\b']);
    expect((await fs.list('/')).single.path, r'/a\b');
  });
}
