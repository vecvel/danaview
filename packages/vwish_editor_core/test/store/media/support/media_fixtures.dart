// OWNER: CORE-27
//
// Shared helpers of the media pool tests: a fake platform port (content URIs backed by files,
// bookmarks, a grant budget, non-persistable URIs), a fake engine probe keyed by extension, a
// native-copy stand-in for the materializer, a filesystem spy check, and session construction.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_core/store.dart';

import '../../../ops/framework/ops_support.dart';
import '../../fs/support/harness.dart';

export '../../../ops/framework/ops_support.dart' show when;
export '../../fs/support/harness.dart';

/// Deterministic pseudo-random bytes (distinct content per [seed]).
Uint8List bytesOf(int seed, int length) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => r.nextInt(256)));
}

/// A fake platform `MediaAccessPort`: plain paths go to [DartIoMediaAccess]; `content://` URIs
/// map to backing files in [contentFiles]; bookmarks resolve through [bookmarkFiles]. Records the
/// calls so tests can assert which side effects the service asked for.
final class FakePlatformPort implements MediaAccessPort {
  /// Creates the port.
  FakePlatformPort(StoreRoots roots, {this.grantBudget = 500}) : plain = DartIoMediaAccess(roots);

  /// Plain-path implementation.
  final DartIoMediaAccess plain;

  /// `content://` URI → backing file.
  final Map<String, String> contentFiles = {};

  /// URIs whose grant cannot be persisted.
  final Set<String> notPersistable = {};

  /// Bookmark base64 → file.
  final Map<String, String> bookmarkFiles = {};

  /// Remaining grants; [persist] of a content URI consumes one.
  int grantBudget;

  /// Every `persist` call (by URI).
  final List<String> persisted = [];

  /// Directories excluded from backup.
  List<String> get excluded => plain.excludedDirs;

  MediaLocator _plainOf(MediaLocator l) => switch (l) {
        ContentUriLocator(:final uri) => FileLocator(
            contentFiles[uri] ?? (throw const MediaAccessFailure(MediaAccessFailureKind.accessLost))),
        BookmarkLocator(:final bookmarkB64, :final lastKnownPath) =>
          FileLocator(bookmarkFiles[bookmarkB64] ?? (lastKnownPath.isEmpty ? (throw const MediaAccessFailure(MediaAccessFailureKind.accessLost)) : lastKnownPath)),
        _ => l,
      };

  @override
  Future<ResolvedMedia> resolve(MediaLocator locator) async {
    final r = await plain.resolve(_plainOf(locator));
    return locator is ContentUriLocator ? r.copyWith(uri: locator.uri) : r;
  }

  @override
  Future<MediaStat?> stat(MediaLocator locator) => plain.stat(_plainOf(locator));

  @override
  Future<String> quickHash(MediaLocator locator) => plain.quickHash(_plainOf(locator));

  @override
  Future<MediaLocator> persist(PickedMediaHandle handle) async {
    persisted.add(handle.uri);
    if (handle.uri.startsWith('content://')) {
      if (notPersistable.contains(handle.uri)) {
        throw const MediaAccessFailure(MediaAccessFailureKind.permissionDenied, 'not persistable');
      }
      grantBudget--;
      return ContentUriLocator(handle.uri);
    }
    final bm = handle.bookmark;
    if (bm != null) {
      final b64 = base64.encode(bm);
      bookmarkFiles[b64] = Uri.parse(handle.uri).toFilePath();
      return BookmarkLocator(b64, lastKnownPath: p.basename(Uri.parse(handle.uri).toFilePath()));
    }
    return plain.persist(handle);
  }

  @override
  Future<void> release(MediaLocator locator) async {}

  @override
  Future<void> excludeFromBackup(String dirPath) => plain.excludeFromBackup(dirPath);

  @override
  Future<int> remainingGrantBudget() async => grantBudget;
}

/// Probe calls seen by [fakeProbe].
final List<String> probedUris = [];

/// A fake engine probe keyed by the file extension of the resolved URI:
/// `.mp4/.mov` video (2 s, 1920×1080, audio), `.wav/.m4a` audio (3 s), `.png/.jpg/.heic` image,
/// `.mkv` not editable (`container_unsupported_ios`), `.drm` not editable (no issue), anything
/// else throws.
Future<MediaProbe> fakeProbe(ResolvedMedia m) async {
  probedUris.add(m.uri);
  final ext = p.extension(Uri.parse(m.uri).path).toLowerCase();
  return switch (ext) {
    '.mp4' || '.mov' => MediaProbe(
        kind: MediaKind.video,
        duration: 2000000,
        hasVideo: true,
        hasAudio: true,
        width: 1920,
        height: 1080,
        nominalFrameRate: FrameRate.fps30,
        audioStreams: 1,
        container: 'mp4'),
    '.wav' || '.m4a' => MediaProbe(kind: MediaKind.audio, duration: 3000000, hasAudio: true, audioStreams: 1),
    '.png' || '.jpg' || '.heic' => MediaProbe(kind: MediaKind.image, hasVideo: true, width: 1080, height: 1920),
    '.mkv' => MediaProbe(kind: MediaKind.video, duration: 1000000, hasVideo: true, editable: false, issues: const ['container_unsupported_ios']),
    '.drm' => MediaProbe(kind: MediaKind.video, duration: 1000000, hasVideo: true, editable: false),
    _ => throw const FormatException('unknown container'),
  };
}

