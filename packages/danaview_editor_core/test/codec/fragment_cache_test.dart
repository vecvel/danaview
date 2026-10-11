// OWNER: CORE-22
//
// FragmentCache (ARCH §8.3): re-encoding after a one-item edit re-serializes only the changed
// item, its track and the small root objects, gives exactly the bytes of a cold encode, and takes
// ≤ 3 ms at 2,000 items (BUILD_PLAN CORE-22; median of warm runs, numbers printed).

import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/model.dart';

import '../support/random_project.dart';
import 'support/codec_projects.dart';

/// Budget for the incremental re-encode after a one-item edit at 2,000 items.
const int budgetUs = 3000;

int medianUs(List<int> samples) {
  final s = List.of(samples)..sort();
  return s[s.length ~/ 2];
}

/// [base] after a typical committed one-item edit: item [index] of track [trackIndex] gets a new
/// volume/label, the track is re-stamped, the timeline revision and the meta (updatedAt,
/// editCount) and docRevision advance; everything else is shared (structural sharing).
EditProject oneItemEdit(EditProject base, int trackIndex, int index, int n) {
  final track = base.tracks[trackIndex];
  final items = List.of(track.items);
  final item = items[index];
  items[index] = switch (item) {
    MediaClip() => item.copyWith(audio: item.audio.copyWith(volume: 0.5 + (n % 100) / 100), label: 'edit $n'),
    TextItem() => item.copyWith(text: '${item.text} $n'),
    SubtitleCue() => item.copyWith(text: '${item.text} $n'),
  };
  final stamp = base.revision + 1 + n;
  final tracks = List.of(base.tracks)..[trackIndex] = track.copyWith(items: items, changedAt: stamp);
  return base.copyWith(
    timeline: base.timeline.copyWith(tracks: tracks, revision: stamp),
    meta: base.meta.copyWith(updatedAt: base.meta.updatedAt.add(Duration(seconds: n + 1)), editCount: base.meta.editCount + 1),
    docRevision: base.docRevision + 1,
  );
}

