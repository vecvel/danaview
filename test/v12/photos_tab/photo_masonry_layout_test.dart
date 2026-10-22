// OWNER: HOM-10
//
// BUILD_PLAN HOM-10, pure half: aspect buckets, date groups (Today, Yesterday, This month, months)
// and the masonry layout — no overlaps, headers spanning the width, monotonic tops, visible ranges
// equal to a brute-force scan — and the acceptance budget: with 50,000 synthetic items the visible
// range of any viewport is computed in ≤ 1 ms (measured as the 99th percentile of 2,000 queries after the
// one linear layout pass, which is recorded too).

// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:danaview_features/src/library/photos/photo_date_groups.dart';
import 'package:danaview_features/src/library/photos/photo_grid_item.dart';
import 'package:danaview_features/src/library/photos/photo_masonry_layout.dart';
import 'package:danaview_features/src/library/photos/photos_tab_providers.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:flutter_test/flutter_test.dart';

PhotoGridItem _photo(int i, DateTime date, {int w = 4032, int h = 3024}) => PhotoGridItem(
      id: EntryId.parse('fe_p$i'),
      origin: PhotoOrigin.danaview,
      name: 'IMG_$i.jpg',
      date: date,
      modifiedAt: date,
      thumbSource: '/tmp/$i.jpg',
      width: w,
      height: h,
    );

/// [n] photos newest first, one every [step] back from [from], sizes cycling through the buckets.
List<PhotoGridItem> synthetic(int n, {DateTime? from, Duration step = const Duration(hours: 7)}) {
  final start = from ?? DateTime(2026, 10, 22, 18);
  const sizes = [(1920, 1080), (4032, 3024), (3000, 3000), (3024, 4032), (1170, 2532), (0, 0)];
  return [
    for (var i = 0; i < n; i++)
      _photo(i, start.subtract(step * i), w: sizes[(i * 7) % sizes.length].$1, h: sizes[(i * 7) % sizes.length].$2),
  ];
}

bool _overlaps(PhotoMasonryLayout l, int a, int b) =>
    l.leftOf(a) < l.leftOf(b) + l.widthOf(b) - 1e-6 &&
    l.leftOf(b) < l.leftOf(a) + l.widthOf(a) - 1e-6 &&
    l.topOf(a) < l.bottomOf(b) - 1e-6 &&
    l.topOf(b) < l.bottomOf(a) - 1e-6;

