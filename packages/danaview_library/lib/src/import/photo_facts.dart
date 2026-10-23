// OWNER: HOM-20
//
// The photo facts the import pipeline records in `entry_meta` (ARCH v1.2 §5.3, §5.6, V2-106;
// FIX-S2Q-3): pixel size, capture time, camera, orientation and the RAW flag, read from the
// imported copy's header with a small pure-Dart reader so the Photos grid can group by date taken
// and the viewer's File info shows Taken, Camera and Dimensions without opening the file.
//
// Formats: JPEG (SOF size, APP1 `Exif`), PNG (IHDR, `eXIf`), TIFF and TIFF-structured RAWs (DNG,
// NEF, ARW, CR2, ORF, RW2), RAF (its embedded JPEG), HEIC/HEIF/AVIF (`ispe`, `irot`, the `Exif`
// item), WebP, GIF and BMP. Anything else, or a malformed file, answers null; the reader never
// throws.
//
// Rules: the file is opened for reading only and never written; reads are bounded (at most
// [_maxRead] bytes per read, [_maxReads] reads, [_maxEntries] tags per IFD); the GPS IFD is never
// followed and no location is read (§9.4); nothing is logged and [PhotoFacts.toString] prints no
// value (rule 30). The size reported is the displayed one: an EXIF orientation of 5–8 (or an
// `irot` of 90°/270°) swaps width and height.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../db/library_folder.dart' show EntryMeta;

/// The facts read from one photo file's header; every field is null when the file lacks it.
@immutable
final class PhotoFacts {
  /// Facts.
  const PhotoFacts({
    this.width,
    this.height,
    this.takenAt,
    this.cameraMake,
    this.cameraModel,
    this.orientation,
  });

  /// Displayed pixel width (after [orientation]).
  final int? width;

  /// Displayed pixel height (after [orientation]).
  final int? height;

  /// `DateTimeOriginal` (else `DateTimeDigitized`, else `DateTime`) as local wall-clock time.
  final DateTime? takenAt;

  /// `Make` (0x010F).
  final String? cameraMake;

  /// `Model` (0x0110).
  final String? cameraModel;

  /// EXIF `Orientation` 1…8 (0x0112), when set.
  final int? orientation;

  /// The camera line kept in `entry_meta.camera`: make and model without the make repeated
  /// (`Apple iPhone 15 Pro`), or null.
  String? get camera {
    final m = cameraModel?.trim();
    final k = cameraMake?.trim();
    if ((m == null || m.isEmpty) && (k == null || k.isEmpty)) return null;
    if (m == null || m.isEmpty) return k;
    if (k == null || k.isEmpty) return m;
    return m.toLowerCase().startsWith(k.toLowerCase()) ? m : '$k $m';
  }

  /// True when nothing was found.
  bool get isEmpty => width == null && height == null && takenAt == null && cameraMake == null && cameraModel == null && orientation == null;

  /// The `entry_meta` row these facts make ([flags] adds RAW/HDR/Live bits).
  EntryMeta toEntryMeta({int flags = 0}) => EntryMeta(width: width, height: height, takenAt: takenAt, camera: camera, flags: flags);

  @override
  bool operator ==(Object other) =>
      other is PhotoFacts &&
      other.width == width &&
      other.height == height &&
      other.takenAt == takenAt &&
      other.cameraMake == cameraMake &&
      other.cameraModel == cameraModel &&
      other.orientation == orientation;

  @override
  int get hashCode => Object.hash(width, height, takenAt, cameraMake, cameraModel, orientation);

  // Never prints values (rule 30).
  @override
  String toString() => 'PhotoFacts(${isEmpty ? 'empty' : 'set'})';
}

// File extensions of camera RAW formats (`EntryMeta.flagRaw`).
const Set<String> _rawExtensions = {'dng', 'cr2', 'cr3', 'nef', 'arw', 'raf', 'orf', 'rw2'};

/// The `entry_meta` row for a photo named [fileName] whose bytes are at [path] (read-only), or
/// null when nothing is known. Never throws.
EntryMeta? photoEntryMeta(String path, {required String fileName}) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  final flags = _rawExtensions.contains(ext) ? EntryMeta.flagRaw : 0;
  final facts = readPhotoFacts(path);
  if (facts == null) return flags == 0 ? null : EntryMeta(flags: flags);
  final meta = facts.toEntryMeta(flags: flags);
  return meta.isEmpty ? null : meta;
}

