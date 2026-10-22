// OWNER: HOM-11
//
// Fixtures of the photo viewer tests (BUILD_PLAN HOM-11): an in-process library store in a temp
// directory, a fake system photo library whose `assetDetail` answers with set EXIF, and grid items
// for system and desktop photos.

// The root package reaches danaview_library(_native) through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_features/src/library/photos/photo_grid_item.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-process store in a temp dir.
class ViewerLib {
  ViewerLib._(this.root, this.store);

  final Directory root;
  final LibraryStore store;

  static Future<ViewerLib> open(WidgetTester tester) async {
    final root = Directory.systemTemp.createTempSync('hom11_');
    final store = (await tester.runAsync(() => LibraryStore.open(root: root.path, background: false)))!;
    return ViewerLib._(root, store);
  }

  Future<T> run<T>(WidgetTester tester, Future<T> Function(LibraryStore s) op) async => (await tester.runAsync(() => op(store))) as T;

  /// Imports a photo named [name] taken at [taken].
  Future<FileEntry> addPhoto(
    WidgetTester tester,
    String name,
    DateTime taken, {
    int w = 4032,
    int h = 3024,
    int flags = 0,
    String? camera,
    SourceHint hint = SourceHint.photos,
    List<int>? bytes,
  }) =>
      run(tester, (s) => s.write((wr, now) {
            final job = wr.beginImport(now: now);
            (wr.fs.openPart(job.id)..writeFromSync(bytes ?? List<int>.filled(2048, 7))).closeSync();
            return wr.commitImport(
              job.id,
              ImportedFileInfo(
                displayName: name,
                kind: FileKind.photo,
                modifiedAt: taken,
                sourceHint: hint,
                meta: EntryMeta(width: w, height: h, takenAt: taken, camera: camera, flags: flags),
              ),
              now: now,
            );
          }));

