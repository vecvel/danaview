// OWNER: QA-03
//
// Frame accuracy through the real plugin (BUILD_PLAN QA-03, ARCH §21.1 'Parity, accuracy, A/V
// sync', §5 / D-35, §11.5, §12.2): MobileEditorEngine -> Pigeon -> the native preview (IOS-11 /
// AND-10), exporter (IOS-12 / AND-11) and media jobs (IOS-06/07, AND-06/07, proxies), checked from
// Dart on the ENG-05 frame-counter fixtures with the ENG-05 barcode reader:
//
//   1. exact seeks: 200/200 through 1×, 2× and 0.5× map segments, then 200/200 again after a
//      structural patch (re-cut, 2× segment, new overlay layer);
//   2. grid-cut case (D-35) at 24, 30, 48 and 60 fps: cuts at frames k ≡ 1 and k ≡ 2 (mod 3), every
//      frame of the 3 s window around each cut shows the expected barcode in exact-seek preview, in
//      playback capture and in the export (read back frame by frame, plus native freeze stills at
//      the cuts);
//   3. reverse rendition: barcodes strictly decreasing, frame by frame;
//   4. freeze stills: barcode exact (frame starts and mid-frame times, four rates);
//   5. proxies: presentation timestamps equal to the original (CFR and VFR) and the proxy shows the
//      same barcode at exact seeks.
//
// Every captured frame carries two independent identities: the source barcode (top band, ENG-05)
// and a timeline marker, a yellow square whose slot (x position) is the timeline frame index mod 8,
// keyframed with held steps so it changes exactly at each frame start. A frame shown one frame off
// at a cut has the right barcode for the wrong marker slot.
//
// Media: the ENG-05 fixtures are not bundled in the example host (ENG-09 owns its pubspec), so the
// tests read them from the directory passed as QA03_MEDIA (an iOS simulator reads host paths
// directly; on Android push the directory to the app's external files dir first):
//
//   cd packages/danaview_editor_engine/example
//   flutter test integration_test/accuracy_test.dart -d <device> \
//     --dart-define=QA03_MEDIA=$PWD/../test_fixtures/media
//
// Without QA03_MEDIA the media tests are skipped (visibly). This file also holds the QA-03 support
// code (fixture lookup, plan builders, PNG codec, MP4 timestamp reader, frame reader, export and
// preview helpers) that av_sync_test.dart and parity_test.dart import with a prefix. Every
// measured row is printed as `QA03|…` for docs/v1.1/editor/qa/QA-03-parity.md.

// The example host depends on the engine and its API only (ENG-09 owns the pubspec); core is
// reached transitively for TimeRange.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:danaview_editor_core/model.dart' show TimeRange;
import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_editor_engine/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_example/engine_host.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// =================================================================================================
// QA-03 support: time, fixtures, environment
// =================================================================================================

/// `timeOfFrame(k) = ceil(k·10⁶/fps)` (ARCH §5, D-03).
int tof(int k, int fps) => (k * 1000000 + fps - 1) ~/ fps;

/// `frameIndexOf(t)`: the largest k with `timeOfFrame(k) ≤ t` (ARCH §5).
int frameIndexOf(int t, int fps) {
  var k = (t * fps) ~/ 1000000;
  while (tof(k + 1, fps) <= t) {
    k++;
  }
  while (k > 0 && tof(k, fps) > t) {
    k--;
  }
  return k;
}

/// The source frame displayed for exact source time [sUs] of a constant-rate source at [fps]:
/// the greatest PTS `i·10⁶/fps` ≤ s + 500 µs (ARCH §11.5).
int displayedSourceFrame(double sUs, int fps) => ((sUs + 500) * fps / 1e6).floor();

