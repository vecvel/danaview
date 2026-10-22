// OWNER: HOM-20
//
// Generated photo headers for the photo-facts tests (FIX-S2Q-3; local test media only): a JPEG
// with an APP1 EXIF block (IFD0 Make, Model, Orientation, a GPS pointer that must never be
// followed, and an Exif IFD with DateTimeOriginal and the pixel size) and a SOF0 frame header; a PNG
// with IHDR (and optionally an `eXIf` chunk). Pure Dart (dart:typed_data only), so the root
// viewer tests can import it too. The images carry no decodable pixels; only headers are read.

import 'dart:convert';
import 'dart:typed_data';

/// A TIFF/EXIF block (no `Exif\0\0` prefix).
Uint8List exifTiff({
  String? make,
  String? model,
  int? orientation,
  String? dateTimeOriginal,
  int? pixelWidth,
  int? pixelHeight,
  bool littleEndian = false,
  bool withGps = true,
}) {
  final e = littleEndian ? Endian.little : Endian.big;
  // Layout: header (8) | IFD0 | Exif IFD | GPS IFD | data area.
  final ifd0 = <(int tag, int type, int count, Object value)>[
    if (make != null) (0x010F, 2, utf8.encode(make).length + 1, make),
    if (model != null) (0x0110, 2, utf8.encode(model).length + 1, model),
    if (orientation != null) (0x0112, 3, 1, orientation),
    (0x8769, 4, 1, 'exif'),
    if (withGps) (0x8825, 4, 1, 'gps'),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final exif = <(int, int, int, Object)>[
    if (dateTimeOriginal != null) (0x9003, 2, 20, dateTimeOriginal),
    if (pixelWidth != null) (0xA002, 4, 1, pixelWidth),
    if (pixelHeight != null) (0xA003, 4, 1, pixelHeight),
  ];
  // A GPS IFD with a latitude ref "N" (never read).
  final gps = <(int, int, int, Object)>[(0x0001, 2, 2, 'N')];

  int ifdSize(List<(int, int, int, Object)> l) => 2 + l.length * 12 + 4;
  final ifd0At = 8;
  final exifAt = ifd0At + ifdSize(ifd0);
  final gpsAt = exifAt + ifdSize(exif);
  var dataAt = gpsAt + ifdSize(gps);
  final data = BytesBuilder();
  final out = ByteData(dataAt + 512);
  if (littleEndian) {
    out
      ..setUint8(0, 0x49)
      ..setUint8(1, 0x49);
  } else {
    out
      ..setUint8(0, 0x4D)
      ..setUint8(1, 0x4D);
  }
  out
    ..setUint16(2, 42, e)
    ..setUint32(4, ifd0At, e);

  void writeIfd(int at, List<(int, int, int, Object)> l) {
    out.setUint16(at, l.length, e);
    var p = at + 2;
    for (final (tag, type, count, value) in l) {
      out
        ..setUint16(p, tag, e)
        ..setUint16(p + 2, type, e)
        ..setUint32(p + 4, count, e);
      if (value == 'exif') {
        out.setUint32(p + 8, exifAt, e);
      } else if (value == 'gps') {
        out.setUint32(p + 8, gpsAt, e);
      } else if (value is String) {
        final bytes = [...utf8.encode(value), 0];
        while (bytes.length < count) {
          bytes.add(0);
        }
        if (bytes.length <= 4) {
          for (var i = 0; i < bytes.length; i++) {
            out.setUint8(p + 8 + i, bytes[i]);
          }
        } else {
          out.setUint32(p + 8, dataAt, e);
          data.add(bytes);
          dataAt += bytes.length;
        }
      } else if (type == 3) {
        out.setUint16(p + 8, value as int, e);
      } else {
        out.setUint32(p + 8, value as int, e);
      }
      p += 12;
    }
    out.setUint32(p, 0, e); // no next IFD
  }

  writeIfd(ifd0At, ifd0);
  writeIfd(exifAt, exif);
  writeIfd(gpsAt, gps);
  final head = Uint8List.sublistView(out, 0, gpsAt + ifdSize(gps));
  return Uint8List.fromList([...head, ...data.takeBytes()]);
}

/// A JPEG header: SOI, APP1 EXIF (when [exif] is set), SOF0 with [width] × [height], SOS, EOI.
Uint8List jpegWithExif({required int width, required int height, Uint8List? exif}) {
  final b = BytesBuilder()..add([0xFF, 0xD8]);
  // An APP0 JFIF segment first, as cameras and encoders write.
  b.add([0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]);
  if (exif != null) {
    final len = 2 + 6 + exif.length;
    b
      ..add([0xFF, 0xE1, len >> 8, len & 0xFF])
      ..add(ascii.encode('Exif'))
      ..add([0, 0])
      ..add(exif);
  }
  b.add([0xFF, 0xC0, 0x00, 0x11, 0x08, height >> 8, height & 0xFF, width >> 8, width & 0xFF, 0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
  b.add([0xFF, 0xDA, 0x00, 0x0C, 0x03, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0]);
  b.add(List<int>.filled(64, 0x55));
  b.add([0xFF, 0xD9]);
  return b.takeBytes();
}

/// A PNG header: signature, IHDR [width] × [height], an optional `eXIf` chunk, IDAT, IEND (CRCs are
/// zero: only the header is read).
Uint8List pngOf({required int width, required int height, Uint8List? exif}) {
  final b = BytesBuilder()..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> body) {
    final len = ByteData(4)..setUint32(0, body.length);
    b
      ..add(len.buffer.asUint8List())
      ..add(ascii.encode(type))
      ..add(body)
      ..add([0, 0, 0, 0]);
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  chunk('IHDR', ihdr.buffer.asUint8List());
  if (exif != null) chunk('eXIf', exif);
  chunk('IDAT', List<int>.filled(32, 0));
  chunk('IEND', const []);
  return b.takeBytes();
}
