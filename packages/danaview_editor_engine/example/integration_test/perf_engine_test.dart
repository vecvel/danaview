// OWNER: QA-04
//
// Native performance and memory budgets through the real plugin (BUILD_PLAN QA-04; ARCH §13.4
// preview budgets, §14.4 export budgets, §18.2 rows whose native half lives in the engine, D-36
// structural renegotiation, D-40 minimal-tier promise): MobileEditorEngine -> Pigeon -> the
// native preview (IOS-11 / AND-16), exporter (IOS-12/17 / AND-11) and thumbnail service.
//
// Rows measured here (each printed as `QA04|<row>|…` for docs/v1.1/editor/qa/QA-04-performance.md):
//
//   export.1080p30         1080p30 H.264, 2 layers + text, ≥ 0.7× RT (low) / ≥ 1.5× (mid)
//   export.workingSet      process RSS peak − baseline during that export, ≤ 220 / 300 / 400 MB
//   preview.firstFrame200  setPlan of a 200-item plan → PreviewFirstFrame, ≤ 1.8 / 1.0 s (§13.4)
//   preview.exactSeek      exact seek on the 1080p H.264 original, p90 ≤ 300 / 200 ms (+30 % on
//                          Android AND-16, D-43(e) point 5)
//   preview.scrubDrag      scrub seeks at 60 Hz while dragging, ack lag p90 ≤ 200 / 120 ms
//   preview.scrubRelease   exact frame after release, ≤ 300 / 200 ms
//   preview.paramPatch     param patch → texture shows it (paused), p90 ≤ 50 / 30 ms (§13.4)
//                          and commit → preview property edit ≤ 150 / 80 ms (§18.2)
//   preview.transient      slider transient → texture, ≤ 3 / 2 frames
//   preview.structural     paused structural patch → frame at the playhead, ≤ 400 / 250 ms
//   preview.nativeMemory   process RSS delta with the preview open (incl. decoder buffers, so an
//                          upper bound of the ≤ 160 / 250 / 350 MB budget)
//   thumb.miss             thumbnail tile on a cache miss, p90 ≤ 400 / 250 ms
//   playback.twoLayers     presented frames while playing 2 layers (captured-marker sampling):
//                          ≥ 24 fps on the minimal tier (D-40); drop share ≤ 2 % / 1 % (§13.4)
//   playback.structural.N  structural edit during playback → playing again with N = 2, 4, 6
//                          visual sequences: ≤ 600 / 400 ms (Android, §13.4 renegotiated D-36
//                          row; ≤ 1,000 / 600 ms in §18.2); recorded on iOS for information
//
// Fixtures are generated on the device (no bundled media): the 1080p30 export of the first test
// (moving noise picture, a PiP copy of it and a text sprite) is the H.264 "original" every later
// preview test decodes. A yellow marker bar, keyframed with one held step per frame, identifies the
// displayed frame in every captured texture.
//
// Budgets are enforced only on real devices in a profile build with --dart-define=QA04_ENFORCE=true
// (simulator and emulator numbers are recorded, never failed; ARCH §21: performance on simulators
// is meaningless). The tier comes from the engine's capabilities unless --dart-define=QA04_TIER=
// minimal|low|mid|high overrides it.
//
//   cd packages/danaview_editor_engine/example
//   flutter test integration_test/perf_engine_test.dart -d <iOS simulator | Android emulator>
//   flutter run --profile -d <device> -t integration_test/perf_engine_test.dart \
//     --dart-define=QA04_ENFORCE=true                     # device lab (profile numbers)
//
// Native compose times (signposts / GL timer queries) are read from Instruments / Perfetto on the
// device lab runs; this file records the Dart-visible end-to-end numbers.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'conformance_test.dart' as qa11;

// =================================================================================================
// QA-04 support: tiers, budgets, report lines
// =================================================================================================

const bool _enforceDefine = bool.fromEnvironment('QA04_ENFORCE');
const String _tierDefine = String.fromEnvironment('QA04_TIER');

/// Whether this run is on a simulator or emulator (numbers recorded, never enforced).
bool get isVirtualDevice {
  if (qa11.Qa11Env.isIosSimulator) return true;
  if (Platform.isAndroid) {
    // Emulator kernels report goldfish / ranchu; the build fingerprint is not visible from Dart.
    final v = Platform.operatingSystemVersion.toLowerCase();
    return v.contains('emulator') || v.contains('sdk_gphone') || File('/dev/goldfish_pipe').existsSync() || File('/dev/qemu_pipe').existsSync();
  }
  return false;
}