/// The frame with the greatest PTS ≤ [targetUs] in sorted [ptsUs] (clamped to the first frame).
int frameAtOrBefore(List<double> ptsUs, double targetUs) {
  var lo = 0, hi = ptsUs.length - 1;
  if (targetUs < ptsUs.first) return 0;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (ptsUs[mid] <= targetUs) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// Video presentation timestamps (µs) of a file, cached per path.
final Map<String, List<double>> _ptsCache = {};
List<double> videoPts(String path) =>
    _ptsCache[path] ??= readTrackTimes(File(path).readAsBytesSync()).firstWhere((t) => t.handler == 'vide').ptsUs;

/// Where the ENG-05 media lives on this device (QA03_MEDIA), null when unavailable.
abstract final class Qa03Media {
  static const String _define = String.fromEnvironment('QA03_MEDIA');

  /// The fixture directory, or null.
  static String? get dir {
    if (_define.isEmpty) return null;
    return File('$_define/manifest.json').existsSync() ? _define : null;
  }

  /// Skip reason for media tests (null when the media is here).
  static String? get skipReason => dir != null
      ? null
      : 'QA03_MEDIA not set or not readable (pass --dart-define=QA03_MEDIA=<packages/danaview_editor_engine/test_fixtures/media>)';

  /// Absolute path of fixture [name].
  static String path(String name) {
    final d = dir;
    if (d == null) throw StateError(skipReason!);
    final p = '$d/$name';
    if (!File(p).existsSync()) throw StateError('fixture $name missing in $d');
    return p;
  }
}

/// Output directories for renders (QA03_OUT) and the other platform's renders (QA03_PEER).
abstract final class Qa03Dirs {
  static const String _out = String.fromEnvironment('QA03_OUT');
  static const String _peer = String.fromEnvironment('QA03_PEER');

  /// Where renders are written: QA03_OUT, else [fallback].
  static String out(String fallback) {
    final d = Directory(_out.isEmpty ? fallback : _out)..createSync(recursive: true);
    return d.path;
  }

  /// The peer render directory, or null.
  static String? get peer => _peer.isNotEmpty && Directory(_peer).existsSync() ? _peer : null;
}

/// Prints one `QA03|kind|k=v|…` report line.
void qa03(String kind, Map<String, Object?> values) =>
    debugPrint('QA03|$kind|${values.entries.map((e) => '${e.key}=${e.value}').join('|')}');

/// Whether this is an iOS simulator.
bool get isIosSimulator =>
    Platform.isIOS &&
    (Platform.environment.containsKey('SIMULATOR_DEVICE_NAME') || Directory.systemTemp.path.contains('/CoreSimulator/'));

/// The engine, its roots and helpers of one test.
final class Qa03Env {
  Qa03Env._(this.base, this.engine, this.caps);

  /// Opens the engine (null when the engine is not supported here).
  static Future<Qa03Env?> open(Directory base) async {
    final engine = createExampleEngine(base: base);
    final caps = await engine.capabilities().timeout(const Duration(seconds: 30));
    if (!caps.supported) {
      debugPrint('QA03 engine not supported here (${caps.unsupportedReason}); skipping');
      return null;
    }
    qa03('caps', {
      'platform': Platform.operatingSystem,
      'os': Platform.operatingSystemVersion.replaceAll('|', '/'),
      'simulator': isIosSimulator,
      'tier': caps.tier.name,
    });
    return Qa03Env._(base, engine, caps);
  }

  /// Temp root.
  final Directory base;

  /// The engine.
  final MobileEditorEngine engine;

  /// Its capabilities.
  final EditorCapabilities caps;

  /// `<cache>/danaview/editor` (as `createExampleEngine` lays it out).
  String get cacheRoot => '${base.path}/cache/danaview/editor';

  /// Scratch directory inside the cache root (the engine may write there).
  String get work => (Directory('$cacheRoot/work/qa03')..createSync(recursive: true)).path;

  /// A [ResolvedMedia] for a local file.
  static ResolvedMedia media(String path, [String? fp]) =>
      ResolvedMedia(uri: Uri.file(path).toString(), fingerprint: fp ?? 'qa03_${path.hashCode.toUnsigned(32)}');

  /// Opens a preview session on [plan] and waits for its first frame.
  Future<PreviewSession> preview(RenderPlan plan, {PreviewQuality quality = PreviewQuality.full, bool useProxies = false}) async {
    final c = plan.canvas;
    final session = await engine
        .openPreview(PreviewConfig(canvasWidth: c.w, canvasHeight: c.h, fps: c.fps, quality: quality, useProxies: useProxies))
        .timeout(const Duration(seconds: 30));
    final first = Completer<void>();
    final sub = session.events.listen((e) {
      if (e is PreviewFirstFrame && !first.isCompleted) first.complete();
      if (e is PreviewFailedEvent && !first.isCompleted) first.completeError(e.failure);
    });
    try {
      await session.setPlan(plan).timeout(const Duration(seconds: 60));
      await first.future.timeout(const Duration(seconds: 30));
    } finally {
      await sub.cancel();
    }
    return session;
  }

  /// Exports [plan] to `<work>/<name>.mp4` (H.264, AAC) and returns the result.
  Future<ExportResult> export(String name, RenderPlan plan, {int? width, int? height, int? fps, int videoBitrate = 8000000}) async {
    final c = plan.canvas;
    final settings = EncodeSettings(width: width ?? c.w, height: height ?? c.h, fps: fps ?? c.fps, videoBitrate: videoBitrate);
    final out = '$work/$name.mp4';
    await engine.exporter.preflight(plan, settings).timeout(const Duration(seconds: 60));
    final sw = Stopwatch()..start();
    final job = await engine.exporter.start(plan, settings,
        outputPath: out, title: 'QA-03 $name', whenDetached: ExportDetachedHandoff.keepForLater);
    final r = await job.result.timeout(const Duration(minutes: 8));
    qa03('export', {'name': name, 'ms': sw.elapsedMilliseconds, 'encoder': r.videoEncoderName, 'hw': r.hardwareEncoder, 'durUs': r.duration});
    return r;
  }

  /// Runs the freeze-still job on [path] at [sourceUs] and decodes the PNG.
  Future<Rgba> freeze(String path, int sourceUs, {String tag = 'f'}) async {
    final out = '$work/freeze_${tag}_$sourceUs.png';
    final job = engine.jobs.freezeFrame(media(path), sourceUs, outputPath: out);
    final r = await job.result.timeout(const Duration(seconds: 60));
    final img = await decodePng(File(r.path).readAsBytesSync());
    try {
      File(r.path).deleteSync();
    } on FileSystemException {
      // already gone
    }
    return img;
  }

  /// Deletes [path] when it exists (keeps the scratch directory small on 8 GB machines).
  static void discard(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // already gone
    }
  }
}

// =================================================================================================
// QA-03 support: pixels and PNG
// =================================================================================================

/// An RGBA8 picture.
final class Rgba {
  /// Creates a picture.
  const Rgba(this.px, this.w, this.h);

  /// Straight RGBA bytes, row-major.
  final Uint8List px;

  /// Width.
  final int w;

  /// Height.
  final int h;

  /// Pixel at (x, y) as [r, g, b].
  List<int> at(int x, int y) {
    final i = (y * w + x) * 4;
    return [px[i], px[i + 1], px[i + 2]];
  }

  /// Box-downscales to [tw] × [th] (area average; both ≤ the source size).
  Rgba downscale(int tw, int th) {
    if (tw == w && th == h) return this;
    final out = Uint8List(tw * th * 4);
    for (var ty = 0; ty < th; ty++) {
      final y0 = ty * h / th, y1 = (ty + 1) * h / th;
      for (var tx = 0; tx < tw; tx++) {
        final x0 = tx * w / tw, x1 = (tx + 1) * w / tw;
        final acc = [0.0, 0.0, 0.0, 0.0];
        var area = 0.0;
        for (var y = y0.floor(); y < y1.ceil() && y < h; y++) {
          final wy = math.min(y + 1.0, y1) - math.max(y.toDouble(), y0);
          for (var x = x0.floor(); x < x1.ceil() && x < w; x++) {
            final wx = math.min(x + 1.0, x1) - math.max(x.toDouble(), x0);
            final a = wx * wy;
            final i = (y * w + x) * 4;
            for (var c = 0; c < 4; c++) {
              acc[c] += px[i + c] * a;
            }
            area += a;
          }
        }
        final o = (ty * tw + tx) * 4;
        for (var c = 0; c < 4; c++) {
          out[o + c] = (acc[c] / area).round().clamp(0, 255);
        }
      }
    }
    return Rgba(out, tw, th);
  }
}

