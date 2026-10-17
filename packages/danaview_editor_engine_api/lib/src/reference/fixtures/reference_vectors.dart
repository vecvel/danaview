// OWNER: API-03
//
// Builders of the shared JSON vectors in `test_fixtures/vectors/` (ARCH §11.6, §5, §11.7): keyframe
// evaluation with the D-35 frame mapping, the placement matrix M (plus the domain inputs `boxAt`
// derives it from), every render-math stage on 8 × 8 images, gain envelopes and dB, reference
// mixes measured per 20 ms window, typewriter reveal and the 8× scale-keyframed text case.
// Inputs are fixed here; expected values come from the Dart reference implementation (core
// geometry / evaluation and `../../math/`). `tool/regen_goldens.dart` writes them; the Swift and
// Kotlin suites (IOS-08/09/18, AND-08/09) and QA-03/QA-11 read them (format:
// `test_fixtures/vectors/README.md`). Numbers are rounded to 1e-9.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/formats.dart' show readVlut;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import '../../math/audio_math.dart';
import '../../math/layer_params.dart';
import '../../math/lut_table.dart';
import '../../math/raster.dart';
import '../../math/render_math.dart';
import '../audio_mix.dart';
import '../reference_renderer.dart';
import '../reference_sources.dart';
import '../synthetic_sources.dart';
import 'golden_cases.dart';

/// The JSON vector files of `test_fixtures/vectors/` (ARCH §11.6, BUILD_PLAN API-03).
abstract final class ReferenceVectors {
  /// Repository path of the generator, recorded in every file.
  static const String generatedBy = 'packages/danaview_editor_engine_api/tool/regen_goldens.dart';

  /// Edge of the synthetic LUT stored as a `.vlut` file next to the vectors.
  static const int lutFileSize = 17;

  /// Path of that LUT relative to `test_fixtures/vectors/`.
  static const String lutFile = 'luts/synthetic_17.vlut';

  /// File name (relative to `test_fixtures/vectors/`) → JSON document.
  static Map<String, Map<String, Object?>> all() => {
        'keyframes.json': keyframes(),
        'transform.json': transform(),
        'render_math.json': renderMath(),
        'gain.json': gain(),
        'audio_mix.json': audioMix(),
        'typewriter.json': typewriter(),
        'text_scale_8x.json': textScale8x(),
      };

  /// Binary files (relative to `test_fixtures/vectors/`) referenced by the vectors.
  static Map<String, Uint8List> binaries() => {lutFile: SyntheticSources.vlutBytes(lutFileSize)};

  // ---------------------------------------------------------------------------------------------
  // Helpers.
  // ---------------------------------------------------------------------------------------------

  /// Rounds to 1e-9 (and normalizes −0).
  static double r9(double v) {
    if (!v.isFinite) throw ArgumentError.value(v, 'v', 'vectors hold finite numbers only');
    final x = (v * 1e9).roundToDouble() / 1e9;
    return x == 0 ? 0.0 : x;
  }

  static List<double> _l(Iterable<double> v) => [for (final x in v) r9(x)];

  static List<double> _c(RenderRgba c) => _l(c.toList());

  static List<List<double>> _img(RenderRaster r) => [
        for (var i = 0; i < r.width * r.height; i++) _l([r.data[4 * i], r.data[4 * i + 1], r.data[4 * i + 2], r.data[4 * i + 3]]),
      ];

  static Map<String, Object?> _header(String spec, String rule) => {'schema': 1, 'generatedBy': generatedBy, 'spec': spec, 'rule': rule};

  static Map<String, Object?> _keys(List<AnimKey> keys) => {
        'keys': [
          for (final k in keys) [k.tUs, r9(k.v)],
        ],
      };

  // ---------------------------------------------------------------------------------------------
  // keyframes.json
  // ---------------------------------------------------------------------------------------------

  /// Keyframe evaluation with the platform-time rule: for sample frame k, `tau = floor(k·10⁶/fps)`
  /// (up to 1 µs before the plan edge) maps to `k = frameIndexNearest(tau)` and the channel is
  /// evaluated at `t = timeOfFrame(k)` (ARCH §11.1 rule 2, §5, D-35).
  static Map<String, Object?> keyframes() {
    final cases = <Map<String, Object?>>[];
    void add({
      required String name,
      required String channel,
      required String property,
      required int fps,
      required int startFrame,
      required int endFrame,
      required List<(int? frame, int? us, double v)> keys,
      required List<int> samples,
    }) {
      final rate = FrameRate(fps, 1);
      final start = rate.timeOfFrame(startFrame);
      final end = rate.timeOfFrame(endFrame);
      final abs = [for (final (f, us, v) in keys) AnimKey(f != null ? rate.timeOfFrame(f) : us!, v)];
      cases.add({
        'name': name,
        'channel': channel,
        'property': property,
        'fps': fps,
        'itemStartUs': start,
        'itemDurationUs': end - start,
        ..._keys(abs),
        'samples': [
          for (final k in samples)
            () {
              final tau = floorDiv(k * microsPerSecond, fps);
              final kk = rate.frameIndexNearest(tau);
              assert(kk == k);
              final t = rate.timeOfFrame(kk);
              return {'k': k, 'tau': tau, 't': t, 'v': r9(evaluateAnimKeys(abs, t))};
            }(),
        ],
      });
    }

    add(
      name: 'scale_linear_30fps',
      channel: PlanChannels.xfS,
      property: 'transform.scale',
      fps: 30,
      startFrame: 30,
      endFrame: 120,
      keys: [(30, null, 1), (90, null, 2)],
      samples: [30, 31, 45, 60, 89, 90, 100, 119],
    );
    add(
      name: 'opacity_three_keys_24fps',
      channel: PlanChannels.xfOp,
      property: 'transform.opacity',
      fps: 24,
      startFrame: 0,
      endFrame: 72,
      keys: [(10, null, 0), (20, null, 1), (50, null, 0.25)],
      samples: [0, 5, 10, 11, 15, 20, 35, 50, 71],
    );
    add(
      name: 'rotation_60fps',
      channel: PlanChannels.xfR,
      property: 'transform.rotation',
      fps: 60,
      startFrame: 60,
      endFrame: 300,
      keys: [(60, null, 0), (180, null, 360), (240, null, -45)],
      samples: [60, 61, 120, 179, 180, 200, 240, 299],
    );
    add(
      name: 'exposure_25fps',
      channel: 'adj.exposure',
      property: 'adjust.exposure',
      fps: 25,
      startFrame: 25,
      endFrame: 100,
      keys: [(25, null, -1), (75, null, 1)],
      samples: [25, 26, 50, 74, 75, 99],
    );
    add(
      name: 'single_key_48fps',
      channel: 'adj.saturation',
      property: 'adjust.saturation',
      fps: 48,
      startFrame: 0,
      endFrame: 96,
      keys: [(40, null, 0.6)],
      samples: [0, 40, 95],
    );
    add(
      name: 'off_grid_keys_30fps',
      channel: PlanChannels.xfS,
      property: 'transform.scale',
      fps: 30,
      startFrame: 0,
      endFrame: 30,
      keys: [(null, 100000, 0.6), (null, 133333, 0.8), (null, 250001, 1)],
      samples: [0, 3, 4, 5, 7, 8, 29],
    );
    return {
      ..._header(
        'ARCH §11.1 rule 2, §5, D-35',
        'Plan channels are [[tUs, v], ...] in absolute µs, linear between keys, held outside. A platform time tau maps to '
            'k = frameIndexNearest(tau) = floor((tau·fps + 500000) / 10^6) and is evaluated at t = timeOfFrame(k) = ceil(k·10^6/fps). '
            'The same keys as item-local domain keyframes (local = abs − itemStartUs, property id) evaluate to v at t − itemStartUs.',
      ),
      'cases': cases,
    };
  }

