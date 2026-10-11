// OWNER: CORE-04
//
// Value semantics (==, hashCode, copyWith) of every pool type, exhaustive switches over the sealed
// hierarchies, DerivedSpec.specHash stability and the MediaAccessPort contract surface.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';

MediaProbe _probe({MediaKind kind = MediaKind.video, List<String> issues = const []}) => MediaProbe(
      kind: kind,
      duration: 5000000,
      hasVideo: true,
      hasAudio: true,
      width: 1920,
      height: 1080,
      nominalFrameRate: FrameRate.fps30,
      nominalFps: 29.97,
      container: 'mp4',
      videoCodec: 'h264',
      audioCodec: 'aac',
      audioStreams: 1,
      channels: 2,
      sampleRate: 48000,
      bitDepth: 8,
      sizeBytes: 1234567,
      issues: issues,
    );

MediaAsset _asset({String id = 'md_aaaaaaaaaaaa', MediaLocator? locator, AssetStatus status = AssetStatus.ready}) =>
    MediaAsset(
      id: MediaId(id),
      kind: MediaKind.video,
      displayName: 'clip.mp4',
      locator: locator ?? const AppRelativeLocator(AppRoot.documents, 'clips/clip.mp4'),
      ownership: MediaOwnership.external,
      fingerprint: const MediaFingerprint(sizeBytes: 1234567, quickHash: 'abc', modifiedMs: 99, duration: 5000000),
      probe: _probe(),
      origin: MediaOrigin.files,
      status: status,
      addedAt: DateTime.utc(2026, 10, 8),
    );

// Exhaustive switches: these fail to compile if a variant is added without updating the tests.
String _locatorName(MediaLocator l) => switch (l) {
      AppRelativeLocator() => 'app',
      FileLocator() => 'file',
      ContentUriLocator() => 'content',
      BookmarkLocator() => 'bookmark',
    };
String _derivedName(DerivedSpec d) => switch (d) {
      ReversedSpec() => 'reversed',
      StillSpec() => 'still',
    };
String _statusName(AssetStatus s) => switch (s) {
      ReadyStatus() => 'ready',
      PendingStatus() => 'pending',
      FailedStatus() => 'failed',
    };
String _changeName(PoolChange c) => switch (c) {
      AddAssets() => 'add',
      UpdateAsset() => 'update',
    };
String _editName(PoolEdit e) => switch (e) {
      RelinkAssets() => 'relink',
      RemoveAssets() => 'remove',
    };