/// Decodes a PNG/JPEG with the engine-independent Flutter codec (straight RGBA).
Future<Rgba> decodePng(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final img = frame.image;
  final data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  final out = Rgba(data!.buffer.asUint8List(), img.width, img.height);
  img.dispose();
  codec.dispose();
  return out;
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

/// Encodes straight RGBA8 as an 8-bit RGBA PNG (or RGB when [rgb]).
Uint8List encodePng(Uint8List rgba, int w, int h, {bool rgb = false}) {
  final ch = rgb ? 3 : 4;
  final raw = Uint8List(h * (w * ch + 1));
  var p = 0;
  for (var y = 0; y < h; y++) {
    raw[p++] = 0;
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      raw[p++] = rgba[i];
      raw[p++] = rgba[i + 1];
      raw[p++] = rgba[i + 2];
      if (!rgb) raw[p++] = rgba[i + 3];
    }
  }
  final out = BytesBuilder();
  void chunk(String type, List<int> body) {
    out.add((ByteData(4)..setUint32(0, body.length)).buffer.asUint8List());
    final tb = [...type.codeUnits, ...body];
    out.add(tb);
    out.add((ByteData(4)..setUint32(0, _crc32(tb))).buffer.asUint8List());
  }

  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  chunk(
      'IHDR',
      (ByteData(13)
            ..setUint32(0, w)
            ..setUint32(4, h)
            ..setUint8(8, 8)
            ..setUint8(9, rgb ? 2 : 6))
          .buffer
          .asUint8List());
  chunk('IDAT', ZLibEncoder(level: 6).convert(raw));
  chunk('IEND', const []);
  return out.toBytes();
}

// =================================================================================================
// QA-03 support: MP4 presentation timestamps (stts + ctts + elst)
// =================================================================================================

/// Presentation timestamps of one track.
final class TrackTimes {
  /// Creates the record.
  TrackTimes(this.handler, this.timescale, this.ptsUs);

  /// `vide` / `soun`.
  final String handler;

  /// Media timescale.
  final int timescale;

  /// Sorted presentation times in µs (edit-list media start subtracted).
  final List<double> ptsUs;
}

/// Reads the presentation timestamps of every track of an MP4/MOV file.
List<TrackTimes> readTrackTimes(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  final out = <TrackTimes>[];
  String type(int at) => String.fromCharCodes(bytes.sublist(at + 4, at + 8));
  (int, int) box(int at) {
    var size = bd.getUint32(at);
    var header = 8;
    if (size == 1) {
      size = bd.getUint64(at + 8);
      header = 16;
    } else if (size == 0) {
      size = bytes.length - at;
    }
    return (size, header);
  }

  Iterable<(String, int, int)> children(int from, int to) sync* {
    var at = from;
    while (at + 8 <= to) {
      final (size, header) = box(at);
      if (size < header) return;
      yield (type(at), at + header, at + size);
      at += size;
    }
  }

  void trak(int from, int to) {
    var handler = '', timescale = 0, mediaStart = 0;
    final stts = <(int, int)>[];
    final ctts = <(int, int)>[];
    void walk(int f, int t) {
      for (final (ty, b, e) in children(f, t)) {
        switch (ty) {
          case 'mdia' || 'minf' || 'stbl' || 'edts':
            walk(b, e);
          case 'mdhd':
            timescale = bd.getUint8(b) == 1 ? bd.getUint32(b + 20) : bd.getUint32(b + 12);
          case 'hdlr':
            handler = String.fromCharCodes(bytes.sublist(b + 8, b + 12));
          case 'stts':
            final n = bd.getUint32(b + 4);
            for (var i = 0; i < n; i++) {
              stts.add((bd.getUint32(b + 8 + i * 8), bd.getUint32(b + 12 + i * 8)));
            }
          case 'ctts':
            final n = bd.getUint32(b + 4);
            for (var i = 0; i < n; i++) {
              ctts.add((bd.getUint32(b + 8 + i * 8), bd.getInt32(b + 12 + i * 8)));
            }
          case 'elst':
            final v = bd.getUint8(b);
            final n = bd.getUint32(b + 4);
            var at = b + 8;
            for (var i = 0; i < n; i++) {
              final mt = v == 1 ? bd.getInt64(at + 8) : bd.getInt32(at + 4);
              at += v == 1 ? 20 : 12;
              if (mt >= 0) {
                mediaStart = mt;
                break;
              }
            }
        }
      }
    }

    walk(from, to);
    final dts = <int>[];
    var t = 0;
    for (final (count, delta) in stts) {
      for (var i = 0; i < count; i++) {
        dts.add(t);
        t += delta;
      }
    }
    final offs = <int>[];
    for (final (count, off) in ctts) {
      for (var i = 0; i < count; i++) {
        offs.add(off);
      }
    }
    final pts = <double>[
      for (var i = 0; i < dts.length; i++) (dts[i] + (i < offs.length ? offs[i] : 0) - mediaStart) * 1e6 / timescale,
    ]..sort();
    out.add(TrackTimes(handler, timescale, pts));
  }

  for (final (ty, b, e) in children(0, bytes.length)) {
    if (ty != 'moov') continue;
    for (final (ct, cb, ce) in children(b, e)) {
      if (ct == 'trak') trak(cb, ce);
    }
  }
  return out;
}

// =================================================================================================
// QA-03 support: plans
// =================================================================================================

/// Canvas of the accuracy plans (the marker slots are laid out on it).
const int qaW = 640;
const int qaH = 360;

/// Marker geometry (canvas px): slot p is centred at (40 + 80·p, 300), 24 px square.
const int markerY = 300;
double markerX(int slot) => 40.0 + 80 * slot;

/// One map segment `[t0, t1, s0, s1]` in µs.
typedef Seg = List<int>;

/// Builds RenderPlan v1 JSON (ARCH §11.2).
abstract final class Qa03Plan {
  /// A video asset.
  static Map<String, Object?> video(String path, {required int w, required int h, required int durUs, bool hasAudio = false, String? proxy}) => {
        'kind': 'video',
        'uri': Uri.file(path).toString(),
        'fp': 'qa03_${path.hashCode.toUnsigned(32)}',
        'w': w,
        'h': h,
        'durUs': durUs,
        'hasAudio': hasAudio,
        if (proxy != null) 'proxyUri': Uri.file(proxy).toString(),
      };

  /// A full-canvas media layer.
  static Map<String, Object?> media(String id, String asset, List<Seg> map,
          {int z = 10, int seq = 0, int w = qaW, int h = qaH, Map<String, Object?>? xf}) =>
      {
        'id': id,
        'z': z,
        'seq': seq,
        't': [map.first[0], map.last[1]],
        'kind': 'media',
        'asset': asset,
        'map': map,
        'base': [w, h],
        'xf': xf ?? {'cx': w / 2, 'cy': h / 2},
      };

  /// A solid layer.
  static Map<String, Object?> solid(String id, int z, String color, int t0, int t1, num w, num h, num cx, num cy,
          {Map<String, Object?>? anim}) =>
      {
        'id': id,
        'z': z,
        't': [t0, t1],
        'kind': 'solid',
        'color': color,
        'base': [w, h],
        'xf': {'cx': cx, 'cy': cy},
        if (anim != null) 'anim': anim,
      };

