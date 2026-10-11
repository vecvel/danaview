import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Container formats, recognised from a file's leading bytes rather than its extension.
enum MediaContainer {
  mp4('MPEG-4', 'MP4'),
  mov('QuickTime', 'MOV'),
  m4v('MPEG-4 video (Apple)', 'M4V'),
  m4a('MPEG-4 audio', 'M4A'),
  threeGpp('3GPP', '3GP'),
  matroska('Matroska', 'MKV'),
  webm('WebM', 'WEBM'),
  avi('Audio Video Interleave', 'AVI'),
  mpegTs('MPEG transport stream', 'TS'),
  bdav('Blu-ray transport stream', 'M2TS'),
  mpegPs('MPEG program stream', 'MPG'),
  mpegVideo('MPEG video stream', 'M2V'),
  flv('Flash Video', 'FLV'),
  asf('Windows Media', 'WMV'),
  ogg('Ogg', 'OGG'),
  realMedia('RealMedia', 'RM'),
  unknown('Unknown format', '');

  const MediaContainer(this.label, this.shortName);

  final String label;

  /// The usual file extension in capitals; empty for [unknown].
  final String shortName;

  /// The MP4 family (ISO base media file format), read box by box.
  bool get isIsoBmff => this == mp4 || this == mov || this == m4v || this == m4a || this == threeGpp;

  bool get isMatroska => this == matroska || this == webm;

  /// Whether [MediaInspector] reads tracks from this format; others only get file details.
  bool get hasTrackDetails => isIsoBmff || isMatroska;
}

enum MediaTrackKind { video, audio, subtitle }

/// One video, audio or subtitle track. Fields the file doesn't state are null.
@immutable
class MediaTrackInfo {
  const MediaTrackInfo({
    required this.kind,
    required this.codec,
    this.codecId,
    this.id,
    this.profile,
    this.language,
    this.name,
    this.isDefault = false,
    this.isForced = false,
    this.encrypted = false,
    this.duration,
    this.width,
    this.height,
    this.frameRate,
    this.bitDepth,
    this.hdr,
    this.rotation = 0,
    this.channels,
    this.sampleRate,
    this.bitrate,
  });

  final MediaTrackKind kind;

  /// Friendly codec name such as "H.264 (AVC)"; the raw [codecId] when it isn't recognised.
  final String codec;

  /// As stored in the file: an MP4 sample entry ("avc1") or a Matroska CodecID ("V_VP9").
  final String? codecId;
  final int? id;

  /// Codec profile and level, e.g. "High, Level 4.1" or "LC".
  final String? profile;

  /// ISO 639-2 code ("eng") or BCP 47 tag ("pt-BR"); null when undetermined.
  final String? language;
  final String? name;

  /// Matroska's default/forced flags; MP4 has no equivalent, so they stay false there.
  final bool isDefault;
  final bool isForced;

  /// The track is DRM-protected; [codec] is still the underlying format.
  final bool encrypted;
  final Duration? duration;

  /// Coded size in pixels, before [rotation].
  final int? width;
  final int? height;
  final double? frameRate;
  final int? bitDepth;

  /// "Dolby Vision", "HDR10" or "HLG" when the stream signals it.
  final String? hdr;

  /// Clockwise rotation applied on display: 0, 90, 180 or 270.
  final int rotation;
  final int? channels;
  final int? sampleRate;

  /// Average bits per second, when the file states it.
  final int? bitrate;
}

/// What [MediaInspector] could read from a file.
@immutable
class MediaFileInfo {
  const MediaFileInfo({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.container,
    this.modified,
    this.brand,
    this.duration,
    this.title,
    this.encoder,
    this.fastStart,
    this.fragmented = false,
    this.tracks = const [],
    this.warnings = const [],
  });

  final String path;
  final String fileName;
  final int sizeBytes;
  final DateTime? modified;
  final MediaContainer container;

  /// The MP4 major brand ("isom", "qt") or Matroska DocType ("matroska", "webm").
  final String? brand;
  final Duration? duration;
  final String? title;

  /// The application or library that wrote the file.
  final String? encoder;

  /// MP4/MOV only: true when the index (moov) comes before the media, so playback over a network
  /// can start before the whole file has arrived. Null for other formats or when unknown.
  final bool? fastStart;

  /// Fragmented MP4 (as used for adaptive streaming and some recorders).
  final bool fragmented;
  final List<MediaTrackInfo> tracks;

  /// User-facing notes about anything that couldn't be read.
  final List<String> warnings;

  /// Average bits per second over the whole file; null without a duration.
  int? get overallBitrate {
    final micros = duration?.inMicroseconds ?? 0;
    if (micros <= 0 || sizeBytes <= 0) return null;
    return (sizeBytes * 8 * 1e6 / micros).round();
  }

  List<MediaTrackInfo> get videoTracks => _tracksOf(MediaTrackKind.video);
  List<MediaTrackInfo> get audioTracks => _tracksOf(MediaTrackKind.audio);
  List<MediaTrackInfo> get subtitleTracks => _tracksOf(MediaTrackKind.subtitle);

  List<MediaTrackInfo> _tracksOf(MediaTrackKind kind) => [for (final t in tracks) if (t.kind == kind) t];
}

/// The file couldn't be opened at all; [message] is safe to show to the user.
class MediaInspectorException implements Exception {
  const MediaInspectorException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads container, duration and track details from a video file without decoding it.
///
/// MP4/MOV/M4V/3GP (ISO base media) and Matroska/WebM are parsed in detail; AVI, MPEG-TS,
/// FLV, WMV and others are recognised from their leading bytes and get file details only. At most
/// [maxBytesRead] bytes are read (the media data itself is seeked over), and damaged or truncated
/// files return whatever was readable plus [MediaFileInfo.warnings] instead of throwing.
class MediaInspector {
  const MediaInspector({this.maxBytesRead = defaultMaxBytesRead});

  static const int defaultMaxBytesRead = 16 * 1024 * 1024;

  final int maxBytesRead;

  /// Inspects [path] on a background isolate. Throws [MediaInspectorException] only when the
  /// file can't be opened.
  Future<MediaFileInfo> inspect(String path) async {
    final limit = maxBytesRead;
    final result = await Isolate.run(() {
      try {
        return (info: _inspectFile(path, limit), error: null);
      } on MediaInspectorException catch (e) {
        return (info: null, error: e.message);
      }
    }, debugName: 'MediaInspector');
    final error = result.error;
    if (error != null) throw MediaInspectorException(error);
    return result.info!;
  }

  /// [inspect] on the calling isolate.
  MediaFileInfo inspectSync(String path) => _inspectFile(path, maxBytesRead);
}

MediaFileInfo _inspectFile(String path, int maxBytesRead) {
  final file = File(path);
  final RandomAccessFile raf;
  final DateTime? modified;
  try {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      throw const MediaInspectorException("This file isn't available. It may have been moved or deleted.");
    }
    if (type == FileSystemEntityType.directory) {
      throw const MediaInspectorException('This is a folder, not a video file.');
    }
    raf = file.openSync();
    modified = _tryOrNull(file.lastModifiedSync);
  } on FileSystemException catch (e) {
    final code = e.osError?.errorCode;
    throw MediaInspectorException(code == 1 || code == 5 || code == 13
        ? "Danaview doesn't have permission to read this file."
        : "Couldn't open this file.");
  }

  final out = _InfoBuilder(path, modified);
  try {
    final source = _Source(raf, raf.lengthSync(), maxBytesRead);
    out.size = source.length;
    if (source.length == 0) {
      out.warn('This file is empty.');
      return out.build();
    }
    final head = source.read(0, 1024);
    out.container = _detectContainer(head);
    if (out.container.isIsoBmff) {
      _IsoBmffReader(source, out).read();
    } else if (out.container.isMatroska) {
      _MatroskaReader(source, out).read();
    } else if (out.container == MediaContainer.unknown) {
      out.warn("This doesn't look like a video format Danaview recognizes.");
    } else {
      out.warn('Track details are available for MP4, MOV, MKV and WebM files. '
          'For ${out.container.shortName} files only the format and file details are shown.');
    }
  } on _ReadLimitReached {
    final limit = maxBytesRead >= 1024 * 1024 ? '${maxBytesRead ~/ (1024 * 1024)} MB' : '${maxBytesRead ~/ 1024} KB';
    out.warn('Only the first $limit were read, so some details may be missing.');
  } catch (e) {
    debugPrint('[MediaInspector] $path: $e');
    out.warn("Part of this file couldn't be read. It may be damaged or incomplete.");
  } finally {
    try {
      raf.closeSync();
    } catch (_) {}
  }
  return out.build();
}

