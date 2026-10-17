// OWNER: INT-02
//
// DefaultPlanCompiler (ARCH §11.7, §9.3, §9.5, §10.2): the asset resolver over the session pool,
// availability, proxies and looks, and the compile/transient/resolve/trim port.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/state/default_plan_compiler.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditSession;
import 'package:danaview_editor_core/plan.dart' show ResolvedLut;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/testing.dart';

final DateTime _when = DateTime.utc(2026, 10, 10);
const _roots = StoreRoots(support: '/fake/support', cache: '/fake/cache', documents: '/fake/documents');

MediaAsset _asset(String id, MediaKind kind, {ProxyState proxy = ProxyState.none, MediaLocator? locator}) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: id,
      locator: locator ?? AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/$id.mp4'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: 'qh_$id'),
      probe: MediaProbe(
        kind: kind,
        duration: kind == MediaKind.video ? 4000000 : 0,
        hasVideo: kind == MediaKind.video,
        hasAudio: false,
        width: kind == MediaKind.lut ? null : 1920,
        height: kind == MediaKind.lut ? null : 1080,
      ),
      origin: MediaOrigin.files,
      proxy: proxy,
      addedAt: _when,
    );

MediaClip _clip(String id, String media, {LookRef? look}) => MediaClip(
      id: ItemId(id),
      start: 0,
      duration: 1000000,
      media: MediaId(media),
      visual: look == null ? VisualProps.neutral : VisualProps.neutral.copyWith(look: look),
    );

EditProject _project(List<MediaAsset> assets, List<MediaClip> clips) => EditProject(
      id: const ProjectId('pr_compiler01'),
      meta: ProjectMeta(name: 'p', createdAt: _when, updatedAt: _when),
      timeline: Timeline(
        settings: const ProjectSettings(),
        tracks: [Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: clips)],
        revision: 1,
      ),
      pool: MediaPool({for (final a in assets) a.id: a}),
    );

Uint8List _vlut(int n) {
  final b = ByteData(8 + n * n * n * 6);
  b
    ..setUint8(0, 0x56)
    ..setUint8(1, 0x4C)
    ..setUint8(2, 0x55)
    ..setUint8(3, 0x54)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, n, Endian.little);
  return b.buffer.asUint8List();
}

class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);

  final Map<String, Uint8List> files;
  int loads = 0;

  @override
  Future<ByteData> load(String key) async {
    loads++;
    final f = files[key];
    if (f == null) throw StateError('missing $key');
    return ByteData.sublistView(f);
  }
}

