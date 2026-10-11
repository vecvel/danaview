// OWNER: CORE-20
//
// SRT / WebVTT codec facade (ARCH §10.1). Pure functions; callers run `parse` in Isolate.run.
//
// The codec works on [SubtitleCueData] (microsecond times, plain text with balanced <i>/<b>
// markup and '\n' line breaks). Mapping to timeline items (frame rounding, >= 1 frame
// duration) is the caller's job on insert.

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../time/time.dart';
import 'srt.dart';
import 'text_decoding.dart';
import 'vtt.dart';

/// A subtitle file format.
enum SubtitleFormat {
  /// SubRip.
  srt('srt'),

  /// WebVTT.
  vtt('vtt');

  const SubtitleFormat(this.extension);

  /// File extension without the dot.
  final String extension;
}

/// Why a cue (or the file) was not imported.
enum SubtitleIssueKind {
  /// A WebVTT file does not start with `WEBVTT`; nothing is imported.
  missingHeader,

  /// A line containing `-->` has an unreadable timestamp.
  invalidTiming,

  /// The end time is before the start time.
  endBeforeStart,

  /// The cue has no text once markup is removed.
  emptyText,

  /// Text outside any cue (no timing line).
  strayText,

  /// A WebVTT block that is not a note/style/region has no timing line.
  noTiming,
}

/// A problem found while parsing; the remaining cues still import.
@immutable
final class SubtitleIssue {
  /// Creates an issue at 1-based [line].
  const SubtitleIssue(this.line, this.kind);

  /// 1-based line number in the decoded text.
  final int line;

  /// What went wrong.
  final SubtitleIssueKind kind;

  @override
  bool operator ==(Object other) => other is SubtitleIssue && other.line == line && other.kind == kind;

  @override
  int get hashCode => Object.hash(line, kind);

  @override
  String toString() => 'Line $line: ${kind.name}';
}

/// One subtitle cue as read from or written to a file.
@immutable
final class SubtitleCueData {
  /// Creates a cue; [text] uses '\n' between lines and may contain balanced `<i>`/`<b>`.
  const SubtitleCueData(this.startUs, this.endUs, this.text);

  /// Start time in microseconds.
  final TimeUs startUs;

  /// End time in microseconds.
  final TimeUs endUs;

  /// Cue text.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is SubtitleCueData && other.startUs == startUs && other.endUs == endUs && other.text == text;

  @override
  int get hashCode => Object.hash(startUs, endUs, text);

  @override
  String toString() => 'SubtitleCueData($startUs..$endUs, ${jsonEncode(text)})';
}

/// Result of [SubtitleCodec.parse].
@immutable
final class SubtitleParseResult {
  /// Creates a result.
  const SubtitleParseResult({
    required this.format,
    required this.cues,
    required this.issues,
    required this.strippedTags,
    required this.ignoredSettings,
    required this.detectedEncoding,
    required this.hadBom,
  });

  /// The format that was parsed.
  final SubtitleFormat format;

  /// Valid cues in file order.
  final List<SubtitleCueData> cues;

  /// Problems, with line numbers.
  final List<SubtitleIssue> issues;

  /// Number of tags and `{\an8}`-style overrides that were removed.
  final int strippedTags;

  /// Number of cues whose WebVTT settings / SRT coordinates were ignored.
  final int ignoredSettings;

  /// The text encoding that was detected.
  final TextEncoding detectedEncoding;

  /// Whether the file started with a byte order mark.
  final bool hadBom;
}

/// SRT and WebVTT reader/writer.
abstract final class SubtitleCodec {
  /// Parses [bytes]. A `WEBVTT` header always selects WebVTT; otherwise [hint] (for example from
  /// the file extension) decides, defaulting to SRT. A WebVTT hint without the header yields a
  /// [SubtitleIssueKind.missingHeader] issue and no cues.
  static SubtitleParseResult parse(Uint8List bytes, {SubtitleFormat? hint}) {
    final d = decodeText(bytes);
    final lines = splitLines(d.text);
    final hasHeader = isVttHeader(lines.isEmpty ? '' : lines[0]);
    final format = hasHeader ? SubtitleFormat.vtt : (hint ?? SubtitleFormat.srt);
    final acc = ParseAccumulator();
    if (format == SubtitleFormat.vtt) {
      parseVtt(lines, acc);
    } else {
      parseSrt(lines, acc);
    }
    return SubtitleParseResult(
      format: format,
      cues: acc.cues,
      issues: acc.issues,
      strippedTags: acc.strippedTags,
      ignoredSettings: acc.ignoredSettings,
      detectedEncoding: d.encoding,
      hadBom: d.hadBom,
    );
  }

