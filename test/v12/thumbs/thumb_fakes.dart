// OWNER: HOM-04
//
// Test doubles of the thumbnail tiers (BUILD_PLAN HOM-04): an in-memory disk tier, a scripted
// platform generator (instant, gated or failing per source), and a fake decoder whose bitmaps
// share reference-counted "pixels", so a test can measure the bytes really retained (the memory
// tier plus the clones visible cells hold).
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:danaview_features/src/library/thumbs/thumb_disk_cache.dart';
import 'package:danaview_features/src/library/thumbs/thumb_key.dart';
import 'package:danaview_features/src/library/thumbs/thumb_memory_cache.dart';
import 'package:danaview_features/src/library/thumbs/thumbnail_service.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'dart:ui' as ui;

/// Tracks the fake pixel buffers alive.
final class PixelTracker {
  int liveBytes = 0;
  int peakLiveBytes = 0;
  int buffers = 0;

  void alloc(int n) {
    liveBytes += n;
    buffers++;
    if (liveBytes > peakLiveBytes) peakLiveBytes = liveBytes;
  }

  void free(int n) {
    liveBytes -= n;
    buffers--;
  }
}

final class _Pixels {
  _Pixels(this.tracker, this.bytes) {
    tracker.alloc(bytes);
  }

  final PixelTracker tracker;
  final int bytes;
  int refs = 1;

  void release() {
    if (--refs == 0) tracker.free(bytes);
    assert(refs >= 0, 'double dispose');
  }
}

/// A decoded fake: no ui.Image, shared pixels.
final class FakeBitmap implements ThumbBitmap {
  FakeBitmap._(this._pixels, this.width, this.height, this.tag);

  factory FakeBitmap.alloc(PixelTracker t, int width, int height, String tag) =>
      FakeBitmap._(_Pixels(t, width * height * 4), width, height, tag);

  final _Pixels _pixels;
  final String tag;
  bool disposed = false;

  @override
  final int width;

  @override
  final int height;

  @override
  int get byteSize => width * height * 4;

  @override
  ui.Image? get image => null;

  @override
  ThumbBitmap clone() {
    assert(!disposed, 'clone of a disposed bitmap');
    _pixels.refs++;
    return FakeBitmap._(_pixels, width, height, tag);
  }

  @override
  void dispose() {
    assert(!disposed, 'double dispose');
    disposed = true;
    _pixels.release();
  }
}

/// Disk tier in memory: path → content tag.
final class MemoryThumbDisk implements ThumbDiskCache {
  final Map<String, String> files = {};
  final Set<String> parts = {};
  int _n = 0;
  int lookups = 0;

  String pathOf(ThumbKey k) => '/mem/${k.relativePath}';

  @override
  Future<String?> lookup(ThumbKey key) async {
    lookups++;
    final p = pathOf(key);
    return files.containsKey(p) ? p : null;
  }

  @override
  Future<String> partPathFor(ThumbKey key) async {
    final p = '/mem/${key.relativeItemDir}/${++_n}.part';
    parts.add(p);
    return p;
  }

  @override
  Future<String> commit(ThumbKey key, String partPath) async {
    final content = files.remove(partPath) ?? 'generated';
    parts.remove(partPath);
    final target = pathOf(key);
    files.removeWhere((p, _) => p.startsWith('/mem/${key.relativeItemDir}/'));
    files[target] = content;
    return target;
  }

  @override
  Future<void> discard(String partPath) async {
    parts.remove(partPath);
    files.remove(partPath);
  }

  @override
  Future<void> evict(ThumbKey key) async => files.remove(pathOf(key));
}

/// Decodes by size class from the path (`/<class>/…`), or from a real file's name.
final class FakeDecoder implements ThumbDecoder {
  FakeDecoder(this.tracker, {this.disk});

  final PixelTracker tracker;
  final MemoryThumbDisk? disk;
  final Set<String> corrupt = {};
  int decodes = 0;

