import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_data/danaview_data.dart';

// Byte builders for tiny synthetic files.

List<int> _u16(int v) => [v >> 8 & 0xFF, v & 0xFF];
List<int> _u32(int v) => [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];
List<int> _u64(int v) => [..._u32(v ~/ 0x100000000), ..._u32(v % 0x100000000)];
List<int> _ascii(String s) => latin1.encode(s);

List<int> _box(String type, List<int> payload) => [..._u32(payload.length + 8), ..._ascii(type), ...payload];
List<int> _fullBox(String type, List<int> payload, {int version = 0, int flags = 0}) =>
    _box(type, [version, ..._u32(flags).sublist(1), ...payload]);

/// A box written with the 64-bit "largesize" header.
List<int> _largeBox(String type, List<int> payload) =>
    [..._u32(1), ..._ascii(type), ..._u64(payload.length + 16), ...payload];

const _identityMatrix = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000];
const _rotate90Matrix = [0, 0x00010000, 0, -0x00010000 & 0xFFFFFFFF, 0, 0, 0, 0, 0x40000000];

int _packLanguage(String code) =>
    ((code.codeUnitAt(0) - 0x60) << 10) | ((code.codeUnitAt(1) - 0x60) << 5) | (code.codeUnitAt(2) - 0x60);

List<int> _ftyp([String brand = 'isom']) =>
    _box('ftyp', [..._ascii(brand), ..._u32(0x200), ..._ascii('isom'), ..._ascii('iso2'), ..._ascii('avc1'), ..._ascii('mp41')]);

List<int> _mvhd({required int timescale, required int duration}) => _fullBox('mvhd', [
      ..._u32(0), ..._u32(0), ..._u32(timescale), ..._u32(duration),
      ..._u32(0x00010000), ..._u16(0x0100), ...List.filled(10, 0),
      for (final m in _identityMatrix) ..._u32(m),
      ...List.filled(24, 0), ..._u32(3),
    ]);

List<int> _tkhd({required int id, required int duration, int width = 0, int height = 0, List<int> matrix = _identityMatrix}) =>
    _fullBox('tkhd', flags: 3, [
      ..._u32(0), ..._u32(0), ..._u32(id), ..._u32(0), ..._u32(duration),
      ...List.filled(8, 0), ..._u16(0), ..._u16(0), ..._u16(0), ..._u16(0),
      for (final m in matrix) ..._u32(m),
      ..._u32(width << 16), ..._u32(height << 16),
    ]);

List<int> _mdhd({required int timescale, required int duration, String language = 'und'}) => _fullBox('mdhd', [
      ..._u32(0), ..._u32(0), ..._u32(timescale), ..._u32(duration), ..._u16(_packLanguage(language)), ..._u16(0),
    ]);

List<int> _hdlr(String handler) =>
    _fullBox('hdlr', [..._u32(0), ..._ascii(handler), ...List.filled(12, 0), ..._ascii('Handler'), 0]);

List<int> _trak({
  required List<int> tkhd,
  required List<int> mdhd,
  required String handler,
  required List<int> sampleEntry,
  List<int> stts = const [],
  int sampleCount = 0,
}) {
  final stbl = _box('stbl', [
    ..._fullBox('stsd', [..._u32(1), ...sampleEntry]),
    ..._fullBox('stts', [..._u32(stts.length ~/ 8), ...stts]),
    ..._fullBox('stsz', [..._u32(0), ..._u32(sampleCount)]),
  ]);
  return _box('trak', [
    ...tkhd,
    ..._box('mdia', [...mdhd, ..._hdlr(handler), ..._box('minf', stbl)]),
  ]);
}

List<int> _visualEntry(String format, {required int width, required int height, List<int> children = const []}) =>
    _box(format, [
      ...List.filled(6, 0), ..._u16(1), ..._u16(0), ..._u16(0), ...List.filled(12, 0),
      ..._u16(width), ..._u16(height), ..._u32(0x00480000), ..._u32(0x00480000), ..._u32(0), ..._u16(1),
      ...List.filled(32, 0), ..._u16(0x18), ..._u16(0xFFFF),
      ...children,
    ]);

List<int> _audioEntry(String format, {required int channels, required int sampleRate, List<int> children = const []}) =>
    _box(format, [
      ...List.filled(6, 0), ..._u16(1), ..._u16(0), ..._u16(0), ..._u32(0),
      ..._u16(channels), ..._u16(16), ..._u16(0), ..._u16(0), ..._u32(sampleRate << 16),
      ...children,
    ]);

