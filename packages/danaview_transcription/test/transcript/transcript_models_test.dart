// OWNER: AI-10

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'transcript_fixtures.dart';

void main() {
  group('TranscriptKey', () {
    String key({String q = 'qh', int? stream, String m = 'msha', String lang = 'en', int pv = 1, bool vad = true}) =>
        TranscriptKey.compute(quickHash: q, audioStream: stream, modelSha256: m, language: lang, paramsVersion: pv, vad: vad);

    test('is a sha256 hex digest of the pipe-joined inputs', () {
      expect(key(), hasLength(64));
      expect(key(), matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(key(), key());
    });

    test('every input changes the key', () {
      final base = key();
      expect({
        base,
        key(q: 'other'),
        key(stream: 1),
        key(m: 'other'),
        key(lang: 'de'),
        key(pv: 2),
        key(vad: false),
      }, hasLength(7));
    });

    test('a null audio stream is the first stream', () {
      expect(key(stream: null), key(stream: 0));
    });

    test('rejects keys that could escape the directory', () {
      expect(TranscriptKey.isValid(keyOf(1)), isTrue);
      expect(TranscriptKey.isValid('../evil'), isFalse);
      expect(TranscriptKey.isValid('a/b'), isFalse);
      expect(TranscriptKey.isValid(''), isFalse);
      expect(() => TranscriptKey.check('a.b'), throwsArgumentError);
    });
  });

  group('TranscriptFile JSON (schema 1)', () {
    test('round-trips, including words, covered ranges and the engine/model records', () {
      final t = transcript(keyOf(1));
      final back = TranscriptFile.fromJson(jsonDecode(jsonEncode(t.toJson())) as Map<String, Object?>);
      expect(back, t);
      expect(back.segments.first.words.first.text, 'hello');
      expect(back.source.covered, [const TimeRange(0, 60000000)]);
    });

    test('writes the ai.md §8.4 field names', () {
      final json = transcript(keyOf(1)).toJson();
      expect(json.keys, containsAll(['schema', 'key', 'engine', 'model', 'source', 'language', 'params', 'segments', 'createdAt']));
      expect((json['engine']! as Map)['shimAbi'], 1);
      expect((json['source']! as Map).keys, containsAll(['mediaFingerprint', 'audioStream', 'covered']));
      final seg = (json['segments']! as List).first as Map;
      expect(seg.keys, containsAll(['startUs', 'endUs', 'text', 'nsp', 'lp', 'words']));
      expect((seg['words']! as List).first, containsPair('t', 'hello'));
    });

    test('an unknown schema is a FormatException', () {
      final json = transcript(keyOf(1)).toJson()..['schema'] = 2;
      expect(() => TranscriptFile.fromJson(json), throwsFormatException);
    });

    test('wrong types are FormatExceptions, never cast errors', () {
      final json = transcript(keyOf(1)).toJson()..['segments'] = 'nope';
      expect(() => TranscriptFile.fromJson(json), throwsFormatException);
    });

    test('slice keeps overlapping segments, trims words and clips the covered range', () {
      final t = transcript(keyOf(1));
      final s = t.slice(const TimeRange(2000000, 11000000));
      expect(texts(s.segments), ['hello brave new world', 'second sentence here']);
      expect([for (final w in s.segments.first.words) w.text], ['new', 'world']);
      expect(s.segments.last.words.length, lessThan(3));
      expect(s.source.covered, [const TimeRange(2000000, 11000000)]);
    });

    test('ranges are normalized and cover checks are per contiguous range', () {
      final src = TranscriptSource(
        mediaFingerprint: 'f',
        audioStream: 0,
        covered: const [TimeRange(10, 20), TimeRange(0, 10), TimeRange(30, 40), TimeRange(35, 50)],
      );
      expect(src.covered, [const TimeRange(0, 20), const TimeRange(30, 50)]);
      expect(rangesCover(src.covered, const TimeRange(5, 15)), isTrue);
      expect(rangesCover(src.covered, const TimeRange(15, 35)), isFalse);
      expect(rangesCover(src.covered, const TimeRange(30, 50)), isTrue);
    });
  });
}
