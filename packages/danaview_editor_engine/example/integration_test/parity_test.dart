// OWNER: QA-03
//
// Render parity through the real plugin (BUILD_PLAN QA-03, ARCH §11.6 'Parity tolerance', §21.1):
// the API-03 golden corpus (GoldenCases: the CORE-29 contract plans plus API-03's own plans,
// including the 8× scale-keyframed text case) is rendered on the device
//
//   - in preview: `PreviewSession.debugCaptureFrame` after an exact seek to each golden frame;
//   - in export (transform fixtures, text and image cases): the exported file's frames, decoded
//     1:1 through a preview session on the file (the freeze-still job applies colour management,
//     see 'freeze stills keep the decoded colours'),
//
// and compared with the Dart CPU reference renderer (API-03) at the same output size, with the
// §11.6 tolerance: mean |Δ| ≤ 1.5/255 per channel and 99th percentile ≤ 6/255 with layer edges
// excluded (pixels within 1.5 px of a placed layer or canvas-mask edge), SSIM ≥ 0.98 on the
// transform fixtures. Exported frames also exclude content edges (withCodecEdges: 8-bit 4:2:0
// H.264 cannot keep sharp chroma edges at any bitrate); preview captures do not. IOS-10 / AND-10 check the compositor in isolation; this suite checks what
// the user sees (texture capture) and what the user gets (the encoded file).
//
// Sources: the engine needs real files. Images, sprites (.vsprite), LUTs (.vlut) and tones are the
// API-03 synthetic sources written to disk unchanged. Videos are encoded on the device first (one
// H.264 file per video asset: the synthetic frames the goldens use, as image layers at the
// source's rate, exported by the engine), then every frame the goldens use is decoded back 1:1
// through a preview session on that file and handed to the reference renderer, so engine and
// reference see the same decoded pixels.
//
// iOS vs Android: every device render is also written, box-downscaled to the golden's own size, to
// `QA03_OUT/<golden>_f<kkkk>_<preview|export>.png` (default: the test's scratch directory). With
// `QA03_PEER=<dir of the other platform's renders>` each render is compared with the peer's at the
// golden size with the same tolerance (the iOS renders live in docs/v1.1/editor/qa/QA-03-parity/ios).
//
//   cd packages/danaview_editor_engine/example
//   flutter test integration_test/parity_test.dart -d <device> \
//     --dart-define=QA03_MEDIA=$PWD/../test_fixtures/media [--dart-define=QA03_OUT=<dir>] [--dart-define=QA03_PEER=<dir>]
//
// The contract-corpus plans are read from the API-03 fixture tree next to the media
// (QA03_GOLDENS, default `<QA03_MEDIA>/../../../danaview_editor_engine_api/test_fixtures/images`);
// without it only API-03's own plans (compiled into the package) run.

// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:danaview_editor_core/eval.dart' show Offset2, cosSinDeg;
import 'package:danaview_editor_core/model.dart' show FrameRate;
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/src/reference/fixtures/golden_cases.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'accuracy_test.dart' as acc;
import 'conformance_test.dart' as qa11;

/// Fixtures whose content is mostly placement (SSIM is required on them, ARCH §11.6).
const Set<String> transformFixtures = {'api03_place', 'api03_text_scale_8x', 'transition_slide', 'transition_zoom', 'anim_every_channel'};

/// Cases also checked through the exporter.
const Set<String> exportCases = {...transformFixtures, 'api03_typewriter', 'image_solid_layers', 'sprites_export_reveal'};

/// Cases not meaningful on a device here: the offline placeholder needs a missing file and a
/// placeholder the reference does not draw.
const Set<String> skippedCases = {'offline_placeholder'};

// =================================================================================================
// Parity metric (ARCH §11.6), the same definition as IOS-10's CompositorTestSupport.parity
// =================================================================================================

/// Parity of one render against the reference.
final class Parity {
  /// Creates the record.
  const Parity(this.mean, this.p99, this.ssim, this.compared, this.excluded, [this.signed = const [0, 0, 0]]);

  /// Signed mean (device − reference) per channel (0..1): a constant offset is a colour
  /// conversion difference, not a geometry one.
  final List<double> signed;

  /// Largest per-channel mean |Δ| (0..1).
  final double mean;