/// esds for AAC-LC, 48 kHz, stereo.
List<int> _aacEsds() {
  const asc = [0x11, 0x90]; // object type 2 (LC), rate index 3 (48 kHz), channel config 2
  final decoderSpecific = [0x05, asc.length, ...asc];
  final decoderConfig = [0x04, 13 + decoderSpecific.length, 0x40, 0x15, 0, 0, 0, ..._u32(160000), ..._u32(128000), ...decoderSpecific];
  final es = [0x03, 3 + decoderConfig.length + 3, ..._u16(1), 0, ...decoderConfig, 0x06, 0x01, 0x02];
  return _fullBox('esds', es);
}

List<int> _avcC({int profile = 100, int level = 41}) => _box('avcC', [1, profile, 0, level, 0xFF, 0xE0, 0x00]);

List<int> _ilstItem(String type, String value) =>
    _box(type, _box('data', [..._u32(1), ..._u32(0), ...utf8.encode(value)]));

List<int> _moov({List<int> matrix = _identityMatrix, bool withVideo = true}) => _box('moov', [
      ..._mvhd(timescale: 1000, duration: 60000),
      if (withVideo)
        ..._trak(
          tkhd: _tkhd(id: 1, duration: 60000, width: 1920, height: 1080, matrix: matrix),
          mdhd: _mdhd(timescale: 24000, duration: 1440 * 1001),
          handler: 'vide',
          sampleEntry: _visualEntry('avc1', width: 1920, height: 1080, children: _avcC()),
          stts: [..._u32(1440), ..._u32(1001)],
          sampleCount: 1440,
        ),
      ..._trak(
        tkhd: _tkhd(id: 2, duration: 60000),
        mdhd: _mdhd(timescale: 48000, duration: 48000 * 60, language: 'eng'),
        handler: 'soun',
        sampleEntry: _audioEntry('mp4a', channels: 2, sampleRate: 48000, children: _aacEsds()),
      ),
      ..._box('udta', _fullBox('meta', [
        ..._hdlr('mdir'),
        ..._box('ilst', [..._ilstItem('©nam', 'Sample Movie'), ..._ilstItem('©too', 'Lavf60.3.100')]),
      ])),
    ]);

List<int> _mdat([int size = 4096]) => _box('mdat', List.filled(size, 0xAB));

// EBML builders

List<int> _ebmlIdBytes(int id) {
  final bytes = <int>[];
  for (var v = id; v > 0; v >>= 8) {
    bytes.insert(0, v & 0xFF);
  }
  return bytes;
}

List<int> _ebmlSizeBytes(int size) {
  if (size < 0x7F) return [0x80 | size];
  if (size < 0x3FFF) return [0x40 | size >> 8, size & 0xFF];
  return [0x10 | size >> 24 & 0x0F, size >> 16 & 0xFF, size >> 8 & 0xFF, size & 0xFF];
}

const _unknownSize = [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];

List<int> _el(int id, List<int> payload) => [..._ebmlIdBytes(id), ..._ebmlSizeBytes(payload.length), ...payload];
List<int> _uintEl(int id, int value) {
  final bytes = <int>[];
  for (var v = value; v > 0; v >>= 8) {
    bytes.insert(0, v & 0xFF);
  }
  return _el(id, bytes.isEmpty ? [0] : bytes);
}

List<int> _strEl(int id, String value) => _el(id, utf8.encode(value));
List<int> _floatEl(int id, double value) => _el(id, (ByteData(8)..setFloat64(0, value)).buffer.asUint8List());

List<int> _ebmlHeader(String docType) => _el(0x1A45DFA3, [
      ..._uintEl(0x4286, 1),
      ..._uintEl(0x42F7, 1),
      ..._uintEl(0x42F2, 4),
      ..._uintEl(0x42F3, 8),
      ..._strEl(0x4282, docType),
      ..._uintEl(0x4287, 4),
      ..._uintEl(0x4285, 2),
    ]);

List<int> _mkvInfo() => _el(0x1549A966, [
      ..._uintEl(0x2AD7B1, 1000000),
      ..._floatEl(0x4489, 90500.0),
      ..._strEl(0x7BA9, 'Big Buck Bunny'),
      ..._strEl(0x4D80, 'libebml v1.4.4 + libmatroska v1.7.1'),
      ..._strEl(0x5741, 'mkvmerge v80.0'),
    ]);