  // ---------------------------------------------------------------------------------------------
  // transform.json
  // ---------------------------------------------------------------------------------------------

  /// Placement matrices M of ARCH §11.6 "Place" with the domain inputs `boxAt` (CORE-07) derives
  /// `base` and `xf` from.
  static Map<String, Object?> transform() {
    final cases = <Map<String, Object?>>[];
    void add(
      String name, {
      required (int, int) aspect,
      required int shortSide,
      required (double, double) source,
      FitMode fit = FitMode.fit,
      CropRect crop = CropRect.full,
      Vec2 position = Vec2.zero,
      double scale = 1,
      double rotation = 0,
      bool flipH = false,
      bool flipV = false,
    }) {
      final spec = CanvasSpec(aspect: AspectRatio(aspect.$1, aspect.$2), baseShortSide: shortSide);
      final canvas = spec.sizePx;
      final base = baseSize(fit: fit, crop: crop, source: Size2(source.$1, source.$2), canvas: canvas);
      final center = positionToCanvas(position, canvas);
      final xf = PlanTransform(cx: center.dx, cy: center.dy, s: scale, r: rotation, fx: flipH, fy: flipV);
      final m = planPlacementMatrix(xf, PlanSize(base.width, base.height), canvas);
      final pts = <List<double>>[
        [0, 0],
        [base.width, 0],
        [base.width, base.height],
        [0, base.height],
        [base.width / 2, base.height / 2],
        [base.width * 0.25, base.height * 0.75],
      ];
      cases.add({
        'name': name,
        'canvas': [spec.widthPx, spec.heightPx],
        'domain': {
          'aspect': [aspect.$1, aspect.$2],
          'baseShortSide': shortSide,
          'source': _l([source.$1, source.$2]),
          'fit': fit.name,
          'crop': _l([crop.left, crop.top, crop.right, crop.bottom]),
          'position': _l([position.x, position.y]),
          'scale': r9(scale),
          'rotation': r9(rotation),
          'flipH': flipH,
          'flipV': flipV,
        },
        'base': _l([base.width, base.height]),
        'xf': {'cx': r9(center.dx), 'cy': r9(center.dy), 's': r9(scale), 'r': r9(rotation), 'fx': flipH, 'fy': flipV},
        'M': _l([m.a, m.b, m.c, m.d, m.tx, m.ty]),
        'points': [
          for (final p in pts)
            {
              'local': _l(p),
              'canvas': () {
                final q = m.apply(Offset2(p[0], p[1]));
                return _l([q.dx, q.dy]);
              }(),
            },
        ],
      });
    }

    add('identity_full_canvas', aspect: (16, 9), shortSide: 1080, source: (1920, 1080));
    add('portrait_source_fit_landscape', aspect: (16, 9), shortSide: 1080, source: (1080, 1920));
    add('fill_with_crop',
        aspect: (16, 9),
        shortSide: 1080,
        source: (1280, 720),
        fit: FitMode.fill,
        crop: const CropRect(left: 0.1, top: 0.05, right: 0.9, bottom: 0.95));
    add('stretch_square_canvas', aspect: (1, 1), shortSide: 720, source: (1920, 1080), fit: FitMode.stretch);
    add('rot90_flip_h',
        aspect: (16, 9), shortSide: 1080, source: (1920, 1080), scale: 0.5, rotation: 90, flipH: true, position: const Vec2(0.25, -0.25));
    add('rot33_5_scale_position',
        aspect: (16, 9), shortSide: 1080, source: (1920, 1080), scale: 0.5, rotation: 33.5, position: const Vec2(-0.1, 0.2));
    add('rot180_flip_v', aspect: (16, 9), shortSide: 1080, source: (1280, 720), rotation: 180, flipV: true, scale: 1.25);
    add('neg15_5_both_flips',
        aspect: (16, 9),
        shortSide: 1080,
        source: (1080, 1920),
        crop: const CropRect(left: 0.1, top: 0.05, right: 0.9, bottom: 0.95),
        scale: 0.8,
        rotation: -15.5,
        flipH: true,
        flipV: true,
        position: const Vec2(-0.03125, 0.0555));
    add('portrait_canvas_landscape_source', aspect: (9, 16), shortSide: 1080, source: (1920, 1080), scale: 2, rotation: 270);
    add('scale_8x', aspect: (16, 9), shortSide: 720, source: (120, 24), scale: 8, rotation: 10);
    return {
      ..._header(
        'ARCH §11.6 Place, CORE-07 boxAt',
        'M = T(cx, cy)·R(r° clockwise, y down)·S(s·(fx ? −1 : 1), s·(fy ? −1 : 1))·T(−base.w/2, −base.h/2), written [a, b, c, d, tx, ty]: '
            '(x, y) in base-local px maps to (a·x + c·y + tx, b·x + d·y + ty) canvas px. Domain: base = baseSize(fit, crop, source, canvas); '
            '(cx, cy) = (W/2 + position.x·W, H/2 + position.y·H). Rotations at multiples of 90° are exact.',
      ),
      'cases': cases,
    };
  }

  // ---------------------------------------------------------------------------------------------
  // render_math.json
  // ---------------------------------------------------------------------------------------------