void main() {
  group('sealed hierarchies are exhaustive', () {
    test('MediaLocator', () {
      expect(
        [
          const AppRelativeLocator(AppRoot.support, 'a'),
          const FileLocator('/x'),
          const ContentUriLocator('content://x'),
          const BookmarkLocator('Ym9vaw=='),
        ].map(_locatorName),
        ['app', 'file', 'content', 'bookmark'],
      );
    });
    test('DerivedSpec', () {
      expect(
        [
          ReversedSpec(const MediaId('md_a'), const TimeRange(0, 10), sourceQuickHash: 'h'),
          StillSpec(const MediaId('md_a'), 5, sourceQuickHash: 'h'),
        ].map(_derivedName),
        ['reversed', 'still'],
      );
    });
    test('AssetStatus', () {
      expect([AssetStatus.ready, const PendingStatus('j1'), const FailedStatus('decode')].map(_statusName),
          ['ready', 'pending', 'failed']);
    });
    test('PoolChange / PoolEdit', () {
      expect([AddAssets([_asset()]), UpdateAsset(_asset())].map(_changeName), ['add', 'update']);
      expect([RelinkAssets({}), RemoveAssets({})].map(_editName), ['relink', 'remove']);
    });
  });

  group('MediaLocator', () {
    test('equality, hashCode and copyWith per variant', () {
      const app = AppRelativeLocator(AppRoot.documents, 'a/b.mp4');
      expect(app, const AppRelativeLocator(AppRoot.documents, 'a/b.mp4'));
      expect(app.hashCode, const AppRelativeLocator(AppRoot.documents, 'a/b.mp4').hashCode);
      expect(app, isNot(const AppRelativeLocator(AppRoot.cache, 'a/b.mp4')));
      expect(app.copyWith(root: AppRoot.support), const AppRelativeLocator(AppRoot.support, 'a/b.mp4'));
      expect(app.copyWith(relPath: 'c'), const AppRelativeLocator(AppRoot.documents, 'c'));

      const file = FileLocator('/a/b');
      expect(file, const FileLocator('/a/b'));
      expect(file.hashCode, const FileLocator('/a/b').hashCode);
      expect(file.copyWith(path: '/c'), const FileLocator('/c'));
      expect(file, isNot(const FileLocator('/a/c')));

      const uri = ContentUriLocator('content://media/1');
      expect(uri, const ContentUriLocator('content://media/1'));
      expect(uri.copyWith(uri: 'content://media/2'), const ContentUriLocator('content://media/2'));
      expect(uri, isNot(const ContentUriLocator('content://media/2')));

      const bm = BookmarkLocator('AAAA', lastKnownPath: '/p');
      expect(bm, const BookmarkLocator('AAAA', lastKnownPath: '/p'));
      expect(bm.hashCode, const BookmarkLocator('AAAA', lastKnownPath: '/p').hashCode);
      expect(bm, isNot(const BookmarkLocator('AAAA')));
      expect(bm.copyWith(bookmarkB64: 'BBBB'), const BookmarkLocator('BBBB', lastKnownPath: '/p'));
      expect(bm.copyWith(lastKnownPath: ''), const BookmarkLocator('AAAA'));
    });

    test('variants never compare equal to each other', () {
      expect(const FileLocator('x'), isNot(const ContentUriLocator('x')));
    });
  });

  group('MediaFingerprint / MediaStat / MediaAccessFailure', () {
    test('MediaFingerprint', () {
      const f = MediaFingerprint(sizeBytes: 10, quickHash: 'h', modifiedMs: 5, duration: 7);
      expect(f, const MediaFingerprint(sizeBytes: 10, quickHash: 'h', modifiedMs: 5, duration: 7));
      expect(f.hashCode, const MediaFingerprint(sizeBytes: 10, quickHash: 'h', modifiedMs: 5, duration: 7).hashCode);
      expect(f, isNot(const MediaFingerprint(sizeBytes: 11, quickHash: 'h', modifiedMs: 5, duration: 7)));
      expect(f.copyWith(quickHash: 'x').quickHash, 'x');
      expect(f.copyWith(modifiedMs: null).modifiedMs, isNull);
      expect(f.copyWith().modifiedMs, 5);
      expect(f.copyWith(duration: 1).duration, 1);
      expect(f.copyWith(sizeBytes: 3).sizeBytes, 3);
    });

    test('MediaStat', () {
      const s = MediaStat(sizeBytes: 3, modifiedMs: 4);
      expect(s, const MediaStat(sizeBytes: 3, modifiedMs: 4));
      expect(s.hashCode, const MediaStat(sizeBytes: 3, modifiedMs: 4).hashCode);
      expect(s.copyWith(modifiedMs: null), const MediaStat(sizeBytes: 3));
      expect(s.copyWith(sizeBytes: 9).sizeBytes, 9);
    });

    test('MediaAccessFailure', () {
      const a = MediaAccessFailure(MediaAccessFailureKind.accessLost, 'bookmark stale');
      expect(a, const MediaAccessFailure(MediaAccessFailureKind.accessLost, 'bookmark stale'));
      expect(a.hashCode, const MediaAccessFailure(MediaAccessFailureKind.accessLost, 'bookmark stale').hashCode);
      expect(a.copyWith(kind: MediaAccessFailureKind.notFound).kind, MediaAccessFailureKind.notFound);
      expect(a.toString(), contains('accessLost'));
      expect(const MediaAccessFailure(MediaAccessFailureKind.io).toString(), 'MediaAccessFailure(MediaAccessFailureKind.io)');
      expect(() => throw a, throwsA(isA<MediaAccessFailure>()));
    });
  });

  group('MediaProbe', () {
    test('equality, hashCode, unmodifiable issues', () {
      final a = _probe(issues: ['x']);
      final b = _probe(issues: ['x']);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(_probe(issues: ['y'])));
      expect(() => a.issues.add('z'), throwsUnsupportedError);
    });

    test('copyWith replaces and clears', () {
      final p = _probe();
      expect(p.copyWith(duration: 1).duration, 1);
      expect(p.copyWith(width: null).width, isNull);
      expect(p.copyWith().width, 1920);
      expect(p.copyWith(nominalFrameRate: null).nominalFrameRate, isNull);
      expect(p.copyWith(transfer: ColorTransfer.hlg).transfer, ColorTransfer.hlg);
      expect(p.copyWith(issues: ['protected']).issues, ['protected']);
      expect(p.copyWith(editable: false).editable, isFalse);
      expect(p.copyWith(kind: MediaKind.audio).kind, MediaKind.audio);
      expect(p.copyWith(container: null, videoCodec: null, audioCodec: null).container, isNull);
      expect(p.copyWith(rotation: 90).rotation, 90);
      expect(p.copyWith(variableFrameRate: true).variableFrameRate, isTrue);
      expect(p.copyWith(), p);
    });

    test('MediaKind and ColorTransfer cover the ARCH §6.8 sets', () {
      expect(MediaKind.values.map((k) => k.name), ['video', 'audio', 'image', 'lut', 'still', 'recording']);
      expect(ColorTransfer.values.map((k) => k.name), ['sdr', 'hlg', 'pq']);
    });
  });

  group('DerivedSpec', () {
    final r = ReversedSpec(const MediaId('md_a'), const TimeRange(1000, 5000), sourceQuickHash: 'qh');
    final s = StillSpec(const MediaId('md_a'), 2500, sourceQuickHash: 'qh');

    test('equality, hashCode, copyWith', () {
      expect(r, ReversedSpec(const MediaId('md_a'), const TimeRange(1000, 5000), sourceQuickHash: 'qh'));
      expect(r.hashCode, ReversedSpec(const MediaId('md_a'), const TimeRange(1000, 5000), sourceQuickHash: 'qh').hashCode);
      expect(r, isNot(r.copyWith(range: const TimeRange(1000, 5001))));
      expect(r.copyWith(media: const MediaId('md_b')).media, 'md_b');
      expect(r.copyWith(sourceQuickHash: 'z').sourceQuickHash, 'z');
      expect(s, StillSpec(const MediaId('md_a'), 2500, sourceQuickHash: 'qh'));
      expect(s.hashCode, StillSpec(const MediaId('md_a'), 2500, sourceQuickHash: 'qh').hashCode);
      expect(s.copyWith(sourceTime: 1).sourceTime, 1);
      expect(s.copyWith(media: const MediaId('md_c')).media, 'md_c');
      expect(s.copyWith(sourceQuickHash: 'q2').sourceQuickHash, 'q2');
      expect(r, isNot(s));
    });

    test('specHash is stable, content-keyed and independent of the media id', () {
      // Golden values: the hash names `derived/<specHash>.mp4` on disk, so it must never change.
      expect(r.specHash, 'ed6da02b6da379e99969dc32762d3fa0a26041a0');
      expect(s.specHash, '8a101f8a3b676b728b30af8011eb221f6b0e9df7');
      expect(r.specHash, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(r.specHash, ReversedSpec(const MediaId('md_other'), const TimeRange(1000, 5000), sourceQuickHash: 'qh').specHash,
          reason: 'survives relink to the same content');
      expect(r.specHash, isNot(r.copyWith(range: const TimeRange(1000, 5001)).specHash));
      expect(r.specHash, isNot(r.copyWith(sourceQuickHash: 'other').specHash));
      expect(s.specHash, isNot(s.copyWith(sourceTime: 2501).specHash));
      expect(s.specHash, isNot(r.specHash));
    });
  });

  group('AssetStatus / ProxyState', () {
    test('equality and copyWith', () {
      expect(AssetStatus.ready, const ReadyStatus());
      expect(AssetStatus.ready.hashCode, const ReadyStatus().hashCode);
      expect(const PendingStatus('a'), const PendingStatus('a'));
      expect(const PendingStatus('a').hashCode, const PendingStatus('a').hashCode);
      expect(const PendingStatus('a'), isNot(const PendingStatus('b')));
      expect(const PendingStatus('a').copyWith(jobId: 'b'), const PendingStatus('b'));
      expect(const FailedStatus('x'), const FailedStatus('x'));
      expect(const FailedStatus('x').hashCode, const FailedStatus('x').hashCode);
      expect(const FailedStatus('x').copyWith(reason: 'y'), const FailedStatus('y'));
      expect(AssetStatus.ready, isNot(const PendingStatus('a')));
      expect(ProxyState.values.map((e) => e.name), ['none', 'pending', 'ready', 'failed']);
      expect(MediaOwnership.values.map((e) => e.name), ['external', 'managedCopy', 'projectOwned']);
    });
  });

  group('MediaAsset', () {
    test('equality, hashCode and copyWith over every field', () {
      final a = _asset();
      expect(a, _asset());
      expect(a.hashCode, _asset().hashCode);
      expect(a.copyWith(), a);
      expect(a.copyWith(displayName: 'b').displayName, 'b');
      expect(a.copyWith(id: const MediaId('md_zzzzzzzzzzzz')).id, 'md_zzzzzzzzzzzz');
      expect(a.copyWith(kind: MediaKind.audio).kind, MediaKind.audio);
      expect(a.copyWith(locator: const FileLocator('/q')).locator, const FileLocator('/q'));
      expect(a.copyWith(ownership: MediaOwnership.managedCopy).ownership, MediaOwnership.managedCopy);
      expect(a.copyWith(fingerprint: const MediaFingerprint(sizeBytes: 1, quickHash: 'z')).fingerprint.quickHash, 'z');
      expect(a.copyWith(probe: _probe(kind: MediaKind.audio)).probe.kind, MediaKind.audio);
      expect(a.copyWith(origin: MediaOrigin.player).origin, MediaOrigin.player);
      expect(a.copyWith(status: const PendingStatus('j')).status, const PendingStatus('j'));
      expect(a.copyWith(proxy: ProxyState.ready).proxy, ProxyState.ready);
      expect(a.copyWith(addedAt: DateTime.utc(2027)).addedAt, DateTime.utc(2027));
      final d = StillSpec(const MediaId('md_s'), 1, sourceQuickHash: 'h');
      final withDerived = a.copyWith(derived: d);
      expect(withDerived.derived, d);
      expect(withDerived.copyWith().derived, d, reason: 'omitted keeps');
      expect(withDerived.copyWith(derived: null).derived, isNull, reason: 'explicit null clears');
      expect(a, isNot(a.copyWith(proxy: ProxyState.pending)));
    });
  });

  group('MediaPool', () {
    final a = _asset(id: 'md_a00000000001');
    final b = _asset(id: 'md_b00000000002');

    test('is immutable, ordered and value-equal', () {
      final src = {a.id: a, b.id: b};
      final pool = MediaPool(src);
      src.clear();
      expect(pool.length, 2, reason: 'the map is copied');
      expect(pool.assets.keys, [a.id, b.id], reason: 'insertion order is kept');
      expect(() => pool.assets[a.id] = b, throwsUnsupportedError);
      expect(pool, MediaPool({a.id: a, b.id: b}));
      expect(pool.hashCode, MediaPool({a.id: a, b.id: b}).hashCode);
      expect(pool, isNot(MediaPool({a.id: a})));
      expect(MediaPool.empty.isEmpty, isTrue);
      expect(pool.isEmpty, isFalse);
    });

    test('lookup, upsert, without, copyWith', () {
      final pool = MediaPool({a.id: a});
      expect(pool[a.id], a);
      expect(pool[b.id], isNull);
      expect(pool.contains(a.id), isTrue);
      final two = pool.upsert(b);
      expect(two.assets.keys, [a.id, b.id]);
      expect(pool.length, 1, reason: 'upsert does not mutate');
      final replaced = two.upsert(a.copyWith(displayName: 'renamed'));
      expect(replaced[a.id]!.displayName, 'renamed');
      expect(replaced.assets.keys, [a.id, b.id], reason: 'replace keeps position');
      expect(two.without({a.id}).assets.keys, [b.id]);
      expect(two.without({}), two);
      expect(two.copyWith(), two);
      expect(two.copyWith(assets: {a.id: a}), pool);
    });
  });

  group('PoolChange / PoolEdit / PoolDelta', () {
    final a = _asset(id: 'md_a00000000001');
    final b = _asset(id: 'md_b00000000002');

    test('AddAssets and UpdateAsset', () {
      expect(AddAssets([a, b]), AddAssets([a, b]));
      expect(AddAssets([a, b]).hashCode, AddAssets([a, b]).hashCode);
      expect(AddAssets([a]), isNot(AddAssets([b])));
      expect(AddAssets([a]).copyWith(assets: [b]).assets, [b]);
      expect(() => AddAssets([a]).assets.add(b), throwsUnsupportedError);
      expect(UpdateAsset(a), UpdateAsset(a));
      expect(UpdateAsset(a).hashCode, UpdateAsset(a).hashCode);
      expect(UpdateAsset(a).copyWith(asset: b).asset, b);
      expect(UpdateAsset(a), isNot(UpdateAsset(b)));
    });

    test('RelinkAssets and RemoveAssets have history labels', () {
      expect(RelinkAssets({a.id: a}).label, 'Relink media');
      expect(RemoveAssets({a.id}).label, 'Remove from project');
      expect(RelinkAssets({a.id: a}), RelinkAssets({a.id: a}));
      expect(RelinkAssets({a.id: a}).hashCode, RelinkAssets({a.id: a}).hashCode);
      expect(RelinkAssets({a.id: a}), isNot(RelinkAssets({a.id: b})));
      expect(RelinkAssets({a.id: a}).copyWith(replacements: {b.id: b}).replacements.keys, [b.id]);
      expect(RemoveAssets({a.id, b.id}), RemoveAssets({b.id, a.id}));
      expect(RemoveAssets({a.id}).hashCode, RemoveAssets({a.id}).hashCode);
      expect(RemoveAssets({a.id}).copyWith(ids: {b.id}).ids, {b.id});
      expect(() => RemoveAssets({a.id}).ids.add(b.id), throwsUnsupportedError);
    });

    test('PoolDelta records before/after (null = absent)', () {
      final d = PoolDelta(before: {a.id: a, b.id: null}, after: {a.id: null, b.id: b});
      expect(d, PoolDelta(before: {a.id: a, b.id: null}, after: {a.id: null, b.id: b}));
      expect(d.hashCode, PoolDelta(before: {a.id: a, b.id: null}, after: {a.id: null, b.id: b}).hashCode);
      expect(d, isNot(PoolDelta(before: {a.id: a}, after: {})));
      expect(d.copyWith(after: {}).after, isEmpty);
      expect(d.copyWith(before: {}).before, isEmpty);
      expect(() => d.before[a.id] = null, throwsUnsupportedError);
    });
  });

  group('PickedMedia / ResolvedMedia', () {
    test('PickedMedia', () {
      final p = PickedMedia(
        uri: 'file:///x.mp4',
        displayName: 'x.mp4',
        origin: MediaOrigin.photos,
        isTemporaryCopy: true,
        bookmark: Uint8List.fromList([1, 2]),
        sizeBytes: 10,
      );
      expect(
          p,
          PickedMedia(
            uri: 'file:///x.mp4',
            displayName: 'x.mp4',
            origin: MediaOrigin.photos,
            isTemporaryCopy: true,
            bookmark: Uint8List.fromList([1, 2]),
            sizeBytes: 10,
          ));
      expect(p.hashCode, p.copyWith().hashCode);
      expect(p, isNot(p.copyWith(bookmark: Uint8List.fromList([1, 3]))), reason: 'bookmark bytes participate');
      expect(p.copyWith(bookmark: null).bookmark, isNull);
      expect(p.copyWith(sizeBytes: null).sizeBytes, isNull);
      expect(p.copyWith(uri: 'u').uri, 'u');
      expect(p.copyWith(displayName: 'n').displayName, 'n');
      expect(p.copyWith(origin: MediaOrigin.drop).origin, MediaOrigin.drop);
      expect(p.copyWith(isTemporaryCopy: false).isTemporaryCopy, isFalse);
      const defaults = PickedMedia(uri: 'u', displayName: 'n');
      expect(defaults.origin, MediaOrigin.files);
      expect(defaults.isTemporaryCopy, isFalse);
      expect(MediaOrigin.values.map((e) => e.name),
          ['photos', 'files', 'library', 'player', 'drop', 'recorded', 'derived', 'imported']);
    });

    test('PickedMediaHandle is the picked item', () {
      const PickedMediaHandle h = PickedMedia(uri: 'u', displayName: 'n');
      expect(h.uri, 'u');
    });

    test('ResolvedMedia', () {
      final r = ResolvedMedia(uri: 'file:///x', fingerprint: 'fp', bookmark: Uint8List.fromList([9]), isProxy: true);
      expect(r, ResolvedMedia(uri: 'file:///x', fingerprint: 'fp', bookmark: Uint8List.fromList([9]), isProxy: true));
      expect(r.hashCode, r.copyWith().hashCode);
      expect(r, isNot(r.copyWith(bookmark: null)));
      expect(r.copyWith(bookmark: null).bookmark, isNull);
      expect(r.copyWith(uri: 'u').uri, 'u');
      expect(r.copyWith(fingerprint: 'f').fingerprint, 'f');
      expect(r.copyWith(isProxy: false).isProxy, isFalse);
      expect(const ResolvedMedia(uri: 'u', fingerprint: 'f').isProxy, isFalse);
    });
  });

  group('MediaAccessPort', () {
    test('a fake implements the whole surface without dart:io', () async {
      final port = _FakePort();
      final locator = await port.persist(const PickedMedia(uri: 'file:///x.mp4', displayName: 'x.mp4'));
      expect(locator, const FileLocator('file:///x.mp4'));
      final resolved = await port.resolve(locator);
      expect(resolved.uri, 'file:///x.mp4');
      expect(await port.stat(locator), const MediaStat(sizeBytes: 1));
      expect(await port.quickHash(locator), 'h');
      await port.release(locator);
      await port.excludeFromBackup('/tmp/x');
      expect(await port.remainingGrantBudget(), 100);
      expect(() => port.stat(const FileLocator('lost')), throwsA(isA<MediaAccessFailure>()));
    });
  });
}

final class _FakePort implements MediaAccessPort {
  @override
  Future<ResolvedMedia> resolve(MediaLocator locator) async =>
      ResolvedMedia(uri: (locator as FileLocator).path, fingerprint: 'h');

  @override
  Future<MediaStat?> stat(MediaLocator locator) async {
    if ((locator as FileLocator).path == 'lost') {
      throw const MediaAccessFailure(MediaAccessFailureKind.accessLost);
    }
    return const MediaStat(sizeBytes: 1);
  }

  @override
  Future<String> quickHash(MediaLocator locator) async => 'h';

  @override
  Future<MediaLocator> persist(PickedMediaHandle handle) async => FileLocator(handle.uri);

  @override
  Future<void> release(MediaLocator locator) async {}

  @override
  Future<void> excludeFromBackup(String dirPath) async {}

  @override
  Future<int> remainingGrantBudget() async => 100;
}