  /// Serializes [cues]; every time is shifted by [offset] (cues ending at or before zero are
  /// dropped, negative starts clamp to zero) and rounded half-up to whole milliseconds. SRT is
  /// numbered from 1 with CRLF, WebVTT uses LF; UTF-8, with a BOM only when [bom] is true.
  /// Cues with no text are skipped; `-->` inside text becomes `->`.
  static Uint8List serialize(
    List<SubtitleCueData> cues,
    SubtitleFormat format, {
    TimeUs offset = 0,
    bool bom = false,
  }) {
    final text = switch (format) {
      SubtitleFormat.srt => writeSrt(cues, offset),
      SubtitleFormat.vtt => writeVtt(cues, offset),
    };
    final body = utf8.encode(text);
    if (!bom) return Uint8List.fromList(body);
    return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...body]);
  }

  /// Suggested export file name `<project>.<bcp47>.srt|vtt`; unsafe characters become `_`.
  static String suggestedFileName(String projectName, String bcp47, SubtitleFormat format) {
    var base = projectName.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    while (base.endsWith('.')) {
      base = base.substring(0, base.length - 1).trimRight();
    }
    if (base.isEmpty) base = 'subtitles';
    final lang = RegExp(r'^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$').hasMatch(bcp47) ? bcp47 : 'und';
    return '$base.$lang.${format.extension}';
  }
}

// ---------------------------------------------------------------------------------------------
// Shared internals (used by srt.dart and vtt.dart).
// ---------------------------------------------------------------------------------------------

/// Mutable parse state shared by the SRT and WebVTT readers.
final class ParseAccumulator {
  /// Cues read so far.
  final List<SubtitleCueData> cues = [];

  /// Issues found so far.
  final List<SubtitleIssue> issues = [];

  /// Count of stripped tags/overrides.
  int strippedTags = 0;

  /// Count of cues with ignored settings.
  int ignoredSettings = 0;
}

/// Splits on CRLF, CR or LF.
List<String> splitLines(String s) {
  final out = <String>[];
  final n = s.length;
  var start = 0;
  for (var i = 0; i < n; i++) {
    final c = s.codeUnitAt(i);
    if (c == 10 || c == 13) {
      out.add(s.substring(start, i));
      if (c == 13 && i + 1 < n && s.codeUnitAt(i + 1) == 10) i++;
      start = i + 1;
    }
  }
  if (start < n) out.add(s.substring(start));
  return out;
}

/// Whether [line] is a WebVTT file header.
bool isVttHeader(String line) => line.startsWith('WEBVTT') && (line.length == 6 || line[6] == ' ' || line[6] == '\t');

/// Whether [s] is empty or only whitespace.
bool isBlank(String s) => s.trim().isEmpty;

const String _ts = r'(?:(\d{1,6}):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})';
final RegExp _timingRe = RegExp('^\\s*$_ts\\s*-->\\s*$_ts(.*)\$');

/// Result of parsing a timing line.
final class Timing {
  /// Creates a timing.
  const Timing(this.startUs, this.endUs, this.hasSettings);

  /// Start.
  final TimeUs startUs;

  /// End.
  final TimeUs endUs;

  /// Whether trailing settings/coordinates were present (and ignored).
  final bool hasSettings;
}

/// Parses `start --> end [settings]`, or null when malformed.
Timing? parseTiming(String line) {
  final m = _timingRe.firstMatch(line);
  if (m == null) return null;
  final a = _stamp(m, 1);
  final b = _stamp(m, 5);
  if (a == null || b == null) return null;
  final rest = m.group(9) ?? '';
  return Timing(a, b, rest.trim().isNotEmpty);
}

int? _stamp(RegExpMatch m, int g) {
  final h = m.group(g) == null ? 0 : int.parse(m.group(g)!);
  final mi = int.parse(m.group(g + 1)!);
  final s = int.parse(m.group(g + 2)!);
  final fr = m.group(g + 3)!;
  if (mi > 59 || s > 59) return null;
  var ms = int.parse(fr);
  for (var i = fr.length; i < 3; i++) {
    ms *= 10;
  }
  return (((h * 60 + mi) * 60 + s) * 1000 + ms) * 1000;
}

const Map<String, String> _entities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'lrm': '‎',
  'rlm': '‏',
};

final RegExp _entityLike = RegExp(r'&(?:#\d+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);');

/// Cleans raw cue [lines]: strips tags and `{\...}` overrides (keeping balanced `<i>`/`<b>`),
/// decodes entities, trims each line and drops blank lines. Returns '' for an empty cue.
String cleanCueText(List<String> lines, ParseAccumulator acc) {
  final raw = lines.length == 1 ? lines[0] : lines.join('\n');
  final buf = StringBuffer();
  final stack = <String>[];
  final n = raw.length;
  var i = 0;
  while (i < n) {
    final c = raw.codeUnitAt(i);
    if (c == 0x3C) {
      final j = raw.indexOf('>', i + 1);
      final k = raw.indexOf('<', i + 1);
      if (j > 0 && (k < 0 || k > j)) {
        _tag(raw.substring(i + 1, j), buf, stack, acc);
        i = j + 1;
        continue;
      }
    } else if (c == 0x7B && i + 1 < n && raw.codeUnitAt(i + 1) == 0x5C) {
      final j = raw.indexOf('}', i + 2);
      if (j > 0) {
        acc.strippedTags++;
        i = j + 1;
        continue;
      }
    } else if (c == 0x26) {
      final semi = raw.indexOf(';', i + 1);
      if (semi > 0 && semi - i <= 10) {
        final dec = _decodeEntity(raw.substring(i + 1, semi));
        if (dec != null) {
          buf.write(dec);
          i = semi + 1;
          continue;
        }
      }
    }
    buf.writeCharCode(c);
    i++;
  }
  for (var s = stack.length - 1; s >= 0; s--) {
    buf.write('</${stack[s]}>');
  }
  final out = <String>[];
  for (final l in buf.toString().split('\n')) {
    final t = l.trim();
    if (t.isNotEmpty) out.add(t);
  }
  return _hasContent(out) ? out.join('\n') : '';
}

