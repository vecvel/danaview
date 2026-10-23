// OWNER: HOM-03
//
// The desktop photo scanner (ARCH v1.2 V2-109): walks one [DesktopRoot] read-only (rule 27)
// through a [DesktopFs] and lists its photos (and, on request, videos and documents) as
// [MediaItem]s with linked ids `lk:<rootId>/<relativePath>` (V2-09), classified by the HOM-16
// type table.
//
// - Skipped: hidden entries (`.…`), photo-library and app packages (`*.photoslibrary`,
//   `*.photolibrary`, `*.aplibrary`, `*.app`, …; the macOS Photos library comes from PhotoKit,
//   HOM-02), Windows system folders (`$RECYCLE.BIN`, `System Volume Information`), names an id
//   cannot carry (control characters).
// - Links: a link to a directory inside the root is skipped (the walk reaches that directory
//   itself); a link leaving the root is followed once, and every directory reached through it is
//   tracked by canonical path, so link loops end. Broken links are ignored.
// - Incremental rescan: each scan returns a [DesktopScanCache]. Passing it to the next scan reuses
//   the listing of every directory whose modification time is unchanged and settled (older than
//   the previous listing by [DesktopScanner.settleWindow], which covers 2 s FAT/exFAT timestamps)
//   and the item of every file whose modification time and size are unchanged. The result's
//   [DesktopScanResult.diff] says what was added, changed and removed.
// - A root that is missing (a removed drive) gives an empty, unavailable result; a directory that
//   disappears mid-walk is skipped. Nothing throws for file-system errors.

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../classify/classifier.dart';
import '../model/document_item.dart';
import '../model/file_kind.dart';
import '../model/ids.dart';
import '../model/media_item.dart';
import 'desktop_fs.dart';
import 'desktop_roots.dart';

/// Directory-name suffixes the scanner never enters (lower case).
const Set<String> skippedPackageSuffixes = {
  '.photoslibrary',
  '.photolibrary',
  '.migratedphotolibrary',
  '.aplibrary',
  '.photoboothlibrary',
  '.lrdata',
  '.app',
  '.bundle',
  '.framework',
};

/// Directory names the scanner never enters (lower case).
const Set<String> skippedDirectoryNames = {
  r'$recycle.bin',
  'system volume information',
  'photo booth library',
  'lost+found',
};

/// RAW photo extensions (`PhotoMediaItem.isRaw`).
const Set<String> rawExtensions = {'dng', 'cr2', 'cr3', 'nef', 'arw', 'raf', 'orf', 'rw2'};

const Map<String, String> _mimeByExtension = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'avif': 'image/avif',
  'gif': 'image/gif',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'dng': 'image/x-adobe-dng',
  'cr2': 'image/x-canon-cr2',
  'cr3': 'image/x-canon-cr3',
  'nef': 'image/x-nikon-nef',
  'arw': 'image/x-sony-arw',
  'raf': 'image/x-fuji-raf',
  'orf': 'image/x-olympus-orf',
  'rw2': 'image/x-panasonic-rw2',
  'mp4': 'video/mp4',
  'm4v': 'video/x-m4v',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'csv': 'text/csv',
};

/// The MIME type desktop discovery reports for [fileName].
String mimeTypeForFileName(String fileName) =>
    _mimeByExtension[extensionOf(fileName) ?? ''] ?? 'application/octet-stream';

/// True when the scanner skips the directory called [name].
bool isSkippedDirectoryName(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith('.')) return true;
  if (skippedDirectoryNames.contains(lower)) return true;
  return skippedPackageSuffixes.any(lower.endsWith);
}

/// What changed between two scans of one root.
@immutable
final class DesktopScanDiff {
  /// A diff of [added], [changed] and [removed] items.
  const DesktopScanDiff({this.added = const [], this.changed = const [], this.removed = const []});

  /// Items not in the previous scan.
  final List<MediaItem> added;

  /// Items whose modification time or size changed.
  final List<MediaItem> changed;

  /// Ids of items that are gone.
  final List<ItemId> removed;

  /// True when nothing changed.
  bool get isEmpty => added.isEmpty && changed.isEmpty && removed.isEmpty;
}

@immutable
final class _CachedDir {
  const _CachedDir(this.modified, this.listedAt, this.children);
  final DateTime modified;
  final DateTime listedAt;
  final List<DesktopDirEntry> children;
}