void main() {
  test('FragmentCache stores by identity and counts hits and misses', () {
    final cache = FragmentCache();
    final a = Marker(id: const MarkerId('mk_a'), time: 0);
    final b = Marker(id: const MarkerId('mk_a'), time: 0);
    var calls = 0;
    String enc() => 'x${calls++}';
    expect(cache.fragment(a, enc), 'x0');
    expect(cache.fragment(a, enc), 'x0');
    expect(cache.fragment(b, enc), 'x1', reason: 'an equal but distinct object is a different key');
    expect(cache.stats.hits, 1);
    expect(cache.stats.misses, 2);
    expect(cache.peek(a), 'x0');
    cache.invalidate(a);
    expect(cache.peek(a), isNull);
    cache.resetStats();
    expect(cache.stats.hits + cache.stats.misses, 0);
  });

  group('incremental encoding', () {
    final base = decoratedRandomProject(5, const RandomProjectSpec(items: 400));

    test('a warm re-encode after a one-item edit equals a cold encode and touches only the changed nodes', () {
      final codec = ProjectJsonCodec();
      codec.encode(base);
      final rnd = Random(3);
      for (var n = 0; n < 50; n++) {
        final t = rnd.nextInt(base.tracks.length);
        if (base.tracks[t].items.isEmpty) continue;
        final edited = oneItemEdit(base, t, rnd.nextInt(base.tracks[t].items.length), n);
        codec.cache.resetStats();
        final warm = codec.encode(edited);
        expect(warm, ProjectJsonCodec().encode(edited), reason: 'edit $n');
        expect(warm, jsonEncode(codec.toJson(edited)), reason: 'edit $n');
        // Re-encoded: the edited item, its track and the meta. Everything else is a hit.
        expect(codec.cache.stats.misses, 3, reason: 'edit $n re-encoded ${codec.cache.stats.misses} nodes');
        final others = base.tracks.length - 1 + base.markers.length + 3; // other tracks, markers, settings, pool, view
        expect(codec.cache.stats.hits, others + base.tracks[t].items.length - 1, reason: 'edit $n');
      }
    });

    test('pool, view and settings changes re-encode only themselves', () {
      final codec = ProjectJsonCodec()..encode(base);
      final asset = base.pool.assets.values.first;
      final pooled = base.copyWith(pool: base.pool.upsert(asset.copyWith(proxy: ProxyState.ready)), docRevision: base.docRevision + 1);
      codec.cache.resetStats();
      expect(codec.encode(pooled), ProjectJsonCodec().encode(pooled));
      expect(codec.cache.stats.misses, 2, reason: 'the changed asset and the pool');
      final viewed = pooled.copyWith(view: pooled.view.copyWith(playhead: 1000000), docRevision: pooled.docRevision + 1);
      codec.cache.resetStats();
      expect(codec.encode(viewed), ProjectJsonCodec().encode(viewed));
      expect(codec.cache.stats.misses, 1, reason: 'the view');
    });

    test('undo back to a cached snapshot is a full cache hit', () {
      final codec = ProjectJsonCodec();
      final before = codec.encode(base);
      codec.encode(oneItemEdit(base, 0, 0, 1));
      codec.cache.resetStats();
      expect(codec.encode(base), before);
      expect(codec.cache.stats.misses, 0);
    });
  });

  group('budget (2,000 items)', () {
    final base = decoratedRandomProject(11, const RandomProjectSpec(items: 2100));
    final count = base.index.itemCount;

    test('the benchmark project has at least 2,000 items', () {
      expect(count, inInclusiveRange(2000, 2600));
    });

    test('incremental re-encode after a one-item edit ≤ 3 ms', () {
      final codec = ProjectJsonCodec();
      final rnd = Random(7);
      // Each sample edits a random item of the busiest lanes (the main lane holds a double share).
      List<EditProject> edits(int n, int offset) => [
            for (var i = 0; i < n; i++)
              () {
                var t = rnd.nextInt(base.tracks.length);
                while (base.tracks[t].items.isEmpty) {
                  t = rnd.nextInt(base.tracks.length);
                }
                return oneItemEdit(base, t, rnd.nextInt(base.tracks[t].items.length), offset + i);
              }(),
          ];
      final cold = Stopwatch()..start();
      final full = codec.encode(base);
      cold.stop();
      // Warm up the JIT on the incremental path.
      for (final p in edits(60, 0)) {
        codec.encode(p);
      }
      final samples = <int>[];
      final mainLane = <int>[];
      final sw = Stopwatch();
      for (final p in edits(101, 1000)) {
        sw
          ..reset()
          ..start();
        codec.encode(p);
        sw.stop();
        samples.add(sw.elapsedMicroseconds);
      }
      // Worst case: always the largest lane.
      final largest = [for (var i = 0; i < base.tracks.length; i++) i]
          .reduce((a, b) => base.tracks[a].items.length >= base.tracks[b].items.length ? a : b);
      for (var i = 0; i < 101; i++) {
        final p = oneItemEdit(base, largest, rnd.nextInt(base.tracks[largest].items.length), 5000 + i);
        sw
          ..reset()
          ..start();
        codec.encode(p);
        sw.stop();
        mainLane.add(sw.elapsedMicroseconds);
      }
      final median = medianUs(samples);
      final medianLargest = medianUs(mainLane);
      // ignore: avoid_print
      print('project encode ($count items, ${(full.length / 1024).toStringAsFixed(0)} KiB): '
          'cold ${(cold.elapsedMicroseconds / 1000).toStringAsFixed(2)} ms; '
          'one-item edit median ${(median / 1000).toStringAsFixed(3)} ms, '
          'largest lane (${base.tracks[largest].items.length} items) median ${(medianLargest / 1000).toStringAsFixed(3)} ms');
      expect(median, lessThanOrEqualTo(budgetUs));
      expect(medianLargest, lessThanOrEqualTo(budgetUs));
    });
  });
}