T? _tryOrNull<T>(T Function() read) {
  try {
    return read();
  } catch (_) {
    return null;
  }
}

// Container detection

MediaContainer _detectContainer(Uint8List b) {
  bool bytesAt(int offset, List<int> signature) {
    if (b.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (b[offset + i] != signature[i]) return false;
    }
    return true;
  }

  bool textAt(int offset, String text) => bytesAt(offset, latin1.encode(text));

  if (textAt(4, 'ftyp')) return _containerForBrand(b.tag(8));
  // Old QuickTime files start straight with an atom other than ftyp.
  if (b.length >= 8 && const {'moov', 'mdat', 'free', 'skip', 'wide', 'pnot'}.contains(b.tag(4))) {
    return MediaContainer.mov;
  }
  if (bytesAt(0, const [0x1A, 0x45, 0xDF, 0xA3])) return MediaContainer.matroska;
  if (textAt(0, 'RIFF') && (textAt(8, 'AVI ') || textAt(8, 'AVIX'))) return MediaContainer.avi;
  if (b.length > 376 && b[0] == 0x47 && b[188] == 0x47 && b[376] == 0x47) return MediaContainer.mpegTs;
  if (b.length > 388 && b[4] == 0x47 && b[196] == 0x47 && b[388] == 0x47) return MediaContainer.bdav;
  if (bytesAt(0, const [0x00, 0x00, 0x01, 0xBA])) return MediaContainer.mpegPs;
  if (bytesAt(0, const [0x00, 0x00, 0x01, 0xB3])) return MediaContainer.mpegVideo;
  if (textAt(0, 'FLV') && b.length > 3 && b[3] == 1) return MediaContainer.flv;
  if (bytesAt(0, const [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11])) return MediaContainer.asf;
  if (textAt(0, 'OggS')) return MediaContainer.ogg;
  if (textAt(0, '.RMF')) return MediaContainer.realMedia;
  return MediaContainer.unknown;
}

MediaContainer _containerForBrand(String brand) {
  if (brand == 'qt  ') return MediaContainer.mov;
  if (brand.startsWith('M4A') || brand.startsWith('M4B') || brand.startsWith('M4P')) return MediaContainer.m4a;
  if (brand.startsWith('M4V')) return MediaContainer.m4v;
  if (brand.startsWith('3g')) return MediaContainer.threeGpp;
  return MediaContainer.mp4;
}

// Shared plumbing

class _ReadLimitReached implements Exception {
  const _ReadLimitReached();
}

/// Random access to the file with a cap on the total bytes read; seeking is free.
class _Source {
  _Source(this._file, this.length, this._remaining);

  final RandomAccessFile _file;
  final int length;
  int _remaining;

  /// Up to [count] bytes at [offset]; fewer at the end of the file.
  Uint8List read(int offset, int count) {
    if (offset < 0 || offset >= length || count <= 0) return Uint8List(0);
    final n = math.min(count, length - offset);
    if (n > _remaining) throw const _ReadLimitReached();
    _remaining -= n;
    _file.setPositionSync(offset);
    return _file.readSync(n);
  }
}

extension _Bytes on Uint8List {
  int u16(int i) => (this[i] << 8) | this[i + 1];
  int u32(int i) => (this[i] << 24) | (this[i + 1] << 16) | (this[i + 2] << 8) | this[i + 3];
  int s32(int i) => u32(i).toSigned(32);

  /// Values past 2^63 (never real sizes) saturate instead of wrapping negative.
  int u64(int i) {
    final high = u32(i);
    return high > 0x7FFFFFFF ? 0x7FFFFFFFFFFFFFFF : high * 0x100000000 + u32(i + 4);
  }

  /// Four bytes as Latin-1 text, the way box types and fourccs are written.
  String tag(int i) => i + 4 <= length ? latin1.decode(Uint8List.sublistView(this, i, i + 4)) : '';
}

/// UTF-8 text without trailing NULs or surrounding spaces; null when empty.
String? _text(Uint8List bytes) {
  final value = utf8.decode(bytes, allowMalformed: true).replaceAll('\u0000', '').trim();
  return value.isEmpty ? null : value;
}

class _BitReader {
  _BitReader(this._data);

  final Uint8List _data;
  int _position = 0;

  int read(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      final byte = _position >> 3;
      if (byte >= _data.length) throw RangeError('Bit reader ran past the end');
      value = (value << 1) | ((_data[byte] >> (7 - (_position & 7))) & 1);
      _position++;
    }
    return value;
  }
}

class _InfoBuilder {
  _InfoBuilder(this.path, this.modified);

  final String path;
  final DateTime? modified;
  int size = 0;
  MediaContainer container = MediaContainer.unknown;
  String? brand;
  Duration? duration;
  String? title;
  String? encoder;
  bool? fastStart;
  bool fragmented = false;
  final List<MediaTrackInfo> tracks = [];
  final List<String> warnings = [];

  void warn(String message) {
    if (!warnings.contains(message)) warnings.add(message);
  }

  MediaFileInfo build() => MediaFileInfo(
        path: path,
        fileName: p.basename(path),
        sizeBytes: size,
        modified: modified,
        container: container,
        brand: brand,
        duration: duration,
        title: title,
        encoder: encoder,
        fastStart: fastStart,
        fragmented: fragmented,
        tracks: List.unmodifiable(tracks),
        warnings: List.unmodifiable(warnings),
      );
}

/// Track fields collected while parsing either container.
class _TrackBuilder {
  MediaTrackKind? kind;
  int? id;
  String? codecId;
  String? codec;
  String? profile;
  String? language;
  String? name;
  bool isDefault = false;
  bool isForced = false;
  bool encrypted = false;
  bool dolbyVision = false;
  bool hdrMetadata = false;
  int? transfer;
  int? width;
  int? height;
  double? frameRate;
  int? bitDepth;
  int rotation = 0;
  int? channels;
  int? sampleRate;
  int? bitrate;
  Duration? duration;

  // MP4 bookkeeping
  String? handler;
  _Box? sampleDescription;
  int timescale = 0;
  int mediaDuration = 0;
  int sampleCount = 0;
  int sttsSamples = 0;
  int sttsTicks = 0;
  int constantDelta = 0;

  String? get hdr {
    if (dolbyVision) return 'Dolby Vision';
    if (transfer == 16) return 'HDR10';
    if (transfer == 18) return 'HLG';
    return hdrMetadata ? 'HDR10' : null;
  }

  MediaTrackInfo build() {
    final fps = frameRate;
    return MediaTrackInfo(
      kind: kind!,
      codec: codec ?? codecId?.trim() ?? 'Unknown',
      codecId: codecId?.trim(),
      id: id,
      profile: profile,
      language: language,
      name: name,
      isDefault: isDefault,
      isForced: isForced,
      encrypted: encrypted,
      duration: duration,
      width: width == 0 ? null : width,
      height: height == 0 ? null : height,
      frameRate: fps == null || !fps.isFinite || fps <= 0 || fps > 1000 ? null : (fps * 1000).round() / 1000,
      // Lossy audio has no real bit depth, though some muxers still write one.
      bitDepth: kind == MediaTrackKind.audio && !_losslessAudio.contains(codec) ? null : bitDepth,
      hdr: kind == MediaTrackKind.video ? hdr : null,
      rotation: rotation,
      channels: channels == 0 ? null : channels,
      sampleRate: sampleRate == 0 ? null : sampleRate,
      bitrate: bitrate == 0 ? null : bitrate,
    );
  }
}

const _losslessAudio = {
  'PCM',
  'FLAC',
  'ALAC (Apple Lossless)',
  'Dolby TrueHD',
  'MLP',
  'DTS-HD Master Audio',
  'WavPack',
  'TTA',
};

/// Runs an optional enrichment step; a malformed codec box must not lose the rest of the track.
void _optional(void Function() body) {
  try {
    body();
  } on _ReadLimitReached {
    rethrow;
  } catch (_) {}
}

// ISO base media (MP4, MOV, M4V, 3GP)

class _Box {
  const _Box(this.type, this.start, this.dataStart, this.end, {this.truncated = false});

  final String type;
  final int start;
  final int dataStart;
  final int end;

  /// The box claims to run past its parent (or the end of the file).
  final bool truncated;

  int get dataLength => end - dataStart;
}

