// OWNER: QA-03
//
// A/V sync through the real plugin (BUILD_PLAN QA-03, ARCH §11.5 'A/V-sync contract', §12.7,
// §21.1 'Parity, accuracy, A/V sync'): the ENG-05 clap_flash_av fixture (flash frames 30, 75, 120
// at 1.0 / 2.5 / 4.0 s, a 20 ms 2 kHz click starting exactly at each flash, AAC with priming in
// the edit list) is placed on a 30 fps timeline at
//
//   1×, 2× keep pitch, a 0.5× ramp (1× → 0.75× → 0.5× → 1×, keep pitch) and across a cross
//   dissolve (two clips, equal-power audio crossfade, the incoming clip fading in on top),
//
// exported, and measured from the file:
//   - video: the export is read back frame by frame (preview exact seeks on the exported file);
//     the first flash frame must be the timeline frame whose source frame is the flash frame;
//   - audio: the export's PCM (engine speech-audio job, 16 kHz mono, sample-accurate) gives the
//     click onset (first sample at ≥ 10 % of the click's peak; the Hann burst reaches 10 % about
//     2 ms after it starts, the measurement bias is therefore ≤ +2 ms);
//   - export rule (§11.5): |click − flash time| ≤ 1 frame and ≤ 20 ms for every click, and the
//     A/V offset (click − first flash frame) ≤ 20 ms where the flash lands on a frame start.
//
// Preview: the video side is checked with exact seeks (the flash frame is shown exactly at its
// timeline frame). The audible preview offset after latency compensation (≤ 1 frame and ≤ 40 ms,
// §12.7, V-N23) needs the device's audio output and the displayed texture captured together; no
// engine API exposes the preview audio from Dart: deferred, no device available (iOS simulator
// numbers are in IOS-01 §2.8; Android's on the Windows lane).
//
//   cd packages/danaview_editor_engine/example
//   flutter test integration_test/av_sync_test.dart -d <device> --dart-define=QA03_MEDIA=$PWD/../test_fixtures/media

// ignore_for_file: depend_on_referenced_packages

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:danaview_editor_core/model.dart' show TimeRange;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'accuracy_test.dart' as acc;
import 'conformance_test.dart' as qa11;

const int _fps = 30;
const int _frameUs = 33333;

/// Source flash frames / click times of clap_flash_av.mp4.
const List<int> _flashSourceUs = [1000000, 2500000, 4000000];
const List<int> _flashSourceFrames = [30, 75, 120];

/// One A/V layout on the timeline.
final class _Case {
  _Case(this.name, this.durUs, this.clips);

  final String name;
  final int durUs;

  /// Clips: (id, map, pitch, xf.op anim or null, audio gain envelope, seq).
  final List<_Clip> clips;
}

final class _Clip {
  _Clip(this.id, this.map, {this.opacity, this.gain, this.seq = 0});

  final String id;
  final List<acc.Seg> map;
  /// Every case keeps pitch (2× keep pitch and the 0.5× ramp of the spec).
  bool get pitch => true;
  final List<List<num>>? opacity;
  final List<List<num>>? gain;
  final int seq;

  int get t0 => map.first[0];
  int get t1 => map.last[1];

  /// Timeline time of source time [s] (null when the clip does not show it).
  double? timelineOf(int s) {
    for (final m in map) {
      if (s >= m[2] && s < m[3]) return m[0] + (s - m[2]) * (m[1] - m[0]) / (m[3] - m[2]);
    }
    return null;
  }

  /// Speed at source time [s].
  double rateAt(int s) {
    for (final m in map) {
      if (s >= m[2] && s < m[3]) return (m[3] - m[2]) / (m[1] - m[0]);
    }
    return 1;
  }

  /// Opacity at timeline [t] (1 without an animation).
  double opacityAt(double t) {
    final o = opacity;
    if (o == null) return 1;
    if (t <= o.first[0]) return o.first[1].toDouble();
    if (t >= o.last[0]) return o.last[1].toDouble();
    for (var i = 1; i < o.length; i++) {
      if (t <= o[i][0]) {
        final a = o[i - 1], b = o[i];
        return a[1] + (b[1] - a[1]) * (t - a[0]) / (b[0] - a[0]);
      }
    }
    return 1;
  }
}