/// Stand-in for the native content-URI copy (AND-14): copies the backing file of the URI into
/// `<intoDir>/<n>/<name>` and records the call.
final class FakeMaterializer {
  /// Creates the materializer over [port]'s content map.
  FakeMaterializer(this.port);

  /// The port whose [FakePlatformPort.contentFiles] back the URIs.
  final FakePlatformPort port;

  /// URIs copied.
  final List<String> calls = [];

  var _n = 0;

  /// The `PickMaterializer` function.
  Future<String> call(PickedMedia picked, String intoDir) async {
    calls.add(picked.uri);
    final src = port.contentFiles[picked.uri]!;
    final dest = p.join(intoDir, 'm${_n++}', picked.displayName);
    await Directory(p.dirname(dest)).create(recursive: true);
    await File(src).copy(dest);
    return dest;
  }
}

/// A media test world: a container, an "external" folder outside the app (a Files location),
/// a fake port, a spying filesystem and a session.
final class MediaWorld {
  /// Creates the world.
  MediaWorld({ImportPlatform platform = ImportPlatform.ios, int grantBudget = 500, bool withMaterializer = true, FreeSpaceProbe? freeSpace, int seed = 4242})
      : c = Container.create() {
    external = p.join(c.dir.path, 'external');
    Directory(external).createSync();
    port = FakePlatformPort(c.roots, grantBudget: grantBudget);
    fs = FaultInjectingFs(const LocalStoreFs());
    deleter = OwnedFileDeleter(c.roots, fs: fs);
    materializer = FakeMaterializer(port);
    service = FileMediaPoolService(
      access: port,
      probe: fakeProbe,
      roots: c.roots,
      fs: fs,
      platform: platform,
      deleter: deleter,
      ids: SeededIdGenerator(seed),
      clock: () => when,
      materialize: withMaterializer ? materializer.call : null,
      freeSpace: freeSpace,
    );
    session = newSession();
  }

  /// The container.
  final Container c;

  /// A directory outside the app container's roots (user files).
  late final String external;

  /// The fake platform port.
  late final FakePlatformPort port;

  /// The spying filesystem every store write goes through.
  late final FaultInjectingFs fs;

  /// The guard.
  late final OwnedFileDeleter deleter;

  /// The native-copy stand-in.
  late final FakeMaterializer materializer;

  /// The service under test.
  late final FileMediaPoolService service;

  /// The session (project `pr_media00001`).
  late EditSession session;

  /// Roots.
  StoreRoots get roots => c.roots;

  /// A fresh session on an empty project with a main lane.
  EditSession newSession({String id = 'pr_media00001'}) => EditSession(
        project([lane('tr_main', TrackKind.video, const [], main: true)], pool: MediaPool.empty, id: id),
        ids: SeededIdGenerator(77),
        clock: () => when,
      );

  /// Writes a user file outside the app.
  String externalFile(String name, Uint8List bytes) => c.put(p.join(external, name), bytes);

  /// Writes a native Photos clone under `work/picks/<uuid>/`.
  String photosClone(String uuid, String name, Uint8List bytes) => c.put(p.join(roots.picksDir, uuid, name), bytes);

  /// Writes a drop copy under `work/drops/<uuid>/`.
  String dropCopy(String uuid, String name, Uint8List bytes) => c.put(p.join(roots.dropsDir, uuid, name), bytes);

  /// Registers a `content://` URI backed by a file outside the app.
  String contentUri(String name, Uint8List bytes) {
    final file = externalFile('provider_$name', bytes);
    final uri = 'content://media/picker/0/$name';
    port.contentFiles[uri] = file;
    return uri;
  }

  /// Absolute path of a locator under the roots.
  String pathOf(MediaLocator l) => roots.resolve(l as AppRelativeLocator);

  /// The mutating filesystem operations that touched anything outside the editor roots (must be
  /// empty: originals are never written, renamed or deleted).
  List<FsOp> opsOutsideEditorRoots() => [
        for (final op in fs.log)
          if (!_insideEditor(op.kind == FsOpKind.copy || op.kind == FsOpKind.copyExclusive ? op.path2! : op.path) ||
              (op.kind == FsOpKind.rename && (!_insideEditor(op.path) || !_insideEditor(op.path2!))))
            op,
      ];

  /// Inside the editor roots, spelled through the container's real path or its symlinked one
  /// (the guard canonicalizes; macOS temp dirs sit behind `/var → /private/var`).
  bool _insideEditor(String path) {
    final real = StoreRoots(
      support: Directory(roots.support).resolveSymbolicLinksSync(),
      cache: Directory(roots.cache).resolveSymbolicLinksSync(),
      documents: Directory(roots.documents).resolveSymbolicLinksSync(),
    );
    return roots.isInsideEditorRoots(path) || real.isInsideEditorRoots(path);
  }

  /// Byte-level snapshot of every file outside the editor roots (originals, Documents, caches).
  String originalsSnapshot() {
    final entries = c.dir
        .listSync(recursive: true, followLinks: false)
        .where((e) => e is! Directory && !roots.isInsideEditorRoots(e.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return entries.map((e) {
      if (e is File) {
        final s = e.statSync();
        return '${e.path}|${s.size}|${s.modified.microsecondsSinceEpoch}|${e.readAsBytesSync().fold<int>(0, (h, b) => (h * 31 + b) & 0x3fffffff)}';
      }
      return '${e.path}|link|${(e as Link).targetSync()}';
    }).join('\n');
  }

  /// Removes the container.
  void dispose() => c.dispose();
}

/// Bytes from a list.
Uint8List u8(List<int> bytes) => Uint8List.fromList(bytes);
