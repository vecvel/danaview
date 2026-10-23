// OWNER: HOM-04
//
// Keys of the Home thumbnail cache (ARCH v1.2 V2-28, V2-104; BUILD_PLAN HOM-04): an item id, its
// modification time and a size class (S/M/L). The disk layout is
// `<cache>/danaview/library/thumbs/<class>/<hh>/<hash>/<modifiedMs>.thumb`, where `<hash>` is a
// 64-bit FNV-1a of the item id, so file names never carry a name, a path or an asset id (rule 30)
// and every version of one item's thumbnail sits in one small directory (invalidation by
// modification time removes its siblings). The encoded format is sniffed when decoding, so one
// name serves JPEG, HEIC, WebP and PNG.
//
// Documents also key on their render scale (screen pixels per PDF point, the device pixel ratio;
// S2 tail): a scale other than 1 adds `@<scale>x` to the hash directory
// (`l/<hh>/<hash>@3x/<modifiedMs>.thumb`), so a 1x and a 3x rendering never collide and the
// sibling clean-up of one scale leaves the other alone. Scale-1 paths are unchanged.

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
    this.scale = 1,
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

  /// Screen pixels per PDF point a [ThumbSourceKind.document] renders at (the device pixel ratio;
  /// the box of [sizeClass] still bounds it). Media ignore it. Kept to hundredths in the key.
  final double scale;

  /// The cache key.
  ThumbKey get key => ThumbKey(
        itemId: itemId,
        modifiedMs: modifiedAt.millisecondsSinceEpoch,
        sizeClass: sizeClass,
        scaleCenti: kind == ThumbSourceKind.document ? scaleCentiOf(scale) : 100,
      );

  /// The same request at another size class.
  ThumbRequest at(ThumbSizeClass c) =>
      ThumbRequest(itemId: itemId, source: source, modifiedAt: modifiedAt, sizeClass: c, kind: kind, scale: scale);

  @override
  bool operator ==(Object other) =>
      other is ThumbRequest && other.key == key && other.source == source && other.kind == kind;

  @override
  int get hashCode => Object.hash(key, source, kind);

  // Never prints the id or the source (rule 30).
  @override
  String toString() => 'ThumbRequest(${sizeClass.name}, ${kind.name})';
}

/// [scale] in hundredths (at least 1): what a key stores, so 2.625 and 2.6249 share a key.
int scaleCentiOf(double scale) {
  if (!scale.isFinite || scale <= 0) return 100;
  final c = (scale * 100).round();
  return c < 1 ? 1 : c;
}

/// Item id + modification time + size class (+ render scale for documents).
@immutable
final class ThumbKey {
  /// A key.
  const ThumbKey({required this.itemId, required this.modifiedMs, required this.sizeClass, this.scaleCenti = 100});

  /// The library item id.
  final String itemId;

  /// Modification time in ms since the epoch.
  final int modifiedMs;

  /// Size class.
  final ThumbSizeClass sizeClass;

  /// Render scale in hundredths (100 = 1x; only documents use another).
  final int scaleCenti;

  /// The render scale passed to the platform.
  double get scale => scaleCenti / 100;

  String get _scaleTag {
    if (scaleCenti == 100) return '';
    final whole = scaleCenti ~/ 100, frac = scaleCenti % 100;
    final f = frac == 0 ? '' : '.${frac.toString().padLeft(2, '0').replaceFirst(RegExp(r'0$'), '')}';
    return '@$whole${f}x';
  }

  /// 16 hex digits of the item id's 64-bit FNV-1a hash.
  String get idHash => fnv1a64Hex(itemId);

  /// Path of this key's file below the cache root (`/`-separated).
  String get relativePath {
    final h = idHash;
    return '${sizeClass.name}/${h.substring(0, 2)}/$h$_scaleTag/$modifiedMs.thumb';
  }

  /// Directory holding every version of this item's thumbnail at this class, below the root.
  String get relativeItemDir {
    final h = idHash;
    return '${sizeClass.name}/${h.substring(0, 2)}/$h$_scaleTag';
  }

  @override
  bool operator ==(Object other) =>
      other is ThumbKey && other.itemId == itemId && other.modifiedMs == modifiedMs && other.sizeClass == sizeClass && other.scaleCenti == scaleCenti;

  @override
  int get hashCode => Object.hash(itemId, modifiedMs, sizeClass, scaleCenti);

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
