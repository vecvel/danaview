// OWNER: HOM-23
//
// The CSV/TSV model of the read-only grid (HOM plan §8.4): the delimiter is sniffed (`,` `;` or
// tab), records are indexed by byte offset in one quote-aware pass (a quoted field may hold the
// delimiter, `""` and line breaks), and a record is parsed only when the grid shows it. The first
// record is the fixed header row. Nothing here logs content (rule 30).

import 'dart:isolate';
import 'dart:typed_data';

import 'text_document.dart';
import 'text_encoding.dart';

/// A CSV delimiter the grid can use.
enum CsvDelimiter {
  /// `,`
  comma(0x2C, 'Comma'),

  /// `;`
  semicolon(0x3B, 'Semicolon'),

  /// Tab.
  tab(0x09, 'Tab');

  const CsvDelimiter(this.unit, this.label);

  /// The code unit.
  final int unit;

  /// The name shown in the viewer's menu.
  final String label;
}

/// Sniffs the delimiter of [sample] (the first lines of a file): the candidate that splits the
/// most lines into the same number of fields wins, then the one with more fields; [preferred]
/// (from the extension, `.tsv` → tab) breaks ties and is the answer when nothing splits.
CsvDelimiter sniffDelimiter(String sample, {CsvDelimiter preferred = CsvDelimiter.comma}) {
  final lines = <String>[];
  var start = 0;
  var quoted = false;
  for (var i = 0; i < sample.length && lines.length < 40; i++) {
    final c = sample.codeUnitAt(i);
    if (c == 0x22) quoted = !quoted;
    if (c == 0x0A && !quoted) {
      final line = sample.substring(start, i).trimRight();
      if (line.isNotEmpty) lines.add(line);
      start = i + 1;
    }
  }
  if (lines.isEmpty && start < sample.length) lines.add(sample.substring(start).trimRight());
  if (lines.isEmpty) return preferred;

  CsvDelimiter best = preferred;
  var bestConsistent = 0;
  var bestFields = 0;
  for (final d in [preferred, ...CsvDelimiter.values.where((d) => d != preferred)]) {
    final counts = <int, int>{};
    for (final line in lines) {
      var n = 0;
      var q = false;
      for (var i = 0; i < line.length; i++) {
        final c = line.codeUnitAt(i);
        if (c == 0x22) {
          q = !q;
        } else if (c == d.unit && !q) {
          n++;
        }
      }
      if (n > 0) counts[n] = (counts[n] ?? 0) + 1;
    }
    if (counts.isEmpty) continue;
    final mode = counts.entries.reduce((a, b) => b.value > a.value || (b.value == a.value && b.key > a.key) ? b : a);
    if (mode.value > bestConsistent || (mode.value == bestConsistent && mode.key > bestFields)) {
      best = d;
      bestConsistent = mode.value;
      bestFields = mode.key;
    }
  }
  return best;
}

/// Parses one record's text into fields (RFC 4180 quoting; the record's own line break removed).
List<String> parseCsvRecord(String text, CsvDelimiter delimiter) {
  var end = text.length;
  if (end > 0 && text.codeUnitAt(end - 1) == 0x0A) end--;
  if (end > 0 && text.codeUnitAt(end - 1) == 0x0D) end--;
  final fields = <String>[];
  final buf = StringBuffer();
  var i = 0;
  var quoted = false;
  var fieldStart = true;
  while (i < end) {
    final c = text.codeUnitAt(i);
    if (quoted) {
      if (c == 0x22) {
        if (i + 1 < end && text.codeUnitAt(i + 1) == 0x22) {
          buf.writeCharCode(0x22);
          i += 2;
          continue;
        }
        quoted = false;
      } else {
        buf.writeCharCode(c);
      }
    } else if (c == delimiter.unit) {
      fields.add(buf.toString());
      buf.clear();
      fieldStart = true;
      i++;
      continue;
    } else if (c == 0x22 && fieldStart) {
      quoted = true;
    } else {
      buf.writeCharCode(c);
    }
    fieldStart = false;
    i++;
  }
  fields.add(buf.toString());
  return fields;
}

/// A CSV/TSV file indexed by record over a [TextDocument]'s bytes.
final class CsvTable {
  CsvTable._(this.document, this.delimiter, this._starts, this.recordCount, this.columnCount, this.columnChars);

  /// Indexes [document] with [delimiter] (sniffed from the first 64 KB when null; [preferred]
  /// breaks ties).
  factory CsvTable.build(TextDocument document, {CsvDelimiter? delimiter, CsvDelimiter preferred = CsvDelimiter.comma}) {
    final bytes = document.bytes;
    final unit = document.encoding.unitBytes;
    final sampleEnd = (document.bomLength + 64 * 1024).clamp(0, bytes.length);
    final d = delimiter ??
        sniffDelimiter(document.decode(document.bomLength, sampleEnd - ((sampleEnd - document.bomLength) % unit)), preferred: preferred);

    var starts = Uint32List(1024);
    var count = 0;
    void add(int v) {
      if (count == starts.length) starts = Uint32List(starts.length * 2)..setRange(0, count, starts);
      starts[count++] = v;
    }

    final le = document.encoding == TextEncodingKind.utf16le;
    final end = unit == 2 ? bytes.length - ((bytes.length - document.bomLength) & 1) : bytes.length;
    var i = document.bomLength;
    if (i < end) add(i);
    var quoted = false;
    while (i < end) {
      final int c;
      if (unit == 1) {
        c = bytes[i];
      } else {
        c = le ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1];
      }
      i += unit;
      if (c == 0x22) {
        quoted = !quoted;
      } else if (c == 0x0A && !quoted && i < end) {
        add(i);
      }
    }
    // A trailing blank record (a final line break followed by nothing) is not a row.
    final table = CsvTable._(document, d, starts, count, 0, const []);
    final sample = <List<String>>[for (var r = 0; r < count && r < 200; r++) table.record(r)];
    var cols = 0;
    for (final rec in sample) {
      if (rec.length > cols) cols = rec.length;
    }
    final chars = List<int>.filled(cols, 1);
    for (final rec in sample) {
      for (var c = 0; c < rec.length; c++) {
        final len = rec[c].length > 60 ? 60 : rec[c].length;
        if (len > chars[c]) chars[c] = len;
      }
    }
    return CsvTable._(document, d, starts, count, cols, List.unmodifiable(chars));
  }

  /// [build] on a background isolate.
  static Future<CsvTable> buildAsync(TextDocument document, {CsvDelimiter? delimiter, CsvDelimiter preferred = CsvDelimiter.comma}) =>
      Isolate.run(() => CsvTable.build(document, delimiter: delimiter, preferred: preferred));

  /// The underlying text.
  final TextDocument document;

  /// The delimiter in use.
  final CsvDelimiter delimiter;

  final Uint32List _starts;

  /// Records, the header included.
  final int recordCount;

  /// Columns (the widest of the first 200 records).
  final int columnCount;

  /// Longest cell per column in the first 200 records, capped at 60 characters (column widths).
  final List<int> columnChars;

  /// Body rows (records after the header).
  int get rowCount => recordCount > 0 ? recordCount - 1 : 0;

  /// The header fields (empty when the file is empty).
  List<String> get header => recordCount > 0 ? record(0) : const [];

  /// Fields of body row [i] (record `i + 1`).
  List<String> row(int i) => record(i + 1);

  /// Fields of record [r].
  List<String> record(int r) {
    final start = _starts[r];
    final end = r + 1 < recordCount ? _starts[r + 1] : document.bytes.length;
    return parseCsvRecord(document.decode(start, end), delimiter);
  }
}