  /// 99th percentile of |Δ| over all channels (0..1).
  final double p99;

  /// Mean SSIM of luma over 8×8 windows (stride 4) without excluded pixels.
  final double ssim;

  /// Pixels compared / excluded.
  final int compared, excluded;

  /// Whether the §11.6 tolerance holds ([needSsim] on transform fixtures).
  bool ok({required bool needSsim}) => mean <= 1.5 / 255 + 1e-9 && p99 <= 6 / 255 + 1e-9 && (!needSsim || ssim >= 0.98);

  @override
  String toString() =>
      'mean=${(mean * 255).toStringAsFixed(2)}/255 p99=${(p99 * 255).toStringAsFixed(2)}/255 ssim=${ssim.toStringAsFixed(4)} excl=$excluded '
      'signedRGB=${signed.map((v) => (v * 255).toStringAsFixed(1)).join('/')}';
}

/// Compares [got] with [want] (same size, RGBA8) without the [exclude]d pixels.
Parity parity(Uint8List got, Uint8List want, int w, int h, List<bool> exclude) {
  final sums = [0.0, 0.0, 0.0];
  final signed = [0.0, 0.0, 0.0];
  final hist = List<int>.filled(256, 0);
  var n = 0;
  for (var i = 0; i < w * h; i++) {
    if (exclude[i]) continue;
    n++;
    for (var c = 0; c < 3; c++) {
      final sd = got[i * 4 + c] - want[i * 4 + c];
      final d = sd.abs();
      signed[c] += sd / 255;
      sums[c] += d / 255;
      hist[d]++;
    }
  }
  var p99 = 0.0;
  final total = n * 3;
  if (total > 0) {
    final rank = (total * 0.99).ceil();
    var acc = 0;
    for (var d = 0; d < 256; d++) {
      acc += hist[d];
      if (acc >= rank) {
        p99 = d / 255;
        break;
      }
    }
  }
  final mean = n == 0 ? 0.0 : sums.reduce(math.max) / n;
  return Parity(mean, p99, ssim(got, want, w, h, exclude), n, w * h - n, [for (final v in signed) n == 0 ? 0.0 : v / n]);
}

/// Mean SSIM of luma (0…1) over 8×8 windows (stride 4) that contain no excluded pixel.
double ssim(Uint8List a, Uint8List b, int w, int h, List<bool> exclude) {
  double luma(Uint8List px, int i) => (0.2126 * px[i * 4] + 0.7152 * px[i * 4 + 1] + 0.0722 * px[i * 4 + 2]) / 255;
  const c1 = 0.01 * 0.01, c2 = 0.03 * 0.03, win = 8;
  var total = 0.0;
  var count = 0;
  for (var y = 0; y + win <= h; y += 4) {
    for (var x = 0; x + win <= w; x += 4) {
      var skip = false;
      var ma = 0.0, mb = 0.0;
      for (var j = y; j < y + win && !skip; j++) {
        for (var i = x; i < x + win; i++) {
          if (exclude[j * w + i]) {
            skip = true;
            break;
          }
          ma += luma(a, j * w + i);
          mb += luma(b, j * w + i);
        }
      }
      if (skip) continue;
      const nn = win * win;
      ma /= nn;
      mb /= nn;
      var va = 0.0, vb = 0.0, cov = 0.0;
      for (var j = y; j < y + win; j++) {
        for (var i = x; i < x + win; i++) {
          final da = luma(a, j * w + i) - ma, db = luma(b, j * w + i) - mb;
          va += da * da;
          vb += db * db;
          cov += da * db;
        }
      }
      va /= nn - 1;
      vb /= nn - 1;
      cov /= nn - 1;
      total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2));
      count++;
    }
  }
  return count == 0 ? 1 : total / count;
}