void main() {
  group('aspect buckets', () {
    test('snap to the nearest of five fixed aspects; unknown sizes are square', () {
      expect(PhotoAspectBucket.of(1920, 1080), PhotoAspectBucket.wide);
      expect(PhotoAspectBucket.of(6000, 1500), PhotoAspectBucket.wide);
      expect(PhotoAspectBucket.of(4032, 3024), PhotoAspectBucket.landscape);
      expect(PhotoAspectBucket.of(6000, 4000), PhotoAspectBucket.landscape);
      expect(PhotoAspectBucket.of(3000, 3100), PhotoAspectBucket.square);
      expect(PhotoAspectBucket.of(3024, 4032), PhotoAspectBucket.portrait);
      expect(PhotoAspectBucket.of(1170, 2532), PhotoAspectBucket.tall);
      expect(PhotoAspectBucket.of(0, 0), PhotoAspectBucket.square);
      expect(PhotoAspectBucket.of(-1, 300), PhotoAspectBucket.square);
    });
  });

  group('date groups', () {
    final now = DateTime(2026, 10, 22, 15);

    test('Today, Yesterday, This month, then months (with the year before this one)', () {
      final photos = [
        _photo(0, DateTime(2026, 10, 23, 9)), // future: Today
        _photo(1, DateTime(2026, 10, 22, 8)),
        _photo(2, DateTime(2026, 10, 21, 23)),
        _photo(3, DateTime(2026, 10, 3)),
        _photo(4, DateTime(2026, 9, 30)),
        _photo(5, DateTime(2026, 9, 1)),
        _photo(6, DateTime(2026, 1, 5)),
        _photo(7, DateTime(2025, 12, 31)),
      ];
      final groups = groupPhotosByDate(photos, now);
      expect([for (final g in groups) g.label], ['Today', 'Yesterday', 'This month', 'September', 'January', 'December 2025']);
      expect([for (final g in groups) g.count], [2, 1, 1, 2, 1, 1]);
      expect(groups.last.end, photos.length);
      for (var i = 1; i < groups.length; i++) {
        expect(groups[i].start, groups[i - 1].end, reason: 'contiguous');
      }
    });

    test('on the first of the month Yesterday belongs to last month and This month is empty', () {
      final first = DateTime(2026, 11, 1, 10);
      final groups = groupPhotosByDate([
        _photo(0, DateTime(2026, 11, 1, 7)),
        _photo(1, DateTime(2026, 10, 31, 20)),
        _photo(2, DateTime(2026, 10, 30, 20)),
      ], first);
      expect([for (final g in groups) g.label], ['Today', 'Yesterday', 'October']);
    });

    test('no photos, no groups', () {
      expect(groupPhotosByDate(const [], now), isEmpty);
      expect(photosGridModelOf(const [], now).isEmpty, isTrue);
    });

    test('mergeNewestFirst keeps both lists in date order', () {
      final a = synthetic(50, step: const Duration(hours: 5));
      final b = synthetic(30, from: DateTime(2026, 10, 22, 17), step: const Duration(hours: 9));
      final merged = mergeNewestFirst(a, b);
      expect(merged, hasLength(80));
      for (var i = 1; i < merged.length; i++) {
        expect(merged[i - 1].date.isBefore(merged[i].date), isFalse);
      }
    });
  });

  group('masonry layout', () {
    PhotoMasonryLayout layoutOf(List<PhotoGridItem> photos, {double width = 402, int columns = 3}) {
      final model = photosGridModelOf(photos, DateTime(2026, 10, 22, 20));
      return PhotoMasonryLayout.compute(
        buckets: model.buckets,
        groups: model.groups,
        width: width,
        columns: columns,
        headerExtent: 44,
        padding: 12,
      );
    }

    test('headers span the width; photos fill columns without overlapping; tops never decrease', () {
      final photos = synthetic(400);
      final l = layoutOf(photos);
      final groups = photosGridModelOf(photos, DateTime(2026, 10, 22, 20)).groups;
      expect(l.childCount, photos.length + groups.length);
      expect(l.photoCount, photos.length);
      expect(l.groupCount, groups.length);
      var headers = 0;
      for (var i = 0; i < l.childCount; i++) {
        if (i > 0) expect(l.topOf(i), greaterThanOrEqualTo(l.topOf(i - 1)), reason: 'top of $i');
        if (l.isHeader(i)) {
          headers++;
          expect(l.widthOf(i), 402);
          expect(l.heightOf(i), 44);
          // Every earlier child ends above the header.
          for (var j = math.max(0, i - 60); j < i; j++) {
            expect(l.bottomOf(j), lessThanOrEqualTo(l.topOf(i) + 1e-6));
          }
        } else {
          final p = l.photoOf(i);
          expect(l.childOfPhoto(p), i);
          expect(l.widthOf(i), closeTo(l.cellWidth, 1e-9));
          expect(l.heightOf(i), closeTo(l.cellWidth * photos[p].bucket.heightPerWidth, 1e-9));
          expect(l.leftOf(i), greaterThanOrEqualTo(12 - 1e-9));
          expect(l.leftOf(i) + l.widthOf(i), lessThanOrEqualTo(402 - 12 + 1e-6));
        }
      }
      expect(headers, groups.length);
      for (var i = 0; i < l.childCount; i++) {
        for (var j = i + 1; j < math.min(l.childCount, i + 40); j++) {
          expect(_overlaps(l, i, j), isFalse, reason: '$i and $j overlap');
        }
      }
      expect(l.totalExtent, greaterThanOrEqualTo(l.bottomOf(l.childCount - 1)));
    });

    test('visible ranges contain exactly the children a brute-force scan finds', () {
      final l = layoutOf(synthetic(1500), width: 1280, columns: 9);
      final random = math.Random(7);
      for (var q = 0; q < 300; q++) {
        final start = random.nextDouble() * l.totalExtent;
        final end = start + 200 + random.nextDouble() * 900;
        final range = l.visibleRange(start, end)!;
        for (var i = 0; i < l.childCount; i++) {
          final visible = l.bottomOf(i) > start && l.topOf(i) < end;
          if (visible) {
            expect(i, inInclusiveRange(range.$1, range.$2), reason: 'child $i at $start..$end');
          }
        }
        expect(l.bottomOf(range.$1), greaterThan(start));
        expect(l.topOf(range.$2) < end || range.$1 == range.$2, isTrue);
      }
      expect(l.visibleRange(l.totalExtent + 10, l.totalExtent + 500), isNull);
    });

    test('an empty library has no children and no extent', () {
      final l = PhotoMasonryLayout.compute(buckets: Uint8List(0), groups: const [], width: 320, columns: 2, headerExtent: 44);
      expect(l.childCount, 0);
      expect(l.totalExtent, 0);
      expect(l.visibleRange(0, 600), isNull);
    });

    test('columns follow the width and the density; cells stay ≥ 80 px so 16:9 cells are ≥ 44 px tall', () {
      for (final width in [256.0, 296.0, 351.0, 744.0, 850.0, 1256.0]) {
        var previous = 0;
        for (var d = 0; d < photoGridDensityTargets.length; d++) {
          final c = photoGridColumnsFor(width, d);
          expect(c, greaterThanOrEqualTo(previous), reason: 'denser levels never have fewer columns');
          previous = c;
          expect(c, inInclusiveRange(2, 12));
          final cell = (width - 2 * (c - 1)) / c;
          if (c > 2) expect(cell, greaterThanOrEqualTo(photoGridMinCellWidth));
          expect(cell * PhotoAspectBucket.wide.heightPerWidth, greaterThanOrEqualTo(44), reason: '$width @ $d');
        }
      }
    });
  });

  test('50,000 synthetic items: visible ranges in ≤ 1 ms', () {
    final photos = synthetic(50000, step: const Duration(minutes: 37));
    final model = photosGridModelOf(photos, DateTime(2026, 10, 22, 20));
    PhotoMasonryLayout build() => PhotoMasonryLayout.compute(
          buckets: model.buckets,
          groups: model.groups,
          width: 402,
          columns: 4,
          headerExtent: 44,
          padding: 12,
        );
    // Warm up the JIT, then take the best of a few full passes (the cost of a width or density change).
    build();
    var bestBuild = Duration.zero;
    late PhotoMasonryLayout l;
    for (var i = 0; i < 5; i++) {
      final sw = Stopwatch()..start();
      l = build();
      sw.stop();
      if (i == 0 || sw.elapsed < bestBuild) bestBuild = sw.elapsed;
    }
    expect(l.photoCount, 50000);
    final random = math.Random(42);
    var worst = 0;
    var total = 0;
    final samples = <int>[];
    const queries = 2000;
    for (var q = 0; q < queries; q++) {
      final start = random.nextDouble() * l.totalExtent;
      final sw = Stopwatch()..start();
      final range = l.visibleRange(start, start + 874 + 250);
      sw.stop();
      expect(range, isNotNull);
      samples.add(sw.elapsedMicroseconds);
      worst = math.max(worst, sw.elapsedMicroseconds);
      total += sw.elapsedMicroseconds;
    }
    samples.sort();
    final p99 = samples[(queries * 0.99).floor()];
    // ignore: avoid_print
    print('HOM-10 50k layout: full pass ${bestBuild.inMicroseconds} µs; visible range p99 $p99 µs, worst $worst µs, mean ${(total / queries).toStringAsFixed(2)} µs');
    // A single sample can include a GC pause on a loaded machine; the p99 and the mean are the query cost.
    expect(p99, lessThanOrEqualTo(1000), reason: 'visible range ≤ 1 ms');
    expect(total / queries, lessThan(100));
    expect(bestBuild.inMilliseconds, lessThan(100), reason: 'the full pass runs only on a width, density or data change');
  });
}
