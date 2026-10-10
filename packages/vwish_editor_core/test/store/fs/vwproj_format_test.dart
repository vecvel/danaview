// OWNER: CORE-24
//
// The `.vwproj` two-line container (ARCH §8.2): checksums detect truncation and bit flips; the
// header can be read without the body.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vwish_editor_core/codec.dart';
import 'package:vwish_editor_core/store.dart';

import 'support/harness.dart';

VwprojIssue? _issue(Uint8List bytes) {
  try {
    VwprojFormat.parse(bytes);
    return null;
  } on VwprojException catch (e) {
    return e.issue;
  }
}

void main() {
  group('format', () {
    test('build: header line, body line, exact byte count and sha256', () {
      final body = Uint8List.fromList(utf8.encode('{"id":"pr_x","name":"été 東京 🎬"}'));
      final bytes = VwprojFormat.build(body, app: '1.1.0+3', savedAt: DateTime.utc(2026, 10, 9, 18), docRevision: 5, saveId: 'sv_a');
      final text = utf8.decode(bytes);
      final lines = text.split('\n');
      expect(lines, hasLength(3));
      expect(lines[2], isEmpty);
      expect(bytes.last, 0x0A);
      final header = ProjectHeader.parseLine(lines[0]);
      expect(header.bodyBytes, body.length, reason: 'UTF-8 byte length, not code units');
      expect(header.bodySha256, hasLength(64));
      expect(utf8.encode(lines[1]), body);
      expect(lines[0], startsWith('{"format":"vwish.editor.project","schema":1,"minReader":1,"app":"1.1.0+3"'));
      final doc = VwprojFormat.parse(bytes);
      expect(doc.body, body);
      expect(doc.header, header);
      expect(VwprojFormat.isValid(bytes), isTrue);
    });

    test('the CORE-22 golden document verifies, header and body', () {
      final bytes = File('test/codec/fixtures/kitchen_sink.vwproj').readAsBytesSync();
      final doc = VwprojFormat.parse(bytes);
      expect(doc.header.docRevision, 9001);
      expect(ProjectJsonCodec().decodeBytes(doc.body).project.meta.name, 'Kitchen sink');
      expect(VwprojFormat.encode(doc.header, doc.body), bytes, reason: 'encode is the inverse of parse');
    });

    test('journal headers keep baseSaveId', () {
      final bytes = VwprojFormat.build(Uint8List.fromList(utf8.encode('{}')),
          app: 'a', savedAt: DateTime.utc(2026), docRevision: 2, saveId: 'sv_b', baseSaveId: 'sv_a');
      expect(VwprojFormat.parse(bytes).header.baseSaveId, 'sv_a');
    });

    test('a document without the final newline is accepted; any other trailing data is not', () {
      final d = document(1);
      expect(_issue(Uint8List.sublistView(d, 0, d.length - 1)), isNull);
      expect(_issue(Uint8List.fromList([...d, 0x0A])), VwprojIssue.trailingData);
      expect(_issue(Uint8List.fromList([...d, 0x20])), VwprojIssue.trailingData);
      expect(_issue(Uint8List.fromList([...d, ...d])), VwprojIssue.trailingData);
    });

    test('encode refuses a header that does not describe the body', () {
      final d = VwprojFormat.parse(document(1));
      expect(() => VwprojFormat.encode(d.header, Uint8List.fromList([...d.body, 0x20])), throwsArgumentError);
      expect(() => VwprojFormat.encode(d.header, Uint8List.fromList(d.body)..[3] ^= 1), throwsArgumentError);
    });

    test('header problems', () {
      expect(_issue(Uint8List(0)), VwprojIssue.noHeader);
      expect(_issue(Uint8List.fromList(utf8.encode('{"format":"vwish.editor.project"}'))), VwprojIssue.noHeader);
      expect(_issue(Uint8List.fromList(utf8.encode('garbage\n{}\n'))), VwprojIssue.badHeader);
      expect(_issue(Uint8List.fromList(utf8.encode('{"format":"other"}\n{}\n'))), VwprojIssue.badHeader);
      expect(_issue(Uint8List.fromList([...List.filled(VwprojFormat.maxHeaderBytes + 10, 0x20), 0x0A, 0x7B, 0x7D])), VwprojIssue.noHeader);
    });
  });

  group('integrity', () {
    final d = document(3, bodySize: 600);
    final headerEnd = ProjectHeader.headerLineEnd(d);

    test('every truncation of a document is detected (all prefix lengths)', () {
      // Cutting only the final newline leaves the document intact; every shorter prefix is invalid.
      for (var n = 0; n < d.length - 1; n++) {
        expect(VwprojFormat.isValid(Uint8List.sublistView(d, 0, n)), isFalse, reason: 'prefix of $n bytes');
      }
      expect(VwprojFormat.isValid(Uint8List.sublistView(d, 0, d.length - 1)), isTrue);
      expect(VwprojFormat.isValid(d), isTrue);
    });

    test('a single flipped bit anywhere in the body is detected (every bit of every body byte)', () {
      for (var i = headerEnd + 1; i < d.length - 1; i++) {
        for (var bit = 0; bit < 8; bit++) {
          final flipped = Uint8List.fromList(d)..[i] ^= 1 << bit;
          expect(VwprojFormat.isValid(flipped), isFalse, reason: 'byte $i bit $bit');
        }
      }
    });

    test('a flipped bit in the header never yields a document that verifies with different content', () {
      final original = VwprojFormat.parse(d);
      for (var i = 0; i < headerEnd; i++) {
        for (var bit = 0; bit < 8; bit++) {
          final flipped = Uint8List.fromList(d)..[i] ^= 1 << bit;
          final parsed = VwprojFormat.tryParse(flipped);
          // Either rejected, or (a flip in a field that is not part of the integrity check, such as a
          // digit of docRevision) the body is still byte-identical: never altered content.
          if (parsed != null) expect(parsed.body, original.body, reason: 'header byte $i bit $bit');
        }
      }
    });

    test('torn sector: zeroed tail and swapped blocks are detected', () {
      final zeroed = Uint8List.fromList(d)..fillRange(d.length - 200, d.length, 0);
      expect(VwprojFormat.isValid(zeroed), isFalse);
      final swapped = Uint8List.fromList(d);
      final a = headerEnd + 20, b = headerEnd + 120;
      for (var i = 0; i < 40; i++) {
        final t = swapped[a + i];
        swapped[a + i] = swapped[b + i];
        swapped[b + i] = t;
      }
      expect(VwprojFormat.isValid(swapped), isFalse);
    });

    test('truncation reports `truncated`, a flip reports `checksumMismatch`', () {
      expect(_issue(Uint8List.sublistView(d, 0, d.length - 50)), VwprojIssue.truncated);
      expect(_issue(Uint8List.fromList(d)..[headerEnd + 30] ^= 1), VwprojIssue.checksumMismatch);
    });
  });

  group('files', () {
    late Container c;
    setUp(() => c = Container.create());
    tearDown(() => c.dispose());

    test('write + read + header-only read', () async {
      final files = VwprojFiles();
      await files.write(c.projectFile, document(4));
      final read = await files.read(c.projectFile);
      expect(read.source, AtomicSource.main);
      expect(read.document.header.docRevision, 4);
      expect((await files.readHeader(c.projectFile)).saveId, 'sv_test00000004');
    });

    test('writing an invalid document is refused before anything touches the disk', () async {
      final good = document(1);
      final bad = Uint8List.fromList(good)..[ProjectHeader.headerLineEnd(good) + 30] ^= 1;
      expect(() => VwprojFiles().write(c.projectFile, bad), throwsArgumentError);
      expect(File(c.projectFile).existsSync(), isFalse);
    });

    test('readHeader reads a bounded prefix, never the body (a 40 MB body is not read)', () async {
      final big = VwprojFormat.build(Uint8List(40 << 20)..fillRange(0, 40 << 20, 0x61),
          app: '1', savedAt: DateTime.utc(2026), docRevision: 1, saveId: 'sv_big');
      c.put(c.projectFile, big);
      final counting = _CountingFs();
      final header = await VwprojFiles(fs: counting).readHeader(c.projectFile);
      expect(header.bodyBytes, 40 << 20);
      expect(counting.bytesRead, lessThanOrEqualTo(VwprojFormat.maxHeaderBytes + 1));
      expect(counting.wholeReads, 0);
    });

    test('readHeader of a newer-schema document with a broken body still works', () async {
      final newer = Uint8List.fromList([
        ...utf8.encode(jsonEncode(ProjectHeader.forBody(Uint8List(0),
            app: '9', savedAt: DateTime.utc(2030), docRevision: 1, saveId: 'sv_n', schema: 9, minReader: 1)
            .toJson())),
        0x0A,
        0xFF, 0xFF, 0xFF,
      ]);
      c.put(c.projectFile, newer);
      final header = await VwprojFiles().readHeader(c.projectFile);
      expect(Migrations.standard.classifyHeader(header), SchemaCompatibility.readOnlyNewer);
      await expectLater(VwprojFiles().read(c.projectFile), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.corrupt)));
    });

    test('readHeader errors: missing file is notFound, junk is a VwprojException', () async {
      await expectLater(VwprojFiles().readHeader(c.projectFile), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.notFound)));
      c.put(c.projectFile, utf8.encode('no newline here'));
      await expectLater(VwprojFiles().readHeader(c.projectFile), throwsA(isA<VwprojException>()));
    });

    test('read falls back to .bak when main is bit-flipped, and to nothing valid: corrupt', () async {
      final files = VwprojFiles();
      await files.write(c.projectFile, document(1));
      await files.write(c.projectFile, document(2));
      final main = File(c.projectFile);
      main.writeAsBytesSync(Uint8List.fromList(main.readAsBytesSync())..[main.lengthSync() - 30] ^= 0x10);
      final r = await files.read(c.projectFile);
      expect(r.source, AtomicSource.backup);
      expect(r.document.header.docRevision, 1);
      File('${c.projectFile}.bak').writeAsBytesSync([1]);
      await expectLater(files.read(c.projectFile), throwsA(isA<StoreFailure>().having((e) => e.kind, 'kind', StoreFailureKind.corrupt)));
    });
  });
}

/// Counts what is read from disk.
final class _CountingFs implements StoreFs {
  final StoreFs _inner = const LocalStoreFs();
  int bytesRead = 0;
  int wholeReads = 0;

  @override
  Future<Uint8List> readBytes(String path) async {
    wholeReads++;
    final b = await _inner.readBytes(path);
    bytesRead += b.length;
    return b;
  }

  @override
  Future<Uint8List> readPrefix(String path, int maxBytes) async {
    final b = await _inner.readPrefix(path, maxBytes);
    bytesRead += b.length;
    return b;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}
