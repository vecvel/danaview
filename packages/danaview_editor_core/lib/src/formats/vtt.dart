// OWNER: CORE-20
//
// WebVTT reader/writer (ARCH §10.1). Requires the WEBVTT header, skips NOTE/STYLE/REGION blocks,
// ignores cue settings, decodes entities, keeps balanced <i>/<b> and strips other tags.

import 'subtitle_codec.dart';

bool _isBlockKeyword(String line, String kw) =>
    line.startsWith(kw) && (line.length == kw.length || line[kw.length] == ' ' || line[kw.length] == '\t');

/// Reads WebVTT [lines] into [acc].
void parseVtt(List<String> lines, ParseAccumulator acc) {
  if (lines.isEmpty || !isVttHeader(lines[0])) {
    acc.issues.add(const SubtitleIssue(1, SubtitleIssueKind.missingHeader));
    return;
  }
  final n = lines.length;
  var i = 1;
  while (i < n && !isBlank(lines[i])) {
    i++; // header block
  }
  while (i < n) {
    if (isBlank(lines[i])) {
      i++;
      continue;
    }
    final s = i;
    var e = s;
    while (e < n && !isBlank(lines[e])) {
      e++;
    }
    i = e;
    final first = lines[s];
    if (_isBlockKeyword(first, 'NOTE') || _isBlockKeyword(first, 'STYLE') || _isBlockKeyword(first, 'REGION')) {
      continue;
    }
    int t;
    if (first.contains('-->')) {
      t = s;
    } else if (s + 1 < e && lines[s + 1].contains('-->')) {
      t = s + 1;
    } else {
      acc.issues.add(SubtitleIssue(s + 1, SubtitleIssueKind.noTiming));
      continue;
    }
    final timing = parseTiming(lines[t]);
    if (timing == null) {
      acc.issues.add(SubtitleIssue(t + 1, SubtitleIssueKind.invalidTiming));
      continue;
    }
    if (timing.endUs < timing.startUs) {
      acc.issues.add(SubtitleIssue(t + 1, SubtitleIssueKind.endBeforeStart));
      continue;
    }
    final clean = cleanCueText(lines.sublist(t + 1, e), acc);
    if (clean.isEmpty) {
      acc.issues.add(SubtitleIssue(t + 1, SubtitleIssueKind.emptyText));
      continue;
    }
    if (timing.hasSettings) acc.ignoredSettings++;
    acc.cues.add(SubtitleCueData(timing.startUs, timing.endUs, clean));
  }
}

/// Writes [cues] as WebVTT text (LF line endings).
String writeVtt(List<SubtitleCueData> cues, int offset) {
  final sb = StringBuffer('WEBVTT\n\n');
  for (final c in cues) {
    final end = c.endUs + offset;
    if (end <= 0 && offset != 0) continue;
    final text = escapeCueText(c.text, vtt: true);
    if (text.isEmpty) continue;
    var start = c.startUs + offset;
    if (start < 0) start = 0;
    sb
      ..write(formatStamp(start, '.'))
      ..write(' --> ')
      ..write(formatStamp(end < 0 ? 0 : end, '.'))
      ..write('\n')
      ..write(text)
      ..write('\n\n');
  }
  return sb.toString();
}