final RegExp _markupOnly = RegExp(r'</?[ib]>');

bool _hasContent(List<String> lines) {
  for (final l in lines) {
    if (l.replaceAll(_markupOnly, '').trim().isNotEmpty) return true;
  }
  return false;
}

String? _decodeEntity(String body) {
  if (body.isEmpty) return null;
  if (body.codeUnitAt(0) == 0x23) {
    final hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
    final cp = int.tryParse(body.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
    if (cp == null || cp <= 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return null;
    return String.fromCharCode(cp);
  }
  return _entities[body];
}

void _tag(String tag, StringBuffer buf, List<String> stack, ParseAccumulator acc) {
  final closing = tag.startsWith('/');
  var p = closing ? 1 : 0;
  final start = p;
  while (p < tag.length) {
    final c = tag.codeUnitAt(p);
    if (c == 0x20 || c == 0x09 || c == 0x2E || c == 0x2F || c == 0x0A) break;
    p++;
  }
  final name = tag.substring(start, p).toLowerCase();
  if (name != 'i' && name != 'b') {
    acc.strippedTags++;
    return;
  }
  if (!closing) {
    stack.add(name);
    buf.write('<$name>');
    return;
  }
  final at = stack.lastIndexOf(name);
  if (at < 0) {
    acc.strippedTags++;
    return;
  }
  final above = stack.sublist(at + 1);
  for (var s = above.length - 1; s >= 0; s--) {
    buf.write('</${above[s]}>');
  }
  buf.write('</$name>');
  stack.length = at;
  for (final a in above) {
    stack.add(a);
    buf.write('<$a>');
  }
}

/// Prepares model text for writing: collapses blank lines, replaces `-->`, balances `<i>`/`<b>`
/// markup and escapes literal characters per [vtt] rules. Returns '' for text with no content.
String escapeCueText(String text, {required bool vtt}) {
  final buf = StringBuffer();
  final stack = <String>[];
  var i = 0;
  final n = text.length;
  while (i < n) {
    final c = text.codeUnitAt(i);
    if (c == 0x3C) {
      final m = _markup(text, i);
      if (m != null) {
        final (closing, name) = m;
        if (!closing) {
          stack.add(name);
          buf.write('<$name>');
        } else {
          final at = stack.lastIndexOf(name);
          if (at >= 0) {
            final above = stack.sublist(at + 1);
            for (var s = above.length - 1; s >= 0; s--) {
              buf.write('</${above[s]}>');
            }
            buf.write('</$name>');
            stack.length = at;
            for (final a in above) {
              stack.add(a);
              buf.write('<$a>');
            }
          }
        }
        i += closing ? 4 : 3;
        continue;
      }
      buf.write('&lt;');
    } else if (c == 0x3E) {
      buf.write(vtt ? '&gt;' : '>');
    } else if (c == 0x26) {
      if (vtt) {
        buf.write('&amp;');
      } else {
        final m = _entityLike.matchAsPrefix(text, i);
        buf.write(m != null ? '&amp;' : '&');
      }
    } else if (c == 0x2D && text.startsWith('-->', i)) {
      buf.write('->');
      i += 3;
      continue;
    } else {
      buf.writeCharCode(c);
    }
    i++;
  }
  for (var s = stack.length - 1; s >= 0; s--) {
    buf.write('</${stack[s]}>');
  }
  final lines = <String>[];
  for (final l in buf.toString().split(RegExp(r'\r\n|\r|\n'))) {
    final t = l.trim();
    if (t.isNotEmpty) lines.add(t);
  }
  return _hasContent(lines) ? lines.join('\n') : '';
}

(bool, String)? _markup(String s, int i) {
  if (s.startsWith('<i>', i)) return (false, 'i');
  if (s.startsWith('<b>', i)) return (false, 'b');
  if (s.startsWith('</i>', i)) return (true, 'i');
  if (s.startsWith('</b>', i)) return (true, 'b');
  return null;
}

/// Formats [us] (already shifted, >= 0) as `HH:MM:SS<sep>mmm`, rounding half-up to ms.
String formatStamp(TimeUs us, String sep) {
  final ms = (us + 500) ~/ 1000;
  final h = ms ~/ 3600000;
  final m = (ms ~/ 60000) % 60;
  final s = (ms ~/ 1000) % 60;
  final f = ms % 1000;
  String p2(int v) => v < 10 ? '0$v' : '$v';
  final fr = f < 10 ? '00$f' : (f < 100 ? '0$f' : '$f');
  return '${p2(h)}:${p2(m)}:${p2(s)}$sep$fr';
}