/// A box header at [pos] in [d] (an in-memory buffer); null when there is no valid box.
_Box? _boxIn(Uint8List d, int pos, int limit) {
  if (pos + 8 > limit) return null;
  var size = d.u32(pos);
  var header = 8;
  if (size == 1) {
    if (pos + 16 > limit) return null;
    size = d.u64(pos + 8);
    header = 16;
  } else if (size == 0) {
    size = limit - pos;
  }
  if (size < header) return null;
  final truncated = size > limit - pos;
  return _Box(d.tag(pos + 4), pos, pos + header, truncated ? limit : pos + size, truncated: truncated);
}

List<_Box> _boxesIn(Uint8List d, int start, int end) {
  final boxes = <_Box>[];
  var pos = start;
  while (boxes.length < 256) {
    final box = _boxIn(d, pos, math.min(end, d.length));
    if (box == null) break;
    boxes.add(box);
    pos = box.end;
  }
  return boxes;
}

/// Whether a plausible child box starts at [at]: a sane size and a printable type.
bool _looksLikeBox(Uint8List d, int at, int end) {
  if (at + 8 > end) return false;
  final size = d.u32(at);
  if (size < 8 || size > end - at) return false;
  for (var i = at + 4; i < at + 8; i++) {
    final c = d[i];
    if (c < 0x20 || (c > 0x7E && c != 0xA9)) return false;
  }
  return true;
}

class _IsoBmffReader {
  _IsoBmffReader(this._src, this._out);

  final _Source _src;
  final _InfoBuilder _out;
  final List<_TrackBuilder> _tracks = [];
  final Set<int> _chapterTrackIds = {};
  int _timescale = 0;
  int _duration = 0;
  int _fragmentDuration = 0;

  void read() {
    var pos = 0;
    var sawMedia = false;
    var sawMoov = false;
    var truncated = false;
    try {
      for (var guard = 0; guard < 100000; guard++) {
        final box = _boxAt(pos, _src.length);
        if (box == null) break;
        truncated = truncated || box.truncated;
        switch (box.type) {
          case 'ftyp':
            _readFtyp(box);
          case 'moov':
            sawMoov = true;
            _out.fastStart = !sawMedia;
            _readMoov(box);
          case 'mdat' || 'moof':
            sawMedia = true;
        }
        // Everything needed is in moov; the rest of the file is media.
        if (sawMoov) break;
        pos = box.end;
      }
    } finally {
      // Keeps the tracks read so far when a damaged box or the read limit cuts moov short.
      if (sawMoov) _finish();
    }

    if (truncated) _out.warn('This file seems to be incomplete. It ends sooner than its contents say.');
    if (!sawMoov) {
      _out.warn(sawMedia
          ? "This file has no index (moov), so its tracks can't be read. "
              'It may be incomplete, still downloading or still recording.'
          : 'No movie information was found in this file.');
    }
  }

  /// A box header read from the file; null when there is no valid box at [pos].
  _Box? _boxAt(int pos, int limit) {
    if (pos + 8 > limit) return null;
    final header = _src.read(pos, math.min(16, limit - pos));
    final box = _boxIn(header, 0, header.length);
    if (box == null) return null;
    // Sizes are relative to the header buffer; rebase them onto the file.
    var size = header.u32(0);
    if (size == 1) {
      size = header.u64(8);
    } else if (size == 0) {
      size = limit - pos;
    }
    final truncated = size > limit - pos;
    return _Box(box.type, pos, pos + (box.dataStart - box.start), truncated ? limit : pos + size,
        truncated: truncated);
  }

  void _walk(_Box parent, void Function(_Box box) visit, {int skip = 0}) {
    var pos = parent.dataStart + skip;
    for (var guard = 0; guard < 10000; guard++) {
      final box = _boxAt(pos, parent.end);
      if (box == null) return;
      visit(box);
      pos = box.end;
    }
  }

  Uint8List _data(_Box box, int cap) => _src.read(box.dataStart, math.min(box.dataLength, cap));

  void _readFtyp(_Box box) {
    final d = _data(box, 64);
    if (d.length >= 4) _out.brand = d.tag(0).trim();
  }

  void _readMoov(_Box moov) {
    _walk(moov, (box) {
      switch (box.type) {
        case 'mvhd':
          final d = _data(box, 32);
          final v1 = d.isNotEmpty && d[0] == 1;
          if (d.length < (v1 ? 32 : 20)) return;
          _timescale = d.u32(v1 ? 20 : 12);
          _duration = v1 ? d.u64(24) : d.u32(16);
          if (!v1 && _duration == 0xFFFFFFFF) _duration = 0;
        case 'trak':
          try {
            _readTrak(box);
          } on _ReadLimitReached {
            rethrow;
          } catch (_) {
            _out.warn("Some track details couldn't be read. The file may be damaged.");
          }
        case 'mvex':
          _out.fragmented = true;
          _walk(box, (child) {
            if (child.type != 'mehd') return;
            final d = _data(child, 12);
            if (d.length >= 8) _fragmentDuration = d[0] == 1 && d.length >= 12 ? d.u64(4) : d.u32(4);
          });
        case 'udta':
          _optional(() => _readUdta(box));
        case 'meta':
          _optional(() => _readMeta(box));
      }
    });
  }

  void _readTrak(_Box trak) {
    final t = _TrackBuilder();
    _walk(trak, (box) {
      switch (box.type) {
        case 'tkhd':
          _readTkhd(box, t);
        case 'tref':
          _walk(box, (reference) {
            if (reference.type != 'chap') return;
            final d = _data(reference, 256);
            for (var i = 0; i + 4 <= d.length; i += 4) {
              _chapterTrackIds.add(d.u32(i));
            }
          });
        case 'mdia':
          _readMdia(box, t);
      }
    });
    t.kind = switch (t.handler) {
      'vide' => MediaTrackKind.video,
      'soun' => MediaTrackKind.audio,
      'sbtl' || 'subt' || 'text' || 'clcp' || 'subp' => MediaTrackKind.subtitle,
      _ => null,
    };
    if (t.kind == null) return;
    final stsd = t.sampleDescription;
    if (stsd != null) _readStsd(stsd, t);
    _tracks.add(t);
  }

  void _readTkhd(_Box box, _TrackBuilder t) {
    final d = _data(box, 96);
    if (d.length < 4) return;
    final v1 = d[0] == 1;
    final idAt = v1 ? 20 : 12;
    final matrixAt = v1 ? 52 : 40;
    if (d.length >= idAt + 4) t.id = d.u32(idAt);
    if (d.length >= matrixAt + 8) t.rotation = _rotationOf(d.s32(matrixAt), d.s32(matrixAt + 4));
  }

  void _readMdia(_Box mdia, _TrackBuilder t) {
    _walk(mdia, (box) {
      switch (box.type) {
        case 'mdhd':
          final d = _data(box, 36);
          final v1 = d.isNotEmpty && d[0] == 1;
          if (d.length < (v1 ? 34 : 22)) return;
          t.timescale = d.u32(v1 ? 20 : 12);
          t.mediaDuration = v1 ? d.u64(24) : d.u32(16);
          t.language = _isoLanguage(d.u16(v1 ? 32 : 20));
        case 'hdlr':
          final d = _data(box, 12);
          if (d.length >= 12) t.handler = d.tag(8);
        case 'minf':
          _walk(box, (minf) {
            if (minf.type == 'stbl') _readStbl(minf, t);
          });
      }
    });
  }

  void _readStbl(_Box stbl, _TrackBuilder t) {
    _walk(stbl, (box) {
      switch (box.type) {
        case 'stsd':
          t.sampleDescription = box;
        case 'stts':
          _readStts(box, t);
        case 'stsz' || 'stz2':
          final d = _data(box, 12);
          if (d.length >= 12) t.sampleCount = d.u32(8);
      }
    });
  }

  void _readStts(_Box box, _TrackBuilder t) {
    final d = _data(box, 8 + 8 * 4096);
    if (d.length < 8) return;
    final count = d.u32(4);
    // Very long tables are skipped; the sample count and duration give the average instead.
    if (count == 0 || count > (d.length - 8) ~/ 8) return;
    var samples = 0;
    var ticks = 0;
    for (var i = 0; i < count; i++) {
      final n = d.u32(8 + i * 8);
      samples += n;
      ticks += n * d.u32(12 + i * 8);
    }
    t.sttsSamples = samples;
    t.sttsTicks = ticks;
    if (count == 1) t.constantDelta = d.u32(12);
  }

  void _readStsd(_Box stsd, _TrackBuilder t) {
    final d = _data(stsd, 1024 * 1024);
    if (d.length < 16) return;
    final entry = _boxIn(d, 8, d.length);
    if (entry == null) return;
    switch (t.kind!) {
      case MediaTrackKind.video:
        _readVisualEntry(d, entry, t);
      case MediaTrackKind.audio:
        _readAudioEntry(d, entry, t);
      case MediaTrackKind.subtitle:
        t.codecId = entry.type;
        t.codec = _isoSubtitleCodecs[entry.type];
    }
  }

