// OWNER: CORE-37
//
// RenderCacheIndex (ARCH D-45(A), §9.6, §17.10): lookup / put / touch, LRU bound, trim, clear and
// bytes; deletes only inside renders/ through OwnedFileDeleter; a corrupt index is rebuilt and
// orphan files removed; a crash at every filesystem step (FaultInjectingFs, every torn-write
// mode) leaves a state the next open repairs, within the LRU bound and without touching anything
// outside renders/.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String h(Object seed) => sha256.convert(utf8.encode('$seed')).toString();

/// A temporary app container with sentinel files outside renders/.
final class Box {
  Box._(this.dir, this.roots);

  factory Box.create() {
    final dir = Directory.systemTemp.createTempSync('render_cache_');
    final roots = StoreRoots(
      support: p.join(dir.path, 'support'),
      cache: p.join(dir.path, 'cache'),
      documents: p.join(dir.path, 'documents'),
    );
    final box = Box._(dir, roots);
    for (final s in box.sentinels) {
      File(s).createSync(recursive: true);
      File(s).writeAsStringSync('keep ${p.basename(s)}');
    }
    return box;
  }

  final Directory dir;
  final StoreRoots roots;

  String get renders => p.join(roots.editorCache, 'renders');

  /// Files next to and around renders/ that the cache must never touch.
  List<String> get sentinels => [
        p.join(roots.editorCache, 'proxies', 'qh_a-540.mp4'),
        p.join(roots.editorCache, 'renders_other', 'x.mp4'),
        p.join(roots.editorCache, 'index.json'),
        p.join(roots.cache, 'other.bin'),
        p.join(roots.editorSupport, 'projects', 'p1', 'project.dnproj'),
        p.join(roots.documents, 'Movies', 'clip.mp4'),
      ];

  void expectSentinelsIntact() {
    for (final s in sentinels) {
      expect(File(s).readAsStringSync(), 'keep ${p.basename(s)}', reason: s);
    }
  }

  /// Simulates the renderer writing [bytes] bytes for [hash] at the staging path.
  String stage(RenderCacheIndex index, String hash, int bytes) {
    final path = index.stagingPathFor(hash);
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(Uint8List(bytes));
    return path;
  }

  List<String> rendersListing() => Directory(renders).existsSync()
      ? (Directory(renders).listSync().map((e) => p.basename(e.path)).toList()..sort())
      : const [];

  void dispose() => dir.deleteSync(recursive: true);
}

final class Clock {
  DateTime t = DateTime.utc(2026, 10, 14);
  DateTime call() => t = t.add(const Duration(seconds: 1));
}

RenderCacheIndex makeIndex(Box box, StoreFs fs, {int limit = 1000, Clock? clock, bool assertOnViolation = true}) => RenderCacheIndex(
      roots: box.roots,
      deleter: OwnedFileDeleter(box.roots, fs: fs, assertOnViolation: assertOnViolation),
      fs: fs,
      limitBytes: limit,
      now: (clock ?? Clock()).call,
      random: Random(7),
    );

/// Invariants after an open: every entry has its file at the indexed size, renders/ holds only
/// entry files and index files, the total is within the limit, and nothing else was touched.
void expectConsistent(Box box, RenderCacheIndex index) {
  final names = box.rendersListing();
  for (final e in index.entries) {
    final file = File(index.pathFor(e.hash));
    expect(file.existsSync(), isTrue, reason: 'entry ${e.hash} has its file');
    expect(file.lengthSync(), e.bytes);
  }
  final allowed = {for (final e in index.entries) '${e.hash}.mp4'};
  for (final n in names) {
    expect(n == 'index.json' || n.startsWith('index.json.') || allowed.contains(n), isTrue, reason: 'orphan $n');
  }
  expect(index.indexedBytes, lessThanOrEqualTo(index.limitBytes));
  box.expectSentinelsIntact();
}

