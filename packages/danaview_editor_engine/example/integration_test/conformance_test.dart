// OWNER: QA-11
//
// Export conformance through the real plugin (BUILD_PLAN QA-11 part 1, ARCH §14.4, §21.1 'Export
// conformance and audio', D-38): MobileEditorEngine.exporter -> Pigeon -> the native exporter
// (iOS IOS-12/IOS-17 reader-writer pipeline; Android AND-11 Transformer), then the output file is
// parsed here, in Dart, box by box, so the same rules hold on both platforms:
//
//   container brand (mp4 / qt), video sample entry `avc1` / `hvc1`, coded size, display size and
//   rotation metadata (tkhd matrix), fps (mdhd timescale / stts delta), frame count =
//   duration × fps ± 1, an AAC (`mp4a`, AudioSpecificConfig) 48 kHz stereo track on EVERY export,
//   audio covering the video (A/V track alignment ≤ 1 frame and ≤ 20 ms), video bitrate within
//   ±25 % of the request, and the hardware-encoder flag (false is allowed only with a visible
//   `softwareEncoder` warning; the iOS simulator is always software, ARCH §14.2).
//
// Fixtures (generated on the device, no bundled media): a moving full-frame noise image (so the
// encoder must spend its bitrate) with a −12 dBFS 1 kHz tone; no audio at all; everything muted
// (clip volumes at 0: segments with zero gain); everything soloed out (export lowering drops every
// segment, CORE-31: assets with audio but `plan.audio` empty); images/text only (image + solids,
// no audio asset). Silent fixtures must still carry the AAC track and measure < −60 dBFS. MOV and
// HEVC rows run where the capabilities allow them. The exported PCM is read back through the
// engine's own speech-audio job (16 kHz s16 mono, sample-accurate, IOS-04/AND-04).
//
//   cd packages/danaview_editor_engine/example
//   flutter test integration_test/conformance_test.dart -d <iOS simulator | Android emulator | device>
//
// This file also holds the QA-11 support code (MP4 box reader, WAV reader, DSP, fixture writers,
// export runner) that preset_matrix_test.dart and audio_mix_test.dart import with a prefix.
// Every measured row is printed as `QA11|…` for docs/v1.1/editor/qa/QA-11-export-audio.md.

// The example host depends on the engine and its API only (ENG-09 owns the pubspec); core is
// reached transitively for the export preset table, TimeRange and the plan types.
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:danaview_editor_core/model.dart' show TimeRange;
import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_example/engine_host.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// =================================================================================================
// QA-11 support: MP4 / MOV box reader
// =================================================================================================

/// One track of an ISO BMFF / QuickTime file, as far as the conformance rules need it.
final class Mp4Track {
  /// Handler type: `vide` or `soun`.
  String handler = '';

  /// Sample entry four-cc (`avc1`, `hvc1`, `mp4a`, …).
  String sampleEntry = '';

  /// tkhd presentation size (16.16 fixed, rounded).
  int tkhdWidth = 0;
  int tkhdHeight = 0;

  /// Coded size from the visual sample entry.
  int codedWidth = 0;
  int codedHeight = 0;

  /// tkhd matrix a, b, c, d (16.16 fixed as doubles).
  List<double> matrix = const [1, 0, 0, 1];

  /// mdhd timescale and duration (media time).
  int timescale = 0;
  int duration = 0;

  /// stts (count, delta) runs.
  final List<(int, int)> stts = [];

  /// stsz sample count and total bytes.
  int sampleCount = 0;
  int sampleBytes = 0;

  /// First edit (elst) media time in media units (-1 = empty edit, null = no edit list).
  int? editMediaTime;

  /// Sum of the non-empty edit durations (movie timescale), null without an edit list.
  int? editDuration;

  /// Empty-edit (delay) durations at the start (movie timescale).
  int editDelay = 0;

  /// Audio: channel count and sample rate from the AudioSpecificConfig (else the sample entry).
  int channels = 0;
  int sampleRate = 0;

  /// Audio: AAC audio object type (2 = AAC-LC) from the AudioSpecificConfig, 0 when absent.
  int audioObjectType = 0;

  /// Duration in µs from mdhd.
  int get durationUs => timescale == 0 ? 0 : (duration * 1000000 / timescale).round();

  /// The most common stts delta (the frame duration of a constant-rate video track).
  int get dominantDelta {
    var best = 0, bestCount = -1;
    for (final (count, delta) in stts) {
      if (count > bestCount) {
        best = delta;
        bestCount = count;
      }
    }
    return best;
  }

  /// Average frame rate (samples / stts duration). A timescale that does not divide by the rate
  /// (48 fps at 600) alternates deltas of 12 and 13 ticks, so the dominant delta is not the rate.
  double get fps {
    var ticks = 0, samples = 0;
    for (final (count, delta) in stts) {
      ticks += count * delta;
      samples += count;
    }
    return ticks == 0 ? 0 : samples * timescale / ticks;
  }

  /// Largest minus smallest stts delta (≤ 1 tick for a constant-rate track).
  int get deltaSpread {
    if (stts.isEmpty) return 0;
    final ds = stts.map((e) => e.$2);
    return ds.reduce(math.max) - ds.reduce(math.min);
  }

  /// Rotation of the display matrix in degrees (0, 90, 180, 270).
  int get rotation {
    final deg = (math.atan2(matrix[1], matrix[0]) * 180 / math.pi).round();
    return ((deg % 360) + 360) % 360;
  }

  /// Display size after the rotation metadata.
  (int, int) get displaySize => rotation == 90 || rotation == 270 ? (codedHeight, codedWidth) : (codedWidth, codedHeight);
}

/// The facts of one output file.
final class Mp4Facts {
  /// ftyp major brand.
  String majorBrand = '';

  /// ftyp compatible brands.
  final List<String> compatibleBrands = [];

