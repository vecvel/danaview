// OWNER: CORE-24
//
// LocalStoreFs on a real directory, the error mapping, and the FaultInjectingFs decorator itself.

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vwish_editor_core/store.dart';

import 'support/harness.dart';

void main() {
  late Container c;
  const fs = LocalStoreFs();
  setUp(() => c = Container.create());
  tearDown(() => c.dispose());

  group('LocalStoreFs', () {
    test('write, read, prefix, stat, rename (file and directory), list, delete', () async {
      final f = c.at('a/one.bin');
      await fs.createDirectory(p.dirname(f));
      await fs.writeBytesSynced(f, Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(await fs.readBytes(f), [1, 2, 3, 4, 5]);
      expect(await fs.readPrefix(f, 3), [1, 2, 3]);
      expect(await fs.readPrefix(f, 99), [1, 2, 3, 4, 5]);
      final s = await fs.stat(f);
      expect((s.type, s.size), (StoreEntityType.file, 5));
      expect(s.modified, isNotNull);
      expect((await fs.stat(c.at('nope'))).type, StoreEntityType.notFound);
      expect((await fs.stat(p.dirname(f))).type, StoreEntityType.directory);

      await fs.rename(f, c.at('a/two.bin'));
      expect(File(f).existsSync(), isFalse);
      await fs.writeBytesSynced(c.at('a/three.bin'), Uint8List.fromList([9]));
      await fs.rename(c.at('a/three.bin'), c.at('a/two.bin'));
      expect(await fs.readBytes(c.at('a/two.bin')), [9], reason: 'rename replaces an existing file');
      await fs.rename(c.at('a'), c.at('b'));
      expect((await fs.list(c.at('b'))).map((e) => (p.basename(e.path), e.type)), [('two.bin', StoreEntityType.file)]);

      await fs.delete(c.at('b'), recursive: true);
      expect(Directory(c.at('b')).existsSync(), isFalse);
      await fs.delete(c.at('b'), recursive: true); // missing: fine
    });

    test('errors are typed', () async {
      await expectLater(fs.readBytes(c.at('missing')), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.notFound)));
      await expectLater(fs.rename(c.at('missing'), c.at('x')), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.notFound)));
      await expectLater(fs.list(c.at('missing')), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.notFound)));
      await expectLater(fs.writeBytesSynced(c.at('no/parent/f'), Uint8List(1)), throwsA(isA<StoreFailure>()));
      await expectLater(fs.copyFile(c.at('missing'), c.at('x')), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.notFound)));
    });

    test('storeFailureOf maps errno values', () {
      StoreFailureKind kind(int code) => storeFailureOf(FileSystemException('x', '/p', OSError('e', code))).kind;
      expect(kind(2), StoreFailureKind.notFound);
      expect(kind(13), StoreFailureKind.permissionDenied);
      expect(kind(1), StoreFailureKind.permissionDenied);
      expect(kind(30), StoreFailureKind.permissionDenied);
      expect(kind(28), StoreFailureKind.diskFull);
      expect(kind(69), StoreFailureKind.diskFull);
      expect(kind(122), StoreFailureKind.diskFull);
      expect(kind(5), StoreFailureKind.io);
      expect(storeFailureOf(StateError('x')).kind, StoreFailureKind.io);
      expect(storeFailureOf(const StoreFailure(StoreFailureKind.busy)).kind, StoreFailureKind.busy);
      expect(const StoreFailure(StoreFailureKind.io, 'a').toString(), 'StoreFailure(io: a)');
      expect(storeFailureOf(StateError('x')).debugDetail, isNot(contains('/')), reason: 'no paths in diagnostics');
    });

    test('links: stat reports link, list reports link, delete removes only the link', () async {
      final target = c.put(c.at('t/file.txt'), [1]);
      final link = c.at('t/lnk');
      Link(link).createSync(target);
      expect((await fs.stat(link)).type, StoreEntityType.link);
      expect((await fs.list(c.at('t'))).firstWhere((e) => p.basename(e.path) == 'lnk').type, StoreEntityType.link);
      await fs.delete(link);
      expect(File(target).existsSync(), isTrue);
      expect(Link(link).existsSync(), isFalse);
      // Directory link: recursive delete of the link never touches the target directory.
      final dirTarget = Directory(c.at('real'))..createSync();
      File(p.join(dirTarget.path, 'keep')).writeAsStringSync('x');
      Link(c.at('dirlink')).createSync(dirTarget.path);
      await fs.delete(c.at('dirlink'), recursive: true);
      expect(File(p.join(dirTarget.path, 'keep')).existsSync(), isTrue);
    });

    test('recursive delete does not follow links inside the tree', () async {
      final keep = c.put(c.at('outside/keep.txt'), [1]);
      c.put(c.at('tree/a/b.txt'), [2]);
      Link(c.at('tree/a/escape')).createSync(c.at('outside'));
      await fs.delete(c.at('tree'), recursive: true);
      expect(File(keep).existsSync(), isTrue);
      expect(Directory(c.at('tree')).existsSync(), isFalse);
    });

    test('canonicalize resolves links of the existing prefix and keeps the missing tail', () async {
      Directory(c.at('real/dir')).createSync(recursive: true);
      Link(c.at('lnk')).createSync(c.at('real'));
      final real = await fs.canonicalize(c.at('real'));
      expect(await fs.canonicalize(c.at('lnk/dir')), p.join(real, 'dir'));
      expect(await fs.canonicalize(c.at('lnk/dir/missing/deeper')), p.join(real, 'dir', 'missing', 'deeper'));
      expect(await fs.canonicalize(c.at('lnk/dir/../dir/./x')), p.join(real, 'dir', 'x'));
      expect(await fs.canonicalize(c.at('lnk/dir/../..')), p.dirname(real));
    });

    test('copyExclusive: copies when free; false and untouched when the target exists (file, dangling link)', () async {
      final src = c.put(c.at('src.bin'), List.generate(3 << 20, (i) => i & 0xFF));
      expect(await fs.copyExclusive(src, c.at('dst.bin')), isTrue);
      expect(File(c.at('dst.bin')).readAsBytesSync(), File(src).readAsBytesSync());
      final dst = File(c.at('dst.bin'));
      final before = (dst.lengthSync(), dst.lastModifiedSync());
      expect(await fs.copyExclusive(c.at('other-source'), c.at('dst.bin')), isFalse, reason: 'existing target: source is not even read');
      expect((dst.lengthSync(), dst.lastModifiedSync()), before);

      Link(c.at('dangling')).createSync(c.at('does-not-exist'));
      expect(await fs.copyExclusive(src, c.at('dangling')), isFalse);
      expect(File(c.at('does-not-exist')).existsSync(), isFalse, reason: 'never written through a link');
    });

    test('copyExclusive with an unreadable source leaves no partial target', () async {
      await expectLater(fs.copyExclusive(c.at('missing'), c.at('dst')), throwsA(isA<StoreFailure>()));
      expect(File(c.at('dst')).existsSync(), isFalse);
    });

    test('copyFile replaces the destination', () async {
      final src = c.put(c.at('s'), [1, 2, 3]);
      c.put(c.at('d'), List.filled(100, 7));
      await fs.copyFile(src, c.at('d'));
      expect(File(c.at('d')).readAsBytesSync(), [1, 2, 3]);
    });
  });

  group('FaultInjectingFs', () {
    late FaultInjectingFs f;
    setUp(() => f = FaultInjectingFs(const LocalStoreFs()));

    test('logs mutating steps only, with 1-based indexes', () async {
      await f.createDirectory(c.at('d'));
      await f.writeBytesSynced(c.at('d/x'), Uint8List(3));
      await f.readBytes(c.at('d/x'));
      await f.stat(c.at('d/x'));
      await f.rename(c.at('d/x'), c.at('d/y'));
      await f.delete(c.at('d/y'));
      expect(f.log.map((o) => (o.index, o.kind)), [
        (1, FsOpKind.createDirectory),
        (2, FsOpKind.write),
        (3, FsOpKind.rename),
        (4, FsOpKind.delete),
      ]);
      expect(f.steps, 4);
    });

    test('a crash applies the torn state, then everything throws until restart', () async {
      final data = Uint8List.fromList(List.generate(10, (i) => i + 1));
      for (final (torn, expected) in [
        (TornWrite.none, null),
        (TornWrite.empty, <int>[]),
        (TornWrite.half, [1, 2, 3, 4, 5]),
        (TornWrite.complete, List.generate(10, (i) => i + 1)),
      ]) {
        final path = c.at('torn-${torn.name}');
        f.reset();
        f.crashAtStep(1, torn: torn);
        await expectLater(f.writeBytesSynced(path, data), throwsA(isA<SimulatedCrash>()));
        expect(f.crashed, isTrue);
        await expectLater(f.readBytes(path), throwsA(isA<SimulatedCrash>()));
        await expectLater(f.stat(path), throwsA(isA<SimulatedCrash>()));
        await expectLater(f.delete(path), throwsA(isA<SimulatedCrash>()));
        f.restart();
        if (expected == null) {
          expect(File(path).existsSync(), isFalse);
        } else {
          expect(File(path).readAsBytesSync(), expected, reason: torn.name);
        }
      }
    });

    test('a crashing rename is either not applied or applied', () async {
      c.put(c.at('a'), [1]);
      f.crashAtStep(1);
      await expectLater(f.rename(c.at('a'), c.at('b')), throwsA(isA<SimulatedCrash>()));
      f.restart();
      expect(File(c.at('a')).existsSync(), isTrue);
      f.reset();
      f.crashAtStep(1, torn: TornWrite.complete);
      await expectLater(f.rename(c.at('a'), c.at('b')), throwsA(isA<SimulatedCrash>()));
      f.restart();
      expect(File(c.at('b')).existsSync(), isTrue);
    });

    test('failStep and failWhere inject typed failures without applying the step', () async {
      f.failStep(2, StoreFailureKind.diskFull);
      await f.writeBytesSynced(c.at('one'), Uint8List(1));
      await expectLater(f.writeBytesSynced(c.at('two'), Uint8List(1)), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.diskFull)));
      expect(File(c.at('two')).existsSync(), isFalse);
      await f.writeBytesSynced(c.at('three'), Uint8List(1)); // one-shot
      expect(f.crashed, isFalse);

      f.failWhere((o) => o.kind == FsOpKind.delete, StoreFailureKind.permissionDenied, times: 2);
      for (var i = 0; i < 2; i++) {
        await expectLater(f.delete(c.at('one')), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.permissionDenied)));
      }
      await f.delete(c.at('one'));
      expect(File(c.at('one')).existsSync(), isFalse);
    });

    test('reset clears the counter and plans', () async {
      f.crashAtStep(1);
      await expectLater(f.createDirectory(c.at('x')), throwsA(isA<SimulatedCrash>()));
      f.reset();
      expect(f.steps, 0);
      await f.createDirectory(c.at('y'));
      expect(f.steps, 1);
    });
  });
}
