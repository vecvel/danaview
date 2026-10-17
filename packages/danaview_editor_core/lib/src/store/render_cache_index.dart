// OWNER: CORE-37
//
// The render-preview cache index (ARCH D-45(A), §9.5, §17.10): `<cache>/danaview/editor/renders/`
// holds `index.json` (written through `AtomicFile`) and one `<rangeHash>.mp4` per rendered range.
//
// - Files are produced by the native renderer (IOS-19 / AND-18) at [RenderCacheIndex.stagingPathFor]
//   (`<hash>.partial.mp4`) and moved into place by [RenderCacheIndex.put], which then records the
//   entry and evicts least-recently-used entries until the total fits the limit (1 GB; 512 MB on
//   the minimal and low tiers, [RenderCacheIndex.limitForTier]).
// - Every delete goes through `OwnedFileDeleter` and only for paths inside `renders/`.
// - [RenderCacheIndex.open] loads the index; when no valid index exists it is rebuilt from the
//   complete `<hash>.mp4` files on disk. Files the index does not know (partials, strays,
//   un-indexed renders left by a crash) are removed, and entries whose file is missing or has the
//   wrong size are dropped. A crash at any step therefore leaves a state the next `open` repairs.
// - Render files are preview-only and never referenced by export plans.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../plan/render_ranges.dart';
import 'atomic_file.dart';
import 'owned_file_deleter.dart';
import 'store_fs.dart';
import 'store_roots.dart';

/// How hard [RenderCacheIndex.trim] cuts.
enum RenderCacheTrimLevel {
  /// Memory pressure: down to half the limit.
  memoryPressure,

  /// Low disk space: down to a quarter of the limit.
  lowDisk,

  /// Critical: remove every render.
  critical,
}

/// One rendered range.
@immutable
final class RenderCacheEntry {
  /// Creates an entry.
  const RenderCacheEntry({required this.hash, required this.bytes, required this.lastUsed});

  /// The range hash ([rangeHash]).
  final String hash;

  /// File size in bytes.
  final int bytes;

  /// Last use (put or touch), for LRU eviction.
  final DateTime lastUsed;

  RenderCacheEntry _touched(DateTime at) => RenderCacheEntry(hash: hash, bytes: bytes, lastUsed: at);

  @override
  bool operator ==(Object other) => other is RenderCacheEntry && other.hash == hash && other.bytes == bytes && other.lastUsed == lastUsed;

  @override
  int get hashCode => Object.hash(hash, bytes, lastUsed);

  @override
  String toString() => 'RenderCacheEntry(${hash.substring(0, 8)}, $bytes B)';
}

/// The render-preview cache index (file header).
final class RenderCacheIndex implements RenderCacheLookup {
  /// Creates the index under [roots]' editor cache. Call [open] before anything else.
  RenderCacheIndex({
    required this.roots,
    required OwnedFileDeleter deleter,
    StoreFs fs = const LocalStoreFs(),
    int limitBytes = defaultLimitBytes,
    DateTime Function()? now,
    math.Random? random,
  })  : _fs = fs,
        _deleter = deleter,
        _limit = limitBytes,
        _now = now ?? DateTime.now,
        _atomic = AtomicFile(fs: fs, deleter: deleter, random: random);

  /// 1 GB (mid and high tiers).
  static const int defaultLimitBytes = 1024 * 1024 * 1024;

  /// 512 MB (minimal and low tiers).
  static const int constrainedLimitBytes = 512 * 1024 * 1024;

  /// The LRU bound of [tier].
  static int limitForTier(RenderTier tier) => tier.isConstrained ? constrainedLimitBytes : defaultLimitBytes;

  /// Index format version.
  static const int formatVersion = 1;

  static final RegExp _hashPattern = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _fileName = RegExp(r'^([0-9a-f]{64})\.mp4$');

  /// Whether [hash] is a well-formed range hash (64 lowercase hex digits).
  static bool isValidHash(String hash) => _hashPattern.hasMatch(hash);

  /// App roots.
  final StoreRoots roots;

  final StoreFs _fs;
  final OwnedFileDeleter _deleter;
  final AtomicFile _atomic;
  final DateTime Function() _now;
  int _limit;

  final Map<String, RenderCacheEntry> _entries = {};
  bool _opened = false;
  Future<void> _tail = Future<void>.value();

  /// `<cache>/danaview/editor/renders`.
  String get rendersDir => p.join(roots.editorCache, 'renders');

  /// `<cache>/danaview/editor/renders/index.json`.
  String get indexPath => p.join(rendersDir, 'index.json');

  /// Final file of [hash]: `renders/<hash>.mp4`.
  String pathFor(String hash) {
    _checkHash(hash);
    return p.join(rendersDir, '$hash.mp4');
  }

  /// Where the renderer writes [hash] before [put]: `renders/<hash>.partial.mp4`.
  String stagingPathFor(String hash) {
    _checkHash(hash);
    return p.join(rendersDir, '$hash.partial.mp4');
  }

  /// Whether `open` has completed.
  bool get isOpen => _opened;