  /// The timeline marker over frames `[0, frames)` at [fps]: slot `k mod 8`, held per frame.
  static Map<String, Object?> marker(int frames, int fps) {
    final keys = <List<num>>[];
    for (var k = 0; k < frames; k++) {
      final x = markerX(k % 8);
      keys.add([tof(k, fps), x]);
      keys.add([tof(k + 1, fps) - 1, x]);
    }
    return solid('it_marker#v', 10010, '#FFFF00FF', 0, tof(frames, fps), 24, 24, markerX(0), markerY, anim: {'xf.cx': keys});
  }

  /// A plan.
  static RenderPlan plan({
    String target = 'preview',
    int w = qaW,
    int h = qaH,
    required int fps,
    int? gridFps,
    required int durUs,
    int rev = 1,
    Map<String, Object?> assets = const {},
    List<Map<String, Object?>> layers = const [],
    List<Map<String, Object?>> audio = const [],
  }) =>
      decodePlanJson({
        'v': 1,
        'rev': rev,
        'target': target,
        'canvas': {'w': w, 'h': h, 'fps': fps, if (gridFps != null) 'gridFps': gridFps, 'bg': '#000000FF'},
        'durUs': durUs,
        'assets': assets,
        'layers': layers,
        'audio': audio,
      });

  /// Decodes plan JSON through the transport (the same bytes the engine receives).
  static RenderPlan decodePlanJson(Map<String, Object?> json) => PlanTransport.decodePlan(Uint8List.fromList(utf8.encode(jsonEncode(json))));

  /// Decodes a patch.
  static RenderPlanPatch patch(Map<String, Object?> json) => PlanTransport.decodePatch(Uint8List.fromList(utf8.encode(jsonEncode(json))));
}

/// The source frame a timeline frame shows, from piecewise-linear maps (ARCH §11.5).
final class SourceMap {
  /// Creates the map: one entry per layer `(segments, sourceFps)`; layers must not overlap. With
  /// [ptsUs] (the source's real presentation timestamps, [videoPts]) the displayed frame follows
  /// the file exactly; otherwise frame i is assumed at `i·10⁶/fps`.
  SourceMap(this.layers, {this.ptsUs});

  /// Layers as (segments, source fps).
  final List<(List<Seg>, int)> layers;

  /// Real source PTS (all layers show the same file), or null for nominal timing.
  final List<double>? ptsUs;

  /// Timeline frames whose expectation from the real PTS differs from nominal `i·10⁶/fps`
  /// timing (a fixture whose timescale cannot hold its rate), over frames `[0, frames)` at [fps].
  List<int> nominalDeviations(int frames, int fps) {
    final p = ptsUs;
    if (p == null) return const [];
    final nominal = SourceMap(layers);
    return [
      for (var k = 0; k < frames; k++)
        if (barcodeAt(tof(k, fps)) != nominal.barcodeAt(tof(k, fps))) k,
    ];
  }

  /// Expected barcode at timeline time [t] (null in a gap).
  int? barcodeAt(int t) {
    for (final (segs, fps) in layers) {
      for (final s in segs) {
        if (t >= s[0] && t < s[1]) {
          final src = s[2] + (t - s[0]) * (s[3] - s[2]) / (s[1] - s[0]);
          final p = ptsUs;
          return p == null ? displayedSourceFrame(src, fps) : frameAtOrBefore(p, src + 500);
        }
      }
    }
    return null;
  }
}

// =================================================================================================
// QA-03 support: frame reading
// =================================================================================================

/// What one captured frame shows.
final class FrameRead {
  /// Creates a reading.
  const FrameRead(this.barcode, this.slot);

  /// The source barcode.
  final FrameBarcodeReading barcode;

  /// The timeline marker slot (0..7), -1 when none is visible, -2 when several are.
  final int slot;

  @override
  String toString() => 'barcode ${barcode.index ?? barcode.status.name}, slot $slot';
}

bool _isYellow(List<int> p) => p[0] > 170 && p[1] > 170 && p[2] < 110;

/// Reads the barcode (over the whole picture) and the marker slot (canvas 640×360 scaled to the
/// picture).
FrameRead readFrame(Rgba f, {bool marker = true}) {
  final b = FrameBarcode.read(f.px, width: f.w, height: f.h);
  if (!marker) return FrameRead(b, -1);
  var slot = -1;
  final y = (markerY * f.h / qaH).round();
  for (var p = 0; p < 8; p++) {
    final x = (markerX(p) * f.w / qaW).round();
    if (_isYellow(f.at(x, y))) {
      slot = slot == -1 ? p : -2;
    }
  }
  return FrameRead(b, slot);
}

/// Captures the displayed preview frame.
Future<Rgba> capture(PreviewSession s) async {
  final px = await s.debugCaptureFrame().timeout(const Duration(seconds: 10));
  final size = s.frameSize.value!;
  final w = size.width.round(), h = size.height.round();
  expect(px.length, w * h * 4, reason: 'debugCaptureFrame is RGBA at frameSize');
  return Rgba(px, w, h);
}

/// Exact seek to frame [k] (at [offsetUs] past its start) and capture.
Future<(SeekAck, Rgba)> seekAndCapture(PreviewSession s, int k, int fps, {int offsetUs = 0}) async {
  final ack = await s.seek(tof(k, fps) + offsetUs).timeout(const Duration(seconds: 10));
  return (ack, await capture(s));
}

/// Mismatch log (first few kept).
final class Misses {
  /// Count.
  int n = 0;

  /// Samples.
  final List<String> samples = [];

  /// Records one miss.
  void add(String s) {
    n++;
    if (samples.length < 12) samples.add(s);
  }

  @override
  String toString() => '$n${samples.isEmpty ? '' : ' (${samples.join('; ')})'}';
}

/// Reads a whole exported file back frame by frame through a preview session on it (exact seeks
/// are verified 200/200 above), [frames] frames at [fps]. Returns the reading per frame.
Future<List<FrameRead>> readBackExport(Qa03Env env, String path, int durUs, int fps, int frames, {int w = qaW, int h = qaH}) async {
  final plan = Qa03Plan.plan(fps: fps, durUs: durUs, w: w, h: h, assets: {
    'x': Qa03Plan.video(path, w: w, h: h, durUs: durUs),
  }, layers: [
    Qa03Plan.media('it_x#v', 'x', [
      [0, durUs, 0, durUs],
    ], w: w, h: h),
  ]);
  final s = await env.preview(plan);
  try {
    return [
      for (var k = 0; k < frames; k++) readFrame((await seekAndCapture(s, k, fps)).$2),
    ];
  } finally {
    await s.dispose();
  }
}

