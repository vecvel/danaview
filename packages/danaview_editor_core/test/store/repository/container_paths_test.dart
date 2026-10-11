// OWNER: CORE-25
//
// ARCH §8.2: no persisted byte under the editor roots holds the absolute app-container path, and a
// project saved under one iOS container `<uuid>` reopens under another with zero missing media
// (iOS changes the container UUID on every app update).

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/store.dart';

import 'support/repo_support.dart';

const _uuid1 = '0D9A1C52-7E8B-4F6A-9C3D-2B1E5F7A8C90';
const _uuid2 = 'F1E2D3C4-B5A6-4978-8695-A4B3C2D1E0F9';

StoreRoots _rootsOf(String uuid) {
  final base = '/var/mobile/Containers/Data/Application/$uuid';
  return StoreRoots(support: '$base/Library/Application Support', cache: '$base/Library/Caches', documents: '$base/Documents');
}

void main() {
  test('persisted files hold no container path and reopen under another container', () async {
    final timers = FakeTimers();
    final roots1 = _rootsOf(_uuid1);
    final repo1 = memRepo(timers, roots: roots1);
    final mem = repo1.memory;

    // Media of every locator kind, given as absolute container paths where they are files.
    final managedBytes = List<int>.generate(3000, (i) => (i * 7) % 256);
    final managedHash = hashOf(managedBytes);
    final managedPath = p.join(roots1.support, 'danaview/editor/media/${managedHash.substring(0, 2)}/$managedHash/clip.mp4');
    mem.putFile(managedPath, managedBytes);
    final docBytes = List<int>.generate(2000, (i) => (i * 3) % 256);
    final docPath = p.join(roots1.documents, 'Movies', 'film.mp4');
    mem.putFile(docPath, docBytes);
    const pid = 'pr_container01';
    final recBytes = List<int>.generate(900, (i) => i % 256);
    final recPath = p.join(roots1.support, 'danaview/editor/projects/$pid/assets/recordings/md_rec.wav');
    mem.putFile(recPath, recBytes);
    final linkedBytes = List<int>.generate(1500, (i) => (i * 11) % 256);
    final linkedPath = p.join(roots1.documents, 'linked.mov'); // reached through a bookmark
    mem.putFile(linkedPath, linkedBytes);

    MediaAsset a(String id, MediaKind kind, MediaLocator l, MediaOwnership o, List<int> bytes) =>
        asset(id, kind, duration: kind == MediaKind.image ? 0 : sec(10), size: bytes.length, hash: hashOf(bytes))
            .copyWith(locator: l, ownership: o);
    final pool = MediaPool({
      for (final x in [
        a('md_managed', MediaKind.video, FileLocator(managedPath), MediaOwnership.managedCopy, managedBytes),
        a('md_doc', MediaKind.video, FileLocator(docPath), MediaOwnership.external, docBytes),
        a('md_rec', MediaKind.recording, FileLocator(recPath), MediaOwnership.projectOwned, recBytes),
        a('md_bm', MediaKind.video, BookmarkLocator('Ym9va21hcms=', lastKnownPath: 'linked.mov'), MediaOwnership.external, linkedBytes),
        a('md_uri', MediaKind.video, const ContentUriLocator('content://media/external/video/42'), MediaOwnership.external, docBytes),
      ])
        x.id: x,
    });
    final project = EditProject(
      id: const ProjectId(pid),
      meta: ProjectMeta(name: 'Container', createdAt: when, updatedAt: when),
      timeline: Timeline(tracks: [
        lane('tr_main', TrackKind.video, [vclip('it_1', 0, 30, media: 'md_managed'), vclip('it_2', 30, 30, media: 'md_doc')], main: true),
      ]),
      pool: pool,
    );
    await repo1.seed(project);
    final loaded = await repo1.open(const ProjectId(pid));
    final s = EditSession(loaded.project, clock: timers.clock);
    edit(s);
    repo1.requestAutosave(s);
    await timers.elapse(const Duration(seconds: 3)); // journal slot
    edit(s, 6);
    await repo1.save(s, reason: SaveReason.lifecycle); // main + meta + refs
    edit(s, 9);
    repo1.requestAutosave(s);
    await timers.elapse(const Duration(seconds: 3));
    await repo1.flush(const ProjectId(pid));

    // 1. No persisted byte under the editor roots contains the container prefix.
    final persisted = [
      for (final f in mem.filePaths)
        if (repo1.inner.roots.isInsideEditorRoots(f) && !f.contains('/danaview/editor/media/') && !f.contains('/assets/')) f,
    ];
    expect(persisted.map((f) => p.basename(f)), containsAll(['project.dnproj', 'meta.json', 'refs.json', 'a.dnproj']));
    for (final f in persisted) {
      final text = utf8.decode(mem.peek(f)!, allowMalformed: true);
      expect(AppContainerPaths.contains(text), isFalse, reason: '$f holds a container path');
      expect(text, isNot(contains(_uuid1)), reason: f);
    }

    // 2. Move the whole container (an app update) and reopen there.
    await repo1.close(const ProjectId(pid));
    final roots2 = _rootsOf(_uuid2);
    final repo2 = memRepo(timers, roots: roots2, seed: 12);
    for (final f in mem.filePaths) {
      repo2.memory.putFile(f.replaceFirst(_uuid1, _uuid2), mem.peek(f)!);
    }
    final reopened = await repo2.open(const ProjectId(pid));
    expect(reopened.warnings, isEmpty);
    final access = MemoryMediaAccess(roots2, repo2.memory)
      ..bookmarks['Ym9va21hcms='] = linkedPath.replaceFirst(_uuid1, _uuid2)
      ..content['content://media/external/video/42'] = docPath.replaceFirst(_uuid1, _uuid2);
    final report = await MediaAvailabilityChecker(access).checkPool(reopened.project.pool);
    expect(report.byMedia.values.toSet(), {MediaAvailability.available});
    expect(report.blocking, isEmpty);
    for (final asset in reopened.project.pool.assets.values) {
      final l = asset.locator;
      if (l is AppRelativeLocator) expect(roots2.resolve(l), contains(_uuid2));
      expect(l, isNot(isA<FileLocator>()));
    }
    // The summary resolves its paths under the new container too.
    final sum = (await repo2.summaries()).single;
    expect(sum.health, ProjectHealth.ok);
  });

  test('refs.json and meta.json store only root-relative paths', () async {
    final timers = FakeTimers();
    final roots = _rootsOf(_uuid1);
    final repo = memRepo(timers, roots: roots);
    final id = await repo.create(const EmptyProjectSpec(name: 'Plain'));
    final refs = utf8.decode(repo.memory.peek(p.join(roots.projectDir(id), 'refs.json'))!);
    final meta = utf8.decode(repo.memory.peek(p.join(roots.projectDir(id), 'meta.json'))!);
    expect(refs, isNot(contains('/var/')));
    expect(meta, isNot(contains('/var/')));
    expect(ProjectRefs.decode(utf8.encode(refs)), ProjectRefs.empty);
  });
}
