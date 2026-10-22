// OWNER: HOM-20
//
// FIX-S2Q-3: imported photos get their photo facts. The header reader (JPEG EXIF + SOF, PNG IHDR
// and `eXIf`, TIFF, WebP, GIF, BMP; orientation; malformed input) and the import pipeline writing
// `entry_meta` in the commit's transaction for a generated JPEG with EXIF and a PNG; videos and
// documents get no photo facts; the source is untouched.

import 'dart:convert';
import 'dart:typed_data';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

import 'import_harness.dart';
import 'photo_fixtures.dart';

void main() {
  group('readPhotoFacts', () {
    test('JPEG: SOF size, EXIF date, make, model, orientation (big-endian)', () {
      final jpeg = jpegWithExif(
        width: 4032,
        height: 3024,
        exif: exifTiff(make: 'Apple', model: 'iPhone 15 Pro', orientation: 1, dateTimeOriginal: '2024:05:17 14:03:09', pixelWidth: 4032, pixelHeight: 3024),
      );
      final f = parsePhotoFacts(jpeg)!;
      expect(f.width, 4032);
      expect(f.height, 3024);
      expect(f.takenAt, DateTime(2024, 5, 17, 14, 3, 9));
      expect(f.cameraMake, 'Apple');
      expect(f.cameraModel, 'iPhone 15 Pro');
      expect(f.camera, 'Apple iPhone 15 Pro');
      expect(f.orientation, 1);
      expect(f.toString(), isNot(contains('Apple')), reason: 'rule 30: no values in toString');
    });

    test('JPEG little-endian, orientation 6 swaps to the displayed size; model already names the make', () {
      final jpeg = jpegWithExif(
        width: 6000,
        height: 4000,
        exif: exifTiff(make: 'NIKON CORPORATION', model: 'NIKON CORPORATION D850', orientation: 6, dateTimeOriginal: '2023:12:31 23:59:58', littleEndian: true),
      );
      final f = parsePhotoFacts(jpeg)!;
      expect((f.width, f.height), (4000, 6000));
      expect(f.orientation, 6);
      expect(f.camera, 'NIKON CORPORATION D850');
      expect(f.takenAt, DateTime(2023, 12, 31, 23, 59, 58));
    });

    test('JPEG without EXIF: size only; blank date ignored', () {
      expect(parsePhotoFacts(jpegWithExif(width: 640, height: 480)), const PhotoFacts(width: 640, height: 480));
      final blank = parsePhotoFacts(jpegWithExif(width: 10, height: 20, exif: exifTiff(dateTimeOriginal: '0000:00:00 00:00:00')))!;
      expect(blank.takenAt, isNull);
      expect((blank.width, blank.height), (10, 20));
    });

    test('PNG: IHDR size, eXIf chunk facts', () {
      expect(parsePhotoFacts(pngOf(width: 1170, height: 2532)), const PhotoFacts(width: 1170, height: 2532));
      final f = parsePhotoFacts(pngOf(width: 800, height: 600, exif: exifTiff(model: 'Pixel 8', dateTimeOriginal: '2025:01:02 03:04:05', orientation: 8)))!;
      expect((f.width, f.height), (600, 800));
      expect(f.camera, 'Pixel 8');
      expect(f.takenAt, DateTime(2025, 1, 2, 3, 4, 5));
    });

    test('TIFF: EXIF pixel size and facts', () {
      final f = parsePhotoFacts(exifTiff(make: 'Canon', model: 'Canon EOS R5', pixelWidth: 8192, pixelHeight: 5464, dateTimeOriginal: '2022:07:08 09:10:11'))!;
      expect((f.width, f.height), (8192, 5464));
      expect(f.camera, 'Canon EOS R5');
    });

    test('GIF, BMP and WebP sizes', () {
      final gif = Uint8List.fromList([...ascii.encode('GIF89a'), 0x40, 0x01, 0xF0, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(parsePhotoFacts(gif), const PhotoFacts(width: 320, height: 240));

      final bmp = ByteData(54)
        ..setUint8(0, 0x42)
        ..setUint8(1, 0x4D)
        ..setUint32(14, 40, Endian.little)
        ..setInt32(18, 1024, Endian.little)
        ..setInt32(22, -768, Endian.little);
      expect(parsePhotoFacts(bmp.buffer.asUint8List()), const PhotoFacts(width: 1024, height: 768));

      final webp = Uint8List(40);
      webp.setAll(0, ascii.encode('RIFF'));
      webp.setAll(8, ascii.encode('WEBPVP8X'));
      // canvas width-1 = 1919, height-1 = 1079 (24-bit little endian at chunk offset 12).
      webp.setAll(24, [0x7F, 0x07, 0x00, 0x37, 0x04, 0x00]);
      expect(parsePhotoFacts(webp), const PhotoFacts(width: 1920, height: 1080));
    });

    test('malformed, truncated, empty and missing inputs answer null without throwing', () {
      expect(parsePhotoFacts(Uint8List(0)), isNull);
      expect(parsePhotoFacts(Uint8List.fromList([0xFF, 0xD8, 0xFF])), isNull);
      expect(parsePhotoFacts(Uint8List.fromList(utf8.encode('not a photo at all, just text'))), isNull);
      final jpeg = jpegWithExif(width: 100, height: 100, exif: exifTiff(model: 'X', dateTimeOriginal: '2020:01:01 00:00:00'));
      for (var cut = 0; cut < jpeg.length; cut += 7) {
        expect(() => parsePhotoFacts(Uint8List.sublistView(jpeg, 0, cut)), returnsNormally);
      }
      expect(readPhotoFacts('/nonexistent/hom20/none.jpg'), isNull);
    });

    test('photoEntryMeta marks RAW by extension', () {
      final dir = tempDir('hom20_facts_');
      final f = sourceFile(dir, 'a.dng', exifTiff(model: 'M', pixelWidth: 100, pixelHeight: 50));
      final meta = photoEntryMeta(f.path, fileName: 'a.dng')!;
      expect(meta.flags & EntryMeta.flagRaw, EntryMeta.flagRaw);
      expect((meta.width, meta.height, meta.camera), (100, 50, 'M'));
      final junk = sourceFile(dir, 'b.png', utf8.encode('junk'));
      expect(photoEntryMeta(junk.path, fileName: 'b.png'), isNull);
    });
  });

  group('import writes entry_meta', () {
    test('a JPEG with EXIF and a PNG get their facts in the import commit; a video and a PDF get none', () async {
      final src = tempDir('hom20_meta_src_');
      final store = await openStore(tempDir('hom20_meta_lib_').path);
      addTearDown(store.close);
      final jpegBytes = jpegWithExif(
        width: 4032,
        height: 3024,
        exif: exifTiff(make: 'Apple', model: 'iPhone 15 Pro', orientation: 6, dateTimeOriginal: '2024:05:17 14:03:09'),
      );
      final jpeg = sourceFile(src, 'IMG_0001.JPG', jpegBytes);
      final png = sourceFile(src, 'Screenshot.png', pngOf(width: 1170, height: 2532));
      final mov = sourceFile(src, 'Clip.mov', bytesOf(4096));
      final pdf = sourceFile(src, 'Doc.pdf', bytesOf(2048, seed: 3));
      final before = jpeg.statSync();

      final service = ImportService(store: store);
      // In the hook (right after the commit) the facts are already there: one transaction.
      final metaInHook = <EntryMeta?>[];
      service.addHook((e) => metaInHook.add(store.reader.meta(e.id)));
      final items = await service.importAll([
        ImportSource.file(jpeg.path, uti: 'public.jpeg'),
        ImportSource.file(png.path, mime: 'image/png'),
        ImportSource.file(mov.path, uti: 'com.apple.quicktime-movie'),
        ImportSource.file(pdf.path, mime: 'application/pdf'),
      ]);
      expect(items.map((i) => i.state), everyElement(ImportItemState.done));

      final jm = store.reader.meta(items[0].entry!.id)!;
      expect((jm.width, jm.height), (3024, 4032), reason: 'orientation 6: displayed portrait');
      expect(jm.takenAt!.toLocal(), DateTime(2024, 5, 17, 14, 3, 9), reason: 'stored as an instant (UTC ms), the EXIF wall clock in local time');
      expect(jm.camera, 'Apple iPhone 15 Pro');
      expect(jm.flags, 0);

      final pm = store.reader.meta(items[1].entry!.id)!;
      expect((pm.width, pm.height), (1170, 2532));
      expect(pm.takenAt, isNull);
      expect(pm.camera, isNull);

      expect(store.reader.meta(items[2].entry!.id), isNull, reason: 'no photo facts for a video');
      expect(store.reader.meta(items[3].entry!.id), isNull, reason: 'no photo facts for a document');
      expect(metaInHook[0], jm);
      expect(metaInHook[1], pm);

      // The source is untouched.
      expect(jpeg.readAsBytesSync(), jpegBytes);
      expect(jpeg.statSync().modified, before.modified);
    });

    test('a photo whose header cannot be read imports with no facts', () async {
      final src = tempDir('hom20_meta_bad_src_');
      final store = await openStore(tempDir('hom20_meta_bad_lib_').path);
      addTearDown(store.close);
      final bad = sourceFile(src, 'broken.jpg', bytesOf(1024, seed: 9));
      final item = (await ImportService(store: store).importAll([ImportSource.file(bad.path, uti: 'public.jpeg')])).single;
      expect(item.state, ImportItemState.done);
      expect(item.entry!.kind, FileKind.photo);
      expect(store.reader.meta(item.entry!.id), isNull);
    });

    test('the facts are written with the writer on its own isolate', () async {
      final src = tempDir('hom20_meta_iso_src_');
      final store = await openStore(tempDir('hom20_meta_iso_lib_').path, background: true);
      addTearDown(store.close);
      final jpeg = sourceFile(src, 'p.jpg', jpegWithExif(width: 300, height: 200, exif: exifTiff(model: 'Cam', dateTimeOriginal: '2021:02:03 04:05:06')));
      final item = (await ImportService(store: store).importAll([ImportSource.file(jpeg.path, uti: 'public.jpeg')])).single;
      final m = store.reader.meta(item.entry!.id)!;
      expect((m.width, m.height, m.camera, m.takenAt!.toLocal()), (300, 200, 'Cam', DateTime(2021, 2, 3, 4, 5, 6)));
    });
  });
}