  /// mvhd timescale.
  int movieTimescale = 0;

  /// Tracks in file order.
  final List<Mp4Track> tracks = [];

  /// The video tracks.
  Iterable<Mp4Track> get videoTracks => tracks.where((t) => t.handler == 'vide');

  /// The audio tracks.
  Iterable<Mp4Track> get audioTracks => tracks.where((t) => t.handler == 'soun');

  /// Presentation duration of [t] in µs: its edit list (movie timescale) when present, else mdhd.
  int presentationUs(Mp4Track t) {
    final e = t.editDuration;
    if (e == null || movieTimescale == 0) return t.durationUs;
    return (e * 1000000 / movieTimescale).round();
  }

  /// Presentation start of [t] in µs (leading empty edits).
  int startUs(Mp4Track t) => movieTimescale == 0 ? 0 : (t.editDelay * 1000000 / movieTimescale).round();
}

/// Reads an MP4 / MOV file's box structure (ISO/IEC 14496-12 and QuickTime; 32/64-bit sizes,
/// version 0/1 full boxes, sound sample description versions 0/1/2).
Mp4Facts readMp4(Uint8List bytes) {
  final facts = Mp4Facts();
  final bd = ByteData.sublistView(bytes);
  String fourcc(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  int u32(int at) => bd.getUint32(at);
  int u64(int at) => bd.getUint32(at) * 4294967296 + bd.getUint32(at + 4);
  double fixed16(int at) => bd.getInt32(at) / 65536.0;

  void walk(int start, int end, Mp4Track? track) {
    var at = start;
    while (at + 8 <= end) {
      var size = u32(at);
      final type = fourcc(at + 4);
      var header = 8;
      if (size == 1) {
        size = u64(at + 8);
        header = 16;
      } else if (size == 0) {
        size = end - at;
      }
      if (size < header || at + size > end) break;
      final body = at + header;
      final boxEnd = at + size;
      switch (type) {
        case 'ftyp':
          facts.majorBrand = fourcc(body);
          for (var p = body + 8; p + 4 <= boxEnd; p += 4) {
            facts.compatibleBrands.add(fourcc(p));
          }
        case 'moov' || 'mdia' || 'minf' || 'stbl' || 'edts':
          walk(body, boxEnd, track);
        case 'trak':
          final t = Mp4Track();
          facts.tracks.add(t);
          walk(body, boxEnd, t);
        case 'mvhd':
          facts.movieTimescale = bytes[body] == 1 ? u32(body + 20) : u32(body + 12);
        case 'tkhd':
          if (track != null) {
            final v1 = bytes[body] == 1;
            final m = body + (v1 ? 4 + 32 : 4 + 20) + 8 + 8; // after duration, reserved, layer..volume
            track.matrix = [fixed16(m), fixed16(m + 4), fixed16(m + 12), fixed16(m + 16)];
            track.tkhdWidth = fixed16(m + 36).round();
            track.tkhdHeight = fixed16(m + 40).round();
          }
        case 'mdhd':
          if (track != null) {
            if (bytes[body] == 1) {
              track.timescale = u32(body + 20);
              track.duration = u64(body + 24);
            } else {
              track.timescale = u32(body + 12);
              track.duration = u32(body + 16);
            }
          }
        case 'hdlr':
          // The first hdlr of a trak is the media handler (mdia); QuickTime adds a data handler
          // (`alis`/`url `) inside minf, which must not overwrite it.
          if (track != null && track.handler.isEmpty) track.handler = fourcc(body + 8);
        case 'elst':
          if (track != null && u32(body + 4) > 0) {
            final v1 = bytes[body] == 1;
            final n = u32(body + 4);
            final entry = v1 ? 20 : 12;
            var sum = 0;
            for (var i = 0; i < n; i++) {
              final e = body + 8 + i * entry;
              final dur = v1 ? u64(e) : u32(e);
              final mediaTime = v1 ? bd.getInt64(e + 8) : bd.getInt32(e + 4);
              if (mediaTime == -1) {
                if (sum == 0) track.editDelay += dur;
              } else {
                track.editMediaTime ??= mediaTime;
                sum += dur;
              }
            }
            track.editDuration = sum;
          }
        case 'stts':
          if (track != null) {
            final n = u32(body + 4);
            for (var i = 0; i < n; i++) {
              track.stts.add((u32(body + 8 + i * 8), u32(body + 12 + i * 8)));
            }
          }
        case 'stsz':
          if (track != null) {
            final fixed = u32(body + 4);
            final n = u32(body + 8);
            track.sampleCount = n;
            if (fixed != 0) {
              track.sampleBytes = fixed * n;
            } else {
              var sum = 0;
              for (var i = 0; i < n; i++) {
                sum += u32(body + 12 + i * 4);
              }
              track.sampleBytes = sum;
            }
          }
        case 'stsd':
          if (track != null && u32(body + 4) > 0) _readSampleEntry(bytes, body + 8, track);
        default:
          break;
      }
      at = boxEnd;
    }
  }

  walk(0, bytes.length, null);
  return facts;
}

const List<int> _aacRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

void _readSampleEntry(Uint8List bytes, int at, Mp4Track track) {
  final bd = ByteData.sublistView(bytes);
  final size = bd.getUint32(at);
  final type = String.fromCharCodes(bytes.sublist(at + 4, at + 8));
  track.sampleEntry = type;
  final end = math.min(bytes.length, at + size);
  if (track.handler == 'vide') {
    // SampleEntry (8) + reserved/data ref (8) + pre_defined/reserved (16) then width, height.
    track.codedWidth = bd.getUint16(at + 8 + 8 + 16);
    track.codedHeight = bd.getUint16(at + 8 + 8 + 18);
    return;
  }
  if (track.handler != 'soun') return;
  final version = bd.getUint16(at + 16);
  if (version == 2) {
    // QuickTime SoundDescription v2: rate as float64, channels as u32.
    track.sampleRate = bd.getFloat64(at + 40).round();
    track.channels = bd.getUint32(at + 48);
  } else {
    track.channels = bd.getUint16(at + 8 + 8 + 8);
    track.sampleRate = bd.getUint32(at + 8 + 8 + 8 + 8) >> 16;
  }
  // AudioSpecificConfig from the esds descriptors (authoritative for AAC).
  for (var p = at + 8; p + 8 <= end; p++) {
    if (bytes[p] == 0x65 && bytes[p + 1] == 0x73 && bytes[p + 2] == 0x64 && bytes[p + 3] == 0x73) {
      final asc = _audioSpecificConfig(bytes, p + 8, end);
      if (asc != null) {
        track.audioObjectType = asc.$1;
        track.sampleRate = asc.$2;
        track.channels = asc.$3;
      }
      break;
    }
  }
}

/// (audio object type, sample rate, channels) from an esds payload starting at [at].
(int, int, int)? _audioSpecificConfig(Uint8List b, int at, int end) {
  var p = at;
  (int, int) descriptor(int pos) {
    // tag, then a 1–4 byte size with continuation bits.
    var q = pos + 1;
    var len = 0;
    for (var i = 0; i < 4; i++) {
      final c = b[q++];
      len = (len << 7) | (c & 0x7f);
      if (c & 0x80 == 0) break;
    }
    return (q, len);
  }

  if (p >= end || b[p] != 0x03) return null;
  var (q, _) = descriptor(p);
  final flags = b[q + 2];
  q += 3;
  if (flags & 0x80 != 0) q += 2;
  if (flags & 0x40 != 0) q += 1 + b[q];
  if (flags & 0x20 != 0) q += 2;
  if (q >= end || b[q] != 0x04) return null;
  (p, _) = descriptor(q);
  p += 13;
  if (p >= end || b[p] != 0x05) return null;
  (p, _) = descriptor(p);
  if (p + 2 > end) return null;
  final bits = (b[p] << 24) | (b[p + 1] << 16) | ((p + 2 < end ? b[p + 2] : 0) << 8) | (p + 3 < end ? b[p + 3] : 0);
  var aot = bits >>> 27;
  var cursor = 5;
  if (aot == 31) {
    aot = 32 + ((bits >>> 21) & 0x3f);
    cursor = 11;
  }
  final freqIndex = (bits >>> (32 - cursor - 4)) & 0xf;
  cursor += 4;
  int rate;
  if (freqIndex == 0xf) {
    // 24-bit explicit rate: read from the following bytes.
    final bitPos = p * 8 + cursor;
    var v = 0;
    for (var i = 0; i < 24; i++) {
      final pos = bitPos + i;
      v = (v << 1) | ((b[pos >> 3] >> (7 - (pos & 7))) & 1);
    }
    rate = v;
    cursor += 24;
  } else {
    rate = freqIndex < _aacRates.length ? _aacRates[freqIndex] : 0;
  }
  final chanPos = p * 8 + cursor;
  var ch = 0;
  for (var i = 0; i < 4; i++) {
    final pos = chanPos + i;
    ch = (ch << 1) | ((b[pos >> 3] >> (7 - (pos & 7))) & 1);
  }
  return (aot, rate, ch);
}

// =================================================================================================
// QA-11 support: WAV, PNG and DSP
// =================================================================================================

/// Mono or interleaved PCM read from a canonical WAV.
final class WavData {
  /// Creates the data.
  const WavData(this.sampleRate, this.channels, this.samples);

  /// Sample rate.
  final int sampleRate;

  /// Channels.
  final int channels;

  /// Interleaved samples in [-1, 1].
  final Float64List samples;

  /// Frames.
  int get frames => samples.length ~/ channels;

  /// Channel [c] alone (or the 0.5/0.5 mix of a stereo file when [c] is null).
  Float64List mono([int? c]) {
    if (channels == 1) return samples;
    final out = Float64List(frames);
    for (var i = 0; i < frames; i++) {
      out[i] = c == null ? 0.5 * (samples[2 * i] + samples[2 * i + 1]) : samples[i * channels + c];
    }
    return out;
  }
}

/// Reads a RIFF/WAVE file (PCM s16 or float32).
WavData readWav(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') throw const FormatException('not RIFF');
  var at = 12;
  var rate = 0, channels = 0, bits = 0, format = 0;
  while (at + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(at, at + 4));
    final size = bd.getUint32(at + 4, Endian.little);
    final body = at + 8;
    if (id == 'fmt ') {
      format = bd.getUint16(body, Endian.little);
      channels = bd.getUint16(body + 2, Endian.little);
      rate = bd.getUint32(body + 4, Endian.little);
      bits = bd.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      final usable = math.min(size, bytes.length - body);
      if (format == 3 && bits == 32) {
        final n = usable ~/ 4;
        final out = Float64List(n);
        for (var i = 0; i < n; i++) {
          out[i] = bd.getFloat32(body + i * 4, Endian.little);
        }
        return WavData(rate, channels, out);
      }
      if (bits != 16) throw FormatException('unsupported WAV bits $bits');
      final n = usable ~/ 2;
      final out = Float64List(n);
      for (var i = 0; i < n; i++) {
        out[i] = bd.getInt16(body + i * 2, Endian.little) / 32768.0;
      }
      return WavData(rate, channels, out);
    }
    at = body + size + (size & 1);
  }
  throw const FormatException('no data chunk');
}