/// Reads the facts of the file at [path] (read-only). Null when the file is missing, unreadable,
/// not a supported format or carries nothing.
PhotoFacts? readPhotoFacts(String path) {
  RandomAccessFile? raf;
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    raf = file.openSync(); // FileMode.read
    return _finish(_readAny(_Source(raf), 0));
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

/// Parses the facts of a whole file held in [bytes] (tests, already-read heads).
PhotoFacts? parsePhotoFacts(Uint8List bytes) {
  try {
    return _finish(_readAny(_Source.bytes(bytes), 0));
  } on Object {
    return null;
  }
}

/// Parses an EXIF `YYYY:MM:DD HH:MM:SS` stamp as local wall-clock time; null when malformed or
/// blank (`0000:00:00 00:00:00`).
DateTime? parseExifStamp(String? text) {
  if (text == null) return null;
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})').firstMatch(text.trim());
  if (m == null) return null;
  final p = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  if (p[0] == 0 || p[1] < 1 || p[1] > 12 || p[2] < 1 || p[2] > 31 || p[3] > 23 || p[4] > 59 || p[5] > 60) return null;
  return DateTime(p[0], p[1], p[2], p[3], p[4], p[5] > 59 ? 59 : p[5]);
}

// ---- internals --------------------------------------------------------------------------------

const int _maxRead = 256 * 1024;
const int _maxEntries = 512;
const int _maxReads = 96;
const int _maxBoxes = 256;
const int _maxDimension = 1 << 20;

/// What a format reader found before the orientation is applied.
final class _Raw {
  int? width;
  int? height;
  int? exifWidth;
  int? exifHeight;
  DateTime? takenAt;
  String? make;
  String? model;
  int? orientation;

  /// Rotation from the container (`irot`), in quarter turns; wins over [orientation] for the size.
  int? quarterTurns;

  void mergeExif(_Raw? e) {
    if (e == null) return;
    takenAt ??= e.takenAt;
    make ??= e.make;
    model ??= e.model;
    orientation ??= e.orientation;
    exifWidth ??= e.exifWidth;
    exifHeight ??= e.exifHeight;
    // A TIFF's own IFD0 size (no container size) stands in for the pixel size.
    width ??= e.width;
    height ??= e.height;
  }
}

PhotoFacts? _finish(_Raw? r) {
  if (r == null) return null;
  var w = _dim(r.width) ?? _dim(r.exifWidth);
  var h = _dim(r.height) ?? _dim(r.exifHeight);
  if (w == null || h == null) {
    w = null;
    h = null;
  }
  final o = r.orientation != null && r.orientation! >= 1 && r.orientation! <= 8 ? r.orientation : null;
  final swap = r.quarterTurns != null ? r.quarterTurns!.isOdd : (o != null && o >= 5);
  final facts = PhotoFacts(
    width: swap ? h : w,
    height: swap ? w : h,
    takenAt: r.takenAt,
    cameraMake: r.make,
    cameraModel: r.model,
    orientation: o,
  );
  return facts.isEmpty ? null : facts;
}

int? _dim(int? v) => v != null && v > 0 && v <= _maxDimension ? v : null;

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

String _ascii(Uint8List b, int start, int end) => end > b.length ? '' : ascii.decode(b.sublist(start, end), allowInvalid: true);

_Raw? _readAny(_Source src, int depth) {
  if (depth > 2) return null;
  final head = src.read(0, 32);
  if (head.length < 8) return null;
  if (head[0] == 0xFF && head[1] == 0xD8) return _readJpeg(src, 0);
  if (head[0] == 0x89 && _ascii(head, 1, 4) == 'PNG') return _readPng(src);
  if (_isTiffHeader(head, 0)) return _readTiff(src.read(0, _maxRead), 0, plainTiff: true);
  if (_ascii(head, 0, 15) == 'FUJIFILMCCD-RAW') {
    final dir = src.read(84, 8);
    if (dir.length < 8) return null;
    return _readJpeg(src, ByteData.sublistView(dir).getUint32(0));
  }
  if (_ascii(head, 4, 8) == 'ftyp') return _readHeif(src);
  if (_ascii(head, 0, 4) == 'RIFF' && _ascii(head, 8, 12) == 'WEBP') return _readWebp(src);
  if (_ascii(head, 0, 4) == 'GIF8') {
    final bd = ByteData.sublistView(head);
    return _Raw()
      ..width = bd.getUint16(6, Endian.little)
      ..height = bd.getUint16(8, Endian.little);
  }
  if (head[0] == 0x42 && head[1] == 0x4D && head.length >= 26) {
    final bd = ByteData.sublistView(head);
    if (bd.getUint32(14, Endian.little) < 40) return null;
    return _Raw()
      ..width = bd.getInt32(18, Endian.little).abs()
      ..height = bd.getInt32(22, Endian.little).abs();
  }
  return null;
}

