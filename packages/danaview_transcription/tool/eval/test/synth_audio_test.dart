// OWNER: QA-06
//
// Deterministic non-speech clips and the WAV helpers (tool/eval/src/synth_audio.dart).

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../src/synth_audio.dart';

void main() {
  test('silence is digital zero; noise and music are non-zero and within range', () {
    final silence = synthesize(const SynthSpec(kind: SynthKind.silence, seconds: 1));
    expect(silence.length, 16000);
    expect(silence.every((s) => s == 0), isTrue);
    for (final kind in [SynthKind.noise, SynthKind.music]) {
      final s = synthesize(SynthSpec(kind: kind, seconds: 2, amplitude: 0.3));
      expect(s.any((v) => v != 0), isTrue, reason: kind.name);
      final peak = s.map((v) => v.abs()).reduce((a, b) => a > b ? a : b);
      expect(peak, lessThanOrEqualTo(32767));
      expect(peak, greaterThan(500), reason: kind.name);
    }
  });

  test('same recipe, same bytes; another seed, other bytes', () {
    String hash(SynthSpec s) => sha256.convert(wavBytes(synthesize(s))).toString();
    const a = SynthSpec(kind: SynthKind.noise, seconds: 1, seed: 7);
    expect(hash(a), hash(a));
    expect(hash(a), isNot(hash(const SynthSpec(kind: SynthKind.noise, seconds: 1, seed: 8))));
  });

  test('written WAVs are canonical 16 kHz mono s16 and report their duration', () async {
    final dir = await Directory.systemTemp.createTemp('dv_eval_synth');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'm.wav');
    final ms = await writeSynthWav(const SynthSpec(kind: SynthKind.music, seconds: 1.5), path);
    expect(ms, 1500);
    expect(wavDurationMs(path), 1500);
    expect(File(path).lengthSync(), 44 + 1.5 * 16000 * 2);
    expect(wavDurationMs(p.join(dir.path, 'missing.wav')), isNull);
  });

  test('wavDurationMs walks chunks before data (whisper samples carry a LIST chunk)', () {
    final jfk = p.join(Directory.current.path, '..', 'danaview_whisper', 'third_party', 'whisper.cpp', 'samples', 'jfk.wav');
    expect(wavDurationMs(jfk), 11000);
  });

  test('recipes are validated', () {
    expect(() => SynthSpec.fromJson({'type': 'speech', 'seconds': 1}), throwsFormatException);
    expect(() => SynthSpec.fromJson({'type': 'noise', 'seconds': 0}), throwsFormatException);
    expect(SynthSpec.fromJson({'type': 'noise', 'seconds': 3, 'seed': 9}).seed, 9);
  });
}
