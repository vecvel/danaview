// OWNER: CORE-20
//
// SubRip reader/writer (ARCH §10.1). Tolerant reader: the index line is optional, fractions use
// ',' or '.', have 1-3 digits, hours may exceed 99, trailing coordinates are ignored, and cues
// without a separating blank line are split on their timing lines.

import 'subtitle_codec.dart';

/// Reads SRT [lines] into [acc].
void parseSrt(List<String> lines, ParseAccumulator acc) {
  List<String>? text; // current cue text, null when between cues
  late Timing timing;
  var timingLine = 0;
  var skipping = false; // inside a rejected cue, up to the next blank line
  var strayReported = false;

  void finish() {
    final t = text;
    if (t == null) return;
    text = null;
    final clean = cleanCueText(t, acc);
    if (clean.isEmpty) {
      acc.issues.add(SubtitleIssue(timingLine, SubtitleIssueKind.emptyText));
      return;
    }
    if (timing.hasSettings) acc.ignoredSettings++;
    acc.cues.add(SubtitleCueData(timing.startUs, timing.endUs, clean));
  }

  final n = lines.length;
  for (var i = 0; i < n; i++) {
    final line = lines[i];
    if (isBlank(line)) {
      finish();
      skipping = false;
      strayReported = false;
      continue;
    }
    if (line.contains('-->')) {
      final t = parseTiming(line);
      // A bare index line right before a timing line belongs to the new cue.
      final cur = text;
      if (cur != null && cur.isNotEmpty && RegExp(r'^\s*\d+\s*$').hasMatch(cur.last)) {
        cur.removeLast();
      }
      finish();
      strayReported = false;
      if (t == null) {
        acc.issues.add(SubtitleIssue(i + 1, SubtitleIssueKind.invalidTiming));
        skipping = true;
      } else if (t.endUs < t.startUs) {
        acc.issues.add(SubtitleIssue(i + 1, SubtitleIssueKind.endBeforeStart));
        skipping = true;
      } else {
        timing = t;
        timingLine = i + 1;
        text = <String>[];
        skipping = false;
      }
      continue;
    }
    final cur = text;
    if (cur != null) {
      cur.add(line);
    } else if (skipping) {
      continue;
    } else if (RegExp(r'^\s*\d+\s*$').hasMatch(line)) {
      continue; // index line
    } else if (!strayReported) {
      acc.issues.add(SubtitleIssue(i + 1, SubtitleIssueKind.strayText));
      strayReported = true;
    }
  }
  finish();
}

/// Writes [cues] as SRT text (CRLF, numbered from 1).
String writeSrt(List<SubtitleCueData> cues, int offset) {
  final sb = StringBuffer();
  var index = 0;
  for (final c in cues) {
    final end = c.endUs + offset;
    if (end <= 0 && offset != 0) continue;
    final text = escapeCueText(c.text, vtt: false);
    if (text.isEmpty) continue;
    var start = c.startUs + offset;
    if (start < 0) start = 0;
    index++;
    sb
      ..write(index)
      ..write('\r\n')
      ..write(formatStamp(start, ','))
      ..write(' --> ')
      ..write(formatStamp(end < 0 ? 0 : end, ','))
      ..write('\r\n')
      ..write(text.replaceAll('\n', '\r\n'))
      ..write('\r\n\r\n');
  }
  return sb.toString();
}