// =================================================================================================
// Grid-cut case (D-35)
// =================================================================================================

/// The grid-cut timeline at [fps]: A, B, C on `frame_counter_720p<fps>` (1080p30 at 30 fps) with
/// cuts at k1 ≡ 1 and k2 ≡ 2 (mod 3), each with ≥ 1.5 s on both sides (3 s window), sources
/// disjoint, the timeline a whole number of seconds.
final class GridCut {
  GridCut(this.fps, {this.ptsUs})
      : k1 = _firstAtLeast((1.5 * fps).round(), 1),
        k2 = _firstAtLeast((1.5 * fps).round(), 1) + 3 * fps + 1 {
    // At least 1.5 s after k2, rounded up to a whole second so durUs is an exact µs value (an
    // export whose durUs is not exact fails on iOS, see the 'export duration off the whole-µs grid'
    // test; the grid-cut case must not depend on that defect).
    end = ((k2 + (1.5 * fps).ceil() + fps - 1) ~/ fps) * fps;
  }

  static int _firstAtLeast(int k, int residue) {
    while (k % 3 != residue) {
      k++;
    }
    return k;
  }

  /// Rate (project and source).
  final int fps;

  /// Real PTS of the source file (null: nominal timing).
  final List<double>? ptsUs;

  /// The ENG-05 fixture of this rate and its display size.
  static (String, int, int) fixtureFor(int fps) =>
      fps == 30 ? ('frame_counter_1080p30.mp4', 1920, 1080) : ('frame_counter_720p$fps.mp4', 1280, 720);

  /// Cut frames.
  final int k1, k2;

  /// Frames on the timeline.
  late final int end;

  /// Source start frames of A, B, C.
  int get a0 => 0;
  int get b0 => (4.5 * fps).round();
  int get c0 => 2 * fps;

  Seg _seg(int from, int to, int src) => [tof(from, fps), tof(to, fps), tof(src, fps), tof(src, fps) + tof(to, fps) - tof(from, fps)];

  /// Map segments of A, B, C.
  List<Seg> get a => [_seg(0, k1, a0)];
  List<Seg> get b => [_seg(k1, k2, b0)];
  List<Seg> get c => [_seg(k2, end, c0)];

  /// Expected barcodes.
  SourceMap get expected => SourceMap([(a, fps), (b, fps), (c, fps)], ptsUs: ptsUs);

  /// The plan ([target] preview or export).
  RenderPlan plan(String mediaPath, {String target = 'preview', int w = 1280, int h = 720}) => Qa03Plan.plan(
        target: target,
        fps: fps,
        durUs: tof(end, fps),
        assets: {'fc': Qa03Plan.video(mediaPath, w: w, h: h, durUs: 8000000)},
        layers: [
          Qa03Plan.media('it_a#v', 'fc', a),
          Qa03Plan.media('it_b#v', 'fc', b),
          Qa03Plan.media('it_c#v', 'fc', c),
          Qa03Plan.marker(end, fps),
        ],
      );
}

/// Checks one reading against timeline frame [k].
String? checkFrame(FrameRead r, int k, SourceMap expected) {
  final want = expected.barcodeAt(tof(k, _fpsOf(expected)));
  if (!r.barcode.isReadable) return 'k=$k unreadable ${r.barcode.status.name}';
  if (r.barcode.index != want) return 'k=$k barcode ${r.barcode.index} != $want';
  if (r.slot != k % 8) return 'k=$k marker slot ${r.slot} != ${k % 8}';
  return null;
}

int _fpsOf(SourceMap m) => m.layers.first.$2;

