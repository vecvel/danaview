// OWNER: AI-10

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_transcription/vwish_transcription.dart';

import 'transcript_fixtures.dart';

CheckpointChunk chunk(int index, int startS, int endS, List<String> sentences) => CheckpointChunk(
      index: index,
      startUs: startS * 1000000,
      endUs: endS * 1000000,
      segments: [
        for (var i = 0; i < sentences.length; i++)
          seg(startS * 1000 + i * 2000, startS * 1000 + i * 2000 + 1800, sentences[i]),
      ],
    );

void main() {
  late Directory dir;
  late TranscriptCheckpoints store;

  setUp(() {
    dir = tempDir(addTearDown);
    store = TranscriptCheckpoints(dir);
  });

  test('no file means no checkpoint', () async {
    expect(await store.replay(keyOf(1)), isNull);
  });

  test('append then replay round-trips every chunk, segment and word', () async {
    final c0 = chunk(0, 100, 280, ['first sentence', 'second one here']);
    final c1 = chunk(1, 280, 455, ['third sentence']);
    await store.append(keyOf(1), c0, unitStartUs: 100000000);
    await store.append(keyOf(1), c1, unitStartUs: 100000000);

    final r = (await store.replay(keyOf(1)))!;
    expect(r.chunks.length, 2);
    expect(r.unitStartUs, 100000000);
    expect(r.resumeFromUs, 455000000);
    expect(r.skippedLines, 0);
    expect(r.segments, [...c0.segments, ...c1.segments]);
    expect(r.chunks.first.segments.first.words.first.text, 'first');
    expect(r.chunks.first.index, 0);
  });

  test('the file is JSON lines: a header then one line per chunk', () async {
    await store.append(keyOf(1), chunk(0, 0, 180, ['a b c']), unitStartUs: 0);
    await store.append(keyOf(1), chunk(1, 180, 360, ['d e f']), unitStartUs: 0);
    final lines = store.fileFor(keyOf(1)).readAsLinesSync();
    expect(store.fileFor(keyOf(1)).path.endsWith('${keyOf(1)}.partial.jsonl'), isTrue);
    expect(lines.length, 3);
    expect(lines[0], contains('"schema":1'));
    expect(lines[1], contains('"chunk":0'));
  });

  test('with no chunks yet the resume point is the unit start', () async {
    final f = store.fileFor(keyOf(1))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"schema":1,"key":"${keyOf(1)}","startUs":5000000}\n');
    expect(f.existsSync(), isTrue);
    final r = (await store.replay(keyOf(1)))!;
    expect(r.chunks, isEmpty);
    expect(r.resumeFromUs, 5000000);
  });

  test('a torn last line (killed mid-write) is skipped and the earlier chunks survive', () async {
    await store.append(keyOf(1), chunk(0, 0, 180, ['kept text']), unitStartUs: 0);
    await store.append(keyOf(1), chunk(1, 180, 360, ['also kept']), unitStartUs: 0);
    final f = store.fileFor(keyOf(1));
    final text = f.readAsStringSync();
    f.writeAsStringSync('$text{"chunk":2,"startUs":360000000,"endUs":540000000,"segments":[{"startUs":3600'); // no newline
    final r = (await store.replay(keyOf(1)))!;
    expect(r.chunks.length, 2);
    expect(r.resumeFromUs, 360000000);
    expect(r.skippedLines, 1);
  });

  test('appending after a torn line starts a fresh line and the new chunk is readable', () async {
    await store.append(keyOf(1), chunk(0, 0, 180, ['one']), unitStartUs: 0);
    final f = store.fileFor(keyOf(1));
    f.writeAsStringSync('${f.readAsStringSync()}{"chunk":1,"startUs":180000000'); // torn
    await store.append(keyOf(1), chunk(0, 180, 360, ['two']), unitStartUs: 0); // resumed run restarts at index 0
    final r = (await store.replay(keyOf(1)))!;
    expect(r.chunks.length, 2);
    expect(r.resumeFromUs, 360000000);
    expect(r.skippedLines, 1);
    expect(texts(r.segments), ['one', 'two']);
  });

  test('a gap ends the contiguous prefix: later chunks are redone', () async {
    await store.append(keyOf(1), chunk(0, 0, 180, ['a']), unitStartUs: 0);
    await store.append(keyOf(1), chunk(2, 360, 540, ['c']), unitStartUs: 0); // chunk 1 was lost
    final r = (await store.replay(keyOf(1)))!;
    expect(r.chunks.length, 1);
    expect(r.resumeFromUs, 180000000);
  });

  test('a first chunk that does not start at the unit start is not a valid prefix', () async {
    await store.append(keyOf(1), chunk(0, 50, 230, ['late']), unitStartUs: 0);
    final r = (await store.replay(keyOf(1)))!;
    expect(r.chunks, isEmpty);
    expect(r.resumeFromUs, 0);
  });

  test('a chunk rewritten after a resume replaces the stale one', () async {
    await store.append(keyOf(1), chunk(0, 0, 180, ['v1']), unitStartUs: 0);
    await store.append(keyOf(1), chunk(1, 180, 360, ['stale']), unitStartUs: 0);
    await store.append(keyOf(1), chunk(0, 180, 330, ['fresh']), unitStartUs: 0);
    final r = (await store.replay(keyOf(1)))!;
    expect(texts(r.segments), ['v1', 'fresh']);
    expect(r.resumeFromUs, 330000000);
  });

  test('a header for another key or schema discards the file', () async {
    final f = store.fileFor(keyOf(1))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"schema":1,"key":"${keyOf(2)}","startUs":0}\n{"chunk":0,"startUs":0,"endUs":1,"segments":[]}\n');
    expect(await store.replay(keyOf(1)), isNull);
    expect(f.existsSync(), isFalse);

    f.writeAsStringSync('garbage\n');
    expect(await store.replay(keyOf(1)), isNull);
    expect(f.existsSync(), isFalse);
  });

  test('delete and keys', () async {
    await store.append(keyOf(1), chunk(0, 0, 10, ['x']), unitStartUs: 0);
    await store.append(keyOf(2), chunk(0, 0, 10, ['y']), unitStartUs: 0);
    expect(await store.keys(), unorderedEquals([keyOf(1), keyOf(2)]));
    await store.delete(keyOf(1));
    expect(await store.keys(), [keyOf(2)]);
    await store.delete(keyOf(1)); // deleting twice is fine
  });

  test('checkpoint replay feeds the normalizer: raw segments in, one transcript out', () async {
    await store.append(keyOf(1), chunk(0, 0, 180, ['[MUSIC]', 'real words one']), unitStartUs: 0);
    await store.append(keyOf(1), chunk(1, 180, 360, ['real words two']), unitStartUs: 0);
    final r = (await store.replay(keyOf(1)))!;
    final n = const TranscriptNormalizer().normalize(r.segments, language: 'en');
    expect(texts(n.segments), ['real words one', 'real words two']);
  });
}