/// Whether budgets fail the test (device lab, profile build, QA04_ENFORCE).
bool get enforceBudgets => _enforceDefine && kProfileMode && !isVirtualDevice;

/// The tier the budgets are read for.
DeviceTier tierOf(EditorCapabilities caps) {
  for (final t in DeviceTier.values) {
    if (t.name == _tierDefine) return t;
  }
  return caps.tier;
}

/// Prints one `QA04|row|k=v|…` line.
void qa04(String row, Map<String, Object?> values) =>
    debugPrint('QA04|$row|${values.entries.map((e) => '${e.key}=${e.value}').join('|')}');

/// A budget row: a limit per tier (`null` = no budget on that tier, e.g. minimal latencies, D-40).
final class Budget {
  const Budget(this.row, {this.minimal, this.low, this.mid, this.high, this.higherIsBetter = false, required this.unit});

  final String row;
  final num? minimal, low, mid, high;
  final bool higherIsBetter;
  final String unit;

  /// The limit for [tier] (high falls back to mid, ARCH §18.2 has low and mid columns).
  num? limitFor(DeviceTier tier) => switch (tier) {
        DeviceTier.minimal => minimal,
        DeviceTier.low => low,
        DeviceTier.mid => mid,
        DeviceTier.high => high ?? mid,
      };

  /// Records [value] for [tier]; fails the test when enforced and over budget.
  bool check(DeviceTier tier, num value, [Map<String, Object?> extra = const {}]) {
    final limit = limitFor(tier);
    final pass = limit == null || (higherIsBetter ? value >= limit : value <= limit);
    qa04(row, {
      'tier': tier.name,
      'value': value is double ? value.toStringAsFixed(2) : value,
      'unit': unit,
      'budget': limit == null ? 'none' : '${higherIsBetter ? '>=' : '<='}$limit',
      'pass': limit == null ? 'n/a' : pass,
      'enforced': enforceBudgets,
      'virtual': isVirtualDevice,
      'platform': Platform.operatingSystem,
      ...extra,
    });
    if (enforceBudgets && limit != null) {
      expect(pass, isTrue, reason: '$row: $value $unit vs budget ${higherIsBetter ? '>=' : '<='} $limit on ${tier.name}');
    }
    return pass;
  }
}

/// ARCH §13.4 / §14.4 / §18.2 rows measured natively.
abstract final class EngineBudgets {
  static const exportRt = Budget('export.1080p30', low: 0.7, mid: 1.5, higherIsBetter: true, unit: 'xRT');
  static const exportWorkingSet = Budget('export.workingSet', low: 220, mid: 300, high: 400, unit: 'MB');
  static const firstFrame200 = Budget('preview.firstFrame200', low: 1800, mid: 1000, unit: 'ms');
  static Budget exactSeek(bool android) =>
      Budget('preview.exactSeek', low: android ? 390 : 300, mid: android ? 260 : 200, unit: 'ms p90');
  static const scrubDrag = Budget('preview.scrubDrag', low: 200, mid: 120, unit: 'ms p90');
  static const scrubRelease = Budget('preview.scrubRelease', low: 300, mid: 200, unit: 'ms');
  static const paramPatch = Budget('preview.paramPatch', low: 50, mid: 30, unit: 'ms p90');
  static const commitProperty = Budget('preview.commitProperty', low: 150, mid: 80, unit: 'ms p90');
  static const transient = Budget('preview.transient', low: 3, mid: 2, unit: 'frames p90');
  static const structural = Budget('preview.structural', low: 400, mid: 250, unit: 'ms');
  static const nativeMemory = Budget('preview.nativeMemory', low: 160, mid: 250, high: 350, unit: 'MB');
  static const thumbMiss = Budget('thumb.miss', low: 400, mid: 250, unit: 'ms p90');
  static const minimalFps = Budget('playback.twoLayers.fps', minimal: 24, unit: 'fps');
  static const dropShare = Budget('playback.twoLayers.drop', low: 2, mid: 1, unit: '%');
  static Budget structuralPlaying(int sequences, bool android) =>
      Budget('playback.structural.$sequences', low: android ? 600 : null, mid: android ? 400 : null, unit: 'ms');
}

/// The [p]-th percentile (0–100) of [xs] (nearest rank).
num percentile(List<num> xs, double p) {
  if (xs.isEmpty) return double.nan;
  final s = [...xs]..sort();
  final rank = ((p / 100) * s.length).ceil().clamp(1, s.length);
  return s[rank - 1];
}

