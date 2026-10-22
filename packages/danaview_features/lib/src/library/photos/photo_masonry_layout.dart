// OWNER: HOM-10
//
// The masonry layout of the Photos tab (ARCH v1.2 V2-102, §10.1; BUILD_PLAN HOM-10). Children are
// the date-group headers and the photos in list order: header 0, its photos, header 1, … Every
// photo has one of five fixed aspect buckets, so its height is `cellWidth × bucket`; it goes to the
// shortest column (leftmost on ties). A header spans the width below the tallest column of the
// previous group, and the columns restart under it.
//
// The rects live in flat typed arrays computed in one linear pass when the photos, the width or
// the density change (not per frame). Two facts make every per-frame query a binary search:
//   * child tops never decrease (the shortest column only grows, and a header starts below every
//     column), so the last child starting before an offset is a search over `tops`;
//   * the running maximum of child bottoms never decreases, so the first child ending after an
//     offset is a search over that prefix maximum.
// Every child intersecting [a, b) has an index in [firstChildEndingAfter(a), lastChildStartingBefore(b)],
// so a frame lays out O(visible) children whatever the library size (50,000 items: well under
// 1 ms per query; test/v12/photos_tab/photo_masonry_layout_test.dart).

import 'dart:math' as math;
import 'dart:typed_data';

import 'photo_date_groups.dart';
import 'photo_grid_item.dart';

/// Density levels of the grid, densest last: the target cell width in logical pixels.
const List<double> photoGridDensityTargets = [200, 140, 104, 80];

/// The default density level (index into [photoGridDensityTargets]).
const int photoGridDefaultDensity = 1;

/// The smallest cell width, so the shortest bucket (16:9) stays a ≥ 44 px target.
const double photoGridMinCellWidth = 80;

/// Column count for [width] at [density] (at least 2, at most 12, cells ≥ [photoGridMinCellWidth]
/// wide whenever two columns fit).
int photoGridColumnsFor(double width, int density, {double spacing = 2}) {
  final target = photoGridDensityTargets[density.clamp(0, photoGridDensityTargets.length - 1)];
  final byTarget = ((width + spacing) / (target + spacing)).floor();
  final byMin = ((width + spacing) / (photoGridMinCellWidth + spacing)).floor();
  return math.max(2, math.min(12, math.min(byTarget, byMin)));
}

/// The computed rects of every header and photo cell.
final class PhotoMasonryLayout {
  PhotoMasonryLayout._({
    required this.width,
    required this.columns,
    required this.cellWidth,
    required this.photoCount,
    required this.groupCount,
    required Float64List tops,
    required Float64List lefts,
    required Float64List widths,
    required Float64List heights,
    required Float64List maxBottoms,
    required Int32List refs,
    required Int32List childOfPhoto,
    required this.totalExtent,
  })  : _tops = tops,
        _lefts = lefts,
        _widths = widths,
        _heights = heights,
        _maxBottoms = maxBottoms,
        _refs = refs,
        _childOfPhoto = childOfPhoto;

