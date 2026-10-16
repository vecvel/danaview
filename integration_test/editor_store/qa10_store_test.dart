// OWNER: QA-10
//
// QA-10 (BUILD_PLAN M6): persistence, crash recovery and media-access survival on a device or
// simulator, driven in three phases by tool/qa10_host.py:
//
//   DV_E2E_PHASE=seed    boot the app; copy the originals into Documents/qa10; the host kills the
//                        app and takes the baseline snapshot of every original (size, SHA-256,
//                        mtime, xattrs) and of the folders that hold them.
//   DV_E2E_PHASE=edit    a project from the originals (Documents references + iOS bookmarks to
//                        files outside the container), a manual save, then one more edit that only
//                        the autosave journal holds; store fixtures for the next launch: a managed
//                        copy (Photos route), a project whose main file is corrupt (.bak good), one
//                        whose every copy is corrupt (journal good), one saved by a newer schema
//                        (read-only) and one that needs a newer app (blocked). The host kills the
//                        app while the editor is open (forced kill).
//   DV_E2E_PHASE=verify  `flutter test` reinstalls the app over the top and launches it: crash
//                        recovery restores the journal; zero missing media after the reinstall; the
//                        bookmark resolves to the same file (V-D3); backup exclusion read back by
//                        the host (V-D4); fsync evidence (V-D1); corrupt-file restore paths; D-12
//                        read-only / blocked; then a full session (export with "Keep a copy",
//                        relink, project delete, GC) and the host's comparison of every original
//                        with the baseline (D-44).
//
// Every check prints `DV_QA10 <check>: <result>` for the report
// (docs/v1.1/editor/qa/QA-10-persistence.md). Without the host driver the phases are skipped with
// a reason.