/// Samples the process RSS every 50 ms (an upper bound of native + Dart memory).
final class RssSampler {
  RssSampler() : baseline = ProcessInfo.currentRss {
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) => _sample());
  }

  final int baseline;
  int peak = 0;
  late final Timer _timer;

  void _sample() {
    final r = ProcessInfo.currentRss;
    if (r > peak) peak = r;
  }

  /// Stops sampling and returns the peak above [baseline] in MB.
  double stop() {
    _sample();
    _timer.cancel();
    return math.max(0, peak - baseline) / (1024 * 1024);
  }
}

// =================================================================================================
// Fixtures and plans
// =================================================================================================

const int _fps = 30;
const int _exportW = 1920, _exportH = 1080;
const int _exportDurUs = 6000000;
const int _pw = 1280, _ph = 720; // preview canvas

int tof(int k) => (k * 1000000 + _fps - 1) ~/ _fps;

/// x (canvas px) of the frame marker at frame [k] (one held step per frame, period 160 frames).
double markerX(int k, int canvasW) => 20 + (k % 160) * ((canvasW - 40) / 160);

/// The marker over frames `[0, frames)`.
Map<String, Object?> markerLayer(int frames, int canvasW, int canvasH) {
  final keys = <List<num>>[];
  for (var k = 0; k < frames; k++) {
    final x = markerX(k, canvasW);
    keys.add([tof(k), x]);
    keys.add([tof(k + 1) - 1, x]);
  }
  return {
    'id': 'it_marker#v',
    'z': 10010,
    't': [0, tof(frames)],
    'kind': 'solid',
    'color': '#FFFF00FF',
    'base': [4, 24],
    'xf': {'cx': markerX(0, canvasW), 'cy': canvasH - 30},
    'anim': {'xf.cx': keys},
  };
}

/// The frame index shown by a captured [rgba] frame of [w]×[h] for a [canvasW]×[canvasH] plan, or
/// -1 when no marker is visible (frame k mod 160).
int markerFrameOf(Uint8List rgba, int w, int h, int canvasW, int canvasH) {
  final sx = w / canvasW, sy = h / canvasH;
  final y = ((canvasH - 30) * sy).round().clamp(0, h - 1);
  var sum = 0, n = 0;
  for (var x = 0; x < w; x++) {
    final i = (y * w + x) * 4;
    if (rgba[i] > 200 && rgba[i + 1] > 200 && rgba[i + 2] < 80) {
      sum += x;
      n++;
    }
  }
  if (n == 0) return -1;
  final cx = sum / n / sx;
  return ((cx - 20) / ((canvasW - 40) / 160)).round();
}

/// A white text sprite (`.vsprite`) of [w]×[h] px with a few glyph-like bars.
String writeTextSprite(String dir, int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = h ~/ 4; y < 3 * h ~/ 4; y++) {
    for (var x = 0; x < w; x++) {
      if ((x ~/ (h ~/ 3)) % 2 == 0) {
        final i = (y * w + x) * 4;
        rgba[i] = rgba[i + 1] = rgba[i + 2] = rgba[i + 3] = 255;
      }
    }
  }
  final path = '$dir/qa04_text_${w}x$h.vsprite';
  File(path).writeAsBytesSync(VspriteCodec.encodeSync(VspriteImage(width: w, height: h, scale: 1, rgba: rgba)));
  return path;
}

/// A media layer of [asset] over `[t0, t1)` reading source from [s0].
Map<String, Object?> mediaLayer(String id, String asset, int t0, int t1, int s0,
        {int z = 0, int seq = 0, num w = _pw, num h = _ph, num? cx, num? cy, double opacity = 1}) =>
    {
      'id': id,
      'z': z,
      'seq': seq,
      't': [t0, t1],
      'kind': 'media',
      'asset': asset,
      'map': [
        [t0, t1, s0, s0 + (t1 - t0)],
      ],
      'base': [w, h],
      'xf': {'cx': cx ?? w / 2, 'cy': cy ?? h / 2, if (opacity != 1) 'op': opacity},
    };

/// A video asset of the export fixture.
Map<String, Object?> videoAsset(String path) => {
      'kind': 'video',
      'uri': Uri.file(path).toString(),
      'fp': 'qa04_${path.hashCode.toUnsigned(32)}',
      'w': _exportW,
      'h': _exportH,
      'durUs': _exportDurUs,
      'hasAudio': true,
    };