/// An equal-power crossfade envelope over [t0, t1] sampled every 50 ms, rising or falling.
List<List<num>> _equalPower(int t0, int t1, {required bool rising, int? clipStart, int? clipEnd}) {
  final keys = <List<num>>[];
  if (clipStart != null && clipStart < t0) keys.add([clipStart, rising ? 0 : 1]);
  for (var t = t0; t <= t1; t += 50000) {
    final x = (t - t0) / (t1 - t0);
    keys.add([t, rising ? math.sin(x * math.pi / 2) : math.cos(x * math.pi / 2)]);
  }
  if (clipEnd != null && clipEnd > t1) keys.add([clipEnd, rising ? 1 : 0]);
  return keys;
}

final List<_Case> _cases = [
  _Case('1x', 6000000, [
    _Clip('it_a', [
      [0, 6000000, 0, 6000000],
    ]),
  ]),
  _Case('2x keep pitch', 3000000, [
    _Clip('it_a', [
      [0, 3000000, 0, 6000000],
    ]),
  ]),
  // 1× → 0.75× → 0.5× → 1×; every breakpoint a frame start (0.8 s = 24, 1.2 s = 36, 4.2 s = 126);
  // the second flash (source 2.5 s) plays inside the 0.5× segment, at 4.0 s.
  _Case('0.5x ramp', 5700000, [
    _Clip('it_a', [
      [0, 800000, 0, 800000],
      [800000, 1200000, 800000, 1100000],
      [1200000, 4200000, 1100000, 2600000],
      [4200000, 5700000, 2600000, 4100000],
    ]),
  ]),
  // Cut at 2.0 s, dissolve 1 s: A extended to 2.5 s, B from 1.5 s (source 2.0 s) on top fading in.
  _Case('cross dissolve', 5500000, [
    _Clip(
      'it_a',
      [
        [0, 2500000, 0, 2500000],
      ],
      gain: _equalPower(1500000, 2500000, rising: false, clipStart: 0),
    ),
    _Clip(
      'it_b',
      [
        [1500000, 5500000, 2000000, 6000000],
      ],
      opacity: [
        [1500000, 0],
        [2500000, 1],
      ],
      gain: _equalPower(1500000, 2500000, rising: true, clipEnd: 5500000),
      seq: 1,
    ),
  ]),
];

/// One expected flash on the timeline.
final class _Flash {
  _Flash(this.sourceFrame, this.tUs, this.rate, this.videoFrame, this.videoCheck);

  final int sourceFrame;
  final double tUs;
  final double rate;

  /// The timeline frame that shows the flash source frame first (null: never shown).
  final int? videoFrame;

  /// False when the flash is inside a transition window (blended).
  final bool videoCheck;

  bool get onGrid => videoFrame != null && (acc.tof(videoFrame!, _fps) - tUs).abs() < 1;
}

List<_Flash> _flashesOf(_Case c, List<double> pts) {
  final out = <_Flash>[];
  for (var i = 0; i < _flashSourceUs.length; i++) {
    for (final clip in c.clips) {
      final t = clip.timelineOf(_flashSourceUs[i]);
      if (t == null || t >= c.durUs) continue;
      int? frame;
      for (var k = acc.frameIndexOf(t.floor(), _fps) - 2; k <= acc.frameIndexOf(t.floor(), _fps) + 3; k++) {
        if (k < 0) continue;
        final tk = acc.tof(k, _fps);
        if (tk < clip.t0 || tk >= clip.t1) continue;
        final src = acc.SourceMap([(clip.map, _fps)], ptsUs: pts).barcodeAt(tk);
        if (src == _flashSourceFrames[i]) {
          frame = k;
          break;
        }
      }
      final blended = c.clips.any((o) => o.opacity != null && o.opacityAt(t) > 0 && o.opacityAt(t) < 1);
      out.add(_Flash(_flashSourceFrames[i], t, clip.rateAt(_flashSourceUs[i]), frame, !blended));
    }
  }
  out.sort((a, b) => a.tUs.compareTo(b.tUs));
  return out;
}

