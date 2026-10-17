// OWNER: AI-10

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'transcript_fixtures.dart';

void main() {
  late Directory dir;
  late DateTime now;
  DateTime clock() => now = now.add(const Duration(seconds: 1));

  setUp(() {
    dir = tempDir(addTearDown);
    now = DateTime.utc(2026, 10, 7);
  });

  TranscriptCache cache({int? maxBytes}) => TranscriptCache(dir, maxBytes: maxBytes ?? transcriptCacheBudgetBytes, clock: clock);

  test('write then read returns the same transcript', () async {
    final c = cache();
    final t = transcript(keyOf(1));
    await c.write(t);
    expect(await c.read(keyOf(1)), t);
    expect(await c.keys(), [keyOf(1)]);
    expect(await c.read(keyOf(2)), isNull);
  });

  test('the default budget is 64 MiB', () {
    expect(transcriptCacheBudgetBytes, 64 * 1024 * 1024);
    expect(TranscriptCache(dir).maxBytes, 64 * 1024 * 1024);
  });

  group('superset-range reuse', () {
    test('a covering transcript is reused and sliced to the requested range', () async {
      final c = cache();
      await c.write(transcript(keyOf(1), coveredMs: 60000));
      final hit = await c.lookup(keyOf(1), const TimeRange(0, 4000000));
      expect(hit, isNotNull);
      expect(texts(hit!.segments), ['hello brave new world']);
      expect(hit.source.covered, [const TimeRange(0, 4000000)]);
    });

    test('exactly the covered range is a hit', () async {
      final c = cache();
      await c.write(transcript(keyOf(1), coveredMs: 60000));
      expect(await c.covers(keyOf(1), const TimeRange(0, 60000000)), isTrue);
    });

    test('partial coverage is a miss in v1', () async {
      final c = cache();
      await c.write(transcript(keyOf(1), coveredMs: 60000));
      expect(await c.lookup(keyOf(1), const TimeRange(50000000, 70000000)), isNull);
      expect(await c.lookup(keyOf(1), const TimeRange(-1000000, 5000000)), isNull);
    });

    test('a later wider run replaces the covered part and keeps the rest', () async {
      final c = cache();
      await c.write(transcript(keyOf(1), coveredStartMs: 0, coveredMs: 20000, segments: [seg(1000, 3000, 'old one'), seg(15000, 17000, 'old two')]));
      await c.write(transcript(keyOf(1), coveredStartMs: 10000, coveredMs: 30000, segments: [seg(16000, 18000, 'new two'), seg(30000, 32000, 'new three')]));
      final t = (await c.read(keyOf(1)))!;
      expect(texts(t.segments), ['old one', 'new two', 'new three']);
      expect(t.source.covered, [const TimeRange(0, 40000000)]);
      expect(await c.covers(keyOf(1), const TimeRange(0, 40000000)), isTrue);
    });

    test('a different media fingerprint under the same key is replaced, not merged', () async {
      final c = cache();
      await c.write(transcript(keyOf(1), fingerprint: 'a', segments: [seg(1000, 2000, 'from a')]));
      await c.write(transcript(keyOf(1), fingerprint: 'b', coveredMs: 5000, segments: [seg(1000, 2000, 'from b')]));
      final t = (await c.read(keyOf(1)))!;
      expect(texts(t.segments), ['from b']);
      expect(t.source.covered, [const TimeRange(0, 5000000)]);
    });
  });

  group('corrupt files are ignored and regenerated', () {
    Future<void> poison(String content) async => File(p.join(dir.path, '${keyOf(1)}.json')).writeAsString(content);

    test('garbage, truncated JSON, wrong types, wrong schema and wrong key all read as a miss and are deleted', () async {
      final c = cache();
      final good = jsonEncode(transcript(keyOf(1)).toJson());
      final wrongSchema = jsonEncode((transcript(keyOf(1)).toJson())..['schema'] = 7);
      final wrongKey = jsonEncode(transcript(keyOf(2)).toJson());
      final wrongType = jsonEncode((transcript(keyOf(1)).toJson())..['segments'] = {'a': 1});
      for (final bad in ['not json at all', good.substring(0, good.length ~/ 2), '[1,2,3]', wrongSchema, wrongKey, wrongType, '']) {
        await poison(bad);
        expect(await c.read(keyOf(1)), isNull, reason: bad.length > 40 ? bad.substring(0, 40) : bad);
        expect(File(p.join(dir.path, '${keyOf(1)}.json')).existsSync(), isFalse);
      }
    });

    test('after a corrupt file the transcript can be regenerated and read back', () async {
      final c = cache();
      await poison('{broken');
      expect(await c.lookup(keyOf(1), const TimeRange(0, 1000000)), isNull);
      await c.write(transcript(keyOf(1)));
      expect(await c.read(keyOf(1)), isNotNull);
    });

    test('writing over a corrupt file does not try to merge it', () async {
      final c = cache();
      await poison('{broken');
      final t = transcript(keyOf(1));
      await c.write(t);
      expect(await c.read(keyOf(1)), t);
    });

    test('stray temp files are not listed, counted or read', () async {
      final c = cache();
      await c.write(transcript(keyOf(1)));
      File(p.join(dir.path, '${keyOf(2)}.json.123.0.tmp')).writeAsStringSync('x' * 1000);
      expect(await c.keys(), [keyOf(1)]);
      await c.clear();
      expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')), isEmpty);
      expect(await c.keys(), [keyOf(1)]);
    });
  });

  group('atomic writes', () {
    test('a crash before the rename leaves the previous transcript intact and no temp file behind', () async {
      final c = cache();
      final old = transcript(keyOf(1), segments: [seg(1000, 2000, 'old')]);
      await c.write(old);
      c.beforeCommit = () async => throw const FileSystemException('simulated crash');
      await expectLater(c.write(transcript(keyOf(1), segments: [seg(1000, 2000, 'new')])), throwsA(isA<FileSystemException>()));
      c.beforeCommit = null;
      expect(await c.read(keyOf(1)), old);
      expect(dir.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
    });

    test('a crash on the first write leaves nothing readable', () async {
      final c = cache();
      c.beforeCommit = () async => throw const FileSystemException('simulated crash');
      await expectLater(c.write(transcript(keyOf(1))), throwsA(isA<FileSystemException>()));
      c.beforeCommit = null;
      expect(await c.read(keyOf(1)), isNull);
      expect(dir.listSync(), isEmpty);
    });

    test('readers during a write see either the old or the new file, never a torn one', () async {
      final c = cache();
      await c.write(transcript(keyOf(1), segments: [seg(1000, 2000, 'old')]));
      var tornSeen = false;
      var done = false;
      final reader = () async {
        while (!done) {
          final r = await c.read(keyOf(1));
          if (r == null) tornSeen = true;
          await Future<void>.delayed(Duration.zero);
        }
      }();
      for (var i = 0; i < 20; i++) {
        await c.write(transcript(keyOf(1), segments: [seg(1000, 2000, 'v$i')]));
      }
      done = true;
      await reader;
      expect(tornSeen, isFalse);
    });

    test('rejects keys that are not file-name safe', () async {
      expect(() => cache().read('../x'), throwsArgumentError);
      expect(() => cache().write(transcript('a/b')), throwsArgumentError);
    });
  });

  group('LRU eviction', () {
    TranscriptFile padded(int n, {int words = 400}) => transcript(
          keyOf(n),
          segments: [
            for (var i = 0; i < words; i++) seg(i * 1000, i * 1000 + 800, 'word$i lorem ipsum'),
          ],
        );

    test('evicts the least recently used transcripts beyond the budget', () async {
      final probe = cache();
      await probe.write(padded(99));
      final one = await probe.totalBytes();
      await probe.clear(everything: true);

      final c = cache(maxBytes: (one * 3.5).floor());
      for (var n = 1; n <= 3; n++) {
        await c.write(padded(n));
      }
      expect(await c.keys(), unorderedEquals([keyOf(1), keyOf(2), keyOf(3)]));
      // Touch 1 so 2 is now the oldest.
      expect(await c.read(keyOf(1)), isNotNull);
      await c.write(padded(4));
      final keys = await c.keys();
      expect(keys, unorderedEquals([keyOf(1), keyOf(3), keyOf(4)]));
      expect(await c.totalBytes(), lessThanOrEqualTo((one * 3.5).floor()));
    });

    test('never evicts the transcript just written, even when it alone exceeds the budget', () async {
      final c = cache(maxBytes: 100);
      await c.write(padded(1));
      expect(await c.keys(), [keyOf(1)]);
      await c.write(padded(2));
      expect(await c.keys(), [keyOf(2)]);
    });

    test('protected keys stay', () async {
      final probe = cache();
      await probe.write(padded(99));
      final one = await probe.totalBytes();
      await probe.clear(everything: true);
      final c = cache(maxBytes: one + one ~/ 2);
      await c.write(padded(1));
      await c.write(padded(2));
      expect(await c.keys(), [keyOf(2)]);
      await c.write(padded(1));
      expect(await c.evict(protect: {keyOf(1), keyOf(2)}), 0);
    });

    test('a read of an entry makes it the most recently used', () async {
      final c = cache();
      await c.write(padded(1, words: 5));
      await c.write(padded(2, words: 5));
      final before = File(p.join(dir.path, '${keyOf(1)}.json')).lastModifiedSync();
      await c.read(keyOf(1));
      expect(File(p.join(dir.path, '${keyOf(1)}.json')).lastModifiedSync().isAfter(before), isTrue);
    });
  });

  test('sweepPartials removes checkpoints older than 30 days only', () async {
    final c = cache();
    await dir.create(recursive: true);
    final old = File(p.join(dir.path, '${keyOf(1)}.partial.jsonl'))..writeAsStringSync('x');
    final fresh = File(p.join(dir.path, '${keyOf(2)}.partial.jsonl'))..writeAsStringSync('x');
    final base = DateTime.now();
    old.setLastModifiedSync(base.subtract(const Duration(days: 31)));
    fresh.setLastModifiedSync(base.subtract(const Duration(days: 2)));
    final sweeping = TranscriptCache(dir, clock: () => base);
    expect(await sweeping.sweepPartials(), 1);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(await c.keys(), isEmpty, reason: 'partial files are not transcripts');
  });
}
