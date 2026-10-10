// OWNER: CORE-24
//
// AtomicFile (ARCH §8.3): a crash at every step, with every kind of torn write, always leaves a
// valid main, tmp or bak document; disk-full and permission failures leave the previous document
// readable; read order and cleanup.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vwish_editor_core/store.dart';

import 'support/harness.dart';

void main() {
  late Container c;
  late FaultInjectingFs fs;
  late OwnedFileDeleter deleter;
  late AtomicFile atomic;

  setUp(() {
    c = Container.create();
    fs = FaultInjectingFs(const LocalStoreFs());
    deleter = OwnedFileDeleter(c.roots, fs: fs);
    atomic = AtomicFile(fs: fs, deleter: deleter, random: Random(1));
  });
  tearDown(() => c.dispose());

  Future<AtomicRead> read() => atomic.read(c.projectFile, isValid: VwprojFormat.isValid);

  group('plain behaviour', () {
    test('first write creates the file (and its directory); no .bak, no leftovers', () async {
      await atomic.write(c.projectFile, document(1));
      expect(File(c.projectFile).readAsBytesSync(), document(1));
      expect(File('${c.projectFile}.bak').existsSync(), isFalse);
      expect(Directory(p.dirname(c.projectFile)).listSync().map((e) => p.basename(e.path)), ['project.vwproj']);
    });

    test('a second write keeps the previous document as .bak', () async {
      await atomic.write(c.projectFile, document(1));
      await atomic.write(c.projectFile, document(2));
      expect(File(c.projectFile).readAsBytesSync(), document(2));
      expect(File('${c.projectFile}.bak').readAsBytesSync(), document(1));
      await atomic.write(c.projectFile, document(3));
      expect(File('${c.projectFile}.bak').readAsBytesSync(), document(2), reason: 'only one generation is kept');
      final r = await read();
      expect(r.source, AtomicSource.main);
      expect(revisionOf(r.bytes), 3);
    });

    test('the write sequence is tmp, main -> bak, tmp -> main', () async {
      await atomic.write(c.projectFile, document(1));
      fs.reset();
      await atomic.write(c.projectFile, document(2));
      expect(fs.log.map((o) => o.kind), [FsOpKind.write, FsOpKind.rename, FsOpKind.rename]);
      expect(p.basename(fs.log[0].path), startsWith('project.vwproj.tmp-'));
      expect(p.basename(fs.log[1].path2!), 'project.vwproj.bak');
      expect(fs.log[2].path2, c.projectFile);
    });

    test('read of nothing is notFound; of only garbage is corrupt', () async {
      await expectLater(read(), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.notFound)));
      c.put(c.projectFile, [1, 2, 3]);
      await expectLater(read(), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.corrupt)));
    });
  });

  group('crash at every step always leaves a valid document', () {
    // Scenario: [existing document revisions to write before the crash run] -> the crashing write.
    Future<void> check({required bool existing, required int crashStep, required TornWrite torn, bool staleTmp = false}) async {
      c.dispose();
      c = Container.create();
      fs = FaultInjectingFs(const LocalStoreFs());
      atomic = AtomicFile(fs: fs, deleter: OwnedFileDeleter(c.roots, fs: fs), random: Random(crashStep * 31 + torn.index));
      if (existing) await atomic.write(c.projectFile, document(1));
      if (staleTmp) c.put('${c.projectFile}.tmp-deadbeef', document(7).sublist(0, 100)); // a torn leftover
      fs.reset();
      fs.crashAtStep(crashStep, torn: torn);
      Object? thrown;
      try {
        await atomic.write(c.projectFile, document(2));
      } on Object catch (e) {
        thrown = e;
      }
      final crashed = fs.crashed;
      expect(thrown, crashed ? isA<SimulatedCrash>() : isNull, reason: 'step $crashStep $torn');
      fs.restart();

      final label = 'existing=$existing step=$crashStep $torn stale=$staleTmp';
      try {
        final r = await read();
        final rev = revisionOf(r.bytes);
        expect(rev, anyOf(1, 2), reason: label);
        if (!crashed) expect(rev, 2, reason: '$label: completed writes are durable');
        if (existing) expect(r.bytes, anyOf(equals(document(1)), equals(document(2))), reason: label);
      } on StoreFailure catch (e) {
        // Only a first-ever write may leave nothing readable, and only before its tmp is complete.
        expect(existing, isFalse, reason: '$label: lost the previous document ($e)');
        expect(e.kind, anyOf(StoreFailureKind.notFound, StoreFailureKind.corrupt), reason: label);
        expect(fs.log[crashStep - 1].kind, anyOf(FsOpKind.createDirectory, FsOpKind.write),
            reason: '$label: from the first rename on, a complete tmp exists');
        if (fs.log[crashStep - 1].kind == FsOpKind.write) expect(torn, isNot(TornWrite.complete), reason: label);
      }
      // A main file, if present, is never torn: it is the old or the new document in full.
      final main = File(c.projectFile);
      if (main.existsSync()) expect(VwprojFormat.isValid(main.readAsBytesSync()), isTrue, reason: '$label: main is valid or absent');

      // The next save after the crash works and yields the new document.
      await atomic.write(c.projectFile, document(3));
      final after = await read();
      expect(after.source, AtomicSource.main, reason: label);
      expect(revisionOf(after.bytes), 3, reason: label);
      expect(Directory(p.dirname(c.projectFile)).listSync().where((e) => p.basename(e.path).contains('.tmp-')), isEmpty,
          reason: '$label: stale temporaries are cleaned after a good save');
    }

    for (final existing in [true, false]) {
      for (final torn in TornWrite.values) {
        for (var step = 1; step <= 4; step++) {
          test('${existing ? 'existing' : 'first'} document, crash at step $step, ${torn.name}', () async {
            await check(existing: existing, crashStep: step, torn: torn);
          });
        }
      }
    }

    test('with a stale torn tmp from an earlier crash lying around', () async {
      for (var step = 1; step <= 5; step++) {
        for (final torn in TornWrite.values) {
          await check(existing: true, crashStep: step, torn: torn, staleTmp: true);
        }
      }
    });

    test('step counts: 3 mutating steps with an existing main (tmp, bak, main), 2 without', () async {
      fs.reset();
      await atomic.write(c.projectFile, document(1));
      expect(fs.steps, 2 + 1, reason: 'createDirectory + tmp + rename');
      fs.reset();
      await atomic.write(c.projectFile, document(2));
      expect(fs.steps, 3);
    });
  });

  test('random crash storm: 300 sequences of saves with random crashes never lose an acknowledged save', () async {
    final rnd = Random(2024);
    for (var run = 0; run < 300; run++) {
      c.dispose();
      c = Container.create();
      fs = FaultInjectingFs(const LocalStoreFs());
      atomic = AtomicFile(fs: fs, deleter: OwnedFileDeleter(c.roots, fs: fs), random: Random(run));
      var acked = 0; // highest acknowledged revision
      var inFlight = 0;
      for (var rev = 1; rev <= 6; rev++) {
        fs.reset();
        if (rnd.nextInt(3) == 0) fs.crashAtStep(1 + rnd.nextInt(4), torn: TornWrite.values[rnd.nextInt(TornWrite.values.length)]);
        inFlight = rev;
        try {
          await atomic.write(c.projectFile, document(rev, bodySize: 100 + rnd.nextInt(3000)));
          acked = rev;
        } on SimulatedCrash {
          fs.restart();
        }
        try {
          final r = await read();
          final got = revisionOf(r.bytes)!;
          expect(got, greaterThanOrEqualTo(acked), reason: 'run $run rev $rev: acknowledged save lost');
          expect(got, lessThanOrEqualTo(inFlight), reason: 'run $run rev $rev');
        } on StoreFailure {
          expect(acked, 0, reason: 'run $run rev $rev: nothing readable after an acknowledged save');
        }
      }
    }
  });

  group('non-crash failures', () {
    for (final kind in [StoreFailureKind.diskFull, StoreFailureKind.permissionDenied, StoreFailureKind.io]) {
      for (var step = 1; step <= 3; step++) {
        test('${kind.name} at step $step leaves the previous document readable and no temporary file', () async {
          await atomic.write(c.projectFile, document(1));
          fs.reset();
          fs.failStep(step, kind);
          await expectLater(atomic.write(c.projectFile, document(2)), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', kind)));
          final r = await read();
          expect(revisionOf(r.bytes), 1);
          expect(r.bytes, document(1));
          expect(File(c.projectFile).existsSync(), isTrue, reason: 'main restored even when the last rename failed');
          expect(Directory(p.dirname(c.projectFile)).listSync().where((e) => e.path.contains('.tmp-')), isEmpty);
          // And the next attempt succeeds.
          fs.reset();
          await atomic.write(c.projectFile, document(3));
          expect(revisionOf((await read()).bytes), 3);
        });
      }
    }

    test('disk full on the very first write leaves nothing behind', () async {
      fs.failWhere((o) => o.kind == FsOpKind.write, StoreFailureKind.diskFull);
      await expectLater(atomic.write(c.projectFile, document(1)), throwsA(isA<StoreFailure>()));
      expect(File(c.projectFile).existsSync(), isFalse);
      expect(Directory(p.dirname(c.projectFile)).listSync(), isEmpty);
    });

    test('LocalStoreFs maps a real EACCES on a read-only directory', () async {
      await atomic.write(c.projectFile, document(1));
      final dir = p.dirname(c.projectFile);
      Process.runSync('chmod', ['555', dir]);
      addTearDown(() => Process.runSync('chmod', ['755', dir]));
      if (Platform.isWindows || Process.runSync('id', ['-u']).stdout.toString().trim() == '0') return;
      await expectLater(
        AtomicFile(fs: const LocalStoreFs(), deleter: deleter).write(c.projectFile, document(2)),
        throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.permissionDenied)),
      );
      Process.runSync('chmod', ['755', dir]);
      expect((await read()).bytes, document(1));
    });
  });

  group('read order and validity', () {
    test('a valid main wins over a newer valid tmp (an unacknowledged write)', () async {
      await atomic.write(c.projectFile, document(1));
      c.put('${c.projectFile}.tmp-aaaaaaaa', document(2));
      final r = await read();
      expect(r.source, AtomicSource.main);
      expect(revisionOf(r.bytes), 1);
    });

    test('a truncated main falls back to the newest valid of tmp and bak', () async {
      await atomic.write(c.projectFile, document(1));
      await atomic.write(c.projectFile, document(2));
      final d2 = document(2);
      File(c.projectFile).writeAsBytesSync(d2.sublist(0, d2.length - 7));
      expect((await read()).source, AtomicSource.backup);
      expect(revisionOf((await read()).bytes), 1);

      c.put('${c.projectFile}.tmp-11111111', document(2));
      final r = await read();
      expect(r.source, AtomicSource.temp, reason: 'a tmp newer than the bak wins');
      expect(revisionOf(r.bytes), 2);
    });

    test('an older valid tmp does not beat a newer bak (mtime decides)', () async {
      c.put(c.projectFile, [0, 0, 0]); // corrupt main
      final tmp = File(c.put('${c.projectFile}.tmp-22222222', document(5)));
      final bak = File(c.put('${c.projectFile}.bak', document(6)));
      tmp.setLastModifiedSync(DateTime.utc(2026, 1, 1));
      bak.setLastModifiedSync(DateTime.utc(2026, 6, 1));
      expect((await read()).source, AtomicSource.backup);
      tmp.setLastModifiedSync(DateTime.utc(2026, 9, 1));
      expect((await read()).source, AtomicSource.temp);
    });

    test('an invalid newest tmp is skipped for the next valid one', () async {
      c.put('${c.projectFile}.tmp-33333333', document(4));
      final newest = File(c.put('${c.projectFile}.tmp-44444444', document(9).sublist(0, 50)));
      newest.setLastModifiedSync(DateTime.utc(2026, 10, 1));
      File('${c.projectFile}.tmp-33333333').setLastModifiedSync(DateTime.utc(2026, 5, 1));
      final r = await read();
      expect(revisionOf(r.bytes), 4);
    });

    test('bit flips and truncation of every copy: corrupt', () async {
      final d = document(1);
      final flipped = Uint8List.fromList(d)..[d.length - 20] ^= 0x04;
      c.put(c.projectFile, flipped);
      c.put('${c.projectFile}.bak', d.sublist(0, d.length ~/ 2));
      await expectLater(read(), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.corrupt)));
    });

    test('read never writes', () async {
      await atomic.write(c.projectFile, document(1));
      File(c.projectFile).writeAsBytesSync([9, 9]);
      c.put('${c.projectFile}.tmp-55555555', document(2));
      final before = c.snapshot();
      fs.reset();
      await read();
      expect(fs.log, isEmpty);
      expect(c.snapshot(), before);
    });
  });

  group('cleanup goes through the deleter', () {
    test('a violation while removing temporaries never fails a completed save', () async {
      // Roots that do not contain the project file: the guard refuses, the save still succeeds.
      final other = Container.create();
      addTearDown(other.dispose);
      final strict = OwnedFileDeleter(other.roots, assertOnViolation: false);
      final a = AtomicFile(fs: fs, deleter: strict);
      c.put('${c.projectFile}.tmp-66666666', [1]);
      await a.write(c.projectFile, document(1));
      expect(revisionOf(File(c.projectFile).readAsBytesSync()), 1);
      expect(File('${c.projectFile}.tmp-66666666').existsSync(), isTrue, reason: 'refused, left alone');
    });

    test('without a deleter nothing is ever deleted', () async {
      final a = AtomicFile(fs: fs);
      c.put('${c.projectFile}.tmp-77777777', [1]);
      await a.write(c.projectFile, document(1));
      expect(File('${c.projectFile}.tmp-77777777').existsSync(), isTrue);
      expect(fs.log.where((o) => o.kind == FsOpKind.delete), isEmpty);
    });
  });
}
