// OWNER: QA-11
//
// Export audio measurements through the real plugin (BUILD_PLAN QA-11 part 3, ARCH §14.4, §21.1,
// §11.6 Audio row, D-37). Every export's PCM is read back through the engine's speech-audio job
// (16 kHz s16 mono, 0.5/0.5 downmix, sample 0 = 0 µs, IOS-04/AND-04) and compared with the API-03
// Dart reference mixer (`ReferenceAudioMixer`) fed the exact PCM of the generated tone fixtures:
//
//   (a) keep-pitch: tone_1khz at 2× and 0.5× with keep-pitch on keeps the dominant FFT bin within
//       ±2 % of 1 kHz; with keep-pitch off it moves to 2 kHz / 500 Hz (±2 %);
//   (b) a 3-lane project (music at 40 % with fade in and out, voice with volume keyframes, a main
//       lane with a cross dissolve whose audio crossfades equal-power, one muted lane), exported
//       as CORE-31 lowers it for export (muted and soloed-out lanes carry no segment), compared per
//       20 ms window with the reference (RMS ±0.5 dB); the muted lane's tone < −60 dBFS; the same
//       project with the voice lane soloed: every soloed-out lane's tone < −60 dBFS;
//   (c) 200 % vs 100 % = +6.02 ± 0.1 dB;
//   (d) speed-ramp seam click test: a 7-point ramp (1, 1.25, 1.6, 2, 1.6, 1.25, 1×, 300 ms each)
//       with keep-pitch: no seam transient more than −40 dBFS above the tone (IOS-18's metric:
//       the pure-tone predictor residual within ±40 ms of a seam exceeds the residual inside the
//       segments by ≤ 0.01);
//   (e) preview PCM: not capturable from Dart (no engine API taps the preview mix). On iOS the
//       AVPlayerItem mix is rendered offline and checked against the same reference by IOS-18's
//       RunnerTests/AudioTap/GainTapPlayerTests; the Android debug audio-sink tap belongs to the
//       Windows lane. Recorded as deferred in the report.
//
// Windows are compared where the reference is ≥ −40 dBFS (quieter windows are the fade tails,
// where ±0.5 dB is below the AAC noise) and away from hard segment edges (±1 window).
//
//   cd packages/danaview_editor_engine/example
//   flutter test integration_test/audio_mix_test.dart -d <iOS simulator | Android emulator | device>

// ignore_for_file: depend_on_referenced_packages

import 'dart:io';
import 'dart:math' as math;

import 'package:danaview_editor_core/plan.dart' show AnimKey;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'conformance_test.dart' as qa;

const int _w = 640;
const int _h = 360;
const int _fps = 30;

EncodeSettings get _settings => const EncodeSettings(width: _w, height: _h, fps: _fps, videoBitrate: 1000000, audioBitrate: 192000);

Map<String, Object?> _backdrop(int durUs) => qa.PlanJsonKit.solid('it_bg000000001#v', 0, '#202040FF', 0, durUs, _w.toDouble(), _h.toDouble(), _w / 2, _h / 2);

/// One timeline lane of the 3-lane project (mute and solo as the editor sets them).
final class _Lane {
  _Lane(this.name, this.segments, {this.muted = false, this.solo = false});

  final String name;
  final List<_Seg> segments;
  final bool muted;
  final bool solo;
}

final class _Seg {
  _Seg(this.id, this.freq, this.map, this.gain);

  final String id;
  final double freq;
  final List<List<int>> map;
  final List<List<num>> gain;
}

/// The export lowering of mute and solo (CORE-31, ARCH §11.2): a muted lane, or a lane silenced by
/// another lane's solo, has no segment in an export plan.
List<_Seg> _audibleForExport(List<_Lane> lanes) {
  final anySolo = lanes.any((l) => l.solo);
  return [
    for (final l in lanes)
      if (!l.muted && (!anySolo || l.solo)) ...l.segments,
  ];
}

String _assetOf(double freq) => 'md_tone${freq.round().toString().padLeft(5, '0')}';