  Future<void> close(WidgetTester tester) async {
    await tester.runAsync(() async {
      await store.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
  }
}

/// The Danaview photos of [store] as grid items, newest first.
List<PhotoGridItem> danaviewItems(LibraryStore store) {
  final entries = store.reader.entriesPage(const EntryQuery(kinds: {FileKind.photo}, sort: EntrySortKey.modifiedAt), limit: 500);
  final out = [
    for (final e in entries)
      PhotoGridItem(
        id: e.id,
        origin: PhotoOrigin.danaview,
        name: e.displayName,
        date: store.reader.meta(e.id)?.takenAt ?? e.modifiedAt,
        modifiedAt: e.modifiedAt,
        thumbSource: store.paths.entryFile(e.id, e.displayName),
        width: store.reader.meta(e.id)?.width ?? 0,
        height: store.reader.meta(e.id)?.height ?? 0,
        folderId: e.folderId,
        isFavourite: e.isFavourite,
      ),
  ]..sort((a, b) => b.date.compareTo(a.date));
  return out;
}

/// A system (PhotoKit) photo grid item.
PhotoGridItem systemPhoto(String localId, {bool live = false, bool raw = false, String name = 'IMG_0001.HEIC', String mime = 'image/heic'}) {
  final t = DateTime(2026, 10, 20, 9, 30);
  final media = PhotoMediaItem(
    id: PhotoKitId.of(localId),
    uri: 'ph://$localId',
    name: name,
    modifiedAt: t,
    mimeType: mime,
    sizeBytes: 2400000,
    width: 4032,
    height: 3024,
    isLivePhoto: live,
    isRaw: raw,
    takenAt: t,
  );
  return photoGridItemOf(media, PhotoOrigin.system);
}

/// A desktop Pictures photo grid item at [path].
PhotoGridItem desktopPhoto(String path, {String name = 'beach.jpg'}) {
  final t = DateTime(2026, 9, 1, 12);
  final media = PhotoMediaItem(
    id: LinkedItemId.of('pictures', name),
    uri: path,
    name: name,
    modifiedAt: t,
    mimeType: 'image/jpeg',
    sizeBytes: 812000,
    width: 1600,
    height: 1200,
    iso: 200,
    aperture: 2.8,
    cameraModel: 'X100V',
    takenAt: t,
  );
  return photoGridItemOf(media, PhotoOrigin.desktop);
}

/// A fake system library answering `assetDetail` from [details].
class FakeViewerSystemLibrary implements SystemPhotoLibrary {
  FakeViewerSystemLibrary({this.details = const {}});

  final Map<String, SystemPhotoDetail> details;
  final List<String> detailRequests = [];

  @override
  Future<SystemPhotoDetail> assetDetail(String localIdentifier) async {
    detailRequests.add(localIdentifier);
    final d = details[localIdentifier];
    if (d == null) throw const LibraryNativeException(LibraryNativeErrorCode.notFound, 'missing');
    return d;
  }

  @override
  Future<PhotoLibraryAuthorization> authorizationStatus() async => PhotoLibraryAuthorization.authorized;

  @override
  Future<PhotoLibraryAuthorization> requestAuthorization() async => PhotoLibraryAuthorization.authorized;

  @override
  Future<List<String>> presentLimitedLibraryPicker() async => const [];

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<void> startObserving() async {}

  @override
  Future<void> stopObserving() async {}

  @override
  Future<SystemPhotoPage> fetchPage({
    SystemPhotoFilter filter = SystemPhotoFilter.all,
    SystemPhotoSort sort = SystemPhotoSort.creationNewestFirst,
    String? albumId,
    int offset = 0,
    int limit = 200,
    String? changeToken,
  }) async =>
      SystemPhotoPage(assets: const [], offset: offset, totalCount: 0, changeToken: 't', tokenStale: false);

  @override
  Future<List<SystemPhotoAsset>> fetchAssets(List<String> ids) async => const [];

  @override
  Future<List<SystemPhotoAlbum>> fetchAlbums() async => const [];

  @override
  Future<SystemPhotoCopy> copyAsset(String localIdentifier, String destinationDirectory, {bool pairedVideo = false, String? requestId}) async =>
      SystemPhotoCopy(path: '$destinationDirectory/x', sizeBytes: 1);

  @override
  Future<void> cancelCopy(String requestId) async {}

  @override
  Stream<SystemPhotoChange> get changes => const Stream.empty();

  @override
  Stream<PhotoLibraryAuthorization> get authorizationChanges => const Stream.empty();
}


/// The EXIF a fixture photo carries.
const exifFixture = (
  make: 'FUJIFILM',
  model: 'X-T5',
  lens: 'XF23mmF1.4 R LM WR',
  exposure: (1, 250),
  fNumber: (28, 10),
  iso: 400,
  focal: (23, 1),
  taken: '2026:09:14 17:42:05',
  width: 7728,
  height: 5152,
);

/// A TIFF/EXIF block (header, IFD0 with Make/Model and the Exif and GPS pointers, the Exif IFD,
/// a GPS IFD with a latitude that must never be read) in [endian].
Uint8List buildExifTiff({Endian endian = Endian.big}) {
  final out = BytesBuilder();
  final data = BytesBuilder(); // out-of-line values, appended after the IFDs
  // Layout: header 8 | IFD0 (4 entries) | Exif IFD (8 entries) | GPS IFD (1 entry) | data.
  const ifd0At = 8;
  const ifd0Len = 2 + 4 * 12 + 4;
  const exifAt = ifd0At + ifd0Len;
  const exifLen = 2 + 8 * 12 + 4;
  const gpsAt = exifAt + exifLen;
  const gpsLen = 2 + 1 * 12 + 4;
  const dataAt = gpsAt + gpsLen;

  int place(List<int> bytes) {
    final at = dataAt + data.length;
    data.add(bytes);
    if (data.length.isOdd) data.addByte(0);
    return at;
  }

  Uint8List u16(int v) => (ByteData(2)..setUint16(0, v, endian)).buffer.asUint8List();
  Uint8List u32(int v) => (ByteData(4)..setUint32(0, v, endian)).buffer.asUint8List();
  List<int> asciiZ(String s) => [...s.codeUnits, 0];
  List<int> rational((int, int) r) => [...u32(r.$1), ...u32(r.$2)];

  List<int> entry(int tag, int type, int count, List<int> inlineOrPointer) {
    final value = List<int>.filled(4, 0);
    for (var i = 0; i < inlineOrPointer.length && i < 4; i++) {
      value[i] = inlineOrPointer[i];
    }
    return [...u16(tag), ...u16(type), ...u32(count), ...value];
  }

  List<int> asciiEntry(int tag, String text) {
    final bytes = asciiZ(text);
    return bytes.length <= 4 ? entry(tag, 2, bytes.length, bytes) : entry(tag, 2, bytes.length, u32(place(bytes)));
  }

  List<int> rationalEntry(int tag, (int, int) r) => entry(tag, 5, 1, u32(place(rational(r))));
  List<int> shortEntry(int tag, int v) => entry(tag, 3, 1, u16(v));
  List<int> longEntry(int tag, int v) => entry(tag, 4, 1, u32(v));

  final ifd0 = [
    ...u16(4),
    ...asciiEntry(0x010F, exifFixture.make),
    ...asciiEntry(0x0110, exifFixture.model),
    ...longEntry(0x8769, exifAt),
    ...longEntry(0x8825, gpsAt),
    ...u32(0),
  ];
  final exif = [
    ...u16(8),
    ...rationalEntry(0x829A, exifFixture.exposure),
    ...rationalEntry(0x829D, exifFixture.fNumber),
    ...shortEntry(0x8827, exifFixture.iso),
    ...asciiEntry(0x9003, exifFixture.taken),
    ...rationalEntry(0x920A, exifFixture.focal),
    ...longEntry(0xA002, exifFixture.width),
    ...longEntry(0xA003, exifFixture.height),
    ...asciiEntry(0xA434, exifFixture.lens),
    ...u32(0),
  ];
  final gps = [
    ...u16(1),
    ...entry(0x0002, 5, 1, u32(place(rational((51, 1))))),
    ...u32(0),
  ];
  assert(ifd0.length == ifd0Len && exif.length == exifLen && gps.length == gpsLen);
  out
    ..add(endian == Endian.little ? [0x49, 0x49, 42, 0] : [0x4D, 0x4D, 0, 42])
    ..add(u32(ifd0At))
    ..add(ifd0)
    ..add(exif)
    ..add(gps)
    ..add(data.takeBytes());
  return out.takeBytes();
}

/// A JPEG head (SOI, APP0, APP1 Exif, a fake scan, EOI) carrying [tiff].
Uint8List buildExifJpeg(Uint8List tiff) {
  final app1 = [...'Exif'.codeUnits, 0, 0, ...tiff];
  final len = app1.length + 2;
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xE0, 0, 16, ...'JFIF'.codeUnits, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0,
    0xFF, 0xE1, len >> 8, len & 0xFF, ...app1,
    0xFF, 0xDA, 0, 2, 1, 2, 3, 4,
    0xFF, 0xD9,
  ]);
}