  void _readVisualEntry(Uint8List d, _Box entry, _TrackBuilder t) {
    var format = entry.type;
    if (entry.end - entry.start >= 36) {
      t.width = d.u16(entry.start + 32);
      t.height = d.u16(entry.start + 34);
    }
    final children = _boxesIn(d, entry.start + 86, entry.end);
    final original = _originalFormat(d, children);
    if (original != null) {
      format = original;
      t.encrypted = true;
    }
    t.codecId = format;
    t.codec = _isoVideoCodec(format);
    if (const {'dvh1', 'dvhe', 'dva1', 'dvav', 'dav1'}.contains(format)) t.dolbyVision = true;
    for (final c in children) {
      final body = Uint8List.sublistView(d, c.dataStart, c.end);
      _optional(() {
        switch (c.type) {
          case 'avcC':
            _applyAvcC(t, body);
          case 'hvcC':
            _applyHvcC(t, body);
          case 'av1C':
            _applyAv1C(t, body);
          case 'vpcC':
            _applyVpcC(t, body);
          case 'colr':
            if (body.length >= 10 && (body.tag(0) == 'nclx' || body.tag(0) == 'nclc')) t.transfer = body.u16(6);
          case 'dvcC' || 'dvvC' || 'dvwC':
            t.dolbyVision = true;
          case 'mdcv' || 'clli' || 'SmDm' || 'CoLL':
            t.hdrMetadata = true;
          case 'esds':
            final esds = _parseEsds(Uint8List.sublistView(body, 4));
            if (esds != null && format == 'mp4v') t.codec = _mpeg4VideoObjectTypes[esds.objectType] ?? t.codec;
            if (esds != null && esds.avgBitrate > 0) t.bitrate = esds.avgBitrate;
          case 'btrt':
            if (body.length >= 12 && body.u32(8) > 0) t.bitrate = body.u32(8);
        }
      });
    }
  }

  void _readAudioEntry(Uint8List d, _Box entry, _TrackBuilder t) {
    var format = entry.type;
    final at = entry.start;
    var childAt = entry.end;
    if (entry.end - at >= 36) {
      final version = d.u16(at + 16);
      t.channels = d.u16(at + 24);
      t.sampleRate = d.u32(at + 32) >> 16;
      childAt = at + 36;
      // QuickTime sound descriptions v1 and v2 carry extra fields before the child boxes; ISO's
      // v1 entry doesn't, so the layout is confirmed by finding a box where it should start.
      if (version == 1 && !_looksLikeBox(d, childAt, entry.end) && _looksLikeBox(d, at + 52, entry.end)) {
        childAt = at + 52;
      } else if (version == 2 && entry.end - at >= 72) {
        t.sampleRate = ByteData.sublistView(d).getFloat64(at + 40).round();
        t.channels = d.u32(at + 48);
        childAt = at + 72;
      }
    }
    var children = _boxesIn(d, childAt, entry.end);
    // QuickTime nests the codec configuration inside a 'wave' box.
    for (final wave in children.where((c) => c.type == 'wave').toList()) {
      children = [...children, ..._boxesIn(d, wave.dataStart, wave.end)];
    }
    final original = _originalFormat(d, children);
    if (original != null) {
      format = original;
      t.encrypted = true;
    }
    t.codecId = format;
    t.codec = _isoAudioCodecs[format];
    for (final c in children) {
      final body = Uint8List.sublistView(d, c.dataStart, c.end);
      _optional(() {
        switch (c.type) {
          case 'esds':
            final esds = _parseEsds(Uint8List.sublistView(body, 4));
            if (esds == null) return;
            if (esds.avgBitrate > 0) t.bitrate = esds.avgBitrate;
            final objectType = esds.objectType;
            t.codec = _mpeg4AudioObjectTypes[objectType] ?? t.codec;
            if (objectType == 0x66 || objectType == 0x67 || objectType == 0x68) {
              t.profile = const {0x66: 'Main', 0x67: 'LC', 0x68: 'SSR'}[objectType];
            }
            final specific = esds.specific;
            if (objectType == 0x40 && specific != null) _applyAudioSpecificConfig(t, specific);
          case 'dac3':
            _applyDac3(t, body);
          case 'dec3':
            _applyDec3(t, body);
          case 'dOps':
            if (body.length >= 2 && body[1] > 0) t.channels = body[1];
            t.sampleRate = 48000;
        }
      });
    }
  }

  /// The real format of an encrypted ('encv'/'enca') entry, from sinf/frma.
  String? _originalFormat(Uint8List d, List<_Box> children) {
    for (final sinf in children.where((c) => c.type == 'sinf')) {
      for (final frma in _boxesIn(d, sinf.dataStart, sinf.end)) {
        if (frma.type == 'frma' && frma.dataLength >= 4) return d.tag(frma.dataStart);
      }
    }
    return null;
  }

  void _readUdta(_Box udta) {
    _walk(udta, (box) {
      switch (box.type) {
        case 'meta':
          _readMeta(box);
        case '©nam':
          _out.title ??= _userDataText(_data(box, 4096));
        case '©too' || '©swr' || '©enc':
          _out.encoder ??= _userDataText(_data(box, 4096));
      }
    });
  }

  void _readMeta(_Box meta) {
    // ISO 'meta' is a full box (4 bytes of version/flags); QuickTime's isn't.
    final head = _src.read(meta.dataStart, math.min(meta.dataLength, 8));
    final skip = head.length >= 8 && head.tag(4) == 'hdlr' ? 0 : 4;
    _walk(meta, skip: skip, (box) {
      if (box.type != 'ilst') return;
      _walk(box, (item) {
        switch (item.type) {
          case '©nam':
            _out.title ??= _userDataText(_data(item, 4096));
          case '©too' || '©swr' || '©enc':
            _out.encoder ??= _userDataText(_data(item, 4096));
        }
      });
    });
  }

  /// A user-data string, either iTunes style (a 'data' box with a type and a locale before the
  /// value) or QuickTime style (2-byte length, 2-byte language, then the text).
  String? _userDataText(Uint8List d) {
    if (d.length >= 16 && d.tag(4) == 'data') {
      return _text(Uint8List.sublistView(d, 16, math.min(d.length, math.max(16, d.u32(0)))));
    }
    if (d.length < 4) return null;
    return _text(Uint8List.sublistView(d, 4, math.min(d.length, 4 + d.u16(0))));
  }

  void _finish() {
    var duration = Duration.zero;
    if (_timescale > 0 && _duration > 0) {
      duration = _durationOf(_duration, _timescale);
    } else if (_timescale > 0 && _fragmentDuration > 0) {
      duration = _durationOf(_fragmentDuration, _timescale);
    }
    for (final t in _tracks) {
      if (t.kind == MediaTrackKind.subtitle && t.id != null && _chapterTrackIds.contains(t.id)) continue;
      if (t.timescale > 0 && t.mediaDuration > 0) {
        t.duration = _durationOf(t.mediaDuration, t.timescale);
        if (t.duration! > duration && _duration == 0 && _fragmentDuration == 0) duration = t.duration!;
      }
      if (t.kind == MediaTrackKind.video && t.timescale > 0) {
        if (t.constantDelta > 0) {
          t.frameRate = t.timescale / t.constantDelta;
        } else if (t.sttsSamples > 0 && t.sttsTicks > 0) {
          t.frameRate = t.sttsSamples * t.timescale / t.sttsTicks;
        } else if (t.sampleCount > 0 && t.mediaDuration > 0) {
          t.frameRate = t.sampleCount * t.timescale / t.mediaDuration;
        }
      }
      _out.tracks.add(t.build());
    }
    if (duration > Duration.zero) _out.duration = duration;
  }
}

Duration _durationOf(int units, int timescale) => Duration(microseconds: (units / timescale * 1e6).round());

/// Clockwise display rotation from the first column of a track's transform matrix.
int _rotationOf(int a, int b) {
  if (a == 0 && b == 0) return 0;
  final degrees = math.atan2(b.toDouble(), a.toDouble()) * 180 / math.pi;
  return ((degrees / 90).round() * 90) % 360;
}

