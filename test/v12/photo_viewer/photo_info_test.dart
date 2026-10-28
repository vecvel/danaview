// OWNER: HOM-11
//
// BUILD_PLAN HOM-11, data half: the info sheet's facts and formatting (EXIF date, camera, lens,
// exposure, dimensions, size, format, source) for Danaview, system and desktop photos; the
// iCloud-only note; the viewer entry's flags, decodability and the PhotoMediaItem Edit receives;
// the toolbar's action sets (Edit hidden with a null callback and on desktop, Share and system
// Delete only with their hooks, Favourite only for Danaview photos).

// The root package reaches danaview_library(_native) through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:danaview_features/src/library/photo_viewer/photo_exif_reader.dart';
import 'package:danaview_features/src/library/photo_viewer/photo_info.dart';
import 'package:danaview_features/src/library/photo_viewer/photo_viewer_actions.dart';
import 'package:danaview_features/src/library/photo_viewer/photo_viewer_entry.dart';
import 'package:danaview_features/src/library/photos/photo_grid_item.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'photo_viewer_fixtures.dart';

String? _value(List<PhotoInfoRow> rows, String id) {
  for (final r in rows) {
    if (r.id == id) return r.value;
  }
  return null;
}

void main() {
  group('formatting', () {
    test('exposure, aperture, focal length, dimensions, dates', () {
      expect(formatExposure(1 / 120), '1/120 s');
      expect(formatExposure(1 / 8000), '1/8000 s');
      expect(formatExposure(0.5), '0.5 s');
      expect(formatExposure(2), '2 s');
      expect(formatExposure(0), '–');
      expect(formatAperture(1.78), 'ƒ/1.8');
      expect(formatAperture(11), 'ƒ/11');
      expect(formatFocalLength(26), '26 mm');
      expect(formatFocalLength(5.73), '5.7 mm');
      expect(formatPhotoDimensions(4032, 3024), '4032 × 3024 · 12.2 MP');
      expect(formatPhotoDateTime(DateTime(2026, 10, 21, 9, 5)), '21 October 2026, 09:05');
      expect(cameraLine('Apple', 'iPhone 15 Pro'), 'Apple iPhone 15 Pro');
      expect(cameraLine('Canon', 'Canon EOS R5'), 'Canon EOS R5');
      expect(cameraLine(null, 'X100V'), 'X100V');
      expect(cameraLine(' ', null), isNull);
      expect(photoFormatLabel(name: 'a.JPG'), 'JPEG');
      expect(photoFormatLabel(name: 'a.heic'), 'HEIC');
      expect(photoFormatLabel(name: 'a.dng'), 'RAW · DNG');
      expect(photoFormatLabel(name: '', mimeType: 'image/heic'), 'HEIC');
      expect(photoFormatLabel(name: '', uti: 'public.heic'), 'HEIC');
      expect(photoFormatLabel(name: 'noext'), isNull);
    });

    test('rows skip unknown facts and keep the display order', () {
      final rows = photoInfoRows(PhotoInfo(
        name: 'IMG_1.HEIC',
        source: PhotoInfoSource.photoLibrary,
        takenAt: DateTime(2026, 10, 20, 9, 30),
        cameraMake: 'Apple',
        cameraModel: 'iPhone 15 Pro',
        lensModel: 'iPhone 15 Pro back triple camera 6.86mm f/1.78',
        exposureSeconds: 1 / 120,
        aperture: 1.78,
        iso: 64,
        focalLengthMm: 6.86,
        width: 4032,
        height: 3024,
        sizeBytes: 2400000,
        formatLabel: 'HEIC',
        colorProfile: 'Display P3',
        bitDepth: 10,
        isHdr: true,
        isLivePhoto: true,
      ));
      expect([for (final r in rows) r.id], ['name', 'taken', 'camera', 'lens', 'exposure', 'dimensions', 'size', 'format', 'colour', 'source']);
      expect(_value(rows, 'exposure'), '1/120 s · ƒ/1.8 · ISO 64 · 6.9 mm');
      expect(_value(rows, 'size'), '2.4 MB');
      expect(_value(rows, 'format'), 'HEIC · HDR · Live Photo · 10-bit');
      expect(_value(rows, 'source'), 'Photo library');
      final bare = photoInfoRows(const PhotoInfo(name: 'x.jpg', source: PhotoInfoSource.picturesFolder));
      expect([for (final r in bare) r.id], ['name', 'source']);
      final raw = photoInfoRows(const PhotoInfo(name: 'x.dng', source: PhotoInfoSource.danaviewFolder, formatLabel: 'RAW · DNG', isRaw: true, folderName: 'Trips'));
      expect(_value(raw, 'format'), 'DNG · RAW');
      expect(_value(raw, 'source'), 'Danaview folder · Trips');
      final cloud = photoInfoRows(const PhotoInfo(name: 'x', source: PhotoInfoSource.photoLibrary, locallyAvailable: false));
      expect(_value(cloud, 'icloud'), contains('iCloud'));
    });

    test('the delete message names projects and saved edits', () {
      expect(photoDeleteMessage(projects: 0, recipes: 0), 'It stays in Recently deleted for 30 days.');
      expect(photoDeleteMessage(projects: 2, recipes: 1), 'Used in 2 projects. Has 1 saved edit. It stays in Recently deleted for 30 days.');
      expect(photoDeleteMessage(projects: 1, recipes: 0), startsWith('Used in 1 project.'));
    });
  });

  group('loadPhotoInfo', () {
    test('a system photo reads PhotoKit EXIF; an unknown asset falls back to the grid facts', () async {
      final system = FakeViewerSystemLibrary(details: {
        'A1': SystemPhotoDetail(
          localIdentifier: 'A1',
          locallyAvailable: true,
          iso: 64,
          aperture: 1.78,
          exposureSeconds: 1 / 120,
          focalLengthMm: 6.86,
          cameraMake: 'Apple',
          cameraModel: 'iPhone 15 Pro',
          lensModel: 'back camera',
          takenAt: DateTime(2026, 10, 20, 9, 30),
          isLivePhoto: true,
          uti: 'public.heic',
          originalFilename: 'IMG_0042.HEIC',
          sizeBytes: 3100000,
          latitude: 51.5,
          longitude: -0.1,
        ),
      });
      final info = await loadPhotoInfo(systemPhoto('A1'), system: system);
      expect(system.detailRequests, ['A1']);
      expect(info.name, 'IMG_0042.HEIC');
      expect(info.source, PhotoInfoSource.photoLibrary);
      expect(info.iso, 64);
      expect(info.lensModel, 'back camera');
      expect(info.sizeBytes, 3100000);
      expect(info.isLivePhoto, isTrue);
      expect(info.formatLabel, 'HEIC');
      final rows = photoInfoRows(info);
      // Location is never shown (ARCH §9.4).
      expect(rows.any((r) => r.value.contains('51.5')), isFalse);
      final fallback = await loadPhotoInfo(systemPhoto('B2'), system: system);
      expect(fallback.name, 'IMG_0001.HEIC');
      expect(fallback.sizeBytes, 2400000);
      expect(fallback.width, 4032);
    });

    testWidgets('a Danaview photo reads library.db: folder, size, import source, flags', (tester) async {
      final lib = await ViewerLib.open(tester);
      await lib.addPhoto(tester, 'live.heic', DateTime(2026, 10, 1, 8), flags: EntryMeta.flagLive | EntryMeta.flagHdr, camera: 'iPhone 16');
      final item = danaviewItems(lib.store).single;
      final info = (await tester.runAsync(() => loadPhotoInfo(item, store: lib.store)))!;
      expect(info.source, PhotoInfoSource.danaviewFolder);
      expect(info.folderName, 'Imported');
      expect(info.sizeBytes, 2048);
      expect(info.importedFrom, SourceHint.photos);
      expect(info.cameraModel, 'iPhone 16');
      expect(info.isLivePhoto, isTrue);
      expect(info.isHdr, isTrue);
      final rows = photoInfoRows(info);
      expect(_value(rows, 'imported'), 'Photos');
      expect(_value(rows, 'size'), '2.05 KB');
      expect(_value(rows, 'taken'), '1 October 2026, 08:00');
      await lib.close(tester);
    });

    test('a desktop photo uses its scanned facts', () async {
      final info = await loadPhotoInfo(desktopPhoto('/Users/me/Pictures/beach.jpg'));
      expect(info.source, PhotoInfoSource.picturesFolder);
      expect(info.cameraModel, 'X100V');
      expect(info.aperture, 2.8);
      expect(info.formatLabel, 'JPEG');
    });
  });

  group('file EXIF (Danaview and desktop photos)', () {
    void expectFixture(PhotoExif? exif) {
      expect(exif, isNotNull);
      expect(exif!.cameraMake, 'FUJIFILM');
      expect(exif.cameraModel, 'X-T5');
      expect(exif.lensModel, 'XF23mmF1.4 R LM WR');
      expect(exif.exposureSeconds, closeTo(1 / 250, 1e-9));
      expect(exif.aperture, closeTo(2.8, 1e-9));
      expect(exif.iso, 400);
      expect(exif.focalLengthMm, 23);
      expect(exif.takenAt, DateTime(2026, 9, 14, 17, 42, 5));
      expect(exif.width, 7728);
      expect(exif.height, 5152);
    }

    test('TIFF in both byte orders, JPEG APP1 and the HEIC Exif item', () {
      expectFixture(parsePhotoExif(buildExifTiff()));
      expectFixture(parsePhotoExif(buildExifTiff(endian: Endian.little)));
      expectFixture(parsePhotoExif(buildExifJpeg(buildExifTiff())));
      expectFixture(parsePhotoExif(buildExifJpeg(buildExifTiff(endian: Endian.little))));
      expectFixture(parsePhotoExif(buildExifHeic(buildExifTiff())));
    });

    test('garbage, truncated and EXIF-less files answer null without throwing', () {
      expect(parsePhotoExif(Uint8List.fromList(List<int>.filled(2048, 7))), isNull);
      expect(parsePhotoExif(Uint8List(0)), isNull);
      final jpeg = buildExifJpeg(buildExifTiff());
      for (final cut in [3, 12, 40, 90, jpeg.length ~/ 2]) {
        expect(() => parsePhotoExif(Uint8List.sublistView(jpeg, 0, cut)), returnsNormally);
      }
      final heic = buildExifHeic(buildExifTiff());
      expect(() => parsePhotoExif(Uint8List.sublistView(heic, 0, heic.length - 40)), returnsNormally);
      expect(parsePhotoExif(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xDA, 0, 2, 0xFF, 0xD9])), isNull);
      expect(readPhotoExif('/nonexistent/hom11/none.jpg'), isNull);
      expect(parseExifDateTime('0000:00:00 00:00:00'), isNull);
      expect(parseExifDateTime('2026:09:14 17:42:05'), DateTime(2026, 9, 14, 17, 42, 5));
    });

    test('reads a real file read-only and leaves its bytes and timestamp unchanged', () {
      final dir = Directory.systemTemp.createTempSync('hom11_exif_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/x.jpg')..writeAsBytesSync(buildExifJpeg(buildExifTiff()));
      final before = file.readAsBytesSync();
      final modified = file.lastModifiedSync();
      expectFixture(readPhotoExif(file.path));
      expect(file.readAsBytesSync(), before);
      expect(file.lastModifiedSync(), modified);
    });

    testWidgets('a Danaview-folder JPEG shows Camera, Lens and Exposure rows from its EXIF', (tester) async {
      final lib = await ViewerLib.open(tester);
      await lib.addPhoto(tester, 'DSCF0001.JPG', DateTime(2026, 9, 14, 17, 42), bytes: buildExifJpeg(buildExifTiff()));
      final item = danaviewItems(lib.store).single;
      final info = (await tester.runAsync(() => loadPhotoInfo(item, store: lib.store)))!;
      expect(info.source, PhotoInfoSource.danaviewFolder);
      expect(info.lensModel, 'XF23mmF1.4 R LM WR');
      final rows = photoInfoRows(info);
      expect(_value(rows, 'camera'), 'FUJIFILM X-T5');
      expect(_value(rows, 'lens'), 'XF23mmF1.4 R LM WR');
      expect(_value(rows, 'exposure'), '1/250 s · ƒ/2.8 · ISO 400 · 23 mm');
      // library.db keeps winning where it knows the value (dimensions, capture time).
      expect(_value(rows, 'dimensions'), '4032 × 3024 · 12.2 MP');
      expect(_value(rows, 'taken'), '14 September 2026, 17:42');
      // No location is read or shown (ARCH §9.4): the fixture's GPS IFD carries latitude 51.
      // Look for a location row or a coordinate, not any "51": the Added/Modified rows show the
      // current time, which can contain 51 (a flaky false failure on CI at hh:51).
      expect(rows.any((r) => r.id.toLowerCase().contains('location') || r.id.toLowerCase().contains('gps') || r.label.toLowerCase().contains('location')), isFalse);
      expect(rows.any((r) => RegExp(r'51(\.\d+)?\s*°|51°|\b51\.\d{3,}').hasMatch(r.value)), isFalse);
      await lib.close(tester);
    });

    testWidgets('a Danaview HEIC reads its Exif item; the stored camera wins over EXIF', (tester) async {
      final lib = await ViewerLib.open(tester);
      await lib.addPhoto(tester, 'IMG_0001.HEIC', DateTime(2026, 9, 14, 17, 42), camera: 'Stored model', bytes: buildExifHeic(buildExifTiff()));
      final item = danaviewItems(lib.store).single;
      final info = (await tester.runAsync(() => loadPhotoInfo(item, store: lib.store)))!;
      expect(info.cameraModel, 'Stored model');
      expect(info.lensModel, 'XF23mmF1.4 R LM WR');
      expect(info.iso, 400);
      await lib.close(tester);
    });

    test('a desktop photo fills lens and exposure from its file; scanned facts win', () {
      final dir = Directory.systemTemp.createTempSync('hom11_exif_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/beach.jpg')..writeAsBytesSync(buildExifJpeg(buildExifTiff()));
      return loadPhotoInfo(desktopPhoto(file.path)).then((info) {
        expect(info.cameraModel, 'X100V');
        expect(info.aperture, 2.8);
        expect(info.iso, 200);
        expect(info.lensModel, 'XF23mmF1.4 R LM WR');
        expect(info.exposureSeconds, closeTo(1 / 250, 1e-9));
        expect(info.focalLengthMm, 23);
      });
    });

    test('system photos never read a file', () async {
      var calls = 0;
      await loadPhotoInfo(systemPhoto('A1'), system: FakeViewerSystemLibrary(), readExif: (_) {
        calls++;
        return null;
      });
      expect(calls, 0);
    });
  });

  group('viewer entry', () {
    testWidgets('Danaview flags come from meta; Edit gets a PhotoMediaItem of the library file', (tester) async {
      final lib = await ViewerLib.open(tester);
      await lib.addPhoto(tester, 'shot.dng', DateTime(2026, 10, 2, 8), camera: 'Leica Q3');
      final item = danaviewItems(lib.store).single;
      final entry = resolvePhotoViewerEntry(item, store: lib.store);
      expect(entry.isRaw, isTrue);
      expect(entry.filePath, item.thumbSource);
      expect(entry.entryId, isNotNull);
      expect(entry.canDecodeFullResolution(TargetPlatform.iOS), isFalse, reason: 'RAW decodes only through the thumbnailer');
      final media = entry.toPhotoMediaItem(store: lib.store);
      expect(media.id, item.id);
      expect(media.uri, item.thumbSource);
      expect(media.isRaw, isTrue);
      expect(media.cameraModel, 'Leica Q3');
      expect(media.takenAt!.isAtSameMomentAs(DateTime(2026, 10, 2, 8)), isTrue);
      expect(media.width, 4032);
      await lib.close(tester);
    });

    test('system photos have no file layer; their PhotoMediaItem passes through', () {
      final item = systemPhoto('A1', live: true);
      final entry = resolvePhotoViewerEntry(item);
      expect(entry.filePath, isNull);
      expect(entry.isLivePhoto, isTrue);
      expect(entry.canDecodeFullResolution(TargetPlatform.iOS), isFalse);
      expect(identical(entry.toPhotoMediaItem(), item.media), isTrue);
      final desktop = resolvePhotoViewerEntry(desktopPhoto('/p/beach.jpg'));
      expect(desktop.canDecodeFullResolution(TargetPlatform.macOS), isTrue);
      expect(dartDecodablePhoto('a.heic', TargetPlatform.windows), isFalse);
      expect(dartDecodablePhoto('a.heic', TargetPlatform.iOS), isTrue);
      expect(dartDecodablePhoto('a.tiff', TargetPlatform.iOS), isFalse);
    });
  });

  group('toolbar actions', () {
    final danaview = PhotoViewerEntry(
      item: PhotoGridItem(
        id: EntryId.parse('fe_${'a' * 22}'),
        origin: PhotoOrigin.danaview,
        name: 'a.jpg',
        date: DateTime(2026),
        modifiedAt: DateTime(2026),
        thumbSource: '/lib/files/a.jpg',
      ),
      isRaw: false,
      isHdr: false,
      isLivePhoto: false,
      mimeType: 'image/jpeg',
      filePath: '/lib/files/a.jpg',
    );
    final system = resolvePhotoViewerEntry(systemPhoto('A1'));
    final desktop = resolvePhotoViewerEntry(desktopPhoto('/p/beach.jpg'));
    final shareHooks = PhotoViewerHooks(share: (_, __) async {}, deleteSystemPhoto: (_, __) async => true);

    test('Edit only with a callback and on an editor platform', () {
      for (final p in TargetPlatform.values) {
        final withEdit = photoViewerActionsFor(entry: danaview, platform: p, hasEditCallback: true, libraryWritable: true);
        final editor = p == TargetPlatform.iOS || p == TargetPlatform.android;
        expect(withEdit.contains(PhotoViewerAction.edit), editor, reason: p.name);
        final without = photoViewerActionsFor(entry: danaview, platform: p, hasEditCallback: false, libraryWritable: true);
        expect(without.contains(PhotoViewerAction.edit), isFalse, reason: p.name);
      }
    });

    test('Danaview photos: Favourite, File info, Delete; Share with its hook; in order', () {
      expect(photoViewerActionsFor(entry: danaview, platform: TargetPlatform.iOS, hasEditCallback: true, libraryWritable: true), [
        PhotoViewerAction.favourite,
        PhotoViewerAction.edit,
        PhotoViewerAction.info,
        PhotoViewerAction.delete,
      ]);
      expect(photoViewerActionsFor(entry: danaview, platform: TargetPlatform.iOS, hasEditCallback: true, libraryWritable: true, hooks: shareHooks), [
        PhotoViewerAction.share,
        PhotoViewerAction.favourite,
        PhotoViewerAction.edit,
        PhotoViewerAction.info,
        PhotoViewerAction.delete,
      ]);
      // A read-only (newer) library: no writes.
      expect(photoViewerActionsFor(entry: danaview, platform: TargetPlatform.iOS, hasEditCallback: false, libraryWritable: false), [PhotoViewerAction.info]);
    });

    test('system and desktop photos: no Danaview star; system Delete only through its hook', () {
      expect(photoViewerActionsFor(entry: system, platform: TargetPlatform.iOS, hasEditCallback: false, libraryWritable: true), [PhotoViewerAction.info]);
      expect(photoViewerActionsFor(entry: system, platform: TargetPlatform.iOS, hasEditCallback: true, libraryWritable: true, hooks: shareHooks),
          [PhotoViewerAction.share, PhotoViewerAction.edit, PhotoViewerAction.info, PhotoViewerAction.delete]);
      expect(photoViewerActionsFor(entry: desktop, platform: TargetPlatform.macOS, hasEditCallback: true, libraryWritable: true, hooks: shareHooks),
          [PhotoViewerAction.share, PhotoViewerAction.info]);
    });
  });
}