/// A minimal HEIC (ftyp, meta with iinf/iloc naming an `Exif` item, mdat) carrying [tiff].
Uint8List buildExifHeic(Uint8List tiff) {
  List<int> box(String type, List<int> body) {
    final size = 8 + body.length;
    return [...(ByteData(4)..setUint32(0, size)).buffer.asUint8List(), ...type.codeUnits, ...body];
  }

  List<int> be16(int v) => [v >> 8 & 0xFF, v & 0xFF];
  List<int> be32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

  final ftyp = box('ftyp', [...'heic'.codeUnits, 0, 0, 0, 0, ...'mif1'.codeUnits, ...'heic'.codeUnits]);
  final infeHvc = box('infe', [2, 0, 0, 0, ...be16(1), ...be16(0), ...'hvc1'.codeUnits, 0]);
  final infeExif = box('infe', [2, 0, 0, 0, ...be16(2), ...be16(0), ...'Exif'.codeUnits, 0]);
  final iinf = box('iinf', [0, 0, 0, 0, ...be16(2), ...infeHvc, ...infeExif]);
  final payload = [...be32(0), ...tiff];
  List<int> metaWith(int exifOffset) {
    final iloc = box('iloc', [
      0, 0, 0, 0, // version 0
      0x44, 0x00, // offset size 4, length size 4, base offset size 0
      ...be16(2),
      ...be16(1), ...be16(0), ...be16(1), ...be32(0), ...be32(0),
      ...be16(2), ...be16(0), ...be16(1), ...be32(exifOffset), ...be32(payload.length),
    ]);
    return box('meta', [0, 0, 0, 0, ...box('hdlr', [0, 0, 0, 0, 0, 0, 0, 0, ...'pict'.codeUnits, ...List.filled(13, 0)]), ...iinf, ...iloc]);
  }

  final metaLen = metaWith(0).length;
  final exifOffset = ftyp.length + metaLen + 8;
  return Uint8List.fromList([...ftyp, ...metaWith(exifOffset), ...box('mdat', payload)]);
}