  /// Lays out photos of [buckets] (one [PhotoAspectBucket.index] per photo) in [groups] across
  /// [width] with [columns] columns. [headerExtent] is each group header's height; [padding] the
  /// horizontal inset, [spacing] the gap between cells, [groupGap] the space above every header but
  /// the first.
  factory PhotoMasonryLayout.compute({
    required Uint8List buckets,
    required List<PhotoDateGroup> groups,
    required double width,
    required int columns,
    required double headerExtent,
    double padding = 0,
    double spacing = 2,
    double groupGap = 8,
  }) {
    assert(columns >= 1);
    final photos = buckets.length;
    final n = photos + groups.length;
    final tops = Float64List(n);
    final lefts = Float64List(n);
    final widths = Float64List(n);
    final heights = Float64List(n);
    final maxBottoms = Float64List(n);
    final refs = Int32List(n);
    final childOfPhoto = Int32List(photos);
    final inner = math.max(0.0, width - 2 * padding);
    final cellWidth = math.max(0.0, (inner - spacing * (columns - 1)) / columns);
    final bucketHeights = Float64List.fromList([for (final b in PhotoAspectBucket.values) b.heightPerWidth * cellWidth]);
    final columnHeights = Float64List(columns);
    final columnLefts = Float64List.fromList([for (var c = 0; c < columns; c++) padding + c * (cellWidth + spacing)]);
    var y = 0.0;
    var child = 0;
    var runningMax = 0.0;
    for (var g = 0; g < groups.length; g++) {
      final group = groups[g];
      if (g > 0) y += groupGap;
      tops[child] = y;
      lefts[child] = 0;
      widths[child] = width;
      heights[child] = headerExtent;
      refs[child] = -(g + 1);
      runningMax = math.max(runningMax, y + headerExtent);
      maxBottoms[child] = runningMax;
      child++;
      final groupTop = y + headerExtent;
      for (var c = 0; c < columns; c++) {
        columnHeights[c] = groupTop;
      }
      final end = math.min(group.end, photos);
      for (var p = group.start; p < end; p++) {
        var best = 0;
        var bestHeight = columnHeights[0];
        for (var c = 1; c < columns; c++) {
          final h = columnHeights[c];
          if (h < bestHeight) {
            best = c;
            bestHeight = h;
          }
        }
        final h = bucketHeights[buckets[p]];
        tops[child] = bestHeight;
        lefts[child] = columnLefts[best];
        widths[child] = cellWidth;
        heights[child] = h;
        refs[child] = p;
        childOfPhoto[p] = child;
        final bottom = bestHeight + h;
        columnHeights[best] = bottom + spacing;
        if (bottom > runningMax) runningMax = bottom;
        maxBottoms[child] = runningMax;
        child++;
      }
      var tallest = groupTop;
      for (var c = 0; c < columns; c++) {
        // The trailing spacing of a column isn't part of the group.
        final h = columnHeights[c] > groupTop ? columnHeights[c] - spacing : groupTop;
        if (h > tallest) tallest = h;
      }
      y = tallest;
    }
    // Groups that don't cover every photo leave the rest out (callers pass covering groups).
    Float64List cut(Float64List a) => child == n ? a : Float64List.sublistView(a, 0, child);
    return PhotoMasonryLayout._(
      width: width,
      columns: columns,
      cellWidth: cellWidth,
      photoCount: photos,
      groupCount: groups.length,
      tops: cut(tops),
      lefts: cut(lefts),
      widths: cut(widths),
      heights: cut(heights),
      maxBottoms: cut(maxBottoms),
      refs: child == n ? refs : Int32List.sublistView(refs, 0, child),
      childOfPhoto: childOfPhoto,
      totalExtent: y,
    );
  }

  /// The width it was computed for.
  final double width;

  /// Columns.
  final int columns;

  /// The width of one photo cell.
  final double cellWidth;

  /// Photos laid out.
  final int photoCount;

  /// Date groups (headers) laid out.
  final int groupCount;

  /// The height of the whole grid.
  final double totalExtent;

  final Float64List _tops;
  final Float64List _lefts;
  final Float64List _widths;
  final Float64List _heights;
  final Float64List _maxBottoms;
  final Int32List _refs;
  final Int32List _childOfPhoto;

  /// Headers plus photos.
  int get childCount => _tops.length;

  /// Top of child [i].
  double topOf(int i) => _tops[i];

  /// Left of child [i].
  double leftOf(int i) => _lefts[i];

  /// Width of child [i].
  double widthOf(int i) => _widths[i];

  /// Height of child [i].
  double heightOf(int i) => _heights[i];

  /// Bottom of child [i].
  double bottomOf(int i) => _tops[i] + _heights[i];

  /// True when child [i] is a date-group header.
  bool isHeader(int i) => _refs[i] < 0;

  /// The group index of header child [i].
  int groupOf(int i) => -_refs[i] - 1;

  /// The photo index of photo child [i].
  int photoOf(int i) => _refs[i];

  /// The child index of photo [p].
  int childOfPhoto(int p) => _childOfPhoto[p];

  /// The first child whose bottom is below [offset] (the first one a viewport starting at
  /// [offset] can show); [childCount] when none is.
  int firstChildEndingAfter(double offset) {
    var lo = 0, hi = childCount;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_maxBottoms[mid] > offset) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// The last child whose top is above [offset] (the last one a viewport ending at [offset] can
  /// show); 0 when none is.
  int lastChildStartingBefore(double offset) {
    var lo = 0, hi = childCount;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_tops[mid] < offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return math.max(0, lo - 1);
  }

  /// The children a viewport over [start, end) needs, as an inclusive index range, or null when
  /// there are no children there.
  (int, int)? visibleRange(double start, double end) {
    if (childCount == 0) return null;
    final first = firstChildEndingAfter(start);
    if (first >= childCount) return null;
    final last = lastChildStartingBefore(end);
    if (last < first) return (first, first);
    return (first, last);
  }
}