/// Pixels within 1.5 px of a placed layer edge or canvas-mask edge at frame time [t], for an output
/// of [w] × [h] (the reference does not antialias edges, ARCH §11.6).
List<bool> edgeMask(RenderPlan plan, int t, int w, int h) {
  final c = plan.canvas;
  final kx = w / c.w, ky = h / c.h;
  final segs = <(Offset2, Offset2)>[];
  for (final l in plan.layers) {
    if (!l.isActiveAt(t)) continue;
    final p = LayerParamSnapshot.at(l, c, t);
    final base = RenderMath.effectiveBase(l, l.asset == null ? null : plan.assets[l.asset], c);
    final m = RenderMath.placement(p.xf, base, c);
    final pts = [
      for (final (x, y) in [(0.0, 0.0), (base.w, 0.0), (base.w, base.h), (0.0, base.h)])
        () {
          final q = m.apply(Offset2(x, y));
          return Offset2(q.dx * kx, q.dy * ky);
        }(),
    ];
    for (var i = 0; i < 4; i++) {
      segs.add((pts[i], pts[(i + 1) % 4]));
    }
    for (final cm in p.cmasks) {
      final (cs, sn) = cosSinDeg(cm.r);
      final q = [
        for (final (u, v) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)])
          () {
            final x = u * cm.w / 2, y = v * cm.h / 2;
            return Offset2((cm.cx + x * cs - y * sn) * kx, (cm.cy + x * sn + y * cs) * ky);
          }(),
      ];
      for (var i = 0; i < 4; i++) {
        segs.add((q[i], q[(i + 1) % 4]));
      }
    }
  }
  final mask = List<bool>.filled(w * h, false);
  for (final (a, b) in segs) {
    final x0 = (math.min(a.dx, b.dx) - 2).floor().clamp(0, w), x1 = (math.max(a.dx, b.dx) + 2).ceil().clamp(0, w);
    final y0 = (math.min(a.dy, b.dy) - 2).floor().clamp(0, h), y1 = (math.max(a.dy, b.dy) + 2).ceil().clamp(0, h);
    final dx = b.dx - a.dx, dy = b.dy - a.dy;
    final l2 = dx * dx + dy * dy;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final px = x + 0.5, py = y + 0.5;
        var u = l2 > 0 ? ((px - a.dx) * dx + (py - a.dy) * dy) / l2 : 0.0;
        u = u.clamp(0.0, 1.0);
        final ex = a.dx + u * dx - px, ey = a.dy + u * dy - py;
        if (ex * ex + ey * ey < 2.25) mask[y * w + x] = true;
      }
    }
  }
  return mask;
}

/// Codec edge pixels of an encoded frame: pixels whose 3×3 neighbourhood in [ref] spans more than
/// [threshold]/255 in any channel, dilated by one pixel, added to [mask]. 8-bit 4:2:0 H.264 cannot
/// keep a sharp chroma edge (a blue/orange checkerboard bleeds across two luma pixels at any
/// bitrate), so exported frames exclude content edges as well as layer edges; preview captures
/// exclude layer edges only (ARCH §11.6 as written).
List<bool> withCodecEdges(List<bool> mask, Uint8List ref, int w, int h, {int threshold = 48}) {
  final edge = List<bool>.filled(w * h, false);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      for (var c = 0; c < 3 && !edge[y * w + x]; c++) {
        var lo = 255, hi = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final v = ref[((y + dy) * w + x + dx) * 4 + c];
            if (v < lo) lo = v;
            if (v > hi) hi = v;
          }
        }
        if (hi - lo > threshold) edge[y * w + x] = true;
      }
    }
  }
  final out = List<bool>.of(mask);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (!edge[y * w + x]) continue;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final yy = y + dy, xx = x + dx;
          if (yy >= 0 && yy < h && xx >= 0 && xx < w) out[yy * w + xx] = true;
        }
      }
    }
  }
  return out;
}

// =================================================================================================
// Device sources
// =================================================================================================

/// One golden case prepared for the device: the plan with file uris and the reference sources.
final class Prepared {
  Prepared(this.name, this.original, this.device, this.sources);

  /// Golden name.
  final String name;

  /// The plan as the reference renders it (synthetic uris).
  final RenderPlan original;

  /// The plan as the engine renders it (local files).
  final Map<String, Object?> device;

  /// Reference sources (decoded device videos, synthetic everything else).
  final ReferenceSources sources;

  /// [device] decoded, as [target].
  RenderPlan devicePlan(String target) {
    final j = jsonDecode(jsonEncode(device)) as Map<String, Object?>;
    j['target'] = target;
    if (target == 'export') {
      j.remove('req');
      for (final a in (j['assets']! as Map<String, Object?>).values) {
        (a! as Map<String, Object?>).remove('proxyUri');
      }
    }
    return acc.Qa03Plan.decodePlanJson(j);
  }
}