/// A mono s16 WAV of a sine: [freqHz] at [amplitude] (−12 dBFS = 0.2512) for [seconds].
/// Returns the quantized samples (what the engine decodes) with the file.
Float32List writeToneWav(String path, double freqHz, {double amplitude = 0.251188643, double seconds = 10, int rate = 48000}) {
  final n = (seconds * rate).round();
  final pcm = Float32List(n);
  final data = ByteData(44 + n * 2);
  void str(int at, String s) {
    for (var i = 0; i < 4; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (amplitude * math.sin(2 * math.pi * freqHz * i / rate) * 32767).round().clamp(-32768, 32767);
    data.setInt16(44 + i * 2, v, Endian.little);
    pcm[i] = v / 32768.0;
  }
  File(path).writeAsBytesSync(data.buffer.asUint8List(), flush: true);
  return pcm;
}

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    t[n] = c;
  }
  return t;
}();

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// An RGB PNG of deterministic per-pixel noise ([side]×[side]); full-frame detail that keeps the
/// encoder at its requested bitrate when it moves.
void writeNoisePng(String path, {int side = 1280, int seed = 0x5eed}) {
  final raw = Uint8List(side * (side * 3 + 1));
  var x = seed;
  var p = 0;
  for (var y = 0; y < side; y++) {
    raw[p++] = 0; // filter: none
    for (var i = 0; i < side * 3; i++) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      raw[p++] = (x >> 16) & 0xff;
    }
  }
  final idat = ZLibEncoder(level: 1).convert(raw);
  final out = BytesBuilder();
  void chunk(String type, List<int> body) {
    final len = ByteData(4)..setUint32(0, body.length);
    out.add(len.buffer.asUint8List());
    final tb = [...type.codeUnits, ...body];
    out.add(tb);
    final crc = ByteData(4)..setUint32(0, _crc32(tb));
    out.add(crc.buffer.asUint8List());
  }

  out.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = ByteData(13)
    ..setUint32(0, side)
    ..setUint32(4, side)
    ..setUint8(8, 8)
    ..setUint8(9, 2)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', idat);
  chunk('IEND', const []);
  File(path).writeAsBytesSync(out.toBytes(), flush: true);
}

