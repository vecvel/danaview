// OWNER: AI-10
//
// Transcript file schema 1 (ai.md §8.4): absolute SOURCE microseconds, words with timestamps and
// probabilities, language, model sha and params version. This is a cache, not project data:
// unknown schema values are discarded and regenerated.

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_whisper/danaview_whisper.dart' show RawSegment;

import 'transcript_json.dart';

/// The transcript file schema this code reads and writes.
const int transcriptSchema = 1;

/// Version of the decoding parameters (`paramsVersion`, part of the cache key). Bump whenever the
/// shim's decoding parameters change: old keys then no longer match.
const int transcriptParamsVersion = 1;

/// One word with its own timing, in absolute source µs.
@immutable
final class TranscriptWord {
  /// Creates a word.
  const TranscriptWord({required this.text, required this.startUs, required this.endUs, this.probability = 1});

  /// Reads the schema-1 JSON form `{t, s, e, p}`.
  factory TranscriptWord.fromJson(Map<String, Object?> json) => TranscriptWord(
        text: jsonString(json['t'], 't'),
        startUs: jsonInt(json['s'], 's'),
        endUs: jsonInt(json['e'], 'e'),
        probability: jsonDouble(json['p'] ?? 1, 'p'),
      );

  /// Word text (never logged).
  final String text;

  /// Start, source µs.
  final TimeUs startUs;

  /// End, source µs.
  final TimeUs endUs;

  /// Token probability, 0..1.
  final double probability;

  /// `endUs - startUs`.
  TimeUs get durationUs => endUs - startUs;

  /// A copy with the given fields replaced.
  TranscriptWord copyWith({String? text, TimeUs? startUs, TimeUs? endUs, double? probability}) => TranscriptWord(
        text: text ?? this.text,
        startUs: startUs ?? this.startUs,
        endUs: endUs ?? this.endUs,
        probability: probability ?? this.probability,
      );

  /// The schema-1 JSON form.
  Map<String, Object?> toJson() => {'t': text, 's': startUs, 'e': endUs, 'p': probability};

  @override
  bool operator ==(Object other) =>
      other is TranscriptWord &&
      other.text == text &&
      other.startUs == startUs &&
      other.endUs == endUs &&
      other.probability == probability;

  @override
  int get hashCode => Object.hash(text, startUs, endUs, probability);

  @override
  String toString() => 'TranscriptWord($startUs..$endUs)';
}

/// One decoded segment in absolute source µs.
@immutable
final class TranscriptSegment {
  /// Creates a segment. [words] are unmodifiable.
  TranscriptSegment({
    required this.startUs,
    required this.endUs,
    required this.text,
    this.noSpeechProb = 0,
    this.avgLogProb = 0,
    List<TranscriptWord> words = const [],
  }) : words = List.unmodifiable(words);

  /// Converts a whisper [RawSegment] (relative to the WAV start) to absolute source time:
  /// [offsetUs] is the source time of WAV sample 0 (the unit's `sourceRange.start`).
  factory TranscriptSegment.fromRaw(RawSegment raw, {required TimeUs offsetUs}) => TranscriptSegment(
        startUs: offsetUs + raw.start.inMicroseconds,
        endUs: offsetUs + raw.end.inMicroseconds,
        text: raw.text,
        noSpeechProb: raw.noSpeechProb,
        avgLogProb: raw.avgLogProb,
        words: [
          for (final w in raw.words)
            TranscriptWord(
              text: w.text.trim(),
              startUs: offsetUs + w.start.inMicroseconds,
              endUs: offsetUs + w.end.inMicroseconds,
              probability: w.probability,
            ),
        ],
      );

  /// Reads the schema-1 JSON form.
  factory TranscriptSegment.fromJson(Map<String, Object?> json) {
    final words = json['words'];
    return TranscriptSegment(
      startUs: jsonInt(json['startUs'], 'startUs'),
      endUs: jsonInt(json['endUs'], 'endUs'),
      text: jsonString(json['text'], 'text'),
      noSpeechProb: jsonDouble(json['nsp'] ?? 0, 'nsp'),
      avgLogProb: jsonDouble(json['lp'] ?? 0, 'lp'),
      words: [
        if (words != null)
          for (final w in jsonList(words, 'words')) TranscriptWord.fromJson(jsonMap(w, 'word')),
      ],
    );
  }

  /// Start, source µs.
  final TimeUs startUs;

  /// End, source µs.
  final TimeUs endUs;

  /// Text (never logged).
  final String text;

