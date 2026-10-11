// OWNER: API-03
//
// Regenerates the render-math vectors and the reference-renderer goldens (ARCH §11.6, §21.1;
// BUILD_PLAN API-03). Output (format: test_fixtures/vectors/README.md, test_fixtures/images/README.md):
//
//   test_fixtures/vectors/*.json, luts/      shared vectors (keyframes, M, render math, gain, mixes,
//                                            typewriter, 8× text), read by Dart, Swift and Kotlin
//   test_fixtures/images/plans/              the golden plans (CORE-29 corpus copies + API-03 plans)
//   test_fixtures/images/goldens/            reference PNGs, one per plan × output frame
//   test_fixtures/images/sources/            the synthetic source content those frames used
//   test_fixtures/images/goldens.json        manifest tying plans, frames, PNGs and sources together
//
//   dart run tool/regen_goldens.dart          # rewrite what changed (review the diff!)
//   dart run tool/regen_goldens.dart --check  # exit 1 if anything would change
//
// Files are rewritten only when their content changes: JSON and binaries byte for byte, PNGs by
// decoded pixels (goldens tolerate 1/255 per channel so a different zlib or libm on another host
// produces no diff). A clean tree therefore regenerates with no diff; test/reference/ runs the
// check.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_editor_core/model.dart' show FrameRate;
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/src/reference/fixtures/golden_cases.dart';
import 'package:danaview_editor_engine_api/src/reference/fixtures/reference_vectors.dart';
import 'package:danaview_editor_engine_api/src/reference/reference_renderer.dart';
import 'package:danaview_editor_engine_api/src/reference/reference_sources.dart';
import 'package:danaview_editor_engine_api/src/reference/synthetic_sources.dart';

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  final root = packageRootFromScript();
  final result = regenerate(root, write: !check);
  for (final c in result.changes) {
    stdout.writeln('${check ? 'stale' : 'wrote'}: $c');
  }
  for (final d in result.deleted) {
    stdout.writeln('${check ? 'unexpected' : 'deleted'}: $d');
  }
  stdout.writeln('${result.files} files checked, ${result.changes.length} changed, ${result.deleted.length} stale');
  if (check && !result.isClean) {
    stderr.writeln('test_fixtures are stale: run dart run tool/regen_goldens.dart and review the diff');
    exitCode = 1;
  }
}

/// The package root when run as `dart run tool/regen_goldens.dart`.
String packageRootFromScript() {
  final script = File.fromUri(Platform.script);
  if (script.path.endsWith('tool/regen_goldens.dart')) return script.parent.parent.path;
  return Directory.current.path;
}

/// Outcome of [regenerate].
final class RegenResult {
  /// Creates a result.
  RegenResult(this.files, this.changes, this.deleted);

  /// Files produced.
  final int files;

  /// Paths (relative to the package) whose content differs from the tree.
  final List<String> changes;

  /// Stale paths that the generator no longer produces.
  final List<String> deleted;

  /// Whether the tree already matches.
  bool get isClean => changes.isEmpty && deleted.isEmpty;
}

/// How a produced file is compared with the one on disk.
enum _Compare { bytes, json, pixelsExact, pixelsTolerant }

final class _Out {
  _Out(this.bytes, this.compare);
  final Uint8List bytes;
  final _Compare compare;
}

const String _vectors = 'test_fixtures/vectors';
const String _images = 'test_fixtures/images';
const String _contractDir = '../danaview_editor_core/test/fixtures/render_plans/contract';