@immutable
final class _CachedFile {
  const _CachedFile(this.modified, this.size, this.item);
  final DateTime modified;
  final int size;
  final MediaItem item;
}

/// What a scan remembers for the next incremental scan of the same root. Opaque.
@immutable
final class DesktopScanCache {
  const DesktopScanCache._(this.rootId, this._dirs, this._files);

  /// The root this cache belongs to.
  final String rootId;
  final Map<String, _CachedDir> _dirs;
  final Map<String, _CachedFile> _files;

  /// Number of directories remembered.
  int get directoryCount => _dirs.length;

  /// Number of files remembered.
  int get fileCount => _files.length;
}

/// The result of [DesktopScanner.scan].
@immutable
final class DesktopScanResult {
  /// A result for [root].
  const DesktopScanResult({
    required this.root,
    required this.available,
    required this.items,
    required this.cache,
    required this.diff,
    this.truncated = false,
    this.listedDirectories = 0,
    this.reusedDirectories = 0,
  });

  /// The scanned root.
  final DesktopRoot root;

  /// False when the root is missing or unreadable (a removed drive): [items] is empty.
  final bool available;

  /// The items found, sorted by relative path.
  final List<MediaItem> items;

  /// Pass to the next scan of [root] for an incremental rescan.
  final DesktopScanCache cache;

  /// What changed since the cache passed in (everything is added on a first scan).
  final DesktopScanDiff diff;

  /// True when a limit of [DesktopScanner] stopped the walk early.
  final bool truncated;

  /// Directories listed from the file system in this scan.
  final int listedDirectories;

  /// Directories whose cached listing was reused.
  final int reusedDirectories;
}

/// Walks desktop roots read-only and lists their media.
final class DesktopScanner {
  /// A scanner over [fs] keeping [kinds] (photos by default), walking at most [maxDepth]
  /// directories deep and keeping at most [maxItems] items per root. [clock] is injectable for
  /// tests.
  DesktopScanner({
    this.fs = const IoDesktopFs(),
    this.kinds = const {FileKind.photo},
    this.maxDepth = 24,
    this.maxItems = 200000,
    this.settleWindow = const Duration(seconds: 2),
    DateTime Function()? clock,
    p.Context? pathContext,
  })  : _clock = clock ?? DateTime.now,
        _p = pathContext ?? p.context;

  /// The read-only file system.
  final DesktopFs fs;

  /// The kinds listed ([FileKind.photo], [FileKind.video], [FileKind.document]; others ignored).
  final Set<FileKind> kinds;

  /// Deepest directory level entered below the root.
  final int maxDepth;

  /// Most items kept per root.
  final int maxItems;

  /// A directory listing is reused only when the directory's modification time is at least this
  /// much older than the time of that listing.
  final Duration settleWindow;

  final DateTime Function() _clock;
  final p.Context _p;

