// OWNER: HOM-20
//
// BUILD_PLAN HOM-20: a 2 GB import keeps memory flat (ARCH v1.2 §10 "Import copy"). The source is a
// generated sparse file (local test media only). FIX-S2Q-6: `dart test` runs suites as isolates of
// one VM, so the VM's resident set also grows with whatever runs next to this suite (it failed at
// +76.9 MB next to `property_test` under -j 2). The import therefore runs in a child process of its
// own (import_memory_child.dart), which measures its own growth from a baseline taken after a
// warm-up import to the peak while the worker isolate streams the file with one 1 MiB buffer.
// The default size is 2 GiB; set DV_IMPORT_TEST_BYTES to run smaller (e.g. on a machine without
// the free disk space), and the copy throughput is printed against a plain `cp` of the same file
// for the §10 budget.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import 'import_harness.dart';

const String _child = 'test/import/import_memory_child.dart';

void main() {
  final size = int.tryParse(Platform.environment['DV_IMPORT_TEST_BYTES'] ?? '') ?? 2 * 1024 * 1024 * 1024;

  test('a ${size >> 20} MiB import keeps memory flat', () async {
    final script = File(_child);
    expect(script.existsSync(), isTrue, reason: 'run from the danaview_library package root');
    final src = tempDir('hom20_big_src_');
    final root = tempDir('hom20_big_lib_').path;
    final file = File('${src.path}/Big Video.mov');
    final raf = file.openSync(mode: FileMode.write);
    raf.truncateSync(size); // sparse: no disk use for the source
    raf.setPositionSync(size - 4);
    raf.writeFromSync(const [1, 2, 3, 4]);
    raf.closeSync();
    final warm = sourceFile(src, 'Warm.mov', bytesOf(4 * 1024 * 1024, seed: 5));

    final packages = await Isolate.packageConfig;
    final run = await Process.run(Platform.resolvedExecutable, [
      if (packages != null) '--packages=${packages.toFilePath()}',
      script.path,
      file.path,
      warm.path,
      root,
    ]);
    final line = LineSplitter.split(run.stdout as String).where((l) => l.startsWith('DV_IMPORT_RSS ')).firstOrNull;
    expect(run.exitCode, 0, reason: 'child failed: ${run.stderr}');
    expect(line, isNotNull, reason: 'child printed no measurement');
    final m = jsonDecode(line!.substring('DV_IMPORT_RSS '.length)) as Map<String, Object?>;
    expect(m['state'], 'done');
    expect(m['size'], size);
    final growthMb = ((m['peak']! as int) - (m['baseline']! as int)) / (1024 * 1024);
    expect(growthMb, lessThan(64), reason: 'the import process grew by ${growthMb.toStringAsFixed(1)} MB');

    // Throughput against `cp` (informational; the §10 budget is measured on the device tiers). The
    // library copy goes first, so the disk holds at most one real copy at a time.
    Directory(root).deleteSync(recursive: true);
    final cpWatch = Stopwatch()..start();
    final cp = Process.runSync('cp', [file.path, '${src.path}/cp.out']);
    cpWatch.stop();
    if (cp.exitCode == 0) {
      File('${src.path}/cp.out').deleteSync();
      // ignore: avoid_print
      print('import ${m['ms']} ms, cp ${cpWatch.elapsedMilliseconds} ms, rss growth ${growthMb.toStringAsFixed(1)} MB');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