RenderPlan _plan(_Case c, String path, {String target = 'preview'}) => acc.Qa03Plan.plan(
      target: target,
      fps: _fps,
      durUs: c.durUs,
      assets: {'cf': acc.Qa03Plan.video(path, w: 1280, h: 720, durUs: 6000000, hasAudio: true)},
      layers: [
        for (final clip in c.clips)
          {
            ...acc.Qa03Plan.media('${clip.id}#v', 'cf', clip.map, seq: clip.seq),
            if (clip.opacity != null) 'anim': {'xf.op': clip.opacity},
          },
      ],
      audio: [
        for (final clip in c.clips)
          {
            'id': '${clip.id}#a',
            'asset': 'cf',
            't': [clip.t0, clip.t1],
            'map': clip.map,
            'gain': clip.gain ?? [
                  [clip.t0, 1],
                ],
            'pitch': clip.pitch,
          },
      ],
    );

/// Fraction of flash-white pixels below the barcode band (flash frames are white with black
/// digits; normal frames are a hue-shifting backdrop).
double _whiteness(acc.Rgba f) {
  var white = 0, n = 0;
  for (var y = (f.h * 0.15).round(); y < f.h; y += 2) {
    for (var x = 0; x < f.w; x += 2) {
      final i = (y * f.w + x) * 4;
      final r = f.px[i], g = f.px[i + 1], b = f.px[i + 2];
      n++;
      if (r > 225 && g > 225 && b > 225) white++;
    }
  }
  return white / n;
}

bool _isFlash(acc.Rgba f) => _whiteness(f) > 0.5;

/// Click onset (µs) in 16 kHz [pcm] near [tUs] (±150 ms) and the click's peak, null when no
/// click is there.
(double, double)? _onset(Float64List pcm, int rate, double tUs) {
  final c = _click(pcm, rate, tUs);
  return c == null ? null : (c.$1, c.$2);
}

/// (onset µs, peak, peak time µs, energy centroid µs) of the click near [tUs].
(double, double, double, double)? _click(Float64List pcm, int rate, double tUs) {
  final from = math.max(0, ((tUs - 150000) * rate / 1e6).floor());
  final to = math.min(pcm.length, ((tUs + 150000) * rate / 1e6).ceil());
  var peak = 0.0;
  var peakAt = from;
  for (var i = from; i < to; i++) {
    if (pcm[i].abs() > peak) {
      peak = pcm[i].abs();
      peakAt = i;
    }
  }
  if (peak < 0.02) return null;
  var onset = from;
  while (pcm[onset].abs() < 0.1 * peak) {
    onset++;
  }
  var e = 0.0, et = 0.0;
  for (var i = from; i < to; i++) {
    final v = pcm[i] * pcm[i];
    if (v < 1e-6) continue;
    e += v;
    et += v * i;
  }
  return (onset * 1e6 / rate, peak, peakAt * 1e6 / rate, (e == 0 ? onset : et / e) * 1e6 / rate);
}

