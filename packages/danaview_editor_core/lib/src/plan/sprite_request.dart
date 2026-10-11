// OWNER: CORE-29
//
// Export sprite pre-pass contract (ARCH §10.3, §14.1 step 4). CORE-31 `collectSpriteRequests`
// produces requests; API-04 `SpritePrepass` rasterizes missing `.vsprite` files and returns the
// manifest that `compileExport` (CORE-33) turns into sprite assets.

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// What a sprite renders.
enum SpriteSource {
  /// A text item.
  text,

  /// A burned subtitle cue.
  cue,
}

/// One sprite to rasterize.
@immutable
final class SpriteRequest {
  /// Creates a request.
  SpriteRequest({
    required this.key,
    required this.itemId,
    required this.source,
    required Map<String, Object?> layoutSpec,
    required this.scale,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.fontsVersion,
    this.reveal = false,
  }) : layoutSpec = Map.unmodifiable(layoutSpec);

  /// Content key: `sha1(TextLayoutSpec JSON, scale, canvas, fontsVersion)` (file name of the
  /// cached `.vsprite`).
  final String key;

  /// Item or cue id.
  final String itemId;

  /// Text item or cue.
  final SpriteSource source;

  /// `TextLayoutSpec` (CORE-07) as JSON.
  final Map<String, Object?> layoutSpec;

  /// Raster scale in sprite px per canvas px: `exportScale × maxAnimatedScale(item)`, clamped so
  /// neither side exceeds `min(maxTextureSize, 2 × output long side)`.
  final double scale;

  /// Output canvas width in px.
  final int canvasWidth;

  /// Output canvas height in px.
  final int canvasHeight;

  /// Version of the bundled content fonts (part of the key).
  final int fontsVersion;

  /// Whether a glyph-order map is needed (typewriter).
  final bool reveal;

  @override
  bool operator ==(Object other) =>
      other is SpriteRequest &&
      other.key == key &&
      other.itemId == itemId &&
      other.source == source &&
      const DeepCollectionEquality().equals(other.layoutSpec, layoutSpec) &&
      other.scale == scale &&
      other.canvasWidth == canvasWidth &&
      other.canvasHeight == canvasHeight &&
      other.fontsVersion == fontsVersion &&
      other.reveal == reveal;

  @override
  int get hashCode => Object.hash(key, itemId, source, scale, canvasWidth, canvasHeight, fontsVersion, reveal);
}

/// A rasterized sprite file.
@immutable
final class SpriteFile {
  /// Creates a sprite file entry.
  const SpriteFile({required this.uri, required this.sw, required this.sh, required this.sscale, required this.reveal});

  /// `file://` URI of the `.vsprite`.
  final String uri;

  /// Pixel width.
  final int sw;

  /// Pixel height.
  final int sh;

  /// Sprite px per canvas px.
  final double sscale;

  /// Whether the file carries a glyph-order map.
  final bool reveal;

  @override
  bool operator ==(Object other) =>
      other is SpriteFile && other.uri == uri && other.sw == sw && other.sh == sh && other.sscale == sscale && other.reveal == reveal;

  @override
  int get hashCode => Object.hash(uri, sw, sh, sscale, reveal);
}

/// Sprite files by request key.
@immutable
final class SpriteManifest {
  /// Creates a manifest.
  SpriteManifest(Map<String, SpriteFile> files) : files = Map.unmodifiable(files);

  /// No sprites.
  static final SpriteManifest empty = SpriteManifest(const {});

  /// Files by [SpriteRequest.key].
  final Map<String, SpriteFile> files;

  /// The file for [key], if rasterized.
  SpriteFile? operator [](String key) => files[key];
}