/// A 200-item preview plan on the 1080p original: 160 half-second media items on the main slot,
/// 40 solids on an overlay lane, a white box (patched by the tests) and the frame marker.
(RenderPlan, int) plan200(String video) {
  const n = 160, itemUs = 500000;
  final dur = n * itemUs;
  final frames = (dur * _fps) ~/ 1000000;
  final layers = <Map<String, Object?>>[
    for (var i = 0; i < n; i++)
      mediaLayer('it_m$i#v', 'v', i * itemUs, (i + 1) * itemUs, (i * 733000) % (_exportDurUs - itemUs - 100000)),
    for (var i = 0; i < 40; i++)
      qa11.PlanJsonKit.solid('it_s$i#v', 20, '#3366CCFF', i * 2 * 1000000, i * 2 * 1000000 + 1000000, 160, 90, 1100, 100),
    boxLayer(200),
    markerLayer(frames, _pw, _ph),
  ];
  return (
    planOf(w: _pw, h: _ph, durUs: dur, assets: {'v': videoAsset(video)}, layers: layers),
    frames
  );
}

/// The patched box.
Map<String, Object?> boxLayer(num cx) => qa11.PlanJsonKit.solid('it_box#v', 30, '#FFFFFFFF', 0, 80000000, 60, 60, cx.toDouble(), 360);

/// RenderPlan v1 JSON → plan through the transport (the bytes the engine receives).
RenderPlan planOf({required int w, required int h, required int durUs, Map<String, Object?> assets = const {},
        required List<Map<String, Object?>> layers, List<Map<String, Object?>> audio = const [], String target = 'preview'}) =>
    PlanTransport.decodePlan(Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'rev': 1,
      'target': target,
      'canvas': {'w': w, 'h': h, 'fps': _fps, 'bg': '#000000FF'},
      'durUs': durUs,
      'assets': assets,
      'layers': layers,
      'audio': audio,
    }))));

/// A patch from revision [from].
RenderPlanPatch patchOf(int from, {List<Map<String, Object?>> upsert = const [], List<String> remove = const []}) =>
    PlanTransport.decodePatch(Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'from': from,
      'to': from + 1,
      'layers': {'upsert': upsert, 'remove': remove},
    }))));

/// A transient moving the box to [cx].
PlanTransient boxTransient(num cx) => PlanTransport.decodeTransient(Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'item': 'it_box',
      'layers': [
        {
          'id': 'it_box#v',
          'xf': {'cx': cx, 'cy': 360},
        },
      ],
    }))));

T _typed<T>(Object value) => value as T;

bool _isWhiteAt(Uint8List rgba, int w, int h, int cx, int cy) {
  final fw = rgba.length ~/ 4 ~/ h;
  final x = (cx * fw / _pw).round(), y = (cy * h / _ph).round();
  final i = (y * fw + x) * 4;
  return rgba[i] > 200 && rgba[i + 1] > 200 && rgba[i + 2] > 200;
}

/// Polls captures until [ok] holds; returns elapsed ms (or -1 after [timeoutMs]).
Future<int> pollFrame(PreviewSession s, bool Function(Uint8List rgba, int w, int h) ok, {int timeoutMs = 5000}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < timeoutMs) {
    final f = await s.debugCaptureFrame();
    final size = s.frameSize.value;
    if (size != null && ok(f, size.width.round(), size.height.round())) return sw.elapsedMilliseconds;
  }
  return -1;
}

// =================================================================================================
// Shared environment (one engine, one export fixture for every test)
// =================================================================================================

final class Qa04Env {
  Qa04Env._(this.qa, this.tier);

  static Future<Qa04Env?> open(Directory base) async {
    final qa = await qa11.Qa11Env.open(base);
    if (qa == null) return null;
    final tier = tierOf(qa.caps);
    qa04('caps', {
      'platform': Platform.operatingSystem,
      'os': Platform.operatingSystemVersion.replaceAll('|', '/'),
      'virtual': isVirtualDevice,
      'profile': kProfileMode,
      'engineTier': qa.caps.tier.name,
      'tier': tier.name,
      'maxLayers': qa.caps.maxConcurrentVideoLayers,
      'maxSequences': qa.caps.maxVisualSequences,
      'enforced': enforceBudgets,
    });
    return Qa04Env._(qa, tier);
  }

  final qa11.Qa11Env qa;
  final DeviceTier tier;
  MobileEditorEngineLike get engine => qa.engine;
  String get work => (Directory('${qa.cacheRoot}/work/qa04')..createSync(recursive: true)).path;

  /// The 1080p30 H.264 "original" (set by the export test; generated on demand otherwise).
  String? video;

