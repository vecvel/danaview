// OWNER: CORE-22
//
// ARCH §8.2: no persisted string holds an absolute app-container path (iOS changes the container
// UUID on every update). A project using every locator kind under a fake
// `/var/mobile/Containers/Data/Application/<uuid>/` root (and an Android `/data/user/0/<pkg>/`
// root) encodes with no string containing the container prefix, except
// `BookmarkLocator.lastKnownPath`, a display hint. Paths inside an app root become
// `AppRelativeLocator`s, through the repository's relativizer or the codec's container detection.

import 'dart:convert';

import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/model.dart';

const String _uuid = '3F2504E0-4F89-41D3-9A0C-0305E82C3301';
const String _ios = '/var/mobile/Containers/Data/Application/$_uuid';
const String _android = '/data/user/0/com.vecvel.danaview';

/// Every string in [json] with its JSON path.
Iterable<(String, String)> stringsOf(Object? json, [String path = r'$']) sync* {
  if (json is String) {
    yield (path, json);
  } else if (json is Map<String, Object?>) {
    for (final e in json.entries) {
      yield (path, e.key);
      yield* stringsOf(e.value, '$path.${e.key}');
    }
  } else if (json is List<Object?>) {
    for (var i = 0; i < json.length; i++) {
      yield* stringsOf(json[i], '$path[$i]');
    }
  }
}

/// Mirrors `StoreRoots.relativize` (CORE-24) for the fake roots: the codec only sees the callback.
AppPathRelativizer relativizerFor(String container, {required String documents, required String support, required String cache}) {
  final roots = {AppRoot.documents: '$container/$documents', AppRoot.support: '$container/$support', AppRoot.cache: '$container/$cache'};
  return (path) {
    for (final e in roots.entries) {
      if (path.startsWith('${e.value}/')) return AppRelativeLocator(e.key, path.substring(e.value.length + 1));
    }
    return null;
  };
}

MediaAsset _asset(String id, MediaLocator locator, {String name = 'clip.mov', MediaOwnership own = MediaOwnership.external}) => MediaAsset(
      id: MediaId(id),
      kind: MediaKind.video,
      displayName: name,
      locator: locator,
      ownership: own,
      fingerprint: const MediaFingerprint(sizeBytes: 10, quickHash: 'aaaa'),
      probe: MediaProbe(kind: MediaKind.video, duration: 1000000, hasVideo: true),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026),
    );

/// A project whose pool uses every locator kind (and both URI forms) under [container], with the
/// app roots laid out as [documents], [support] and [cache] inside it.
EditProject containerProject(String container, {required String documents, required String support, required String cache}) {
  final assets = [
    _asset('md_app', const AppRelativeLocator(AppRoot.support, 'danaview/editor/media/ab/abcd/clip.mov'), own: MediaOwnership.managedCopy),
    _asset('md_docs', FileLocator('$container/$documents/Movies/holiday.mov')),
    _asset('md_support', FileLocator('$container/$support/danaview/editor/media/cd/cdef/take 2.mov'), own: MediaOwnership.managedCopy),
    _asset('md_cache', FileLocator('$container/$cache/danaview/editor/work/picks/IMG_0001.MOV'), own: MediaOwnership.managedCopy),
    _asset('md_tmp', FileLocator('$container/tmp/stray.mov')),
    _asset('md_bundle', FileLocator('/var/containers/Bundle/Application/$_uuid/Runner.app/demo.mov')),
    _asset('md_fileuri', ContentUriLocator('file://$container/$documents/Clips/with%20space.mov')),
    _asset('md_content', const ContentUriLocator('content://com.android.providers.media.documents/document/video%3A42')),
    _asset('md_bookmark', BookmarkLocator('Ym9va21hcms=', lastKnownPath: '$container/$documents/Movies/holiday.mov')),
    _asset('md_named', FileLocator('$container/$documents/a.mov'), name: '$container/$documents/a.mov'),
  ];
  return EditProject(
    id: const ProjectId('pr_container0001'),
    meta: ProjectMeta(
      name: 'Container',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      origin: FromPlayerOrigin(quickHash: 'aaaa', sizeBytes: 10, displayName: '$container/$documents/Movies/holiday.mov'),
    ),
    timeline: Timeline(tracks: [
      Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [
        for (final (i, a) in assets.indexed)
          MediaClip(id: ItemId('it_$i'), start: i * 1000000, duration: 1000000, media: a.id, visual: VisualProps.neutral),
      ]),
    ]),
    pool: MediaPool({for (final a in assets) a.id: a}),
  );
}