bool _isTiffHeader(Uint8List b, int o) {
  if (b.length < o + 4) return false;
  if (b[o] == 0x49 && b[o + 1] == 0x49) {
    final magic = b[o + 2] | (b[o + 3] << 8);
    return magic == 42 || magic == 0x4F52 || magic == 0x5352 || magic == 0x55;
  }
  if (b[o] == 0x4D && b[o + 1] == 0x4D) return ((b[o + 2] << 8) | b[o + 3]) == 42;
  return false;
}

_Raw? _readJpeg(_Source src, int start) {
  final soi = src.read(start, 2);
  if (soi.length < 2 || soi[0] != 0xFF || soi[1] != 0xD8) return null;
  final out = _Raw();
  _Raw? exif;
  var pos = start + 2;
  for (var i = 0; i < 64 && pos + 4 <= src.length; i++) {
    final m = src.read(pos, 10);
    if (m.length < 4 || m[0] != 0xFF) break;
    final marker = m[1];
    if (marker == 0xFF) {
      pos += 1; // fill byte
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) break; // EOI / start of scan
    final segLen = (m[2] << 8) | m[3];
    if (segLen < 2) break;
    if (marker == 0xE1 && segLen >= 8 && exif == null) {
      final seg = src.read(pos + 4, segLen - 2);
      if (seg.length >= 6 && _ascii(seg, 0, 4) == 'Exif' && seg[4] == 0 && seg[5] == 0) exif = _readTiff(seg, 6);
    }
    // SOF0…SOF15 except DHT (C4), JPG (C8) and DAC (CC): precision, height, width.
    if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC && m.length >= 9) {
      out.height = (m[5] << 8) | m[6];
      out.width = (m[7] << 8) | m[8];
      break; // the frame header comes after the APP segments
    }
    pos += 2 + segLen;
  }
  out.mergeExif(exif);
  return out;
}

_Raw? _readPng(_Source src) {
  final ihdr = src.read(8, 25);
  if (ihdr.length < 16 || _ascii(ihdr, 4, 8) != 'IHDR') return null;
  final bd = ByteData.sublistView(ihdr);
  final out = _Raw()
    ..width = bd.getUint32(8)
    ..height = bd.getUint32(12);
  // Look for an `eXIf` chunk before the image data.
  var pos = 8;
  for (var i = 0; i < 64 && pos + 8 <= src.length; i++) {
    final h = src.read(pos, 8);
    if (h.length < 8) break;
    final len = ByteData.sublistView(h).getUint32(0);
    final type = _ascii(h, 4, 8);
    if (type == 'IDAT' || type == 'IEND') break;
    if (type == 'eXIf' && len >= 8) {
      final body = src.read(pos + 8, len);
      final exif = _readTiff(body, 0);
      out.mergeExif(exif?..width = null..height = null);
      break;
    }
    pos += 12 + len;
  }
  return out;
}

_Raw? _readWebp(_Source src) {
  final h = src.read(12, 30);
  if (h.length < 18) return null;
  final type = _ascii(h, 0, 4);
  final bd = ByteData.sublistView(h);
  switch (type) {
    case 'VP8X':
      if (h.length < 18) return null;
      return _Raw()
        ..width = 1 + (h[12] | (h[13] << 8) | (h[14] << 16))
        ..height = 1 + (h[15] | (h[16] << 8) | (h[17] << 16));
    case 'VP8 ':
      if (h.length < 18 || h[11] != 0x9D || h[12] != 0x01 || h[13] != 0x2A) return null;
      return _Raw()
        ..width = bd.getUint16(14, Endian.little) & 0x3FFF
        ..height = bd.getUint16(16, Endian.little) & 0x3FFF;
    case 'VP8L':
      if (h.length < 13 || h[8] != 0x2F) return null;
      final bits = bd.getUint32(9, Endian.little);
      return _Raw()
        ..width = (bits & 0x3FFF) + 1
        ..height = ((bits >> 14) & 0x3FFF) + 1;
  }
  return null;
}

