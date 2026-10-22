// OWNER: HOM-11
//
// A small, read-only EXIF reader for the photo viewer's info sheet (ARCH v1.2 V2-106, §9.4;
// BUILD_PLAN HOM-11). Danaview-folder photos keep only width, height, capture time, camera and
// flags in library.db (`EntryMeta`), so the sheet reads the remaining camera facts (make, lens,
// exposure time, aperture, ISO, focal length) from the library file itself when it opens.
//
// Formats: JPEG (APP1 `Exif`), TIFF-based files (TIFF, DNG, NEF, ARW, CR2, ORF, RW2 and other
// TIFF-structured RAWs), HEIC/HEIF/AVIF (the ISOBMFF `Exif` item through `iinf`/`iloc`) and RAF
// (its embedded JPEG). Anything else, or a malformed file, answers null; the reader never throws.
//
// Rules: the file is opened for reading only (rule 27) and is never written; reads are bounded
// (at most [_maxRead] bytes per read, [_maxEntries] tags per IFD, [_maxReads] reads per file);
// the GPS IFD is never followed and no location is read (§9.4); nothing is logged (rule 30). Reads
// are synchronous and small (a few KB for a typical photo) so the sheet's provider resolves inside
// one frame and in fake-async widget tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// The camera facts read from one photo file; every field is null when the file lacks it.
@immutable
final class PhotoExif {
  /// Facts read from EXIF.
  const PhotoExif({
    this.cameraMake,
    this.cameraModel,
    this.lensModel,
    this.exposureSeconds,
    this.aperture,
    this.iso,
    this.focalLengthMm,
    this.takenAt,
    this.width,
    this.height,
  });

  /// `Make` (0x010F).
  final String? cameraMake;

  /// `Model` (0x0110).
  final String? cameraModel;

  /// `LensModel` (0xA434), else `LensMake` (0xA433).
  final String? lensModel;

  /// `ExposureTime` (0x829A) in seconds.
  final double? exposureSeconds;

  /// `FNumber` (0x829D).
  final double? aperture;

  /// `PhotographicSensitivity` (0x8827).
  final int? iso;

  /// `FocalLength` (0x920A) in millimetres.
  final double? focalLengthMm;

  /// `DateTimeOriginal` (0x9003) as local wall-clock time.
  final DateTime? takenAt;

  /// `PixelXDimension` (0xA002).
  final int? width;

  /// `PixelYDimension` (0xA003).
  final int? height;

  /// Whether nothing was found.
  bool get isEmpty =>
      cameraMake == null &&
      cameraModel == null &&
      lensModel == null &&
      exposureSeconds == null &&
      aperture == null &&
      iso == null &&
      focalLengthMm == null &&
      takenAt == null &&
      width == null &&
      height == null;

  // Never prints values (rule 30).
  @override
  String toString() => 'PhotoExif(${isEmpty ? 'empty' : 'set'})';
}

const int _maxRead = 256 * 1024;
const int _maxEntries = 512;
const int _maxReads = 64;
const int _maxBoxes = 256;

/// Reads the EXIF of the file at [path] (read-only). Null when the file is missing, unreadable,
/// not a supported format or carries no EXIF.
PhotoExif? readPhotoExif(String path) {
  RandomAccessFile? raf;
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    raf = file.openSync(); // FileMode.read
    final src = _Source(raf);
    final exif = _readAny(src, 0);
    return exif == null || exif.isEmpty ? null : exif;
  } on Object {
    return null;
  } finally {
    try {
      raf?.closeSync();
    } on Object {
      // Closing a read-only handle cannot lose data.
    }
  }
}

/// Parses EXIF from in-memory [bytes] of a whole file (tests, already-read heads).
PhotoExif? parsePhotoExif(Uint8List bytes) {
  try {
    final exif = _readAny(_Source.bytes(bytes), 0);
    return exif == null || exif.isEmpty ? null : exif;
  } on Object {
    return null;
  }
}

final class _Source {
  _Source(RandomAccessFile this._raf)
      : _bytes = null,
        length = _raf.lengthSync();

  _Source.bytes(Uint8List this._bytes)
      : _raf = null,
        length = _bytes.length;

