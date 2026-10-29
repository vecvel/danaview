// OWNER: HOM-28
//
// The page tools in the single-file menu (HOM plan §8.5 entry points): a readable PDF (a library
// file or a linked file) gets "Organise pages" and "Merge with…" after "Open in another app" when
// the tools are wired; never other documents, photos, unwired builds or files without a path.

import 'package:danaview_library/danaview_library.dart';
import 'package:test/test.dart';

final DateTime _t = DateTime.utc(2026, 10, 30);

DocumentItem _doc(String id, DocumentKind kind, {String uri = '/lib/d.pdf'}) => DocumentItem(
      id: ItemId.opaque(id),
      uri: uri,
      name: 'd',
      modifiedAt: _t,
      mimeType: kind == DocumentKind.pdf ? 'application/pdf' : 'text/plain',
      docKind: kind,
    );

List<FileAction> _menu(MediaItem item, {bool tools = true}) => fileActionsFor(
      FileActionTarget.of(item),
      canShare: true,
      canOpenIn: true,
      canSaveOut: true,
      canSaveToPhotos: true,
      canPdfTools: tools,
    );

void main() {
  test('a PDF gets Organise pages and Merge with… after Open in another app', () {
    final library = _menu(_doc('fe_abc', DocumentKind.pdf));
    final open = library.indexOf(FileAction.openIn);
    expect(library.sublist(open + 1, open + 3), [FileAction.organisePages, FileAction.mergeWith]);
    final linked = _menu(_doc('lk:r1/a.pdf', DocumentKind.pdf));
    expect(linked, containsAll([FileAction.organisePages, FileAction.mergeWith]));
    expect(FileActionTarget.of(_doc('fe_abc', DocumentKind.pdf)).isPdf, isTrue);
  });

  test('never for other documents, photos, unwired builds or files without a path', () {
    expect(_menu(_doc('fe_abc', DocumentKind.word)), isNot(contains(FileAction.organisePages)));
    expect(_menu(_doc('fe_abc', DocumentKind.pdf), tools: false), isNot(contains(FileAction.organisePages)));
    expect(_menu(_doc('ph:1', DocumentKind.pdf, uri: 'ph://asset')), isNot(contains(FileAction.mergeWith)));
    final photo = PhotoMediaItem(id: ItemId.opaque('fe_p'), uri: '/lib/p.jpg', name: 'p.jpg', modifiedAt: _t, mimeType: 'image/jpeg', width: 1, height: 1);
    expect(_menu(photo), isNot(contains(FileAction.organisePages)));
  });
}