  @override
  Future<ThumbBitmap> decode(String path) async {
    decodes++;
    if (corrupt.contains(path) || disk?.files[path] == 'corrupt') throw const FormatException('corrupt');
    final cls = ThumbSizeClass.values.firstWhere((c) => path.contains('/${c.name}/'), orElse: () => ThumbSizeClass.m);
    final side = cls.pixels;
    final h = cls == ThumbSizeClass.l ? side * 3 ~/ 4 : side;
    return FakeBitmap.alloc(tracker, side, h, path);
  }
}

/// A scripted platform generator.
class FakeGenerator implements ThumbnailGenerator {
  FakeGenerator({this.disk});

  final MemoryThumbDisk? disk;

  /// When true, each request waits for [release] (or cancel).
  bool gated = false;

  /// Sources that fail with the given code.
  final Map<String, LibraryNativeErrorCode> failures = {};

  /// Sources whose document thumbnail is null.
  final Set<String> noDocumentThumbnail = {};

  final List<String> started = [];
  final List<String> cancelled = [];
  final List<({List<String> start, List<String> stop})> caching = [];
  final Map<String, Completer<void>> _gates = {};
  final Map<String, String> _sources = {};

  int get pending => _gates.length;

  /// Lets the request for [source] finish.
  void release(String source) {
    for (final e in _sources.entries.where((e) => e.value == source).toList()) {
      _gates.remove(e.key)?.complete();
    }
  }

  void releaseAll() {
    for (final g in _gates.values) {
      g.complete();
    }
    _gates.clear();
  }

  Future<NativeThumbnail> _make(String id, String source, String outputPath, int w, int h, NativeThumbnailFormat f) async {
    started.add(source);
    _sources[id] = source;
    if (gated) {
      final g = Completer<void>();
      _gates[id] = g;
      await g.future;
    }
    _sources.remove(id);
    if (cancelled.contains(id)) throw const LibraryNativeException(LibraryNativeErrorCode.cancelled, 'cancelled');
    final code = failures[source];
    if (code != null) throw LibraryNativeException(code, 'scripted');
    disk?.files[outputPath] = 'generated';
    return NativeThumbnail(path: outputPath, width: w, height: h, format: f);
  }

  @override
  Future<NativeThumbnail> mediaThumbnail({
    required String requestId,
    required String source,
    required int width,
    required int height,
    required String outputPath,
    NativeThumbnailMode mode = NativeThumbnailMode.fill,
    NativeThumbnailFormat format = NativeThumbnailFormat.jpeg,
    double quality = 0.8,
  }) =>
      _make(requestId, source, outputPath, width, height, format);

  @override
  Future<NativeThumbnail?> documentThumbnail({
    required String requestId,
    required String path,
    required int width,
    required int height,
    required String outputPath,
    double scale = 1,
    NativeThumbnailFormat format = NativeThumbnailFormat.jpeg,
    double quality = 0.8,
  }) async {
    if (noDocumentThumbnail.contains(path)) {
      started.add(path);
      return null;
    }
    return _make(requestId, path, outputPath, width, height, format);
  }

  @override
  Future<void> cancel(String requestId) async {
    cancelled.add(requestId);
    _gates.remove(requestId)?.complete();
  }

  @override
  Future<void> updateCaching({
    required List<String> start,
    required List<String> stop,
    required int width,
    required int height,
    NativeThumbnailMode mode = NativeThumbnailMode.fill,
  }) async =>
      caching.add((start: start, stop: stop));
}

ThumbRequest req(int i, {ThumbSizeClass c = ThumbSizeClass.m, DateTime? modified, ThumbSourceKind kind = ThumbSourceKind.media, String? source}) => ThumbRequest(
      itemId: 'fe_${i.toString().padLeft(6, '0')}',
      source: source ?? '/lib/item$i.jpg',
      modifiedAt: modified ?? DateTime.utc(2026, 1, 1),
      sizeClass: c,
      kind: kind,
    );