// ignore_for_file: implementation_imports, avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor/src/editor/flows/export/export_controller.dart';
import 'package:danaview_editor/src/editor/flows/relink/relink_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show SavePhase;
import 'package:danaview_editor/src/editor/state/media_health_controller.dart';
import 'package:danaview_editor_core/codec.dart' show currentProjectMinReader, currentProjectSchema;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddMarker, EditSession, SetText;
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../editor/support/e2e.dart';
import 'support/qa10.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const phase = E2eConfig.phase;
  final hosted = E2eHandshake.available;

  // -----------------------------------------------------------------------------------------------
  // Phase seed
  // -----------------------------------------------------------------------------------------------

  testWidgets('QA-10 seed: originals staged in Documents, then the host takes the baseline', (tester) async {
    await E2eApp.launch(tester);
    Qa10Media.stage();
    E2eHandshake.saveState(Qa10Config.stateKey, {
      'documents': Qa10Store.roots.documents,
      'container': Directory.systemTemp.parent.path,
      'originals': [Qa10Media.video, Qa10Media.still, Qa10Media.relinkTarget],
    });
    qa10Report('seed', 'staged', 'container ${Directory.systemTemp.parent.path}');
    await E2eHandshake.requestAndDie(tester, 'kill');
  }, skip: phase != 'seed' || !hosted);

  // -----------------------------------------------------------------------------------------------
  // Phase edit
  // -----------------------------------------------------------------------------------------------

  testWidgets('QA-10 edit: session, journal-only edit and store fixtures, then a forced kill', (tester) async {
    final seeded = E2eHandshake.loadState(Qa10Config.stateKey);
    expect(seeded, isNotNull, reason: 'run phase "seed" first');
    final state = <String, Object?>{...seeded!};
    await E2eApp.launch(tester);
    final world = E2eApp.world;
    final repo = Qa10Store.repo;
    final stamp = DateTime.now().millisecondsSinceEpoch % 1000000;
    state['editContainer'] = Directory.systemTemp.parent.path;

    // 1. The session project from the originals (Projects › New project › Files).
    final external = Qa10Config.hasHostMedia;
    if (!external) qa10Report('V-D3 bookmark', 'not run', 'no DV_QA10_HOST_DIR (iOS Simulator host folder) on this run');
    final media = [Qa10Media.video, Qa10Media.still, if (external) ...[Qa10Config.hostOriginal, Qa10Config.hostScratch]];
    final ed = await E2eEditor.createProject(tester, name: 'QA10 session $stamp', media: media);
    final byName = {for (final a in ed.project.pool.assets.values) a.displayName: a};
    for (final name in [Fx.frameCounter, Fx.still4k]) {
      final l = byName[name]!.locator;
      expect(l, isA<AppRelativeLocator>().having((l) => l.root, 'root', AppRoot.documents), reason: '$name is a Documents reference');
    }
    if (external) {
      final tone = byName[Fx.toneUnderVideo]!;
      final scratch = byName[Fx.clapFlash]!;
      expect(tone.locator, isA<BookmarkLocator>(), reason: 'a Files pick outside the container is bookmarked (ARCH §9.1)');
      expect(scratch.locator, isA<BookmarkLocator>());
      final stat = await world.engine.access.stat(tone.locator);
      final hash = await world.engine.access.quickHash(tone.locator);
      state['bookmark'] = {'media': tone.id.value, 'size': stat!.sizeBytes, 'modifiedMs': stat.modifiedMs, 'hash': hash};
      state['scratchMedia'] = scratch.id.value;
      qa10Report('V-D3 bookmark created', 'ok', '${stat.sizeBytes} B hash $hash');
    }

    // 2. A manual save, then one edit only the journal holds.
    await ed.seekFrame(30);
    await ed.invoke(EditorActionId.addText);
    await ed.waitProject((p) => ed.items<TextItem>().isNotEmpty, what: 'the text');
    final text = ed.items<TextItem>().single.id;
    final saved = 'QA10 SAVED $stamp';
    final journaled = 'QA10 JOURNAL $stamp';
    ed.apply(SetText(text, saved));
    await ed.controller.saveNow(manual: true);
    await E2eApp.pumpUntil(tester, () => ed.state.save.phase == SavePhase.saved, what: 'the manual save');
    ed.apply(SetText(text, journaled));
    await E2eApp.pumpUntil(tester, () => ed.state.save.phase == SavePhase.saved, what: 'the autosave journal', timeout: const Duration(seconds: 30));
    final journalDir = Directory('${Qa10Store.roots.projectDir(ed.id.value)}/journal');
    expect(journalDir.existsSync() && journalDir.listSync().whereType<File>().any((f) => f.path.endsWith('.dnproj')), isTrue,
        reason: 'the journal slot is on disk before the kill');
    state['session'] = ed.id.value;
    state['saved'] = saved;
    state['journaled'] = journaled;

    // 3. A managed copy (the Photos route: a temporary copy under work/picks is moved into media/).
    final managed = await repo.create(FromMediaProjectSpec(picks: [Qa10Media.temporaryPick(Fx.tone1k)], name: 'QA10 managed $stamp'));
    state['managed'] = managed.value;
    expect(Directory(Qa10Store.roots.mediaDir).existsSync(), isTrue, reason: 'media/ exists after a managed import');

    // 4. Corrupt main, good .bak: main = 2 markers, .bak = 1 marker.
    final bakOnly = await _project(repo, 'QA10 bak $stamp', saves: 2);
    Qa10Store.corrupt(Qa10Store.mainOf(bakOnly));
    state['bakOnly'] = bakOnly.value;

    // 5. Every copy corrupt, journal good: main = 1 marker, journal = 2 markers.
    final journalOnly = await _project(repo, 'QA10 journal $stamp', saves: 1, journaled: 1);
    Qa10Store.corrupt(Qa10Store.mainOf(journalOnly));
    if (Qa10Store.bakOf(journalOnly).existsSync()) Qa10Store.corrupt(Qa10Store.bakOf(journalOnly));
    state['journalOnly'] = journalOnly.value;

    // 6. D-12: saved by a newer schema this app can read (read-only), and one it cannot (blocked).
    final newer = await _project(repo, 'QA10 newer $stamp', saves: 1);
    Qa10Store.markNewer(newer, schema: currentProjectSchema + 1, minReader: currentProjectMinReader);
    final blocked = await _project(repo, 'QA10 blocked $stamp', saves: 1);
    Qa10Store.markNewer(blocked, schema: currentProjectSchema + 1, minReader: currentProjectMinReader + 1);
    state['newer'] = newer.value;
    state['blocked'] = blocked.value;

    E2eHandshake.saveState(Qa10Config.stateKey, state);
    qa10Report('edit', 'ready for the kill', 'session ${ed.id} managed $managed bak $bakOnly journal $journalOnly newer $newer blocked $blocked');
    await E2eApp.screenshot(tester, 'qa10_before_kill');
    // Forced kill with the editor open and the journal ahead of the main document.
    await E2eHandshake.requestAndDie(tester, 'kill');
  }, skip: phase != 'edit' || !hosted);

  // -----------------------------------------------------------------------------------------------
  // Phase verify
  // -----------------------------------------------------------------------------------------------

  Map<String, Object?>? st;
  Map<String, Object?> state() => st ??= E2eHandshake.loadState(Qa10Config.stateKey) ?? (throw TestFailure('run phases "seed" and "edit" first'));
  ProjectId idOf(String key) => ProjectId(state()[key]! as String);
  String? keptCopy;

  testWidgets('QA-10 verify 1: crash recovery after the forced kill, zero missing media after the reinstall, bookmark (V-D3)',
      (tester) async {
    final st = state();
    await E2eApp.launch(tester);
    final world = E2eApp.world;
    final repo = Qa10Store.repo;
    final session = idOf('session');

    final container = Directory.systemTemp.parent.path;
    qa10Report('reinstall container', container == st['editContainer'] ? 'same path' : 'new path',
        'before ${st['editContainer']} after $container');

    // The journal is ahead of the main document after the kill.
    final recoverable = await repo.recoverable();
    final rs = recoverable.where((r) => r.projectId == session).toList();
    expect(rs, hasLength(1), reason: 'the killed session is recoverable');
    expect(rs.single.journalRevision, greaterThan(rs.single.mainRevision));
    qa10Report('crash recovery offer', 'ok', 'journal rev ${rs.single.journalRevision} > main rev ${rs.single.mainRevision}');

    // Projects › recovery banner › Restore (the user's path).
    await E2eApp.openProjectsFromHome(tester);
    await E2eApp.waitKey(tester, 'recovery-$session');
    await E2eApp.screenshot(tester, 'qa10_recovery_offer');
    await E2eApp.tapKey(tester, 'recovery-restore-$session');
    if (find.byType(EditorScreen).evaluate().isEmpty) {
      await E2eApp.pumpUntil(tester, () => !E2eApp.hasKey('recovery-$session'), what: 'the restore to finish');
      await E2eApp.tapKey(tester, 'project-card-$session');
    }
    final ed = await E2eEditor.attach(tester);
    expect(ed.id, session);
    final texts = [for (final t in ed.items<TextItem>()) t.text];
    expect(texts, contains(st['journaled']), reason: 'the journal-only edit is restored');
    qa10Report('crash recovery restore', 'ok', 'text "${st['journaled']}" restored');

    // Zero missing media after the reinstall (Documents references re-resolve against the new
    // container; bookmarks resolve).
    final health = ed.container.listen(mediaHealthControllerProvider(session), (_, __) {});
    try {
      await E2eApp.pumpUntil(tester, () => health.read().checked, what: 'the media health report', timeout: const Duration(seconds: 60));
      final h = health.read();
      expect(h.offline, isEmpty, reason: 'no missing media after the reinstall: ${h.byMedia}');
      qa10Report('reinstall zero missing media', 'ok', '${h.byMedia.length} assets online');
    } finally {
      health.close();
    }
    for (final a in ed.project.pool.assets.values) {
      final s = await world.engine.access.stat(a.locator);
      expect(s, isNotNull, reason: '${a.displayName} resolves after the reinstall');
    }

    // V-D3: the bookmark made before the kill resolves to the same file.
    if (st['bookmark'] case final Map<String, Object?> b) {
      final asset = ed.project.pool[MediaId(b['media']! as String)]!;
      final stat = await world.engine.access.stat(asset.locator);
      final hash = await world.engine.access.quickHash(asset.locator);
      expect(stat?.sizeBytes, b['size']);
      expect(hash, b['hash']);
      qa10Report('V-D3 bookmark across launches', 'ok', 'same size and quickHash $hash after kill + reinstall');
    } else {
      qa10Report('V-D3 bookmark across launches', 'not run', 'no host media in the edit phase');
    }

    // Full session part 1: an export with "Keep a copy in Danaview" (D-44: Documents/Exports only).
    final handoffs = world.engine.files.records.length;
    await E2eExport.open(ed);
    final c = E2eExport.controller(ed);
    c.selectPreset(ExportPresetId.custom);
    c.updateSettings((s) => s.copyWith(shortSide: 720, container: ExportContainer.mp4, codec: VideoCodec.h264));
    c.setDestination(ExportDestination.files);
    c.setKeepCopy(true);
    await tester.pump();
    final settings = (E2eExport.state(ed) as ExportUiSetup).draft.settings;
    expect((E2eExport.state(ed) as ExportUiSetup).draft.keepCopy, isTrue);
    await E2eApp.tapKey(tester, 'export-start');
    final completed = Completer<ExportUiCompleted>();
    await E2eExport.finish(ed, settings, handoffs: handoffs, observe: (s) {
      if (s is ExportUiCompleted && !completed.isCompleted) completed.complete(s);
    });
    final done = await completed.future;
    expect(done.keptCopyName, isNotNull, reason: 'Keep a copy wrote a file (keepCopyFailed: ${done.keepCopyFailed})');
    keptCopy = done.keptCopyName;
    final kept = File('${Qa10Store.roots.documentsExportsDir}/$keptCopy');
    expect(kept.existsSync(), isTrue, reason: 'the kept copy is in Documents/Exports');
    qa10Report('export keep a copy', 'ok', 'Documents/Exports/$keptCopy ${kept.lengthSync()} B');

    // Full session part 2: relink. The bookmarked scratch file goes away; the Missing media flow
    // relinks it to the byte-identical original in Documents/qa10/relink.
    if (st['scratchMedia'] case final String scratchId) {
      final id = MediaId(scratchId);
      File(Qa10Config.hostScratch).deleteSync();
      await world.runtime.resumed();
      final relink = ed.container.listen(relinkControllerProvider(session), (_, __) {});
      try {
        RelinkController ctl() => ed.container.read(relinkControllerProvider(session).notifier);
        RelinkState relinkState() => ed.container.read(relinkControllerProvider(session));
        await E2eApp.pumpUntil(tester, () => relinkState().rows.any((r) => r.asset.id == id), what: 'the missing scratch file row',
            timeout: const Duration(seconds: 60));
        await E2eApp.pumpWhile(tester, ctl().stage(id, Qa10Media.filesPick(Qa10Media.relinkTarget)), what: 'the relink check');
        await E2eApp.pumpUntil(tester, () => relinkState().rows.firstWhere((r) => r.asset.id == id).willRelink, what: 'the staged relink');
        final changed = await E2eApp.pumpWhile(tester, ctl().apply(), what: 'the relink');
        expect(changed, isTrue);
      } finally {
        relink.close();
      }
      final relinked = ed.project.pool[id]!;
      expect(relinked.locator, isA<AppRelativeLocator>().having((l) => l.root, 'root', AppRoot.documents));
      qa10Report('relink', 'ok', '${relinked.displayName} -> Documents/${(relinked.locator as AppRelativeLocator).relPath}');
    } else {
      qa10Report('relink', 'not run', 'no host scratch media in the edit phase');
    }
    await ed.controller.saveNow(manual: true);
    await E2eApp.pumpUntil(tester, () => ed.state.save.phase == SavePhase.saved, what: 'the save after the session');
    await ed.close();
  }, skip: phase != 'verify');

  testWidgets('QA-10 verify 2: backup exclusion read back (V-D4)', (tester) async {
    await E2eApp.launch(tester);
    final roots = Qa10Store.roots;
    if (!Platform.isIOS) {
      qa10Report('V-D4 backup exclusion', 'deferred: Windows lane', 'Android uses integration_test/editor_store/tool/android_backup_check.sh (V-A7)');
      return;
    }
    if (!hosted) {
      qa10Report('V-D4 backup exclusion', 'not run', 'needs the host driver');
      return;
    }
    final attrs = await Qa10Host.backupAttributes(tester, {
      'media': roots.mediaDir,
      'derived': roots.derivedDir,
      'speech': roots.speechSupport,
      'projects': roots.projectsDir,
      'editorSupport': roots.editorSupport,
      'documents': roots.documents,
    });
    print('DV_QA10 backup attributes $attrs');
    for (final name in ['media', 'derived']) {
      expect(attrs[name]!['exists'], isTrue, reason: '$name/ exists (created by the managed import)');
      expect(attrs[name]!['excluded'], isTrue, reason: '$name/ is excluded from backup');
    }
    if (attrs['speech']!['exists'] == true) {
      expect(attrs['speech']!['excluded'], isTrue, reason: 'danaview/speech is excluded from backup');
    } else {
      qa10Report('V-D4 speech', 'not present', 'danaview/speech was not created in this run (no speech model)');
    }
    for (final name in ['projects', 'editorSupport', 'documents']) {
      expect(attrs[name]!['excluded'], isFalse, reason: '$name stays in backups (projects and recordings are backed up)');
    }
    qa10Report('V-D4 backup exclusion', 'ok', 'media/ derived/ excluded; projects/ and Documents backed up');
  }, skip: phase != 'verify');

  testWidgets('QA-10 verify 3: fsync evidence (V-D1)', (tester) async {
    await E2eApp.launch(tester);
    final probe = Qa10FsyncProbe.load();
    if (probe == null) {
      qa10Report('V-D1 fsync', Platform.isIOS ? 'not run' : 'deferred: Windows lane',
          Platform.isIOS ? 'fsync probe not injected (run through tool/qa10_host.py)' : 'strace procedure in android_backup_check.sh');
      return;
    }
    final repo = Qa10Store.repo;
    // dart:io RandomAccessFile.flush (LocalStoreFs.writeBytesSynced).
    final dir = Directory('${Qa10Store.roots.workDir}/qa10-fsync')..createSync(recursive: true);
    final path = '${dir.path}/probe.bin';
    final before = probe.fsyncCalls;
    await const LocalStoreFs().writeBytesSynced(path, Uint8List.fromList(List.filled(4096, 7)));
    final after = probe.fsyncCalls;
    final records = probe.records();
    expect(after, greaterThan(before), reason: 'RandomAccessFile.flush() calls fsync(2)');
    expect(records.any((r) => r.startsWith('fsync ') && r.endsWith('/probe.bin')), isTrue, reason: 'fsync on the written file: $records');
    qa10Report('V-D1 RandomAccessFile.flush', 'fsync(2) observed', '${after - before} call(s), F_FULLFSYNC calls ${probe.fullFsyncCalls}');

    // A real project save (writer isolate, AtomicFile tmp → fsync → rename).
    final id = await _project(repo, 'QA10 fsync', saves: 0, keepOpen: true);
    final s0 = probe.fsyncCalls;
    final session = _sessions.remove(id)!;
    session.apply(const AddMarker(500000, name: 'fsync'));
    await repo.save(session, reason: SaveReason.manual);
    await repo.close(id);
    final tmpFsync = probe.records().where((r) => r.contains('/projects/${id.value}/project.dnproj.tmp-')).toList();
    expect(probe.fsyncCalls, greaterThan(s0));
    expect(tmpFsync, isNotEmpty, reason: 'the main document is fsynced under its tmp name before the rename');
    qa10Report('V-D1 project save', 'fsync(2) observed', '${probe.fsyncCalls - s0} call(s): ${tmpFsync.first}');
    await repo.delete(id);
    dir.deleteSync(recursive: true);
  }, skip: phase != 'verify');

  testWidgets('QA-10 verify 4: corrupt-file restore paths', (tester) async {
    await E2eApp.launch(tester);
    final repo = Qa10Store.repo;
    final bakOnly = idOf('bakOnly');
    final journalOnly = idOf('journalOnly');

    // Corrupt main, valid .bak: the summary is fine and open reads the .bak (1 marker); opening
    // never writes.
    final sBak = await Qa10Store.summaryOf(bakOnly);
    expect(sBak?.health, ProjectHealth.ok);
    final mainBefore = Qa10Store.fingerprint(Qa10Store.mainOf(bakOnly));
    final lBak = await repo.open(bakOnly);
    expect(lBak.project.markers, hasLength(1), reason: 'the .bak (previous save) is read');
    expect(Qa10Store.fingerprint(Qa10Store.mainOf(bakOnly)), mainBefore, reason: 'opening never writes');
    // The next save repairs the main document.
    final sess = EditSession(lBak.project);
    await repo.save(sess, reason: SaveReason.manual);
    await repo.close(bakOnly);
    final lBak2 = await repo.open(bakOnly);
    expect(lBak2.project.markers, hasLength(1));
    await repo.close(bakOnly);
    qa10Report('corrupt main, .bak restore', 'ok', 'opened from .bak, the next save rewrote a valid main');

    // Every copy corrupt, journal valid. The Projects scan reads headers only (the bodies are
    // verified on open), so the card shows the recovery flag; open fails with `corrupt`; the
    // recovery banner offers "Restore last good version", which promotes the journal.
    final sJ = await Qa10Store.summaryOf(journalOnly);
    expect(sJ?.hasRecovery, isTrue, reason: 'the card shows the recovery flag');
    qa10Report('corrupt summary', 'info', 'header-only scan health ${sJ?.health.name} (bodies are verified on open)');
    await expectLater(repo.open(journalOnly), throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.corrupt)));
    final r = (await repo.recoverable()).where((r) => r.projectId == journalOnly).toList();
    expect(r, hasLength(1), reason: '"Restore last good version" is offered');
    await E2eApp.openProjectsFromHome(tester);
    await E2eApp.waitKey(tester, 'recovery-$journalOnly');
    await E2eApp.screenshot(tester, 'qa10_projects_corrupt_recovery');
    await E2eApp.tapKey(tester, 'recovery-restore-$journalOnly');
    if (find.byType(EditorScreen).evaluate().isEmpty) {
      await E2eApp.pumpUntil(tester, () => !E2eApp.hasKey('recovery-$journalOnly'), what: 'the restore to finish');
      await E2eApp.tapKey(tester, 'project-card-$journalOnly');
    }
    final ed = await E2eEditor.attach(tester, waitPreview: false);
    expect(ed.id, journalOnly);
    expect(ed.project.markers, hasLength(2), reason: 'the journal slot holds both markers');
    await ed.close();
    final reopened = await repo.open(journalOnly);
    expect(reopened.project.markers, hasLength(2), reason: 'the promoted main document is valid on disk');
    await repo.close(journalOnly);
    qa10Report('corrupt main and .bak, journal restore', 'ok', 'open fails corrupt; banner Restore promoted the journal (2 markers)');
  }, skip: phase != 'verify');

  testWidgets('QA-10 verify 5: newer schema read-only, newer minReader blocked (D-12)', (tester) async {
    await E2eApp.launch(tester);
    final repo = Qa10Store.repo;
    final newer = idOf('newer');
    final blocked = idOf('blocked');

    expect((await Qa10Store.summaryOf(newer))?.health, ProjectHealth.readOnlyNewer);
    expect((await Qa10Store.summaryOf(blocked))?.health, ProjectHealth.needsNewerApp);

    final before = Qa10Store.fingerprint(Qa10Store.mainOf(newer));
    final ln = await repo.open(newer);
    expect(ln.readOnly, isTrue);
    final sess = EditSession(ln.project)..apply(const AddMarker(1000000, name: 'must not save'));
    await expectLater(repo.save(sess, reason: SaveReason.manual), throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.newerSchema)));
    await repo.close(newer);
    expect(Qa10Store.fingerprint(Qa10Store.mainOf(newer)), before, reason: 'a read-only project is never written');

    // The editor opens it read-only (an empty project: no preview to wait for).
    await E2eApp.openProjectsFromHome(tester);
    await E2eApp.screenshot(tester, 'qa10_projects_newer_blocked');
    await E2eApp.tapKey(tester, 'project-card-$newer');
    final ed = await E2eEditor.attach(tester, waitPreview: false);
    await E2eApp.waitKey(tester, 'read-only-banner');
    await E2eApp.pumpUntil(tester, () => ed.state.save.phase == SavePhase.readOnly, what: 'the read-only save state');
    await E2eApp.screenshot(tester, 'qa10_read_only_newer');
    await ed.close();
    expect(Qa10Store.fingerprint(Qa10Store.mainOf(newer)), before, reason: 'the editor did not write it either');

    final bBefore = Qa10Store.fingerprint(Qa10Store.mainOf(blocked));
    await expectLater(repo.open(blocked), throwsA(isA<StoreFailure>().having((f) => f.kind, 'kind', StoreFailureKind.newerSchema)));
    expect(Qa10Store.fingerprint(Qa10Store.mainOf(blocked)), bBefore);
    qa10Report('D-12', 'ok', 'schema ${currentProjectSchema + 1}/minReader $currentProjectMinReader opens read-only; minReader ${currentProjectMinReader + 1} is blocked; neither file written');
  }, skip: phase != 'verify');

  testWidgets('QA-10 verify 6: project delete and GC, then every original is unchanged (D-44)', (tester) async {
    await E2eApp.launch(tester);
    final repo = Qa10Store.repo;
    final ids = [for (final k in ['session', 'managed', 'bakOnly', 'journalOnly', 'newer', 'blocked']) idOf(k)];
    // Delete moves any bundle (corrupt or newer schema too) to trash/ and deletes it.
    for (final id in ids) {
      try {
        await repo.delete(id);
      } on StoreFailure catch (e) {
        qa10Report('delete ${id.value}', 'refused', e.kind.name);
      }
    }
    final left = [for (final id in ids) if (Directory(Qa10Store.roots.projectDir(id.value)).existsSync()) id.value];
    final gc = await E2eApp.world.runtime.collectGarbage();
    qa10Report('delete + GC', 'ran', 'bundles left: $left; $gc');
    for (final f in [Qa10Media.video, Qa10Media.still, Qa10Media.relinkTarget]) {
      expect(File(f).existsSync(), isTrue, reason: 'original $f survives delete and GC');
    }
    if (!hosted) {
      qa10Report('D-44 originals unchanged', 'not run', 'needs the host driver');
      return;
    }
    final report = await Qa10Host.compareOriginals(tester, allowedNew: [if (keptCopy != null) 'Exports/$keptCopy']);
    print('DV_QA10 originals report $report');
    expect(report['ok'], isTrue, reason: 'originals or their folders changed: $report');
    qa10Report('D-44 originals unchanged', 'ok', '${report['checked']} files compared (size, SHA-256, mtime, xattrs); no sidecars');
  }, skip: phase != 'verify');

  testWidgets('QA-10 needs the host driver', (tester) async {
    print('DV_QA10 skipped: run `integration_test/editor_store/tool/qa10_host.py -p ios -d <udid> run` (phases seed, edit, verify)');
  }, skip: phase == 'seed' || phase == 'edit' || phase == 'verify');
}

