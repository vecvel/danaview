// OWNER: UX-24
//
// Generates the 12 built-in looks (ARCH §10.2, §6.5) as deterministic `.vlut` v1 files into
// `assets/looks/`:
//
//   dart run tool/gen_looks.dart            # (re)writes assets/looks/<id>.vlut
//   dart run tool/gen_looks.dart --check    # exits 1 when a committed file differs
//   dart run tool/gen_looks.dart --out=DIR  # writes somewhere else
//
// * Every look is a pure per-pixel colour function on display-referred [0, 1] RGB, sampled on a
//   [lookTableSize]³ lattice (red fastest, the CORE-21 layout) and written with `writeVlut`
//   (float16, round to nearest even).
// * The functions use only + − × ÷ and clamps (no pow/exp/trig), so the bytes are identical on
//   every host and Dart version: the output is committed and a test regenerates it and compares.
// * Preset ids are lower-case (`teal_orange`): the bundled-look extractor accepts `[a-z0-9_-]` only
//   (`BundledLookFiles`), and the asset path is `assets/looks/<id>.vlut`.
// * Intensity is the engine's: it mixes the source and the table by `BuiltinLook.intensity`.
// * Pure Dart (no Flutter imports), so `dart run` works.

import 'dart:io';
import 'dart:typed_data';

import 'package:vwish_editor_core/formats.dart' show writeVlut;

/// Edge length N of every generated table (33³ × 3 half floats ≈ 210 KB per look).
const int lookTableSize = 33;

/// The built-in look ids, in carousel order (ux.md §10.7).
const List<String> lookIds = <String>[
  'teal_orange',
  'warm',
  'cool',
  'vivid',
  'matte',
  'fade',
  'mono',
  'noir',
  'sepia',
  'vintage',
  'cinematic',
  'pastel',
];

/// A colour as red, green, blue in [0, 1] (not clamped between stages).
typedef Rgb = (double, double, double);

double _clamp01(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);

Rgb _clamp(Rgb c) => (_clamp01(c.$1), _clamp01(c.$2), _clamp01(c.$3));

/// Rec. 709 luma.
double _luma(Rgb c) => 0.2126 * c.$1 + 0.7152 * c.$2 + 0.0722 * c.$3;

Rgb _map(Rgb c, double Function(double) f) => (f(c.$1), f(c.$2), f(c.$3));

Rgb _add(Rgb c, Rgb o, [double w = 1]) => (c.$1 + o.$1 * w, c.$2 + o.$2 * w, c.$3 + o.$3 * w);

/// Saturation around luma: 0 = monochrome, 1 = unchanged.
Rgb _sat(Rgb c, double s) {
  final l = _luma(c);
  return (l + (c.$1 - l) * s, l + (c.$2 - l) * s, l + (c.$3 - l) * s);
}

/// Linear contrast around mid grey: 1 = unchanged.
Rgb _contrast(Rgb c, double k) => _map(c, (x) => (x - 0.5) * k + 0.5);

/// Maps black to [black] and white to [white] (a matte or faded range).
Rgb _range(Rgb c, double black, double white) => _map(c, (x) => black + x * (white - black));

double _smooth(double x) {
  final t = _clamp01(x);
  return t * t * (3 - 2 * t);
}

/// An S-curve: [k] 0 = identity, 1 = smoothstep; negative flattens.
Rgb _curve(Rgb c, double k) => _map(c, (x) => x + k * (_smooth(x) - x));

/// Adds [shadows] weighted towards dark pixels and [highlights] towards bright ones.
Rgb _splitTone(Rgb c, Rgb shadows, Rgb highlights) {
  final l = _clamp01(_luma(c));
  final ws = (1 - l) * (1 - l);
  final wh = l * l;
  return _add(_add(c, shadows, ws), highlights, wh);
}

