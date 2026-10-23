// OWNER: HOM-23
//
// BUILD_PLAN HOM-23 "CSV with `,`, `;` and tab": delimiter sniffing, RFC 4180 quoting (delimiters,
// `""` and line breaks inside quotes), the header record, ragged rows, a UTF-16 LE TSV (Excel's
// "Unicode text" export) and the column width sample. Fixtures are generated here.

import 'dart:convert';
import 'dart:typed_data';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:flutter_test/flutter_test.dart';

CsvTable _table(String text, {CsvDelimiter? delimiter, CsvDelimiter preferred = CsvDelimiter.comma}) =>
    CsvTable.build(TextDocument.fromBytes(Uint8List.fromList(utf8.encode(text))), delimiter: delimiter, preferred: preferred);

void main() {
  group('sniffDelimiter', () {
    test('comma, semicolon and tab', () {
      expect(sniffDelimiter('a,b,c\n1,2,3\n4,5,6\n'), CsvDelimiter.comma);
      expect(sniffDelimiter('a;b;c\n1,5;2;3\n4;5,5;6\n'), CsvDelimiter.semicolon);
      expect(sniffDelimiter('a\tb\tc\n1\t2\t3\n'), CsvDelimiter.tab);
    });

    test('delimiters inside quotes do not count', () {
      expect(sniffDelimiter('"a;b";c\n"1;2";3\n"x;y";z\n'), CsvDelimiter.semicolon);
      expect(sniffDelimiter('"a,b,c";d\n"1,2,3";4\n'), CsvDelimiter.semicolon);
    });

    test('a single column falls back to the preferred delimiter', () {
      expect(sniffDelimiter('name\nalpha\nbeta\n'), CsvDelimiter.comma);
      expect(sniffDelimiter('name\nalpha\n', preferred: CsvDelimiter.tab), CsvDelimiter.tab);
      expect(sniffDelimiter(''), CsvDelimiter.comma);
    });
  });

  group('parseCsvRecord', () {
    test('quotes, escaped quotes, empty fields and CRLF', () {
      expect(parseCsvRecord('a,"b,c","say ""hi""",,e\r\n', CsvDelimiter.comma), ['a', 'b,c', 'say "hi"', '', 'e']);
      expect(parseCsvRecord('"multi\nline";x', CsvDelimiter.semicolon), ['multi\nline', 'x']);
      expect(parseCsvRecord('', CsvDelimiter.comma), ['']);
    });
  });

  group('CsvTable', () {
    test('comma file: header and rows', () {
      final t = _table('name,qty,price\napple,3,"1,20"\npear,10,0.5\n');
      expect(t.delimiter, CsvDelimiter.comma);
      expect(t.header, ['name', 'qty', 'price']);
      expect(t.rowCount, 2);
      expect(t.row(0), ['apple', '3', '1,20']);
      expect(t.row(1), ['pear', '10', '0.5']);
      expect(t.columnCount, 3);
    });

    test('semicolon file (European decimals)', () {
      final t = _table('Name;Betrag;Datum\nMiete;1.234,50;01.10.2026\nStrom;87,10;02.10.2026');
      expect(t.delimiter, CsvDelimiter.semicolon);
      expect(t.row(0), ['Miete', '1.234,50', '01.10.2026']);
      expect(t.rowCount, 2);
    });

    test('tab file', () {
      final t = _table('a\tb\n1\t2\n3\t4\n', preferred: CsvDelimiter.tab);
      expect(t.delimiter, CsvDelimiter.tab);
      expect(t.row(1), ['3', '4']);
    });

    test('a quoted line break stays inside one record', () {
      final t = _table('id,note\n1,"first\nsecond"\n2,plain\n');
      expect(t.rowCount, 2);
      expect(t.row(0), ['1', 'first\nsecond']);
      expect(t.row(1), ['2', 'plain']);
    });

    test('ragged rows: the widest record sets the column count', () {
      final t = _table('a,b\n1,2,3\n4\n');
      expect(t.columnCount, 3);
      expect(t.row(1), ['4']);
    });

    test('a wide record past the 200-record width sample keeps all its columns', () {
      final text = StringBuffer('a,b,c\n');
      for (var i = 0; i < 300; i++) {
        text.write('$i,x,y\n');
      }
      text.write('w,"q,uoted",3,4,5\n');
      final t = _table(text.toString());
      expect(t.columnCount, 5);
      expect(t.columnChars.length, 5);
      expect(t.columnChars[3], greaterThan(1));
      expect(t.row(300), ['w', 'q,uoted', '3', '4', '5']);
    });

    test('a forced delimiter overrides sniffing', () {
      final t = _table('a,b;c\n1,2;3\n', delimiter: CsvDelimiter.semicolon);
      expect(t.header, ['a,b', 'c']);
    });

    test('UTF-16 LE tab-separated (Excel Unicode text)', () {
      final bytes = BytesBuilder()..add([0xFF, 0xFE]);
      for (final u in 'Name\tCity\nZoë\tKöln\n'.codeUnits) {
        bytes.add([u & 0xFF, u >> 8]);
      }
      final t = CsvTable.build(TextDocument.fromBytes(bytes.toBytes()), preferred: CsvDelimiter.tab);
      expect(t.delimiter, CsvDelimiter.tab);
      expect(t.header, ['Name', 'City']);
      expect(t.row(0), ['Zoë', 'Köln']);
    });

    test('empty file', () {
      final t = _table('');
      expect(t.rowCount, 0);
      expect(t.header, isEmpty);
    });

    test('column widths come from the longest cells, capped at 60 characters', () {
      final t = _table('a,b\n${'x' * 100},yy\n');
      expect(t.columnChars, [60, 2]);
    });

    test('buildAsync gives the same table', () async {
      final doc = TextDocument.fromBytes(Uint8List.fromList(utf8.encode('a;b\n1;2\n')));
      final t = await CsvTable.buildAsync(doc);
      expect(t.delimiter, CsvDelimiter.semicolon);
      expect(t.row(0), ['1', '2']);
    });
  });
}