// =================================================================================================
// Tests
// =================================================================================================

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('danaview_qa03_acc'));
  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  group('support self-checks', () {
    test('time grid, grid-cut layout and the expected-frame rule', () {
      expect(tof(1, 30), 33334);
      expect(frameIndexOf(33333, 30), 0);
      expect(frameIndexOf(33334, 30), 1);
      for (final fps in [24, 30, 48, 60]) {
        final g = GridCut(fps);
        expect(g.k1 % 3, 1);
        expect(g.k2 % 3, 2);
        expect(g.k1, greaterThanOrEqualTo(1.5 * fps));
        expect(g.k2 - g.k1, greaterThanOrEqualTo(3 * fps));
        expect(g.end - g.k2, greaterThanOrEqualTo(1.5 * fps));
        expect(g.b0 + (g.k2 - g.k1), lessThanOrEqualTo(8 * fps), reason: 'B inside the 8 s fixture');
        final e = g.expected;
        // A shows 0.., B shows b0.., C shows c0.. and every timeline frame maps to one source frame.
        expect(e.barcodeAt(tof(g.k1 - 1, fps)), g.k1 - 1);
        expect(e.barcodeAt(tof(g.k1, fps)), g.b0);
        expect(e.barcodeAt(tof(g.k2 - 1, fps)), g.b0 + g.k2 - g.k1 - 1);
        expect(e.barcodeAt(tof(g.k2, fps)), g.c0);
        final seen = <int>{};
        for (var k = 0; k < g.end; k++) {
          expect(seen.add(e.barcodeAt(tof(k, fps))!), isTrue, reason: 'barcodes unique at $fps fps');
        }
      }
    });

    test('frame reader: barcode and marker slot on a synthetic frame; PNG round trip', () async {
      const w = 320, h = 180;
      final px = Uint8List(w * h * 4);
      for (var i = 3; i < px.length; i += 4) {
        px[i] = 255;
      }
      FrameBarcode.paint(px, width: w, height: h, index: 1234);
      final x = (markerX(5) * w / qaW).round(), y = (markerY * h / qaH).round();
      for (var dy = -4; dy <= 4; dy++) {
        for (var dx = -4; dx <= 4; dx++) {
          final i = ((y + dy) * w + x + dx) * 4;
          px[i] = 255;
          px[i + 1] = 255;
          px[i + 2] = 0;
        }
      }
      final r = readFrame(Rgba(px, w, h));
      expect(r.barcode.index, 1234);
      expect(r.slot, 5);
      final back = await decodePng(encodePng(px, w, h));
      expect(back.w, w);
      expect(back.px, px);
      final small = Rgba(px, w, h).downscale(160, 90);
      expect(FrameBarcode.read(small.px, width: 160, height: 90).index, 1234);
    });

    test('MP4 timestamp reader on a synthetic moov (stts + ctts + elst)', () {
      Uint8List b(String type, List<int> body) {
        final out = BytesBuilder()
          ..add((ByteData(4)..setUint32(0, body.length + 8)).buffer.asUint8List())
          ..add(type.codeUnits)
          ..add(body);
        return out.toBytes();
      }

      List<int> u32(List<int> v) => [for (final x in v) ...(ByteData(4)..setUint32(0, x)).buffer.asUint8List()];
      final mdhd = b('mdhd', [...u32([0, 0, 0, 600, 60])]);
      final hdlr = b('hdlr', [...u32([0, 0]), ...'vide'.codeUnits, ...u32([0, 0, 0])]);
      final stts = b('stts', u32([0, 1, 3, 20]));
      final ctts = b('ctts', u32([0, 3, 1, 40, 1, 0, 1, 20]));
      final elst = b('elst', u32([0, 1, 60, 40, 0x10000]));
      final moov = b('moov', b('trak', [...b('edts', elst), ...b('mdia', [...mdhd, ...hdlr, ...b('minf', b('stbl', [...stts, ...ctts]))])]));
      final t = readTrackTimes(Uint8List.fromList([...b('ftyp', 'isom'.codeUnits), ...moov]));
      expect(t.single.handler, 'vide');
      // DTS 0, 20, 40 + ctts 40, 0, 20 − 40 = 0, −20, 20 → sorted −20, 0, 20 ticks of 1/600 s.
      expect(t.single.ptsUs.map((e) => e.round()), [-33333, 0, 33333]);
    });
  });

  final skip = Qa03Media.skipReason;

  testWidgets('exact seeks 200/200 through speed segments, then 200/200 after a structural patch', (tester) async {
    final env = await Qa03Env.open(base);
    if (env == null) return;
    const fps = 30;
    final path = Qa03Media.path('frame_counter_1080p30.mp4');
    final assets = {'fc': Qa03Plan.video(path, w: 1920, h: 1080, durUs: 8000000)};
    // 1× | 2× | 0.5× | 1×, every breakpoint a frame start (ARCH §11.3).
    final speed = <Seg>[
      [0, 1000000, 0, 1000000],
      [1000000, 2000000, 1000000, 3000000],
      [2000000, 4000000, 3000000, 4000000],
      [4000000, 5000000, 4000000, 5000000],
    ];
    const frames = 150;
    final plan = Qa03Plan.plan(fps: fps, durUs: 5000000, assets: assets, layers: [
      Qa03Plan.media('it_v#v', 'fc', speed),
      Qa03Plan.marker(frames, fps),
    ]);
    final s = await env.preview(plan);
    try {
      Future<(int, Misses, List<int>)> run(SourceMap want, List<(int, int)> seeks) async {
        final miss = Misses();
        final ms = <int>[];
        var lastSeq = -1;
        for (final (k, off) in seeks) {
          final sw = Stopwatch()..start();
          final (ack, f) = await seekAndCapture(s, k, fps, offsetUs: off);
          ms.add(sw.elapsedMilliseconds);
          if (ack.seq <= lastSeq) miss.add('k=$k seq ${ack.seq} not increasing');
          lastSeq = ack.seq;
          if (ack.displayedFrame != k) miss.add('k=$k ack displayed ${ack.displayedFrame}');
          final bad = checkFrame(readFrame(f), k, want);
          if (bad != null) miss.add(bad);
        }
        ms.sort();
        return (seeks.length - miss.n, miss, ms);
      }

      List<(int, int)> seeks(int seed, {bool every = false}) {
        final out = <(int, int)>[if (every) for (var k = 0; k < frames; k++) (k, 0)];
        var x = seed;
        while (out.length < 200) {
          x = (x * 1103515245 + 12345) & 0x7fffffff;
          final k = x % frames;
          // Odd draws seek inside the frame (frameIndexOf(t) = k).
          out.add((k, (x >> 8).isOdd ? (tof(k + 1, fps) - tof(k, fps)) ~/ 2 : 0));
        }
        return out;
      }

      final want1 = SourceMap([(speed, 30)]);
      final (ok1, miss1, ms1) = await run(want1, seeks(0x0303, every: true));
      qa03('seek', {'phase': 'speed 1x/2x/0.5x', 'ok': '$ok1/200', 'p50ms': ms1[100], 'p95ms': ms1[190], 'misses': miss1});
      expect(miss1.n, 0, reason: '$miss1');

      // Structural patch: re-cut at frame 77 (k ≡ 2 mod 3) into a 1× clip from 3 s and a 2× clip
      // from 0.5 s, plus an overlay solid in the lower left.
      final t77 = tof(77, fps);
      final p1 = <Seg>[
        [0, t77, 3000000, 3000000 + t77],
      ];
      final p2 = <Seg>[
        [t77, 5000000, 500000, 500000 + 2 * (5000000 - t77)],
      ];
      final ack = await s
          .applyPatch(Qa03Plan.patch({
            'v': 1,
            'from': 1,
            'to': 2,
            'layers': {
              'upsert': [
                Qa03Plan.media('it_p1#v', 'fc', p1),
                Qa03Plan.media('it_p2#v', 'fc', p2),
                Qa03Plan.solid('it_ov#v', 10020, '#00FFFFFF', 0, 5000000, 60, 40, 100, 240),
              ],
              'remove': ['it_v#v'],
            },
          }))
          .timeout(const Duration(seconds: 30));
      expect(ack.rev, 2);
      expect(ack.structural, isTrue);
      final want2 = SourceMap([(p1, 30), (p2, 30)]);
      final (ok2, miss2, ms2) = await run(want2, seeks(0x7a11));
      qa03('seek', {'phase': 'after structural patch', 'ok': '$ok2/200', 'p50ms': ms2[100], 'p95ms': ms2[190], 'applyMs': ack.applyMs, 'misses': miss2});
      expect(miss2.n, 0, reason: '$miss2');
      final (_, f) = await seekAndCapture(s, 10, fps);
      final ov = f.at((100 * f.w / qaW).round(), (240 * f.h / qaH).round());
      expect(ov[0] < 80 && ov[1] > 180 && ov[2] > 180, isTrue, reason: 'overlay drawn after the patch');
    } finally {
      await s.dispose();
    }
  }, skip: skip != null);

  for (final fps in [24, 30, 48, 60]) {
    testWidgets('grid-cut case at $fps fps: exact-seek preview, playback capture and export', (tester) async {
      final env = await Qa03Env.open(base);
      if (env == null) return;
      final (name, sw, sh) = GridCut.fixtureFor(fps);
      final path = Qa03Media.path(name);
      final g = GridCut(fps, ptsUs: videoPts(path));
      final want = g.expected;
      final deviations = want.nominalDeviations(g.end, fps);
      qa03('gridcut', {'fps': fps, 'source': name, 'nominalPtsDeviations': '${deviations.length}/${g.end}'});

      // ---- exact-seek preview, every frame ----
      final s = await env.preview(g.plan(path, w: sw, h: sh));
      final seekMiss = Misses();
      try {
        for (var k = 0; k < g.end; k++) {
          final (ack, f) = await seekAndCapture(s, k, fps);
          if (ack.displayedFrame != k) seekMiss.add('k=$k ack ${ack.displayedFrame}');
          final bad = checkFrame(readFrame(f), k, want);
          if (bad != null) seekMiss.add(bad);
        }
        qa03('gridcut', {'fps': fps, 'mode': 'exact seek', 'k1': g.k1, 'k2': g.k2, 'frames': g.end, 'misses': seekMiss});

        // ---- playback capture: frames captured while playing, identified by barcode + marker ----
        final inverse = <int, int>{for (var k = 0; k < g.end; k++) want.barcodeAt(tof(k, fps))!: k};
        final covered = <int>{};
        final playMiss = Misses();
        var captures = 0;
        var blackAtEnd = 0;
        for (var pass = 0; pass < 4 && covered.length < g.end * 0.9; pass++) {
          await s.seek(0).timeout(const Duration(seconds: 10));
          await s.play().timeout(const Duration(seconds: 10));
          final sw = Stopwatch()..start();
          final durMs = tof(g.end, fps) ~/ 1000;
          while (sw.elapsedMilliseconds < durMs + 1500) {
            final f = await capture(s);
            captures++;
            final r = readFrame(f);
            if (!r.barcode.isReadable && r.barcode.status == FrameBarcodeStatus.noSignal && sw.elapsedMilliseconds >= durMs - 50) {
              // Playback reached the end of the timeline (the player shows black past durUs).
              blackAtEnd++;
              break;
            }
            if (!r.barcode.isReadable) {
              playMiss.add('unreadable ${r.barcode.status.name} at ${sw.elapsedMilliseconds} ms');
              if (playMiss.n <= 3) {
                File('${Qa03Dirs.out(env.work)}/playback_unreadable_${fps}_${playMiss.n}.png').writeAsBytesSync(encodePng(f.px, f.w, f.h));
              }
              continue;
            }
            final near = inverse[r.barcode.index];
            if (near == null) {
              playMiss.add('unexpected barcode ${r.barcode.index}');
              continue;
            }
            if (r.slot < 0) {
              playMiss.add('barcode ${r.barcode.index}: marker slot ${r.slot}');
              continue;
            }
            // The timeline frame whose slot matches, within ±4 of the barcode's own frame.
            var k = near - 4;
            while (k % 8 != r.slot) {
              k++;
            }
            if (k < 0 || k >= g.end || want.barcodeAt(tof(k, fps)) != r.barcode.index) {
              playMiss.add('k=$k (slot ${r.slot}) shows ${r.barcode.index}, expected ${k >= 0 && k < g.end ? want.barcodeAt(tof(k, fps)) : '-'}');
              continue;
            }
            covered.add(k);
          }
          await s.pause().timeout(const Duration(seconds: 10));
        }
        final cutsSeen = [g.k1 - 1, g.k1, g.k2 - 1, g.k2].where(covered.contains).length;
        qa03('gridcut', {
          'fps': fps,
          'mode': 'playback capture',
          'captures': captures,
          'covered': '${covered.length}/${g.end}',
          'cutFramesSeen': '$cutsSeen/4',
          'passesEndingBlack': blackAtEnd,
          'misses': playMiss,
        });
        expect(seekMiss.n, 0, reason: 'exact seek: $seekMiss');
        expect(playMiss.n, 0, reason: 'playback: $playMiss');
        expect(covered.length, greaterThanOrEqualTo(g.end ~/ 2), reason: 'playback capture coverage');
      } finally {
        await s.dispose();
      }

      // ---- export: every frame read back, and native freeze stills at the cuts ----
      final r = await env.export('gridcut_$fps', g.plan(path, target: 'export', w: sw, h: sh), videoBitrate: 6000000);
      expect(r.duration, tof(g.end, fps));
      final reads = await readBackExport(env, r.path, r.duration, fps, g.end);
      final expMiss = Misses();
      for (var k = 0; k < g.end; k++) {
        final bad = checkFrame(reads[k], k, want);
        if (bad != null) expMiss.add(bad);
      }
      final stillMiss = Misses();
      for (final k in [g.k1 - 2, g.k1 - 1, g.k1, g.k1 + 1, g.k2 - 2, g.k2 - 1, g.k2, g.k2 + 1]) {
        final f = await env.freeze(r.path, tof(k, fps), tag: 'gc$fps');
        final bad = checkFrame(readFrame(f), k, want);
        if (bad != null) stillMiss.add('still $bad');
      }
      qa03('gridcut', {'fps': fps, 'mode': 'export', 'frames': g.end, 'misses': expMiss, 'stillsAtCuts': '${8 - stillMiss.n}/8 $stillMiss'});
      Qa03Env.discard(r.path);
      expect(expMiss.n, 0, reason: 'export: $expMiss');
      expect(stillMiss.n, 0, reason: 'export stills: $stillMiss');
    }, skip: skip != null);
  }

  testWidgets('export duration off the whole-µs grid (D-35): 24/30/48/60 fps, durUs = timeOfFrame(K)', (tester) async {
    // Every project whose frame count K is not a multiple of fps/gcd has a durUs = ceil(K·10⁶/fps)
    // that is not an exact µs time (two thirds of all lengths at 30 fps). Such exports must work.
    final env = await Qa03Env.open(base);
    if (env == null) return;
    final failures = <String>[];
    for (final (fps, k) in [(24, 73), (30, 91), (48, 49), (60, 179), (25, 51)]) {
      final d = tof(k, fps);
      try {
        final r = await env.export('offgrid_${fps}_$k', Qa03Plan.plan(target: 'export', fps: fps, durUs: d, layers: [
          Qa03Plan.solid('it_s#v', 10, '#FF0000FF', 0, d, 100, 100, 320, 180),
        ]));
        qa03('offgrid', {'fps': fps, 'frames': k, 'durUs': d, 'result': 'ok ${r.duration}'});
        Qa03Env.discard(r.path);
      } on EngineFailure catch (f) {
        qa03('offgrid', {'fps': fps, 'frames': k, 'durUs': d, 'result': '${f.code.name}: ${f.message}'});
        failures.add('$fps fps × $k: ${f.code.name} ${f.message}');
      }
    }
    expect(failures, isEmpty, reason: 'exports of off-grid durations fail: $failures');
  });

  testWidgets('reverse rendition: barcode strictly decreasing, frame by frame', (tester) async {
    final env = await Qa03Env.open(base);
    if (env == null) return;
    const fps = 30;
    final path = Qa03Media.path('frame_counter_1080p30.mp4');
    final out = '${env.work}/reverse_60_120.mp4';
    final sw = Stopwatch()..start();
    final job = env.engine.jobs.reverse(Qa03Env.media(path), TimeRange(tof(60, fps), tof(120, fps)), outputPath: out);
    final r = await job.result.timeout(const Duration(minutes: 3));
    final dur = r.duration ?? tof(60, fps);
    final frames = frameIndexOf(dur - 1, fps) + 1;
    final plan = Qa03Plan.plan(fps: fps, durUs: tof(frames, fps), assets: {
      'rv': Qa03Plan.video(r.path, w: 1920, h: 1080, durUs: dur),
    }, layers: [
      Qa03Plan.media('it_rv#v', 'rv', [
        [0, tof(frames, fps), 0, tof(frames, fps)],
      ]),
    ]);
    final s = await env.preview(plan);
    final seen = <int>[];
    final miss = Misses();
    try {
      for (var k = 0; k < frames; k++) {
        final (_, f) = await seekAndCapture(s, k, fps);
        final b = readFrame(f, marker: false).barcode;
        if (!b.isReadable) {
          miss.add('k=$k ${b.status.name}');
          continue;
        }
        if (seen.isNotEmpty && b.index! >= seen.last) miss.add('k=$k ${b.index} after ${seen.last}');
        if (b.index != 119 - k) miss.add('k=$k ${b.index} != ${119 - k}');
        seen.add(b.index!);
      }
    } finally {
      await s.dispose();
    }
    qa03('reverse', {'range': '60..119', 'jobMs': sw.elapsedMilliseconds, 'frames': frames, 'first': seen.firstOrNull, 'last': seen.lastOrNull, 'misses': miss});
    expect(frames, 60);
    expect(miss.n, 0, reason: '$miss');
  }, skip: skip != null);

  testWidgets('freeze stills: barcode exact at frame starts and mid-frame, four rates', (tester) async {
    final env = await Qa03Env.open(base);
    if (env == null) return;
    final cases = <(String, int, List<int>)>[
      ('frame_counter_1080p30.mp4', 30, [0, 1, 29, 30, 31, 89, 160, 239]),
      ('frame_counter_720p24.mp4', 24, [0, 37, 110, 191]),
      ('frame_counter_720p48.mp4', 48, [0, 73, 218, 383]),
      ('frame_counter_720p60.mp4', 60, [0, 91, 272, 479]),
    ];
    final miss = Misses();
    var n = 0;
    for (final (name, fps, frames) in cases) {
      final path = Qa03Media.path(name);
      final pts = videoPts(path);
      for (final k in frames) {
        for (final off in [0, (tof(k + 1, fps) - tof(k, fps)) ~/ 2]) {
          final f = await env.freeze(path, tof(k, fps) + off, tag: name.hashCode.toUnsigned(16).toString());
          n++;
          final b = FrameBarcode.read(f.px, width: f.w, height: f.h);
          // Zero tolerance: the frame with the greatest real PTS ≤ the requested time.
          final want = frameAtOrBefore(pts, (tof(k, fps) + off).toDouble());
          if (want != k) qa03('freeze', {'source': name, 'k': k, 'offUs': off, 'note': 'fixture PTS of frame $k is ${pts[k].toStringAsFixed(0)} µs, after ${tof(k, fps)}'});
          if (b.index != want) miss.add('$name k=$k +$off µs: ${b.index ?? b.status.name} (want $want)');
        }
      }
    }
    qa03('freeze', {'stills': n, 'exact': '${n - miss.n}/$n', 'misses': miss});
    expect(miss.n, 0, reason: '$miss');
  }, skip: skip != null);

  testWidgets('proxies: PTS equal to the original (CFR and VFR), same barcode at exact seeks', (tester) async {
    final env = await Qa03Env.open(base);
    if (env == null) return;
    for (final (name, w, h, dur) in [('frame_counter_1080p30.mp4', 1920, 1080, 8000000), ('vfr_720p.mp4', 1280, 720, 6000000)]) {
      final path = Qa03Media.path(name);
      final m = Qa03Env.media(path, 'qa03_proxy_$name');
      final sw = Stopwatch()..start();
      final r = await env.engine.jobs.proxy(m).result.timeout(const Duration(minutes: 3));
      final src = readTrackTimes(File(path).readAsBytesSync()).firstWhere((t) => t.handler == 'vide');
      final px = readTrackTimes(File(r.path).readAsBytesSync()).firstWhere((t) => t.handler == 'vide');
      var maxDelta = 0.0;
      for (var i = 0; i < math.min(src.ptsUs.length, px.ptsUs.length); i++) {
        maxDelta = math.max(maxDelta, (src.ptsUs[i] - px.ptsUs[i]).abs());
      }
      qa03('proxy', {
        'source': name,
        'jobMs': sw.elapsedMilliseconds,
        'frames': '${px.ptsUs.length}/${src.ptsUs.length}',
        'timescale': '${px.timescale}/${src.timescale}',
        'maxPtsDeltaUs': maxDelta.toStringAsFixed(2),
      });
      expect(px.ptsUs.length, src.ptsUs.length, reason: '$name: proxy frame count');
      expect(maxDelta, lessThanOrEqualTo(1.0), reason: '$name: proxy PTS equal to the source');

      if (name.startsWith('frame_counter')) {
        // The proxy shows the same frame as the original at exact seeks (preview with proxies on).
        const fps = 30;
        final plan = Qa03Plan.plan(fps: fps, durUs: dur, assets: {
          'fc': Qa03Plan.video(path, w: w, h: h, durUs: dur, proxy: r.path),
        }, layers: [
          Qa03Plan.media('it_fc#v', 'fc', [
            [0, dur, 0, dur],
          ]),
        ]);
        final s = await env.preview(plan, useProxies: true);
        final miss = Misses();
        try {
          for (var k = 0; k < 240; k += 7) {
            final (_, f) = await seekAndCapture(s, k, fps);
            final b = readFrame(f, marker: false).barcode;
            if (b.index != k) miss.add('k=$k ${b.index ?? b.status.name}');
          }
        } finally {
          await s.dispose();
        }
        qa03('proxy', {'source': name, 'mode': 'exact seek on proxy', 'misses': miss});
        expect(miss.n, 0, reason: '$miss');
      }
      Qa03Env.discard(r.path);
    }
  }, skip: skip != null);
}
