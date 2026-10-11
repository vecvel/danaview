// OWNER: AI-10
//
// Builders shared by the transcript tests.

import 'dart:io';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

/// A segment of [text] spread evenly over `[startMs, endMs]`, words split on spaces.
TranscriptSegment seg(
  int startMs,
  int endMs,
  String text, {
  double nsp = 0.02,
  double lp = -0.2,
  bool words = true,
}) {
  final tokens = text.trim().isEmpty ? <String>[] : text.trim().split(RegExp(r'\s+'));
  final ws = <TranscriptWord>[];
  if (words && tokens.isNotEmpty) {
    final span = (endMs - startMs) * 1000;
    final step = span ~/ tokens.length;
    for (var i = 0; i < tokens.length; i++) {
      ws.add(TranscriptWord(text: tokens[i], startUs: startMs * 1000 + i * step, endUs: startMs * 1000 + (i + 1) * step, probability: 0.9));
    }
  }
  return TranscriptSegment(startUs: startMs * 1000, endUs: endMs * 1000, text: text, noSpeechProb: nsp, avgLogProb: lp, words: ws);
}

/// The texts of [segments].
List<String> texts(Iterable<TranscriptSegment> segments) => [for (final s in segments) s.text];

/// A transcript with a few words, covering `[0, coveredMs]`.
TranscriptFile transcript(
  String key, {
  int coveredStartMs = 0,
  int coveredMs = 60000,
  List<TranscriptSegment>? segments,
  String fingerprint = 'fp1',
  DateTime? createdAt,
  int padWords = 0,
}) {
  final segs = segments ?? [seg(1000, 3000, 'hello brave new world'), seg(10000, 12000, 'second sentence here')];
  return TranscriptFile(
    key: key,
    engine: const TranscriptEngineInfo(version: '1.9.4'),
    model: const TranscriptModelInfo(id: 'whisper-base-q5_1', sha256: 'abc'),
    source: TranscriptSource(
      mediaFingerprint: fingerprint,
      audioStream: 0,
      covered: [TimeRange(coveredStartMs * 1000, (coveredStartMs + coveredMs) * 1000)],
    ),
    language: const TranscriptLanguageInfo(code: 'en', detected: true, probability: 0.97),
    segments: segs,
    createdAt: createdAt ?? DateTime.utc(2026, 10, 7, 12),
  );
}

/// A 64-hex-character key for tests.
String keyOf(int n) => n.toRadixString(16).padLeft(64, '0');

/// Creates and returns a fresh temp directory, deleted by [addTearDown].
Directory tempDir(void Function(Future<void> Function()) addTearDown) {
  final d = Directory.systemTemp.createTempSync('danaview_transcript_test_');
  addTearDown(() async {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  return d;
}