String? _goldenDir() {
  const define = String.fromEnvironment('QA03_GOLDENS');
  final media = acc.Qa03Media.dir;
  final dir = define.isNotEmpty ? define : (media == null ? null : '$media/../../../danaview_editor_engine_api/test_fixtures/images');
  return dir != null && File('$dir/goldens.json').existsSync() ? dir : null;
}

Future<Map<String, Object?>?> _planJson(GoldenCase c) async {
  final p = c.plan;
  if (p != null) return jsonDecode(utf8.decode(await PlanTransport.encodePlan(p))) as Map<String, Object?>;
  final dir = _goldenDir();
  if (dir == null) return null;
  return jsonDecode(File('$dir/plans/${c.name}.json').readAsStringSync()) as Map<String, Object?>;
}

int _even(int v) => math.max(16, v + (v & 1));

/// Writes the case's sources to [dir] and encodes its videos (see the header).
Future<Prepared?> prepare(acc.Qa03Env env, GoldenCase c, String dir) async {
  final json = await _planJson(c);
  if (json == null) return null;
  final original = acc.Qa03Plan.decodePlanJson(json);
  if (original.durUs == 0) return null;
  const synth = SyntheticSources();
  final device = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
  final assets = device['assets']! as Map<String, Object?>;
  final videos = <String, ReferenceVideo>{};
  final fpsOut = original.canvas.fps;
  for (final MapEntry(key: id, value: a) in original.assets.entries) {
    final dj = assets[id]! as Map<String, Object?>
      // The written content is display-oriented SDR already (the synthetic sources are), so the
      // device asset carries no rotation and no HDR transfer; `w`/`h` stay the display size.
      ..remove('rot')
      ..remove('transfer');
    final key = SyntheticSources.sourceKey(a);
    switch (a.kind) {
      case PlanAssetKind.image:
        final (w, h) = SyntheticSources.rasterSize(a, synth.imageLongSide);
        final path = '$dir/img_$key.png';
        File(path).writeAsBytesSync(acc.encodePng(synth.imageRgba8(a), w, h));
        dj['uri'] = Uri.file(path).toString();
      case PlanAssetKind.sprite:
        final (rgba, glyphs) = synth.spriteRgba8(a);
        final path = '$dir/sprite_${a.sw}x${a.sh}_${a.reveal == true ? 'r' : 'p'}.vsprite';
        File(path).writeAsBytesSync(VspriteCodec.encodeSync(
            VspriteImage(width: a.sw!, height: a.sh!, scale: a.sscale ?? 1, rgba: rgba, glyphs: a.reveal == true ? glyphs : null)));
        dj['uri'] = Uri.file(path).toString();
      case PlanAssetKind.lut:
        final path = '$dir/lut_${a.n ?? 33}.vlut';
        File(path).writeAsBytesSync(SyntheticSources.vlutBytes(a.n ?? 33));
        dj['uri'] = Uri.file(path).toString();
      case PlanAssetKind.audio:
        final path = '$dir/tone_$key.wav';
        qa11.writeToneWav(path, 440, seconds: math.max(1, ((a.durUs ?? 10000000) / 1e6).ceil()).toDouble());
        dj['uri'] = Uri.file(path).toString();
      case PlanAssetKind.video:
        final (path, durUs, video) = await _encodeVideo(env, c, original, id, a, dir);
        dj['uri'] = Uri.file(path).toString();
        dj['durUs'] = durUs;
        dj.remove('proxyUri');
        dj.remove('bookmark');
        videos[id] = video;
    }
  }
  // Only the frames listed by the golden are compared; keep the output rate.
  expect(original.canvas.fps, fpsOut);
  return Prepared(c.name, original, device, MapReferenceSources(videos: videos, fallback: synth));
}

