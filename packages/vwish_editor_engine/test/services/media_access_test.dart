// OWNER: ENG-03
//
// MobileMediaAccess over mocked channels (ARCH §9.1, §9.2, §12.4, D-44): resolve / stat /
// quickHash per locator kind (incl. stale bookmark refresh), persist decisions, release, grant
// budget, failure mapping to MediaAccessFailure, the notification prompt, and excludeFromBackup
// refusing Documents and every path outside the editor roots (lexically and through symlinks)
// without reaching native.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/store.dart' show OwnershipViolation;
import 'package:vwish_editor_engine/src/mobile_media_access.dart';
import 'package:vwish_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:vwish_editor_engine/src/pigeon/engine_channels.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import 'support/services_harness.dart';

const _docs = '/d/Documents';

Matcher _throwsAccess(MediaAccessFailureKind kind) => throwsA(isA<MediaAccessFailure>().having((f) => f.kind, 'kind', kind));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServicesHarness h;
  late MobileMediaAccess access;
  late List<OwnershipViolation> violations;

  setUp(() {
    h = ServicesHarness();
    violations = [];
    access = MobileMediaAccess(h.channels, documentsRoot: _docs, onViolation: violations.add);
    h.host
      ..on('PlatformHostApi', 'quickHash', (args) => 'qh:${(args.single! as MediaRefMsg).uri}')
      ..on('PlatformHostApi', 'stat', (_) => MediaStatMsg(sizeBytes: 77, modifiedMs: 1700000000000))
      ..on('PlatformHostApi', 'excludeFromBackup', (_) => null)
      ..on('PlatformHostApi', 'persistUriGrant', (_) => null)
      ..on('PlatformHostApi', 'releaseUriGrant', (_) => null)
      ..on('PlatformHostApi', 'createBookmark', (_) => Uint8List.fromList([9, 8, 7]))
      ..on(
          'PlatformHostApi', 'resolveBookmark', (args) => ResolvedBookmarkMsg(uri: 'file:///private/var/mobile/Files/a.mov', stale: false));
  });
  tearDown(() => h.dispose());

  MediaRefMsg lastRef(String method) => h.argsOf('PlatformHostApi', method).last.single! as MediaRefMsg;

  group('resolve, stat and quickHash', () {
    test('app-relative locators resolve under the derived app roots and Documents', () async {
      final media = await access.resolve(const AppRelativeLocator(AppRoot.support, 'vwish/editor/media/ab/qh/a.mov'));
      expect(media.uri, 'file:///s/vwish/editor/media/ab/qh/a.mov');
      expect(media.fingerprint, 'qh:file:///s/vwish/editor/media/ab/qh/a.mov');
      expect(media.bookmark, isNull);
      expect((await access.resolve(const AppRelativeLocator(AppRoot.cache, 'vwish/editor/work/picks/u/b.mp4'))).uri,
          'file:///c/vwish/editor/work/picks/u/b.mp4');
      expect((await access.resolve(const AppRelativeLocator(AppRoot.documents, 'Movies/My clip.mp4'))).uri,
          'file:///d/Documents/Movies/My%20clip.mp4');
    });

    test('an app-relative locator escaping its root is refused without a native call', () async {
      await expectLater(access.resolve(const AppRelativeLocator(AppRoot.documents, '../../etc/passwd')),
          _throwsAccess(MediaAccessFailureKind.permissionDenied));
      expect(h.host.count('PlatformHostApi', 'quickHash'), 0);
    });

    test('Documents locators need the documents root', () async {
      access.documentsRoot = null;
      await expectLater(
          access.resolve(const AppRelativeLocator(AppRoot.documents, 'a.mp4')), _throwsAccess(MediaAccessFailureKind.accessLost));
      access.documentsRoot = _docs;
      expect((await access.resolve(const AppRelativeLocator(AppRoot.documents, 'a.mp4'))).uri, 'file:///d/Documents/a.mp4');
    });

    test('file and content locators pass their URI; content URIs carry no bookmark', () async {
      expect((await access.resolve(const FileLocator('/x/y/../z.mov'))).uri, 'file:///x/z.mov');
      final content = await access.resolve(const ContentUriLocator('content://media/external/video/42'));
      expect(content.uri, 'content://media/external/video/42');
      expect(lastRef('quickHash').bookmark, isNull);
    });

    test('bookmarks resolve natively; a stale bookmark is refreshed and the new bytes are returned', () async {
      final b64 = base64Encode([1, 2, 3]);
      final fresh = await access.resolve(BookmarkLocator(b64, lastKnownPath: '/hint/a.mov'));
      expect(fresh.uri, 'file:///private/var/mobile/Files/a.mov');
      expect(fresh.bookmark, [1, 2, 3]);
      expect(h.argsOf('PlatformHostApi', 'resolveBookmark').single.single, [1, 2, 3]);
      expect(lastRef('quickHash').bookmark, [1, 2, 3], reason: 'the hash call carries the access grant');

      h.host.on('PlatformHostApi', 'resolveBookmark',
          (_) => ResolvedBookmarkMsg(uri: 'file:///moved/a.mov', stale: true, refreshedBookmark: Uint8List.fromList([4, 5])));
      final refreshed = await access.resolve(BookmarkLocator(b64));
      expect(refreshed.uri, 'file:///moved/a.mov');
      expect(refreshed.bookmark, [4, 5]);
    });

    test('an unresolvable or malformed bookmark is accessLost', () async {
      h.host.fail('PlatformHostApi', 'resolveBookmark', 'permissionDenied');
      await expectLater(access.stat(BookmarkLocator(base64Encode([1]))), _throwsAccess(MediaAccessFailureKind.accessLost));
      await expectLater(access.resolve(const BookmarkLocator('%%not base64%%')), _throwsAccess(MediaAccessFailureKind.accessLost));
    });

    test('stat maps the result; null means missing', () async {
      final s = await access.stat(const FileLocator('/x/a.mov'));
      expect(s, const MediaStat(sizeBytes: 77, modifiedMs: 1700000000000));
      expect(lastRef('stat').uri, 'file:///x/a.mov');
      h.host.on('PlatformHostApi', 'stat', (_) => null);
      expect(await access.stat(const ContentUriLocator('content://x/1')), isNull);
    });

    test('native failures map to MediaAccessFailure kinds', () async {
      h.host.fail('PlatformHostApi', 'stat', 'permissionDenied');
      await expectLater(access.stat(const ContentUriLocator('content://x/1')), _throwsAccess(MediaAccessFailureKind.accessLost));
      await expectLater(access.stat(const FileLocator('/x/a')), _throwsAccess(MediaAccessFailureKind.permissionDenied));
      h.host.fail('PlatformHostApi', 'quickHash', 'mediaOffline');
      await expectLater(access.quickHash(const FileLocator('/x/a')), _throwsAccess(MediaAccessFailureKind.notFound));
      h.host.fail('PlatformHostApi', 'quickHash', 'io', message: 'read failed at /private/var/x');
      await expectLater(
        access.quickHash(const FileLocator('/x/a')),
        throwsA(isA<MediaAccessFailure>()
            .having((f) => f.kind, 'kind', MediaAccessFailureKind.io)
            .having((f) => f.debugDetail, 'detail', isNot(contains('/private')))),
      );
    });

    test('quickHash returns the native hash', () async {
      expect(await access.quickHash(const ContentUriLocator('content://x/9')), 'qh:content://x/9');
    });
  });

  group('persist and release', () {
    test('a Files pick with a bookmark becomes a BookmarkLocator (no native call)', () async {
      final loc = await access
          .persist(PickedMedia(uri: 'file:///private/var/mobile/Files/a.mov', displayName: 'a.mov', bookmark: Uint8List.fromList([5, 6])));
      expect(loc, BookmarkLocator(base64Encode([5, 6]), lastKnownPath: '/private/var/mobile/Files/a.mov'));
      expect(h.host.calls.where((c) => c.startsWith('PlatformHostApi')), isEmpty);
    });

    test('a content URI takes a persisted grant', () async {
      final loc = await access.persist(const PickedMedia(uri: 'content://media/picker/0/1', displayName: 'v.mp4'));
      expect(loc, const ContentUriLocator('content://media/picker/0/1'));
      expect(h.argsOf('PlatformHostApi', 'persistUriGrant').single, ['content://media/picker/0/1']);
    });

    test('a non-persistable content URI is reported (the import policy then makes a managed copy)', () async {
      h.host.fail('PlatformHostApi', 'persistUriGrant', 'permissionDenied');
      await expectLater(
          access.persist(const PickedMedia(uri: 'content://x/1', displayName: 'x')), _throwsAccess(MediaAccessFailureKind.accessLost));
    });

    test('files under an app root become app-relative (never an absolute container path)', () async {
      expect(await access.persist(const PickedMedia(uri: 'file:///d/Documents/Movies/a.mp4', displayName: 'a.mp4')),
          const AppRelativeLocator(AppRoot.documents, 'Movies/a.mp4'));
      expect(await access.persist(const PickedMedia(uri: 'file:///c/vwish/editor/work/picks/u/b.mov', displayName: 'b.mov')),
          const AppRelativeLocator(AppRoot.cache, 'vwish/editor/work/picks/u/b.mov'));
      expect(await access.persist(const PickedMedia(uri: '/s/vwish/editor/media/x.mov', displayName: 'x.mov')),
          const AppRelativeLocator(AppRoot.support, 'vwish/editor/media/x.mov'));
      expect(h.host.calls.where((c) => c.startsWith('PlatformHostApi')), isEmpty);
    });

    test('other file paths (iOS in-place URLs) get a bookmark from native', () async {
      final loc = await access.persist(const PickedMedia(uri: 'file:///private/var/mobile/Inbox/c.mov', displayName: 'c.mov'));
      expect(loc, BookmarkLocator(base64Encode([9, 8, 7]), lastKnownPath: '/private/var/mobile/Inbox/c.mov'));
      expect(h.argsOf('PlatformHostApi', 'createBookmark').single, ['file:///private/var/mobile/Inbox/c.mov']);
    });

    test('unsupported schemes are not persistable', () async {
      await expectLater(access.persist(const PickedMedia(uri: 'https://example.com/a.mp4', displayName: 'a')),
          _throwsAccess(MediaAccessFailureKind.permissionDenied));
    });

    test('release frees content URI grants only; remainingGrantBudget is native', () async {
      await access.release(const ContentUriLocator('content://x/1'));
      await access.release(BookmarkLocator(base64Encode([1])));
      await access.release(const AppRelativeLocator(AppRoot.support, 'vwish/editor/media/a'));
      await access.release(const FileLocator('/x'));
      expect(h.argsOf('PlatformHostApi', 'releaseUriGrant'), [
        ['content://x/1']
      ]);
      h.host.on('PlatformHostApi', 'remainingGrantBudget', (_) => 97);
      expect(await access.remainingGrantBudget(), 97);
    });
  });

  group('requestNotificationPermission', () {
    test('answers the native prompt; true without a native engine; other failures typed', () async {
      h.host.on('PlatformHostApi', 'requestNotificationPermission', (_) => false);
      expect(await access.requestNotificationPermission(), isFalse);
      h.host.fail('PlatformHostApi', 'requestNotificationPermission', 'internal');
      await expectLater(access.requestNotificationPermission(), throwsEngineError(EngineErrorCode.internal));
      final bare = EngineChannels(config: servicesConfig, messageChannelSuffix: 'no_native');
      addTearDown(bare.dispose);
      expect(await MobileMediaAccess(bare).requestNotificationPermission(), isTrue);
    });
  });

  group('excludeFromBackup (D-44)', () {
    test('accepts the editor roots, the speech root and their subdirectories', () async {
      for (final d in [
        '/s/vwish/editor/media',
        '/s/vwish/editor/derived',
        '/s/vwish/editor',
        '/s/vwish/speech',
        '/s/vwish/speech/models',
        '/c/vwish/editor/proxies/',
        '/s/vwish/editor/media/./x//y',
      ]) {
        await access.excludeFromBackup(d);
      }
      expect(h.argsOf('PlatformHostApi', 'excludeFromBackup').map((a) => a.single), [
        '/s/vwish/editor/media',
        '/s/vwish/editor/derived',
        '/s/vwish/editor',
        '/s/vwish/speech',
        '/s/vwish/speech/models',
        '/c/vwish/editor/proxies',
        '/s/vwish/editor/media/x/y',
      ]);
      expect(violations, isEmpty);
    });

    test('refuses a Documents path (and every path outside the editor roots) without reaching native', () async {
      for (final d in [
        _docs,
        '$_docs/Exports',
        '$_docs/Movies/clip.mp4',
        '/s',
        '/s/vwish',
        '/s/vwish/editorx',
        '/c',
        '/',
        'vwish/editor/media',
        '/s/vwish/editor/media/../../../../d/Documents',
        '/s/vwish/speech/../../../d/Documents/Exports',
      ]) {
        await expectLater(access.excludeFromBackup(d), _throwsAccess(MediaAccessFailureKind.outsideEditorRoots), reason: d);
      }
      expect(h.host.count('PlatformHostApi', 'excludeFromBackup'), 0);
      expect(violations, hasLength(11));
      expect(violations.first.path, _docs);
      expect(violations.first.reason, 'inside Documents');
      expect(violations.map((v) => v.reason).toSet(), {'inside Documents', 'outside the editor roots', 'not an absolute path'});
    });

    test('refuses an editor-root path that is Documents itself (odd layouts)', () async {
      final odd = MobileMediaAccess(h.channels, documentsRoot: '/s/vwish/editor/media/docs');
      await expectLater(odd.excludeFromBackup('/s/vwish/editor/media/docs/a'), _throwsAccess(MediaAccessFailureKind.outsideEditorRoots));
    });

    test('the refusal message never carries the path', () async {
      try {
        await access.excludeFromBackup('$_docs/secret name');
        fail('must refuse');
      } on MediaAccessFailure catch (f) {
        expect(f.debugDetail, isNot(contains('secret')));
      }
    });

    test('native failures of an accepted path are typed MediaAccessFailures', () async {
      h.host.fail('PlatformHostApi', 'excludeFromBackup', 'io');
      await expectLater(access.excludeFromBackup('/s/vwish/editor/media'), _throwsAccess(MediaAccessFailureKind.io));
    });

    test('a symlink inside the editor roots that points into Documents is refused (real file system)', () async {
      final tmp = await Directory.systemTemp.createTemp('vw_eng03_');
      addTearDown(() => tmp.delete(recursive: true));
      final support = Directory('${tmp.path}/support/vwish/editor')..createSync(recursive: true);
      Directory('${tmp.path}/cache/vwish/editor').createSync(recursive: true);
      final docs = Directory('${tmp.path}/Documents/Movies')..createSync(recursive: true);
      Directory('${support.path}/media').createSync();
      Link('${support.path}/media/evil').createSync(docs.path);

      final real = EngineChannels(
        config: EditorEngineConfig(cacheRoot: '${tmp.path}/cache/vwish/editor', supportRoot: support.path),
      );
      addTearDown(real.dispose);
      final fsAccess = MobileMediaAccess(real, documentsRoot: '${tmp.path}/Documents', onViolation: violations.add);
      await expectLater(fsAccess.excludeFromBackup('${support.path}/media/evil'), _throwsAccess(MediaAccessFailureKind.outsideEditorRoots));
      expect(violations.single.reason, 'resolves outside the editor roots');
      // The same tree without the symlink is accepted (the temp dir itself may sit behind /var ->
      // /private/var: roots are resolved too).
      await fsAccess.excludeFromBackup('${support.path}/media');
      expect(h.argsOf('PlatformHostApi', 'excludeFromBackup').single.single, '${support.path}/media');
    }, skip: Platform.isWindows ? 'POSIX symlinks only' : false);
  });

  test('path helpers', () {
    expect(normalizePosixPath('/a//b/./c/../d/'), '/a/b/d');
    expect(normalizePosixPath('/../..'), '/');
    expect(normalizePosixPath('a/../../b'), '../b');
    expect(isWithinPosix('/a/b', '/a/b'), isTrue);
    expect(isWithinPosix('/a/b', '/a/bc'), isFalse);
    expect(isWithinPosix('/a/b', '/a/b/c'), isTrue);
    expect(mediaAccessFailureOf(EngineFailure.of(EngineErrorCode.cancelled), external: true).kind, MediaAccessFailureKind.io);
    expect(access.backupExclusionRoots, ['/s/vwish/editor', '/c/vwish/editor', '/s/vwish/speech']);
  });
}