  /// whisper no-speech probability.
  final double noSpeechProb;

  /// Mean token log probability.
  final double avgLogProb;

  /// Words, when token timestamps were on.
  final List<TranscriptWord> words;

  /// `endUs - startUs`.
  TimeUs get durationUs => endUs - startUs;

  /// A copy with the given fields replaced.
  TranscriptSegment copyWith({
    TimeUs? startUs,
    TimeUs? endUs,
    String? text,
    double? noSpeechProb,
    double? avgLogProb,
    List<TranscriptWord>? words,
  }) =>
      TranscriptSegment(
        startUs: startUs ?? this.startUs,
        endUs: endUs ?? this.endUs,
        text: text ?? this.text,
        noSpeechProb: noSpeechProb ?? this.noSpeechProb,
        avgLogProb: avgLogProb ?? this.avgLogProb,
        words: words ?? this.words,
      );

  /// The schema-1 JSON form.
  Map<String, Object?> toJson() => {
        'startUs': startUs,
        'endUs': endUs,
        'text': text,
        'nsp': noSpeechProb,
        'lp': avgLogProb,
        'words': [for (final w in words) w.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is TranscriptSegment &&
      other.startUs == startUs &&
      other.endUs == endUs &&
      other.text == text &&
      other.noSpeechProb == noSpeechProb &&
      other.avgLogProb == avgLogProb &&
      const ListEquality<TranscriptWord>().equals(other.words, words);

  @override
  int get hashCode => Object.hash(startUs, endUs, text, noSpeechProb, avgLogProb, Object.hashAll(words));

  @override
  String toString() => 'TranscriptSegment($startUs..$endUs, ${words.length} words)';
}

/// Engine that produced a transcript.
@immutable
final class TranscriptEngineInfo {
  /// Creates the record.
  const TranscriptEngineInfo({this.name = 'whisper.cpp', required this.version, this.shimAbi = 1});

  /// Reads the JSON form.
  factory TranscriptEngineInfo.fromJson(Map<String, Object?> json) => TranscriptEngineInfo(
        name: jsonString(json['name'], 'name'),
        version: jsonString(json['version'], 'version'),
        shimAbi: jsonInt(json['shimAbi'], 'shimAbi'),
      );

  /// `whisper.cpp`.
  final String name;

  /// Engine version (`1.9.4`).
  final String version;

  /// Shim C ABI version.
  final int shimAbi;

  /// The JSON form.
  Map<String, Object?> toJson() => {'name': name, 'version': version, 'shimAbi': shimAbi};

  @override
  bool operator ==(Object other) =>
      other is TranscriptEngineInfo && other.name == name && other.version == version && other.shimAbi == shimAbi;

  @override
  int get hashCode => Object.hash(name, version, shimAbi);
}

/// Model that produced a transcript.
@immutable
final class TranscriptModelInfo {
  /// Creates the record.
  const TranscriptModelInfo({required this.id, required this.sha256});

  /// Reads the JSON form.
  factory TranscriptModelInfo.fromJson(Map<String, Object?> json) =>
      TranscriptModelInfo(id: jsonString(json['id'], 'id'), sha256: jsonString(json['sha256'], 'sha256'));

  /// Catalog id.
  final String id;

  /// Model file sha256.
  final String sha256;

  /// The JSON form.
  Map<String, Object?> toJson() => {'id': id, 'sha256': sha256};

  @override
  bool operator ==(Object other) => other is TranscriptModelInfo && other.id == id && other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(id, sha256);
}

/// Normalizes [ranges]: sorted, empty ranges removed, overlapping or touching ranges merged.
List<TimeRange> normalizeRanges(Iterable<TimeRange> ranges) {
  final sorted = ranges.where((r) => !r.isEmpty).toList()..sort((a, b) => a.start.compareTo(b.start));
  final out = <TimeRange>[];
  for (final r in sorted) {
    if (out.isNotEmpty && r.start <= out.last.end) {
      if (r.end > out.last.end) out[out.length - 1] = TimeRange(out.last.start, r.end);
    } else {
      out.add(r);
    }
  }
  return out;
}

/// Whether one range of the normalized [covered] list contains all of [range].
bool rangesCover(List<TimeRange> covered, TimeRange range) {
  if (range.isEmpty) return true;
  for (final c in covered) {
    if (c.start <= range.start && c.end >= range.end) return true;
  }
  return false;
}

/// Where a transcript's audio came from and which source ranges it covers.
@immutable
final class TranscriptSource {
  /// Creates the record; [covered] is normalized.
  TranscriptSource({required this.mediaFingerprint, required this.audioStream, required Iterable<TimeRange> covered})
      : covered = List.unmodifiable(normalizeRanges(covered));

  /// Reads the JSON form `{mediaFingerprint, audioStream, covered: [{startUs, endUs}]}`.
  factory TranscriptSource.fromJson(Map<String, Object?> json) => TranscriptSource(
        mediaFingerprint: jsonString(json['mediaFingerprint'], 'mediaFingerprint'),
        audioStream: jsonInt(json['audioStream'], 'audioStream'),
        covered: [
          for (final c in jsonList(json['covered'], 'covered')) jsonRange(jsonMap(c, 'covered range')),
        ],
      );

  /// `quickHash` of the media.
  final String mediaFingerprint;

  /// Audio stream index (0 = first).
  final int audioStream;

  /// Covered source ranges, sorted and merged.
  final List<TimeRange> covered;

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'mediaFingerprint': mediaFingerprint,
        'audioStream': audioStream,
        'covered': [
          for (final r in covered) {'startUs': r.start, 'endUs': r.end},
        ],
      };

  @override
  bool operator ==(Object other) =>
      other is TranscriptSource &&
      other.mediaFingerprint == mediaFingerprint &&
      other.audioStream == audioStream &&
      const ListEquality<TimeRange>().equals(other.covered, covered);

  @override
  int get hashCode => Object.hash(mediaFingerprint, audioStream, Object.hashAll(covered));
}

/// The language a transcript was decoded in.
@immutable
final class TranscriptLanguageInfo {
  /// Creates the record.
  const TranscriptLanguageInfo({required this.code, this.detected = false, this.probability});

