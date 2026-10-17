// OWNER: AI-10
//
// Job records for resume (ai.md §8.6) under `<support>/danaview/speech/jobs/<jobId>.json`: the
// serializable request, the units with their state, the detected language and the start time.
// Written at start and on each unit transition (atomically); records older than 7 days are
// dropped silently.

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/model.dart';

import '../contracts/transcription_service.dart' show ResumableTranscription;
import 'transcript_json.dart';

/// Job record schema.
const int jobRecordSchema = 1;

/// Records older than this are dropped.
const Duration jobRecordExpiry = Duration(days: 7);

/// Where a unit is in the pipeline.
enum JobUnitState {
  /// Waiting.
  pending,

  /// Audio being extracted.
  extracting,

  /// Being transcribed (a checkpoint may exist).
  transcribing,

  /// Transcript written to the cache.
  done,
}

/// One unit of a job record.
@immutable
final class JobUnitRecord {
  /// Creates the record.
  const JobUnitRecord({
    required this.transcriptKey,
    required this.mediaId,
    required this.audioStream,
    required this.sourceRange,
    this.state = JobUnitState.pending,
  });

  /// Reads the JSON form.
  factory JobUnitRecord.fromJson(Map<String, Object?> json) {
    final stateName = jsonString(json['state'], 'state');
    return JobUnitRecord(
      transcriptKey: jsonString(json['key'], 'key'),
      mediaId: MediaId(jsonString(json['media'], 'media')),
      audioStream: jsonInt(json['audioStream'], 'audioStream'),
      sourceRange: TimeRange(
        jsonInt(json['startUs'], 'startUs'),
        jsonInt(json['endUs'], 'endUs'),
      ),
      state: JobUnitState.values
          .firstWhere((s) => s.name == stateName, orElse: () => throw FormatException('Unknown unit state $stateName')),
    );
  }

  /// The unit's transcript cache key (also its checkpoint name).
  final String transcriptKey;

  /// Pool asset.
  final MediaId mediaId;

  /// Audio stream (0 = first).
  final int audioStream;

  /// Padded source range being transcribed.
  final TimeRange sourceRange;

  /// State.
  final JobUnitState state;

  /// A copy with the given state.
  JobUnitRecord withState(JobUnitState state) => JobUnitRecord(
        transcriptKey: transcriptKey,
        mediaId: mediaId,
        audioStream: audioStream,
        sourceRange: sourceRange,
        state: state,
      );

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'key': transcriptKey,
        'media': mediaId.value,
        'audioStream': audioStream,
        'startUs': sourceRange.start,
        'endUs': sourceRange.end,
        'state': state.name,
      };

  @override
  bool operator ==(Object other) =>
      other is JobUnitRecord &&
      other.transcriptKey == transcriptKey &&
      other.mediaId == mediaId &&
      other.audioStream == audioStream &&
      other.sourceRange == sourceRange &&
      other.state == state;

  @override
  int get hashCode => Object.hash(transcriptKey, mediaId, audioStream, sourceRange, state);
}

/// A resumable job.
@immutable
final class JobRecord {
  /// Creates a record. [request] is the JSON form of the transcription request (the pipeline
  /// owns its shape); it must contain only JSON-encodable values.
  JobRecord({
    required this.jobId,
    required this.project,
    required Map<String, Object?> request,
    required List<JobUnitRecord> units,
    this.detectedLanguage,
    this.detectedLanguageP,
    required this.startedAt,
    DateTime? updatedAt,
  })  : request = Map.unmodifiable(request),
        units = List.unmodifiable(units),
        updatedAt = updatedAt ?? startedAt;

  /// Reads the JSON form. Throws [FormatException] for unknown schemas and malformed data.
  factory JobRecord.fromJson(Map<String, Object?> json) {
    if (json['schema'] != jobRecordSchema) throw FormatException('Unsupported job record schema ${json['schema']}');
    try {
      return JobRecord(
        jobId: jsonString(json['jobId'], 'jobId'),
        project: ProjectId(jsonString(json['project'], 'project')),
        request: jsonMap(json['request'], 'request'),
        units: [for (final u in jsonList(json['units'], 'units')) JobUnitRecord.fromJson(jsonMap(u, 'unit'))],
        detectedLanguage: json['language'] == null ? null : jsonString(json['language'], 'language'),
        detectedLanguageP: json['languageP'] == null ? null : jsonDouble(json['languageP'], 'languageP'),
        startedAt: DateTime.parse(jsonString(json['startedAt'], 'startedAt')),
        updatedAt: DateTime.parse(jsonString(json['updatedAt'], 'updatedAt')),
      );
    } on FormatException {
      rethrow;
    } on Object catch (e) {
      throw FormatException('Malformed job record: $e');
    }
  }

  /// Job id (file name stem).
  final String jobId;

  /// Project the job belongs to.
  final ProjectId project;

  /// Serializable request.
  final Map<String, Object?> request;

  /// Units with state.
  final List<JobUnitRecord> units;

  /// Detected language (whisper code), once known.
  final String? detectedLanguage;

  /// Detection probability.
  final double? detectedLanguageP;

  /// When the job started (UTC); expiry counts from here.
  final DateTime startedAt;

