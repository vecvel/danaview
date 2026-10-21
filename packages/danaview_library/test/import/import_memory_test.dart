// OWNER: HOM-20
//
// BUILD_PLAN HOM-20: a 2 GB import keeps memory flat (ARCH v1.2 §10 "Import copy"). The source is a
// generated sparse file (local test media only); the resident set is sampled on every progress row
// while the worker isolate streams it with one 1 MiB buffer. The default size is 2 GiB; set
// DV_IMPORT_TEST_BYTES to run smaller (e.g. on a machine without the free disk space), and the
// copy throughput is printed against a plain `cp` of the same file for the §10 budget.

import 'dart:io';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import 'import_harness.dart';

void main() {
  final size = int.tryParse(Platform.environment['DV_IMPORT_TEST_BYTES'] ?? '') ?? 2 * 1024 * 1024 * 1024;

  test('a ${size >> 20} MiB import keeps memory flat', () async {
    final src = tempDir('hom20_big_src_');
    final root = tempDir('hom20_big_lib_').path;
    final file = File('${src.path}/Big Video.mov');
    final raf = file.openSync(mode: FileMode.write);
    raf.truncateSync(size); // sparse: no disk use for the source
    raf.setPositionSync(size - 4);
    raf.writeFromSync(const [1, 2, 3, 4]);
    raf.closeSync();

    final store = await openStore(root);
    addTearDown(store.close);
    final service = ImportService(store: store);
    final baseline = ProcessInfo.currentRss;
    var peak = baseline;
    service.updates.listen((_) {
      final rss = ProcessInfo.currentRss;
      if (rss > peak) peak = rss;
    });
    final watch = Stopwatch()..start();
    final item = (await service.importAll([ImportSource.file(file.path, uti: 'com.apple.quicktime-movie')])).single;
    watch.stop();
    expect(item.state, ImportItemState.done);
    expect(item.entry!.sizeBytes, size);
    final growthMb = (peak - baseline) / (1024 * 1024);
    expect(growthMb, lessThan(64), reason: 'resident set grew by ${growthMb.toStringAsFixed(1)} MB');

    // Throughput against `cp` (informational; the §10 budget is measured on the device tiers).
    File(store.paths.entryFile(item.entry!.id, item.entry!.displayName)).deleteSync();
    final cpWatch = Stopwatch()..start();
    final cp = Process.runSync('cp', [file.path, '${src.path}/cp.out']);
    cpWatch.stop();
    if (cp.exitCode == 0) {
      File('${src.path}/cp.out').deleteSync();
      // ignore: avoid_print
      print('import ${watch.elapsedMilliseconds} ms, cp ${cpWatch.elapsedMilliseconds} ms, rss growth ${growthMb.toStringAsFixed(1)} MB');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