List<int> _mkvTracks() => _el(0x1654AE6B, [
      ..._el(0xAE, [
        ..._uintEl(0xD7, 1),
        ..._uintEl(0x73C5, 0x1234),
        ..._uintEl(0x83, 1),
        ..._strEl(0x86, 'V_MPEG4/ISO/AVC'),
        ..._uintEl(0x23E383, 41708333),
        ..._strEl(0x22B59C, 'und'),
        ..._el(0xE0, [..._uintEl(0xB0, 1280), ..._uintEl(0xBA, 720)]),
      ]),
      ..._el(0xAE, [
        ..._uintEl(0xD7, 2),
        ..._uintEl(0x83, 2),
        ..._strEl(0x86, 'A_OPUS'),
        ..._strEl(0x22B59C, 'jpn'),
        ..._strEl(0x536E, 'Japanese 5.1'),
        ..._el(0xE1, [..._floatEl(0xB5, 48000.0), ..._uintEl(0x9F, 6)]),
      ]),
      ..._el(0xAE, [
        ..._uintEl(0xD7, 3),
        ..._uintEl(0x83, 17),
        ..._strEl(0x86, 'S_TEXT/UTF8'),
        ..._uintEl(0x88, 0),
        ..._uintEl(0x55AA, 1),
        ..._strEl(0x536E, 'Signs'),
      ]),
    ]);

List<int> _cluster() => _el(0x1F43B675, [..._uintEl(0xE7, 0), ..._el(0xA3, List.filled(64, 0x55))]);