void main() {
  late Box box;
  setUp(() => box = Box.create());
  tearDown(() => box.dispose());

  group('basic operations', () {
    test('open creates renders/; put, lookup, contains, touch, bytes', () async {
      final index = makeIndex(box, const LocalStoreFs());
      await index.open();
      expect(Directory(box.renders).existsSync(), isTrue);
      expect(index.rendersDir, p.join(box.roots.cache, 'danaview', 'editor', 'renders'));
      expect(index.indexPath, p.join(index.rendersDir, 'index.json'));
      expect(await index.lookup(h(1)), isNull);

      await index.put(h(1), box.stage(index, h(1), 100));
      expect(index.contains(h(1)), isTrue);
      expect(await index.lookup(h(1)), index.pathFor(h(1)));
      expect(File(index.stagingPathFor(h(1))).existsSync(), isFalse, reason: 'staged file moved into place');
      expect(index.indexedBytes, 100);
      final onDisk = Directory(box.renders).listSync().whereType<File>().fold<int>(0, (s, f) => s + f.lengthSync());
      expect(await index.bytes(), onDisk, reason: 'render files plus the index files');
      expect(onDisk, greaterThan(100));

      // A second index on the same directory sees the entry.
      final again = makeIndex(box, const LocalStoreFs());
      await again.open();
      expect(again.contains(h(1)), isTrue);
      expect(again.entries.single.bytes, 100);
      box.expectSentinelsIntact();
    });

    test('re-putting a hash replaces its file', () async {
      final index = makeIndex(box, const LocalStoreFs());
      await index.open();
      await index.put(h(1), box.stage(index, h(1), 100));
      await index.put(h(1), box.stage(index, h(1), 120));
      expect(index.entries.single.bytes, 120);
      expect(File(index.pathFor(h(1))).lengthSync(), 120);
    });

    test('lookup of an entry whose file vanished drops it', () async {
      final index = makeIndex(box, const LocalStoreFs());
      await index.open();
      await index.put(h(1), box.stage(index, h(1), 100));
      File(index.pathFor(h(1))).deleteSync();
      expect(await index.lookup(h(1)), isNull);
      expect(index.contains(h(1)), isFalse);
    });

    test('limits per tier: 512 MB on minimal/low, 1 GB on mid/high', () {
      expect(RenderCacheIndex.limitForTier(RenderTier.minimal), 512 * 1024 * 1024);
      expect(RenderCacheIndex.limitForTier(RenderTier.low), 512 * 1024 * 1024);
      expect(RenderCacheIndex.limitForTier(RenderTier.mid), 1024 * 1024 * 1024);
      expect(RenderCacheIndex.limitForTier(RenderTier.high), 1024 * 1024 * 1024);
    });

    test('rejects malformed hashes and staged files outside renders/', () async {
      final index = makeIndex(box, const LocalStoreFs());
      await index.open();
      expect(() => index.pathFor('../../escape'), throwsArgumentError);
      expect(() => index.pathFor(h(1).toUpperCase()), throwsArgumentError);
      final outside = p.join(box.roots.editorCache, 'proxies', 'qh_a-540.mp4');
      await expectLater(index.put(h(2), outside), throwsA(isA<OwnershipViolation>()));
      box.expectSentinelsIntact();
    });

    test('operations before open fail', () async {
      final index = makeIndex(box, const LocalStoreFs());
      await expectLater(index.lookup(h(1)), throwsStateError);
    });
  });

  group('LRU bound', () {
    test('evicts least recently used entries to the limit; touch refreshes', () async {
      final index = makeIndex(box, const LocalStoreFs(), limit: 1000);
      await index.open();
      for (var i = 1; i <= 3; i++) {
        await index.put(h(i), box.stage(index, h(i), 300));
      }
      await index.touch(h(1)); // order now 1, 3, 2
      await index.put(h(4), box.stage(index, h(4), 300));
      expect(index.contains(h(2)), isFalse, reason: 'least recently used');
      expect([h(1), h(3), h(4)].every(index.contains), isTrue);
      expect(File(index.pathFor(h(2))).existsSync(), isFalse);
      expect(index.indexedBytes, 900);
      expect(index.entries.first.hash, h(4));
      expectConsistent(box, index);
    });

    test('a file larger than the limit is not kept', () async {
      final index = makeIndex(box, const LocalStoreFs(), limit: 1000);
      await index.open();
      await index.put(h(1), box.stage(index, h(1), 400));
      await index.put(h(2), box.stage(index, h(2), 1500));
      expect(index.contains(h(2)), isFalse);
      expect(index.contains(h(1)), isTrue);
      expectConsistent(box, index);
    });

    test('a lower limit (tier change) evicts on setLimit and on open', () async {
      final index = makeIndex(box, const LocalStoreFs(), limit: 1000);
      await index.open();
      for (var i = 1; i <= 3; i++) {
        await index.put(h(i), box.stage(index, h(i), 300));
      }
      await index.setLimit(700);
      expect(index.indexedBytes, 600);
      final smaller = makeIndex(box, const LocalStoreFs(), limit: 300);
      await smaller.open();
      expect(smaller.entries.single.hash, h(3));
      expectConsistent(box, smaller);
    });

    test('trim levels: memory pressure -> half, low disk -> quarter, critical -> empty', () async {
      final index = makeIndex(box, const LocalStoreFs(), limit: 1000);
      await index.open();
      for (var i = 1; i <= 4; i++) {
        await index.put(h(i), box.stage(index, h(i), 200));
      }
      await index.trim(RenderCacheTrimLevel.memoryPressure);
      expect(index.indexedBytes, 400);
      await index.trim(RenderCacheTrimLevel.lowDisk);
      expect(index.indexedBytes, 200);
      expect(index.entries.single.hash, h(4));
      await index.trim(RenderCacheTrimLevel.critical);
      expect(index.entries, isEmpty);
      expectConsistent(box, index);
    });
  });

  group('clear', () {
    test('removes everything inside renders/ and nothing else', () async {
      final index = makeIndex(box, const LocalStoreFs());
      await index.open();
      await index.put(h(1), box.stage(index, h(1), 100));
      box.stage(index, h(2), 50); // an in-flight partial
      Directory(p.join(box.renders, 'stray_dir')).createSync();
      File(p.join(box.renders, 'stray_dir', 'x')).writeAsStringSync('x');
      await index.clear();
      expect(box.rendersListing(), isEmpty);
      expect(index.entries, isEmpty);
      expect(await index.bytes(), 0);
      box.expectSentinelsIntact();
    });

    test('a symbolic link inside renders/ to a file outside is never followed', () async {
      final index = makeIndex(box, const LocalStoreFs(), assertOnViolation: false);
      await index.open();
      final target = p.join(box.roots.documents, 'Movies', 'clip.mp4');
      Link(p.join(box.renders, 'evil.mp4')).createSync(target);
      await expectLater(index.clear(), throwsA(isA<OwnershipViolation>()));
      box.expectSentinelsIntact();
    });

    test('clear on a missing directory is a no-op', () async {
      final index = makeIndex(box, const LocalStoreFs());
      await index.clear();
      expect(Directory(box.renders).existsSync(), isFalse);
      expect(await index.bytes(), 0);
    });
  });

  group('repair', () {
    test('a corrupt index is rebuilt from complete files; orphans are removed', () async {
      final index = makeIndex(box, const LocalStoreFs());
      await index.open();
      await index.put(h(1), box.stage(index, h(1), 100));
      await index.put(h(2), box.stage(index, h(2), 200));
      File(index.indexPath).writeAsStringSync('{not json');
      for (final f in Directory(box.renders).listSync()) {
        if (p.basename(f.path).startsWith('index.json.')) f.deleteSync();
      }
      box.stage(index, h(3), 70); // partial
      File(p.join(box.renders, 'notes.txt')).writeAsStringSync('stray');
      File(p.join(box.renders, 'ABC.mp4')).writeAsStringSync('bad name');
      final rebuilt = makeIndex(box, const LocalStoreFs());
      await rebuilt.open();
      expect(rebuilt.entries.map((e) => e.hash).toSet(), {h(1), h(2)});
      expect(rebuilt.indexedBytes, 300);
      expectConsistent(box, rebuilt);
      expect(box.rendersListing().where((n) => !n.startsWith('index.json')), ['${h(1)}.mp4', '${h(2)}.mp4']..sort());
    });

    test('with a valid index, unknown files and size mismatches are removed and missing files dropped', () async {
      final index = makeIndex(box, const LocalStoreFs());
      await index.open();
      await index.put(h(1), box.stage(index, h(1), 100));
      await index.put(h(2), box.stage(index, h(2), 200));
      await index.put(h(3), box.stage(index, h(3), 300));
      File(index.pathFor(h(1))).deleteSync(); // missing
      File(index.pathFor(h(2))).writeAsBytesSync(Uint8List(10)); // truncated
      File(p.join(box.renders, '${h(9)}.mp4')).writeAsBytesSync(Uint8List(5)); // un-indexed
      final repaired = makeIndex(box, const LocalStoreFs());
      await repaired.open();
      expect(repaired.entries.map((e) => e.hash), [h(3)]);
      expectConsistent(box, repaired);
    });
  });

  group('crash safety', () {
    Future<void> scenario(Box box, RenderCacheIndex index) async {
      await index.open();
      await index.put(h(1), box.stage(index, h(1), 300));
      await index.put(h(2), box.stage(index, h(2), 300));
      await index.touch(h(1));
      await index.put(h(3), box.stage(index, h(3), 300)); // evicts h(2) at limit 800
      await index.lookup(h(3));
      await index.trim(RenderCacheTrimLevel.memoryPressure);
      await index.put(h(4), box.stage(index, h(4), 300));
      await index.put(h(4), box.stage(index, h(4), 250));
      await index.remove([h(3)]);
      await index.clear();
      await index.put(h(5), box.stage(index, h(5), 100));
    }

    test('the scenario without faults', () async {
      final index = makeIndex(box, const LocalStoreFs(), limit: 800);
      await scenario(box, index);
      expect(index.entries.single.hash, h(5));
      expectConsistent(box, index);
    });

    test('a crash at every step, with every torn-write mode, is repaired by the next open', () async {
      final probe = FaultInjectingFs(const LocalStoreFs());
      await scenario(box, makeIndex(box, probe, limit: 800));
      final total = probe.steps;
      expect(total, greaterThan(20));
      var runs = 0;
      for (var step = 1; step <= total; step++) {
        for (final torn in TornWrite.values) {
          final b = Box.create();
          try {
            final fs = FaultInjectingFs(const LocalStoreFs())..crashAtStep(step, torn: torn);
            Object? crash;
            try {
              await scenario(b, makeIndex(b, fs, limit: 800));
            } on SimulatedCrash catch (e) {
              crash = e;
            }
            expect(crash, isNotNull, reason: 'step $step crashed');
            fs.restart();
            final reopened = makeIndex(b, fs, limit: 800);
            await reopened.open();
            expectConsistent(b, reopened);
            // And it keeps working.
            await reopened.put(h('after'), b.stage(reopened, h('after'), 100));
            expect(await reopened.lookup(h('after')), isNotNull);
            expectConsistent(b, reopened);
            runs++;
          } finally {
            b.dispose();
          }
        }
      }
      expect(runs, total * TornWrite.values.length);
    });
  });
}