/// The look function of [id] on a display-referred colour.
Rgb lookFunction(String id, Rgb c) {
  switch (id) {
    case 'teal_orange':
      var o = _contrast(c, 1.1);
      o = _sat(o, 1.15);
      o = _splitTone(o, (-0.09, 0.02, 0.1), (0.1, 0.03, -0.09));
      return _clamp(o);
    case 'warm':
      return _clamp(_contrast((c.$1 * 1.07 + 0.015, c.$2 * 1.01, c.$3 * 0.9), 1.03));
    case 'cool':
      return _clamp(_contrast((c.$1 * 0.91, c.$2 * 1.0, c.$3 * 1.08 + 0.012), 1.03));
    case 'vivid':
      return _clamp(_contrast(_sat(c, 1.42), 1.08));
    case 'matte':
      return _clamp(_sat(_range(c, 0.075, 0.94), 0.9));
    case 'fade':
      return _clamp(_sat(_range(_contrast(c, 0.9), 0.13, 0.96), 0.78));
    case 'mono':
      final l = _luma(c);
      return _clamp((l, l, l));
    case 'noir':
      var l = _curve((_luma(c), _luma(c), _luma(c)), 1).$1;
      l = _clamp01((l - 0.5) * 1.18 + 0.5 - 0.03);
      return (l, l, l);
    case 'sepia':
      final r = c.$1, g = c.$2, b = c.$3;
      final s = (0.393 * r + 0.769 * g + 0.189 * b, 0.349 * r + 0.686 * g + 0.168 * b, 0.272 * r + 0.534 * g + 0.131 * b);
      final l = _luma(c);
      // 85 % sepia matrix over 15 % luma keeps highlights from clipping to a flat tone.
      return _clamp((s.$1 * 0.85 + l * 0.15, s.$2 * 0.85 + l * 0.15, s.$3 * 0.85 + l * 0.15));
    case 'vintage':
      var o = _sat(c, 0.8);
      o = _range(o, 0.06, 0.94);
      o = _add(o, (0.045, 0.02, -0.045));
      o = _splitTone(o, (-0.01, 0.025, 0.0), (0.03, 0.0, -0.02));
      return _clamp(o);
    case 'cinematic':
      var o = _curve(c, 0.4);
      o = _sat(o, 0.92);
      o = _splitTone(o, (-0.035, 0.012, 0.05), (0.045, 0.015, -0.035));
      return _clamp(o);
    case 'pastel':
      var o = _sat(c, 0.7);
      o = _range(o, 0.17, 0.97);
      o = _add(o, (0.02, 0.0, 0.03));
      return _clamp(o);
  }
  throw ArgumentError.value(id, 'id', 'not a built-in look');
}

/// The `.vlut` bytes of look [id].
Uint8List generateLook(String id) {
  final n = lookTableSize;
  final rgb = List<double>.filled(n * n * n * 3, 0);
  final step = 1.0 / (n - 1);
  var o = 0;
  for (var b = 0; b < n; b++) {
    for (var g = 0; g < n; g++) {
      for (var r = 0; r < n; r++) {
        final out = lookFunction(id, (r * step, g * step, b * step));
        rgb[o++] = out.$1;
        rgb[o++] = out.$2;
        rgb[o++] = out.$3;
      }
    }
  }
  return writeVlut(n, rgb);
}

/// Every look by id.
Map<String, Uint8List> generateLooks() => {for (final id in lookIds) id: generateLook(id)};

/// The package's `assets/looks/` directory (this script lives in `tool/`).
Directory get defaultLooksDirectory => Directory.fromUri(Platform.script.resolve('../assets/looks'));

/// Writes the looks into [dir] (or compares with [check]); returns the ids that differ.
List<String> writeLooks(Directory dir, {bool check = false}) {
  final differing = <String>[];
  for (final entry in generateLooks().entries) {
    final file = File('${dir.path}/${entry.key}.vlut');
    final same = file.existsSync() && _same(file.readAsBytesSync(), entry.value);
    if (!same) differing.add(entry.key);
    if (!check && !same) {
      dir.createSync(recursive: true);
      file.writeAsBytesSync(entry.value, flush: true);
    }
  }
  return differing;
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Entry point (see the file comment).
void main(List<String> args) {
  final check = args.contains('--check');
  final outArg = args.where((a) => a.startsWith('--out=')).map((a) => a.substring(6)).firstOrNull;
  final dir = outArg == null ? defaultLooksDirectory : Directory(outArg);
  final differing = writeLooks(dir, check: check);
  if (check) {
    if (differing.isNotEmpty) {
      stderr.writeln('Out of date: ${differing.join(', ')}. Run: dart run tool/gen_looks.dart');
      exit(1);
    }
    stdout.writeln('${lookIds.length} looks up to date.');
    return;
  }
  stdout.writeln(differing.isEmpty ? 'Looks already up to date in ${dir.path}.' : 'Wrote ${differing.length} look(s) to ${dir.path}: ${differing.join(', ')}');
}
