// OWNER: AI-10
//
// The on-disk transcript cache under `<support>/danaview/speech/transcripts/` (ai.md §5.2, §8.4):
// one `<key>.json` per TranscriptKey, atomic writes (temp file + rename), LRU eviction at a
// 64 MiB budget (last use = file modification time), unreadable or unknown-schema files ignored
// and deleted so they are regenerated, and superset-range reuse (a transcript whose covered range
// contains the requested range is returned sliced to it).

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/model.dart';

import 'transcript_key.dart';
import 'transcript_models.dart';

/// Default transcript cache budget.
const int transcriptCacheBudgetBytes = 64 * 1024 * 1024;

/// The transcript cache.
final class TranscriptCache {
  /// Creates a cache in [directory] (created on first write). [clock] stamps last use (tests
  /// inject a fake one so LRU order is deterministic).
  TranscriptCache(this.directory, {this.maxBytes = transcriptCacheBudgetBytes, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// `<support>/danaview/speech/transcripts/`.
  final Directory directory;

  /// Budget in bytes; the least recently used transcripts are evicted beyond it.
  final int maxBytes;

  final DateTime Function() _clock;
  int _tmpCounter = 0;

  /// Test hook: runs after the temp file is fully written and before it is renamed into place
  /// (to simulate a crash in the middle of a write).
  @visibleForTesting
  Future<void> Function()? beforeCommit;

  File _file(String key) {
    TranscriptKey.check(key);
    return File(p.join(directory.path, '$key.json'));
  }

  /// Reads the transcript stored under [key], or null when absent or unreadable. A corrupt,
  /// truncated, wrong-schema or wrong-key file is deleted. A hit counts as a use (LRU).
  Future<TranscriptFile?> read(String key) async {
    final file = _file(key);
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException {
      return null;
    }
    TranscriptFile? parsed;
    try {
      final json = jsonDecode(text);
      if (json is Map<String, Object?>) {
        final t = TranscriptFile.fromJson(json);
        if (t.key == key) parsed = t;
      }
    } on FormatException {
      parsed = null;
    }
    if (parsed == null) {
      await _deleteQuietly(file);
      return null;
    }
    await _touch(file);
    return parsed;
  }

  /// Superset-range reuse: the transcript under [key] sliced to [range], or null when nothing is
  /// stored or no covered range contains all of [range] (partial coverage is a miss in v1).
  Future<TranscriptFile?> lookup(String key, TimeRange range) async {
    final t = await read(key);
    if (t == null || !t.covers(range)) return null;
    return t.slice(range);
  }

  /// Whether a transcript covering [range] is stored under [key] (counts as a use).
  Future<bool> covers(String key, TimeRange range) async => (await lookup(key, range)) != null;

  /// Stores [transcript] under its key, merged with what is already there: covered ranges are
  /// united and stored segments inside the newly covered ranges are replaced by the new ones, so a
  /// later, wider run never loses earlier work. The write is atomic (temp file + rename); other
  /// transcripts are then evicted LRU-first down to [maxBytes], never the one just written.
  Future<void> write(TranscriptFile transcript) async {
    final file = _file(transcript.key);
    await directory.create(recursive: true);
    var merged = transcript;
    final existing = await _readQuietly(transcript.key);
    if (existing != null &&
        existing.source.mediaFingerprint == transcript.source.mediaFingerprint &&
        existing.source.audioStream == transcript.source.audioStream) {
      merged = _merge(existing, transcript);
    }

    final tmp = File('${file.path}.${_clock().microsecondsSinceEpoch}.${_tmpCounter++}.tmp');
    try {
      await tmp.writeAsString(jsonEncode(merged.toJson()), flush: true);
      final hook = beforeCommit;
      if (hook != null) await hook();
      await tmp.rename(file.path);
    } on Object {
      await _deleteQuietly(tmp);
      rethrow;
    }
    await _touch(file);
    await evict(protect: {transcript.key});
  }

  static TranscriptFile _merge(TranscriptFile old, TranscriptFile fresh) {
    final covered = normalizeRanges([...old.source.covered, ...fresh.source.covered]);
    final kept = [
      for (final s in old.segments)
        if (!_insideAny(fresh.source.covered, (s.startUs + s.endUs) ~/ 2)) s,
    ];
    final segments = [...kept, ...fresh.segments]
      ..sort((a, b) => a.startUs != b.startUs ? a.startUs.compareTo(b.startUs) : a.endUs.compareTo(b.endUs));
    return fresh.copyWith(
      segments: segments,
      source: TranscriptSource(
        mediaFingerprint: fresh.source.mediaFingerprint,
        audioStream: fresh.source.audioStream,
        covered: covered,
      ),
    );
  }

  static bool _insideAny(List<TimeRange> ranges, TimeUs t) {
    for (final r in ranges) {
      if (t >= r.start && t < r.end) return true;
    }
    return false;
  }

  /// Deletes the transcript under [key].
  Future<void> delete(String key) => _deleteQuietly(_file(key));

  /// Keys of the stored transcripts (stray temp files are not listed).
  Future<List<String>> keys() async => [for (final e in await _entries()) e.key];

  /// Total size of the stored transcripts in bytes.
  Future<int> totalBytes() async {
    var n = 0;
    for (final e in await _entries()) {
      n += e.bytes;
    }
    return n;
  }

  /// Evicts least recently used transcripts until the total is within [maxBytes]; keys in
  /// [protect] (the one just written, the ones an active job reads) stay. Returns the number
  /// evicted.
  Future<int> evict({Set<String> protect = const {}}) async {
    final entries = await _entries();
    var total = entries.fold<int>(0, (n, e) => n + e.bytes);
    if (total <= maxBytes) return 0;
    entries.sort((a, b) {
      final c = a.used.compareTo(b.used);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    var evicted = 0;
    for (final e in entries) {
      if (total <= maxBytes) break;
      if (protect.contains(e.key)) continue;
      await _deleteQuietly(e.file);
      total -= e.bytes;
      evicted++;
    }
    return evicted;
  }

  /// Removes stray `.tmp` files left by a crash, and every transcript when [everything] is true.
  Future<void> clear({bool everything = false}) async {
    if (!await directory.exists()) return;
    await for (final e in directory.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name.endsWith('.tmp') || (everything && name.endsWith('.json'))) await _deleteQuietly(e);
    }
  }

  /// Deletes `<key>.partial.jsonl` checkpoints older than [maxAge] (30 days, ai.md §5.2).
  Future<int> sweepPartials({Duration maxAge = const Duration(days: 30)}) async {
    if (!await directory.exists()) return 0;
    var n = 0;
    final cutoff = _clock().subtract(maxAge);
    await for (final e in directory.list()) {
      if (e is! File || !e.path.endsWith('.partial.jsonl')) continue;
      try {
        if ((await e.lastModified()).isBefore(cutoff)) {
          await e.delete();
          n++;
        }
      } on FileSystemException {
        // Gone already.
      }
    }
    return n;
  }

  Future<TranscriptFile?> _readQuietly(String key) async {
    try {
      final json = jsonDecode(await _file(key).readAsString());
      if (json is! Map<String, Object?>) return null;
      final t = TranscriptFile.fromJson(json);
      return t.key == key ? t : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<List<_Entry>> _entries() async {
    final out = <_Entry>[];
    if (!await directory.exists()) return out;
    await for (final e in directory.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!name.endsWith('.json') || name.endsWith('.partial.jsonl')) continue;
      final key = name.substring(0, name.length - '.json'.length);
      if (!TranscriptKey.isValid(key)) continue;
      try {
        final stat = await e.stat();
        out.add(_Entry(key, e, stat.size, stat.modified));
      } on FileSystemException {
        // Raced with a delete.
      }
    }
    return out;
  }

  Future<void> _touch(File file) async {
    try {
      await file.setLastModified(_clock());
    } on FileSystemException {
      // Best effort: LRU order is advisory.
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

final class _Entry {
  const _Entry(this.key, this.file, this.bytes, this.used);
  final String key;
  final File file;
  final int bytes;
  final DateTime used;
}
