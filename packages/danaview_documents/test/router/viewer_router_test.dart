// OWNER: HOM-23
//
// BUILD_PLAN HOM-23 "router picks the right viewer per platform": ARCH §3 / HOM plan §8.4 as a
// table test over every kind × platform with every native viewer registered, then the capability
// probes (PdfRenderer can't open a password PDF → file card; Quick Look can't preview → in-app
// text or file card), unregistered viewers, throwing probes and skipped (failed) viewers.

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

ViewerFile _f(String name, {FileKind? kind, String? mime, String? uti}) {
  final c = classify(fileName: name, mime: mime, uti: uti);
  return ViewerFile(path: '/tmp/$name', displayName: name, kind: kind ?? c.kind, docKind: c.docKind, mime: mime, uti: uti);
}

const _all = {ViewerKind.photo, ViewerKind.player, ViewerKind.pdf, ViewerKind.quickLook};

const _ios = ViewerPlatform.iOS;
const _android = ViewerPlatform.android;
const _mac = ViewerPlatform.macOS;
const _win = ViewerPlatform.windows;
const _linux = ViewerPlatform.linux;

void main() {
  // ARCH §3 / HOM plan §8.4: file → expected viewer on iOS, Android, macOS, Windows, Linux.
  final matrix = <String, Map<ViewerPlatform, ViewerKind>>{
    'holiday.jpg': {
      _ios: ViewerKind.photo,
      _android: ViewerKind.photo,
      _mac: ViewerKind.photo,
      _win: ViewerKind.photo,
      _linux: ViewerKind.photo
    },
    'clip.mp4': {
      _ios: ViewerKind.player,
      _android: ViewerKind.player,
      _mac: ViewerKind.player,
      _win: ViewerKind.player,
      _linux: ViewerKind.player
    },
    'song.mp3': {
      _ios: ViewerKind.player,
      _android: ViewerKind.player,
      _mac: ViewerKind.player,
      _win: ViewerKind.player,
      _linux: ViewerKind.player
    },
    'report.pdf': {
      _ios: ViewerKind.pdf,
      _android: ViewerKind.pdf,
      _mac: ViewerKind.pdf,
      _win: ViewerKind.fileCard,
      _linux: ViewerKind.fileCard
    },
    'letter.docx': {
      _ios: ViewerKind.quickLook,
      _android: ViewerKind.fileCard,
      _mac: ViewerKind.quickLook,
      _win: ViewerKind.fileCard,
      _linux: ViewerKind.fileCard
    },
    'budget.xlsx': {
      _ios: ViewerKind.quickLook,
      _android: ViewerKind.fileCard,
      _mac: ViewerKind.quickLook,
      _win: ViewerKind.fileCard,
      _linux: ViewerKind.fileCard
    },
    'deck.pptx': {
      _ios: ViewerKind.quickLook,
      _android: ViewerKind.fileCard,
      _mac: ViewerKind.quickLook,
      _win: ViewerKind.fileCard,
      _linux: ViewerKind.fileCard
    },
    'notes.txt': {
      _ios: ViewerKind.quickLook,
      _android: ViewerKind.text,
      _mac: ViewerKind.quickLook,
      _win: ViewerKind.text,
      _linux: ViewerKind.text
    },
    'readme.md': {
      _ios: ViewerKind.quickLook,
      _android: ViewerKind.text,
      _mac: ViewerKind.quickLook,
      _win: ViewerKind.text,
      _linux: ViewerKind.text
    },
    'server.log': {
      _ios: ViewerKind.quickLook,
      _android: ViewerKind.text,
      _mac: ViewerKind.quickLook,
      _win: ViewerKind.text,
      _linux: ViewerKind.text
    },
    'data.json': {
      _ios: ViewerKind.quickLook,
      _android: ViewerKind.text,
      _mac: ViewerKind.quickLook,
      _win: ViewerKind.text,
      _linux: ViewerKind.text
    },
    'table.csv': {
      _ios: ViewerKind.quickLook,
      _android: ViewerKind.csv,
      _mac: ViewerKind.quickLook,
      _win: ViewerKind.csv,
      _linux: ViewerKind.csv
    },
    'table.tsv': {
      _ios: ViewerKind.quickLook,
      _android: ViewerKind.csv,
      _mac: ViewerKind.quickLook,
      _win: ViewerKind.csv,
      _linux: ViewerKind.csv
    },
    'archive.zip': {
      _ios: ViewerKind.quickLook,
      _android: ViewerKind.fileCard,
      _mac: ViewerKind.quickLook,
      _win: ViewerKind.fileCard,
      _linux: ViewerKind.fileCard
    },
  };

  for (final MapEntry(key: name, value: expected) in matrix.entries) {
    for (final MapEntry(key: platform, value: viewer) in expected.entries) {
      test('$name on ${platform.name} → ${viewer.name}', () async {
        final router = ViewerRouter(platform);
        expect(await router.resolve(_f(name), registered: _all), viewer);
        // The last candidate is always something the app has.
        final last = router.candidates(_f(name)).last;
        expect(last == ViewerKind.fileCard || last.isBuiltIn, isTrue);
      });
    }
  }

  test('a file of an unknown stored kind (FileKind.other) is routed like Documents › Other', () async {
    final f = ViewerFile(path: '/x/code.dncode', displayName: 'code.dncode', kind: FileKind.other);
    expect(await const ViewerRouter(_android).resolve(f, registered: _all), ViewerKind.fileCard);
    expect(await const ViewerRouter(_ios).resolve(f, registered: _all), ViewerKind.quickLook);
  });

  test('without registered native viewers the app still shows every file', () async {
    expect(await const ViewerRouter(_ios).resolve(_f('report.pdf')), ViewerKind.fileCard);
    expect(await const ViewerRouter(_ios).resolve(_f('notes.txt')), ViewerKind.text);
    expect(await const ViewerRouter(_mac).resolve(_f('table.csv')), ViewerKind.csv);
    expect(await const ViewerRouter(_android).resolve(_f('holiday.jpg')), ViewerKind.fileCard);
  });

  group('capability probes', () {
    test('PdfRenderer refusing a password PDF on older Android → file card', () async {
      final probes = FunctionProbes({ViewerKind.pdf: (f) async => false});
      expect(await const ViewerRouter(_android).resolve(_f('locked.pdf'), registered: _all, probes: probes), ViewerKind.fileCard);
    });

    test('PDFKit unavailable on Apple → Quick Look, then the file card', () async {
      final noPdf = FunctionProbes({ViewerKind.pdf: (f) async => false});
      expect(await const ViewerRouter(_ios).resolve(_f('report.pdf'), registered: _all, probes: noPdf), ViewerKind.quickLook);
      final neither = FunctionProbes({ViewerKind.pdf: (f) async => false, ViewerKind.quickLook: (f) async => false});
      expect(await const ViewerRouter(_mac).resolve(_f('report.pdf'), registered: _all, probes: neither), ViewerKind.fileCard);
    });

    test('Quick Look unable to preview → in-app text or CSV on Apple, file card for Office', () async {
      final noQl = FunctionProbes({ViewerKind.quickLook: (f) async => false});
      expect(await const ViewerRouter(_ios).resolve(_f('notes.txt'), registered: _all, probes: noQl), ViewerKind.text);
      expect(await const ViewerRouter(_mac).resolve(_f('table.csv'), registered: _all, probes: noQl), ViewerKind.csv);
      expect(await const ViewerRouter(_ios).resolve(_f('letter.docx'), registered: _all, probes: noQl), ViewerKind.fileCard);
    });

    test('a throwing probe counts as "can\'t"', () async {
      final boom = FunctionProbes({ViewerKind.pdf: (f) => Future<bool>.error(StateError('x'))});
      expect(await const ViewerRouter(_android).resolve(_f('report.pdf'), registered: _all, probes: boom), ViewerKind.fileCard);
    });

    test('probes see the file and run only for registered native viewers', () async {
      final asked = <(ViewerKind, String)>[];
      final probes = FunctionProbes({
        ViewerKind.quickLook: (f) async {
          asked.add((ViewerKind.quickLook, f.displayName));
          return true;
        },
      });
      await const ViewerRouter(_ios).resolve(_f('notes.txt'), registered: {ViewerKind.quickLook}, probes: probes);
      await const ViewerRouter(_android).resolve(_f('notes.txt'), registered: {ViewerKind.quickLook}, probes: probes);
      expect(asked, [(ViewerKind.quickLook, 'notes.txt')]);
    });
  });

  test('a skipped (failed) viewer moves to the next candidate', () async {
    const r = ViewerRouter(_ios);
    expect(await r.resolve(_f('report.pdf'), registered: _all, skip: {ViewerKind.pdf}), ViewerKind.quickLook);
    expect(await r.resolve(_f('table.csv'), registered: _all, skip: {ViewerKind.quickLook, ViewerKind.csv}), ViewerKind.text);
    expect(await r.resolve(_f('notes.txt'), registered: _all, skip: {ViewerKind.quickLook, ViewerKind.text}), ViewerKind.fileCard);
  });

  test('MIME and UTType inputs decide like the classifier (Android content URIs without extensions)', () async {
    final pdf = _f('document', mime: 'application/pdf');
    expect(await const ViewerRouter(_android).resolve(pdf, registered: _all), ViewerKind.pdf);
    final csv = ViewerFile(path: '/x/export', displayName: 'export', kind: FileKind.document, docKind: DocumentKind.text, mime: 'text/csv');
    expect(await const ViewerRouter(_android).resolve(csv), ViewerKind.csv);
  });

  test('ViewerPlatform.of maps every TargetPlatform', () {
    expect(ViewerPlatform.of(TargetPlatform.iOS), _ios);
    expect(ViewerPlatform.of(TargetPlatform.android), _android);
    expect(ViewerPlatform.of(TargetPlatform.macOS), _mac);
    expect(ViewerPlatform.of(TargetPlatform.windows), _win);
    expect(ViewerPlatform.of(TargetPlatform.linux), _linux);
    expect(ViewerPlatform.of(TargetPlatform.fuchsia), _linux);
  });

  group('ViewerFile', () {
    test('fromEntry and fromItem carry the facts; toString hides the name and path', () {
      final t = DateTime.utc(2026, 10, 20);
      final entry = FileEntry(
        id: EntryId.random(),
        folderId: FolderId.parse('fd_${'a' * 22}'),
        displayName: 'Secret plan.pdf',
        kind: FileKind.document,
        subKind: DocumentKind.pdf.code,
        sizeBytes: 1234,
        addedAt: t,
        modifiedAt: t,
        sourceHint: SourceHint.files,
      );
      final f = ViewerFile.fromEntry(entry, '/lib/files/secret.pdf');
      expect(f.entryId, entry.id);
      expect(f.docKind, DocumentKind.pdf);
      expect(f.sizeBytes, 1234);
      expect(f.toString(), isNot(contains('Secret')));
      expect(f.toString(), isNot(contains('/lib')));

      final item = DocumentItem(
        id: ItemId.parse('lk:root/notes.txt'),
        uri: 'file:///Users/me/notes%20a.txt',
        name: 'notes a.txt',
        modifiedAt: t,
        mimeType: 'application/octet-stream',
        docKind: DocumentKind.text,
      );
      final g = ViewerFile.fromItem(item);
      expect(g.path, '/Users/me/notes a.txt');
      expect(g.entryId, isNull);
      expect(g.mime, isNull);
      expect(g.outFile.displayName, 'notes a.txt');
    });
  });
}