  /// Reads the JSON form `{code, detected, p}`.
  factory TranscriptLanguageInfo.fromJson(Map<String, Object?> json) => TranscriptLanguageInfo(
        code: jsonString(json['code'], 'code'),
        detected: json['detected'] == true,
        probability: json['p'] == null ? null : jsonDouble(json['p'], 'p'),
      );

  /// whisper code.
  final String code;

  /// Whether detected rather than chosen.
  final bool detected;

  /// Detection probability.
  final double? probability;

  /// The JSON form.
  Map<String, Object?> toJson() => {'code': code, 'detected': detected, if (probability != null) 'p': probability};

  @override
  bool operator ==(Object other) =>
      other is TranscriptLanguageInfo &&
      other.code == code &&
      other.detected == detected &&
      other.probability == probability;

  @override
  int get hashCode => Object.hash(code, detected, probability);
}

/// Decoding parameters that shaped a transcript.
@immutable
final class TranscriptParams {
  /// Creates the record.
  const TranscriptParams({
    this.version = transcriptParamsVersion,
    this.vad = true,
    this.tokenTimestamps = true,
    this.suppressNst = true,
  });

  /// Reads the JSON form.
  factory TranscriptParams.fromJson(Map<String, Object?> json) => TranscriptParams(
        version: jsonInt(json['version'], 'version'),
        vad: json['vad'] == true,
        tokenTimestamps: json['tokenTimestamps'] == true,
        suppressNst: json['suppressNst'] == true,
      );

  /// `paramsVersion`.
  final int version;

  /// Whether Silero VAD gated the audio.
  final bool vad;

  /// Whether word timestamps were requested.
  final bool tokenTimestamps;

  /// Whether `[music]` style annotations were suppressed.
  final bool suppressNst;

  /// The JSON form.
  Map<String, Object?> toJson() =>
      {'version': version, 'vad': vad, 'tokenTimestamps': tokenTimestamps, 'suppressNst': suppressNst};

  @override
  bool operator ==(Object other) =>
      other is TranscriptParams &&
      other.version == version &&
      other.vad == vad &&
      other.tokenTimestamps == tokenTimestamps &&
      other.suppressNst == suppressNst;

  @override
  int get hashCode => Object.hash(version, vad, tokenTimestamps, suppressNst);
}

/// A normalized transcript of one media/audio stream (schema 1).
@immutable
final class TranscriptFile {
  /// Creates a transcript. [segments] are unmodifiable.
  TranscriptFile({
    this.schema = transcriptSchema,
    required this.key,
    required this.engine,
    required this.model,
    required this.source,
    required this.language,
    this.params = const TranscriptParams(),
    List<TranscriptSegment> segments = const [],
    required this.createdAt,
  }) : segments = List.unmodifiable(segments);