/// dBFS of an RMS (floored at −120).
double dbOf(double rms) => rms > 0 ? math.max(-120, 20 * math.log(rms) / math.ln10) : -120;

/// RMS of `x[from, to)`.
double rmsOf(Float64List x, [int from = 0, int? to]) {
  final end = math.min(to ?? x.length, x.length);
  if (end <= from) return 0;
  var s = 0.0;
  for (var i = from; i < end; i++) {
    s += x[i] * x[i];
  }
  return math.sqrt(s / (end - from));
}

/// RMS per window of [windowSamples] (the last partial window dropped).
List<double> windowRms(Float64List x, int windowSamples) => [
      for (var w = 0; (w + 1) * windowSamples <= x.length; w++) rmsOf(x, w * windowSamples, (w + 1) * windowSamples),
    ];

/// Peak amplitude (dBFS) of a sine at [freqHz] in `x[from, to)` (Hann-windowed Goertzel; ≈ −6 dB
/// per halving of the amplitude, a −12 dBFS tone reads −12).
double toneLevelDb(Float64List x, double freqHz, int sampleRate, [int from = 0, int? to]) {
  final end = math.min(to ?? x.length, x.length);
  final n = end - from;
  if (n <= 0) return -120;
  var re = 0.0, im = 0.0, wsum = 0.0;
  final w0 = 2 * math.pi * freqHz / sampleRate;
  for (var i = 0; i < n; i++) {
    final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
    final v = x[from + i] * w;
    re += v * math.cos(w0 * i);
    im -= v * math.sin(w0 * i);
    wsum += w;
  }
  final amp = 2 * math.sqrt(re * re + im * im) / wsum;
  return dbOf(amp);
}

/// Frequency of the dominant FFT bin of `x[from, from + 2^k)` (Hann window, parabolic peak
/// interpolation).
double dominantFrequency(Float64List x, int sampleRate, {int from = 0, int log2n = 14}) {
  final n = 1 << log2n;
  final re = Float64List(n), im = Float64List(n);
  for (var i = 0; i < n; i++) {
    final v = from + i < x.length ? x[from + i] : 0.0;
    re[i] = v * (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1)));
  }
  // Iterative radix-2 FFT.
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    for (var i = 0; i < n; i += len) {
      for (var k = 0; k < len ~/ 2; k++) {
        final c = math.cos(ang * k), s = math.sin(ang * k);
        final a = i + k, b = i + k + len ~/ 2;
        final tr = re[b] * c - im[b] * s;
        final ti = re[b] * s + im[b] * c;
        re[b] = re[a] - tr;
        im[b] = im[a] - ti;
        re[a] += tr;
        im[a] += ti;
      }
    }
  }
  var best = 1;
  var bestMag = -1.0;
  final mags = Float64List(n ~/ 2);
  for (var k = 1; k < n ~/ 2; k++) {
    mags[k] = math.sqrt(re[k] * re[k] + im[k] * im[k]);
    if (mags[k] > bestMag) {
      bestMag = mags[k];
      best = k;
    }
  }
  var offset = 0.0;
  if (best > 1 && best < n ~/ 2 - 1) {
    final a = mags[best - 1], b = mags[best], c = mags[best + 1];
    final d = a - 2 * b + c;
    if (d != 0) offset = 0.5 * (a - c) / d;
  }
  return (best + offset) * sampleRate / n;
}

/// The pure-tone predictor residual `e[i] = x[i] − 2cos(ω)·x[i−1] + x[i−2]` (0 for a steady sine
/// at [freqHz], ≈ the jump at a discontinuity; the IOS-18 click metric).
Float64List toneResidual(Float64List x, double freqHz, int sampleRate) {
  final k = 2 * math.cos(2 * math.pi * freqHz / sampleRate);
  final e = Float64List(x.length);
  for (var i = 2; i < x.length; i++) {
    e[i] = x[i] - k * x[i - 1] + x[i - 2];
  }
  return e;
}

