// OWNER: UX-10
//
// ParagraphCache (ux.md §17.5): 512-entry LRU keyed by (text, style, 8 px width bucket), cleared on
// a text-scale change and on memory pressure.

import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/caches/paragraph_cache.dart';

const _style = TimelineTextStyle(fontFamily: 'Ahem', fontSize: 11, color: Color(0xFFFFFFFF));

void main() {
  test('width buckets round down to 8 px; infinite stays infinite; under one bucket is empty', () {
    expect(ParagraphCache.bucketWidth(100), 96);
    expect(ParagraphCache.bucketWidth(103.9), 96);
    expect(ParagraphCache.bucketWidth(104), 104);
    expect(ParagraphCache.bucketWidth(7.9), 0);
    expect(ParagraphCache.bucketWidth(double.infinity), double.infinity);
  });

  test('hits within a bucket, misses across buckets and styles', () {
    final cache = ParagraphCache();
    final a = cache.paragraph('beach.mp4', _style, maxWidth: 100)!;
    final b = cache.paragraph('beach.mp4', _style, maxWidth: 101)!;
    expect(identical(a, b), isTrue);
    expect(a.width, 96, reason: 'laid out at the bucket, never wider than asked');
    expect(cache.hits, 1);
    expect(cache.misses, 1);
    cache.paragraph('beach.mp4', _style, maxWidth: 120);
    cache.paragraph('beach.mp4', _style.copyWith(fontSize: 14), maxWidth: 100);
    expect(cache.misses, 3);
    expect(cache.length, 3);
    expect(cache.paragraph('x', _style, maxWidth: 4), isNull);
  });

  test('long text is ellipsized at the bucket width', () {
    final cache = ParagraphCache();
    final p = cache.paragraph('a very long clip name that cannot fit', _style, maxWidth: 64)!;
    expect(p.didExceedMaxLines, isTrue);
    expect(p.longestLine, lessThanOrEqualTo(64));
  });

  test('LRU of 512 entries evicts the least recently used', () {
    final cache = ParagraphCache();
    expect(cache.capacity, 512);
    for (var i = 0; i < 512; i++) {
      cache.paragraph('t$i', _style);
    }
    cache.paragraph('t0', _style); // touch: t1 is now the oldest
    cache.paragraph('new', _style);
    expect(cache.length, 512);
    expect(cache.contains('t0', _style), isTrue);
    expect(cache.contains('t1', _style), isFalse);
    expect(cache.contains('new', _style), isTrue);
  });

  test('a text-scale change and memory pressure clear the cache', () {
    final cache = ParagraphCache()..setTextScale(1);
    cache.paragraph('a', _style);
    cache.setTextScale(1);
    expect(cache.length, 1);
    cache.setTextScale(1.35);
    expect(cache.length, 0);
    cache.paragraph('a', _style);
    cache.onMemoryPressure();
    expect(cache.length, 0);
  });
}