Future<Float64List> _pcm(acc.Qa03Env env, String path, int durUs, String tag) async {
  final out = '${env.work}/pcm_$tag.wav';
  final job = env.engine.jobs.extractSpeechAudio(SpeechAudioJobRequest(
    media: acc.Qa03Env.media(path, 'qa03_pcm_$tag'),
    range: TimeRange(0, durUs),
    outputPath: out,
  ));
  final x = await job.result.timeout(const Duration(minutes: 2));
  final wav = qa11.readWav(File(x.path).readAsBytesSync());
  expect(wav.sampleRate, 16000);
  return wav.mono();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('danaview_qa03_av'));
  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  group('support self-checks', () {
    test('case layouts: grid edges, flash timeline times', () {
      for (final c in _cases) {
        expect(acc.tof(acc.frameIndexOf(c.durUs, _fps), _fps), c.durUs, reason: '${c.name}: duration on the grid');
        expect(c.durUs % 100000, 0, reason: '${c.name}: exact µs duration');
        for (final clip in c.clips) {
          for (final m in clip.map) {
            expect(acc.tof(acc.frameIndexOf(m[0], _fps), _fps), m[0], reason: '${c.name}: map edge on the grid');
            expect(acc.tof(acc.frameIndexOf(m[1], _fps), _fps), m[1], reason: '${c.name}: map edge on the grid');
          }
        }
      }
      final pts = [for (var i = 0; i < 180; i++) i * 1e6 / 30];
      final one = _flashesOf(_cases[0], pts);
      expect(one.map((f) => f.videoFrame), [30, 75, 120]);
      final two = _flashesOf(_cases[1], pts);
      expect(two.map((f) => f.tUs), [500000, 1250000, 2000000]);
      expect(two.map((f) => f.videoFrame), [15, null, 60], reason: 'flash 75 is skipped at 2×');
      final ramp = _flashesOf(_cases[2], pts);
      expect(ramp.map((f) => f.videoFrame), [32, 120, 168]);
      expect(ramp.map((f) => f.rate), [0.75, 0.5, 1.0]);
      expect(ramp.every((f) => f.onGrid), isTrue);
      final xd = _flashesOf(_cases[3], pts);
      expect(xd.map((f) => f.tUs), [1000000, 2000000, 3500000]);
      expect(xd.map((f) => f.videoCheck), [true, false, true]);
    });

    test('click onset finder', () {
      const rate = 16000;
      final x = Float64List(rate);
      final start = (0.4 * rate).round();
      for (var i = 0; i < 320; i++) {
        final w = math.pow(math.sin(math.pi * i / 320), 2);
        x[start + i] = 0.5 * w * math.sin(2 * math.pi * 2000 * i / rate);
      }
      final (t, _) = _onset(x, rate, 410000)!;
      expect(t, inInclusiveRange(400000, 403000));
      expect(_onset(x, rate, 800000), isNull);
    });
  });

  final skip = acc.Qa03Media.skipReason;

  testWidgets('measurement chain: the fixture itself (clicks at 1.0 / 2.5 / 4.0 s through the speech-audio job)', (tester) async {
    final env = await acc.Qa03Env.open(base);
    if (env == null) return;
    final path = acc.Qa03Media.path('clap_flash_av.mp4');
    final pcm = await _pcm(env, path, 6000000, 'fixture');
    for (final t in _flashSourceUs) {
      final o = _onset(pcm, 16000, t.toDouble());
      acc.qa03('avsync', {'case': 'fixture', 'flashUs': t, 'clickOnsetUs': o?.$1.round(), 'deltaMs': o == null ? null : ((o.$1 - t) / 1000).toStringAsFixed(2)});
      expect(o, isNotNull);
      expect((o!.$1 - t).abs(), lessThanOrEqualTo(3000), reason: 'fixture click within the onset bias');
    }
  }, skip: skip != null);

  for (final c in _cases) {
    testWidgets('export A/V sync, ${c.name}: ≤ 1 frame and ≤ 20 ms; preview flash frame exact', (tester) async {
      final env = await acc.Qa03Env.open(base);
      if (env == null) return;
      final path = acc.Qa03Media.path('clap_flash_av.mp4');
      final flashes = _flashesOf(c, acc.videoPts(path));
      final failures = <String>[];

      // ---- preview: the flash frame at exact seeks ----
      final s = await env.preview(_plan(c, path));
      try {
        for (final f in flashes.where((f) => f.videoFrame != null && f.videoCheck)) {
          final k = f.videoFrame!;
          final (_, before) = await acc.seekAndCapture(s, k - 1, _fps);
          final (_, at) = await acc.seekAndCapture(s, k, _fps);
          final ok = !_isFlash(before) && _isFlash(at);
          acc.qa03('avsync', {'case': c.name, 'mode': 'preview video', 'flashFrame': k, 'ok': ok});
          if (!ok) failures.add('preview: flash not exactly at frame $k');
        }
      } finally {
        await s.dispose();
      }

      // ---- export ----
      final r = await env.export('av_${c.name.replaceAll(' ', '_')}', _plan(c, path, target: 'export'));
      final pcm = await _pcm(env, r.path, r.duration, c.name.replaceAll(' ', '_'));
      final framesToRead = <int>{
        for (final f in flashes)
          if (f.videoFrame != null && f.videoCheck) ...[for (var d = -3; d <= 3; d++) f.videoFrame! + d],
      }.where((k) => k >= 0 && acc.tof(k, _fps) < r.duration).toList()
        ..sort();
      final exportPts = acc.videoPts(r.path);
      final flashAt = <int, bool>{};
      if (framesToRead.isNotEmpty) {
        final last = acc.tof(acc.frameIndexOf(r.duration - 1, _fps), _fps);
        final plan = acc.Qa03Plan.plan(fps: _fps, durUs: r.duration, assets: {
          'x': acc.Qa03Plan.video(r.path, w: acc.qaW, h: acc.qaH, durUs: r.duration),
        }, layers: [
          acc.Qa03Plan.media('it_x#v', 'x', [
            [0, last, acc.readLeadUs, last + acc.readLeadUs],
            [last, r.duration, last + acc.readLeadUs, r.duration],
          ]),
        ]);
        final rs = await env.preview(plan);
        try {
          for (final k in framesToRead) {
            expect(acc.exportFrameIndexAt(exportPts, k, _fps), k, reason: 'export frame timing');
            flashAt[k] = _isFlash((await acc.seekAndCapture(rs, k, _fps)).$2);
          }
        } finally {
          await rs.dispose();
        }
      }

      for (final f in flashes) {
        final o = _onset(pcm, 16000, f.tUs);
        final shape = _click(pcm, 16000, f.tUs);
        int? videoFirst;
        if (f.videoFrame != null && f.videoCheck) {
          for (var k = f.videoFrame! - 3; k <= f.videoFrame! + 3; k++) {
            if (flashAt[k] ?? false) {
              videoFirst = k;
              break;
            }
          }
        }
        final audioErrMs = o == null ? null : (o.$1 - f.tUs) / 1000;
        final avMs = o == null || videoFirst == null ? null : (o.$1 - acc.tof(videoFirst, _fps)) / 1000;
        acc.qa03('avsync', {
          'case': c.name,
          'mode': 'export',
          'sourceFrame': f.sourceFrame,
          'rate': f.rate.toStringAsFixed(2),
          'flashTimelineUs': f.tUs.round(),
          'expectedFrame': f.videoFrame ?? 'not shown',
          'videoFirstFlash': f.videoCheck ? (videoFirst ?? 'none') : 'in transition',
          'clickOnsetUs': o?.$1.round(),
          'clickPeak': o?.$2.toStringAsFixed(3),
          'peakAtMs': shape == null ? null : ((shape.$3 - f.tUs) / 1000).toStringAsFixed(2),
          'centroidMs': shape == null ? null : ((shape.$4 - f.tUs) / 1000).toStringAsFixed(2),
          'audioErrMs': audioErrMs?.toStringAsFixed(2),
          'avOffsetMs': avMs?.toStringAsFixed(2),
        });
        if (o == null) {
          failures.add('no click near ${f.tUs.round()} µs');
          continue;
        }
        if (audioErrMs!.abs() > 20 || audioErrMs.abs() * 1000 > _frameUs) failures.add('click at ${f.tUs.round()} µs off by $audioErrMs ms');
        if (f.videoFrame != null && f.videoCheck) {
          if (videoFirst != f.videoFrame) failures.add('flash at frame $videoFirst, expected ${f.videoFrame}');
          if (f.onGrid && avMs != null && avMs.abs() > 20) failures.add('A/V offset $avMs ms at ${f.tUs.round()} µs');
        }
      }
      acc.Qa03Env.discard(r.path);
      expect(failures, isEmpty, reason: failures.join('; '));
    }, skip: skip != null);
  }
}
