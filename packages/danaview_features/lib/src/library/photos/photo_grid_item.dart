// OWNER: HOM-10
//
// One cell of the Photos tab's masonry grid (ARCH v1.2 V2-102, V2-108; BUILD_PLAN HOM-10): a photo
// from a Danaview folder, from the system photo library (after the user opted in, Q-N8) or from a
// desktop Pictures folder, with what the grid needs to place it (its aspect bucket) and to draw it
// (thumbnail source and version). The grid never decodes anything to lay itself out: the aspect
// comes from stored pixel sizes and is quantised to five fixed buckets, so a cell's height is one
// multiply and the whole layout is a single linear pass over small integers.

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/foundation.dart';

import '../badges/media_badges.dart';

/// Where a Photos tab cell comes from.
enum PhotoOrigin {
  /// A Danaview folder (library.db, `fe_` id).
  danaview,

  /// The system photo library (PhotoKit `ph:` or MediaStore `ms:` id).
  system,

  /// A desktop Pictures folder or volume (`lk:` id, HOM-03).
  desktop,
}

/// The five fixed cell aspects of the masonry grid (height / width). Every photo snaps to the
/// nearest one, which keeps the columns tidy and the layout arithmetic trivial.
enum PhotoAspectBucket {
  /// 16:9 landscape and wider (panoramas too).
  wide(9 / 16),

  /// 4:3 and 3:2 landscape.
  landscape(3 / 4),

  /// Square-ish, and every photo whose size is unknown.
  square(1),

  /// 3:4 and 2:3 portrait.
  portrait(4 / 3),

  /// 9:16 portrait and taller (screenshots, stories).
  tall(16 / 9);

  const PhotoAspectBucket(this.heightPerWidth);

  /// Cell height for a cell width of 1.
  final double heightPerWidth;

  /// The bucket of a [width] × [height] photo; unknown or invalid sizes are [square].
  static PhotoAspectBucket of(int width, int height) {
    if (width <= 0 || height <= 0) return square;
    final r = height / width;
    // Boundaries are the geometric means of neighbouring buckets, so snapping is symmetric in log space.
    if (r < 0.6495) return wide; // sqrt(9/16 * 3/4)
    if (r < 0.8660) return landscape; // sqrt(3/4 * 1)
    if (r < 1.1547) return square; // sqrt(1 * 4/3)
    if (r < 1.5396) return portrait; // sqrt(4/3 * 16/9)
    return tall;
  }
}

/// One photo of the Photos tab.
@immutable
final class PhotoGridItem {
  /// A photo. [date] decides its date group; [thumbSource] and [modifiedAt] feed the thumbnail
  /// cache (HOM-04).
  const PhotoGridItem({
    required this.id,
    required this.origin,
    required this.name,
    required this.date,
    required this.modifiedAt,
    required this.thumbSource,
    this.width = 0,
    this.height = 0,
    this.folderId,
    this.isFavourite = false,
    this.badges = MediaBadges.none,
    this.media,
  });

  /// The V2-09 id (`fe_`, `ph:`, `ms:` or `lk:`).
  final ItemId id;

  /// Where it comes from.
  final PhotoOrigin origin;

  /// The display name (never logged, rule 30).
  final String name;

  /// When it was taken (or, without that, modified): the date group.
  final DateTime date;

  /// The modification time (the thumbnail version).
  final DateTime modifiedAt;

  /// What the thumbnailer opens: a `ph:`/`ms:` id or an absolute path.
  final String thumbSource;

  /// Pixel width, 0 when unknown.
  final int width;

  /// Pixel height, 0 when unknown.
  final int height;

  /// The Danaview folder, for Danaview photos.
  final FolderId? folderId;

  /// Starred in Danaview.
  final bool isFavourite;

  /// The Live, RAW and HDR badges (V2-110, HOM-13).
  final MediaBadges badges;

  /// The library item for system and desktop photos (the viewer's input), null for Danaview ones.
  final MediaItem? media;

  /// The cell aspect.
  PhotoAspectBucket get bucket => PhotoAspectBucket.of(width, height);

  @override
  bool operator ==(Object other) =>
      other is PhotoGridItem &&
      other.id == id &&
      other.date.isAtSameMomentAs(date) &&
      other.modifiedAt.isAtSameMomentAs(modifiedAt) &&
      other.width == width &&
      other.height == height &&
      other.isFavourite == isFavourite &&
      other.badges == badges &&
      other.name == name &&
      other.folderId == folderId;

  @override
  int get hashCode => Object.hash(id, modifiedAt.millisecondsSinceEpoch, width, height, isFavourite);

  // Never prints the name, id or source (rule 30).
  @override
  String toString() => 'PhotoGridItem(${origin.name}, ${bucket.name})';
}

/// [photo] (a system or desktop photo) as a grid item; [thumbSource] defaults to its id for
/// `ph:`/`ms:` assets and its URI otherwise.
PhotoGridItem photoGridItemOf(PhotoMediaItem photo, PhotoOrigin origin) {
  final raw = photo.id.value;
  final source = raw.startsWith('ph:') || raw.startsWith('ms:') ? raw : photo.uri;
  return PhotoGridItem(
    id: photo.id,
    origin: origin,
    name: photo.name,
    date: photo.takenAt ?? photo.modifiedAt,
    modifiedAt: photo.modifiedAt,
    thumbSource: source,
    width: photo.width,
    height: photo.height,
    badges: MediaBadges.ofItem(photo),
    media: photo,
  );
}

/// Merges two lists that are each newest first into one newest-first list (stable: on equal dates
/// [a] comes first).
List<PhotoGridItem> mergeNewestFirst(List<PhotoGridItem> a, List<PhotoGridItem> b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final out = List<PhotoGridItem?>.filled(a.length + b.length, null);
  var i = 0, j = 0, k = 0;
  while (i < a.length && j < b.length) {
    out[k++] = b[j].date.isAfter(a[i].date) ? b[j++] : a[i++];
  }
  while (i < a.length) {
    out[k++] = a[i++];
  }
  while (j < b.length) {
    out[k++] = b[j++];
  }
  return List<PhotoGridItem>.unmodifiable(out.cast<PhotoGridItem>());
}
