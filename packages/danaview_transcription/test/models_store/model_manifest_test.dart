// OWNER: AI-09

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_transcription/danaview_transcription.dart';

import 'support/fake_model_server.dart';

Map<String, Object?> entry({Object? id = 'a', Object? file = 'a.bin', Object? sha = 'AB', Object? bytes = 10, Object? installed = '2026-10-10T10:00:00Z', Object? verified = '2026-10-10T10:00:00Z'}) =>
    {'id': id, 'file': file, 'sha256': sha, 'bytes': bytes, 'installedAt': installed, 'verifiedAt': verified};

void main() {
  group('SpeechModelManifest', () {
    test('round-trips schema 1', () {
      final m = SpeechModelManifest([
        ManifestEntry(id: 'a', file: 'a.bin', sha256: 'ab', bytes: 10, installedAt: DateTime.utc(2026, 10, 10), verifiedAt: DateTime.utc(2026, 10, 11), lastUsedAt: DateTime.utc(2026, 10, 12)),
      ]);
      final back = SpeechModelManifest.tryDecode(m.encode())!;
      expect(back.installed.single.id, 'a');
      expect(back.installed.single.lastUsedAt, DateTime.utc(2026, 10, 12));
      expect(back.installed.single.verifiedAt, DateTime.utc(2026, 10, 11));
      expect((jsonDecode(m.encode()) as Map)['schema'], 1);
    });

    test('malformed input reads as absent, never throws', () {
      for (final text in ['', 'null', '[]', '{', '{"schema":2,"installed":[]}', '{"schema":1}', '{"schema":1,"installed":3}']) {
        expect(SpeechModelManifest.tryDecode(text), isNull, reason: text);
      }
    });

    test('bad entries are dropped, good ones kept; duplicates collapse; sha is lowercased', () {
      final text = jsonEncode({
        'schema': 1,
        'installed': [
          entry(),
          entry(id: 3),
          entry(bytes: 0),
          entry(bytes: '10'),
          entry(installed: 'not a date'),
          entry(file: '../escape.bin'),
          entry(file: 'sub/dir.bin'),
          entry(file: r'..\x'),
          entry(file: ''),
          'nonsense',
          entry(),
        ],
      });
      final m = SpeechModelManifest.tryDecode(text)!;
      expect(m.installed, hasLength(1));
      expect(m.installed.single.sha256, 'ab');
    });

    test('upsert replaces by id; without removes', () {
      final e1 = ManifestEntry(id: 'a', file: 'a', sha256: '1', bytes: 1, installedAt: DateTime.utc(2026), verifiedAt: DateTime.utc(2026));
      final e2 = ManifestEntry(id: 'a', file: 'a', sha256: '2', bytes: 1, installedAt: DateTime.utc(2026), verifiedAt: DateTime.utc(2026));
      final m = const SpeechModelManifest([]).upsert(e1).upsert(e2);
      expect(m.installed.single.sha256, '2');
      expect(m.without('a').installed, isEmpty);
      expect(m.entryOf('b'), isNull);
    });
  });

  group('PartialSidecar', () {
    test('round-trips url, bytes, sha256, written, updatedAt, catalogRevision', () {
      final s = PartialSidecar(url: 'https://x/y', bytes: 5, sha256: 'AA', written: 3, updatedAt: DateTime.utc(2026, 10, 10), catalogRevision: 1);
      final back = PartialSidecar.tryDecode(s.encode())!;
      expect(back.url, 'https://x/y');
      expect(back.bytes, 5);
      expect(back.sha256, 'aa');
      expect(back.written, 3);
      expect(back.updatedAt, DateTime.utc(2026, 10, 10));
      expect(back.catalogRevision, 1);
    });

    test('malformed sidecars read as null', () {
      for (final text in ['', '{', '[]', '{"url":1}', '{"url":"u","bytes":1,"sha256":"a","written":-1,"updatedAt":"2026-01-01T00:00:00Z","catalogRevision":1}']) {
        expect(PartialSidecar.tryDecode(text), isNull, reason: text);
      }
    });

    test('read of a missing file is null', () async {
      expect(await PartialSidecar.read('/definitely/not/here.part.json'), isNull);
    });
  });

  group('file checks', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('danaview_checks_'));
    tearDown(() => dir.delete(recursive: true));

    test('sha256OfFile (in an isolate) equals the crypto digest, across block boundaries', () async {
      for (final size in [0, 1, 1024 * 1024 - 1, 1024 * 1024, 3 * 1024 * 1024 + 17]) {
        final data = modelBytes(size == 0 ? 0 : size, seed: size, magic: size >= 4);
        final f = File(p.join(dir.path, 'f$size'))..writeAsBytesSync(data);
        expect(await sha256OfFile(f.path), sha256.convert(data).toString(), reason: '$size bytes');
      }
    });

    test('sha256OfFile of a missing file throws a FileSystemException', () async {
      await expectLater(sha256OfFile(p.join(dir.path, 'nope')), throwsA(anything));
    });

    test('hasGgmlMagic checks the first four bytes only', () async {
      final good = File(p.join(dir.path, 'good'))..writeAsBytesSync([...ggmlMagicBytes, 1, 2, 3]);
      final bad = File(p.join(dir.path, 'bad'))..writeAsBytesSync([0x67, 0x67, 0x6d, 0x6c, 1]);
      final short = File(p.join(dir.path, 'short'))..writeAsBytesSync([0x6c, 0x6d]);
      expect(await hasGgmlMagic(good.path), isTrue);
      expect(await hasGgmlMagic(bad.path), isFalse, reason: 'big-endian byte order is not what the converters write');
      expect(await hasGgmlMagic(short.path), isFalse);
      expect(await hasGgmlMagic(p.join(dir.path, 'missing')), isFalse);
    });
  });
}
