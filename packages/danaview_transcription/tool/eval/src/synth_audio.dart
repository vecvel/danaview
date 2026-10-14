// OWNER: QA-06
//
// Deterministic non-speech clips for the hallucination check (ai.md §16.5): digital silence,
// pink-ish noise and a synthetic "music" bed (sustained chords with a beat), written as the canonical
// 16 kHz mono s16le WAV the shim reads. Same parameters, same bytes, on every host.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Sample rate of every eval WAV.
const int evalSampleRate = 16000;

/// Kinds of generated clips.
enum SynthKind {
  /// Digital zero.
  silence,

  /// Filtered noise (room tone / hiss).
  noise,

  /// Chords with a kick-like beat (instrumental music without vocals).
  music,
}

/// A generated clip's recipe (manifest `synth` object).
final class SynthSpec {
  /// Creates a recipe.
  const SynthSpec({required this.kind, required this.seconds, this.amplitude = 0.1, this.seed = 1});

  /// Reads `{"type": "silence"|"noise"|"music", "seconds": n, "amplitude": a, "seed": s}`.
  factory SynthSpec.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    final kind = SynthKind.values.where((k) => k.name == type).firstOrNull;
    if (kind == null) throw FormatException('unknown synth type $type');
    final seconds = json['seconds'];
    if (seconds is! num || seconds <= 0 || seconds > 600) throw FormatException('synth seconds must be in (0, 600]');
    return SynthSpec(
      kind: kind,
      seconds: seconds.toDouble(),
      amplitude: (json['amplitude'] as num?)?.toDouble() ?? 0.1,
      seed: (json['seed'] as num?)?.toInt() ?? 1,
    );
  }

  /// What to generate.
  final SynthKind kind;

  /// Length in seconds.
  final double seconds;

  /// Peak amplitude in [0, 1].
  final double amplitude;

  /// Noise seed.
  final int seed;
}

/// The 16-bit samples of [spec].
Int16List synthesize(SynthSpec spec) {
  final n = (spec.seconds * evalSampleRate).round();
  final out = Int16List(n);
  switch (spec.kind) {
    case SynthKind.silence:
      break;
    case SynthKind.noise:
      // Xorshift white noise through a one-pole low-pass: a soft hiss with most energy below 2 kHz.
      var x = spec.seed == 0 ? 0x9E3779B9 : spec.seed;
      var y = 0.0;
      for (var i = 0; i < n; i++) {
        x ^= (x << 13) & 0xFFFFFFFF;
        x ^= x >> 17;
        x ^= (x << 5) & 0xFFFFFFFF;
        final white = (x & 0xFFFF) / 32768.0 - 1.0;
        y = 0.92 * y + 0.08 * white;
        out[i] = _s16(y * 4 * spec.amplitude);
      }
    case SynthKind.music:
      // A I-V-vi-IV progression, two seconds per chord, three partials per note, plus a decaying
      // 60 Hz kick on every beat at 120 bpm.
      const chords = [
        [261.63, 329.63, 392.00],
        [392.00, 493.88, 587.33],
        [220.00, 261.63, 329.63],
        [349.23, 440.00, 523.25],
      ];
      for (var i = 0; i < n; i++) {
        final t = i / evalSampleRate;
        final chord = chords[(t ~/ 2) % chords.length];
        var v = 0.0;
        for (final f in chord) {
          v += math.sin(2 * math.pi * f * t) + 0.3 * math.sin(4 * math.pi * f * t) + 0.1 * math.sin(6 * math.pi * f * t);
        }
        v /= chord.length * 1.4;
        final beat = t % 0.5;
        v += 0.8 * math.exp(-beat * 18) * math.sin(2 * math.pi * 60 * beat);
        out[i] = _s16(v * spec.amplitude);
      }
  }
  return out;
}

/// Canonical RIFF/WAVE bytes (PCM, 16 kHz, mono, 16-bit) of [samples].
Uint8List wavBytes(Int16List samples) {
  final data = samples.length * 2;
  final b = ByteData(44 + data);
  void tag(int at, String s) {
    for (var k = 0; k < 4; k++) {
      b.setUint8(at + k, s.codeUnitAt(k));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + data, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, evalSampleRate, Endian.little)
    ..setUint32(28, evalSampleRate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, data, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(44 + 2 * i, samples[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Writes [spec] to [path] as a WAV and returns its duration in ms.
Future<int> writeSynthWav(SynthSpec spec, String path) async {
  final samples = synthesize(spec);
  await File(path).writeAsBytes(wavBytes(samples), flush: true);
  return samples.length * 1000 ~/ evalSampleRate;
}

/// Duration in ms of a canonical 16 kHz mono s16 WAV at [path] (from its size; null when the
/// header is not the canonical 44-byte one at 16 kHz mono 16-bit).
int? wavDurationMs(String path) {
  final f = File(path);
  if (!f.existsSync()) return null;
  final raf = f.openSync();
  try {
    final header = raf.readSync(44);
    if (header.length < 44) return null;
    final b = ByteData.sublistView(header);
    final rate = b.getUint32(24, Endian.little);
    final channels = b.getUint16(22, Endian.little);
    final bits = b.getUint16(34, Endian.little);
    if (String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' || rate != evalSampleRate || channels != 1 || bits != 16) {
      return null;
    }
    // Walk the chunks to the data chunk (whisper samples carry LIST chunks before it).
    var offset = 12;
    final length = f.lengthSync();
    while (offset + 8 <= length) {
      raf.setPositionSync(offset);
      final h = raf.readSync(8);
      final id = String.fromCharCodes(h.sublist(0, 4));
      final size = ByteData.sublistView(h).getUint32(4, Endian.little);
      if (id == 'data') return (size ~/ 2) * 1000 ~/ evalSampleRate;
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    return null;
  } finally {
    raf.closeSync();
  }
}

int _s16(double v) => (v.clamp(-1.0, 1.0) * 32767).round();