  /// Scans [root]; pass the previous result's cache as [previous] for an incremental rescan.
  Future<DesktopScanResult> scan(DesktopRoot root, {DesktopScanCache? previous}) async {
    final prev = previous != null && previous.rootId == root.id ? previous : null;
    final dirs = <String, _CachedDir>{};
    final files = <String, _CachedFile>{};
    final items = <MediaItem>[];
    final added = <MediaItem>[];
    final changed = <MediaItem>[];
    var listed = 0;
    var reused = 0;
    var truncated = false;

    final rootStat = await fs.stat(root.path);
    final rootCanonical = rootStat?.type == DesktopEntryType.directory ? await fs.resolve(root.path) : null;
    if (rootCanonical == null) {
      return DesktopScanResult(
        root: root,
        available: false,
        items: const [],
        cache: DesktopScanCache._(root.id, const {}, const {}),
        diff: DesktopScanDiff(removed: [for (final f in prev?._files.values ?? const <_CachedFile>[]) f.item.id]),
      );
    }

    final visited = <String>{rootCanonical};
    // (absolute path, relative segments, depth, reached through a link leaving the root);
    // depth-first in name order. Plain directories inside the root cannot loop; directories
    // reached through a link are tracked by canonical path in [visited].
    final stack = <(String, List<String>, int, bool)>[(root.path, const [], 0, false)];
    while (stack.isNotEmpty) {
      final (dir, rel, depth, viaLink) = stack.removeLast();
      final dirStat = await fs.stat(dir);
      if (dirStat == null || dirStat.type != DesktopEntryType.directory) continue;
      final now = _clock();
      final cachedDir = prev?._dirs[dir];
      List<DesktopDirEntry> children;
      if (cachedDir != null &&
          cachedDir.modified == dirStat.modified &&
          !dirStat.modified.isAfter(cachedDir.listedAt.subtract(settleWindow))) {
        children = cachedDir.children;
        dirs[dir] = cachedDir;
        reused++;
      } else {
        final list = await fs.list(dir);
        if (list == null) continue;
        list.sort((a, b) => a.name.compareTo(b.name));
        children = List.unmodifiable(list);
        dirs[dir] = _CachedDir(dirStat.modified, now, children);
        listed++;
      }

      final subdirs = <(String, List<String>, int, bool)>[];
      for (final child in children) {
        if (child.name.isEmpty || child.name.startsWith('.')) continue;
        final path = _p.join(dir, child.name);
        var type = child.type;
        DesktopStat? st;
        if (type == DesktopEntryType.link) {
          st = await fs.stat(path);
          if (st == null) continue; // broken link
          type = st.type;
        }
        if (type == DesktopEntryType.directory) {
          if (depth >= maxDepth || isSkippedDirectoryName(child.name)) continue;
          var outside = viaLink;
          if (child.type == DesktopEntryType.link || viaLink) {
            final canonical = await fs.resolve(path);
            if (canonical == null) continue;
            if (child.type == DesktopEntryType.link) {
              // A link back into the root is walked there already; one outside is walked once.
              if (canonical == rootCanonical || _p.isWithin(rootCanonical, canonical)) continue;
              outside = true;
            }
            if (!visited.add(canonical)) continue; // link loop or repeat
          }
          subdirs.add((path, [...rel, child.name], depth + 1, outside));
          continue;
        }
        if (type != DesktopEntryType.file) continue;
        if (items.length >= maxItems) {
          truncated = true;
          continue;
        }
        final cls = classify(fileName: child.name);
        if (cls.decidedBy == ClassifiedBy.fallback || !kinds.contains(cls.kind)) continue;
        st ??= await fs.stat(path);
        if (st == null || st.type != DesktopEntryType.file) continue;
        final relPath = [...rel, child.name].join('/');
        final cachedFile = prev?._files[path];
        MediaItem? item;
        if (cachedFile != null && cachedFile.modified == st.modified && cachedFile.size == st.size) {
          item = cachedFile.item;
        } else {
          item = _itemFor(root, relPath, path, child.name, st, cls);
          if (item == null) continue;
          (cachedFile == null ? added : changed).add(item);
        }
        files[path] = _CachedFile(st.modified, st.size, item);
        items.add(item);
      }
      // Push in reverse so the walk visits subdirectories in name order.
      stack.addAll(subdirs.reversed);
    }

    final removed = <ItemId>[
      for (final entry in prev?._files.entries ?? const <MapEntry<String, _CachedFile>>[])
        if (!files.containsKey(entry.key)) entry.value.item.id,
    ];
    items.sort((a, b) => a.id.value.compareTo(b.id.value));
    return DesktopScanResult(
      root: root,
      available: true,
      items: List.unmodifiable(items),
      cache: DesktopScanCache._(root.id, Map.unmodifiable(dirs), Map.unmodifiable(files)),
      diff: DesktopScanDiff(added: added, changed: changed, removed: removed),
      truncated: truncated,
      listedDirectories: listed,
      reusedDirectories: reused,
    );
  }

  MediaItem? _itemFor(DesktopRoot root, String relPath, String path, String name, DesktopStat st, FileClass cls) {
    final id = LinkedItemId.tryParse('lk:${root.id}/$relPath');
    if (id == null) return null;
    final mime = mimeTypeForFileName(name);
    return switch (cls.kind) {
      FileKind.photo => PhotoMediaItem(
          id: id,
          uri: path,
          name: name,
          modifiedAt: st.modified,
          mimeType: mime,
          sizeBytes: st.size,
          isRaw: rawExtensions.contains(extensionOf(name)),
        ),
      FileKind.video => VideoMediaItem(
          id: id,
          uri: path,
          name: name,
          modifiedAt: st.modified,
          mimeType: mime,
          sizeBytes: st.size,
        ),
      FileKind.document => DocumentItem(
          id: id,
          uri: path,
          name: name,
          modifiedAt: st.modified,
          mimeType: mime,
          sizeBytes: st.size,
          docKind: cls.docKind ?? DocumentKind.other,
        ),
      FileKind.audio || FileKind.other => null,
    };
  }
}