  /// Exports the 2 layers + text fixture and records the export rows; returns the file.
  Future<String> exportFixture({bool record = true}) async {
    final noise = qa.noise;
    final sprite = writeTextSprite(work, 900, 140);
    final plan = qa11.PlanJsonKit.plan(
      w: _exportW,
      h: _exportH,
      fps: _fps,
      durUs: _exportDurUs,
      assets: {
        'n': qa11.PlanJsonKit.imageAsset(noise, qa11.noiseSide, qa11.noiseSide),
        't': {'kind': 'sprite', 'uri': Uri.file(sprite).toString(), 'fp': 'qa04_text', 'sw': 900, 'sh': 140, 'sscale': 1},
        'a': qa11.PlanJsonKit.audioAsset(qa.tone(1000), 10000000),
      },
      layers: [
        qa11.PlanJsonKit.movingImage('it_bg#v', 'n', 0, _exportDurUs, _exportW, _exportH),
        {
          ...qa11.PlanJsonKit.movingImage('it_pip#v', 'n', 0, _exportDurUs, _exportW, _exportH),
          'z': 10,
          'base': [640, 640],
          'xf': {'cx': 1500, 'cy': 400, 'op': 0.9},
        },
        {
          'id': 'it_text#v',
          'z': 20010, // text band (ARCH §11.3)
          't': [0, _exportDurUs],
          'kind': 'sprite',
          'asset': 't',
          'base': [900, 140],
          'xf': {'cx': 960, 'cy': 900},
        },
      ],
      audio: [
        qa11.PlanJsonKit.audioSeg('au_tone', 'a', [
          [0, _exportDurUs, 0, _exportDurUs],
        ], [
          [0, 1],
        ]),
      ],
    );
    final settings = EncodeSettings(
        container: ExportContainer.mp4, codec: VideoCodec.h264, width: _exportW, height: _exportH, fps: _fps, videoBitrate: 16000000, audioBitrate: 192000);
    final rss = RssSampler();
    final run = await qa.export('qa04_1080p30', plan, settings);
    final workingSetMb = rss.stop();
    if (run.failure != null) fail('export failed: ${run.failure}');
    final rt = _exportDurUs / 1000 / run.wallMs;
    if (record) {
      EngineBudgets.exportRt.check(tier, rt, {
        'wallMs': run.wallMs,
        'durMs': _exportDurUs ~/ 1000,
        'hw': run.result!.hardwareEncoder,
        'encoder': run.result!.videoEncoderName,
        'frames': run.facts?.videoTracks.single.sampleCount,
      });
      EngineBudgets.exportWorkingSet.check(tier, workingSetMb, {'note': 'RSS peak minus baseline'});
    }
    expect(run.facts!.videoTracks.single.sampleEntry, 'avc1');
    final out = '$work/original_1080p30.mp4';
    File(run.result!.path).renameSync(out);
    return video = out;
  }

  Future<String> original() async => video ?? await exportFixture(record: false);

  /// Opens a preview at the preview canvas and waits for the first frame after [plan].
  Future<(PreviewSession, int, PlanAck)> preview(RenderPlan plan, {PreviewQuality quality = PreviewQuality.full}) async {
    final session = await engine
        .openPreview(PreviewConfig(canvasWidth: plan.canvas.w, canvasHeight: plan.canvas.h, fps: plan.canvas.fps, quality: quality, useProxies: false))
        .timeout(const Duration(seconds: 30));
    final first = Completer<void>();
    final sub = session.events.listen((e) {
      if (e is PreviewFirstFrame && !first.isCompleted) first.complete();
      if (e is PreviewFailedEvent && !first.isCompleted) first.completeError(e.failure);
    });
    try {
      final sw = Stopwatch()..start();
      final ack = await session.setPlan(plan).timeout(const Duration(seconds: 60));
      await first.future.timeout(const Duration(seconds: 60));
      return (session, sw.elapsedMilliseconds, ack);
    } finally {
      await sub.cancel();
    }
  }
}

/// The engine as these tests use it.
typedef MobileEditorEngineLike = EditorEngine;