/// Largest |x| in `[from, to)`.
double maxAbs(Float64List x, int from, int to) {
  var m = 0.0;
  for (var i = math.max(0, from); i < math.min(to, x.length); i++) {
    m = math.max(m, x[i].abs());
  }
  return m;
}

// =================================================================================================
// QA-11 support: plans and the export runner
// =================================================================================================

/// Builds plan JSON maps (RenderPlan v1, ARCH §11; the same shapes CORE-30/31 lower to).
abstract final class PlanJsonKit {
  /// An image asset.
  static Map<String, Object?> imageAsset(String path, int w, int h) =>
      {'kind': 'image', 'uri': Uri.file(path).toString(), 'fp': 'fp_${path.hashCode.toUnsigned(32)}', 'w': w, 'h': h};

  /// An audio asset.
  static Map<String, Object?> audioAsset(String path, int durUs) =>
      {'kind': 'audio', 'uri': Uri.file(path).toString(), 'fp': 'fp_${path.hashCode.toUnsigned(32)}', 'durUs': durUs, 'hasAudio': true};

  /// A solid layer.
  static Map<String, Object?> solid(String id, int z, String color, int t0, int t1, double w, double h, double cx, double cy) => {
        'id': id,
        'z': z,
        't': [t0, t1],
        'kind': 'solid',
        'color': color,
        'base': [w, h],
        'xf': {'cx': cx, 'cy': cy},
      };

  /// A full-frame image layer [side]² that drifts horizontally across `[t0, t1)` (every frame
  /// differs, so the encoder spends its bitrate).
  static Map<String, Object?> movingImage(String id, String asset, int t0, int t1, int canvasW, int canvasH) {
    final side = 1.3 * math.max(canvasW, canvasH);
    final drift = 0.1 * canvasW;
    return {
      'id': id,
      'z': 0,
      't': [t0, t1],
      'kind': 'image',
      'asset': asset,
      'base': [side, side],
      'xf': {'cx': canvasW / 2, 'cy': canvasH / 2},
      'anim': {
        'xf.cx': [
          [t0, canvasW / 2 - drift],
          [t1, canvasW / 2 + drift],
        ],
      },
    };
  }

  /// An audio segment: `map` entries are `[t0, t1, s0, s1]`, `gain` entries `[tUs, gain]`.
  static Map<String, Object?> audioSeg(String id, String asset, List<List<int>> map, List<List<num>> gain, {bool pitch = true}) => {
        'id': id,
        'asset': asset,
        't': [map.first[0], map.last[1]],
        'map': map,
        'gain': gain,
        if (!pitch) 'pitch': false,
      };

  /// An export plan.
  static RenderPlan plan({
    required int w,
    required int h,
    required int fps,
    required int durUs,
    Map<String, Object?> assets = const {},
    List<Map<String, Object?>> layers = const [],
    List<Map<String, Object?>> audio = const [],
  }) =>
      PlanTransport.decodePlan(Uint8List.fromList(utf8.encode(jsonEncode({
        'v': 1,
        'rev': 1,
        'target': 'export',
        'canvas': {'w': w, 'h': h, 'fps': fps, 'bg': '#000000FF'},
        'durUs': durUs,
        'assets': assets,
        'layers': layers,
        'audio': audio,
      }))));
}

/// One finished (or visibly refused) export.
final class ExportRun {
  /// Creates the run.
  ExportRun({required this.name, required this.settings, this.result, this.failure, this.warnings = const {}, this.facts, this.wallMs = 0});

  /// Row name.
  final String name;

  /// Settings requested.
  final EncodeSettings settings;

  /// The result (null when [failure]).
  final ExportResult? result;

  /// A visible engine failure.
  final EngineFailure? failure;

  /// Warning codes from preflight and progress.
  final Set<String> warnings;

  /// Parsed output.
  final Mp4Facts? facts;

  /// Wall time of the export.
  final int wallMs;
}

/// Side of the noise picture. Upscaled about 2× at 1080p and drifting, it is detailed enough that
/// the encoder spends its whole budget at every preset, yet encodable at the requested rates
/// (per-pixel noise at the output resolution is incompressible and makes every encoder overshoot).
const int noiseSide = 640;

/// The engine, its roots and the generated fixtures of one test.
final class Qa11Env {
  Qa11Env._(this.base, this.engine, this.caps);

  /// Creates the environment (null when the engine is not supported here).
  static Future<Qa11Env?> open(Directory base) async {
    final engine = createExampleEngine(base: base);
    final caps = await engine.capabilities().timeout(const Duration(seconds: 30));
    if (!caps.supported) {
      debugPrint('QA11 engine not supported here (${caps.unsupportedReason}); skipping');
      return null;
    }
    return Qa11Env._(base, engine, caps);
  }

  /// Temp root.
  final Directory base;

  /// The engine.
  final MobileEditorEngine engine;

  /// Its capabilities.
  final EditorCapabilities caps;

  /// `<cache>/danaview/editor` (as `createExampleEngine` lays it out).
  String get cacheRoot => '${base.path}/cache/danaview/editor';

  /// Scratch directory for fixtures and outputs (inside the cache root, so the engine may write).
  String get work {
    final d = Directory('$cacheRoot/work/qa11')..createSync(recursive: true);
    return d.path;
  }

  /// Whether this is an iOS simulator (software encoders only).
  static bool get isIosSimulator =>
      Platform.isIOS &&
      (Platform.environment.containsKey('SIMULATOR_DEVICE_NAME') || Directory.systemTemp.path.contains('/CoreSimulator/'));

  final Map<String, Float32List> _tones = {};
  String? _noise;

  /// A mono 48 kHz −12 dBFS tone WAV of [freqHz] (10 s); its quantized PCM in [toneSamples].
  String tone(double freqHz) {
    final path = '$work/tone_${freqHz.round()}hz.wav';
    if (!_tones.containsKey(path)) _tones[path] = writeToneWav(path, freqHz);
    return path;
  }

