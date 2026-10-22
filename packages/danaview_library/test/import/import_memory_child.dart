// OWNER: HOM-20
//
// The child process of import_memory_test.dart (FIX-S2Q-6). `dart test` runs suites as isolates of
// one VM, so `ProcessInfo.currentRss` there is shared with whatever else runs; this program imports
// the big file alone in its own VM and prints its own resident-set baseline and peak. The baseline
// is taken after a warm-up import (the copier isolate, sqlite and the import code are loaded), the
// peak sampled on every progress row and every 20 ms. Output: one line
// `DV_IMPORT_RSS {"baseline":…,"peak":…,"ms":…,"state":…,"size":…}`. No names or paths are printed
// (rule 30).
//
// Usage: dart run test/import/import_memory_child.dart <bigSource> <warmSource> <libraryRoot>

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:danaview_library/testing.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('usage: import_memory_child <bigSource> <warmSource> <libraryRoot>');
    exit(64);
  }
  final [big, warm, root] = args;
  final store = await LibraryStore.open(root: root, clock: FakeLibraryClock(DateTime.utc(2026, 10, 22, 9)).call, background: false);
  final service = ImportService(store: store);
  try {
    // Warm-up: the same path end to end on a small file.
    final w = (await service.importAll([ImportSource.file(warm, uti: 'com.apple.quicktime-movie')])).single;
    if (w.state != ImportItemState.done) throw StateError('warm-up import ${w.state.name}');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    var baseline = ProcessInfo.currentRss;
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final rss = ProcessInfo.currentRss;
      if (rss > baseline) baseline = rss;
    }

    var peak = baseline;
    void sample() {
      final rss = ProcessInfo.currentRss;
      if (rss > peak) peak = rss;
    }

    final sub = service.updates.listen((_) => sample());
    final timer = Timer.periodic(const Duration(milliseconds: 20), (_) => sample());
    final watch = Stopwatch()..start();
    final item = (await service.importAll([ImportSource.file(big, uti: 'com.apple.quicktime-movie')])).single;
    watch.stop();
    sample();
    timer.cancel();
    await sub.cancel();
    stdout.writeln('DV_IMPORT_RSS ${jsonEncode({
          'baseline': baseline,
          'peak': peak,
          'ms': watch.elapsedMilliseconds,
          'state': item.state.name,
          'size': item.entry?.sizeBytes ?? -1,
        })}');
  } finally {
    await service.dispose();
    await store.close();
  }
}