/// Builds every fixture in memory, compares it with the tree under [root] and (when [write])
/// writes changed files and deletes stale ones in the generated directories.
RegenResult regenerate(String root, {required bool write}) {
  final out = <String, _Out>{};

  // Vectors.
  for (final e in ReferenceVectors.all().entries) {
    out['$_vectors/${e.key}'] = _Out(_utf8('${prettyJson(e.value)}\n'), _Compare.json);
  }
  for (final e in ReferenceVectors.binaries().entries) {
    out['$_vectors/${e.key}'] = _Out(e.value, _Compare.bytes);
  }

  // Goldens.
  const synthetic = SyntheticSources();
  final manifest = <Map<String, Object?>>[];
  final sourceFiles = <String, _Out>{};
  for (final g in GoldenCases.all) {
    final Uint8List planBytes;
    final String origin;
    if (g.contractFile != null) {
      planBytes = File('$root/$_contractDir/${g.contractFile}').readAsBytesSync();
      origin = 'packages/danaview_editor_core/test/fixtures/render_plans/contract/${g.contractFile}';
    } else {
      planBytes = _utf8('${PlanJson.canonicalString(PlanJson.encodePlan(g.plan!))}\n');
      origin = 'packages/danaview_editor_engine_api/lib/src/reference/fixtures/golden_cases.dart';
    }
    final plan = PlanJson.decodePlanBytes(Uint8List.fromList(utf8.encode(utf8.decode(planBytes).trimRight())));
    final violations = PlanValidator.validate(plan);
    if (violations.isNotEmpty) throw StateError('golden plan ${g.name} is invalid: $violations');
    out['$_images/plans/${g.name}.json'] = _Out(planBytes, _Compare.bytes);

    final recording = RecordingReferenceSources(synthetic);
    final renderer = ReferenceRenderer(sources: recording, longSide: g.longSide);
    final (w, h) = renderer.outputSizeOf(plan.canvas);
    final rate = FrameRate(plan.canvas.fps, 1);
    final frames = <Map<String, Object?>>[];
    for (final k in g.frames) {
      final t = rate.timeOfFrame(k);
      final frame = renderer.render(plan, t);
      out['$_images/${g.pngPath(k)}'] = _Out(encodePng(w, h, _rgbOf(frame.toRgba8()), PngColor.rgb8), _Compare.pixelsTolerant);
      frames.add({'k': k, 'tUs': t, 'png': g.pngPath(k), 'layers': frame.drawnLayerIds});
    }

    final sources = <String, Object?>{};
    for (final id in recording.assets.keys.toList()..sort()) {
      final asset = recording.assets[id]!;
      switch (asset.kind) {
        case PlanAssetKind.video:
          final key = SyntheticSources.sourceKey(asset);
          final (vw, vh) = SyntheticSources.rasterSize(asset, synthetic.videoLongSide);
          final used = (recording.videoFrames[id] ?? <int>{}).toList()..sort();
          final files = <String, String>{};
          for (final j in used) {
            final path = 'sources/${key}_f${j.toString().padLeft(5, '0')}.png';
            files['$j'] = path;
            sourceFiles['$_images/$path'] =
                _Out(encodePng(vw, vh, _rgbOf(synthetic.videoFrameRgba8(asset, j)), PngColor.rgb8), _Compare.pixelsExact);
          }
          sources[id] = {
            'kind': 'video',
            'fps': SyntheticSources.nominalFps(asset),
            'size': [vw, vh],
            'frames': files
          };
        case PlanAssetKind.image:
          final key = SyntheticSources.sourceKey(asset);
          final (iw, ih) = SyntheticSources.rasterSize(asset, synthetic.imageLongSide);
          final path = 'sources/$key.png';
          sourceFiles['$_images/$path'] = _Out(encodePng(iw, ih, _rgbOf(synthetic.imageRgba8(asset)), PngColor.rgb8), _Compare.pixelsExact);
          sources[id] = {
            'kind': 'image',
            'size': [iw, ih],
            'png': path
          };
        case PlanAssetKind.sprite:
          final sw = asset.sw!;
          final sh = asset.sh!;
          final (rgba, glyphs) = synthetic.spriteRgba8(asset);
          final png = 'sources/sprite_${sw}x$sh.png';
          final glyphPng = 'sources/sprite_${sw}x${sh}_glyphs.png';
          sourceFiles['$_images/$png'] = _Out(encodePng(sw, sh, _unpremultiply(rgba), PngColor.rgba8), _Compare.pixelsExact);
          if (asset.reveal == true) {
            sourceFiles['$_images/$glyphPng'] = _Out(encodePng(sw, sh, _gray16Bytes(glyphs), PngColor.gray16), _Compare.pixelsExact);
          }
          sources[id] = {
            'kind': 'sprite',
            'size': [sw, sh],
            'png': png,
            'glyphs': asset.reveal == true ? glyphPng : null
          };
        case PlanAssetKind.lut:
          final n = asset.n ?? 33;
          final path = 'sources/lut_$n.vlut';
          sourceFiles['$_images/$path'] = _Out(SyntheticSources.vlutBytes(n), _Compare.bytes);
          sources[id] = {'kind': 'lut', 'n': n, 'vlut': path};
        case PlanAssetKind.audio:
          break;
      }
    }
    manifest.add({
      'name': g.name,
      'plan': 'plans/${g.name}.json',
      'origin': origin,
      'longSide': g.longSide,
      'size': [w, h],
      'renderScale': ReferenceVectors.r9(w / plan.canvas.w),
      'frames': frames,
      'sources': sources,
    });
  }
  out.addAll(sourceFiles);
  out['$_images/goldens.json'] = _Out(
    _utf8('${prettyJson({
          'schema': 1,
          'generatedBy': ReferenceVectors.generatedBy,
          'spec': 'ARCH §11.6, §21.1 (render parity), BUILD_PLAN API-03',
          'rule': 'Each frame is the Dart reference renderer (ReferenceRenderer) of `plan` at plan time tUs = timeOfFrame(k) of canvas.fps, '
              'rendered at `size` (renderScale render px per canvas px) with the synthetic sources listed per asset id; PNGs are 8-bit RGB '
              'without colour management. Engines render the same plan with the same sources and compare with the parity tolerance.',
          'tolerance': {'meanAbs': 1.5 / 255, 'p99': 6 / 255, 'ssim': 0.98, 'edgePixelsExcluded': true},
          'renderer': {'maxSupersample': 8, 'videoLongSide': synthetic.videoLongSide, 'imageLongSide': synthetic.imageLongSide},
          'goldens': manifest,
        })}\n'),
    _Compare.json,
  );

  // Compare and write.
  final changes = <String>[];
  for (final e in out.entries) {
    final f = File('$root/${e.key}');
    if (f.existsSync() && _same(f.readAsBytesSync(), e.value)) continue;
    changes.add(e.key);
    if (write) {
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(e.value.bytes);
    }
  }
  final deleted = <String>[];
  for (final dir in ['$_images/plans', '$_images/goldens', '$_images/sources', '$_vectors/luts']) {
    final d = Directory('$root/$dir');
    if (!d.existsSync()) continue;
    for (final f in d.listSync().whereType<File>()) {
      final rel = '$dir/${f.uri.pathSegments.last}';
      if (out.containsKey(rel)) continue;
      deleted.add(rel);
      if (write) f.deleteSync();
    }
  }
  changes.sort();
  deleted.sort();
  return RegenResult(out.length, changes, deleted);
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Structural JSON equality; doubles may differ by 2e-9 relative (the 1e-9 rounding of the vectors
/// can flip on a host whose libm differs in the last ulp).
bool jsonClose(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !jsonClose(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonClose(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) {
    if (a is int && b is int) return a == b;
    return (a - b).abs() <= 2e-9 * (a.abs() > 1 ? a.abs() : 1);
  }
  return a == b;
}

bool _same(Uint8List existing, _Out produced) {
  switch (produced.compare) {
    case _Compare.bytes:
      return _sameBytes(existing, produced.bytes);
    case _Compare.json:
      if (_sameBytes(existing, produced.bytes)) return true;
      try {
        return jsonClose(jsonDecode(utf8.decode(existing)), jsonDecode(utf8.decode(produced.bytes)));
      } on FormatException {
        return false;
      }
    case _Compare.pixelsExact:
    case _Compare.pixelsTolerant:
      try {
        final a = decodePng(existing);
        final b = decodePng(produced.bytes);
        if (a.width != b.width || a.height != b.height || a.color != b.color) return false;
        final tol = produced.compare == _Compare.pixelsTolerant ? 1 : 0;
        for (var i = 0; i < a.samples.length; i++) {
          if ((a.samples[i] - b.samples[i]).abs() > tol) return false;
        }
        return true;
      } on FormatException {
        return false;
      }
  }
}

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

/// JSON with two-space indented objects; arrays of scalars stay on one line and arrays of such
/// arrays put one inner array per line (keeps 8×8 image vectors readable and small).
String prettyJson(Object? value, [String indent = '']) {
  bool scalar(Object? v) => v == null || v is num || v is bool || v is String;
  final inner = '$indent  ';
  if (value is Map) {
    if (value.isEmpty) return '{}';
    final parts = [for (final e in value.entries) '$inner${jsonEncode(e.key)}: ${prettyJson(e.value, inner)}'];
    return '{\n${parts.join(',\n')}\n$indent}';
  }
  if (value is List) {
    if (value.isEmpty) return '[]';
    if (value.every(scalar)) return '[${value.map(jsonEncode).join(', ')}]';
    final parts = [for (final v in value) '$inner${prettyJson(v, inner)}'];
    return '[\n${parts.join(',\n')}\n$indent]';
  }
  return jsonEncode(value);
}

Uint8List _rgbOf(Uint8List rgba) {
  final out = Uint8List(rgba.length ~/ 4 * 3);
  for (var i = 0, o = 0; i < rgba.length; i += 4, o += 3) {
    out[o] = rgba[i];
    out[o + 1] = rgba[i + 1];
    out[o + 2] = rgba[i + 2];
  }
  return out;
}

Uint8List _unpremultiply(Uint8List rgba) {
  final out = Uint8List(rgba.length);
  for (var i = 0; i < rgba.length; i += 4) {
    final a = rgba[i + 3];
    out[i + 3] = a;
    if (a == 0) continue;
    for (var c = 0; c < 3; c++) {
      out[i + c] = (rgba[i + c] * 255 / a).round().clamp(0, 255);
    }
  }
  return out;
}

Uint8List _gray16Bytes(Uint16List v) {
  final out = Uint8List(v.length * 2);
  for (var i = 0; i < v.length; i++) {
    out[2 * i] = v[i] >> 8;
    out[2 * i + 1] = v[i] & 0xFF;
  }
  return out;
}

// -----------------------------------------------------------------------------------------------
// Minimal PNG codec (non-interlaced; RGB8, RGBA8, gray8, gray16), deterministic adaptive filters.
// -----------------------------------------------------------------------------------------------

/// Pixel formats written and read by [encodePng] / [decodePng].
enum PngColor {
  /// 8-bit RGB (colour type 2).
  rgb8(2, 8, 3),

  /// 8-bit RGBA, straight alpha (colour type 6).
  rgba8(6, 8, 4),

  /// 8-bit grey (colour type 0).
  gray8(0, 8, 1),

  /// 16-bit grey, big-endian (colour type 0).
  gray16(0, 16, 1);

  const PngColor(this.colorType, this.bitDepth, this.channels);

  /// PNG colour type.
  final int colorType;

  /// Bits per sample.
  final int bitDepth;

  /// Samples per pixel.
  final int channels;

  /// Bytes per pixel.
  int get bytesPerPixel => channels * bitDepth ~/ 8;
}

/// A decoded PNG: [samples] holds one value per channel sample (16-bit for gray16).
final class DecodedPng {
  /// Creates a decoded image.
  DecodedPng(this.width, this.height, this.color, this.samples);

  /// Width.
  final int width;

  /// Height.
  final int height;

  /// Format.
  final PngColor color;

  /// Samples, row-major.
  final List<int> samples;
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// Encodes [data] (row-major bytes in [color]'s layout, 16-bit samples big-endian) as a PNG.
Uint8List encodePng(int width, int height, Uint8List data, PngColor color) {
  final bpp = color.bytesPerPixel;
  final stride = width * bpp;
  assert(data.length == stride * height);
  final raw = BytesBuilder(copy: false);
  final prev = Uint8List(stride);
  final candidates = List.generate(5, (_) => Uint8List(stride));
  for (var y = 0; y < height; y++) {
    final row = Uint8List.sublistView(data, y * stride, (y + 1) * stride);
    var best = 0;
    var bestScore = -1;
    for (var f = 0; f < 5; f++) {
      final o = candidates[f];
      var score = 0;
      for (var i = 0; i < stride; i++) {
        final a = i >= bpp ? row[i - bpp] : 0;
        final b = prev[i];
        final c = i >= bpp ? prev[i - bpp] : 0;
        final p = switch (f) { 0 => 0, 1 => a, 2 => b, 3 => (a + b) >> 1, _ => _paeth(a, b, c) };
        final v = (row[i] - p) & 0xFF;
        o[i] = v;
        score += v < 128 ? v : 256 - v;
      }
      if (bestScore < 0 || score < bestScore) {
        best = f;
        bestScore = score;
      }
    }
    raw
      ..addByte(best)
      ..add(Uint8List.fromList(candidates[best]));
    prev.setAll(0, row);
  }
  final out = BytesBuilder(copy: false)..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> body) {
    final t = ascii.encode(type);
    final len = ByteData(4)..setUint32(0, body.length);
    final crc = ByteData(4)..setUint32(0, _crc([...t, ...body]));
    out
      ..add(len.buffer.asUint8List())
      ..add(t)
      ..add(body)
      ..add(crc.buffer.asUint8List());
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, color.bitDepth)
    ..setUint8(9, color.colorType);
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', ZLibEncoder(level: 9).convert(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

/// Decodes a PNG written by [encodePng] (or any non-interlaced PNG in the [PngColor] formats).
DecodedPng decodePng(Uint8List bytes) {
  const sig = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 8) throw const FormatException('not a PNG');
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != sig[i]) throw const FormatException('not a PNG');
  }
  final bd = ByteData.sublistView(bytes);
  var o = 8;
  int? width, height, depth, type;
  final idat = BytesBuilder(copy: false);
  while (o + 8 <= bytes.length) {
    final len = bd.getUint32(o);
    final kind = ascii.decode(bytes.sublist(o + 4, o + 8));
    final body = Uint8List.sublistView(bytes, o + 8, o + 8 + len);
    if (kind == 'IHDR') {
      final h = ByteData.sublistView(body);
      width = h.getUint32(0);
      height = h.getUint32(4);
      depth = h.getUint8(8);
      type = h.getUint8(9);
      if (h.getUint8(12) != 0) throw const FormatException('interlaced PNG');
    } else if (kind == 'IDAT') {
      idat.add(body);
    } else if (kind == 'IEND') {
      break;
    }
    o += 12 + len;
  }
  if (width == null || height == null) throw const FormatException('missing IHDR');
  final color = PngColor.values.firstWhere((c) => c.colorType == type && c.bitDepth == depth,
      orElse: () => throw FormatException('unsupported PNG format $type/$depth'));
  final raw = Uint8List.fromList(ZLibDecoder().convert(idat.takeBytes()));
  final bpp = color.bytesPerPixel;
  final stride = width * bpp;
  final data = Uint8List(stride * height);
  var prevStart = -1;
  for (var y = 0; y < height; y++) {
    final f = raw[y * (stride + 1)];
    final src = y * (stride + 1) + 1;
    final dst = y * stride;
    for (var i = 0; i < stride; i++) {
      final a = i >= bpp ? data[dst + i - bpp] : 0;
      final b = prevStart >= 0 ? data[prevStart + i] : 0;
      final c = i >= bpp && prevStart >= 0 ? data[prevStart + i - bpp] : 0;
      final p = switch (f) { 0 => 0, 1 => a, 2 => b, 3 => (a + b) >> 1, 4 => _paeth(a, b, c), _ => throw FormatException('bad filter $f') };
      data[dst + i] = (raw[src + i] + p) & 0xFF;
    }
    prevStart = dst;
  }
  final samples = color.bitDepth == 16 ? [for (var i = 0; i < data.length; i += 2) (data[i] << 8) | data[i + 1]] : data;
  return DecodedPng(width, height, color, samples);
}