  /// The PCM written for [tone]'s file.
  Float32List toneSamples(String path) => _tones[path]!;

  /// The noise PNG ([noiseSide]²).
  String get noise => _noise ??= () {
        final path = '$work/noise_$noiseSide.png';
        writeNoisePng(path, side: noiseSide);
        return path;
      }();

  /// Exports [plan] with [settings]; a visible engine failure is returned in the run (callers
  /// decide whether it is allowed). The output is parsed when present.
  Future<ExportRun> export(String name, RenderPlan plan, EncodeSettings settings, {Duration timeout = const Duration(minutes: 6)}) async {
    final ext = settings.container == ExportContainer.mov ? 'mov' : 'mp4';
    final out = '$work/export-$name.$ext';
    final warnings = <String>{};
    final sw = Stopwatch()..start();
    try {
      final pre = await engine.exporter.preflight(plan, settings).timeout(const Duration(seconds: 60));
      warnings.addAll(pre.warnings.map((w) => w.code));
      final job = await engine.exporter.start(plan, settings, outputPath: out, title: 'QA-11 $name',
          whenDetached: ExportDetachedHandoff.keepForLater);
      final sub = job.progress.listen((p) => warnings.addAll(p.warnings.map((w) => w.code)));
      try {
        final result = await job.result.timeout(timeout);
        final facts = readMp4(File(result.path).readAsBytesSync());
        return ExportRun(name: name, settings: settings, result: result, warnings: warnings, facts: facts, wallMs: sw.elapsedMilliseconds);
      } finally {
        await sub.cancel();
      }
    } on EngineFailure catch (f) {
      return ExportRun(name: name, settings: settings, failure: f, warnings: warnings, wallMs: sw.elapsedMilliseconds);
    }
  }

  /// The export's audio as 16 kHz mono through the engine's speech-audio job (sample 0 = 0 µs).
  Future<(WavData, ExtractedSpeechAudio)> pcmOf(ExportRun run) async {
    final r = run.result!;
    final out = '$work/pcm-${run.name}.wav';
    final job = engine.jobs.extractSpeechAudio(SpeechAudioJobRequest(
      media: ResolvedMedia(uri: Uri.file(r.path).toString(), fingerprint: 'qa11_${run.name}'),
      range: TimeRange(0, r.duration),
      outputPath: out,
    ));
    final x = await job.result.timeout(const Duration(minutes: 2));
    return (readWav(File(x.path).readAsBytesSync()), x);
  }

  /// Deletes an output (keeps the scratch directory small on the 8 GB machines).
  void discard(ExportRun run) {
    final p = run.result?.path;
    if (p != null) {
      try {
        File(p).deleteSync();
      } on FileSystemException {
        // already gone
      }
    }
  }
}

/// Measured conformance values of one export (one report row).
final class ConformanceRow {
  /// Creates a row.
  ConformanceRow(this.values);

  /// Column -> value.
  final Map<String, Object?> values;

  /// `QA11|<kind>|k=v|…` line.
  String line(String kind) => 'QA11|$kind|${values.entries.map((e) => '${e.key}=${e.value}').join('|')}';
}