void main() {
  void expectNoContainerPaths(String body, String container) {
    final json = jsonDecode(body);
    final leaks = [
      for (final (path, s) in stringsOf(json))
        if ((s.contains(container) || AppContainerPaths.contains(s)) && !RegExp(r'\.loc\.hint$').hasMatch(path)) '$path = $s',
    ];
    expect(leaks, isEmpty, reason: 'only BookmarkLocator.lastKnownPath (loc.hint) may hold a container path');
    expect(body, contains('"hint":"$container/'), reason: 'the bookmark hint is kept as a display hint');
  }

  Map<String, Map<String, Object?>> locatorsById(String body) {
    final json = jsonDecode(body) as Map<String, Object?>;
    return {
      for (final a in (json['pool']! as Map<String, Object?>)['assets']! as List<Object?>)
        (a! as Map<String, Object?>)['id']! as String: (a as Map<String, Object?>)['loc']! as Map<String, Object?>,
    };
  }

  group('iOS container ($_ios)', () {
    final project = containerProject(_ios, documents: 'Documents', support: 'Library/Application Support', cache: 'Library/Caches');

    for (final (label, codec) in [
      ('with the repository relativizer', ProjectJsonCodec(relativize: relativizerFor(_ios, documents: 'Documents', support: 'Library/Application Support', cache: 'Library/Caches'))),
      ('with container detection only', ProjectJsonCodec()),
    ]) {
      test('every locator kind encodes without the container prefix ($label)', () {
        final body = codec.encode(project);
        expectNoContainerPaths(body, _ios);
        final loc = locatorsById(body);
        expect(loc['md_app'], {'app': 'support', 'rel': 'danaview/editor/media/ab/abcd/clip.mov'});
        expect(loc['md_docs'], {'app': 'documents', 'rel': 'Movies/holiday.mov'});
        expect(loc['md_support'], {'app': 'support', 'rel': 'danaview/editor/media/cd/cdef/take 2.mov'});
        expect(loc['md_cache'], {'app': 'cache', 'rel': 'danaview/editor/work/picks/IMG_0001.MOV'});
        expect(loc['md_fileuri'], {'app': 'documents', 'rel': 'Clips/with space.mov'});
        expect(loc['md_content'], {'uri': 'content://com.android.providers.media.documents/document/video%3A42'});
        expect(loc['md_tmp'], {'file': 'stray.mov'}, reason: 'outside the app roots only the file name survives (relink hint)');
        expect(loc['md_bundle'], {'file': 'demo.mov'}, reason: 'the app bundle path changes on update too');
        expect(loc['md_bookmark'], {'bookmark': 'Ym9va21hcms=', 'hint': '$_ios/Documents/Movies/holiday.mov'});
      });
    }

    test('the /private/var alias and a simulator container are detected too', () {
      const sim = '/Users/dev/Library/Developer/CoreSimulator/Devices/11111111-2222-3333-4444-555555555555/data/Containers/Data/Application/$_uuid';
      for (final c in ['/private$_ios', sim]) {
        final body = ProjectJsonCodec().encode(containerProject(c, documents: 'Documents', support: 'Library/Application Support', cache: 'Library/Caches'));
        expectNoContainerPaths(body, c);
      }
    });

    test('decoding the encoded project yields app-relative locators that resolve under any new container', () {
      final decoded = ProjectJsonCodec().decode(ProjectJsonCodec().encode(project)).project;
      expect(decoded.pool[const MediaId('md_docs')]!.locator, const AppRelativeLocator(AppRoot.documents, 'Movies/holiday.mov'));
      expect(decoded.pool[const MediaId('md_cache')]!.locator, const AppRelativeLocator(AppRoot.cache, 'danaview/editor/work/picks/IMG_0001.MOV'));
      expect(decoded.pool[const MediaId('md_named')]!.displayName, 'a.mov');
      expect((decoded.meta.origin as FromPlayerOrigin).displayName, 'holiday.mov');
    });
  });

  group('Android app data ($_android)', () {
    final project = containerProject(_android, documents: 'app_flutter', support: 'files', cache: 'cache');

    test('every locator kind encodes without the app data prefix', () {
      for (final codec in [
        ProjectJsonCodec(relativize: relativizerFor(_android, documents: 'app_flutter', support: 'files', cache: 'cache')),
        ProjectJsonCodec(),
      ]) {
        final body = codec.encode(project);
        expectNoContainerPaths(body, _android);
        final loc = locatorsById(body);
        expect(loc['md_docs'], {'app': 'documents', 'rel': 'Movies/holiday.mov'});
        expect(loc['md_support'], {'app': 'support', 'rel': 'danaview/editor/media/cd/cdef/take 2.mov'});
        expect(loc['md_cache'], {'app': 'cache', 'rel': 'danaview/editor/work/picks/IMG_0001.MOV'});
        expect(loc['md_tmp'], {'file': 'stray.mov'});
      }
    });

    test('/data/data/<pkg> is the same container', () {
      final body = ProjectJsonCodec().encode(containerProject('/data/data/com.vecvel.danaview', documents: 'app_flutter', support: 'files', cache: 'cache'));
      expectNoContainerPaths(body, '/data/data/com.vecvel.danaview');
    });
  });

  group('AppContainerPaths', () {
    test('detects containers and maps their roots', () {
      expect(AppContainerPaths.contains('$_ios/Documents/x.mov'), isTrue);
      expect(AppContainerPaths.contains('file://$_ios/Documents/x.mov'), isTrue);
      expect(AppContainerPaths.contains('$_android/files/x'), isTrue);
      expect(AppContainerPaths.contains('/private/var/containers/Bundle/Application/$_uuid/Runner.app/a.vlut'), isTrue);
      expect(AppContainerPaths.contains('/data/user_de/10/com.vecvel.danaview/files/a'), isTrue);
      expect(AppContainerPaths.contains('/Users/me/Movies/x.mov'), isFalse);
      expect(AppContainerPaths.contains('content://media/external/video/1'), isFalse);
      expect(AppContainerPaths.contains('/data/local/tmp/x'), isFalse);
      expect(AppContainerPaths.containerRootOf('$_ios/Library/Caches/a'), _ios);
      expect(AppContainerPaths.containerRootOf('$_android/cache/a'), _android);
      expect(AppContainerPaths.relativize('$_ios/Library/Application Support/a/b'), const AppRelativeLocator(AppRoot.support, 'a/b'));
      expect(AppContainerPaths.relativize('$_ios/Documents/../Documents/c'), const AppRelativeLocator(AppRoot.documents, 'c'));
      expect(AppContainerPaths.relativize('$_ios/Documents'), isNull, reason: 'the root itself is not a file');
      expect(AppContainerPaths.relativize('$_ios/tmp/x'), isNull);
      expect(AppContainerPaths.relativize('relative/path'), isNull);
    });

    test('paths outside every container and root are kept as they are (desktop)', () {
      final p = containerProject('/Users/me/Projects', documents: 'Documents', support: 'Support', cache: 'Cache');
      final loc = locatorsById(ProjectJsonCodec().encode(p));
      expect(loc['md_docs'], {'file': '/Users/me/Projects/Documents/Movies/holiday.mov'});
    });
  });
}
