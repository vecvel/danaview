// HOM-16: FileKind, SourceHint, DocumentItem and FileEntry (ARCH v1.2 §5.1).

import 'package:danaview_library/danaview_library.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 10, 1, 12);

FileEntry _entry({FileKind kind = FileKind.document, String? subKind = 'pdf'}) => FileEntry(
      id: EntryId.parse('fe_abc'),
      folderId: FolderId.parse('fd_root'),
      displayName: 'Report.pdf',
      kind: kind,
      subKind: subKind,
      sizeBytes: 1234,
      addedAt: _t0,
      modifiedAt: _t0,
      sourceHint: SourceHint.files,
    );

void main() {
  group('FileKind (open, append-only)', () {
    test('codes are stable and in the ARCH order', () {
      expect(FileKind.values.map((k) => k.code), ['video', 'photo', 'document', 'audio', 'other']);
      for (final k in FileKind.values) {
        expect(FileKind.decode(k.code), k);
      }
    });

    test('an unknown kind (1.3.0 savedCode) decodes to other', () {
      expect(FileKind.decode('savedCode'), FileKind.other);
      expect(FileKind.tryDecode('savedCode'), isNull);
      expect(FileKind.isKnownCode('savedCode'), isFalse);
      expect(FileKind.decode(''), FileKind.other);
    });

    test('MediaItem.kind follows the subtype', () {
      final m = DateTime.utc(2026);
      expect(VideoMediaItem(id: const ItemId.opaque('/a.mp4'), uri: '/a.mp4', name: 'a', modifiedAt: m, mimeType: 'video/mp4').kind,
          FileKind.video);
      expect(PhotoMediaItem(id: PhotoKitId.of('X/L0/001'), uri: 'ph://X', name: 'p', modifiedAt: m, mimeType: 'image/heic').kind,
          FileKind.photo);
      expect(DocumentItem(id: EntryId.parse('fe_d'), uri: 'u', name: 'd', modifiedAt: m, mimeType: 'application/pdf').kind,
          FileKind.document);
    });
  });

  group('SourceHint', () {
    test('codes round-trip; unknown codes decode to unknown', () {
      expect(SourceHint.values.map((s) => s.code),
          ['photos', 'files', 'openWith', 'shareExtension', 'linkedFolder', 'editorExport', 'player', 'unknown']);
      for (final s in SourceHint.values) {
        expect(SourceHint.decode(s.code), s);
      }
      expect(SourceHint.decode('camera'), SourceHint.unknown);
    });
  });

  group('DocumentKind and DocumentItem', () {
    test('decode is lenient', () {
      for (final k in DocumentKind.values) {
        expect(DocumentKind.decode(k.code), k);
      }
      expect(DocumentKind.decode(null), DocumentKind.other);
      expect(DocumentKind.decode('keynote2030'), DocumentKind.other);
    });

    test('DocumentItem fields, validation, equality by id', () {
      final d = DocumentItem(
        id: EntryId.parse('fe_doc'),
        uri: 'danaview-library://fe_doc',
        name: 'Deck.pptx',
        modifiedAt: _t0,
        mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        sizeBytes: 10,
        docKind: DocumentKind.powerpoint,
        pageCount: 12,
      );
      expect(d, isA<DocumentMediaItem>());
      expect(d.subKind, 'powerpoint');
      final e = d.copyWith(pageCount: 13, textEncoding: 'utf-8');
      expect(e.pageCount, 13);
      expect(e.docKind, DocumentKind.powerpoint);
      expect(e, d);
      expect(
          () => DocumentItem(id: EntryId.parse('fe_x'), uri: 'u', name: 'n', modifiedAt: _t0, mimeType: 'm', pageCount: -1),
          throwsArgumentError);
      expect(() => DocumentItem(id: FolderId.parse('fd_x'), uri: 'u', name: 'n', modifiedAt: _t0, mimeType: 'm'),
          throwsArgumentError);
    });

    test('switches over MediaItem stay exhaustive with DocumentItem', () {
      final MediaItem item = DocumentItem(id: EntryId.parse('fe_s'), uri: 'u', name: 'n', modifiedAt: _t0, mimeType: 'text/plain');
      final label = switch (item) {
        VideoMediaItem() => 'video',
        PhotoMediaItem() => 'photo',
        DocumentMediaItem() => 'document',
      };
      expect(label, 'document');
    });
  });

  group('FileEntry', () {
    test('a savedCode kind string decodes to other without loss of the raw string', () {
      final json = _entry().toJson()
        ..['kind'] = 'savedCode'
        ..['subKind'] = 'qr';
      final e = FileEntry.fromJson(json);
      expect(e.kind, FileKind.other);
      expect(e.kindCode, 'savedCode');
      expect(e.hasKnownKind, isFalse);
      expect(e.subKind, 'qr');
      expect(e.docKind, isNull);
      expect(documentSubFilterOf(e.kind, e.subKind), DocumentKind.other);
      expect(e.toJson()['kind'], 'savedCode');
      expect(FileEntry.fromJson(e.toJson()), e);
      // Editing other fields keeps the raw kind; changing the kind replaces it.
      expect(e.copyWith(isFavourite: true).kindCode, 'savedCode');
      expect(e.copyWith(kind: FileKind.photo).kindCode, 'photo');
    });

    test('toJson / fromJson round-trip every field', () {
      final e = _entry().copyWith(
        lastOpenedAt: _t0.add(const Duration(days: 1)),
        isFavourite: true,
        quickHash: 'qh',
        trashedAt: _t0.add(const Duration(days: 2)),
        expiresAt: _t0.add(const Duration(days: 32)),
        sourceHint: SourceHint.shareExtension,
      );
      final back = FileEntry.fromJson(e.toJson());
      expect(back, e);
      expect(back.hashCode, e.hashCode);
      expect(back.isTrashed, isTrue);
      expect(back.docKind, DocumentKind.pdf);
      expect(back.copyWith(trashedAt: null, expiresAt: null).isTrashed, isFalse);
    });

    test('equality compares moments, not time zones', () {
      final a = _entry();
      final b = a.copyWith(addedAt: _t0.toLocal());
      expect(b, a);
      expect(b.hashCode, a.hashCode);
      expect(a.copyWith(displayName: 'Other.pdf'), isNot(a));
    });

    test('invalid entries are rejected', () {
      expect(() => _entry().copyWith(displayName: ''), throwsArgumentError);
      expect(() => _entry().copyWith(sizeBytes: -1), throwsArgumentError);
      expect(() => _entry().copyWith(trashedAt: _t0), throwsArgumentError);
      expect(
          () => FileEntry(
                id: EntryId.parse('fe_a'),
                folderId: FolderId.parse('fd_a'),
                displayName: 'n',
                kind: FileKind.photo,
                kindCode: 'video',
                sizeBytes: 0,
                addedAt: _t0,
                modifiedAt: _t0,
                sourceHint: SourceHint.photos,
              ),
          throwsArgumentError);
      final bad = _entry().toJson()..['id'] = 'not-an-id';
      expect(() => FileEntry.fromJson(bad), throwsFormatException);
      final missing = _entry().toJson()..remove('addedAt');
      expect(() => FileEntry.fromJson(missing), throwsFormatException);
      final wrongType = _entry().toJson()..['sizeBytes'] = '12';
      expect(() => FileEntry.fromJson(wrongType), throwsFormatException);
      final halfTrashed = _entry().toJson()..['trashedAt'] = 5;
      expect(() => FileEntry.fromJson(halfTrashed), throwsFormatException);
    });

    test('toString carries no file name (ARCH rule 30)', () {
      expect(_entry().toString(), isNot(contains('Report')));
    });

    test('an entry built from a classification', () {
      final c = classify(uti: 'public.data', mime: 'application/octet-stream', fileName: 'Budget.numbers');
      final e = _entry(kind: c.kind, subKind: c.subKind);
      expect(e.docKind, DocumentKind.excel);
    });
  });
}
