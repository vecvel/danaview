// OWNER: AI-10

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'transcript_fixtures.dart';

JobRecord record(String id, {String project = 'p1', DateTime? startedAt, int units = 3, int done = 0}) => JobRecord(
      jobId: id,
      project: ProjectId(project),
      request: {
        'scope': {'kind': 'timeline'},
        'language': 'auto',
        'modelId': 'whisper-base-q5_1',
        'segmentation': {'preset': 'standard'},
      },
      units: [
        for (var i = 0; i < units; i++)
          JobUnitRecord(
            transcriptKey: keyOf(i + 1),
            mediaId: MediaId('m$i'),
            audioStream: 0,
            sourceRange: TimeRange(i * 1000000, (i + 1) * 1000000),
            state: i < done ? JobUnitState.done : JobUnitState.pending,
          ),
      ],
      startedAt: startedAt ?? DateTime.utc(2026, 10, 1),
    );

void main() {
  late Directory dir;
  late DateTime now;

  setUp(() {
    dir = tempDir(addTearDown);
    now = DateTime.utc(2026, 10, 3);
  });

  JobRecordStore store() => JobRecordStore(dir, clock: () => now);

  test('write then read round-trips the request, units, language and times', () async {
    final r = record('job1', done: 1).copyWith(detectedLanguage: 'ja', detectedLanguageP: 0.91);
    await store().write(r);
    final back = (await store().read('job1'))!;
    expect(back, r);
    expect(back.request['modelId'], 'whisper-base-q5_1');
    expect(back.detectedLanguage, 'ja');
    expect(back.units[0].state, JobUnitState.done);
  });

  test('doneFraction counts finished units and becomes a ResumableTranscription', () {
    final r = record('job1', units: 4, done: 3);
    expect(r.doneFraction, 0.75);
    final resumable = r.toResumable();
    expect(resumable.jobId, 'job1');
    expect(resumable.project, const ProjectId('p1'));
    expect(resumable.doneFraction, 0.75);
    expect(resumable.createdAt, DateTime.utc(2026, 10, 1));
    expect(record('x', units: 0).doneFraction, 0);
  });

  test('unit transitions rewrite the record', () async {
    var r = record('job1');
    await store().write(r);
    for (var i = 0; i < r.units.length; i++) {
      r = r.withUnitState(i, JobUnitState.transcribing, at: now).withUnitState(i, JobUnitState.done, at: now);
      await store().write(r);
    }
    final back = (await store().read('job1'))!;
    expect(back.units.every((u) => u.state == JobUnitState.done), isTrue);
    expect(back.doneFraction, 1);
  });

  test('records older than 7 days are dropped silently', () async {
    await store().write(record('old', startedAt: DateTime.utc(2026, 9, 25)));
    await store().write(record('fresh', startedAt: DateTime.utc(2026, 10, 1)));
    expect(await store().read('old'), isNull);
    expect(File(p.join(dir.path, 'old.json')).existsSync(), isFalse);
    expect((await store().read('fresh')), isNotNull);

    // Exactly 7 days is still live, a moment later it is not.
    now = DateTime.utc(2026, 10, 8);
    expect(await store().read('fresh'), isNotNull);
    now = DateTime.utc(2026, 10, 8, 0, 0, 1);
    expect(await store().read('fresh'), isNull);
  });

  test('list is newest first and skips expired and corrupt records', () async {
    await store().write(record('a', startedAt: DateTime.utc(2026, 10, 1)));
    await store().write(record('b', startedAt: DateTime.utc(2026, 10, 2)));
    await store().write(record('gone', startedAt: DateTime.utc(2026, 9, 1)));
    File(p.join(dir.path, 'bad.json')).writeAsStringSync('{nope');
    final ids = [for (final r in await store().list()) r.jobId];
    expect(ids, ['b', 'a']);
    expect(File(p.join(dir.path, 'bad.json')).existsSync(), isFalse);
  });

  test('forProject finds the latest record of one project', () async {
    await store().write(record('a', project: 'p1', startedAt: DateTime.utc(2026, 10, 1)));
    await store().write(record('b', project: 'p2', startedAt: DateTime.utc(2026, 10, 2)));
    await store().write(record('c', project: 'p1', startedAt: DateTime.utc(2026, 10, 2, 12)));
    expect((await store().forProject(const ProjectId('p1')))!.jobId, 'c');
    expect(await store().forProject(const ProjectId('nobody')), isNull);
  });

  test('delete removes the record, sweep removes expired and stray files', () async {
    await store().write(record('a'));
    await store().write(record('old', startedAt: DateTime.utc(2026, 9, 1)));
    File(p.join(dir.path, 'c.json.1.0.tmp')).writeAsStringSync('x');
    expect(await store().sweep(), 2);
    expect([for (final r in await store().list()) r.jobId], ['a']);
    await store().delete('a');
    expect(await store().list(), isEmpty);
  });

  test('unknown schema, wrong id and wrong types read as a miss', () async {
    final json = record('a').toJson()..['schema'] = 9;
    expect(() => JobRecord.fromJson(json), throwsFormatException);
    expect(() => JobRecord.fromJson(record('a').toJson()..['units'] = 'x'), throwsFormatException);
    File(p.join(dir.path, 'a.json')).writeAsStringSync(record('b').toJson().toString());
    expect(await store().read('a'), isNull);
    expect(() => store().read('../x'), throwsArgumentError);
  });

  test('the write is atomic: no temp file remains', () async {
    await store().write(record('a'));
    expect(dir.listSync().map((e) => p.basename(e.path)), ['a.json']);
  });
}