void main() {
  late FakeMediaAccess access;
  late Set<String> existing;
  MediaAvailabilityReport? report;

  setUp(() {
    access = FakeEditorEngine().access;
    existing = {};
    report = null;
  });

  DefaultSessionPlanCompiler compilerFor(EditProject project, {int isolateThreshold = 300}) {
    final port = DefaultPlanCompiler(
      access: access,
      roots: _roots,
      availability: (_) => report,
      looks: (id) async => id == 'warm' ? const ResolvedLut(uri: 'file:///fake/cache/danaview/editor/looks/warm.vlut', size: 33) : null,
      readVlutSize: (path) async => path.endsWith('.vlut') ? 17 : null,
      exists: (path) async => existing.contains(path),
      isolateThreshold: isolateThreshold,
    );
    return port.forSession(EditSession(project), fakeDefaultCapabilities) as DefaultSessionPlanCompiler;
  }

  test('compiles with every pool asset resolved through the media access', () async {
    final project = _project([_asset('md_a', MediaKind.video)], [_clip('it_a', 'md_a')]);
    final c = compilerFor(project);
    expect(c.resolve(project, const MediaId('md_a')), isNull, reason: 'nothing resolved before the first compile');

    final plan = await c.compile(project);
    expect(plan.assets['md_a']?.uri, 'file:///fake/support/danaview/editor/media/md_a/md_a.mp4');
    expect(plan.req?.offline ?? const [], isEmpty);
    expect(c.resolve(project, const MediaId('md_a'))?.uri, plan.assets['md_a']?.uri);
    expect(c.compiles, 1);
  });

  test('a resolution is cached per locator and redone after a relink', () async {
    final a = _asset('md_a', MediaKind.video);
    final project = _project([a], [_clip('it_a', 'md_a')]);
    final c = compilerFor(project);
    await c.compile(project);
    await c.compile(project);
    expect(c.assets.resolveCalls, 1);

    final relinked = project.copyWith(
      pool: MediaPool({a.id: a.copyWith(locator: const FileLocator('/elsewhere/a.mp4'))}),
    );
    final plan = await c.compile(relinked);
    expect(c.assets.resolveCalls, 2);
    expect(plan.assets['md_a']?.uri, 'file:///elsewhere/a.mp4');
  });

  test('media the access cannot resolve is offline; retried only when availability changes', () async {
    final project = _project([_asset('md_a', MediaKind.video)], [_clip('it_a', 'md_a')]);
    access.missing.add('file:///fake/support/danaview/editor/media/md_a/md_a.mp4');
    final c = compilerFor(project);

    final plan = await c.compile(project);
    expect(plan.assets.containsKey('md_a'), isFalse);
    expect(plan.req?.offline, contains('md_a'));
    await c.compile(project);
    expect(c.assets.resolveCalls, 1, reason: 'no platform call per commit for a missing file');

    access.missing.clear();
    report = MediaAvailabilityReport({const MediaId('md_a'): MediaAvailability.available});
    final again = await c.compile(project);
    expect(c.assets.resolveCalls, 2);
    expect(again.assets.containsKey('md_a'), isTrue);
  });

  group('FIX-INT-02-2: a derived still re-resolves when its job finishes', () {
    const stillUri = 'file:///fake/support/danaview/editor/projects/pr_compiler01/assets/stills/md_still.png';

    MediaAsset pendingStill() => MediaAsset(
          id: const MediaId('md_still'),
          kind: MediaKind.still,
          displayName: 'Freeze frame',
          locator: const AppRelativeLocator(AppRoot.support, 'danaview/editor/projects/pr_compiler01/assets/stills/md_still.png'),
          ownership: MediaOwnership.projectOwned,
          fingerprint: const MediaFingerprint(sizeBytes: 0, quickHash: 'pending'),
          probe: MediaProbe(kind: MediaKind.still, hasVideo: true),
          origin: MediaOrigin.derived,
          derived: const StillSpec(MediaId('md_a'), 1000000, sourceQuickHash: 'qh_md_a'),
          status: const PendingStatus('job_freeze'),
          addedAt: _when,
        );

    EditProject withStill(MediaAsset still) => _project([_asset('md_a', MediaKind.video), still], [_clip('it_a', 'md_a'), _clip('it_still', 'md_still')]);

    test('pending (no PNG yet) -> ready with the job result: the still is in the next plan', () async {
      final pending = pendingStill();
      final project = withStill(pending);
      access.missing.add(stillUri);
      final c = compilerFor(project);

      final before = await c.compile(project);
      expect(before.assets.containsKey('md_still'), isFalse, reason: 'its file does not exist while the job runs');
      await c.compile(project);
      final calls = c.assets.resolveCalls;

      // TasksController._derivedDone: the PNG exists, status ready and a new fingerprint, same
      // locator and no new availability report.
      access.missing.remove(stillUri);
      final ready = pending.copyWith(
        status: AssetStatus.ready,
        fingerprint: MediaFingerprint(sizeBytes: 2048, quickHash: pending.derived!.specHash),
      );
      final after = await c.compile(project.copyWith(pool: MediaPool({...project.pool.assets, ready.id: ready})));
      expect(after.assets['md_still']?.uri, stillUri);
      expect(after.req?.offline ?? const [], isNot(contains('md_still')));
      expect(c.assets.resolveCalls, calls + 1, reason: 'only the still is resolved again');
      expect(c.resolve(project, const MediaId('md_still'))?.uri, stillUri);
    });

    test('a status change alone (same fingerprint) also re-resolves', () async {
      final pending = pendingStill();
      final project = withStill(pending);
      access.missing.add(stillUri);
      final c = compilerFor(project);
      await c.compile(project);

      access.missing.remove(stillUri);
      final ready = pending.copyWith(status: AssetStatus.ready);
      final after = await c.compile(project.copyWith(pool: MediaPool({...project.pool.assets, ready.id: ready})));
      expect(after.assets['md_still']?.uri, stillUri);
    });

    test('a ready still stays cached across commits', () async {
      final ready = pendingStill().copyWith(status: AssetStatus.ready);
      final project = withStill(ready);
      final c = compilerFor(project);
      await c.compile(project);
      final calls = c.assets.resolveCalls;
      await c.compile(project);
      await c.compile(project);
      expect(c.assets.resolveCalls, calls);
    });
  });

  test('missing, access-lost, changed and derived-missing media are offline in the plan', () async {
    for (final state in [
      MediaAvailability.missing,
      MediaAvailability.accessLost,
      MediaAvailability.changed,
      MediaAvailability.derivedMissing,
    ]) {
      final project = _project([_asset('md_a', MediaKind.video)], [_clip('it_a', 'md_a')]);
      report = MediaAvailabilityReport({const MediaId('md_a'): state});
      final plan = await compilerFor(project).compile(project);
      expect(plan.req?.offline, contains('md_a'), reason: state.name);
    }
  });

  test('a ready proxy is offered only when its file exists', () async {
    final project = _project([_asset('md_a', MediaKind.video, proxy: ProxyState.ready)], [_clip('it_a', 'md_a')]);
    final c = compilerFor(project);
    expect((await c.compile(project)).assets['md_a']?.proxyUri, isNull);

    final path = c.assets.proxyPathOf('qh_md_a');
    expect(path, '/fake/cache/danaview/editor/proxies/qh_md_a-540.mp4');
    existing.add(path);
    expect((await c.compile(project)).assets['md_a']?.proxyUri, 'file://$path');
  });

  test('a proxy that is not ready is never offered', () async {
    final project = _project([_asset('md_a', MediaKind.video, proxy: ProxyState.pending)], [_clip('it_a', 'md_a')]);
    final c = compilerFor(project);
    existing.add(c.assets.proxyPathOf('qh_md_a'));
    expect((await c.compile(project)).assets['md_a']?.proxyUri, isNull);
  });

  test('bundled looks and imported LUTs resolve to .vlut files', () async {
    final lut = _asset('md_lut', MediaKind.lut, locator: const AppRelativeLocator(AppRoot.support, 'danaview/editor/projects/p/assets/luts/l.cube'));
    final project = _project(
      [_asset('md_a', MediaKind.video), _asset('md_b', MediaKind.video), lut],
      [
        _clip('it_a', 'md_a', look: const BuiltinLook('warm')),
        _clip('it_b', 'md_b', look: const ImportedLut(MediaId('md_lut'))).copyWith(start: 1000000),
      ],
    );
    final plan = await compilerFor(project).compile(project);
    expect(plan.assets['lk_warm']?.uri, 'file:///fake/cache/danaview/editor/looks/warm.vlut');
    expect(plan.assets['lk_warm']?.n, 33);
    expect(plan.assets['md_lut']?.uri, 'file:///fake/support/danaview/editor/projects/p/assets/luts/l.vlut');
    expect(plan.assets['md_lut']?.n, 17);
    expect(SessionAssetResolver.builtinLooksOf(project), {'warm'});
  });

  test('a large project compiles cold in an isolate with the sendable snapshot', () async {
    final project = _project([_asset('md_a', MediaKind.video)], [_clip('it_a', 'md_a')]);
    final c = compilerFor(project, isolateThreshold: 0);
    final plan = await c.compile(project);
    expect(plan.assets['md_a'], isNotNull);
  });

  test('transients use the latest snapshot; trim keeps resolutions', () async {
    final project = _project([_asset('md_a', MediaKind.video)], [_clip('it_a', 'md_a')]);
    final c = compilerFor(project);
    await c.compile(project);
    expect(c.transientFor(project, const ItemId('it_a')), isNotNull);
    c.trim();
    expect(c.resolve(project, const MediaId('md_a')), isNotNull);
    await c.compile(project);
    expect(c.assets.resolveCalls, 1);
  });

  test('concurrent refreshes share one run and end on the latest project', () async {
    final a = _asset('md_a', MediaKind.video);
    final b = _asset('md_b', MediaKind.video);
    final p1 = _project([a], [_clip('it_a', 'md_a')]);
    final p2 = _project([a, b], [_clip('it_a', 'md_a')]);
    final c = compilerFor(p1);
    final r1 = c.assets.refresh(p1);
    final r2 = c.assets.refresh(p2);
    expect(identical(await r1, await r2), isTrue);
    expect(c.assets.current.original(const MediaId('md_b')), isNotNull);
  });

  group('.vlut header', () {
    test('reads N and rejects bad headers', () {
      expect(vlutTableSizeOf(_vlut(33)), 33);
      expect(vlutTableSizeOf(Uint8List(4)), isNull);
      final bad = _vlut(33)..[0] = 0;
      expect(vlutTableSizeOf(bad), isNull);
      final big = _vlut(2);
      ByteData.sublistView(big).setUint16(6, 66, Endian.little);
      expect(vlutTableSizeOf(big), isNull);
    });

    test('readVlutTableSize returns null for a missing file', () async {
      expect(await readVlutTableSize('/definitely/not/here.vlut'), isNull);
    });
  });

  group('BundledLookFiles', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('looks'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('extracts a bundled look once into the cache looks folder', () async {
      final roots = StoreRoots(support: '${tmp.path}/s', cache: '${tmp.path}/c', documents: '${tmp.path}/d');
      final bundle = _Bundle({BundledLookFiles.assetKeyOf('warm'): _vlut(5)});
      final looks = BundledLookFiles(roots: roots, bundle: bundle);

      final lut = await looks.resolve('warm');
      expect(lut?.size, 5);
      expect(lut?.uri, Uri.file('${tmp.path}/c/danaview/editor/looks/warm.vlut').toString());
      expect(File('${tmp.path}/c/danaview/editor/looks/warm.vlut').existsSync(), isTrue);

      expect((await looks.resolve('warm'))?.size, 5);
      expect(bundle.loads, 1, reason: 'the extracted file is reused');
      expect(await looks.resolve('unknown'), isNull);
      expect(await looks.resolve('../escape'), isNull);
    });
  });
}