/// Equal-power crossfade keys over `[t0, t1)` (11 keys).
List<List<num>> _equalPower(int t0, int t1, {required bool fadeIn}) => [
      for (var k = 0; k <= 10; k++)
        [t0 + (t1 - t0) * k ~/ 10, fadeIn ? math.sin(math.pi / 2 * k / 10) : math.cos(math.pi / 2 * k / 10)],
    ];

/// CI round 6: an export through AVFoundation's time-pitch unit has clean audio or fails typed.
/// When every audio read had a dropout or a dropped seam crossfade, the iOS export fails with a
/// retryable `decodeFailed` ('audio time-pitch fault …') instead of writing the gap. Returns whether
/// [run] completed (measure it); the typed failure is logged and accepted, any other failure fails
/// the test. A silent dropout in a completed export fails the measurements that follow.
bool _cleanOrTypedFailure(qa.ExportRun run, String name) {
  final f = run.failure;
  if (f == null) return true;
  expect(f.code, EngineErrorCode.decodeFailed, reason: '$name: ${f.code} ${f.debugDetail}');
  expect(f.debugDetail, startsWith('audio time-pitch fault'), reason: '$name: ${f.debugDetail}');
  expect(f.retryable, isTrue, reason: '$name: the time-pitch failure is retryable');
  expect(run.result, isNull);
  debugPrint('QA11|timePitchFailure|name=$name|detail=${f.debugDetail}');
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('danaview_qa11_audio'));
  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  /// Builds an export plan from segments over tone fixtures and returns it with the reference
  /// sources holding the exact fixture PCM.
  (RenderPlan, ReferenceSources) planOf(qa.Qa11Env env, List<_Seg> segs, int durUs) {
    // Plans list audio sorted by (t0, id) (ARCH §11.3, CORE-29 validator).
    segs = [...segs]..sort((a, b) => a.map.first[0] != b.map.first[0] ? a.map.first[0].compareTo(b.map.first[0]) : a.id.compareTo(b.id));
    final assets = <String, Object?>{};
    final audios = <String, ReferenceAudio>{};
    for (final s in segs) {
      final path = env.tone(s.freq);
      assets[_assetOf(s.freq)] = qa.PlanJsonKit.audioAsset(path, 10000000);
      audios[_assetOf(s.freq)] = PcmAudio(sampleRate: 48000, channels: 1, interleaved: env.toneSamples(path));
    }
    final plan = qa.PlanJsonKit.plan(w: _w, h: _h, fps: _fps, durUs: durUs, assets: assets, layers: [
      _backdrop(durUs),
    ], audio: [
      for (final s in segs) qa.PlanJsonKit.audioSeg(s.id, _assetOf(s.freq), s.map, s.gain),
    ]);
    return (plan, MapReferenceSources(audios: audios));
  }

  testWidgets('(a) keep-pitch at 2x and 0.5x: dominant FFT bin', (tester) async {
    final env = await qa.Qa11Env.open(base);
    if (env == null) return;
    const durUs = 3000000;
    final tone = env.tone(1000);
    for (final (rate, pitch, expected) in [(2.0, true, 1000.0), (2.0, false, 2000.0), (0.5, true, 1000.0), (0.5, false, 500.0)]) {
      final name = 'pitch_${rate}x_${pitch ? 'keep' : 'vari'}';
      final plan = qa.PlanJsonKit.plan(w: _w, h: _h, fps: _fps, durUs: durUs, assets: {
        'md_tone01000': qa.PlanJsonKit.audioAsset(tone, 10000000),
      }, layers: [
        _backdrop(durUs),
      ], audio: [
        qa.PlanJsonKit.audioSeg('it_tone0000001#a', 'md_tone01000', [
          [0, durUs, 0, (durUs * rate).round()],
        ], [
          [0, 1],
        ], pitch: pitch),
      ]);
      final run = await env.export(name, plan, _settings);
      if (!_cleanOrTypedFailure(run, name)) continue;
      final (wav, _) = await env.pcmOf(run);
      final x = wav.mono();
      final f = qa.dominantFrequency(x, wav.sampleRate, from: wav.sampleRate ~/ 2);
      final err = (f - expected).abs() / expected;
      debugPrint('QA11|pitch|name=$name|rate=$rate|keepPitch=$pitch|dominantHz=${f.toStringAsFixed(1)}|expectedHz=$expected'
          '|errorPct=${(err * 100).toStringAsFixed(2)}|rmsDb=${qa.dbOf(qa.rmsOf(x, 8000, x.length - 8000)).toStringAsFixed(2)}');
      expect(err, lessThanOrEqualTo(0.02), reason: '$name: dominant ${f.toStringAsFixed(1)} Hz, expected $expected Hz ±2 %');
      env.discard(run);
    }
  }, timeout: const Timeout(Duration(minutes: 20)));

  testWidgets('(b) 3-lane mix vs the reference mixer per 20 ms; muted and soloed-out lanes < -60 dBFS', (tester) async {
    final env = await qa.Qa11Env.open(base);
    if (env == null) return;
    const durUs = 3000000;
    const xd0 = 1500000, xd1 = 2000000;
    List<_Lane> lanes({required bool soloVoice}) => [
          // Music at 40 % with a 0.5 s fade in and out.
          _Lane('music', [
            _Seg('it_music000001#a', 440, [
              [0, durUs, 0, durUs],
            ], [
              [0, 0],
              [500000, 0.4],
              [2500000, 0.4],
              [durUs, 0],
            ]),
          ]),
          // Voice with volume keyframes (100 % -> 50 % -> 150 %).
          _Lane('voice', [
            _Seg('it_voice000001#a', 1000, [
              [0, durUs, 0, durUs],
            ], [
              [0, 1],
              [1000000, 1],
              [1500000, 0.5],
              [2500000, 1.5],
              [durUs, 1.5],
            ]),
          ], solo: soloVoice),
          // Main lane: clip A then clip B with a 0.5 s cross dissolve (equal-power audio).
          _Lane('main', [
            _Seg('it_mainA00001#a', 660, [
              [0, xd1, 0, xd1],
            ], [
              [0, 1],
              ..._equalPower(xd0, xd1, fadeIn: false),
            ]),
            _Seg('it_mainB00001#a', 1500, [
              [xd0, durUs, 0, durUs - xd0],
            ], [
              ..._equalPower(xd0, xd1, fadeIn: true),
              [durUs, 1],
            ]),
          ]),
          // A muted lane.
          _Lane('muted', [
            _Seg('it_muted00001#a', 3000, [
              [0, durUs, 0, durUs],
            ], [
              [0, 1],
            ]),
          ], muted: true),
        ];

    for (final soloVoice in [false, true]) {
      final name = soloVoice ? 'mix_solo_voice' : 'mix_3lane';
      final all = lanes(soloVoice: soloVoice);
      final segs = _audibleForExport(all);
      final (plan, sources) = planOf(env, segs, durUs);
      // Every fixture is written (the reference may need lanes that the export dropped).
      for (final l in all) {
        for (final s in l.segments) {
          env.tone(s.freq);
        }
      }
      final run = await env.export(name, plan, _settings);
      expect(run.failure, isNull, reason: '$name: ${run.failure?.code} ${run.failure?.debugDetail}');
      final (wav, _) = await env.pcmOf(run);
      final actual = wav.mono();
      final sr = wav.sampleRate;

      // Reference: 48 kHz stereo -> mono (lanes are mono, L = R).
      final ref = ReferenceAudioMixer(sources: sources).mix(plan, 0, durUs);
      final refMono = Float64List(ref.length ~/ 2);
      for (var i = 0; i < refMono.length; i++) {
        refMono[i] = 0.5 * (ref[2 * i] + ref[2 * i + 1]);
      }
      final refWin = qa.windowRms(refMono, 960);
      final actWin = qa.windowRms(actual, sr * 20 ~/ 1000);

      // Windows next to a hard edge (a segment boundary at non-zero gain) are not compared.
      final skip = <int>{0, refWin.length - 1};
      for (final s in segs) {
        for (final t in [s.map.first[0], s.map.last[1]]) {
          final g = AudioMath.gainAt([for (final k in s.gain) AnimKey(k[0].toInt(), k[1].toDouble())], t.toDouble());
          if (g.abs() > 0.01 && t > 0 && t < durUs) {
            final w = t ~/ 20000;
            skip.addAll([w - 1, w, w + 1]);
          }
        }
      }
      var compared = 0;
      var worst = 0.0;
      var worstAt = -1;
      final n = math.min(refWin.length, actWin.length);
      for (var w = 0; w < n; w++) {
        if (skip.contains(w)) continue;
        final r = qa.dbOf(refWin[w]);
        if (r < -40) continue;
        final d = qa.dbOf(actWin[w]) - r;
        compared++;
        if (d.abs() > worst.abs()) {
          worst = d;
          worstAt = w;
        }
      }
      // Lane tones in the export (dBFS peak) vs the reference.
      final levels = <String, double>{};
      for (final l in all) {
        final freqs = {for (final s in l.segments) s.freq};
        for (final f in freqs) {
          levels['${l.name}@${f.round()}'] = qa.toneLevelDb(actual, f, sr);
        }
      }
      debugPrint('QA11|mix|name=$name|windows=$n|compared=$compared|worstDeltaDb=${worst.toStringAsFixed(3)}|worstWindow=$worstAt'
          '|levels=${levels.entries.map((e) => '${e.key}:${e.value.toStringAsFixed(1)}').join(',')}');
      expect(compared, greaterThan(n * 0.7), reason: '$name: most windows are compared');
      expect(worst.abs(), lessThanOrEqualTo(0.5), reason: '$name: window $worstAt differs by ${worst.toStringAsFixed(3)} dB');

      final anySolo = all.any((l) => l.solo);
      for (final l in all) {
        final silenced = l.muted || (anySolo && !l.solo);
        if (!silenced) continue;
        for (final s in l.segments) {
          final level = levels['${l.name}@${s.freq.round()}']!;
          expect(level, lessThan(-60), reason: '$name: ${l.name} (${l.muted ? 'muted' : 'soloed out'}) at ${s.freq} Hz is $level dBFS');
        }
      }
      env.discard(run);
    }
  }, timeout: const Timeout(Duration(minutes: 20)));

  testWidgets('(c) 200 % volume = +6.02 ± 0.1 dB vs 100 %', (tester) async {
    final env = await qa.Qa11Env.open(base);
    if (env == null) return;
    const durUs = 3000000;
    final levels = <double, double>{};
    for (final gain in [1.0, 2.0]) {
      final (plan, sources) = planOf(env, [
        _Seg('it_tone0000001#a', 1000, [
          [0, durUs, 0, durUs],
        ], [
          [0, gain],
        ]),
      ], durUs);
      final run = await env.export('gain_${(gain * 100).round()}', plan, _settings);
      expect(run.failure, isNull, reason: '${run.failure?.code} ${run.failure?.debugDetail}');
      final (wav, _) = await env.pcmOf(run);
      final x = wav.mono();
      final level = qa.dbOf(qa.rmsOf(x, wav.sampleRate ~/ 5, x.length - wav.sampleRate ~/ 5));
      final ref = ReferenceAudioMixer(sources: sources).mix(plan, 200000, durUs - 200000);
      final refL = Float64List.fromList([for (var i = 0; i < ref.length; i += 2) ref[i].toDouble()]);
      final refLevel = qa.dbOf(qa.rmsOf(refL));
      levels[gain] = level;
      debugPrint('QA11|gain|gain=$gain|rmsDb=${level.toStringAsFixed(3)}|referenceDb=${refLevel.toStringAsFixed(3)}');
      expect(level, closeTo(refLevel, 0.5));
      env.discard(run);
    }
    final delta = levels[2.0]! - levels[1.0]!;
    debugPrint('QA11|gain|deltaDb=${delta.toStringAsFixed(3)}|expected=6.02±0.1');
    expect(delta, closeTo(6.02, 0.1));
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('(d) speed-ramp seam click test (7-point ramp, keep pitch)', (tester) async {
    final env = await qa.Qa11Env.open(base);
    if (env == null) return;
    const speeds = [1.0, 1.25, 1.6, 2.0, 1.6, 1.25, 1.0];
    const segUs = 300000;
    final map = <List<int>>[];
    var s0 = 500000;
    for (var k = 0; k < speeds.length; k++) {
      final s1 = s0 + (speeds[k] * segUs).round();
      map.add([k * segUs, (k + 1) * segUs, s0, s1]);
      s0 = s1;
    }
    final durUs = speeds.length * segUs;
    final (plan, _) = planOf(env, [
      _Seg('it_ramp0000001#a', 1000, map, [
        [0, 1],
      ]),
    ], durUs);
    final run = await env.export('ramp_seams', plan, _settings);
    if (!_cleanOrTypedFailure(run, 'ramp_seams')) return;
    final (wav, _) = await env.pcmOf(run);
    final x = wav.mono();
    final sr = wav.sampleRate;
    int at(int us) => us * sr ~/ 1000000;
    final e = qa.toneResidual(x, 1000, sr);
    var floor = 0.0;
    for (var k = 0; k < speeds.length; k++) {
      floor = math.max(floor, qa.maxAbs(e, at(k * segUs + 50000), at((k + 1) * segUs - 50000)));
    }
    final seams = [for (var k = 1; k < speeds.length; k++) qa.maxAbs(e, at(k * segUs - 40000), at(k * segUs + 40000))];
    final worst = seams.reduce(math.max);
    final excess = worst - floor;
    final excessDb = excess > 0 ? 20 * math.log(excess) / math.ln10 : double.negativeInfinity;
    // The tone level of every 20 ms window inside a piece, and the quietest one. Keep-pitch latency
    // compensation reads each piece's source at its own offset, so the tone's phase steps at every
    // seam by design (AudioMixLayout, FIX-IOS-PITCH-SYNC): one phase-coherent Goertzel over the
    // whole ramp sums seven phases and reads −18.4 dB for a −12 dBFS tone with no gap at all
    // (CI runs 40741900194 and 40906413424). Windows never straddle a seam, so a dropout, a quiet
    // patch or a lost crossfade still pulls the quietest window down.
    const winUs = 20000;
    var toneDb = double.infinity;
    var quietestUs = 0;
    for (var k = 0; k < speeds.length; k++) {
      for (var t = math.max(k * segUs, 100000); t + winUs <= math.min((k + 1) * segUs, durUs - 100000); t += winUs) {
        final level = qa.toneLevelDb(x, 1000, sr, at(t), at(t + winUs));
        if (level < toneDb) {
          toneDb = level;
          quietestUs = t;
        }
      }
    }
    debugPrint('QA11|ramp|floor=${floor.toStringAsFixed(5)}|seams=${seams.map((v) => v.toStringAsFixed(5)).join(',')}'
        '|worstExcessDbfs=${excessDb.toStringAsFixed(1)}|toneDb=${toneDb.toStringAsFixed(2)}|quietestUs=$quietestUs');
    expect(toneDb, greaterThan(-14), reason: 'the ramp keeps the tone audible (quietest 20 ms window at $quietestUs µs)');
    expect(excess, lessThanOrEqualTo(0.01), reason: 'seam transient ${excessDb.toStringAsFixed(1)} dBFS above the tone floor');
    env.discard(run);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('(e) preview PCM is measured natively (deferred here)', () {
    debugPrint('QA11|deferred|previewPcm|iOS: RunnerTests/AudioTap/GainTapPlayerTests (IOS-18) renders the AVPlayerItem mix offline '
        'against the API-03 vectors; no Dart API taps the preview mix|Android: debug audio-sink tap, Windows lane');
  });
}