  final RandomAccessFile? _raf;
  final Uint8List? _bytes;
  final int length;
  int _reads = 0;

  /// Up to [count] bytes at [offset] (fewer at the end of the file).
  Uint8List read(int offset, int count) {
    if (offset < 0 || count <= 0 || offset >= length) return Uint8List(0);
    if (++_reads > _maxReads) throw const FormatException('too many reads');
    final n = count > _maxRead ? _maxRead : count;
    final end = offset + n > length ? length : offset + n;
    final bytes = _bytes;
    if (bytes != null) return Uint8List.sublistView(bytes, offset, end);
    final raf = _raf!;
    raf.setPositionSync(offset);
    return raf.readSync(end - offset);
  }
}

PhotoExif? _readAny(_Source src, int depth) {
  if (depth > 2) return null;
  final head = src.read(0, 16);
  if (head.length < 8) return null;
  // JPEG.
  if (head[0] == 0xFF && head[1] == 0xD8) return _readJpeg(src, 0);
  // TIFF family (II*\0, MM\0*, ORF IIRO / IIRS, RW2 IIU\0).
  if (_isTiffHeader(head, 0)) return _readTiff(src.read(0, _maxRead), 0);
  // RAF: `FUJIFILMCCD-RAW ` then the embedded JPEG's offset at byte 84.
  if (ascii.decode(head.sublist(0, 15), allowInvalid: true) == 'FUJIFILMCCD-RAW') {
    final dir = src.read(84, 8);
    if (dir.length < 8) return null;
    final bd = ByteData.sublistView(dir);
    final offset = bd.getUint32(0);
    return _readJpeg(src, offset);
  }
  // ISOBMFF (HEIC/HEIF/AVIF).
  if (ascii.decode(head.sublist(4, 8), allowInvalid: true) == 'ftyp') return _readHeif(src);
  return null;
}

bool _isTiffHeader(Uint8List b, int o) {
  if (b.length < o + 4) return false;
  if (b[o] == 0x49 && b[o + 1] == 0x49) {
    final magic = b[o + 2] | (b[o + 3] << 8);
    return magic == 42 || magic == 0x4F52 || magic == 0x5352 || magic == 0x55;
  }
  if (b[o] == 0x4D && b[o + 1] == 0x4D) {
    final magic = (b[o + 2] << 8) | b[o + 3];
    return magic == 42;
  }
  return false;
}

PhotoExif? _readJpeg(_Source src, int start) {
  var pos = start + 2;
  final soi = src.read(start, 2);
  if (soi.length < 2 || soi[0] != 0xFF || soi[1] != 0xD8) return null;
  for (var i = 0; i < 32 && pos + 4 <= src.length; i++) {
    final m = src.read(pos, 4);
    if (m.length < 4 || m[0] != 0xFF) return null;
    final marker = m[1];
    if (marker == 0xD9 || marker == 0xDA) return null; // EOI / start of scan: no EXIF before.
    final segLen = (m[2] << 8) | m[3];
    if (segLen < 2) return null;
    if (marker == 0xE1 && segLen >= 8) {
      final seg = src.read(pos + 4, segLen - 2);
      if (seg.length >= 6 && ascii.decode(seg.sublist(0, 4), allowInvalid: true) == 'Exif' && seg[4] == 0 && seg[5] == 0) {
        return _readTiff(seg, 6);
      }
    }
    pos += 2 + segLen;
  }
  return null;
}