/// Checks the §14.4 conformance rules on [run] (it must have a result) and returns the measured
/// row. [checkBitrate] is false for content that cannot fill the bitrate (solids only).
ConformanceRow checkConformance(ExportRun run, {required int planDurUs, bool checkBitrate = true}) {
  final s = run.settings;
  final r = run.result!;
  final f = run.facts!;
  final name = run.name;

  // Container.
  if (s.container == ExportContainer.mov) {
    expect(f.majorBrand, 'qt  ', reason: '$name: MOV brand');
  } else {
    expect(f.majorBrand == 'qt  ', isFalse, reason: '$name: MP4 brand ${f.majorBrand}');
    expect(['mp42', 'isom', 'mp41', 'iso6', 'iso5', 'iso4', 'avc1'], contains(f.majorBrand), reason: '$name: MP4 brand');
  }

  // Exactly one video and one audio track.
  expect(f.videoTracks.length, 1, reason: '$name: video tracks');
  expect(f.audioTracks.length, 1, reason: '$name: every export has an audio track (D-38)');
  final v = f.videoTracks.single;
  final a = f.audioTracks.single;

  // Codec. A HEVC request may fall back to H.264 only with a visible warning.
  final wantHevc = s.codec == VideoCodec.hevc;
  if (wantHevc && v.sampleEntry == 'avc1') {
    expect(run.warnings, contains('hevcUnavailable'), reason: '$name: silent HEVC fallback');
  } else {
    expect(v.sampleEntry, wantHevc ? 'hvc1' : 'avc1', reason: '$name: video sample entry');
  }

  // Size and orientation: the display size is the requested size; a rotated layout (portrait
  // refused by the encoder, ARCH §14.1) must be announced.
  final (dw, dh) = v.displaySize;
  expect((dw, dh), (s.width, s.height), reason: '$name: display size (coded ${v.codedWidth}x${v.codedHeight}, rotation ${v.rotation})');
  expect([0, 90, 180, 270], contains(v.rotation));
  final rotated = v.rotation != 0;
  if (rotated) {
    expect(run.warnings, contains('portraitRetried'), reason: '$name: a rotated layout must be visible');
    expect(v.rotation == 90 || v.rotation == 270, isTrue);
  }

  // Frame rate and frame count.
  expect(v.fps, closeTo(s.fps, 0.05), reason: '$name: fps');
  expect(v.deltaSpread, lessThanOrEqualTo(1), reason: '$name: constant frame rate (stts ${v.stts})');
  final durUs = r.duration;
  expect((durUs - planDurUs).abs(), lessThanOrEqualTo(1000000 ~/ s.fps), reason: '$name: result duration');
  final expectedFrames = durUs * s.fps / 1e6;
  expect((v.sampleCount - expectedFrames).abs(), lessThanOrEqualTo(1.0), reason: '$name: frame count ${v.sampleCount} vs $expectedFrames');
  expect((f.presentationUs(v) - durUs).abs(), lessThanOrEqualTo(1000000 ~/ s.fps), reason: '$name: video track duration');

  // Audio: AAC-LC 48 kHz stereo, covering the video (offset ≤ 1 frame and ≤ 20 ms).
  expect(a.sampleEntry, 'mp4a', reason: '$name: audio sample entry');
  expect(a.audioObjectType, 2, reason: '$name: AAC-LC');
  expect(a.sampleRate, 48000, reason: '$name: audio rate');
  expect(a.channels, 2, reason: '$name: stereo');
  final frameUs = 1000000 ~/ s.fps;
  final avTolUs = math.min(frameUs, 20000);
  final audioUs = f.presentationUs(a), videoUs = f.presentationUs(v);
  final avStartUs = (f.startUs(a) - f.startUs(v)).abs();
  final avGapUs = (audioUs - videoUs).abs();
  expect(avStartUs, lessThanOrEqualTo(avTolUs), reason: '$name: audio starts ${f.startUs(a)} µs, video ${f.startUs(v)} µs');
  expect(avGapUs, lessThanOrEqualTo(avTolUs), reason: '$name: audio $audioUs µs vs video $videoUs µs (media ${a.durationUs} / ${v.durationUs})');

  // Bitrate within ±25 %.
  final videoBps = v.sampleBytes * 8 * 1e6 / v.durationUs;
  final ratio = videoBps / s.videoBitrate;
  if (checkBitrate) {
    expect(ratio, inInclusiveRange(0.75, 1.25), reason: '$name: video bitrate ${(videoBps / 1e6).toStringAsFixed(2)} Mbps vs ${s.videoBitrate / 1e6} Mbps');
  }

  // Hardware encoder flag: software only visibly; the iOS simulator is always software.
  if (!r.hardwareEncoder) {
    expect(run.warnings, contains('softwareEncoder'), reason: '$name: a software encoder must be announced');
  }
  if (Qa11Env.isIosSimulator) expect(r.hardwareEncoder, isFalse, reason: '$name: simulator encoders are software');
  expect(r.bytes, File(r.path).lengthSync());

  return ConformanceRow({
    'name': name,
    'container': f.majorBrand.trim(),
    'codec': v.sampleEntry,
    'coded': '${v.codedWidth}x${v.codedHeight}',
    'rotation': v.rotation,
    'display': '${dw}x$dh',
    'fps': v.fps.toStringAsFixed(2),
    'frames': v.sampleCount,
    'expectedFrames': expectedFrames.toStringAsFixed(1),
    'durUs': durUs,
    'audio': '${a.sampleEntry}/aot${a.audioObjectType}/${a.sampleRate}/${a.channels}ch',
    'avGapMs': (avGapUs / 1000).toStringAsFixed(1),
    'avStartMs': (avStartUs / 1000).toStringAsFixed(1),
    'audioMediaUs': a.durationUs,
    'videoMbps': (videoBps / 1e6).toStringAsFixed(2),
    'targetMbps': (s.videoBitrate / 1e6).toStringAsFixed(2),
    'bitrateRatio': ratio.toStringAsFixed(3),
    'bitrateChecked': checkBitrate,
    'hw': r.hardwareEncoder,
    'encoder': r.videoEncoderName,
    'warnings': (run.warnings.toList()..sort()).join(','),
    'wallMs': run.wallMs,
  });
}

// =================================================================================================
// Conformance tests
// =================================================================================================

const int _w = 1280;
const int _h = 720;
const int _fps = 30;
const int _durUs = 3000000;

