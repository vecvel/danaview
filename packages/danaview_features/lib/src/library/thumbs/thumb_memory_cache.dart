// OWNER: HOM-04
//
// The decoded-thumbnail memory tier (ARCH v1.2 V2-104): a byte-accounted LRU, 64 MB by default.
// Every entry is charged its decoded size (width × height × 4); inserting past the budget evicts
// the least recently used entries and disposes them. A widget showing a thumbnail holds its own
// clone of the image ([ThumbBitmap.clone]), so eviction never pulls an image out from under a
// visible cell. Flutter's global ImageCache is not used for thumbnails.

import 'dart:collection';
import 'dart:ui' as ui;

import 'thumb_key.dart';

/// A decoded thumbnail.
abstract interface class ThumbBitmap {
  /// Pixel width.
  int get width;

  /// Pixel height.
  int get height;

  /// Bytes charged to the memory budget.
  int get byteSize;

  /// The image to paint, or null for a test double.
  ui.Image? get image;

  /// Another handle to the same pixels, disposed independently.
  ThumbBitmap clone();

  /// Releases this handle.
  void dispose();
}

/// A [ThumbBitmap] over a `dart:ui` image.
final class UiThumbBitmap implements ThumbBitmap {
  /// Wraps [image] (this object owns the handle).
  UiThumbBitmap(ui.Image this.image);

  @override
  final ui.Image? image;

  @override
  int get width => image!.width;

  @override
  int get height => image!.height;

  @override
  int get byteSize => width * height * 4;

  @override
  ThumbBitmap clone() => UiThumbBitmap(image!.clone());

  @override
  void dispose() => image!.dispose();
}

/// The memory LRU of decoded thumbnails.
final class ThumbMemoryCache {
  /// A cache of at most [maxBytes] (64 MB by default, V2-104).
  ThumbMemoryCache({this.maxBytes = defaultMaxBytes}) : assert(maxBytes > 0);

  /// 64 MB.
  static const defaultMaxBytes = 64 * 1024 * 1024;

  /// The byte budget.
  final int maxBytes;

  final LinkedHashMap<ThumbKey, ThumbBitmap> _entries = LinkedHashMap<ThumbKey, ThumbBitmap>();
  int _bytes = 0;
  int _peakBytes = 0;
  int _evictions = 0;

  /// Bytes held now.
  int get bytes => _bytes;

  /// The most bytes ever held at once (tests and the performance report).
  int get peakBytes => _peakBytes;

  /// Number of entries.
  int get length => _entries.length;

  /// Entries evicted so far.
  int get evictions => _evictions;

  /// The entry of [key], marked most recently used; null on a miss.
  ThumbBitmap? get(ThumbKey key) {
    final b = _entries.remove(key);
    if (b == null) return null;
    _entries[key] = b;
    return b;
  }

  /// True when [key] is cached (does not touch the LRU order).
  bool contains(ThumbKey key) => _entries.containsKey(key);

  /// Stores [bitmap] under [key] (the cache takes ownership), replacing and disposing an older
  /// entry, then evicts least recently used entries until the budget holds. A bitmap larger than
  /// the whole budget is disposed and not stored; returns false then.
  bool put(ThumbKey key, ThumbBitmap bitmap) {
    final old = _entries.remove(key);
    if (old != null) {
      _bytes -= old.byteSize;
      if (!identical(old, bitmap)) old.dispose();
    }
    if (bitmap.byteSize > maxBytes) {
      bitmap.dispose();
      return false;
    }
    while (_bytes + bitmap.byteSize > maxBytes && _entries.isNotEmpty) {
      _evictOldest();
    }
    _entries[key] = bitmap;
    _bytes += bitmap.byteSize;
    if (_bytes > _peakBytes) _peakBytes = _bytes;
    return true;
  }

  /// Removes and disposes every entry of [itemId] (all classes and versions).
  void removeItem(String itemId) {
    final keys = _entries.keys.where((k) => k.itemId == itemId).toList();
    for (final k in keys) {
      final b = _entries.remove(k)!;
      _bytes -= b.byteSize;
      b.dispose();
    }
  }

  /// Disposes every entry (memory pressure, settings › clear cache).
  void clear() {
    for (final b in _entries.values) {
      b.dispose();
    }
    _entries.clear();
    _bytes = 0;
  }

  void _evictOldest() {
    final k = _entries.keys.first;
    final b = _entries.remove(k)!;
    _bytes -= b.byteSize;
    _evictions++;
    b.dispose();
  }
}