/// Encodes the synthetic frames a golden's media layers show for video asset [id] into an H.264
/// file at the source's nominal rate, and decodes those frames back.
Future<(String, int, ReferenceVideo)> _encodeVideo(acc.Qa03Env env, GoldenCase c, RenderPlan plan, String id, PlanAsset a, String dir) async {
  final fps = SyntheticSources.nominalFps(a);
  const longSide = 256;
  final synth = const SyntheticSources(videoLongSide: longSide);
  final (rw, rh) = SyntheticSources.rasterSize(a, longSide);
  final vw = _even(rw), vh = _even(rh);
  final needed = <int>{};
  var maxS = 0;
  final rate = FrameRate(plan.canvas.fps, 1);
  for (final l in plan.layers.where((l) => l.asset == id)) {
    for (final m in l.map) {
      maxS = math.max(maxS, m.s1);
    }
    for (final k in c.frames) {
      final t = rate.timeOfFrame(k);
      if (!l.isActiveAt(t)) continue;
      double s = l.map.first.s0.toDouble();
      if (!l.hold) {
        for (final m in l.map) {
          if (t >= m.t0 && t < m.t1) s = m.s0 + (t - m.t0) * (m.s1 - m.s0) / (m.t1 - m.t0);
        }
      }
      final j = ((s + 500) * fps / 1e6).floor();
      needed.addAll([j - 1, j, j + 1].where((x) => x >= 0));
    }
  }
  // Whole seconds (an exact-µs duration) covering every mapped source time.
  final frames = ((((maxS + 1) * fps / 1e6).ceil() + 2 + fps - 1) ~/ fps) * fps;
  final durUs = acc.tof(frames, fps);
  final layerAssets = <String, Object?>{};
  final layers = <Map<String, Object?>>[
    acc.Qa03Plan.solid('it_bg#v', 10, '#404040FF', 0, durUs, vw, vh, vw / 2, vh / 2),
  ];
  for (final j in needed.where((j) => j < frames)) {
    final path = '$dir/v_${SyntheticSources.sourceKey(a)}_$j.png';
    File(path).writeAsBytesSync(acc.encodePng(synth.videoFrameRgba8(a, j), rw, rh));
    layerAssets['f$j'] = {'kind': 'image', 'uri': Uri.file(path).toString(), 'fp': 'qa03_v_$j', 'w': rw, 'h': rh};
    layers.add({
      'id': 'it_f$j#v',
      'z': 20,
      't': [acc.tof(j, fps), acc.tof(j + 1, fps)],
      'kind': 'image',
      'asset': 'f$j',
      'base': [vw, vh],
      'xf': {'cx': vw / 2, 'cy': vh / 2},
    });
  }
  final gen = acc.Qa03Plan.plan(target: 'export', w: vw, h: vh, fps: fps, durUs: durUs, assets: layerAssets, layers: layers);
  final name = 'src_${c.name}_$id'.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
  final r = await env.export(name, gen, videoBitrate: 4000000);
  final path = '$dir/$name.mp4';
  File(r.path).renameSync(path);
  final pts = acc.videoPts(path);
  final decoded = <int, RenderRaster>{};
  final ks = needed.where((j) => j < pts.length).toList()..sort();
  final got = await acc.readFramesOf(env, path, durUs, fps, ks, w: vw, h: vh);
  for (var i = 0; i < ks.length; i++) {
    expect(acc.exportFrameIndexAt(pts, ks[i], fps), ks[i], reason: '$name: source frame timing');
    expect((got[i].w, got[i].h), (vw, vh), reason: '$name: 1:1 decode');
    decoded[ks[i]] = RenderRaster.fromStraightRgba8(got[i].px, got[i].w, got[i].h);
  }
  final video = ReferenceVideo.withPts([for (final p in pts) p.round()], frame: (j) {
    final f = decoded[j];
    if (f == null) throw StateError('${c.name}: reference asked for undecoded frame $j of $id');
    return f;
  });
  return (path, durUs, video);
}

// =================================================================================================
// Comparison and output
// =================================================================================================

/// The golden's own output size.
(int, int) goldenSize(GoldenCase c, PlanCanvas canvas) => ReferenceRenderer(longSide: c.longSide).outputSizeOf(canvas);