void main() {
  late Directory dir;
  var counter = 0;

  setUpAll(() => dir = Directory.systemTemp.createTempSync('danaview_inspector_test_'));
  tearDownAll(() => dir.deleteSync(recursive: true));

  String write(List<int> bytes, [String extension = 'bin']) {
    final file = File('${dir.path}${Platform.pathSeparator}fixture_${counter++}.$extension')..writeAsBytesSync(bytes);
    return file.path;
  }

  const inspector = MediaInspector();

  void expectMp4Details(MediaFileInfo info) {
    expect(info.container, MediaContainer.mp4);
    expect(info.brand, 'isom');
    expect(info.duration, const Duration(seconds: 60));
    expect(info.title, 'Sample Movie');
    expect(info.encoder, 'Lavf60.3.100');
    expect(info.overallBitrate, (info.sizeBytes * 8 / 60).round());

    final video = info.videoTracks.single;
    expect(video.codec, 'H.264 (AVC)');
    expect(video.codecId, 'avc1');
    expect(video.profile, 'High, Level 4.1');
    expect(video.width, 1920);
    expect(video.height, 1080);
    expect(video.frameRate, closeTo(23.976, 0.001));
    expect(video.bitDepth, 8);
    expect(video.language, isNull);

    final audio = info.audioTracks.single;
    expect(audio.codec, 'AAC');
    expect(audio.profile, 'LC');
    expect(audio.channels, 2);
    expect(audio.sampleRate, 48000);
    expect(audio.language, 'eng');
    expect(audio.bitrate, 128000);
    expect(audio.duration, const Duration(seconds: 60));
    expect(info.subtitleTracks, isEmpty);
  }

  group('MP4', () {
    test('reads a fast-start file (moov before mdat)', () {
      final info = inspector.inspectSync(write([..._ftyp(), ..._moov(), ..._mdat()], 'mp4'));
      expectMp4Details(info);
      expect(info.fastStart, isTrue);
      expect(info.fragmented, isFalse);
      expect(info.warnings, isEmpty);
    });

    test('reads a file with moov at the end', () {
      final info = inspector.inspectSync(write([..._ftyp(), ..._mdat(64 * 1024), ..._moov()]));
      expectMp4Details(info);
      expect(info.fastStart, isFalse);
      expect(info.warnings, isEmpty);
    });

    test('follows 64-bit box sizes', () {
      final moov = _moov();
      final info = inspector.inspectSync(write([
        ..._ftyp(),
        ..._largeBox('mdat', List.filled(10000, 1)),
        ..._largeBox('moov', moov.sublist(8)),
      ]));
      expectMp4Details(info);
      expect(info.fastStart, isFalse);
    });

    test('accepts an mdat that runs to the end of the file (size 0)', () {
      final info = inspector.inspectSync(write([..._ftyp(), ..._moov(), ..._u32(0), ..._ascii('mdat'), 1, 2, 3, 4]));
      expectMp4Details(info);
      expect(info.fastStart, isTrue);
    });

    test('detects the container from the bytes, not the extension', () {
      final info = inspector.inspectSync(write([..._ftyp('qt  '), ..._moov(), ..._mdat()], 'mkv'));
      expect(info.container, MediaContainer.mov);
      expect(info.videoTracks.single.codec, 'H.264 (AVC)');
      expect(info.fileName, endsWith('.mkv'));
    });

    test('reads rotation, HEVC profile, bit depth and HDR signalling', () {
      // Main 10 profile, level 5.1 (153), 10-bit luma and chroma.
      final hvcC = _box('hvcC', [
        1, 0x02, ...List.filled(4, 0), ...List.filled(6, 0), 153, //
        0xF0, 0, 0xFC, 0xFD, 0xFA, 0xFA, 0, 0, 0x0F, 0,
      ]);
      final colr = _box('colr', [..._ascii('nclx'), ..._u16(9), ..._u16(16), ..._u16(9), 0]);
      final moov = _box('moov', [
        ..._mvhd(timescale: 600, duration: 6000),
        ..._trak(
          tkhd: _tkhd(id: 1, duration: 6000, width: 3840, height: 2160, matrix: _rotate90Matrix),
          mdhd: _mdhd(timescale: 30000, duration: 300000),
          handler: 'vide',
          sampleEntry: _visualEntry('hvc1', width: 3840, height: 2160, children: [...hvcC, ...colr]),
          sampleCount: 300,
        ),
      ]);
      final info = inspector.inspectSync(write([..._ftyp(), ...moov, ..._mdat()]));
      final video = info.videoTracks.single;
      expect(video.codec, 'H.265 (HEVC)');
      expect(video.profile, 'Main 10, Level 5.1');
      expect(video.bitDepth, 10);
      expect(video.hdr, 'HDR10');
      expect(video.rotation, 90);
      expect(video.frameRate, 30);
      expect(info.audioTracks, isEmpty);
    });

    test('lists subtitle tracks and skips chapter text tracks', () {
      final moov = _box('moov', [
        ..._mvhd(timescale: 1000, duration: 1000),
        ..._box('trak', [
          ..._tkhd(id: 1, duration: 1000),
          ..._box('tref', _box('chap', _u32(3))),
          ..._box('mdia', [
            ..._mdhd(timescale: 1000, duration: 1000, language: 'eng'),
            ..._hdlr('soun'),
            ..._box('minf', _box('stbl', _fullBox('stsd', [
              ..._u32(1),
              ..._audioEntry('ac-3', channels: 2, sampleRate: 48000, children: _box('dac3', [0x10, 0x3D, 0xC0])),
            ]))),
          ]),
        ]),
        ..._trak(
          tkhd: _tkhd(id: 2, duration: 1000),
          mdhd: _mdhd(timescale: 1000, duration: 1000, language: 'spa'),
          handler: 'sbtl',
          sampleEntry: _box('tx3g', List.filled(38, 0)),
        ),
        ..._trak(
          tkhd: _tkhd(id: 3, duration: 1000),
          mdhd: _mdhd(timescale: 1000, duration: 1000),
          handler: 'text',
          sampleEntry: _box('text', List.filled(16, 0)),
        ),
      ]);
      final info = inspector.inspectSync(write([..._ftyp(), ...moov]));
      expect(info.audioTracks.single.codec, 'AC-3 (Dolby Digital)');
      expect(info.audioTracks.single.channels, 6);
      final subtitle = info.subtitleTracks.single;
      expect(subtitle.codec, 'Timed Text (tx3g)');
      expect(subtitle.language, 'spa');
    });

    test('flags a file without an index', () {
      final info = inspector.inspectSync(write([..._ftyp(), ..._u32(1 << 20), ..._ascii('mdat'), ...List.filled(512, 0)]));
      expect(info.container, MediaContainer.mp4);
      expect(info.tracks, isEmpty);
      expect(info.fastStart, isNull);
      expect(info.warnings.join(' '), contains('no index'));
    });

    test('never throws on a truncated file and keeps what was read', () {
      final full = [..._ftyp(), ..._moov(), ..._mdat()];
      final moovEnd = _ftyp().length + _moov().length;
      for (final cut in [10, 30, 120, moovEnd - 400, moovEnd - 40, moovEnd + 20]) {
        final info = inspector.inspectSync(write(full.sublist(0, cut)));
        expect(info.container, MediaContainer.mp4, reason: 'cut at $cut');
        expect(info.sizeBytes, cut);
        if (cut < moovEnd) expect(info.warnings, isNotEmpty, reason: 'cut at $cut');
      }
    });

    test('never throws on corrupt boxes', () {
      final garbage = List.generate(4096, (i) => (i * 7919 + 13) & 0xFF);
      for (final bytes in [
        [..._ftyp(), ...garbage],
        [..._ftyp(), ..._box('moov', garbage)],
        [..._ftyp(), ..._box('moov', [..._u32(0xFFFFFFF0), ..._ascii('trak'), ...garbage])],
        [..._u32(3), ..._ascii('ftyp'), ...garbage],
      ]) {
        final info = inspector.inspectSync(write(bytes));
        expect(info.container.isIsoBmff, isTrue);
      }
    });

    test('stops at the read limit with a warning', () {
      const small = MediaInspector(maxBytesRead: 1500);
      final info = small.inspectSync(write([..._ftyp(), ..._mdat(), ..._moov()]));
      expect(info.container, MediaContainer.mp4);
      expect(info.warnings.join(' '), contains('Only the first'));
    });
  });

  group('Matroska', () {
    test('reads an unknown-size segment with info and tracks', () {
      final info = inspector.inspectSync(write([
        ..._ebmlHeader('matroska'),
        ..._ebmlIdBytes(0x18538067),
        ..._unknownSize,
        ..._el(0xEC, List.filled(32, 0)), // Void
        ..._mkvInfo(),
        ..._mkvTracks(),
        ..._ebmlIdBytes(0x1F43B675),
        ..._unknownSize,
        ...List.filled(256, 0x42),
      ], 'mkv'));

      expect(info.container, MediaContainer.matroska);
      expect(info.brand, 'matroska');
      expect(info.duration, const Duration(milliseconds: 90500));
      expect(info.title, 'Big Buck Bunny');
      expect(info.encoder, 'mkvmerge v80.0');
      expect(info.fastStart, isNull);
      expect(info.warnings, isEmpty);

      final video = info.videoTracks.single;
      expect(video.codec, 'H.264 (AVC)');
      expect(video.codecId, 'V_MPEG4/ISO/AVC');
      expect(video.width, 1280);
      expect(video.height, 720);
      expect(video.frameRate, closeTo(23.976, 0.001));
      expect(video.language, isNull);
      expect(video.isDefault, isTrue);

      final audio = info.audioTracks.single;
      expect(audio.codec, 'Opus');
      expect(audio.channels, 6);
      expect(audio.sampleRate, 48000);
      expect(audio.language, 'jpn');
      expect(audio.name, 'Japanese 5.1');

      final subtitle = info.subtitleTracks.single;
      expect(subtitle.codec, 'SubRip (SRT)');
      expect(subtitle.language, 'eng');
      expect(subtitle.isForced, isTrue);
      expect(subtitle.isDefault, isFalse);
    });

    test('reads WebM with HDR colour info and an IETF language tag', () {
      final tracks = _el(0x1654AE6B, [
        ..._el(0xAE, [
          ..._uintEl(0xD7, 1),
          ..._uintEl(0x83, 1),
          ..._strEl(0x86, 'V_VP9'),
          ..._el(0xE0, [
            ..._uintEl(0xB0, 3840),
            ..._uintEl(0xBA, 2160),
            ..._el(0x55B0, [..._uintEl(0x55B2, 10), ..._uintEl(0x55BA, 18)]),
          ]),
        ]),
        ..._el(0xAE, [
          ..._uintEl(0xD7, 2),
          ..._uintEl(0x83, 2),
          ..._strEl(0x86, 'A_VORBIS'),
          ..._strEl(0x22B59D, 'pt-BR'),
          ..._el(0xE1, [..._floatEl(0xB5, 44100.0), ..._uintEl(0x9F, 2)]),
        ]),
      ]);
      final segment = [..._mkvInfo(), ...tracks, ..._cluster()];
      final info = inspector.inspectSync(write([..._ebmlHeader('webm'), ..._el(0x18538067, segment)], 'webm'));
      expect(info.container, MediaContainer.webm);
      expect(info.videoTracks.single.codec, 'VP9');
      expect(info.videoTracks.single.bitDepth, 10);
      expect(info.videoTracks.single.hdr, 'HLG');
      expect(info.videoTracks.single.frameRate, isNull);
      expect(info.audioTracks.single.codec, 'Vorbis');
      expect(info.audioTracks.single.language, 'pt-BR');
      expect(info.audioTracks.single.sampleRate, 44100);
    });

    test('finds tracks written after the clusters through the SeekHead', () {
      final info = _mkvInfo();
      final cluster = _cluster();
      // SeekHead positions are relative to the segment data; the SeekHead itself comes first.
      List<int> seekHead(int tracksAt) => _el(0x114D9B74, _el(0x4DBB, [
            ..._el(0x53AB, _ebmlIdBytes(0x1654AE6B)),
            ..._el(0x53AC, _u32(tracksAt)),
          ]));
      final headLength = seekHead(0).length;
      final segment = [...seekHead(headLength + info.length + cluster.length), ...info, ...cluster, ..._mkvTracks()];
      final result = inspector.inspectSync(write([..._ebmlHeader('matroska'), ..._el(0x18538067, segment)]));
      expect(result.tracks, hasLength(3));
      expect(result.warnings, isEmpty);
    });

    test('never throws on truncated or corrupt files', () {
      final full = [..._ebmlHeader('matroska'), ..._ebmlIdBytes(0x18538067), ..._unknownSize, ..._mkvInfo(), ..._mkvTracks()];
      for (var cut = 4; cut < full.length; cut += 37) {
        final info = inspector.inspectSync(write(full.sublist(0, cut)));
        expect(info.container.isMatroska, isTrue, reason: 'cut at $cut');
      }
      final truncatedTracks = inspector.inspectSync(write(full.sublist(0, full.length - 20)));
      expect(truncatedTracks.duration, const Duration(milliseconds: 90500));
      expect(truncatedTracks.videoTracks, hasLength(1));

      final garbage = [..._ebmlHeader('matroska'), ...List.generate(2048, (i) => (i * 31 + 7) & 0xFF)];
      final info = inspector.inspectSync(write(garbage));
      expect(info.container, MediaContainer.matroska);
      expect(info.warnings, isNotEmpty);
    });
  });

  group('other formats', () {
    test('are recognised from their leading bytes', () {
      final samples = <MediaContainer, List<int>>{
        MediaContainer.avi: [..._ascii('RIFF'), ..._u32(1000), ..._ascii('AVI '), ..._ascii('LIST'), ...List.filled(64, 0)],
        MediaContainer.mpegTs: [for (var i = 0; i < 4; i++) ...[0x47, ...List.filled(187, 0xFF)]],
        MediaContainer.bdav: [for (var i = 0; i < 4; i++) ...[0, 0, 0, 0, 0x47, ...List.filled(187, 0xFF)]],
        MediaContainer.mpegPs: [0, 0, 1, 0xBA, ...List.filled(64, 0)],
        MediaContainer.flv: [..._ascii('FLV'), 1, 5, ..._u32(9), ...List.filled(32, 0)],
        MediaContainer.asf: [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, ...List.filled(64, 0)],
        MediaContainer.ogg: [..._ascii('OggS'), ...List.filled(64, 0)],
        MediaContainer.m4a: [..._ftyp('M4A '), ..._mdat(16)],
      };
      for (final MapEntry(key: container, value: bytes) in samples.entries) {
        final info = inspector.inspectSync(write(bytes, 'mp4'));
        expect(info.container, container);
        if (!container.hasTrackDetails) {
          expect(info.tracks, isEmpty);
          expect(info.warnings.single, contains(container.shortName));
        }
      }
    });

    test('unknown and empty files get a note instead of an error', () {
      final unknown = inspector.inspectSync(write(utf8.encode('just some text, not a video')));
      expect(unknown.container, MediaContainer.unknown);
      expect(unknown.warnings, isNotEmpty);

      final empty = inspector.inspectSync(write(const []));
      expect(empty.sizeBytes, 0);
      expect(empty.warnings.single, contains('empty'));
    });
  });

  test('a missing file throws a readable MediaInspectorException', () {
    expect(
      () => inspector.inspectSync('${dir.path}${Platform.pathSeparator}missing.mp4'),
      throwsA(isA<MediaInspectorException>().having((e) => e.message, 'message', contains("isn't available"))),
    );
    expect(() => inspector.inspectSync(dir.path), throwsA(isA<MediaInspectorException>()));
  });

  test('inspect runs on a background isolate', () async {
    final info = await inspector.inspect(write([..._ftyp(), ..._moov(), ..._mdat()]));
    expectMp4Details(info);
    await expectLater(inspector.inspect('${dir.path}/nope.mkv'), throwsA(isA<MediaInspectorException>()));
  });
}