final Map<ProjectId, EditSession> _sessions = {};

/// Creates an empty project, adds one marker per save ([saves] manual saves), then [journaled]
/// more markers that only the autosave journal holds, and closes it (unless [keepOpen]).
Future<ProjectId> _project(FileProjectRepository repo, String name, {required int saves, int journaled = 0, bool keepOpen = false}) async {
  final id = await repo.create(EmptyProjectSpec(name: name));
  final loaded = await repo.open(id);
  final session = EditSession(loaded.project);
  var t = 0;
  for (var i = 0; i < saves; i++) {
    session.apply(AddMarker(t += 1000000, name: 'saved $i'));
    await repo.save(session, reason: SaveReason.manual);
  }
  for (var i = 0; i < journaled; i++) {
    session.apply(AddMarker(t += 1000000, name: 'journal $i'));
    repo.requestAutosave(session);
  }
  await repo.flush(id);
  if (journaled > 0) {
    final journal = Directory('${Qa10Store.roots.projectDir(id.value)}/journal');
    if (!journal.existsSync() || journal.listSync().whereType<File>().every((f) => !f.path.endsWith('.dnproj'))) {
      throw TestFailure('flush did not write the journal slot of $name');
    }
  }
  if (keepOpen) {
    _sessions[id] = session;
  } else {
    await repo.close(id);
  }
  return id;
}