  /// Reads the schema-1 JSON form. Throws [FormatException] for anything else (an unknown schema
  /// included): the cache then discards the file and regenerates it.
  factory TranscriptFile.fromJson(Map<String, Object?> json) {
    final schema = json['schema'];
    if (schema != transcriptSchema) throw FormatException('Unsupported transcript schema $schema');
    try {
      return TranscriptFile(
        key: jsonString(json['key'], 'key'),
        engine: TranscriptEngineInfo.fromJson(jsonMap(json['engine'], 'engine')),
        model: TranscriptModelInfo.fromJson(jsonMap(json['model'], 'model')),
        source: TranscriptSource.fromJson(jsonMap(json['source'], 'source')),
        language: TranscriptLanguageInfo.fromJson(jsonMap(json['language'], 'language')),
        params: TranscriptParams.fromJson(jsonMap(json['params'], 'params')),
        segments: [
          for (final s in jsonList(json['segments'], 'segments')) TranscriptSegment.fromJson(jsonMap(s, 'segment'))
        ],
        createdAt: DateTime.parse(jsonString(json['createdAt'], 'createdAt')),
      );
    } on FormatException {
      rethrow;
    } on Object catch (e) {
      throw FormatException('Malformed transcript: $e');
    }
  }

  /// Schema version (1).
  final int schema;

  /// The `TranscriptKey` (file name stem).
  final String key;

  /// Engine.
  final TranscriptEngineInfo engine;

  /// Model.
  final TranscriptModelInfo model;

  /// Source media, stream and covered ranges.
  final TranscriptSource source;

  /// Language.
  final TranscriptLanguageInfo language;

  /// Decoding parameters.
  final TranscriptParams params;

  /// Segments in source order.
  final List<TranscriptSegment> segments;

  /// Creation time (UTC).
  final DateTime createdAt;

  /// Total number of words.
  int get wordCount => segments.fold(0, (n, s) => n + s.words.length);

  /// Whether one covered range contains all of [range] (superset reuse).
  bool covers(TimeRange range) => rangesCover(source.covered, range);

  /// A copy with the given fields replaced.
  TranscriptFile copyWith({
    String? key,
    TranscriptEngineInfo? engine,
    TranscriptModelInfo? model,
    TranscriptSource? source,
    TranscriptLanguageInfo? language,
    TranscriptParams? params,
    List<TranscriptSegment>? segments,
    DateTime? createdAt,
  }) =>
      TranscriptFile(
        schema: schema,
        key: key ?? this.key,
        engine: engine ?? this.engine,
        model: model ?? this.model,
        source: source ?? this.source,
        language: language ?? this.language,
        params: params ?? this.params,
        segments: segments ?? this.segments,
        createdAt: createdAt ?? this.createdAt,
      );

  /// The transcript restricted to [range]: segments that overlap it, with only the words that
  /// overlap it, and `covered` clipped to it. The unit's padded range is what callers pass.
  TranscriptFile slice(TimeRange range) {
    final out = <TranscriptSegment>[];
    for (final s in segments) {
      if (s.endUs <= range.start || s.startUs >= range.end) continue;
      if (s.words.isEmpty) {
        out.add(s);
        continue;
      }
      final words = [
        for (final w in s.words)
          if (w.endUs > range.start && w.startUs < range.end) w,
      ];
      if (words.isEmpty) continue;
      out.add(words.length == s.words.length ? s : s.copyWith(words: words));
    }
    final covered = <TimeRange>[
      for (final c in source.covered)
        if (c.intersect(range) case final r?) r,
    ];
    return copyWith(
      segments: out,
      source: TranscriptSource(
        mediaFingerprint: source.mediaFingerprint,
        audioStream: source.audioStream,
        covered: covered,
      ),
    );
  }

  /// The schema-1 JSON form.
  Map<String, Object?> toJson() => {
        'schema': schema,
        'key': key,
        'engine': engine.toJson(),
        'model': model.toJson(),
        'source': source.toJson(),
        'language': language.toJson(),
        'params': params.toJson(),
        'segments': [for (final s in segments) s.toJson()],
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      other is TranscriptFile &&
      other.schema == schema &&
      other.key == key &&
      other.engine == engine &&
      other.model == model &&
      other.source == source &&
      other.language == language &&
      other.params == params &&
      other.createdAt == createdAt &&
      const ListEquality<TranscriptSegment>().equals(other.segments, segments);

  @override
  int get hashCode =>
      Object.hash(schema, key, engine, model, source, language, params, createdAt, Object.hashAll(segments));
}