PhotoExif? _readHeif(_Source src) {
  // Top-level boxes: find `meta`.
  var pos = 0;
  Uint8List? meta;
  for (var i = 0; i < _maxBoxes && pos + 8 <= src.length; i++) {
    final h = src.read(pos, 16);
    if (h.length < 8) return null;
    final bd = ByteData.sublistView(h);
    var size = bd.getUint32(0);
    final type = ascii.decode(h.sublist(4, 8), allowInvalid: true);
    var headerLen = 8;
    if (size == 1) {
      if (h.length < 16) return null;
      size = bd.getUint64(8);
      headerLen = 16;
    } else if (size == 0) {
      size = src.length - pos;
    }
    if (size < headerLen) return null;
    if (type == 'meta') {
      meta = src.read(pos + headerLen, size - headerLen);
      break;
    }
    pos += size;
  }
  if (meta == null || meta.length < 4) return null;
  // `meta` is a full box: 4 bytes version/flags, then children.
  int? exifItem;
  final locations = <int, (int offset, int length)>{};
  _forEachBox(meta, 4, meta.length, (type, body) {
    if (type == 'iinf') exifItem = _exifItemId(body);
    if (type == 'iloc') locations.addAll(_itemLocations(body));
  });
  final id = exifItem;
  if (id == null) return null;
  final loc = locations[id];
  if (loc == null) return null;
  final payload = src.read(loc.$1, loc.$2);
  if (payload.length < 8) return null;
  // The Exif item starts with a 4-byte offset to the TIFF header.
  final skip = ByteData.sublistView(payload).getUint32(0);
  final tiffStart = 4 + skip;
  if (tiffStart >= payload.length) return null;
  return _readTiff(payload, tiffStart);
}

void _forEachBox(Uint8List b, int start, int end, void Function(String type, Uint8List body) visit) {
  var pos = start;
  final bd = ByteData.sublistView(b);
  for (var i = 0; i < _maxBoxes && pos + 8 <= end; i++) {
    var size = bd.getUint32(pos);
    final type = ascii.decode(b.sublist(pos + 4, pos + 8), allowInvalid: true);
    var headerLen = 8;
    if (size == 1) {
      if (pos + 16 > end) return;
      size = bd.getUint64(pos + 8);
      headerLen = 16;
    } else if (size == 0) {
      size = end - pos;
    }
    if (size < headerLen || pos + size > end) return;
    visit(type, Uint8List.sublistView(b, pos + headerLen, pos + size));
    pos += size;
  }
}

int? _exifItemId(Uint8List iinf) {
  if (iinf.length < 6) return null;
  final version = iinf[0];
  final countLen = version == 0 ? 2 : 4;
  int? found;
  _forEachBox(iinf, 4 + countLen, iinf.length, (type, body) {
    if (type != 'infe' || found != null || body.length < 4) return;
    final v = body[0];
    if (v < 2) return;
    final ib = ByteData.sublistView(body);
    var p = 4;
    final int itemId;
    if (v == 2) {
      if (body.length < p + 2 + 2 + 4) return;
      itemId = ib.getUint16(p);
      p += 2;
    } else {
      if (body.length < p + 4 + 2 + 4) return;
      itemId = ib.getUint32(p);
      p += 4;
    }
    p += 2; // protection index
    if (ascii.decode(body.sublist(p, p + 4), allowInvalid: true) == 'Exif') found = itemId;
  });
  return found;
}

Map<int, (int, int)> _itemLocations(Uint8List b) {
  final out = <int, (int, int)>{};
  if (b.length < 8) return out;
  final bd = ByteData.sublistView(b);
  final version = b[0];
  var p = 4;
  final offsetSize = b[p] >> 4;
  final lengthSize = b[p] & 0xF;
  final baseOffsetSize = b[p + 1] >> 4;
  final indexSize = version == 1 || version == 2 ? b[p + 1] & 0xF : 0;
  p += 2;
  int readN(int n) {
    if (p + n > b.length) throw const FormatException('iloc');
    final v = switch (n) {
      0 => 0,
      4 => bd.getUint32(p),
      8 => bd.getUint64(p),
      2 => bd.getUint16(p),
      _ => throw const FormatException('iloc size'),
    };
    p += n;
    return v;
  }

  final count = version < 2 ? readN(2) : readN(4);
  for (var i = 0; i < count && i < _maxEntries; i++) {
    final id = version < 2 ? readN(2) : readN(4);
    var method = 0;
    if (version == 1 || version == 2) method = readN(2) & 0xF;
    readN(2); // data reference index
    final base = readN(baseOffsetSize);
    final extents = readN(2);
    int? first;
    var firstLen = 0;
    for (var e = 0; e < extents && e < 64; e++) {
      if (indexSize > 0) readN(indexSize);
      final off = readN(offsetSize);
      final len = readN(lengthSize);
      if (first == null) {
        first = off;
        firstLen = len;
      }
    }
    // Only file-offset items (construction method 0) with one usable extent.
    if (method == 0 && first != null && firstLen > 0) out[id] = (base + first, firstLen);
  }
  return out;
}