  /// The LRU bound in bytes.
  int get limitBytes => _limit;

  /// Entries, most recently used first.
  List<RenderCacheEntry> get entries => _entries.values.toList()..sort(_byRecency);

  /// Sum of the indexed files' sizes.
  int get indexedBytes => _entries.values.fold(0, (s, e) => s + e.bytes);

  @override
  bool contains(String hash) => _entries.containsKey(hash);

  /// Loads (or rebuilds) the index and removes orphan files (file header). Safe to call again.
  Future<void> open() => _serial(() async {
        await _ensureDir();
        var dirty = false;
        Map<String, RenderCacheEntry>? loaded;
        try {
          final read = await _atomic.read(indexPath, isValid: _isValidIndex);
          loaded = _decode(read.bytes);
          if (read.source != AtomicSource.main) dirty = true;
        } on StoreFailure catch (e) {
          if (e.kind != StoreFailureKind.notFound && e.kind != StoreFailureKind.corrupt) rethrow;
        }
        final rebuild = loaded == null;
        if (rebuild) dirty = true;
        final onDisk = <String, StoreStat>{};
        final strays = <String>[];
        for (final e in await _fs.list(rendersDir)) {
          final name = p.basename(e.path);
          if (_isIndexFile(name)) continue;
          final m = _fileName.firstMatch(name);
          if (m != null && e.type == StoreEntityType.file) {
            onDisk[m[1]!] = await _fs.stat(e.path);
          } else {
            strays.add(e.path);
          }
        }
        _entries.clear();
        if (rebuild) {
          for (final MapEntry(key: hash, value: stat) in onDisk.entries) {
            _entries[hash] = RenderCacheEntry(hash: hash, bytes: stat.size, lastUsed: stat.modified ?? _now());
          }
        } else {
          for (final e in loaded.values) {
            final stat = onDisk[e.hash];
            if (stat == null || stat.size != e.bytes) {
              dirty = true;
              if (stat != null) strays.add(pathFor(e.hash));
              continue;
            }
            _entries[e.hash] = e;
          }
          for (final hash in onDisk.keys) {
            if (!loaded.containsKey(hash)) strays.add(pathFor(hash));
          }
        }
        if (dirty) await _persist();
        for (final s in strays) {
          await _delete(s, recursive: true);
        }
        _opened = true;
        await _evictTo(_limit);
      });

  /// The file of [hash] when it is indexed and present, else null (a missing file drops the
  /// entry).
  Future<String?> lookup(String hash) => _serial(() async {
        _checkOpen();
        if (!_entries.containsKey(hash)) return null;
        final path = pathFor(hash);
        final stat = await _fs.stat(path);
        if (stat.type == StoreEntityType.file && stat.size == _entries[hash]!.bytes) return path;
        _entries.remove(hash);
        await _persist();
        await _delete(path);
        return null;
      });

  /// Moves the rendered file [stagedFile] (inside `renders/`, normally [stagingPathFor]) to
  /// [pathFor]`(hash)`, records it as most recently used and evicts to the limit. A file larger
  /// than the whole limit is not kept.
  Future<void> put(String hash, String stagedFile) => _serial(() async {
        _checkOpen();
        _checkHash(hash);
        _checkInside(stagedFile);
        final dest = pathFor(hash);
        if (p.normalize(stagedFile) != p.normalize(dest)) {
          final staged = await _fs.stat(stagedFile);
          if (staged.type != StoreEntityType.file) throw const StoreFailure(StoreFailureKind.notFound, 'staged render');
          if ((await _fs.stat(dest)).exists) {
            _entries.remove(hash);
            await _persist();
            await _delete(dest);
          }
          await _fs.rename(stagedFile, dest);
        }
        final stat = await _fs.stat(dest);
        if (stat.type != StoreEntityType.file) throw const StoreFailure(StoreFailureKind.notFound, 'render');
        _entries[hash] = RenderCacheEntry(hash: hash, bytes: stat.size, lastUsed: _now());
        if (stat.size > _limit) {
          _entries.remove(hash);
          await _persist();
          await _delete(dest);
          return;
        }
        await _persist();
        await _evictTo(_limit);
      });

  /// Marks [hash] as just used (no-op when absent).
  Future<void> touch(String hash) => _serial(() async {
        _checkOpen();
        final e = _entries[hash];
        if (e == null) return;
        _entries[hash] = e._touched(_now());
        await _persist();
      });

  /// Removes the entries of [hashes] and their files (e.g. renders the session no longer wants).
  Future<void> remove(Iterable<String> hashes) => _serial(() async {
        _checkOpen();
        final gone = [for (final h in hashes) if (_entries.remove(h) != null) h];
        if (gone.isEmpty) return;
        await _persist();
        for (final h in gone) {
          await _delete(pathFor(h));
        }
      });

  /// Changes the LRU bound (tier change) and evicts to it.
  Future<void> setLimit(int bytes) => _serial(() async {
        _limit = bytes;
        if (_opened) await _evictTo(_limit);
      });