/// mdhd's packed ISO 639-2/T code; QuickTime's older Macintosh codes and "und" give null.
String? _isoLanguage(int packed) {
  if (packed < 0x400 || packed == 0x7FFF) return null;
  final code = String.fromCharCodes([
    ((packed >> 10) & 0x1F) + 0x60,
    ((packed >> 5) & 0x1F) + 0x60,
    (packed & 0x1F) + 0x60,
  ]);
  return code == 'und' || !RegExp(r'^[a-z]{3}$').hasMatch(code) ? null : code;
}

/// objectTypeIndication, average bitrate and DecoderSpecificInfo of an MPEG-4 ES_Descriptor.
({int objectType, int avgBitrate, Uint8List? specific})? _parseEsds(Uint8List d) {
  var i = 0;
  int length() {
    var value = 0;
    for (var n = 0; n < 4; n++) {
      final b = d[i++];
      value = (value << 7) | (b & 0x7F);
      if ((b & 0x80) == 0) break;
    }
    return value;
  }

  if (d[i++] != 0x03) return null;
  length();
  i += 2;
  final flags = d[i++];
  if ((flags & 0x80) != 0) i += 2;
  if ((flags & 0x40) != 0) i += 1 + d[i];
  if ((flags & 0x20) != 0) i += 2;
  if (d[i++] != 0x04) return null;
  length();
  final objectType = d[i];
  final avgBitrate = d.length >= i + 13 ? d.u32(i + 9) : 0;
  i += 13;
  Uint8List? specific;
  if (i < d.length && d[i] == 0x05) {
    i++;
    final size = length();
    specific = Uint8List.sublistView(d, i, math.min(d.length, i + size));
  }
  return (objectType: objectType, avgBitrate: avgBitrate, specific: specific);
}

// Codec configuration records (shared by MP4 boxes and Matroska CodecPrivate)

