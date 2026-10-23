// HOM-16: the type table and classifier (ARCH v1.2 §5.1, HOM plan §8.1, V2-114).

import 'package:danaview_library/danaview_library.dart';
import 'package:test/test.dart';

TypeRow _row(String id) => typeTable.singleWhere((r) => r.id == id);

void main() {
  group('type table', () {
    test('row ids are unique and every document row has a sub-filter', () {
      expect(typeTable.map((r) => r.id).toSet(), hasLength(typeTable.length));
      for (final row in typeTable) {
        expect(row.docKind != null, row.kind == FileKind.document, reason: row.id);
      }
    });

    test('every value is lower case and in at most one row', () {
      for (final pick in <Set<String> Function(TypeRow)>[
        (r) => r.utis,
        (r) => r.mimes,
        (r) => r.mimePrefixes,
        (r) => r.extensions,
      ]) {
        final seen = <String, String>{};
        for (final row in typeTable) {
          for (final v in pick(row)) {
            expect(v, v.toLowerCase(), reason: '${row.id}: $v');
            expect(v.startsWith('.'), isFalse, reason: '${row.id}: $v');
            expect(seen[v], isNull, reason: '$v is in ${seen[v]} and ${row.id}');
            seen[v] = row.id;
          }
        }
      }
    });

    test('one row per Documents sub-filter, each in plan order', () {
      final docRows = typeTable.where((r) => r.kind == FileKind.document).map((r) => r.docKind).toList();
      expect(docRows, DocumentKind.values);
      expect(DocumentKind.values.map((k) => k.filterLabel), ['PDF', 'Word', 'Excel', 'PowerPoint', 'Text/CSV', 'Other']);
      expect(fallbackRow.docKind, DocumentKind.other);
    });
  });

  // One test per table row: every UTType, MIME type, MIME family and extension of the row
  // classifies to it, alone and decided by that input.
  group('every row', () {
    for (final row in typeTable) {
      test('row ${row.id}', () {
        for (final uti in row.utis) {
          expect(classify(uti: uti, fileName: 'x'), FileClass(row, ClassifiedBy.uti), reason: uti);
        }
        for (final mime in row.mimes) {
          expect(classify(mime: mime, fileName: 'x'), FileClass(row, ClassifiedBy.mime), reason: mime);
        }
        for (final prefix in row.mimePrefixes) {
          expect(classify(mime: '${prefix}x-anything', fileName: 'x'), FileClass(row, ClassifiedBy.mimeFamily),
              reason: prefix);
        }
        for (final ext in row.extensions) {
          expect(classify(fileName: 'file.$ext'), FileClass(row, ClassifiedBy.extension), reason: ext);
          expect(classify(fileName: 'FILE.${ext.toUpperCase()}').row, row, reason: ext);
        }
        expect(row.utis.length + row.mimes.length + row.mimePrefixes.length + row.extensions.length, greaterThan(0));
      });
    }
  });

  // One test per sub-filter: the exact matches HOM plan §8.1 lists.
  group('Documents sub-filters (HOM plan §8.1)', () {
    void expectDoc(DocumentKind kind, {List<String> utis = const [], List<String> mimes = const [], required List<String> exts}) {
      for (final u in utis) {
        expect(classify(uti: u, fileName: 'x').docKind, kind, reason: u);
      }
      for (final m in mimes) {
        expect(classify(mime: m, fileName: 'x').docKind, kind, reason: m);
      }
      for (final e in exts) {
        final c = classify(fileName: 'a.$e');
        expect(c.kind, FileKind.document, reason: e);
        expect(c.docKind, kind, reason: e);
        expect(c.subKind, kind.code, reason: e);
      }
    }

    test('PDF', () => expectDoc(DocumentKind.pdf, utis: ['com.adobe.pdf'], mimes: ['application/pdf'], exts: ['pdf']));
    test('Word', () => expectDoc(DocumentKind.word, exts: ['doc', 'docx', 'odt', 'rtf', 'pages']));
    test('Excel', () => expectDoc(DocumentKind.excel, exts: ['xls', 'xlsx', 'ods', 'numbers']));
    test('PowerPoint', () => expectDoc(DocumentKind.powerpoint, exts: ['ppt', 'pptx', 'odp', 'key']));
    test('Text/CSV', () {
      expectDoc(DocumentKind.text,
          utis: ['public.plain-text'],
          mimes: ['text/plain', 'text/csv', 'text/markdown', 'text/x-log'],
          exts: ['txt', 'md', 'csv', 'tsv', 'json', 'log']);
    });
    test('Other: archives, e-books and unknown types', () {
      expectDoc(DocumentKind.other, exts: ['zip', 'rar', '7z', 'epub', 'mobi']);
      for (final name in ['blob.xyz', 'README', '.bashrc', 'trailing.', '']) {
        final c = classify(fileName: name);
        expect(c, FileClass(fallbackRow, ClassifiedBy.fallback), reason: name);
        expect(c.docKind, DocumentKind.other);
      }
      expect(classify(uti: 'public.html', mime: 'application/x-made-up', fileName: 'a.zzz').decidedBy,
          ClassifiedBy.fallback);
    });

    test('documentSubFilterOf places kinds under Documents', () {
      expect(documentSubFilterOf(FileKind.document, 'pdf'), DocumentKind.pdf);
      expect(documentSubFilterOf(FileKind.document, null), DocumentKind.other);
      expect(documentSubFilterOf(FileKind.document, 'futureSubKind'), DocumentKind.other);
      expect(documentSubFilterOf(FileKind.other, null), DocumentKind.other);
      for (final k in [FileKind.video, FileKind.photo, FileKind.audio]) {
        expect(documentSubFilterOf(k, null), isNull);
      }
    });
  });

  group('conflicting inputs (UTType → MIME → extension)', () {
    test('a specific UTType wins over MIME and extension', () {
      final c = classify(uti: 'com.adobe.pdf', mime: 'text/plain', fileName: 'report.docx');
      expect(c, FileClass(_row('pdf'), ClassifiedBy.uti));
    });

    test('a specific MIME type wins over the extension', () {
      expect(classify(mime: 'application/pdf', fileName: 'notes.txt'), FileClass(_row('pdf'), ClassifiedBy.mime));
      expect(classify(mime: 'video/mp4', fileName: 'clip.jpg').kind, FileKind.video);
    });

    test('generic UTTypes defer to MIME, then extension', () {
      for (final uti in ['public.data', 'public.item', 'public.content', 'dyn.ah62d4rv4ge80', 'PUBLIC.DATA', '  ']) {
        expect(classify(uti: uti, mime: 'application/pdf', fileName: 'a.txt'), FileClass(_row('pdf'), ClassifiedBy.mime),
            reason: uti);
        expect(classify(uti: uti, fileName: 'a.xlsx'), FileClass(_row('excel'), ClassifiedBy.extension), reason: uti);
      }
    });

    test('generic or malformed MIME types defer to the extension', () {
      for (final mime in ['application/octet-stream', 'APPLICATION/OCTET-STREAM; x=1', 'binary/octet-stream', '*/*', '', 'garbage', 'a/b/c']) {
        expect(classify(mime: mime, fileName: 'a.csv'), FileClass(_row('text'), ClassifiedBy.extension), reason: mime);
      }
      expect(classify(uti: 'public.data', mime: 'application/octet-stream', fileName: 'deck.pptx').docKind,
          DocumentKind.powerpoint);
    });

    test('an unknown specific UTType defers instead of deciding', () {
      expect(classify(uti: 'com.example.unknown', mime: 'image/heic', fileName: 'a.bin'),
          FileClass(_row('photo'), ClassifiedBy.mimeFamily));
      expect(classify(uti: 'com.example.unknown', fileName: 'a.mov').kind, FileKind.video);
    });

    test('an exact MIME match beats a family prefix', () {
      expect(classify(mime: 'text/rtf', fileName: 'x').docKind, DocumentKind.word);
      expect(classify(mime: 'image/svg+xml', fileName: 'x').kind, FileKind.document);
      expect(classify(mime: 'text/rtf', fileName: 'x').decidedBy, ClassifiedBy.mime);
    });

    test('MIME parameters and case are ignored', () {
      expect(classify(mime: 'Text/Plain; charset=UTF-8', fileName: 'x').docKind, DocumentKind.text);
      expect(classify(uti: ' COM.ADOBE.PDF ', fileName: 'x').docKind, DocumentKind.pdf);
    });

    test('extension parsing ignores directories and takes the last dot', () {
      expect(extensionOf('/a.b/c/d.TAR.GZ'), 'gz');
      expect(extensionOf(r'C:\dir.pdf\file'), isNull);
      expect(extensionOf('.hidden'), isNull);
      expect(extensionOf('x.'), isNull);
      expect(classify(fileName: r'C:\Users\me\Docs\Budget.XLSX').docKind, DocumentKind.excel);
    });
  });

  test('isGenericUti / isGenericMime / normalizeMime', () {
    expect(isGenericUti(null), isTrue);
    expect(isGenericUti('public.jpeg'), isFalse);
    expect(isGenericMime(null), isTrue);
    expect(isGenericMime('image/png'), isFalse);
    expect(normalizeMime(' Image/PNG ;q=1'), 'image/png');
    expect(normalizeMime('/png'), isNull);
    expect(normalizeMime('image/'), isNull);
  });
}