  static RenderRaster _image(RenderRgba Function(int x, int y) f, [int w = 8, int h = 8]) {
    final r = RenderRaster(w, h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        r.setPixel(x, y, f(x, y));
      }
    }
    return r;
  }

  static final RenderRaster _impulse = _image((x, y) => x == 4 && y == 4 ? const RenderRgba(1, 1, 1) : RenderRgba.transparent);
  static final RenderRaster _edge = _image((x, y) => x < 4 ? const RenderRgba(0, 0, 0) : const RenderRgba(1, 1, 1));
  static final RenderRaster _gradient = _image((x, y) => RenderRgba(x / 7, y / 7, 0.5));
  static final RenderRaster _alphaEdge = _image((x, y) => x < 4 ? const RenderRgba(0.9, 0.1, 0.1) : RenderRgba.transparent);
  static final RenderRaster _checker =
      _image((x, y) => ((x >> 1) + (y >> 1)).isEven ? const RenderRgba(0.8, 0.7, 0.2) : const RenderRgba(0.1, 0.2, 0.4));

  static Map<String, Object?> _adjJson(PlanAdjust a) => {
        'exposure': r9(a.exposure),
        'brightness': r9(a.brightness),
        'contrast': r9(a.contrast),
        'highlights': r9(a.highlights),
        'shadows': r9(a.shadows),
        'saturation': r9(a.saturation),
        'temperature': r9(a.temperature),
        'tint': r9(a.tint),
      };

  static Map<String, Object?> _chromaJson(PlanChroma c) =>
      {'key': PlanJson.encodeColor(0xFF000000 | c.key).substring(0, 7), 'sim': r9(c.sim), 'smooth': r9(c.smooth), 'spill': r9(c.spill)};

  static Map<String, Object?> _maskJson(PlanMask m) => {
        'shape': m.shape.name,
        'cx': r9(m.cx),
        'cy': r9(m.cy),
        'w': r9(m.w),
        'h': r9(m.h),
        'r': r9(m.r),
        'corner': r9(m.corner),
        'feather': r9(m.feather),
        'op': r9(m.op),
        'inv': m.inv,
      };

  static Map<String, Object?> _cmaskJson(CanvasMask m) =>
      {'cx': r9(m.cx), 'cy': r9(m.cy), 'w': r9(m.w), 'h': r9(m.h), 'r': r9(m.r), 'feather': r9(m.feather), 'inv': m.inv};

  static Map<String, Object?> _lutJson(RenderLut lut) => {'n': lut.size, 'rgb': _l(lut.rgb)};

  /// Every render-math stage as 8 × 8 image rows plus scalar tables (ARCH §11.6).
  static Map<String, Object?> renderMath() {
    final rows = <Map<String, Object?>>[];
    const tol = 1e-6;

    void pointwise(String stage, String name, Map<String, Object?> params, RenderRgba input, RenderRgba Function(RenderRgba) f,
        {String space = 'straight'}) {
      rows.add({
        'stage': stage,
        'name': name,
        'space': space,
        'params': params,
        'w': 8,
        'h': 8,
        'in': _c(input),
        'out': _c(f(input)),
        'tol': tol
      });
    }

    void image(String stage, String name, Map<String, Object?> params, RenderRaster input, RenderRaster output, {Object? inUniform}) {
      rows.add({
        'stage': stage,
        'name': name,
        'space': 'premultiplied',
        'params': params,
        'w': input.width,
        'h': input.height,
        if (inUniform != null) 'in': inUniform else 'inImage': _img(input),
        'outImage': _img(output),
        'tol': tol,
      });
    }

    const colours = <String, RenderRgba>{
      'blue_mid': RenderRgba(0.2, 0.5, 0.8),
      'orange': RenderRgba(0.9, 0.3, 0.1),
      'near_black': RenderRgba(0.05, 0.05, 0.05),
      'near_white': RenderRgba(0.95, 0.92, 0.9),
      'grey': RenderRgba(0.5, 0.5, 0.5),
    };

    // Chroma key + spill.
    const green = PlanChroma(key: 0x00B140, sim: 0.4, smooth: 0.1, spill: 0.5);
    const blue = PlanChroma(key: 0x0000FF, sim: 0.3, smooth: 0.2, spill: 0.5);
    final chromaCases = <(String, PlanChroma, RenderRgba)>[
      ('green_exact_key', green, RenderRgba.fromRgb(0x00B140)),
      ('green_near_key', green, const RenderRgba(0.1, 0.65, 0.3)),
      ('green_edge_partial', green, const RenderRgba(0.3, 0.62, 0.35)),
      ('green_far_orange', green, colours['orange']!),
      ('green_spill_on_skin', green, const RenderRgba(0.75, 0.8, 0.55)),
      ('green_no_spill', const PlanChroma(key: 0x00B140, sim: 0.4, smooth: 0.1, spill: 0), const RenderRgba(0.6, 0.75, 0.5)),
      ('green_smooth_zero', const PlanChroma(key: 0x00B140, sim: 0.4, smooth: 0, spill: 0), const RenderRgba(0.25, 0.6, 0.35)),
      ('green_straight_alpha_half', green, const RenderRgba(0.1, 0.65, 0.3, 0.5)),
      ('blue_exact_key', blue, const RenderRgba(0, 0, 1)),
      ('blue_spill_on_white', blue, const RenderRgba(0.8, 0.85, 0.98)),
      ('blue_far_yellow', blue, const RenderRgba(0.9, 0.85, 0.1)),
    ];
    for (final (name, ch, c) in chromaCases) {
      pointwise('chromaKey', name, _chromaJson(ch), c, (x) => RenderMath.chromaKey(x, ch));
    }

    // Grade steps.
    for (final ev in const [-1.0, -0.25, 0.25, 1.0]) {
      for (final e in colours.entries.take(3)) {
        pointwise('exposure', 'exposure_${ev}_${e.key}', {'exposure': ev}, e.value, (x) => RenderMath.exposure(x, ev));
      }
    }
    for (final (b, c) in const [(0.2, 0.0), (0.0, 0.5), (-0.3, -0.4), (1.0, 1.0)]) {
      for (final e in colours.entries.take(3)) {
        pointwise('brightnessContrast', 'bc_${b}_${c}_${e.key}', {'brightness': b, 'contrast': c}, e.value,
            (x) => RenderMath.brightnessContrast(x, b, c));
      }
    }
    for (final (h, s) in const [(1.0, 0.0), (0.0, 1.0), (-1.0, -1.0), (0.5, 0.5)]) {
      for (final e in colours.entries.skip(1)) {
        pointwise('highlightsShadows', 'hs_${h}_${s}_${e.key}', {'highlights': h, 'shadows': s}, e.value,
            (x) => RenderMath.highlightsShadows(x, h, s));
      }
    }
    for (final s in const [-1.0, -0.5, 0.5, 1.0]) {
      for (final e in colours.entries.take(2)) {
        pointwise('saturation', 'saturation_${s}_${e.key}', {'saturation': s}, e.value, (x) => RenderMath.saturation(x, s));
      }
    }
    for (final (temp, tint) in const [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0), (0.6, -0.4)]) {
      for (final e in [colours.entries.first, colours.entries.elementAt(3)]) {
        pointwise('temperatureTint', 'tt_${temp}_${tint}_${e.key}', {'temperature': temp, 'tint': tint}, e.value,
            (x) => RenderMath.temperatureTint(x, temp, tint));
      }
    }
    final grades = <(String, PlanAdjust)>[
      (
        'all_positive',
        const PlanAdjust(
            exposure: 0.3, brightness: 0.1, contrast: 0.25, highlights: 0.3, shadows: 0.3, saturation: 0.4, temperature: 0.5, tint: 0.3)
      ),
      (
        'all_negative',
        const PlanAdjust(
            exposure: -0.3,
            brightness: -0.1,
            contrast: -0.25,
            highlights: -0.3,
            shadows: -0.3,
            saturation: -0.4,
            temperature: -0.5,
            tint: -0.3)
      ),
      (
        'mixed',
        const PlanAdjust(
            exposure: 0.3, brightness: -0.1, contrast: 0.25, highlights: -0.3, shadows: 0.3, saturation: 0.4, temperature: 0.5, tint: -0.3)
      ),
      ('clamping_extremes', const PlanAdjust(exposure: 1, brightness: 1, contrast: 1, saturation: 1, temperature: 1)),
    ];
    for (final (name, a) in grades) {
      for (final e in colours.entries) {
        pointwise('grade', 'grade_${name}_${e.key}', {'adj': _adjJson(a)}, e.value, (x) => RenderMath.grade(x, a));
      }
    }

    // LUT.
    final lut2 = RenderLut.generate(2, (r, g, b) => (1 - 0.8 * r, 0.5 * g + 0.25, b * b));
    final lut3 = RenderLut.identity(3);
    final lut5 = RenderLut.fromVlut(readVlut(SyntheticSources.vlutBytes(5)));
    final lut17 = RenderLut.fromVlut(readVlut(SyntheticSources.vlutBytes(lutFileSize)));
    final lutInputs = <RenderRgba>[
      const RenderRgba(0, 0, 0),
      const RenderRgba(1, 1, 1),
      const RenderRgba(0.5, 0.5, 0.5),
      const RenderRgba(0.2, 0.5, 0.8),
      const RenderRgba(0.9, 0.3, 0.1, 0.7),
      const RenderRgba(0.33, 0.66, 0.99),
    ];
    final luts = <String, Map<String, Object?>>{
      'n2_inline': _lutJson(lut2),
      'n3_identity_inline': _lutJson(lut3),
      'n5_synthetic_inline': _lutJson(lut5),
      'n17_synthetic_file': {'n': lutFileSize, 'file': lutFile},
    };
    for (final (name, lut) in <(String, RenderLut)>[
      ('n2_inline', lut2),
      ('n3_identity_inline', lut3),
      ('n5_synthetic_inline', lut5),
      ('n17_synthetic_file', lut17)
    ]) {
      for (final i in const [1.0, 0.5]) {
        for (final (j, c) in lutInputs.indexed) {
          pointwise('lut', 'lut_${name}_i${i}_$j', {'lut': name, 'i': i}, c, (x) => RenderMath.lut(x, lut, i));
        }
      }
    }

    // Blur (σ in raster px; premultiplied, all four channels, clamp-to-edge).
    for (final (name, src, sigma) in <(String, RenderRaster, double)>[
      ('impulse_s0_75', _impulse, 0.75),
      ('edge_s1', _edge, 1.0),
      ('gradient_s1_5', _gradient, 1.5),
      ('alpha_edge_s1', _alphaEdge, 1.0),
      ('checker_s2_5', _checker, 2.5),
      ('skipped_s0_4', _checker, 0.4),
    ]) {
      image('gaussianBlur', name, {'sigma': sigma}, src, RenderMath.gaussianBlur(src, sigma));
    }
    // Sharpen.
    for (final (name, src, amount) in <(String, RenderRaster, double)>[
      ('edge_0_5', _edge, 0.5),
      ('checker_1', _checker, 1.0),
      ('alpha_edge_1', _alphaEdge, 1.0),
      ('gradient_1', _gradient, 1.0),
    ]) {
      image('sharpen', name, {'amount': amount}, src, RenderMath.sharpen(src, amount));
    }
    // Vignette and item masks over the 8×8 layer box (texel centres at ((x + 0.5)/8, (y + 0.5)/8)).
    const fill = RenderRgba(0.8, 0.6, 0.4);
    final uniform = RenderRaster.filled(8, 8, fill);
    for (final (amount, aspect) in const [(1.0, 1.0), (0.5, 16 / 9), (0.9, 9 / 16)]) {
      image(
        'vignette',
        'vignette_${amount}_${aspect.toStringAsFixed(3)}',
        {'amount': amount, 'aspect': r9(aspect)},
        uniform,
        ReferenceRenderer.applyEffects(uniform, base: PlanSize(aspect, 1), vignette: amount),
        inUniform: _c(fill),
      );
    }
    final maskCases = <(String, PlanMask, PlanSize)>[
      ('rect_half', const PlanMask(shape: PlanMaskShape.rect, w: 0.5, h: 0.5), const PlanSize(8, 8)),
      (
        'rect_rot45_round_feather',
        const PlanMask(shape: PlanMaskShape.rect, w: 0.6, h: 0.6, r: 45, corner: 0.5, feather: 0.3),
        const PlanSize(8, 8)
      ),
      (
        'ellipse_inverted',
        const PlanMask(shape: PlanMaskShape.ellipse, cx: 0.45, cy: 0.55, w: 0.8, h: 0.6, inv: true),
        const PlanSize(8, 8)
      ),
      ('ellipse_feather_op_half', const PlanMask(shape: PlanMaskShape.ellipse, w: 0.7, h: 0.7, feather: 1, op: 0.5), const PlanSize(8, 8)),
      (
        'rect_rot90_wide_base',
        const PlanMask(shape: PlanMaskShape.rect, w: 0.6, h: 0.4, r: 90, corner: 0.2, feather: 0.1),
        const PlanSize(16, 9)
      ),
      (
        'rect_rot_neg30_wide_base_inv',
        const PlanMask(shape: PlanMaskShape.rect, w: 0.5, h: 0.8, r: -30, feather: 0.05, inv: true, op: 0.8),
        const PlanSize(16, 9)
      ),
    ];
    for (final (name, m, base) in maskCases) {
      image(
          'mask',
          name,
          {
            'mask': _maskJson(m),
            'base': _l([base.w, base.h])
          },
          uniform,
          ReferenceRenderer.applyEffects(uniform, base: base, mask: m),
          inUniform: _c(fill));
    }
    // Canvas masks on an 8 × 8 canvas (pixel centres at (x + 0.5, y + 0.5) canvas px).
    final cmaskCases = <(String, CanvasMask)>[
      ('rect_hard', const CanvasMask(cx: 4, cy: 4, w: 4, h: 6)),
      ('rect_rot30_feather', const CanvasMask(cx: 4, cy: 4, w: 5, h: 3, r: 30, feather: 1.5)),
      ('inverted_band', const CanvasMask(cx: 4, cy: 2, w: 8, h: 3, feather: 2, inv: true)),
      ('wipe_start_zero_width', const CanvasMask(cx: 0, cy: 4, w: 0, h: 8, feather: 2)),
    ];
    for (final (name, m) in cmaskCases) {
      final out = RenderRaster(8, 8);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final k = RenderMath.canvasMaskAlpha(m, x + 0.5, y + 0.5);
          out.setPixel(x, y, RenderRgba(fill.r * k, fill.g * k, fill.b * k, k));
        }
      }
      image('canvasMask', name, {'cmask': _cmaskJson(m)}, uniform, out, inUniform: _c(fill));
    }
    // Place: the 8 × 8 gradient as a layer raster over `base`, placed on a transparent 8 × 8 canvas.
    const tiny = PlanCanvas(w: 8, h: 8, fps: 30);
    final placeCases = <(String, PlanSize, PlanTransform)>[
      ('identity', const PlanSize(8, 8), const PlanTransform(cx: 4, cy: 4)),
      ('rot90_flip_h', const PlanSize(8, 8), const PlanTransform(cx: 4, cy: 4, r: 90, fx: true)),
      ('half_scale_offset_op', const PlanSize(8, 8), const PlanTransform(cx: 2.5, cy: 5, s: 0.5, op: 0.5)),
      ('narrow_base_rot45', const PlanSize(4, 8), const PlanTransform(cx: 4, cy: 4, s: 0.9, r: 45)),
      ('flip_v_rot180_scale', const PlanSize(8, 4), const PlanTransform(cx: 4, cy: 4, s: 0.75, r: 180, fy: true)),
    ];
    for (final (name, base, xf) in placeCases) {
      final out = RenderRaster(8, 8);
      ReferenceRenderer.placeOnto(out, _gradient, RenderMath.placement(xf, base, tiny), base, xf.op, const [], 1, 1);
      final m = RenderMath.placement(xf, base, tiny);
      image(
          'place',
          name,
          {
            'base': _l([base.w, base.h]),
            'xf': {'cx': xf.cx, 'cy': xf.cy, 's': xf.s, 'r': xf.r, 'fx': xf.fx, 'fy': xf.fy, 'op': xf.op},
            'M': _l([m.a, m.b, m.c, m.d, m.tx, m.ty])
          },
          _gradient,
          out);
    }
    // Premultiplied source-over.
    for (final (name, src, dst) in const <(String, RenderRgba, RenderRgba)>[
      ('half_red_over_blue', RenderRgba(0.5, 0, 0, 0.5), RenderRgba(0, 0, 1, 1)),
      ('opaque_over', RenderRgba(0.2, 0.4, 0.6, 1), RenderRgba(1, 1, 1, 1)),
      ('transparent_over', RenderRgba(0, 0, 0, 0), RenderRgba(0.3, 0.3, 0.3, 1)),
      ('quarter_white_over_translucent', RenderRgba(0.25, 0.25, 0.25, 0.25), RenderRgba(0, 0.4, 0, 0.5)),
    ]) {
      rows.add({
        'stage': 'composite',
        'name': name,
        'space': 'premultiplied',
        'params': {'dst': _c(dst)},
        'w': 8,
        'h': 8,
        'in': _c(src),
        'out': _c(RenderMath.sourceOver(src, dst)),
        'tol': tol,
      });
    }
    // Sprite reveal: glyph columns 0,0,1,1,2,2,bg,bg.
    final glyphs = [
      for (var y = 0; y < 8; y++)
        for (var x = 0; x < 8; x++) x < 6 ? x >> 1 : RenderMath.spriteBackgroundGlyph
    ];
    for (final reveal in const <double?>[null, 0, 1.5, 2, 3.99, 10]) {
      final out = RenderRaster(8, 8);
      for (var i = 0; i < 64; i++) {
        if (RenderMath.spriteTexelDrawn(glyphs[i], reveal)) out.setPixel(i % 8, i ~/ 8, const RenderRgba(1, 1, 1));
      }
      rows.add({
        'stage': 'spriteReveal',
        'name': 'reveal_${reveal ?? 'not_animated'}',
        'space': 'premultiplied',
        'params': {'reveal': reveal, 'glyphs': glyphs},
        'w': 8,
        'h': 8,
        'in': _c(const RenderRgba(1, 1, 1)),
        'outImage': _img(out),
        'tol': tol,
      });
    }

    // Scalars.
    final sigmas = <Map<String, Object?>>[
      for (final (blur, w, h, perSource, renderScale) in const [
        (0.5, 1080, 1920, 0.5625, 0.05),
        (0.05, 1920, 1080, 0.8, 1.0),
        (1.0, 1280, 720, 1.0, 0.075),
        (0.01, 1280, 720, 1.0, 1.0),
        (0.4, 3840, 2160, 2.0, 0.025),
      ])
        () {
          final canvasSigma = RenderMath.blurSigmaCanvasPx(blur, w, h);
          final source = RenderMath.blurSigmaSourcePx(canvasSigma, perSource);
          final render = RenderMath.blurSigmaRenderPx(canvasSigma, renderScale);
          return {
            'blur': blur,
            'canvas': [w, h],
            'canvasPxPerSourcePx': perSource,
            'renderScale': renderScale,
            'sigmaCanvasPx': r9(canvasSigma),
            'sigmaSourcePx': r9(source),
            'sigmaRenderPx': r9(render),
            'radiusSource': RenderMath.blurRadius(source),
            'radiusRender': RenderMath.blurRadius(render),
            'skippedSource': RenderMath.blurSkipped(source),
            'skippedRender': RenderMath.blurSkipped(render),
          };
        }(),
    ];
    final kernels = [
      for (final s in const [0.5, 1.0, 2.5]) {'sigma': s, 'radius': RenderMath.blurRadius(s), 'weights': _l(RenderMath.gaussianKernel(s))},
    ];
    final vignette = [
      for (final (u, v, aspect, amount) in const [
        (0.5, 0.5, 1.0, 1.0),
        (0.0, 0.0, 1.0, 1.0),
        (1.0, 0.5, 16 / 9, 0.6),
        (0.2, 0.9, 9 / 16, 0.3)
      ])
        {'u': u, 'v': v, 'aspect': r9(aspect), 'amount': amount, 'factor': r9(RenderMath.vignetteFactor(u, v, aspect, amount))},
    ];
    final maskPoints = [
      for (final (m, base, u, v) in <(PlanMask, PlanSize, double, double)>[
        (const PlanMask(shape: PlanMaskShape.rect, w: 0.5, h: 0.5), const PlanSize(100, 100), 0.5, 0.5),
        (const PlanMask(shape: PlanMaskShape.rect, w: 0.5, h: 0.5), const PlanSize(100, 100), 0.75, 0.5),
        (const PlanMask(shape: PlanMaskShape.rect, w: 0.5, h: 0.5, feather: 0.4), const PlanSize(100, 100), 0.75, 0.5),
        (const PlanMask(shape: PlanMaskShape.ellipse, w: 0.5, h: 0.25, feather: 0.2), const PlanSize(160, 90), 0.6, 0.55),
        (const PlanMask(shape: PlanMaskShape.rect, w: 0.4, h: 0.2, r: 90, corner: 0.5), const PlanSize(200, 100), 0.5, 0.65),
        (const PlanMask(shape: PlanMaskShape.ellipse, w: 0.3, h: 0.3, inv: true, op: 0.7), const PlanSize(64, 64), 0.1, 0.1),
      ])
        {
          'mask': _maskJson(m),
          'base': _l([base.w, base.h]),
          'u': u,
          'v': v,
          'alpha': r9(RenderMath.maskAlpha(m, u, v, base.w, base.h))
        },
    ];
    final cmaskPoints = [
      for (final (m, x, y) in const <(CanvasMask, double, double)>[
        (CanvasMask(cx: 960, cy: 540, w: 1920, h: 1080), 10, 10),
        (CanvasMask(cx: 0, cy: 540, w: 0, h: 1080, feather: 21.6), 10.8, 540),
        (CanvasMask(cx: 640, cy: 360, w: 700, h: 400, r: 20, feather: 30), 980, 360),
        (CanvasMask(cx: 960, cy: 270, w: 1920, h: 540, feather: 38.4, inv: true), 500, 540),
      ])
        {'cmask': _cmaskJson(m), 'x': x, 'y': y, 'alpha': r9(RenderMath.canvasMaskAlpha(m, x, y))},
    ];
    final bytes = [
      for (final v in const [0.0, 0.002, 0.25, 0.498, 0.5, 0.998, 1.0, -0.2, 1.3]) {'v': r9(v), 'byte': RenderMath.toByte(v)},
    ];
    return {
      ..._header(
        'ARCH §11.6 (danaview_editor_core schema/effects_reference.md), D-08',
        'Each row runs one stage on a w×h image whose every texel is `in` (or `inImage`, row-major RGBA) and expects `out` everywhere '
            '(or `outImage`). space = straight: colours are straight alpha; premultiplied: RGB already multiplied by alpha. Layer-box '
            'stages (vignette, mask) use texel centres u = (x + 0.5)/w, v = (y + 0.5)/h; canvasMask and place use canvas px (x + 0.5, y + 0.5). '
            'tol is the CPU tolerance; GPU implementations use the ARCH §11.6 parity tolerance.',
      ),
      'luts': luts,
      'rows': rows,
      'scalars': {
        'blurSigma': sigmas,
        'gaussianKernel': kernels,
        'vignetteFactor': vignette,
        'maskAlpha': maskPoints,
        'canvasMaskAlpha': cmaskPoints,
        'toByte': bytes,
      },
    };
  }

  // ---------------------------------------------------------------------------------------------
  // gain.json
  // ---------------------------------------------------------------------------------------------

  /// Gain envelopes sampled at 48 kHz sample times, dB conversions and the equal-power crossfade
  /// sampling error (ARCH §11.6 Audio, §11.7, D-37).
  static Map<String, Object?> gain() {
    const step = 20000; // lowering samples equal-power curves every 20 ms
    List<AnimKey> curve(TimeUs from, int n, double Function(double x) f) => [
          for (var j = 0; j <= n; j++) AnimKey(from + j * step, f(j / n)),
        ];
    final envelopes = <(String, List<AnimKey>, List<int>, double Function(double t)?)>[
      ('unity', const [AnimKey(0, 1)], [0, 1, 47999, 48000], null),
      ('boost_200pct', const [AnimKey(0, 2)], [0, 24000], null),
      ('fade_in_500ms', const [AnimKey(0, 0), AnimKey(500000, 1)], [0, 1, 2, 12000, 23999, 24000, 30000], null),
      ('fade_out_music_40pct', const [AnimKey(3000000, 0.4), AnimKey(4000000, 0)], [143999, 144000, 168000, 191999, 192000], null),
      (
        'volume_keyframes',
        const [AnimKey(0, 1), AnimKey(1000000, 2), AnimKey(2000000, 2), AnimKey(3000000, 0), AnimKey(4000000, 0.5), AnimKey(9966667, 1)],
        [0, 24000, 48000, 72000, 96000, 120000, 144000, 168000, 192000, 300000, 478400, 480000],
        null,
      ),
      (
        'equal_power_out_400ms',
        [const AnimKey(0, 1), ...curve(1800000, 20, AudioMath.equalPowerOut)],
        [86400, 86401, 86880, 87360, 90000, 96000, 100000, 105600, 105601],
        (t) => t <= 1800000 ? 1 : (t >= 2200000 ? 0 : AudioMath.equalPowerOut((t - 1800000) / 400000)),
      ),
      (
        'equal_power_in_400ms',
        curve(1800000, 20, AudioMath.equalPowerIn),
        [86400, 86401, 86880, 87360, 90000, 96000, 100000, 105600, 105601],
        (t) => t <= 1800000 ? 0 : (t >= 2200000 ? 1 : AudioMath.equalPowerIn((t - 1800000) / 400000)),
      ),
    ];
    return {
      ..._header(
        'ARCH §11.6 Audio row, §11.7 (fades, crossfades), D-37',
        'gain(t) is linear between [tUs, g] keys and held outside; output sample i (from timeline 0) is at t = i·10^6/48000 µs (exact, no ε). '
            'db = 20·log10(g). Equal-power crossfades are lowered as cos/sin(π·x/2) sampled every 20 ms; `ideal` is the curve and `errDb` '
            'the sampling error (ARCH §11.7: ≤ 0.1 dB).',
      ),
      'sampleRate': AudioMath.sampleRate,
      'envelopes': [
        for (final (name, keys, samples, ideal) in envelopes)
          {
            'name': name,
            ..._keys(keys),
            'samples': [
              for (final i in samples)
                () {
                  final t = AudioMath.sampleTimeUs(0, i);
                  final g = AudioMath.gainAt(keys, t);
                  final id = ideal?.call(t);
                  return {
                    'i': i,
                    'tUs': r9(t),
                    'g': r9(g),
                    'db': g > 0 ? r9(AudioMath.gainToDb(g)) : null,
                    if (id != null) 'ideal': r9(id),
                    if (id != null && id > 0.05) 'errDb': r9(AudioMath.gainToDb(g) - AudioMath.gainToDb(id)),
                  };
                }(),
            ],
          },
      ],
      'db': [
        for (final g in const [2.0, 1.0, 0.5, 0.4, 0.3, 0.1, 0.001]) {'g': g, 'db': r9(AudioMath.gainToDb(g))},
      ],
    };
  }

  // ---------------------------------------------------------------------------------------------
  // audio_mix.json
  // ---------------------------------------------------------------------------------------------

  static const double _minus12dBFS = 0.251188643150958;

  static Map<String, Object?> _tonesJson(ToneAudio a) => {
        'type': 'tones',
        'durUs': a.durUs,
        'channels': [
          for (final t in a.tones) t == null ? null : {'freqHz': t.freqHz, 'amplitude': r9(t.amplitude), 'phase': t.phase},
        ],
      };

  static PlanAsset _audioAsset(String uri, int dur) =>
      PlanAsset(kind: PlanAssetKind.audio, uri: uri, fp: SyntheticSources.fnv1a(uri).toRadixString(16), durUs: dur);

  static PlanAsset _videoAsset(String uri, int dur) =>
      PlanAsset(kind: PlanAssetKind.video, uri: uri, fp: 'api03', w: 1280, h: 720, durUs: dur, hasAudio: true);

  /// The three-lane reference project of QA-11 and four analytic cases, mixed by
  /// [ReferenceAudioMixer] and measured per 20 ms window (ARCH §11.6 Audio row, §21.1).
  static Map<String, Object?> audioMix() {
    const canvas = PlanCanvas(w: 1280, h: 720, fps: 30);
    final cases = <Map<String, Object?>>[];
    void add(String name, String description, RenderPlan plan, Map<String, ToneAudio> sources,
        {List<Map<String, Object?>> omitted = const [], List<int> spot = const []}) {
      final mixer = ReferenceAudioMixer(sources: MapReferenceSources(audios: sources));
      final pcm = mixer.mix(plan, 0, plan.durUs);
      final windows = ReferenceAudioMixer.windows(pcm);
      cases.add({
        'name': name,
        'description': description,
        'plan': PlanJson.encodePlan(plan),
        'sources': {for (final e in sources.entries) e.key: _tonesJson(e.value)},
        if (omitted.isNotEmpty) 'omitted': omitted,
        'startUs': 0,
        'endUs': plan.durUs,
        'frames': pcm.length ~/ 2,
        'windowSamples': AudioMath.windowSamples,
        'windows': [
          for (final w in windows) _l([w.rmsDbL, w.rmsDbR, w.peakL, w.peakR]),
        ],
        'samples': [
          for (final i in spot) {'i': i, 'l': r9(pcm[2 * i]), 'r': r9(pcm[2 * i + 1])},
        ],
      });
    }

    // 1. Three audible lanes: main video lane (clips A and B with a 400 ms cross dissolve), music
    //    at 40 % with 1 s fades, voice with volume keyframes up to 200 %. Lowered: the muted lane and
    //    the soloed-out lane are absent from the plan (ARCH §11.7).
    const dissolveFrom = 1800000;
    final crossOut = [
      const AnimKey(0, 1),
      for (var j = 0; j <= 20; j++) AnimKey(dissolveFrom + j * 20000, AudioMath.equalPowerOut(j / 20))
    ];
    final crossIn = [for (var j = 0; j <= 20; j++) AnimKey(dissolveFrom + j * 20000, AudioMath.equalPowerIn(j / 20))];
    final threeLane = RenderPlan(
      rev: 1,
      target: PlanTarget.export,
      canvas: canvas,
      durUs: 4000000,
      assets: {
        'md_mainA0000001': _videoAsset('file:///fixtures/api03_main_a_1khz.mp4', 10000000),
        'md_mainB0000001': _videoAsset('file:///fixtures/api03_main_b_440hz.mp4', 10000000),
        'md_music0000001': _audioAsset('file:///fixtures/api03_music_220_330.m4a', 60000000),
        'md_voice0000001': _audioAsset('file:///fixtures/api03_voice_700.wav', 10000000),
      },
      layers: [
        PlanLayer(
          id: 'it_mainA000001#v',
          z: 10,
          seq: 0,
          t0: 0,
          t1: 2200000,
          kind: PlanLayerKind.media,
          asset: 'md_mainA0000001',
          map: const [MapSegment(0, 2200000, 0, 2200000)],
          base: const PlanSize(1280, 720),
        ),
        PlanLayer(
          id: 'it_mainB000001#v',
          z: 10,
          seq: 1,
          t0: 1800000,
          t1: 4000000,
          kind: PlanLayerKind.media,
          asset: 'md_mainB0000001',
          map: const [MapSegment(1800000, 4000000, 1000000, 3200000)],
          base: const PlanSize(1280, 720),
          anim: const {
            'xf.op': [AnimKey(1800000, 0), AnimKey(2200000, 1)],
          },
        ),
      ],
      audio: [
        AudioSeg(
            id: 'it_mainA000001#a',
            asset: 'md_mainA0000001',
            t0: 0,
            t1: 2200000,
            map: const [MapSegment(0, 2200000, 0, 2200000)],
            gain: crossOut),
        AudioSeg(
          id: 'it_music000001#a',
          asset: 'md_music0000001',
          t0: 0,
          t1: 4000000,
          map: const [MapSegment(0, 4000000, 5000000, 9000000)],
          gain: const [AnimKey(0, 0), AnimKey(1000000, 0.4), AnimKey(3000000, 0.4), AnimKey(4000000, 0)],
        ),
        AudioSeg(
          id: 'it_voice000001#a',
          asset: 'md_voice0000001',
          t0: 500000,
          t1: 3500000,
          map: const [MapSegment(500000, 3500000, 0, 3000000)],
          gain: const [AnimKey(500000, 1), AnimKey(1500000, 2), AnimKey(2500000, 0.5), AnimKey(3500000, 1)],
        ),
        AudioSeg(
          id: 'it_mainB000001#a',
          asset: 'md_mainB0000001',
          t0: 1800000,
          t1: 4000000,
          map: const [MapSegment(1800000, 4000000, 1000000, 3200000)],
          gain: crossIn,
        ),
      ]..sort((a, b) => a.t0 != b.t0 ? a.t0.compareTo(b.t0) : a.id.compareTo(b.id)),
    );
    add(
      'three_lane_reference',
      'QA-11 (b): main lane A→B with a 400 ms cross dissolve (equal-power audio), music at 40 % with 1 s fade in and out, voice with '
          'volume keyframes 100 → 200 → 50 → 100 %; the muted lane and the soloed-out lane are omitted by lowering and must stay below −60 dBFS.',
      threeLane,
      {
        'md_mainA0000001': const ToneAudio([Tone(1000, _minus12dBFS)]),
        'md_mainB0000001': const ToneAudio([Tone(440, _minus12dBFS)]),
        'md_music0000001': const ToneAudio([Tone(220, 0.5), Tone(330, 0.5)]),
        'md_voice0000001': const ToneAudio([Tone(700, 0.2)], durUs: 10000000),
      },
      omitted: [
        {
          'lane': 'A3',
          'flag': 'muted',
          'asset': 'md_sfx00000001',
          'source': _tonesJson(const ToneAudio([Tone(3000, 0.5)])),
        },
        {
          'lane': 'A4',
          'flag': 'soloedOut',
          'asset': 'md_amb00000001',
          'source': _tonesJson(const ToneAudio([Tone(5000, 0.5), Tone(5000, 0.5)])),
        },
      ],
      spot: [0, 1, 24000, 48000, 72000, 86400, 96000, 105600, 120000, 144000, 168000, 191999],
    );

    // 2. Hard clip: a 0.75 tone at 200 %.
    add(
      'hard_clip',
      'A 1 kHz tone of peak 0.75 at gain 2.0: the sum is hard-clipped to [−1, 1] (no limiter).',
      RenderPlan(
        rev: 1,
        target: PlanTarget.export,
        canvas: canvas,
        durUs: 200000,
        assets: {'md_tone0000001': _audioAsset('file:///fixtures/api03_tone_1k.wav', 1000000)},
        audio: [
          AudioSeg(
              id: 'it_tone0000001#a',
              asset: 'md_tone0000001',
              t0: 0,
              t1: 200000,
              map: const [MapSegment(0, 200000, 0, 200000)],
              gain: const [AnimKey(0, 2)]),
        ],
      ),
      {
        'md_tone0000001': const ToneAudio([Tone(1000, 0.75)])
      },
      spot: [0, 12, 24, 36, 48],
    );

    // 3. 5.1 downmix: centre-only tone plus an LFE tone (dropped).
    add(
      'downmix_5_1',
      '6 channels L R C LFE Ls Rs: 1 kHz on C at 0.5 → L = R = 0.5·0.7071; the 100 Hz LFE is dropped.',
      RenderPlan(
        rev: 1,
        target: PlanTarget.export,
        canvas: canvas,
        durUs: 200000,
        assets: {'md_surround00001': _audioAsset('file:///fixtures/api03_surround_5_1.m4a', 1000000)},
        audio: [
          AudioSeg(
              id: 'it_surround0001#a',
              asset: 'md_surround00001',
              t0: 0,
              t1: 200000,
              map: const [MapSegment(0, 200000, 0, 200000)],
              gain: const [AnimKey(0, 1)]),
        ],
      ),
      {
        'md_surround00001': const ToneAudio([null, null, Tone(1000, 0.5), Tone(100, 0.5), null, null]),
      },
      spot: [0, 12, 24],
    );

    // 4. Varispeed: a 500 Hz tone played at 2× without pitch keeping sounds at 1 kHz.
    add(
      'varispeed_2x',
      'A 500 Hz mono tone on a 2× map with pitch: false is exactly a 1 kHz tone (mono duplicated to both channels).',
      RenderPlan(
        rev: 1,
        target: PlanTarget.export,
        canvas: canvas,
        durUs: 200000,
        assets: {'md_tone0000500': _audioAsset('file:///fixtures/api03_tone_500.wav', 1000000)},
        audio: [
          AudioSeg(
            id: 'it_fast0000001#a',
            asset: 'md_tone0000500',
            t0: 0,
            t1: 200000,
            map: const [MapSegment(0, 200000, 0, 400000)],
            gain: const [AnimKey(0, 1)],
            pitch: false,
          ),
        ],
      ),
      {
        'md_tone0000500': const ToneAudio([Tone(500, 0.5)])
      },
      spot: [0, 12, 24, 36, 48],
    );
    return {
      ..._header(
        'ARCH §11.6 Audio row, §21.1 (QA-11), D-37, D-38',
        'Interleaved stereo at 48 kHz for [startUs, endUs): sample i at t = startUs + i·10^6/48000; each segment with t0 ≤ t < t1 reads its '
            'source at s = s0 + (t − t0)·(s1 − s0)/(t1 − t0) (varispeed, no pitch processing), downmixes (mono duplicated, ITU −3 dB '
            'for C and surrounds, LFE dropped), multiplies by gain(t), sums and hard-clips. windows: per 20 ms window '
            '[rmsDbL, rmsDbR, peakL, peakR] with dB = 20·log10(RMS) floored at −120. Sources are analytic: tones amplitude·sin(2π·f·s/10^6 + phase) '
            'per channel, zero outside [0, durUs).',
      ),
      'cases': cases,
    };
  }

  // ---------------------------------------------------------------------------------------------
  // typewriter.json
  // ---------------------------------------------------------------------------------------------

  /// Typewriter reveal: the plan's `reveal` channel and the glyphs shown per output frame (ARCH
  /// §11.2, §11.6 Sprite, §11.7).
  static Map<String, Object?> typewriter() {
    final cases = <Map<String, Object?>>[];
    void add(String name, String text, int fps, int startFrame, int frames, int inFrames, List<int> sampleFrames) {
      final rate = FrameRate(fps, 1);
      final start = rate.timeOfFrame(startFrame);
      final end = rate.timeOfFrame(startFrame + frames);
      final inEnd = rate.timeOfFrame(startFrame + inFrames);
      final n = textGraphemeCount(text);
      final channel = [AnimKey(start, 0), AnimKey(inEnd, n.toDouble())];
      cases.add({
        'name': name,
        'text': text,
        'graphemes': n,
        'fps': fps,
        'itemStartUs': start,
        'itemDurationUs': end - start,
        'inDurationUs': inEnd - start,
        'channel': _keys(channel)['keys'],
        'frames': [
          for (final k in sampleFrames)
            () {
              final t = rate.timeOfFrame(k);
              final v = evaluateAnimKeys(channel, t);
              return {'k': k, 't': t, 'reveal': r9(v), 'shown': RenderMath.revealCount(v)};
            }(),
        ],
      });
    }

    add('hello_world_30fps', 'Hello, world', 30, 30, 90, 30, [30, 31, 32, 33, 45, 59, 60, 61, 119]);
    add('graphemes_24fps', 'héllo 👋🏽 世界!', 24, 0, 72, 20, [0, 1, 2, 5, 10, 19, 20, 50]);
    add('long_60fps_short_in', 'Typewriter at sixty frames', 60, 120, 240, 45, [120, 121, 122, 140, 164, 165, 166, 359]);
    return {
      ..._header(
        'ARCH §11.2 (reveal), §11.6 Sprite, §11.7, D-06',
        'The compiler emits reveal = [[itemStartUs, 0], [itemStartUs + inDurationUs, graphemes]] (linear, held after); output frame k is '
            'evaluated at t = timeOfFrame(k); shown = floor(reveal(t)); a sprite texel of glyph g is drawn iff g < shown (0xFFFF never while '
            'reveal is animated). Core evaluateTextAnimation(...).revealCount equals `shown`.',
      ),
      'cases': cases,
    };
  }

  // ---------------------------------------------------------------------------------------------
  // text_scale_8x.json
  // ---------------------------------------------------------------------------------------------

  /// The 8× scale-keyframed text parity case: per golden frame the evaluated `xf.s`/`xf.r`, M,
  /// the sprite texels per output px and the golden PNG (ARCH §10.3, §11.6 Sprite).
  static Map<String, Object?> textScale8x() {
    final g = GoldenCases.all.firstWhere((c) => c.name == 'api03_text_scale_8x');
    final plan = g.plan!;
    final layer = plan.layers.firstWhere((l) => l.kind == PlanLayerKind.sprite);
    final asset = plan.assets[layer.asset]!;
    final renderer = ReferenceRenderer(longSide: g.longSide);
    final (ow, oh) = renderer.outputSizeOf(plan.canvas);
    final k = ow / plan.canvas.w;
    final rate = plan.canvas.frameRate;
    return {
      ..._header(
        'ARCH §10.3 (raster scale), §11.6 Sprite and Place, BUILD_PLAN API-03',
        'A sprite rasterized at sscale = 8 (sw × sh = 8·base) is drawn with M at every scale up to 8×; the golden PNGs are the reference '
            'renderer at the listed size. texelsPerOutputPx = sw / (base.w·s·renderScale) (> 1: minified, box-filtered).',
      ),
      'plan': '../images/plans/${g.name}.json',
      'layer': layer.id,
      'sprite': {'sw': asset.sw, 'sh': asset.sh, 'sscale': asset.sscale},
      'output': [ow, oh],
      'renderScale': r9(k),
      'frames': [
        for (final f in g.frames)
          () {
            final t = rate.timeOfFrame(f);
            final p = LayerParamSnapshot.at(layer, plan.canvas, t);
            final m = RenderMath.placement(p.xf, layer.base!, plan.canvas);
            return {
              'k': f,
              't': t,
              'xf.s': r9(p.xf.s),
              'xf.r': r9(p.xf.r),
              'M': _l([m.a, m.b, m.c, m.d, m.tx, m.ty]),
              'texelsPerOutputPx': r9(asset.sw! / (layer.base!.w * p.xf.s * k)),
              'png': '../images/${g.pngPath(f)}',
            };
          }(),
      ],
    };
  }

  /// Largest absolute difference between two equal-length lists (test helper for the vectors).
  static double maxAbsDiff(List<num> a, List<num> b) {
    var m = 0.0;
    for (var i = 0; i < a.length; i++) {
      m = math.max(m, (a[i] - b[i]).abs().toDouble());
    }
    return m;
  }
}