_Raw? _readHeif(_Source src) {
  var pos = 0;
  Uint8List? meta;
  for (var i = 0; i < _maxBoxes && pos + 8 <= src.length; i++) {
    final h = src.read(pos, 16);
    if (h.length < 8) return null;
    final bd = ByteData.sublistView(h);
    var size = bd.getUint32(0);
    final type = _ascii(h, 4, 8);
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
  final out = _Raw();
  int? exifItem;
  final locations = <int, (int, int)>{};
  _forEachBox(meta, 4, meta.length, (type, body) {
    if (type == 'iinf') exifItem = _exifItemId(body);
    if (type == 'iloc') locations.addAll(_itemLocations(body));
    if (type == 'iprp') {
      _forEachBox(body, 0, body.length, (t, ipco) {
        if (t != 'ipco') return;
        _forEachBox(ipco, 0, ipco.length, (p, prop) {
          if (p == 'ispe' && prop.length >= 12) {
            // The largest extent: the primary image (or its grid), not a tile or a thumbnail.
            final pb = ByteData.sublistView(prop);
            final w = pb.getUint32(4);
            final hh = pb.getUint32(8);
            if (w * hh > (out.width ?? 0) * (out.height ?? 0)) {
              out.width = w;
              out.height = hh;
            }
          }
          if (p == 'irot' && prop.isNotEmpty) out.quarterTurns ??= prop[0] & 0x3;
        });
      });
    }
  });
  final id = exifItem;
  final loc = id == null ? null : locations[id];
  if (loc != null) {
    final payload = src.read(loc.$1, loc.$2);
    if (payload.length >= 8) {
      final tiffStart = 4 + ByteData.sublistView(payload).getUint32(0);
      if (tiffStart < payload.length) out.mergeExif(_readTiff(payload, tiffStart)?..width = null..height = null);
    }
  }
  return out;
}

void _forEachBox(Uint8List b, int start, int end, void Function(String type, Uint8List body) visit) {
  var pos = start;
  final bd = ByteData.sublistView(b);
  for (var i = 0; i < _maxBoxes && pos + 8 <= end; i++) {
    var size = bd.getUint32(pos);
    final type = _ascii(b, pos + 4, pos + 8);
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
  final countLen = iinf[0] == 0 ? 2 : 4;
  int? found;
  _forEachBox(iinf, 4 + countLen, iinf.length, (type, body) {
    if (type != 'infe' || found != null || body.length < 4) return;
    final v = body[0];
    if (v < 2) return;
    final ib = ByteData.sublistView(body);
    var p = 4;
    final int itemId;
    if (v == 2) {
      if (body.length < p + 8) return;
      itemId = ib.getUint16(p);
      p += 2;
    } else {
      if (body.length < p + 10) return;
      itemId = ib.getUint32(p);
      p += 4;
    }
    p += 2; // protection index
    if (_ascii(body, p, p + 4) == 'Exif') found = itemId;
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
      2 => bd.getUint16(p),
      4 => bd.getUint32(p),
      8 => bd.getUint64(p),
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
    if (method == 0 && first != null && firstLen > 0) out[id] = (base + first, firstLen);
  }
  return out;
}

/// The EXIF of the TIFF structure at [t] in [b]. With [plainTiff] the IFD0 `ImageWidth` /
/// `ImageLength` are the file's pixel size (a TIFF or a RAW without a container size).
_Raw? _readTiff(Uint8List b, int t, {bool plainTiff = false}) {
  if (!_isTiffHeader(b, t) || b.length < t + 8) return null;
  final endian = b[t] == 0x49 ? Endian.little : Endian.big;
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
      final valueAt = size * count <= 4 ? e + 8 : t + u32(e + 8);
      if (valueAt < 0 || valueAt + (type == 2 ? 1 : size) > b.length) continue;
      if (root && tag == 0x8769) {
        tags[tag] = u32(e + 8); // Exif sub-IFD pointer
        continue;
      }
      if (tag == 0x8825) continue; // GPS IFD: never followed (§9.4).
      if (!root && tags.containsKey(tag)) continue; // IFD0 wins for shared tags
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
        default:
          break;
      }
    }
  }

  readIfd(u32(t + 4), root: true);
  final exifIfd = tags.remove(0x8769);
  if (exifIfd is int) readIfd(exifIfd, root: false);

  String? text(int tag) => tags[tag] is String ? tags[tag]! as String : null;
  int? integer(int tag) => tags[tag] is int && (tags[tag]! as int) > 0 ? tags[tag]! as int : null;

  final out = _Raw()
    ..make = text(0x010F)
    ..model = text(0x0110)
    ..orientation = integer(0x0112)
    ..takenAt = parseExifStamp(text(0x9003)) ?? parseExifStamp(text(0x9004)) ?? parseExifStamp(text(0x0132))
    ..exifWidth = integer(0xA002)
    ..exifHeight = integer(0xA003);
  if (plainTiff) {
    // RAWs keep a small preview in IFD0; their EXIF pixel size (when set) is the sensor image.
    final pw = integer(0xA002);
    final ph = integer(0xA003);
    out
      ..width = pw ?? integer(0x0100)
      ..height = ph ?? integer(0x0101);
  }
  return out;
}
