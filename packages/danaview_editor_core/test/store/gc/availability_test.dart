// OWNER: CORE-28
//
// Every availability state with a fake platform port (ARCH §9.3), and the monitor: a report on
// open (first listen), on resume and after a relink.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/store.dart';

import '../../ops/framework/ops_support.dart' show lane, project;
import '../media/support/media_fixtures.dart';

void main() {
  late MediaWorld w;
  late MediaAvailabilityChecker checker;
  setUp(() {
    w = MediaWorld();
    checker = MediaAvailabilityChecker(w.port);
  });
  tearDown(() => w.dispose());

  MediaAsset fileAsset(String id, String path, List<int> bytes, {MediaKind kind = MediaKind.video, bool withMtime = true}) {
    final s = File(path).statSync();
    return MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: p.basename(path),
      locator: FileLocator(path),
      ownership: MediaOwnership.external,
      fingerprint: MediaFingerprint(
        sizeBytes: bytes.length,
        quickHash: hashOfBytes(bytes),
        modifiedMs: withMtime ? s.modified.millisecondsSinceEpoch : null,
        duration: 2000000,
      ),
      probe: MediaProbe(kind: kind, duration: 2000000, hasVideo: true, width: 1920, height: 1080),
      origin: MediaOrigin.files,
      addedAt: when,
    );
  }

  test('available: size and mtime equal (no hashing) or hash equal', () async {
    final bytes = bytesOf(1, 5000);
    final f = w.externalFile('a.mp4', bytes);
    expect(await checker.check(fileAsset('md_a', f, bytes)), MediaAvailability.available);
    expect(await checker.check(fileAsset('md_b', f, bytes, withMtime: false)), MediaAvailability.available);
  });

  test('missing: the file is gone, or a repair placeholder', () async {
    final bytes = bytesOf(2, 100);
    final f = w.externalFile('gone.mp4', bytes);
    final a = fileAsset('md_g', f, bytes);
    File(f).deleteSync();
    expect(await checker.check(a), MediaAvailability.missing);
    final placeholder = a.copyWith(status: const FailedStatus(missingPlaceholderReason));
    expect(await checker.check(placeholder), MediaAvailability.missing);
    final managed = a.copyWith(locator: const AppRelativeLocator(AppRoot.support, 'danaview/editor/media/ab/abcd/x.mp4'));
    expect(await checker.check(managed), MediaAvailability.missing);
  });

  test('accessLost: revoked grant or unresolvable bookmark', () async {
    final bytes = bytesOf(3, 100);
    final f = w.externalFile('x.mp4', bytes);
    final a = fileAsset('md_x', f, bytes);
    expect(await checker.check(a.copyWith(locator: const ContentUriLocator('content://revoked/1'))), MediaAvailability.accessLost);
    expect(await checker.check(a.copyWith(locator: const BookmarkLocator('c3RhbGU='))), MediaAvailability.accessLost);
    final uri = w.contentUri('ok.mp4', bytes);
    final ok = fileAsset('md_ok', w.port.contentFiles[uri]!, bytes).copyWith(locator: ContentUriLocator(uri));
    expect(await checker.check(ok), MediaAvailability.available);
  });

  test('changed: same path, different size or content', () async {
    final bytes = bytesOf(4, 4000);
    final f = w.externalFile('c.mp4', bytes);
    final a = fileAsset('md_c', f, bytes);
    File(f).writeAsBytesSync(bytesOf(5, 4001));
    expect(await checker.check(a), MediaAvailability.changed);
    File(f)
      ..writeAsBytesSync(bytesOf(6, 4000)) // same size, other bytes
      ..setLastModifiedSync(DateTime(2020)); // a different mtime sends the check to the hash
    expect(await checker.check(a), MediaAvailability.changed);
  });

  test('derivedMissing: reversed rendition, pending job, LUT companion', () async {
    final bytes = bytesOf(7, 100);
    final f = w.externalFile('src.mp4', bytes);
    final src = fileAsset('md_src', f, bytes);
    final rev = src.copyWith(
      id: const MediaId('md_rev'),
      locator: const AppRelativeLocator(AppRoot.support, 'danaview/editor/derived/abc.mp4'),
      ownership: MediaOwnership.projectOwned,
      derived: const ReversedSpec(MediaId('md_src'), TimeRange(0, 1000000), sourceQuickHash: 'q'),
    );
    expect(await checker.check(rev), MediaAvailability.derivedMissing);
    w.c.put(w.roots.resolve(rev.locator as AppRelativeLocator), [1, 2, 3]);
    expect(await checker.check(rev), MediaAvailability.available);
    expect(await checker.check(rev.copyWith(status: const PendingStatus('job1'))), MediaAvailability.derivedMissing);

    const cubeRel = 'danaview/editor/projects/pr_media00001/assets/luts/md_l.cube';
    w.c.put(w.roots.resolve(const AppRelativeLocator(AppRoot.support, cubeRel)), [1]);
    final lut = MediaAsset(
      id: const MediaId('md_l'),
      kind: MediaKind.lut,
      displayName: 'look.cube',
      locator: const AppRelativeLocator(AppRoot.support, cubeRel),
      ownership: MediaOwnership.projectOwned,
      fingerprint: const MediaFingerprint(sizeBytes: 1, quickHash: ''),
      probe: MediaProbe(kind: MediaKind.lut),
      origin: MediaOrigin.imported,
      addedAt: when,
    );
    expect(await checker.check(lut), MediaAvailability.derivedMissing, reason: '.vlut missing');
    w.c.put(w.roots.resolve(ManagedStore.vlutOf(lut.locator as AppRelativeLocator)), [1]);
    expect(await checker.check(lut), MediaAvailability.available);
  });

  test('report and counts', () async {
    final bytes = bytesOf(8, 100);
    final f = w.externalFile('ok.mp4', bytes);
    final ok = fileAsset('md_ok', f, bytes);
    final gone = ok.copyWith(id: const MediaId('md_gone'), locator: FileLocator(p.join(w.external, 'nope.mp4')));
    final lost = ok.copyWith(id: const MediaId('md_lost'), locator: const ContentUriLocator('content://x'));
    final report = await checker.checkPool(MediaPool({ok.id: ok, gone.id: gone, lost.id: lost}));
    expect(report.blocking.toSet(), {const MediaId('md_gone'), const MediaId('md_lost')});
    final counts = AvailabilityCounts.of(report);
    expect((counts.missing, counts.accessLost, counts.blocking), (1, 1, 2));
  });

  test('monitor: report on listen, on resume and after relink', () async {
    final bytes = bytesOf(9, 2000);
    final f = w.externalFile('m.mp4', bytes);
    final a = fileAsset('md_m', f, bytes);
    final session = EditSession(project(
      [lane('tr_main', TrackKind.video, const [], main: true)],
      pool: MediaPool({a.id: a}),
      id: 'pr_media00001',
    ));
    final service = MediaRelinkService(access: w.port, probe: fakeProbe, roots: w.roots, fs: w.fs, platform: ImportPlatform.desktop);
    final reports = <MediaAvailabilityReport>[];
    final sub = service.watchAvailability(session).listen(reports.add);
    await settleIo();
    expect(reports.single.byMedia[a.id], MediaAvailability.available);
    File(f).deleteSync();
    await service.resumed();
    await settleIo();
    expect(reports.last.byMedia[a.id], MediaAvailability.missing);
    final again = w.externalFile('m2.mp4', bytes);
    final out = await service.relink(session, {a.id: PickedMedia(uri: again, displayName: 'm2.mp4')});
    expect(out.rejection, isNull);
    await settleIo();
    expect(reports.last.byMedia[a.id], MediaAvailability.available);
    await sub.cancel();
  });

  test('FIX-CORE-28-1: a relink on a scratch copy re-checks the open session\'s monitor', () async {
    final bytes = bytesOf(10, 2000);
    final f = w.externalFile('o.mp4', bytes);
    final a = fileAsset('md_o', f, bytes);
    final open = EditSession(project(
      [lane('tr_main', TrackKind.video, const [], main: true)],
      pool: MediaPool({a.id: a}),
      id: 'pr_media00001',
    ));
    final service = MediaRelinkService(access: w.port, probe: fakeProbe, roots: w.roots, fs: w.fs, platform: ImportPlatform.desktop);
    final reports = <MediaAvailabilityReport>[];
    final sub = service.watchAvailability(open).listen(reports.add);
    await settleIo();
    File(f).deleteSync();
    await service.resumed();
    await settleIo();
    expect(reports.last.byMedia[a.id], MediaAvailability.missing);
    final count = reports.length;

    // UX-40: relink on a scratch copy, then replay the result on the open session right away.
    final scratch = EditSession(open.committedProject, editPolicy: open.editPolicy);
    final again = w.externalFile('o2.mp4', bytes);
    final out = await service.relink(scratch, {a.id: PickedMedia(uri: again, displayName: 'o2.mp4')});
    expect(out.rejection, isNull);
    open.applyPoolEdit(RelinkAssets({a.id: scratch.committedProject.pool[a.id]!}));
    await settleIo();

    // The open session's watcher gets a fresh report without subscribing again, and the monitor
    // the plan compiler reads (`last`) says the file is back.
    expect(reports.length, greaterThan(count));
    expect(reports.last.byMedia[a.id], MediaAvailability.available);
    expect(service.monitorOf(open).last!.byMedia[a.id], MediaAvailability.available);
    await sub.cancel();
  });
}

/// Lets async file I/O finish.
Future<void> settleIo() => Future<void>.delayed(const Duration(milliseconds: 50));

/// quickHash of [bytes].
String hashOfBytes(List<int> bytes) {
  final b = u8(bytes);
  final head = b.sublist(0, b.length < quickHashChunkBytes ? b.length : quickHashChunkBytes);
  final tail = b.sublist(b.length > quickHashChunkBytes ? b.length - quickHashChunkBytes : 0);
  return computeQuickHash(u8(head), u8(tail), b.length);
}