/// Compares one device render with the reference and records it; returns a failure or null.
String? compareRender(Prepared p, GoldenCase c, int k, acc.Rgba got, String mode, String outDir) {
  final plan = p.original;
  final t = FrameRate(plan.canvas.fps, 1).timeOfFrame(k);
  final renderer = ReferenceRenderer(sources: p.sources, longSide: math.max(got.w, got.h));
  final (rw, rh) = renderer.outputSizeOf(plan.canvas);
  final dev = got.w == rw && got.h == rh ? got : got.downscale(rw, rh);
  final want = renderer.renderFrame(plan, t);
  final layerEdges = edgeMask(plan, t, rw, rh);
  final par = parity(dev.px, want, rw, rh, mode == 'export' ? withCodecEdges(layerEdges, want, rw, rh) : layerEdges);
  final needSsim = transformFixtures.contains(c.name);
  final ok = par.ok(needSsim: needSsim);
  acc.qa03('parity', {'case': c.name, 'k': k, 'mode': mode, 'size': '${rw}x$rh', 'result': par.toString(), 'ok': ok});

  // iOS vs Android renders at the golden size.
  final (gw, gh) = goldenSize(c, plan.canvas);
  final small = dev.downscale(gw, gh);
  final file = '${c.name}_f${k.toString().padLeft(4, '0')}_$mode.png';
  File('$outDir/$file').writeAsBytesSync(acc.encodePng(small.px, gw, gh, rgb: true));
  const debugDir = String.fromEnvironment('QA03_DEBUG');
  if (debugDir.isNotEmpty && !ok) {
    Directory(debugDir).createSync(recursive: true);
    File('$debugDir/${file.replaceAll('.png', '_got.png')}').writeAsBytesSync(acc.encodePng(dev.px, rw, rh, rgb: true));
    File('$debugDir/${file.replaceAll('.png', '_want.png')}').writeAsBytesSync(acc.encodePng(want, rw, rh, rgb: true));
  }
  return ok ? null : '${c.name} k=$k $mode: $par${needSsim ? ' (ssim required)' : ''}';
}

