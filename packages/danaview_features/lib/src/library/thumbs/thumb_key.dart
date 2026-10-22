// OWNER: HOM-04
//
// Keys of the Home thumbnail cache (ARCH v1.2 V2-28, V2-104; BUILD_PLAN HOM-04): an item id, its
// modification time and a size class (S/M/L). The disk layout is
// `<cache>/danaview/library/thumbs/<class>/<hh>/<hash>/<modifiedMs>.thumb`, where `<hash>` is a
// 64-bit FNV-1a of the item id, so file names never carry a name, a path or an asset id (rule 30)
// and every version of one item's thumbnail sits in one small directory (invalidation by
// modification time removes its siblings). The encoded format is sniffed when decoding, so one
// name serves JPEG, HEIC, WebP and PNG.

import 'package:flutter/foundation.dart';

import 'package:danaview_library_native/danaview_library_native.dart';

/// The three thumbnail sizes. Grid cells use [s] or [m] (square, centre-cropped); [l] fits the
/// image's aspect for viewers and large tiles.
enum ThumbSizeClass {
  /// Lists, trays and small cells: 192 px square.
  s(192, NativeThumbnailMode.fill),

  /// Grid cells: 384 px square.
  m(384, NativeThumbnailMode.fill),

  /// Viewers and large tiles: fits 1280 px.
  l(1280, NativeThumbnailMode.fit);

  const ThumbSizeClass(this.pixels, this.mode);

  /// Longest side in pixels.
  final int pixels;

  /// How the thumbnail fits its box.
  final NativeThumbnailMode mode;

  /// The smallest class that covers a box whose longest side is [logicalSide] at [devicePixelRatio].
  static ThumbSizeClass forBox(double logicalSide, double devicePixelRatio) {
    final px = logicalSide * devicePixelRatio;
    if (px <= s.pixels) return s;
    if (px <= m.pixels) return m;
    return l;
  }

  /// Decoded size upper bound (RGBA) of a thumbnail of this class.
  int get maxDecodedBytes => pixels * pixels * 4;
}

/// What a thumbnail is of.
enum ThumbSourceKind {
  /// A photo or a video (system asset or file).
  media,

  /// A document (first page or Quick Look preview; HOM-26 on Apple, HOM-04A on Android).
  document,
}

/// One thumbnail request: which item, where its bytes are, its version and the size class.
@immutable
final class ThumbRequest {
  /// A request for [itemId] (a V2-09 id) whose bytes are at [source] (`ph:`/`ms:` id, absolute
  /// path or `content://` URI), last modified at [modifiedAt].
  const ThumbRequest({
    required this.itemId,
    required this.source,
    required this.modifiedAt,
    required this.sizeClass,
    this.kind = ThumbSourceKind.media,
  });

  /// The library item id.
  final String itemId;

  /// Where the platform reads the item (opened read-only).
  final String source;

  /// The item's modification time; a newer one invalidates the cached thumbnail.
  final DateTime modifiedAt;

  /// Requested size class.
  final ThumbSizeClass sizeClass;

  /// Media or document.
  final ThumbSourceKind kind;

  /// The cache key.
  ThumbKey get key => ThumbKey(itemId: itemId, modifiedMs: modifiedAt.millisecondsSinceEpoch, sizeClass: sizeClass);

  /// The same request at another size class.
  ThumbRequest at(ThumbSizeClass c) =>
      ThumbRequest(itemId: itemId, source: source, modifiedAt: modifiedAt, sizeClass: c, kind: kind);

  @override
  bool operator ==(Object other) =>
      other is ThumbRequest && other.key == key && other.source == source && other.kind == kind;

  @override
  int get hashCode => Object.hash(key, source, kind);

  // Never prints the id or the source (rule 30).
  @override
  String toString() => 'ThumbRequest(${sizeClass.name}, ${kind.name})';
}

/// Item id + modification time + size class.
@immutable
final class ThumbKey {
  /// A key.
  const ThumbKey({required this.itemId, required this.modifiedMs, required this.sizeClass});

  /// The library item id.
  final String itemId;

  /// Modification time in ms since the epoch.
  final int modifiedMs;

  /// Size class.
  final ThumbSizeClass sizeClass;

  /// 16 hex digits of the item id's 64-bit FNV-1a hash.
  String get idHash => fnv1a64Hex(itemId);

  /// Path of this key's file below the cache root (`/`-separated).
  String get relativePath {
    final h = idHash;
    return '${sizeClass.name}/${h.substring(0, 2)}/$h/$modifiedMs.thumb';
  }

  /// Directory holding every version of this item's thumbnail at this class, below the root.
  String get relativeItemDir {
    final h = idHash;
    return '${sizeClass.name}/${h.substring(0, 2)}/$h';
  }

  @override
  bool operator ==(Object other) =>
      other is ThumbKey && other.itemId == itemId && other.modifiedMs == modifiedMs && other.sizeClass == sizeClass;

  @override
  int get hashCode => Object.hash(itemId, modifiedMs, sizeClass);

  @override
  String toString() => 'ThumbKey(${sizeClass.name})';
}

/// The 64-bit FNV-1a hash of the UTF-16 code units of [s], as 16 lowercase hex digits. Computed in
/// two 32-bit halves so it is identical on every platform.
String fnv1a64Hex(String s) {
  // 64-bit FNV-1a with offset basis 0xcbf29ce484222325 and prime 0x100000001b3, in 32-bit limbs.
  var hi = 0xcbf29ce4, lo = 0x84222325;
  for (final unit in s.codeUnits) {
    for (final byte in [unit & 0xFF, unit >> 8]) {
      lo ^= byte;
      // (hi:lo) * 0x00000100_000001b3 = (hi:lo) * 0x1b3 + ((lo * 0x100) << 32)
      final loMul = lo * 0x1b3;
      final newLo = loMul & 0xFFFFFFFF;
      final carry = (loMul - newLo) ~/ 0x100000000;
      final newHi = (hi * 0x1b3 + carry + ((lo << 8) & 0xFFFFFFFF)) & 0xFFFFFFFF;
      hi = newHi;
      lo = newLo;
    }
  }
  return hi.toRadixString(16).padLeft(8, '0') + lo.toRadixString(16).padLeft(8, '0');
}
