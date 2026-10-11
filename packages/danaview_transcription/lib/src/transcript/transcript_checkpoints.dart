// OWNER: AI-10
//
// Per-chunk checkpoints (ARCH §16.4 step 6, ai.md §8.2, §8.6): `<key>.partial.jsonl` next to the
// transcript cache. One header line, then one line per finished chunk, appended and flushed as the
// chunk completes. A crash can only tear the last line, which replay ignores, so everything up to
// the last complete chunk survives. Replay yields the contiguous prefix of finished chunks and the
// source time where the next whisper request resumes (`range_start`).

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/model.dart';

import 'transcript_key.dart';
import 'transcript_json.dart';
import 'transcript_models.dart';

/// Checkpoint line schema.
const int checkpointSchema = 1;

/// One finished chunk: raw (not yet normalized) segments in absolute source µs.
@immutable
final class CheckpointChunk {
  /// Creates a chunk covering `[startUs, endUs)` of the source.
  CheckpointChunk(
      {required this.index, required this.startUs, required this.endUs, List<TranscriptSegment> segments = const []})
      : segments = List.unmodifiable(segments);

  /// Reads one chunk line.
  factory CheckpointChunk.fromJson(Map<String, Object?> json) => CheckpointChunk(
        index: jsonInt(json['chunk'], 'chunk'),
        startUs: jsonInt(json['startUs'], 'startUs'),
        endUs: jsonInt(json['endUs'], 'endUs'),
        segments: [
          for (final s in jsonList(json['segments'], 'segments')) TranscriptSegment.fromJson(jsonMap(s, 'segment')),
        ],
      );

  /// Chunk index within the request that produced it (restarts at 0 after a resume).
  final int index;

  /// Source time where the chunk begins.
  final TimeUs startUs;

  /// Source time where the chunk ends (the next chunk starts here).
  final TimeUs endUs;

  /// The chunk's segments.
  final List<TranscriptSegment> segments;

  /// The JSON line form.
  Map<String, Object?> toJson() => {
        'chunk': index,
        'startUs': startUs,
        'endUs': endUs,
        'segments': [for (final s in segments) s.toJson()],
      };
}

/// What replaying a checkpoint file found.
@immutable
final class CheckpointReplay {
  /// Creates the result.
  CheckpointReplay({required this.chunks, required this.unitStartUs, this.skippedLines = 0})
      : segments = List.unmodifiable([for (final c in chunks) ...c.segments]);

  /// The contiguous prefix of finished chunks, in source order.
  final List<CheckpointChunk> chunks;

  /// Source start of the unit the checkpoint belongs to (from the header).
  final TimeUs unitStartUs;

  /// Lines that could not be read (a torn last line, or garbage).
  final int skippedLines;

  /// All segments of [chunks].
  final List<TranscriptSegment> segments;

  /// Source time of the first sample not yet transcribed: the end of the last contiguous chunk,
  /// or [unitStartUs] when there is none.
  TimeUs get resumeFromUs => chunks.isEmpty ? unitStartUs : chunks.last.endUs;
}

/// Reads and writes checkpoints.
final class TranscriptCheckpoints {
  /// Creates the store in [directory] (the transcripts directory).
  TranscriptCheckpoints(this.directory);

  /// Where `<key>.partial.jsonl` files live.
  final Directory directory;

  /// Largest gap between one chunk's end and the next chunk's start still counted as contiguous.
  static const int contiguityToleranceUs = 1000;

  /// The checkpoint file of [key].
  File fileFor(String key) {
    TranscriptKey.check(key);
    return File(p.join(directory.path, '$key.partial.jsonl'));
  }

  /// Appends a finished [chunk] and flushes. The first append writes the header carrying
  /// [unitStartUs] (the source time the unit's transcription starts at).
  Future<void> append(String key, CheckpointChunk chunk, {required TimeUs unitStartUs}) async {
    final file = fileFor(key);
    await directory.create(recursive: true);
    final lines = StringBuffer();
    final exists = await file.exists();
    if (!exists || await file.length() == 0) {
      lines.writeln(jsonEncode({'schema': checkpointSchema, 'key': key, 'startUs': unitStartUs}));
    } else if (!await _endsWithNewline(file)) {
      // A previous run was killed in the middle of a line; start a fresh line.
      lines.writeln();
    }
    lines.writeln(jsonEncode(chunk.toJson()));
    final sink = file.openWrite(mode: FileMode.append);
    try {
      sink.write(lines.toString());
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// Replays the checkpoint of [key], or null when there is none (or its header is for another
  /// key or schema: the file is then deleted).
  Future<CheckpointReplay?> replay(String key) async {
    final file = fileFor(key);
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException {
      return null;
    }
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty) {
      await _deleteQuietly(file);
      return null;
    }
    TimeUs unitStart;
    try {
      final header = jsonMap(jsonDecode(lines.first), 'header');
      if (header['schema'] != checkpointSchema || header['key'] != key) throw const FormatException('foreign header');
      unitStart = jsonInt(header['startUs'], 'startUs');
    } on FormatException {
      await _deleteQuietly(file);
      return null;
    }

    var skipped = 0;
    // Later lines win: a resumed run re-covers the range after the last good chunk.
    final all = <CheckpointChunk>[];
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      try {
        final c = CheckpointChunk.fromJson(jsonMap(jsonDecode(line), 'chunk'));
        if (c.endUs < c.startUs) throw const FormatException('negative chunk');
        all.removeWhere((o) => o.startUs >= c.startUs);
        all.add(c);
      } on FormatException {
        skipped++;
      }
    }
    all.sort((a, b) => a.startUs.compareTo(b.startUs));

    final chain = <CheckpointChunk>[];
    var covered = unitStart;
    for (final c in all) {
      if (c.startUs > covered + contiguityToleranceUs) break;
      if (c.endUs <= covered && chain.isNotEmpty) continue;
      chain.add(c);
      covered = c.endUs;
    }
    return CheckpointReplay(chunks: chain, unitStartUs: unitStart, skippedLines: skipped);
  }

  /// Deletes the checkpoint of [key] (after the transcript was written).
  Future<void> delete(String key) => _deleteQuietly(fileFor(key));

  /// Keys that have a checkpoint file.
  Future<List<String>> keys() async {
    final out = <String>[];
    if (!await directory.exists()) return out;
    await for (final e in directory.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!name.endsWith('.partial.jsonl')) continue;
      final key = name.substring(0, name.length - '.partial.jsonl'.length);
      if (TranscriptKey.isValid(key)) out.add(key);
    }
    return out;
  }

  static Future<bool> _endsWithNewline(File file) async {
    final raf = await file.open();
    try {
      final len = await raf.length();
      if (len == 0) return true;
      await raf.setPosition(len - 1);
      return (await raf.readByte()) == 0x0A;
    } finally {
      await raf.close();
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
