// OWNER: HOM-22
//
// BUILD_PLAN HOM-22: which actions the single-file menu and the multi-select file group offer for
// library files, read-only files (linked folders: no rename, move or delete) and system-library
// assets; Merge into PDF only for PDFs and photos; the platform capabilities of HOM plan §8.3.

import 'dart:io' show Platform;

import 'package:danaview_library/danaview_library.dart';
import 'package:test/test.dart';

final DateTime _t = DateTime.utc(2026, 10, 1);

PhotoMediaItem _photo(String id, {String uri = '/lib/files/x/p.jpg'}) =>
    PhotoMediaItem(id: ItemId.opaque(id), uri: uri, name: 'p.jpg', modifiedAt: _t, mimeType: 'image/jpeg', width: 1, height: 1);

VideoMediaItem _video(String id) =>
    VideoMediaItem(id: ItemId.opaque(id), uri: '/lib/v.mp4', name: 'v.mp4', modifiedAt: _t, mimeType: 'video/mp4', duration: Duration.zero);

DocumentItem _doc(String id, DocumentKind kind, {String uri = '/lib/d'}) =>
    DocumentItem(id: ItemId.opaque(id), uri: uri, name: 'd', modifiedAt: _t, mimeType: kind == DocumentKind.pdf ? 'application/pdf' : 'text/plain', docKind: kind);

List<FileAction> _menu(MediaItem item, {FileOutPlatform platform = FileOutPlatform.iOS}) {
  final caps = FileOutCapabilities.of(platform);
  return fileActionsFor(
    FileActionTarget.of(item),
    canShare: caps.canShare,
    canOpenIn: caps.canOpenIn,
    canSaveOut: caps.primarySaveTarget != null,
    canSaveToPhotos: caps.canSaveToPhotos,
  );
}

List<FileAction> _group(List<MediaItem> items, {bool merge = true, FileOutPlatform platform = FileOutPlatform.iOS}) {
  final caps = FileOutCapabilities.of(platform);
  return selectionFileActionsFor(
    [for (final i in items) FileActionTarget.of(i)],
    canShare: caps.canShare,
    canSaveOut: caps.primarySaveTarget != null,
    canSaveToPhotos: caps.canSaveToPhotos,
    canMerge: merge,
  );
}