String _level(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

void _applyAvcC(_TrackBuilder t, Uint8List c) {
  if (c.length < 4) return;
  final profile = c[1];
  final constraints = c[2];
  final level = c[3];
  final name = switch (profile) {
    66 => (constraints & 0x40) != 0 ? 'Constrained Baseline' : 'Baseline',
    77 => 'Main',
    88 => 'Extended',
    100 => 'High',
    110 => 'High 10',
    122 => 'High 4:2:2',
    244 => 'High 4:4:4',
    44 => 'CAVLC 4:4:4',
    _ => null,
  };
  if (name == null) return;
  t.profile = '$name, Level ${level == 9 ? '1b' : _level(level / 10)}';
  // These profiles only allow 8-bit video.
  if (profile == 66 || profile == 77 || profile == 88 || profile == 100) t.bitDepth = 8;
}

void _applyHvcC(_TrackBuilder t, Uint8List c) {
  if (c.length < 18) return;
  final name = switch (c[1] & 0x1F) {
    1 => 'Main',
    2 => 'Main 10',
    3 => 'Main Still Picture',
    4 => 'Range Extensions',
    5 => 'High Throughput',
    9 => 'Screen Content',
    _ => null,
  };
  final tier = (c[1] & 0x20) != 0 ? ' (High tier)' : '';
  if (name != null) t.profile = '$name$tier, Level ${_level(c[12] / 30)}';
  t.bitDepth = (c[17] & 0x07) + 8;

  // Encoders often store prefix SEI messages next to the parameter sets; mastering display
  // colour volume (137) or content light level (144) metadata means HDR10.
  if (c.length < 23) return;
  var pos = 23;
  for (var array = 0; array < c[22] && pos + 3 <= c.length; array++) {
    final nalType = c[pos] & 0x3F;
    final count = c.u16(pos + 1);
    pos += 3;
    for (var k = 0; k < count && pos + 2 <= c.length; k++) {
      final start = pos + 2;
      pos = start + c.u16(pos);
      if (nalType != 39 || pos > c.length) continue;
      var payloadType = 0;
      var i = start + 2;
      while (i < pos && c[i] == 0xFF) {
        payloadType += 255;
        i++;
      }
      if (i < pos) payloadType += c[i];
      if (payloadType == 137 || payloadType == 144) t.hdrMetadata = true;
    }
  }
}

void _applyAv1C(_TrackBuilder t, Uint8List c) {
  if (c.length < 3 || (c[0] & 0x80) == 0) return;
  final profile = c[1] >> 5;
  final levelIndex = c[1] & 0x1F;
  final highBitDepth = (c[2] & 0x40) != 0;
  final twelveBit = (c[2] & 0x20) != 0;
  final name = const ['Main', 'High', 'Professional'].elementAtOrNull(profile);
  final level = levelIndex >= 24 ? null : '${2 + (levelIndex >> 2)}.${levelIndex & 3}';
  if (name != null) t.profile = level == null ? name : '$name, Level $level';
  t.bitDepth = highBitDepth ? (twelveBit ? 12 : 10) : 8;
}

void _applyVpcC(_TrackBuilder t, Uint8List c) {
  // Full box: version and flags come first.
  if (c.length < 10 || c[0] != 1) return;
  t.profile = 'Profile ${c[4]}';
  t.bitDepth = c[6] >> 4;
  t.transfer = c[8];
}

const _aacProfiles = {
  1: 'Main',
  2: 'LC',
  3: 'SSR',
  4: 'LTP',
  5: 'HE-AAC',
  23: 'LD',
  29: 'HE-AAC v2',
  39: 'ELD',
  42: 'xHE-AAC',
};

const _aacSampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

void _applyAudioSpecificConfig(_TrackBuilder t, Uint8List config) {
  final bits = _BitReader(config);
  var objectType = bits.read(5);
  if (objectType == 31) objectType = 32 + bits.read(6);
  final rateIndex = bits.read(4);
  final rate = rateIndex == 15 ? bits.read(24) : _aacSampleRates.elementAtOrNull(rateIndex) ?? 0;
  final channelConfig = bits.read(4);
  t.profile = _aacProfiles[objectType] ?? t.profile;
  if ((t.sampleRate ?? 0) == 0) t.sampleRate = rate;
  if (channelConfig > 0 && channelConfig < 8) t.channels = const [0, 1, 2, 3, 4, 5, 6, 8][channelConfig];
}

const _ac3Channels = [2, 1, 2, 3, 3, 4, 4, 5];

void _applyDac3(_TrackBuilder t, Uint8List c) {
  final bits = _BitReader(c)
    ..read(2)
    ..read(5)
    ..read(3);
  final acmod = bits.read(3);
  t.channels = _ac3Channels[acmod] + bits.read(1);
}

void _applyDec3(_TrackBuilder t, Uint8List c) {
  final bits = _BitReader(c)
    ..read(13)
    ..read(3)
    ..read(2)
    ..read(5)
    ..read(1)
    ..read(1)
    ..read(3);
  final acmod = bits.read(3);
  var channels = _ac3Channels[acmod] + bits.read(1);
  bits.read(3);
  if (bits.read(4) > 0) {
    // Each extra location in a dependent substream is mostly a channel pair.
    var locations = bits.read(9);
    while (locations != 0) {
      channels += 2 * (locations & 1);
      locations >>= 1;
    }
  }
  t.channels = channels;
}

void _applyOpusHead(_TrackBuilder t, Uint8List c) {
  if (c.length >= 10 && latin1.decode(Uint8List.sublistView(c, 0, 8)) == 'OpusHead' && c[9] > 0) {
    t.channels = c[9];
  }
  t.sampleRate = 48000;
}

String _isoVideoCodec(String format) {
  final known = _isoVideoCodecs[format];
  if (known != null) return known;
  if (format.startsWith('xdv')) return 'MPEG-2 Video (XDCAM)';
  if (format.startsWith('hdv')) return 'MPEG-2 Video (HDV)';
  if (format.startsWith('ai')) return 'H.264 (AVC-Intra)';
  return format.trim();
}

const _isoVideoCodecs = {
  'avc1': 'H.264 (AVC)',
  'avc2': 'H.264 (AVC)',
  'avc3': 'H.264 (AVC)',
  'avc4': 'H.264 (AVC)',
  'dva1': 'H.264 (AVC)',
  'dvav': 'H.264 (AVC)',
  'hvc1': 'H.265 (HEVC)',
  'hev1': 'H.265 (HEVC)',
  'dvh1': 'H.265 (HEVC)',
  'dvhe': 'H.265 (HEVC)',
  'vvc1': 'H.266 (VVC)',
  'vvi1': 'H.266 (VVC)',
  'av01': 'AV1',
  'dav1': 'AV1',
  'vp09': 'VP9',
  'vp08': 'VP8',
  'mp4v': 'MPEG-4 Visual',
  's263': 'H.263',
  'h263': 'H.263',
  'apch': 'Apple ProRes 422 HQ',
  'apcn': 'Apple ProRes 422',
  'apcs': 'Apple ProRes 422 LT',
  'apco': 'Apple ProRes 422 Proxy',
  'ap4h': 'Apple ProRes 4444',
  'ap4x': 'Apple ProRes 4444 XQ',
  'aprn': 'Apple ProRes RAW',
  'aprh': 'Apple ProRes RAW HQ',
  'jpeg': 'Motion JPEG',
  'mjpa': 'Motion JPEG',
  'mjpb': 'Motion JPEG',
  'mjp2': 'Motion JPEG 2000',
  'dvc ': 'DV',
  'dvcp': 'DV',
  'dvpp': 'DVCPRO',
  'dv5n': 'DVCPRO50',
  'dv5p': 'DVCPRO50',
  'dvh5': 'DVCPRO HD',
  'dvh6': 'DVCPRO HD',
  'dvhp': 'DVCPRO HD',
  'dvhq': 'DVCPRO HD',
  'mx3n': 'MPEG-2 Video (IMX)',
  'mx3p': 'MPEG-2 Video (IMX)',
  'mx4n': 'MPEG-2 Video (IMX)',
  'mx4p': 'MPEG-2 Video (IMX)',
  'mx5n': 'MPEG-2 Video (IMX)',
  'mx5p': 'MPEG-2 Video (IMX)',
  'm2v1': 'MPEG-2 Video',
  'mp2v': 'MPEG-2 Video',
  'AVdn': 'Avid DNxHD',
  'AVdh': 'Avid DNxHR',
  'SVQ1': 'Sorenson Video',
  'SVQ3': 'Sorenson Video 3',
  'cvid': 'Cinepak',
  'rle ': 'QuickTime Animation',
  'png ': 'PNG',
  'raw ': 'Uncompressed',
  '2vuy': 'Uncompressed',
  'yuv2': 'Uncompressed',
  'v210': 'Uncompressed',
};

const _isoAudioCodecs = {
  'mp4a': 'AAC',
  'ac-3': 'AC-3 (Dolby Digital)',
  'ec-3': 'E-AC-3 (Dolby Digital Plus)',
  'ac-4': 'AC-4 (Dolby)',
  'mlpa': 'Dolby TrueHD',
  'Opus': 'Opus',
  'fLaC': 'FLAC',
  'alac': 'ALAC (Apple Lossless)',
  '.mp3': 'MP3',
  'mp3 ': 'MP3',
  'samr': 'AMR-NB',
  'sawb': 'AMR-WB',
  'dtsc': 'DTS',
  'dtsh': 'DTS-HD',
  'dtsl': 'DTS-HD Master Audio',
  'dtse': 'DTS Express',
  'dtsx': 'DTS:X',
  'mha1': 'MPEG-H 3D Audio',
  'mha2': 'MPEG-H 3D Audio',
  'mhm1': 'MPEG-H 3D Audio',
  'mhm2': 'MPEG-H 3D Audio',
  'lpcm': 'PCM',
  'sowt': 'PCM',
  'twos': 'PCM',
  'in24': 'PCM',
  'in32': 'PCM',
  'fl32': 'PCM',
  'fl64': 'PCM',
  'raw ': 'PCM',
  'NONE': 'PCM',
  'ipcm': 'PCM',
  'fpcm': 'PCM',
  'ulaw': 'G.711 µ-law',
  'alaw': 'G.711 A-law',
  'ima4': 'IMA ADPCM',
  'spex': 'Speex',
};

const _isoSubtitleCodecs = {
  'tx3g': 'Timed Text (tx3g)',
  'text': 'QuickTime Text',
  'wvtt': 'WebVTT',
  'stpp': 'TTML',
  'dfxp': 'TTML',
  'c608': 'CEA-608 captions',
  'c708': 'CEA-708 captions',
  'mp4s': 'VobSub (DVD)',
};

/// MPEG-4 objectTypeIndication values that appear in video 'esds' boxes.
const _mpeg4VideoObjectTypes = {
  0x20: 'MPEG-4 Visual',
  0x21: 'H.264 (AVC)',
  0x23: 'H.265 (HEVC)',
  0x60: 'MPEG-2 Video',
  0x61: 'MPEG-2 Video',
  0x62: 'MPEG-2 Video',
  0x63: 'MPEG-2 Video',
  0x64: 'MPEG-2 Video',
  0x65: 'MPEG-2 Video',
  0x6A: 'MPEG-1 Video',
  0x6C: 'Motion JPEG',
  0x6E: 'JPEG 2000',
};

/// MPEG-4 objectTypeIndication values that appear in audio 'esds' boxes.
const _mpeg4AudioObjectTypes = {
  0x40: 'AAC',
  0x66: 'AAC',
  0x67: 'AAC',
  0x68: 'AAC',
  0x69: 'MP3',
  0x6B: 'MP3',
  0xA5: 'AC-3 (Dolby Digital)',
  0xA6: 'E-AC-3 (Dolby Digital Plus)',
  0xA9: 'DTS',
  0xAD: 'Opus',
  0xDD: 'Vorbis',
};

// Matroska / WebM (EBML)

const _ebmlHeaderId = 0x1A45DFA3;
const _docTypeId = 0x4282;
const _segmentId = 0x18538067;
const _seekHeadId = 0x114D9B74;
const _seekId = 0x4DBB;
const _seekElementId = 0x53AB;
const _seekPositionId = 0x53AC;
const _infoId = 0x1549A966;
const _tracksId = 0x1654AE6B;
const _clusterId = 0x1F43B675;
const _trackEntryId = 0xAE;

/// Elements that sit directly in a Segment; an unknown-size element ends where one begins.
const _segmentChildIds = {
  _seekHeadId,
  _infoId,
  _tracksId,
  _clusterId,
  0x1C53BB6B, // Cues
  0x1941A469, // Attachments
  0x1043A770, // Chapters
  0x1254C367, // Tags
  _segmentId,
  _ebmlHeaderId,
};

/// Info and Tracks are normally a few kilobytes; larger ones are read only this far.
const _maxMasterRead = 4 * 1024 * 1024;

class _Element {
  const _Element(this.id, this.start, this.dataStart, this.size);

  final int id;
  final int start;
  final int dataStart;

  /// Null when the element has an unknown size (live streams and recorders write these).
  final int? size;
}

/// An EBML variable-length ID (marker bits kept) at [pos]; null when invalid.
({int value, int length})? _ebmlId(Uint8List d, int pos, int end) {
  if (pos >= end) return null;
  final first = d[pos];
  if (first == 0) return null;
  final length = 9 - first.bitLength;
  if (length > 4 || pos + length > end) return null;
  var value = 0;
  for (var i = 0; i < length; i++) {
    value = (value << 8) | d[pos + i];
  }
  return (value: value, length: length);
}

/// An EBML variable-length size at [pos]; [value] is null for the reserved "unknown" size.
({int? value, int length})? _ebmlSize(Uint8List d, int pos, int end) {
  if (pos >= end) return null;
  final first = d[pos];
  if (first == 0) return null;
  final length = 9 - first.bitLength;
  if (pos + length > end) return null;
  var value = first & ((1 << (8 - length)) - 1);
  for (var i = 1; i < length; i++) {
    value = (value << 8) | d[pos + i];
  }
  final unknown = value == (1 << (7 * length)) - 1;
  return (value: unknown ? null : value, length: length);
}

/// Calls [visit] for each element in d[start, end). Unknown-size children run to [end].
/// Stops before an element whose ID is in [stopAt] and returns where it stopped.
int _ebmlChildren(
  Uint8List d,
  int start,
  int end,
  void Function(int id, int dataStart, int dataEnd) visit, {
  Set<int> stopAt = const {},
}) {
  var pos = start;
  end = math.min(end, d.length);
  while (pos < end) {
    final id = _ebmlId(d, pos, end);
    if (id == null || stopAt.contains(id.value)) break;
    final size = _ebmlSize(d, pos + id.length, end);
    if (size == null) break;
    final dataStart = pos + id.length + size.length;
    final sizeValue = size.value;
    final dataEnd = sizeValue == null ? end : math.min(end, dataStart + sizeValue);
    visit(id.value, dataStart, dataEnd);
    pos = dataEnd;
  }
  return math.min(pos, end);
}

int _ebmlUint(Uint8List d, int start, int end) {
  var value = 0;
  for (var i = start; i < end && i < start + 8; i++) {
    value = (value << 8) | d[i];
  }
  return value;
}

double? _ebmlFloat(Uint8List d, int start, int end) {
  final data = ByteData.sublistView(d, start, end);
  return switch (end - start) {
    0 => 0,
    4 => data.getFloat32(0),
    8 => data.getFloat64(0),
    _ => null,
  };
}

String? _ebmlString(Uint8List d, int start, int end) => _text(Uint8List.sublistView(d, start, end));

class _MatroskaReader {
  _MatroskaReader(this._src, this._out);

  final _Source _src;
  final _InfoBuilder _out;
  bool _haveInfo = false;
  bool _haveTracks = false;

  void read() {
    final header = _elementAt(0);
    if (header == null || header.id != _ebmlHeaderId || header.size == null) {
      _out.warn("This file's Matroska header couldn't be read.");
      return;
    }
    final headerData = _src.read(header.dataStart, math.min(header.size!, 4096));
    _ebmlChildren(headerData, 0, headerData.length, (id, s, e) {
      if (id != _docTypeId) return;
      final docType = _ebmlString(headerData, s, e);
      _out.brand = docType;
      _out.container = docType == 'webm' ? MediaContainer.webm : MediaContainer.matroska;
    });

    var pos = header.dataStart + header.size!;
    for (var guard = 0; guard < 64; guard++) {
      final element = _elementAt(pos);
      if (element == null) break;
      if (element.id == _segmentId) {
        _readSegment(element);
        return;
      }
      final size = element.size;
      if (size == null) break;
      pos = element.dataStart + size;
    }
    _out.warn('No Matroska segment was found in this file.');
  }

  _Element? _elementAt(int pos) {
    final head = _src.read(pos, 12);
    final id = _ebmlId(head, 0, head.length);
    if (id == null) return null;
    final size = _ebmlSize(head, id.length, head.length);
    if (size == null) return null;
    return _Element(id.value, pos, pos + id.length + size.length, size.value);
  }

  void _readSegment(_Element segment) {
    final segmentStart = segment.dataStart;
    final segmentSize = segment.size;
    final segmentEnd = segmentSize == null ? _src.length : math.min(_src.length, segmentStart + segmentSize);
    if (segmentSize != null && segmentStart + segmentSize > _src.length) {
      _out.warn('This file seems to be incomplete. It ends sooner than its contents say.');
    }
    final seekTargets = <int, int>{};

    var pos = segmentStart;
    for (var guard = 0; guard < 10000 && pos < segmentEnd && !(_haveInfo && _haveTracks); guard++) {
      final element = _elementAt(pos);
      if (element == null) break;
      // The media data starts here; anything still missing is found through the SeekHead.
      if (element.id == _clusterId) break;
      if (element.id == _infoId || element.id == _tracksId) {
        pos = _readTopLevel(element, segmentEnd);
        continue;
      }
      if (element.id == _seekHeadId && element.size != null) {
        _readSeekHead(element, segmentStart, seekTargets);
      }
      final size = element.size;
      if (size == null) break;
      pos = element.dataStart + size;
    }

    for (final (id, done) in [(_infoId, _haveInfo), (_tracksId, _haveTracks)]) {
      final target = seekTargets[id];
      if (done || target == null || target >= segmentEnd) continue;
      final element = _elementAt(target);
      if (element?.id == id) _readTopLevel(element!, segmentEnd);
    }

    if (!_haveTracks) _out.warn("This file's track list couldn't be found. It may be damaged or incomplete.");
  }

  void _readSeekHead(_Element seekHead, int segmentStart, Map<int, int> targets) {
    final d = _src.read(seekHead.dataStart, math.min(seekHead.size!, 64 * 1024));
    _ebmlChildren(d, 0, d.length, (id, s, e) {
      if (id != _seekId) return;
      int? target;
      int? position;
      _ebmlChildren(d, s, e, (childId, cs, ce) {
        if (childId == _seekElementId) target = _ebmlUint(d, cs, ce);
        if (childId == _seekPositionId) position = _ebmlUint(d, cs, ce);
      });
      if (target != null && position != null) targets.putIfAbsent(target!, () => segmentStart + position!);
    });
  }

  /// Reads Info or Tracks and returns where the next element starts.
  int _readTopLevel(_Element element, int segmentEnd) {
    final size = element.size;
    final available = math.min(size ?? segmentEnd - element.dataStart, segmentEnd - element.dataStart);
    final d = _src.read(element.dataStart, math.min(available, _maxMasterRead));
    if (d.length < available) _out.warn("Some of this file's details were too large to read in full.");
    // An unknown-size element ends where the next Segment-level element begins.
    final consumed = _ebmlChildren(d, 0, d.length, (_, __, ___) {}, stopAt: size == null ? _segmentChildIds : const {});
    final end = size == null ? consumed : d.length;
    if (element.id == _infoId) {
      _haveInfo = true;
      _optional(() => _readInfo(d, end));
    } else {
      _haveTracks = true;
      _readTracks(d, end);
    }
    return size == null ? element.dataStart + consumed : element.dataStart + size;
  }

  void _readInfo(Uint8List d, int end) {
    var timestampScale = 1000000;
    double? duration;
    String? muxingApp;
    String? writingApp;
    _ebmlChildren(d, 0, end, (id, s, e) {
      switch (id) {
        case 0x2AD7B1:
          final scale = _ebmlUint(d, s, e);
          if (scale > 0) timestampScale = scale;
        case 0x4489:
          duration = _ebmlFloat(d, s, e);
        case 0x7BA9:
          _out.title = _ebmlString(d, s, e);
        case 0x4D80:
          muxingApp = _ebmlString(d, s, e);
        case 0x5741:
          writingApp = _ebmlString(d, s, e);
      }
    });
    _out.encoder = writingApp ?? muxingApp;
    final seconds = (duration ?? 0) * timestampScale / 1e9;
    if (seconds.isFinite && seconds > 0) _out.duration = Duration(microseconds: (seconds * 1e6).round());
  }

  void _readTracks(Uint8List d, int end) {
    _ebmlChildren(d, 0, end, (id, s, e) {
      if (id != _trackEntryId) return;
      try {
        final track = _readTrackEntry(d, s, e);
        if (track != null) _out.tracks.add(track);
      } on _ReadLimitReached {
        rethrow;
      } catch (_) {
        _out.warn("Some track details couldn't be read. The file may be damaged.");
      }
    });
  }

  MediaTrackInfo? _readTrackEntry(Uint8List d, int start, int end) {
    // Matroska defaults: language "eng", default flag on.
    final t = _TrackBuilder()
      ..language = 'eng'
      ..isDefault = true;
    int? type;
    String? languageTag;
    Uint8List? codecPrivate;
    var defaultDuration = 0;
    _ebmlChildren(d, start, end, (id, s, e) {
      switch (id) {
        case 0xD7:
          t.id = _ebmlUint(d, s, e);
        case 0x83:
          type = _ebmlUint(d, s, e);
        case 0x86:
          t.codecId = _ebmlString(d, s, e);
        case 0x63A2:
          codecPrivate = Uint8List.sublistView(d, s, e);
        case 0x22B59C:
          t.language = _ebmlString(d, s, e);
        case 0x22B59D:
          languageTag = _ebmlString(d, s, e);
        case 0x536E:
          t.name = _ebmlString(d, s, e);
        case 0x88:
          t.isDefault = _ebmlUint(d, s, e) != 0;
        case 0x55AA:
          t.isForced = _ebmlUint(d, s, e) != 0;
        case 0x23E383:
          defaultDuration = _ebmlUint(d, s, e);
        case 0xE0:
          _readVideo(d, s, e, t);
        case 0xE1:
          _readAudio(d, s, e, t);
        case 0x41E4: // BlockAdditionMapping: Dolby Vision configuration
          _ebmlChildren(d, s, e, (childId, cs, ce) {
            if (childId != 0x41E7) return;
            final addType = _ebmlUint(d, cs, ce);
            if (addType == 0x64766343 || addType == 0x64767643) t.dolbyVision = true;
          });
        case 0x6D80: // ContentEncodings: encrypted tracks carry a ContentEncryption
          _ebmlChildren(d, s, e, (_, cs, ce) {
            _ebmlChildren(d, cs, ce, (encodingId, _, __) {
              if (encodingId == 0x5035) t.encrypted = true;
            });
          });
      }
    });

    final codecId = t.codecId ?? '';
    t.kind = switch (type) {
      1 => MediaTrackKind.video,
      2 => MediaTrackKind.audio,
      17 => MediaTrackKind.subtitle,
      null when codecId.startsWith('V_') => MediaTrackKind.video,
      null when codecId.startsWith('A_') => MediaTrackKind.audio,
      null when codecId.startsWith('S_') => MediaTrackKind.subtitle,
      _ => null,
    };
    if (t.kind == null) return null;

    t.language = languageTag ?? t.language;
    if (t.language == 'und') t.language = null;
    t.codec = _matroskaCodec(codecId);
    final private = codecPrivate;
    if (private != null && private.isNotEmpty) _optional(() => _applyCodecPrivate(t, codecId, private));
    if (t.kind == MediaTrackKind.video && defaultDuration > 0) t.frameRate = 1e9 / defaultDuration;
    return t.build();
  }

  void _readVideo(Uint8List d, int start, int end, _TrackBuilder t) {
    _ebmlChildren(d, start, end, (id, s, e) {
      switch (id) {
        case 0xB0:
          t.width = _ebmlUint(d, s, e);
        case 0xBA:
          t.height = _ebmlUint(d, s, e);
        case 0x55B0: // Colour
          _ebmlChildren(d, s, e, (colourId, cs, ce) {
            switch (colourId) {
              case 0x55B2:
                final bits = _ebmlUint(d, cs, ce);
                if (bits > 0) t.bitDepth = bits;
              case 0x55BA:
                t.transfer = _ebmlUint(d, cs, ce);
              case 0x55D0:
                t.hdrMetadata = true;
            }
          });
      }
    });
  }

  void _readAudio(Uint8List d, int start, int end, _TrackBuilder t) {
    // Matroska defaults: 8 kHz, mono.
    double sampling = 8000;
    double? output;
    var channels = 1;
    _ebmlChildren(d, start, end, (id, s, e) {
      switch (id) {
        case 0xB5:
          sampling = _ebmlFloat(d, s, e) ?? sampling;
        case 0x78B5:
          output = _ebmlFloat(d, s, e);
        case 0x9F:
          channels = _ebmlUint(d, s, e);
        case 0x6264:
          final bits = _ebmlUint(d, s, e);
          if (bits > 0) t.bitDepth = bits;
      }
    });
    final rate = output ?? sampling;
    if (rate.isFinite && rate > 0) t.sampleRate = rate.round();
    t.channels = channels;
  }
}

void _applyCodecPrivate(_TrackBuilder t, String codecId, Uint8List private) {
  switch (codecId) {
    case 'V_MPEG4/ISO/AVC':
      _applyAvcC(t, private);
    case 'V_MPEGH/ISO/HEVC':
      _applyHvcC(t, private);
    case 'V_AV1':
      _applyAv1C(t, private);
    case 'A_OPUS':
      _applyOpusHead(t, private);
    case 'V_MS/VFW/FOURCC':
      // BITMAPINFOHEADER: the compression fourcc sits at byte 16.
      if (private.length >= 20) {
        final fourcc = private.tag(16);
        t.codec = _vfwCodecs[fourcc.toUpperCase()] ?? fourcc.trim();
      }
    case 'A_MS/ACM':
      // WAVEFORMATEX, little-endian: format tag, channels, sample rate.
      if (private.length >= 8) {
        final data = ByteData.sublistView(private);
        t.codec = _acmCodecs[data.getUint16(0, Endian.little)] ?? t.codec;
        t.channels = data.getUint16(2, Endian.little);
        t.sampleRate = data.getUint32(4, Endian.little);
      }
    default:
      if (codecId == 'A_AAC' || codecId.startsWith('A_AAC/')) _applyAudioSpecificConfig(t, private);
  }
}

String _matroskaCodec(String codecId) {
  final known = _matroskaCodecs[codecId];
  if (known != null) return known;
  if (codecId.startsWith('A_AAC')) return 'AAC';
  if (codecId.startsWith('A_REAL/')) return 'RealAudio';
  if (codecId.startsWith('V_REAL/')) return 'RealVideo';
  if (codecId.startsWith('V_QUICKTIME')) return 'QuickTime video';
  if (codecId.startsWith('A_QUICKTIME')) return 'QuickTime audio';
  return codecId.isEmpty ? 'Unknown' : codecId;
}

const _matroskaCodecs = {
  'V_MPEG4/ISO/AVC': 'H.264 (AVC)',
  'V_MPEGH/ISO/HEVC': 'H.265 (HEVC)',
  'V_MPEGI/ISO/VVC': 'H.266 (VVC)',
  'V_AV1': 'AV1',
  'V_VP9': 'VP9',
  'V_VP8': 'VP8',
  'V_MPEG4/ISO/SP': 'MPEG-4 Visual',
  'V_MPEG4/ISO/ASP': 'MPEG-4 Visual',
  'V_MPEG4/ISO/AP': 'MPEG-4 Visual',
  'V_MPEG4/MS/V3': 'Microsoft MPEG-4 v3',
  'V_MPEG1': 'MPEG-1 Video',
  'V_MPEG2': 'MPEG-2 Video',
  'V_THEORA': 'Theora',
  'V_PRORES': 'Apple ProRes',
  'V_FFV1': 'FFV1',
  'V_MJPEG': 'Motion JPEG',
  'V_DIRAC': 'Dirac',
  'V_UNCOMPRESSED': 'Uncompressed',
  'V_MS/VFW/FOURCC': 'Video for Windows',
  'A_AAC': 'AAC',
  'A_AC3': 'AC-3 (Dolby Digital)',
  'A_AC3/BSID9': 'AC-3 (Dolby Digital)',
  'A_AC3/BSID10': 'AC-3 (Dolby Digital)',
  'A_EAC3': 'E-AC-3 (Dolby Digital Plus)',
  'A_TRUEHD': 'Dolby TrueHD',
  'A_MLP': 'MLP',
  'A_DTS': 'DTS',
  'A_DTS/EXPRESS': 'DTS Express',
  'A_DTS/LOSSLESS': 'DTS-HD Master Audio',
  'A_OPUS': 'Opus',
  'A_VORBIS': 'Vorbis',
  'A_FLAC': 'FLAC',
  'A_ALAC': 'ALAC (Apple Lossless)',
  'A_MPEG/L3': 'MP3',
  'A_MPEG/L2': 'MP2',
  'A_MPEG/L1': 'MP1',
  'A_PCM/INT/LIT': 'PCM',
  'A_PCM/INT/BIG': 'PCM',
  'A_PCM/FLOAT/IEEE': 'PCM',
  'A_TTA1': 'TTA',
  'A_WAVPACK4': 'WavPack',
  'A_MS/ACM': 'ACM audio',
  'S_TEXT/UTF8': 'SubRip (SRT)',
  'S_TEXT/ASCII': 'Plain text',
  'S_TEXT/SSA': 'SubStation Alpha (SSA)',
  'S_TEXT/ASS': 'Advanced SubStation (ASS)',
  'S_SSA': 'SubStation Alpha (SSA)',
  'S_ASS': 'Advanced SubStation (ASS)',
  'S_TEXT/WEBVTT': 'WebVTT',
  'D_WEBVTT/SUBTITLES': 'WebVTT',
  'D_WEBVTT/CAPTIONS': 'WebVTT',
  'S_TEXT/USF': 'Universal Subtitle Format',
  'S_VOBSUB': 'VobSub (DVD)',
  'S_HDMV/PGS': 'PGS (Blu-ray)',
  'S_HDMV/TEXTST': 'Blu-ray Text',
  'S_DVBSUB': 'DVB subtitles',
  'S_KATE': 'Kate',
  'S_ARIBSUB': 'ARIB captions',
};

const _vfwCodecs = {
  'XVID': 'MPEG-4 Visual (Xvid)',
  'DIVX': 'MPEG-4 Visual (DivX)',
  'DX50': 'MPEG-4 Visual (DivX)',
  'FMP4': 'MPEG-4 Visual',
  'MP4V': 'MPEG-4 Visual',
  'H264': 'H.264 (AVC)',
  'X264': 'H.264 (AVC)',
  'AVC1': 'H.264 (AVC)',
  'HEVC': 'H.265 (HEVC)',
  'WMV3': 'Windows Media Video 9',
  'WVC1': 'VC-1',
  'MJPG': 'Motion JPEG',
  'MPG2': 'MPEG-2 Video',
};

const _acmCodecs = {
  0x0001: 'PCM',
  0x0003: 'PCM',
  0x0050: 'MP2',
  0x0055: 'MP3',
  0x00FF: 'AAC',
  0x1610: 'AAC',
  0x0161: 'Windows Media Audio',
  0x0162: 'Windows Media Audio Pro',
  0x0163: 'Windows Media Audio Lossless',
  0x2000: 'AC-3 (Dolby Digital)',
  0x2001: 'DTS',
  0xFFFE: 'PCM',
};