PhotoExif? _readTiff(Uint8List b, int t) {
  if (!_isTiffHeader(b, t) || b.length < t + 8) return null;
  final little = b[t] == 0x49;
  final endian = little ? Endian.little : Endian.big;
  final bd = ByteData.sublistView(b);
  int u16(int o) => bd.getUint16(o, endian);
  int u32(int o) => bd.getUint32(o, endian);

  final tags = <int, Object>{};
  void readIfd(int rel, {required bool root}) {
    final o = t + rel;
    if (rel <= 0 || o + 2 > b.length) return;
    final n = u16(o);
    for (var i = 0; i < n && i < _maxEntries; i++) {
      final e = o + 2 + i * 12;
      if (e + 12 > b.length) return;
      final tag = u16(e);
      final type = u16(e + 2);
      final count = u32(e + 4);
      final size = switch (type) {
        1 || 2 || 6 || 7 => 1,
        3 || 8 => 2,
        4 || 9 => 4,
        5 || 10 => 8,
        _ => 0,
      };
      if (size == 0 || count == 0) continue;
      final total = size * count;
      final valueAt = total <= 4 ? e + 8 : t + u32(e + 8);
      if (valueAt < 0 || valueAt + (type == 2 ? 1 : size) > b.length) continue;
      if (root && tag == 0x8769) {
        // Exif sub-IFD pointer.
        tags[tag] = u32(e + 8);
        continue;
      }
      if (tag == 0x8825) continue; // GPS IFD: never followed (§9.4).
      switch (type) {
        case 2:
          final avail = b.length - valueAt;
          final len = count > avail ? avail : (count > 256 ? 256 : count);
          final raw = b.sublist(valueAt, valueAt + len);
          final zero = raw.indexOf(0);
          final text = utf8.decode(zero < 0 ? raw : raw.sublist(0, zero), allowMalformed: true).trim();
          if (text.isNotEmpty) tags[tag] = text;
        case 3:
          tags[tag] = u16(valueAt);
        case 4:
          tags[tag] = u32(valueAt);
        case 5:
          final den = u32(valueAt + 4);
          if (den != 0) tags[tag] = u32(valueAt) / den;
        case 10:
          final den = bd.getInt32(valueAt + 4, endian);
          if (den != 0) tags[tag] = bd.getInt32(valueAt, endian) / den;
        default:
          break;
      }
    }
  }

  readIfd(u32(t + 4), root: true);
  final exifIfd = tags.remove(0x8769);
  if (exifIfd is int) readIfd(exifIfd, root: false);

  String? text(int tag) => tags[tag] is String ? tags[tag]! as String : null;
  double? number(int tag) {
    final v = tags[tag];
    if (v is double && v.isFinite && v > 0) return v;
    if (v is int && v > 0) return v.toDouble();
    return null;
  }

  int? integer(int tag) {
    final v = tags[tag];
    if (v is int && v > 0) return v;
    if (v is double && v.isFinite && v > 0) return v.round();
    return null;
  }

  return PhotoExif(
    cameraMake: text(0x010F),
    cameraModel: text(0x0110),
    lensModel: text(0xA434) ?? text(0xA433),
    exposureSeconds: number(0x829A),
    aperture: number(0x829D),
    iso: integer(0x8827),
    focalLengthMm: number(0x920A),
    takenAt: parseExifDateTime(text(0x9003) ?? text(0x9004) ?? text(0x0132)),
    width: integer(0xA002),
    height: integer(0xA003),
  );
}

/// Parses an EXIF `YYYY:MM:DD HH:MM:SS` stamp as local wall-clock time; null when malformed or
/// blank (`0000:00:00 00:00:00`).
DateTime? parseExifDateTime(String? text) {
  if (text == null) return null;
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})').firstMatch(text.trim());
  if (m == null) return null;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  if (parts[0] == 0 || parts[1] < 1 || parts[1] > 12 || parts[2] < 1 || parts[2] > 31) return null;
  return DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
}