void main() {
  test('a library photo gets the full menu, in menu order', () {
    expect(_menu(_photo('fe_a')), [
      FileAction.share,
      FileAction.copyTo,
      FileAction.moveTo,
      FileAction.rename,
      FileAction.info,
      FileAction.openIn,
      FileAction.favourite,
      FileAction.saveOut,
      FileAction.saveToPhotos,
      FileAction.delete,
    ]);
    expect(_menu(_doc('fe_d', DocumentKind.pdf)), isNot(contains(FileAction.saveToPhotos)), reason: 'documents are not media');
  });

  test('a linked-folder file is read-only: no copy, move, rename, favourite or delete', () {
    final linked = _doc('lk:root/a.txt', DocumentKind.text, uri: 'file:///Users/me/Docs/a.txt');
    expect(_menu(linked), [FileAction.share, FileAction.info, FileAction.openIn, FileAction.saveOut]);
    // `file://` URIs become host paths: a rooted path without a drive on Windows (FIX-S1Q-A5).
    expect(FileActionTarget.of(linked).localPath, Platform.isWindows ? r'\Users\me\Docs\a.txt' : '/Users/me/Docs/a.txt');
  });

  test('a file:// URI becomes a path of the host style, on either host', () {
    expect(localPathOf('file:///Users/me/Docs/a.txt', windows: false), '/Users/me/Docs/a.txt');
    expect(localPathOf('file:///Users/me/Docs/a.txt', windows: true), r'\Users\me\Docs\a.txt');
    expect(localPathOf('file:///C:/Users/me/My%20Docs/a.pdf', windows: true), r'C:\Users\me\My Docs\a.pdf');
    expect(localPathOf('file://server/share/a.pdf', windows: true), r'\\server\share\a.pdf');
    expect(localPathOf('file:///C:/Users/me/a.pdf', windows: false), '/C:/Users/me/a.pdf');
  });

  test('a system-library asset without a path offers File info only', () {
    expect(_menu(_photo('ph:ABC/L0/001', uri: 'ph:ABC/L0/001')), [FileAction.info]);
    expect(localPathOf('content://media/external/images/1'), isNull);
    expect(localPathOf(r'C:\Users\me\a.pdf'), r'C:\Users\me\a.pdf');
  });

  test('Windows and Linux: no share sheet and no Photos', () {
    final menu = _menu(_photo('fe_a'), platform: FileOutPlatform.windows);
    expect(menu, isNot(contains(FileAction.share)));
    expect(menu, isNot(contains(FileAction.saveToPhotos)));
    expect(menu, containsAll([FileAction.openIn, FileAction.saveOut]));
    expect(FileOutCapabilities.of(FileOutPlatform.linux).saveLabel, 'Save…');
  });

  test('platform save labels and targets (HOM plan §8.3)', () {
    expect(FileOutCapabilities.of(FileOutPlatform.iOS).saveLabel, 'Save to Files');
    expect(FileOutCapabilities.of(FileOutPlatform.iOS).primarySaveTarget, SaveOutTarget.files);
    expect(FileOutCapabilities.of(FileOutPlatform.android).saveLabel, 'Save to Downloads');
    expect(FileOutCapabilities.of(FileOutPlatform.android).primarySaveTarget, SaveOutTarget.downloads);
    expect(FileOutCapabilities.of(FileOutPlatform.macOS).canSaveToPhotos, isTrue);
    expect(FileOutCapabilities.none.primarySaveTarget, isNull);
  });

  test('the multi-select group for library files, read-only files and mixes', () {
    expect(_group([_photo('fe_a'), _video('fe_b')]), [
      FileAction.share,
      FileAction.moveTo,
      FileAction.copyTo,
      FileAction.favourite,
      FileAction.saveOut,
      FileAction.saveToPhotos,
      FileAction.delete,
    ]);
    expect(_group([_photo('fe_a'), _doc('fe_d', DocumentKind.word)]), [
      FileAction.share,
      FileAction.moveTo,
      FileAction.copyTo,
      FileAction.favourite,
      FileAction.saveOut,
      FileAction.delete,
    ]);
    expect(_group([_photo('fe_a'), _doc('lk:r/x', DocumentKind.text)]), [FileAction.share, FileAction.saveOut],
        reason: 'a read-only item limits the group to the out actions');
    expect(_group([_photo('fe_a'), _photo('ph:A/L0/1', uri: 'ph:A/L0/1')]), isEmpty, reason: 'nothing every item can do');
    expect(_group(const []), isEmpty);
  });

  test('Merge into PDF only for two or more PDFs and photos, and only when wired', () {
    expect(_group([_doc('fe_a', DocumentKind.pdf), _photo('fe_b')]), contains(FileAction.mergeIntoPdf));
    expect(_group([_doc('fe_a', DocumentKind.pdf), _doc('fe_b', DocumentKind.pdf)]), contains(FileAction.mergeIntoPdf));
    expect(_group([_doc('fe_a', DocumentKind.pdf), _video('fe_v')]), isNot(contains(FileAction.mergeIntoPdf)));
    expect(_group([_doc('fe_a', DocumentKind.pdf), _doc('fe_w', DocumentKind.word)]), isNot(contains(FileAction.mergeIntoPdf)));
    expect(_group([_doc('fe_a', DocumentKind.pdf)]), isNot(contains(FileAction.mergeIntoPdf)));
    expect(_group([_doc('fe_a', DocumentKind.pdf), _photo('fe_b')], merge: false), isNot(contains(FileAction.mergeIntoPdf)));
  });
}