  /// Evicts least-recently-used entries under memory pressure or low disk ([RenderCacheTrimLevel]).
  Future<void> trim(RenderCacheTrimLevel level) => _serial(() async {
        _checkOpen();
        await _evictTo(switch (level) {
          RenderCacheTrimLevel.memoryPressure => _limit ~/ 2,
          RenderCacheTrimLevel.lowDisk => _limit ~/ 4,
          RenderCacheTrimLevel.critical => 0,
        });
      });

  /// Removes everything inside `renders/` (renders, partials, the index) and nothing else. Used
  /// by the "Editor cache" storage contributor and "Clear rendered previews".
  Future<void> clear() => _serial(() async {
        _entries.clear();
        if ((await _fs.stat(rendersDir)).type != StoreEntityType.directory) return;
        final children = await _fs.list(rendersDir);
        // Renders first, the index last: a crash in between leaves an index whose files are gone,
        // which the next open repairs.
        children.sort((a, b) => (_isIndexFile(p.basename(a.path)) ? 1 : 0).compareTo(_isIndexFile(p.basename(b.path)) ? 1 : 0));
        for (final e in children) {
          await _delete(e.path, recursive: e.type == StoreEntityType.directory);
        }
      });

  /// Bytes on disk inside `renders/` (renders, partials and the index) for the "Editor cache"
  /// storage contributor.
  Future<int> bytes() => _serial(() async {
        if ((await _fs.stat(rendersDir)).type != StoreEntityType.directory) return 0;
        var total = 0;
        Future<void> walk(String dir) async {
          for (final e in await _fs.list(dir)) {
            if (e.type == StoreEntityType.file) {
              total += (await _fs.stat(e.path)).size;
            } else if (e.type == StoreEntityType.directory) {
              await walk(e.path);
            }
          }
        }

        await walk(rendersDir);
        return total;
      });

  // -------------------------------------------------------------------------------------------

  Future<T> _serial<T>(Future<T> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _evictTo(int bound) async {
    if (indexedBytes <= bound) return;
    final order = _entries.values.toList()..sort(_byRecency);
    final victims = <String>[];
    var total = indexedBytes;
    for (final e in order.reversed) {
      if (total <= bound) break;
      victims.add(e.hash);
      total -= e.bytes;
    }
    for (final v in victims) {
      _entries.remove(v);
    }
    // Index first: a crash before the deletes leaves orphan files, which open removes.
    await _persist();
    for (final v in victims) {
      await _delete(pathFor(v));
    }
  }

  Future<void> _persist() async {
    await _ensureDir();
    await _atomic.write(indexPath, _encode());
  }

  Future<void> _ensureDir() async {
    if ((await _fs.stat(rendersDir)).type != StoreEntityType.directory) await _fs.createDirectory(rendersDir);
  }

  Future<void> _delete(String path, {bool recursive = false}) async {
    _checkInside(path);
    await _deleter.delete(path, recursive: recursive);
  }

  void _checkInside(String path) {
    if (!p.isWithin(p.normalize(rendersDir), p.normalize(path))) {
      throw OwnershipViolation(path, 'outside the render cache');
    }
  }

  void _checkHash(String hash) {
    if (!isValidHash(hash)) throw ArgumentError.value(hash, 'hash', 'not a range hash');
  }

  void _checkOpen() {
    if (!_opened) throw StateError('RenderCacheIndex.open() has not completed');
  }

  bool _isIndexFile(String name) => name == 'index.json' || name.startsWith('index.json.');

  static int _byRecency(RenderCacheEntry a, RenderCacheEntry b) {
    final t = b.lastUsed.compareTo(a.lastUsed);
    return t != 0 ? t : a.hash.compareTo(b.hash);
  }

  Uint8List _encode() {
    final list = _entries.values.toList()..sort((a, b) => a.hash.compareTo(b.hash));
    return Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
      'v': formatVersion,
      'entries': [
        for (final e in list) {'h': e.hash, 'b': e.bytes, 'u': e.lastUsed.toUtc().microsecondsSinceEpoch},
      ],
    })));
  }

  static bool _isValidIndex(Uint8List bytes) {
    try {
      _decode(bytes);
      return true;
    } on Object {
      return false;
    }
  }

  static Map<String, RenderCacheEntry> _decode(Uint8List bytes) {
    final j = jsonDecode(utf8.decode(bytes));
    if (j is! Map<String, Object?> || j['v'] != formatVersion) throw const FormatException('index');
    final raw = j['entries'];
    if (raw is! List<Object?>) throw const FormatException('entries');
    final out = <String, RenderCacheEntry>{};
    for (final e in raw) {
      if (e is! Map<String, Object?>) throw const FormatException('entry');
      final h = e['h'];
      final b = e['b'];
      final u = e['u'];
      if (h is! String || !isValidHash(h) || b is! int || b < 0 || u is! int) throw const FormatException('entry');
      out[h] = RenderCacheEntry(hash: h, bytes: b, lastUsed: DateTime.fromMicrosecondsSinceEpoch(u, isUtc: true));
    }
    return out;
  }
}