/// Compares this device's golden-size renders in [outDir] with the peer platform's.
Future<List<String>> comparePeer(String outDir, String peerDir, Map<String, (RenderPlan, GoldenCase)> byName) async {
  final failures = <String>[];
  var n = 0;
  for (final f in Directory(outDir).listSync().whereType<File>().where((f) => f.path.endsWith('.png'))) {
    final file = f.uri.pathSegments.last;
    final peer = File('$peerDir/$file');
    if (!peer.existsSync()) continue;
    final m = RegExp(r'^(.*)_f(\d{4})_(preview|export)\.png$').firstMatch(file);
    if (m == null) continue;
    final entry = byName[m.group(1)];
    if (entry == null) continue;
    final (plan, c) = entry;
    final k = int.parse(m.group(2)!);
    final a = await acc.decodePng(f.readAsBytesSync());
    final b = await acc.decodePng(peer.readAsBytesSync());
    if (a.w != b.w || a.h != b.h) {
      failures.add('$file: size ${a.w}x${a.h} vs ${b.w}x${b.h}');
      continue;
    }
    final t = FrameRate(plan.canvas.fps, 1).timeOfFrame(k);
    final edges = edgeMask(plan, t, a.w, a.h);
    final par = parity(a.px, b.px, a.w, a.h, m.group(3) == 'export' ? withCodecEdges(withCodecEdges(edges, a.px, a.w, a.h), b.px, a.w, a.h) : edges);
    final ok = par.ok(needSsim: transformFixtures.contains(c.name));
    n++;
    acc.qa03('peer', {'file': file, 'result': par.toString(), 'ok': ok});
    if (!ok) failures.add('$file: $par');
  }
  acc.qa03('peer', {'compared': n, 'failures': failures.length});
  if (n == 0) failures.add('no peer render matched in $peerDir');
  return failures;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('danaview_qa03_par'));
  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  group('support self-checks', () {
    test('parity metric: identical, offset by 1, edge mask', () {
      const w = 32, h = 16;
      final a = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 128);
      final b = Uint8List.fromList([for (final v in a) v + 1]);
      final none = List<bool>.filled(w * h, false);
      expect(parity(a, a, w, h, none).mean, 0);
      expect(parity(a, a, w, h, none).ssim, closeTo(1, 1e-9));
      final p = parity(a, b, w, h, none);
      expect(p.mean * 255, closeTo(1, 1e-9));
      expect(p.p99 * 255, closeTo(1, 1e-9));
      expect(p.ok(needSsim: true), isTrue);
      final plan = acc.Qa03Plan.plan(fps: 30, durUs: 1000000, w: 320, h: 160, layers: [
        acc.Qa03Plan.solid('it_s#v', 10, '#FF0000FF', 0, 1000000, 100, 50, 160, 80),
      ]);
      final mask = edgeMask(plan, 0, w, h);
      // The box spans x 110..210, y 55..105 at canvas scale; at 32×16 that is x 11..21, y 5.5..10.5.
      expect(mask[8 * w + 11], isTrue);
      expect(mask[8 * w + 16], isFalse);
      expect(mask[0], isFalse);
    });

    test('golden corpus is reachable', () {
      expect(GoldenCases.all.length, greaterThanOrEqualTo(25));
      expect(GoldenCases.all.where((c) => c.plan != null).map((c) => c.name), contains('api03_text_scale_8x'));
    });
  });

  testWidgets('freeze stills keep the decoded colours (colour management off, ARCH §11.6)', (tester) async {
    // A freeze still replaces video frames on the timeline (freeze frame, pending-still hold), so
    // it must carry the same pixels the preview and the exporter decode. Solid colours exported
    // by the engine are read back three ways: preview decode (1:1), freeze still, and expected.
    final env = await acc.Qa03Env.open(base);
    if (env == null) return;
    const colors = [0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFF808080, 0xFFC08040, 0xFF202020];
    String hex(int c) => '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}FF';
    final plan = acc.Qa03Plan.plan(target: 'export', fps: 30, durUs: 1000000, layers: [
      for (var i = 0; i < colors.length; i++)
        acc.Qa03Plan.solid('it_c$i#v', 10 + 10 * i, hex(colors[i]), 0, 1000000, acc.qaW / colors.length, acc.qaH, (i + 0.5) * acc.qaW / colors.length, acc.qaH / 2),
    ]);
    final r = await env.export('freeze_colour', plan);
    final viaPreview = (await acc.readFramesOf(env, r.path, r.duration, 30, [10])).single;
    final viaFreeze = await env.freeze(r.path, acc.tof(10, 30) + acc.readLeadUs, tag: 'colour');
    // The export encodes BT.709 (ARCH §11.6). The platform's GL sampler picks the YUV→RGB matrix
    // of the read-back: BT.709 on devices, BT.601 on the x86_64 emulator whatever the stream
    // signals (measured: SourceFrameCacheTest, PrecomposePlanner). Each read-back must match the
    // round trip of ONE matrix within 3 for every colour, and the freeze still the same one as the
    // preview decode.
    final worstPreview = [0, 0], worstFreeze = [0, 0]; // [BT.709 read-back, BT.601 read-back]
    for (var i = 0; i < colors.length; i++) {
      final want = [(colors[i] >> 16) & 0xFF, (colors[i] >> 8) & 0xFF, colors[i] & 0xFF];
      final want601 = _bt709EncodeBt601Decode(want);
      final x = ((i + 0.5) * acc.qaW / colors.length).round();
      final pv = viaPreview.at(x * viaPreview.w ~/ acc.qaW, viaPreview.h ~/ 2);
      final fz = viaFreeze.at(x * viaFreeze.w ~/ acc.qaW, viaFreeze.h ~/ 2);
      for (var ch = 0; ch < 3; ch++) {
        worstPreview[0] = math.max(worstPreview[0], (pv[ch] - want[ch]).abs());
        worstPreview[1] = math.max(worstPreview[1], (pv[ch] - want601[ch]).abs());
        worstFreeze[0] = math.max(worstFreeze[0], (fz[ch] - want[ch]).abs());
        worstFreeze[1] = math.max(worstFreeze[1], (fz[ch] - want601[ch]).abs());
      }
      acc.qa03('colour', {'color': hex(colors[i]), 'preview': pv.join(','), 'freeze': fz.join(','), 'bt601ReadBack': want601.join(',')});
    }
    final m = worstPreview[0] <= worstPreview[1] ? 0 : 1;
    acc.qa03('colour', {
      'worstPreviewDelta': worstPreview[m],
      'worstFreezeDelta': worstFreeze[m],
      'readBackMatrix': m == 0 ? 'BT.709' : 'BT.601',
      'worstPreviewDelta709': worstPreview[0],
      'worstPreviewDelta601': worstPreview[1],
    });
    acc.Qa03Env.discard(r.path);
    expect(worstPreview[m], lessThanOrEqualTo(3), reason: 'export + preview decode round trip (${m == 0 ? 'BT.709' : 'BT.601'} read-back)');
    expect(worstFreeze[m], lessThanOrEqualTo(3), reason: 'freeze still colours differ from the decoded video');
  });

  testWidgets('render parity: preview captures and exported frames vs the reference; iOS vs Android renders', (tester) async {
    final env = await acc.Qa03Env.open(base);
    if (env == null) return;
    final outDir = acc.Qa03Dirs.out('${env.work}/renders');
    acc.qa03('parity', {'goldens': _goldenDir() ?? 'API-03 plans only', 'out': outDir});
    final failures = <String>[];
    final byName = <String, (RenderPlan, GoldenCase)>{};
    var frames = 0, cases = 0;
    for (final c in GoldenCases.all) {
      if (skippedCases.contains(c.name)) continue;
      final dir = (Directory('${env.work}/src_${c.name}')..createSync(recursive: true)).path;
      final Prepared? p;
      try {
        p = await prepare(env, c, dir);
      } on EngineFailure catch (e) {
        failures.add('${c.name}: preparing sources failed: $e');
        continue;
      }
      if (p == null) {
        acc.qa03('parity', {'case': c.name, 'skipped': 'plan unavailable or empty'});
        continue;
      }
      cases++;
      byName[c.name] = (p.original, c);
      final canvas = p.original.canvas;
      final long = math.max(canvas.w, canvas.h);
      final quality = long <= 640 ? PreviewQuality.full : (long <= 1280 ? PreviewQuality.half : PreviewQuality.quarter);

      // ---- preview ----
      try {
        final s = await env.preview(p.devicePlan('preview'), quality: quality);
        try {
          for (final k in c.frames) {
            final (_, got) = await acc.seekAndCapture(s, k, canvas.fps);
            frames++;
            final bad = compareRender(p, c, k, got, 'preview', outDir);
            if (bad != null) failures.add(bad);
          }
        } finally {
          await s.dispose();
        }
      } on Exception catch (e) {
        failures.add('${c.name}: preview failed: $e');
      }

      // ---- export ----
      if (exportCases.contains(c.name)) {
        try {
          final bitrate = canvas.w * canvas.h * 12;
          final r = await env.export('parity_${c.name}', p.devicePlan('export'), videoBitrate: bitrate);
          final ks = c.frames.where((k) => FrameRate(canvas.fps, 1).timeOfFrame(k) < r.duration).toList();
          final got = await acc.readFramesOf(env, r.path, r.duration, canvas.fps, ks, w: canvas.w, h: canvas.h);
          for (var i = 0; i < ks.length; i++) {
            frames++;
            final bad = compareRender(p, c, ks[i], got[i], 'export', outDir);
            if (bad != null) failures.add(bad);
          }
          acc.Qa03Env.discard(r.path);
        } on Exception catch (e) {
          failures.add('${c.name}: export failed: $e');
        }
      }
      Directory(dir).deleteSync(recursive: true);
    }
    acc.qa03('parity', {'cases': cases, 'frames': frames, 'failures': failures.length});
    final peer = acc.Qa03Dirs.peer;
    if (peer != null) failures.addAll(await comparePeer(outDir, peer, byName));
    expect(cases, greaterThanOrEqualTo(8));
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, skip: acc.Qa03Media.skipReason != null);
}

/// [rgb] (8-bit) encoded with the BT.709 limited-range matrix and decoded with the BT.601 one (the
/// x86_64 emulator's GL sampler), rounded and clamped like the read-back.
List<int> _bt709EncodeBt601Decode(List<int> rgb) {
  final r = rgb[0] / 255, g = rgb[1] / 255, b = rgb[2] / 255;
  final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final cb = (b - y) / 1.8556, cr = (r - y) / 1.5748;
  // Quantised to 8-bit video range, as the encoder stores it.
  final yq = (16 + 219 * y).round(), cbq = (128 + 224 * cb).round(), crq = (128 + 224 * cr).round();
  final y1 = (yq - 16) / 219, pb = (cbq - 128) / 224, pr = (crq - 128) / 224;
  int c(double v) => (v * 255).round().clamp(0, 255);
  return [c(y1 + 1.402 * pr), c(y1 - 0.344136 * pb - 0.714136 * pr), c(y1 + 1.772 * pb)];
}
