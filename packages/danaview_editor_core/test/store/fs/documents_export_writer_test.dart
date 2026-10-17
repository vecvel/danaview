// OWNER: CORE-24
//
// DocumentsExportWriter (D-44): the only writer into Documents. Exclusive create, `<name> (2).mp4`
// naming, never overwrites, refuses symlinked targets and parents, copies only editor-root files.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:danaview_editor_core/store.dart';

import 'support/harness.dart';

String _sha(String path) => sha256.convert(File(path).readAsBytesSync()).toString();

void main() {
  late Container c;
  late DocumentsExportWriter writer;
  late String export;

  setUp(() {
    c = Container.create();
    writer = DocumentsExportWriter(c.roots);
    export = c.put(p.join(c.roots.workDir, 'export-j1.mp4'), List.generate(300000, (i) => (i * 7) & 0xFF));
  });
  tearDown(() => c.dispose());

  List<String> exportsDirListing() => Directory(c.roots.documentsExportsDir).listSync().map((e) => p.basename(e.path)).toList()..sort();

  test('creates Documents/Exports and copies the export there byte for byte', () async {
    expect(Directory(c.roots.documentsExportsDir).existsSync(), isFalse);
    final out = await writer.keepCopy(export, fileName: 'Holiday.mp4');
    expect(out, p.join(c.roots.documentsExportsDir, 'Holiday.mp4'));
    expect(File(out).readAsBytesSync(), File(export).readAsBytesSync());
    expect(File(export).existsSync(), isTrue, reason: 'the source stays; deleting it is the deleter\'s job');
    expect(exportsDirListing(), ['Holiday.mp4']);
  });

  test('a pre-existing file of the same name stays byte-identical (hash, size, mtime); the copy is "<name> (2).mp4"', () async {
    final existing = c.put(p.join(c.roots.documentsExportsDir, 'Holiday.mp4'), utf8.encode('precious earlier export'));
    File(existing).setLastModifiedSync(DateTime.utc(2020, 5, 17, 3, 4, 5));
    final before = (_sha(existing), File(existing).lengthSync(), File(existing).lastModifiedSync(), File(existing).statSync().changed);

    final out = await writer.keepCopy(export, fileName: 'Holiday.mp4');
    expect(p.basename(out), 'Holiday (2).mp4');
    expect(File(out).readAsBytesSync(), File(export).readAsBytesSync());
    expect((_sha(existing), File(existing).lengthSync(), File(existing).lastModifiedSync(), File(existing).statSync().changed), before,
        reason: 'not opened, not truncated, not touched (mtime and ctime)');
    expect(exportsDirListing(), ['Holiday (2).mp4', 'Holiday.mp4']);
  });

  test('numbering continues: (3), skips an existing (2), works for names without extension and with dots', () async {
    await writer.keepCopy(export, fileName: 'a.mp4');
    await writer.keepCopy(export, fileName: 'a.mp4');
    expect(p.basename(await writer.keepCopy(export, fileName: 'a.mp4')), 'a (3).mp4');
    c.put(p.join(c.roots.documentsExportsDir, 'b (2).mov'), [1]);
    await writer.keepCopy(export, fileName: 'b.mov');
    expect(p.basename(await writer.keepCopy(export, fileName: 'b.mov')), 'b (3).mov');
    expect(p.basename(await writer.keepCopy(export, fileName: 'noext')), 'noext');
    expect(p.basename(await writer.keepCopy(export, fileName: 'noext')), 'noext (2)');
    expect(p.basename(await writer.keepCopy(export, fileName: 'my.clip.v2.mp4')), 'my.clip.v2.mp4');
    expect(p.basename(await writer.keepCopy(export, fileName: 'my.clip.v2.mp4')), 'my.clip.v2 (2).mp4');
    expect(File(p.join(c.roots.documentsExportsDir, 'b (2).mov')).readAsBytesSync(), [1]);
  });

  test('concurrent copies of the same name end up in distinct files', () async {
    final results = await Future.wait([for (var i = 0; i < 6; i++) writer.keepCopy(export, fileName: 'same.mp4')]);
    expect(results.toSet(), hasLength(6));
    for (final r in results) {
      expect(File(r).readAsBytesSync(), File(export).readAsBytesSync());
    }
  });

  group('symbolic links', () {
    test('a symlinked Exports directory is refused and nothing is written through it', () async {
      final elsewhere = Directory(c.at('elsewhere'))..createSync();
      Link(c.roots.documentsExportsDir).createSync(elsewhere.path);
      await expectLater(writer.keepCopy(export, fileName: 'x.mp4'), throwsA(isA<OwnershipViolation>().having((e) => e.reason, 'reason', contains('symbolic link'))));
      expect(elsewhere.listSync(), isEmpty);
    });

    test('Exports replaced by a regular file is refused', () async {
      c.put(c.roots.documentsExportsDir, [1]);
      await expectLater(writer.keepCopy(export, fileName: 'x.mp4'), throwsA(isA<OwnershipViolation>()));
      expect(File(c.roots.documentsExportsDir).readAsBytesSync(), [1]);
    });

    test('a symlink at the target name (to a file or dangling) is refused; its destination is untouched', () async {
      Directory(c.roots.documentsExportsDir).createSync(recursive: true);
      final victim = c.put(c.at('outside/victim.mp4'), utf8.encode('victim'));
      Link(p.join(c.roots.documentsExportsDir, 'x.mp4')).createSync(victim);
      await expectLater(writer.keepCopy(export, fileName: 'x.mp4'), throwsA(isA<OwnershipViolation>()));
      expect(File(victim).readAsBytesSync(), utf8.encode('victim'));

      Link(p.join(c.roots.documentsExportsDir, 'y.mp4')).createSync(c.at('outside/nowhere.mp4'));
      await expectLater(writer.keepCopy(export, fileName: 'y.mp4'), throwsA(isA<OwnershipViolation>()));
      expect(File(c.at('outside/nowhere.mp4')).existsSync(), isFalse);
    });

    test('a symlink at a later candidate name ("(2)") aborts too, without writing through it', () async {
      await writer.keepCopy(export, fileName: 'z.mp4');
      final victim = c.put(c.at('outside/v2.mp4'), [9]);
      Link(p.join(c.roots.documentsExportsDir, 'z (2).mp4')).createSync(victim);
      await expectLater(writer.keepCopy(export, fileName: 'z.mp4'), throwsA(isA<OwnershipViolation>()));
      expect(File(victim).readAsBytesSync(), [9]);
    });

    test('Documents itself may be reached through a symbolic link (like /var on iOS)', () async {
      final alias = Link(c.at('alias'))..createSync(c.dir.path);
      final aliased = StoreRoots(support: p.join(alias.path, 'support'), cache: p.join(alias.path, 'cache'), documents: p.join(alias.path, 'documents'));
      final out = await DocumentsExportWriter(aliased).keepCopy(export, fileName: 'ok.mp4');
      expect(File(out).existsSync(), isTrue);
    });

    test('Documents itself being a symbolic link is trusted (it is configuration); Exports under it is written normally', () async {
      final elsewhere = Directory(c.at('elsewhere'))..createSync();
      Directory(c.roots.documents).deleteSync(recursive: true);
      Link(c.roots.documents).createSync(elsewhere.path);
      final out = await writer.keepCopy(export, fileName: 'fine.mp4');
      expect(File(p.join(elsewhere.path, 'Exports', 'fine.mp4')).existsSync(), isTrue);
      expect(out, p.join(c.roots.documentsExportsDir, 'fine.mp4'));
    });
  });

  group('source rules', () {
    test('only regular files under the editor roots; links, directories, Documents and outsiders are refused', () async {
      final doc = c.put(p.join(c.roots.documents, 'Movie.mp4'), [1]);
      final outside = c.put(c.at('outside/o.mp4'), [2]);
      final link = p.join(c.roots.workDir, 'link.mp4');
      Link(link).createSync(outside);
      final speech = c.put(p.join(c.roots.speechSupport, 'x.wav'), [3]);
      for (final source in [doc, outside, link, speech, c.roots.workDir, p.join(c.roots.workDir, 'missing.mp4'), 'relative.mp4', p.join(c.roots.workDir, '..', '..', '..', '..', 'outside', 'o.mp4')]) {
        await expectLater(writer.keepCopy(source, fileName: 'x.mp4'), throwsA(isA<OwnershipViolation>()), reason: source);
      }
      expect(Directory(c.roots.documentsExportsDir).existsSync(), isFalse, reason: 'refusals happen before anything is created');
      // Both editor roots are fine sources.
      final supportFile = c.put(p.join(c.roots.mediaDir, 'a.mp4'), [4]);
      expect(File(await writer.keepCopy(supportFile, fileName: 's.mp4')).readAsBytesSync(), [4]);
    });
  });

  group('file names', () {
    test('only plain names are accepted', () async {
      for (final bad in ['', '.', '..', 'a/b.mp4', r'a\b.mp4', '../x.mp4', '/abs.mp4', 'tab\there.mp4', 'nul\u0000.mp4', 'del\u007F.mp4', '${'x' * 300}.mp4', 'é' * 130]) {
        expect(() => writer.keepCopy(export, fileName: bad), throwsArgumentError, reason: bad);
      }
      expect(Directory(c.roots.documentsExportsDir).existsSync(), isFalse);
      // Unicode and spaces are fine.
      final out = await writer.keepCopy(export, fileName: '東京 のビデオ (final).mp4');
      expect(p.basename(out), '東京 のビデオ (final).mp4');
      expect(p.basename(await writer.keepCopy(export, fileName: '東京 のビデオ (final).mp4')), '東京 のビデオ (final) (2).mp4');
    });
  });

  group('failures', () {
    test('disk full while copying leaves no partial file and no change to existing exports', () async {
      final existing = c.put(p.join(c.roots.documentsExportsDir, 'a.mp4'), [1, 2, 3]);
      final fs = FaultInjectingFs(const LocalStoreFs());
      fs.failWhere((o) => o.kind == FsOpKind.copyExclusive, StoreFailureKind.diskFull);
      await expectLater(
        DocumentsExportWriter(c.roots, fs: fs).keepCopy(export, fileName: 'a.mp4'),
        throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.diskFull)),
      );
      expect(exportsDirListing(), ['a.mp4']);
      expect(File(existing).readAsBytesSync(), [1, 2, 3]);
    });

    test('a source that disappears mid-way leaves no partial file (LocalStoreFs removes what it created)', () async {
      final fs = const LocalStoreFs();
      Directory(c.roots.documentsExportsDir).createSync(recursive: true);
      await expectLater(fs.copyExclusive(p.join(c.roots.workDir, 'gone.mp4'), p.join(c.roots.documentsExportsDir, 'gone.mp4')), throwsA(isA<StoreFailure>()));
      expect(exportsDirListing(), isEmpty);
    });

    test('the writer never deletes: a crash mid-copy is the only way to leave a partial file, and existing exports survive', () async {
      final existing = c.put(p.join(c.roots.documentsExportsDir, 'a.mp4'), utf8.encode('first'));
      final fs = FaultInjectingFs(const LocalStoreFs());
      fs.crashAtStep(1, torn: TornWrite.none);
      await expectLater(DocumentsExportWriter(c.roots, fs: fs).keepCopy(export, fileName: 'a.mp4'), throwsA(isA<SimulatedCrash>()));
      expect(fs.log.where((o) => o.kind == FsOpKind.delete), isEmpty);
      expect(File(existing).readAsBytesSync(), utf8.encode('first'));
    });
  });

  test('source is not modified and the written copy is complete for a multi-megabyte export', () async {
    final big = Uint8List(6 << 20);
    for (var i = 0; i < big.length; i++) {
      big[i] = (i * 31 + (i >> 8)) & 0xFF;
    }
    final src = c.put(p.join(c.roots.workDir, 'export-big.mp4'), big);
    final out = await writer.keepCopy(src, fileName: 'Big.mp4');
    expect(_sha(out), _sha(src));
    expect(File(out).lengthSync(), big.length);
  });
}