// =================================================================================================
// Tests
// =================================================================================================

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;
  Qa04Env? env;
  var opened = false;

  Future<Qa04Env?> envOf() async {
    if (!opened) {
      opened = true;
      env = await Qa04Env.open(base);
    }
    return env;
  }

  setUpAll(() {
    base = Directory.systemTemp.createTempSync('danaview_qa04_perf');
  });

  tearDownAll(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  test('support: percentile, marker round trip, budgets per tier', () {
    expect(percentile([5, 1, 3, 2, 4], 50), 3);
    expect(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 90), 9);
    expect(percentile([7], 99), 7);
    // Marker decoding at full and half size.
    for (final (w, h) in [(_pw, _ph), (_pw ~/ 2, _ph ~/ 2)]) {
      for (final k in [0, 1, 37, 159]) {
        final rgba = Uint8List(w * h * 4);
        final cx = markerX(k, _pw) * w / _pw;
        final y = ((_ph - 30) * h / _ph).round();
        for (var x = (cx - 2 * w / _pw).round(); x <= (cx + 2 * w / _pw).round(); x++) {
          final i = (y * w + x) * 4;
          rgba[i] = rgba[i + 1] = 255;
          rgba[i + 3] = 255;
        }
        expect(markerFrameOf(rgba, w, h, _pw, _ph), k, reason: 'frame $k at ${w}x$h');
      }
    }
    expect(EngineBudgets.exportRt.limitFor(DeviceTier.low), 0.7);
    expect(EngineBudgets.exportRt.limitFor(DeviceTier.high), 1.5);
    expect(EngineBudgets.nativeMemory.limitFor(DeviceTier.high), 350);
    expect(EngineBudgets.firstFrame200.limitFor(DeviceTier.minimal), isNull, reason: 'D-40: no latency budget on minimal');
    expect(EngineBudgets.exactSeek(true).limitFor(DeviceTier.low), 390, reason: '+30 % on AND-16');
    expect(EngineBudgets.structuralPlaying(4, false).limitFor(DeviceTier.mid), isNull);
  });

  testWidgets('export 1080p30 H.264 with 2 layers + text: speed and working set', (tester) async {
    final e = await envOf();
    if (e == null) return;
    await e.exportFixture();
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('preview: first frame (200 items), exact seeks, scrub, patches, transient, memory', (tester) async {
    final e = await envOf();
    if (e == null) return;
    final video = await e.original();
    final (plan, frames) = plan200(video);
    final rss = RssSampler();
    final (session, firstMs, firstAck) = await e.preview(plan);
    try {
      EngineBudgets.firstFrame200.check(e.tier, firstMs, {'items': 200, 'applyMs': firstAck.applyMs});

      // Exact seeks across the 160 media items (each lands in a different source GOP).
      final rnd = math.Random(0x4a04);
      final seekMs = <num>[];
      var wrong = 0;
      for (var i = 0; i < 60; i++) {
        final k = rnd.nextInt(frames);
        final sw = Stopwatch()..start();
        final ack = await session.seek(tof(k)).timeout(const Duration(seconds: 10));
        seekMs.add(sw.elapsedMilliseconds);
        if (ack.displayedFrame != k) wrong++;
      }
      expect(wrong, 0, reason: 'exact seeks are exact');
      EngineBudgets.exactSeek(Platform.isAndroid).check(e.tier, percentile(seekMs, 90), {
        'p50': percentile(seekMs, 50),
        'max': percentile(seekMs, 100),
        'n': seekMs.length,
      });

      // Scrub drag: one scrub request every 16 ms, as the timeline sends them while dragging
      // (PlayheadController keeps ≤ 1 seek in flight; the engine coalesces the rest).
      final lag = <num>[];
      final pending = <Future<void>>[];
      for (var i = 0; i < 45; i++) {
        final t = tof(300 + i * 4);
        final sw = Stopwatch()..start();
        pending.add(session.seek(t, kind: SeekKind.scrub).then((_) => lag.add(sw.elapsedMilliseconds)));
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      await Future.wait(pending).timeout(const Duration(seconds: 20));
      EngineBudgets.scrubDrag.check(e.tier, percentile(lag, 90), {'p50': percentile(lag, 50), 'n': lag.length});
      final release = Stopwatch()..start();
      final settle = await session.seek(tof(480)).timeout(const Duration(seconds: 10));
      EngineBudgets.scrubRelease.check(e.tier, release.elapsedMilliseconds, {'frame': settle.displayedFrame});
      expect(settle.displayedFrame, 480);

      // Capture overhead (subtracted from the frame-poll numbers below).
      final cap = <num>[];
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        await session.debugCaptureFrame();
        cap.add(sw.elapsedMilliseconds);
      }
      final capMs = percentile(cap, 50);

      // Param patches: move the box; ack (applyMs + channel) and ack → texture.
      var rev = firstAck.rev;
      final patchMs = <num>[], commitMs = <num>[];
      for (var i = 0; i < 12; i++) {
        final cx = i.isEven ? 900 : 200;
        final sw = Stopwatch()..start();
        final ack = await session
            .applyPatch(patchOf(rev, upsert: [boxLayer(cx)]))
            .timeout(const Duration(seconds: 10));
        rev = ack.rev;
        expect(ack.structural, isFalse);
        final shown = await pollFrame(session, (f, w, h) => _isWhiteAt(f, w, h, cx, 360));
        expect(shown, greaterThanOrEqualTo(0), reason: 'patch $i shown');
        final total = sw.elapsedMilliseconds;
        commitMs.add(total);
        patchMs.add(math.max(0, total - capMs));
      }
      EngineBudgets.paramPatch.check(e.tier, percentile(patchMs, 90), {'captureMs': capMs, 'p50': percentile(patchMs, 50)});
      EngineBudgets.commitProperty.check(e.tier, percentile(commitMs, 90),
          {'note': 'engine half (ack + texture incl. capture); UI half in the editor perf suite'});

      // Transients: a slider drag on the box position.
      final trFrames = <num>[];
      for (var i = 0; i < 10; i++) {
        final cx = 300 + 50 * i;
        final sw = Stopwatch()..start();
        session.setTransient(_typed('it_box'), boxTransient(cx));
        final shown = await pollFrame(session, (f, w, h) => _isWhiteAt(f, w, h, cx, 360));
        expect(shown, greaterThanOrEqualTo(0), reason: 'transient $i shown');
        trFrames.add(math.max(0, sw.elapsedMilliseconds - capMs) * _fps / 1000);
      }
      session.clearTransient(_typed('it_box'));
      EngineBudgets.transient.check(e.tier, percentile(trFrames, 90), {'captureMs': capMs});

      // Paused structural patch: a new layer at the playhead.
      final sw = Stopwatch()..start();
      final add = await session
          .applyPatch(patchOf(rev, upsert: [qa11.PlanJsonKit.solid('it_new#v', 40, '#FF00FFFF', 0, 80000000, 80, 80, 640, 200)]))
          .timeout(const Duration(seconds: 10));
      rev = add.rev;
      final shown = await pollFrame(session, (f, w, h) {
        final fw = f.length ~/ 4 ~/ h;
        final i = ((200 * h / _ph).round() * fw + (640 * fw / _pw).round()) * 4;
        return f[i] > 200 && f[i + 1] < 80 && f[i + 2] > 200;
      });
      expect(shown, greaterThanOrEqualTo(0));
      EngineBudgets.structural.check(e.tier, math.max(0, sw.elapsedMilliseconds - capMs),
          {'structural': add.structural, 'applyMs': add.applyMs, 'captureMs': capMs});

      // Native memory while the preview is open (RSS includes decoder buffers and the Dart heap
      // growth of this test, so it over-states the budgeted figure).
      EngineBudgets.nativeMemory.check(e.tier, rss.stop(), {'note': 'RSS delta incl. decoder buffers'});
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('thumbnail tile after scroll stop (cache miss)', (tester) async {
    final e = await envOf();
    if (e == null) return;
    final video = await e.original();
    final media = ResolvedMedia(uri: Uri.file(video).toString(), fingerprint: 'qa04_thumb_${DateTime.now().microsecondsSinceEpoch}');
    final ms = <num>[];
    // Distinct (interval, tile) pairs: none of them is in the disk cache.
    for (var i = 0; i < 16; i++) {
      final sw = Stopwatch()..start();
      final tile = await e.engine.thumbnails
          .request(ThumbnailRequest(media: media, intervalMs: 50 + 7 * i, tileIndex: i % 8, heightPx: 56), priority: ThumbPriority.visible)
          .result
          .timeout(const Duration(seconds: 20));
      ms.add(sw.elapsedMilliseconds);
      expect(tile.frames, greaterThan(0));
      expect(tile.encoded, isNotEmpty);
    }
    EngineBudgets.thumbMiss.check(e.tier, percentile(ms, 90), {'p50': percentile(ms, 50), 'max': percentile(ms, 100), 'n': ms.length});
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('playback at 2 layers: presented frames (D-40 minimal promise, drop share)', (tester) async {
    final e = await envOf();
    if (e == null) return;
    final video = await e.original();
    const dur = _exportDurUs - 200000;
    final frames = (dur * _fps) ~/ 1000000;
    final plan = planOf(w: _pw, h: _ph, durUs: dur, assets: {
      'v': videoAsset(video),
    }, layers: [
      mediaLayer('it_main#v', 'v', 0, dur, 0),
      mediaLayer('it_pip#v', 'v', 0, dur, 100000, z: 10, seq: 1, w: 480, h: 270, cx: 1000, cy: 200),
      markerLayer(frames, _pw, _ph),
    ]);
    final (session, _, _) = await e.preview(plan);
    final clocks = <PreviewClock>[];
    final sub = session.clock.listen(clocks.add);
    try {
      await session.seek(0);
      final seen = <int>{};
      var lastK = -1, maxGapFrames = 0, captures = 0;
      final wall = Stopwatch();
      await session.play();
      wall.start();
      while (wall.elapsedMilliseconds < 4000) {
        final f = await session.debugCaptureFrame();
        captures++;
        final size = session.frameSize.value!;
        final k = markerFrameOf(f, size.width.round(), size.height.round(), _pw, _ph);
        if (k >= 0) {
          seen.add(k);
          if (lastK >= 0 && k > lastK) maxGapFrames = math.max(maxGapFrames, k - lastK);
          lastK = k;
        }
      }
      final elapsedMs = wall.elapsedMilliseconds;
      await session.pause();
      final elapsedFrames = elapsedMs * _fps / 1000;
      final captureHz = captures * 1000 / elapsedMs;
      final fps = seen.length * 1000 / elapsedMs;
      // Sampling only sees every frame when captures outpace playback; below 2× the frame rate the
      // count is a lower bound (recorded as such).
      final exact = captureHz >= 2 * _fps;
      final drop = math.max(0.0, 100 * (1 - seen.length / elapsedFrames));
      final extra = {'captureHz': captureHz.toStringAsFixed(1), 'distinct': seen.length, 'maxGapFrames': maxGapFrames, 'samplingExact': exact};
      EngineBudgets.minimalFps.check(e.tier, fps, extra);
      if (exact) {
        EngineBudgets.dropShare.check(e.tier, drop, extra);
      } else {
        qa04('playback.twoLayers.drop', {'tier': e.tier.name, 'value': drop.toStringAsFixed(2), 'unit': '% (upper bound)', 'pass': 'n/a', ...extra,
          'note': 'capture slower than 2x fps: drop share from native signposts on devices'});
      }
      expect(clocks.any((c) => c.playing), isTrue);
      expect(seen.length, greaterThan(1), reason: 'playback advanced');
    } finally {
      await sub.cancel();
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('structural edit during playback -> playing again at 2, 4 and 6 visual sequences', (tester) async {
    final e = await envOf();
    if (e == null) return;
    final video = await e.original();
    const dur = _exportDurUs - 200000;
    for (final n in [2, 4, 6]) {
      if (n > e.qa.caps.maxVisualSequences) {
        qa04('playback.structural.$n', {'tier': e.tier.name, 'value': 'n/a', 'note': 'above maxVisualSequences ${e.qa.caps.maxVisualSequences}'});
        continue;
      }
      final layers = <Map<String, Object?>>[
        for (var s = 0; s < n; s++)
          mediaLayer('it_l$s#v', 'v', 0, dur, 100000 * s, z: s * 10, seq: s, w: s == 0 ? _pw : 320, h: s == 0 ? _ph : 180,
              cx: s == 0 ? null : 200 + 300 * ((s - 1) % 4), cy: s == 0 ? null : 120 + 220 * ((s - 1) ~/ 4)),
      ];
      final plan = planOf(w: _pw, h: _ph, durUs: dur, assets: {'v': videoAsset(video)}, layers: layers);
      final (session, _, ack0) = await e.preview(plan);
      final clocks = <(int, PreviewClock)>[];
      final wall = Stopwatch()..start();
      final sub = session.clock.listen((c) => clocks.add((wall.elapsedMilliseconds, c)));
      try {
        await session.seek(0);
        await session.play();
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        // Structural: re-cut the top layer (new source in-point) and add one more PiP item.
        final t0 = wall.elapsedMilliseconds;
        final ack = await session
            .applyPatch(patchOf(ack0.rev, upsert: [
              mediaLayer('it_l${n - 1}#v', 'v', 0, dur, 1500000, z: (n - 1) * 10, seq: n - 1, w: n == 1 ? _pw : 320, h: n == 1 ? _ph : 180,
                  cx: 200 + 300 * ((n - 2) % 4), cy: 120 + 220 * ((n - 2) ~/ 4)),
            ]))
            .timeout(const Duration(seconds: 10));
        final ackMs = wall.elapsedMilliseconds - t0;
        // Playing again: two clock samples after the patch, both playing, time advancing.
        var againMs = -1;
        for (var i = 0; i < 400 && againMs < 0; i++) {
          final after = clocks.where((c) => c.$1 >= t0 + ackMs && c.$2.playing).toList();
          for (var j = 1; j < after.length; j++) {
            if (after[j].$2.time > after[j - 1].$2.time) {
              againMs = after[j - 1].$1 - t0;
              break;
            }
          }
          if (againMs < 0) await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(againMs, greaterThanOrEqualTo(0), reason: 'playback resumed after the structural edit ($n sequences)');
        EngineBudgets.structuralPlaying(n, Platform.isAndroid).check(e.tier, againMs, {
          'ackMs': ackMs,
          'structural': ack.structural,
          'note': 'clock sample resolution ~100 ms (10 Hz)',
        });
        await session.pause();
      } finally {
        await sub.cancel();
        await session.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