  /// Last write.
  final DateTime updatedAt;

  /// Fraction of units done (0 for a record without units).
  double get doneFraction => units.isEmpty ? 0 : units.where((u) => u.state == JobUnitState.done).length / units.length;

  /// A copy with the given fields replaced.
  JobRecord copyWith({
    List<JobUnitRecord>? units,
    String? detectedLanguage,
    double? detectedLanguageP,
    DateTime? updatedAt,
  }) =>
      JobRecord(
        jobId: jobId,
        project: project,
        request: request,
        units: units ?? this.units,
        detectedLanguage: detectedLanguage ?? this.detectedLanguage,
        detectedLanguageP: detectedLanguageP ?? this.detectedLanguageP,
        startedAt: startedAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// A copy with unit [index] set to [state].
  JobRecord withUnitState(int index, JobUnitState state, {DateTime? at}) => copyWith(
        units: [for (var i = 0; i < units.length; i++) i == index ? units[i].withState(state) : units[i]],
        updatedAt: at,
      );

  /// The resumable-job summary shown by the Captions tool.
  ResumableTranscription toResumable() =>
      ResumableTranscription(jobId: jobId, project: project, doneFraction: doneFraction, createdAt: startedAt);

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'schema': jobRecordSchema,
        'jobId': jobId,
        'project': project.value,
        'request': request,
        'units': [for (final u in units) u.toJson()],
        if (detectedLanguage != null) 'language': detectedLanguage,
        if (detectedLanguageP != null) 'languageP': detectedLanguageP,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      other is JobRecord &&
      other.jobId == jobId &&
      other.project == project &&
      const DeepCollectionEquality().equals(other.request, request) &&
      const ListEquality<JobUnitRecord>().equals(other.units, units) &&
      other.detectedLanguage == detectedLanguage &&
      other.detectedLanguageP == detectedLanguageP &&
      other.startedAt == startedAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(jobId, project, Object.hashAll(units), detectedLanguage, startedAt, updatedAt);
}

/// Reads and writes job records.
final class JobRecordStore {
  /// Creates the store in [directory] (`<support>/danaview/speech/jobs/`).
  JobRecordStore(this.directory, {DateTime Function()? clock, this.expiry = jobRecordExpiry})
      : _clock = clock ?? DateTime.now;

  /// Where `<jobId>.json` files live.
  final Directory directory;

  /// Age after which a record is dropped.
  final Duration expiry;

  final DateTime Function() _clock;
  int _tmpCounter = 0;

  static final RegExp _validId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  File _file(String jobId) {
    if (!_validId.hasMatch(jobId)) throw ArgumentError.value(jobId, 'jobId', 'not a valid job id');
    return File(p.join(directory.path, '$jobId.json'));
  }

  /// Writes [record] atomically.
  Future<void> write(JobRecord record) async {
    final file = _file(record.jobId);
    await directory.create(recursive: true);
    final tmp = File('${file.path}.${_clock().microsecondsSinceEpoch}.${_tmpCounter++}.tmp');
    try {
      await tmp.writeAsString(jsonEncode(record.toJson()), flush: true);
      await tmp.rename(file.path);
    } on Object {
      try {
        await tmp.delete();
      } on FileSystemException {
        // Nothing to clean.
      }
      rethrow;
    }
  }

  /// The record of [jobId], or null when absent, unreadable or expired (the file is deleted).
  Future<JobRecord?> read(String jobId) async {
    final file = _file(jobId);
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException {
      return null;
    }
    JobRecord? record;
    try {
      final json = jsonDecode(text);
      if (json is Map<String, Object?>) record = JobRecord.fromJson(json);
    } on FormatException {
      record = null;
    }
    if (record == null || record.jobId != jobId || _expired(record)) {
      await _deleteQuietly(file);
      return null;
    }
    return record;
  }

  /// Every live record, newest first. Expired and unreadable ones are dropped silently.
  Future<List<JobRecord>> list() async {
    final out = <JobRecord>[];
    if (!await directory.exists()) return out;
    await for (final e in directory.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!name.endsWith('.json')) continue;
      final id = name.substring(0, name.length - '.json'.length);
      if (!_validId.hasMatch(id)) continue;
      final r = await read(id);
      if (r != null) out.add(r);
    }
    out.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return out;
  }

  /// The most recent live record of [project] that is not finished, or null.
  Future<JobRecord?> forProject(ProjectId project) async {
    for (final r in await list()) {
      if (r.project == project) return r;
    }
    return null;
  }

  /// Deletes the record of [jobId] (job finished or discarded).
  Future<void> delete(String jobId) => _deleteQuietly(_file(jobId));

  /// Deletes expired and unreadable records and stray temp files; returns how many were removed.
  Future<int> sweep() async {
    if (!await directory.exists()) return 0;
    var n = 0;
    await for (final e in directory.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name.endsWith('.tmp')) {
        await _deleteQuietly(e);
        n++;
      } else if (name.endsWith('.json')) {
        final id = name.substring(0, name.length - '.json'.length);
        if (_validId.hasMatch(id) && await read(id) == null) n++;
      }
    }
    return n;
  }

  bool _expired(JobRecord r) => _clock().difference(r.startedAt) > expiry;

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
