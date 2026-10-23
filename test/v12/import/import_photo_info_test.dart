// OWNER: HOM-20
//
// FIX-S2Q-3 end to end on the Dart side: a JPEG with EXIF and a PNG imported through the real
// ImportService get their facts in `entry_meta`, and the viewer's File info (HOM-11's
// `loadPhotoInfo` + `photoInfoRows`) shows Taken, Camera and Dimensions for them from library.db
// alone (the file's own EXIF read is stubbed out to prove it), and the Photos grid item carries the
// pixel size and the date taken.
//
// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:danaview_features/src/library/photo_viewer/photo_info.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/danaview_library/test/import/photo_fixtures.dart';
import '../photo_viewer/photo_viewer_fixtures.dart';

String? _value(List<PhotoInfoRow> rows, String id) => rows.where((r) => r.id == id).firstOrNull?.value;

void main() {
  testWidgets('imported JPEG with EXIF and PNG: File info shows camera, date taken and dimensions', (tester) async {
    final lib = await ViewerLib.open(tester);
    final src = Directory.systemTemp.createTempSync('hom20_info_src_');
    addTearDown(() => src.deleteSync(recursive: true));
    final jpeg = File('${src.path}/IMG_0001.JPG')
      ..writeAsBytesSync(jpegWithExif(
        width: 4032,
        height: 3024,
        exif: exifTiff(make: 'Apple', model: 'iPhone 15 Pro', orientation: 6, dateTimeOriginal: '2024:05:17 14:03:09'),
      ));
    final png = File('${src.path}/Screenshot.png')..writeAsBytesSync(pngOf(width: 1170, height: 2532));

    final items = (await tester.runAsync(() => ImportService(store: lib.store).importAll([
          ImportSource.file(jpeg.path, uti: 'public.jpeg'),
          ImportSource.file(png.path, mime: 'image/png'),
        ])))!;
    expect(items.map((i) => i.state), everyElement(ImportItemState.done));

    final grid = danaviewItems(lib.store);
    final jpegItem = grid.firstWhere((i) => i.id == items[0].entry!.id);
    final pngItem = grid.firstWhere((i) => i.id == items[1].entry!.id);
    expect((jpegItem.width, jpegItem.height), (3024, 4032), reason: 'the grid knows the displayed size');
    expect(jpegItem.date.toLocal(), DateTime(2024, 5, 17, 14, 3, 9), reason: 'the grid groups by date taken');

    // From library.db alone: the file's EXIF is not read.
    final info = (await tester.runAsync(() => loadPhotoInfo(jpegItem, store: lib.store, readExif: (_) => null)))!;
    final rows = photoInfoRows(info);
    expect(_value(rows, 'camera'), 'Apple iPhone 15 Pro');
    expect(_value(rows, 'taken'), '17 May 2024, 14:03');
    expect(_value(rows, 'dimensions'), '3024 × 4032 · 12.2 MP');

    // With the real reader too (the viewer's default), the rows agree.
    final full = photoInfoRows((await tester.runAsync(() => loadPhotoInfo(jpegItem, store: lib.store)))!);
    expect(_value(full, 'camera'), 'Apple iPhone 15 Pro');
    expect(_value(full, 'dimensions'), '3024 × 4032 · 12.2 MP');

    final pngRows = photoInfoRows((await tester.runAsync(() => loadPhotoInfo(pngItem, store: lib.store, readExif: (_) => null)))!);
    expect(_value(pngRows, 'dimensions'), '1170 × 2532 · 3.0 MP');
    expect(_value(pngRows, 'camera'), isNull);
    expect(_value(pngRows, 'taken'), isNull);

    await lib.close(tester);
  });
}