EncodeSettings _settings({ExportContainer container = ExportContainer.mp4, VideoCodec codec = VideoCodec.h264}) =>
    EncodeSettings(container: container, codec: codec, width: _w, height: _h, fps: _fps, videoBitrate: 5000000, audioBitrate: 192000);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('danaview_qa11_conf'));
  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  group('support self-checks', () {
    test('DSP: tone level, dominant frequency and click residual', () {
      const sr = 16000;
      final x = Float64List(sr * 2);
      for (var i = 0; i < x.length; i++) {
        x[i] = 0.251188643 * math.sin(2 * math.pi * 1000 * i / sr) + 0.01 * math.sin(2 * math.pi * 440 * i / sr);
      }
      expect(toneLevelDb(x, 1000, sr), closeTo(-12, 0.1));
      expect(toneLevelDb(x, 440, sr), closeTo(-40, 0.3));
      expect(toneLevelDb(x, 3000, sr), lessThan(-90));
      expect(dominantFrequency(x, sr), closeTo(1000, 1));
      expect(dbOf(rmsOf(x)), closeTo(-15.0, 0.1));
      final steady = Float64List(sr);
      for (var i = 0; i < sr; i++) {
        steady[i] = 0.25 * math.sin(2 * math.pi * 1000 * i / sr + (i >= sr ~/ 2 ? math.pi / 2 : 0));
      }
      final e = toneResidual(steady, 1000, sr);
      expect(maxAbs(e, 2, sr ~/ 2 - 1), lessThan(1e-9));
      expect(maxAbs(e, sr ~/ 2 - 2, sr ~/ 2 + 3), greaterThan(0.1));
    });

    test('fixture writers: WAV round trip and PNG header', () {
      final dir = Directory.systemTemp.createTempSync('qa11_support');
      try {
        final pcm = writeToneWav('${dir.path}/t.wav', 1000, seconds: 0.5);
        final wav = readWav(File('${dir.path}/t.wav').readAsBytesSync());
        expect(wav.sampleRate, 48000);
        expect(wav.channels, 1);
        expect(wav.frames, 24000);
        expect(wav.samples[100], closeTo(pcm[100], 1e-9));
        writeNoisePng('${dir.path}/n.png', side: 16);
        final png = File('${dir.path}/n.png').readAsBytesSync();
        expect(png.sublist(1, 4), 'PNG'.codeUnits);
        expect(ByteData.sublistView(png).getUint32(16), 16);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  testWidgets('export conformance: audio, no audio, all muted, all soloed out, images only, MOV, HEVC', (tester) async {
    final env = await Qa11Env.open(base);
    if (env == null) return;
    final caps = env.caps;
    debugPrint('QA11|caps|platform=${Platform.operatingSystem}|simulator=${Qa11Env.isIosSimulator}|tier=${caps.tier.name}'
        '|hevc=${caps.hevcEncode}|hwHevc=${caps.hardwareHevc}|mov=${caps.movContainer}|maxExport=${caps.maxExportSize.width.round()}x${caps.maxExportSize.height.round()}');

    final noise = env.noise;
    final tone = env.tone(1000);
    final assetsAv = {
      'md_noise000001': PlanJsonKit.imageAsset(noise, noiseSide, noiseSide),
      'md_tone1000001': PlanJsonKit.audioAsset(tone, 10000000),
    };
    final picture = [
      PlanJsonKit.movingImage('it_noise000001#v', 'md_noise000001', 0, _durUs, _w, _h),
      PlanJsonKit.solid('it_box00000001#v', 5, '#FFCC00FF', 0, _durUs, 200, 120, 200, 120),
    ];
    final full = [
      [0, _durUs, 0, _durUs],
    ];

    final cases = <(String, RenderPlan, EncodeSettings, bool)>[
      // (name, plan, settings, audible)
      (
        'av_h264_mp4',
        PlanJsonKit.plan(w: _w, h: _h, fps: _fps, durUs: _durUs, assets: assetsAv, layers: picture, audio: [
          PlanJsonKit.audioSeg('it_tone1000001#a', 'md_tone1000001', full, [
            [0, 1],
          ]),
        ]),
        _settings(),
        true,
      ),
      (
        'no_audio',
        PlanJsonKit.plan(w: _w, h: _h, fps: _fps, durUs: _durUs, assets: {'md_noise000001': assetsAv['md_noise000001']}, layers: picture),
        _settings(),
        false,
      ),
      (
        'all_muted',
        PlanJsonKit.plan(w: _w, h: _h, fps: _fps, durUs: _durUs, assets: assetsAv, layers: picture, audio: [
          PlanJsonKit.audioSeg('it_tone1000001#a', 'md_tone1000001', full, [
            [0, 0],
          ]),
          PlanJsonKit.audioSeg('it_tone1000002#a', 'md_tone1000001', [
            [1000000, _durUs, 0, _durUs - 1000000],
          ], [
            [1000000, 0],
          ]),
        ]),
        _settings(),
        false,
      ),
      (
        'all_soloed_out',
        PlanJsonKit.plan(w: _w, h: _h, fps: _fps, durUs: _durUs, assets: assetsAv, layers: picture),
        _settings(),
        false,
      ),
      (
        'images_only',
        PlanJsonKit.plan(w: _w, h: _h, fps: _fps, durUs: _durUs, assets: {'md_noise000001': assetsAv['md_noise000001']}, layers: [
          ...picture,
          PlanJsonKit.solid('it_title000001#v', 20, '#FFFFFFFF', 500000, 2500000, 600, 80, 640, 600),
        ]),
        _settings(),
        false,
      ),
    ];
    if (caps.movContainer) {
      cases.add((
        'av_h264_mov',
        cases.first.$2,
        _settings(container: ExportContainer.mov),
        true,
      ));
    } else {
      debugPrint('QA11|skip|av_h264_mov|movContainer=false');
    }
    if (caps.hevcEncode) {
      cases.add(('av_hevc_mp4', cases.first.$2, _settings(codec: VideoCodec.hevc), true));
    } else {
      debugPrint('QA11|skip|av_hevc_mp4|hevcEncode=false (simulator/emulator: no HEVC encoder; device lab)');
    }

    for (final (name, plan, settings, audible) in cases) {
      final run = await env.export(name, plan, settings);
      expect(run.failure, isNull, reason: '$name: ${run.failure?.code} ${run.failure?.debugDetail}');
      final row = checkConformance(run, planDurUs: _durUs);
      // The engine's own probe agrees on the streams.
      final probe = await env.engine.probe(ResolvedMedia(uri: Uri.file(run.result!.path).toString(), fingerprint: 'qa11_probe_$name'));
      expect(probe.hasVideo, isTrue, reason: '$name: probe video');
      expect(probe.hasAudio, isTrue, reason: '$name: probe audio');
      expect(probe.channels, 2, reason: '$name: probe channels');
      expect(probe.sampleRate, 48000, reason: '$name: probe rate');
      // Audio content: the tone where audible, digital silence otherwise.
      final (wav, extracted) = await env.pcmOf(run);
      expect(extracted.sourceChannels, 2);
      expect(extracted.sourceSampleRate, 48000);
      final mono = wav.mono();
      final level = dbOf(rmsOf(mono, wav.sampleRate ~/ 10, mono.length - wav.sampleRate ~/ 10));
      if (audible) {
        expect(level, closeTo(-15.0, 0.5), reason: '$name: −12 dBFS peak tone = −15 dBFS RMS');
        expect(toneLevelDb(mono, 1000, wav.sampleRate), closeTo(-12, 0.5));
      } else {
        expect(level, lessThan(-60), reason: '$name: silent track');
      }
      row.values['audioRmsDb'] = level.toStringAsFixed(1);
      row.values['probe'] = '${probe.videoCodec}/${probe.audioCodec}/${probe.width}x${probe.height}/r${probe.rotation}';
      debugPrint(row.line('conformance'));
      env.discard(run);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
