// OWNER: API-03
//
// The golden corpus of the Dart reference renderer (ARCH §11.6, §21.1 "Reference renderer
// goldens"): every valid plan of the CORE-29 contract corpus plus API-03's own plans for the
// stages the corpus does not isolate (grade + LUT, detail, masks, chroma spill, placement, canvas
// masks, typewriter reveal and the 8× scale-keyframed text parity case), each at a few output
// frames. `tool/regen_goldens.dart` copies or encodes the plans to `test_fixtures/images/plans/`,
// renders the PNGs and writes `test_fixtures/images/goldens.json`.

import 'package:danaview_editor_core/model.dart' show TimeUs;
import 'package:danaview_editor_core/plan.dart';

/// One golden plan and the output frames rendered from it (ARCH §11.6, API-03).
final class GoldenCase {
  /// Creates a case. Exactly one of [contractFile] and [plan] is set.
  const GoldenCase({required this.name, required this.frames, this.contractFile, this.plan, this.longSide = 96})
      : assert((contractFile == null) != (plan == null));

  /// File name (and golden prefix) under `test_fixtures/images/plans/`, without `.json`.
  final String name;

  /// File name inside `danaview_editor_core/test/fixtures/render_plans/contract/`, for corpus plans.
  final String? contractFile;

  /// The plan, for API-03's own cases.
  final RenderPlan? plan;

  /// Output frame indices `k` (plan time `timeOfFrame(k)` of `canvas.fps`).
  final List<int> frames;

  /// Long side of the rendered PNG in px.
  final int longSide;

  /// The PNG path of frame [k] relative to `test_fixtures/images/`.
  String pngPath(int k) => 'goldens/${name}_f${k.toString().padLeft(4, '0')}.png';
}

/// The golden corpus (ARCH §11.6, API-03).
abstract final class GoldenCases {
  /// Every case, in manifest order.
  static final List<GoldenCase> all = List.unmodifiable([
    ..._contract,
    GoldenCase(name: 'api03_text_scale_8x', plan: textScale8x(), frames: const [0, 15, 30, 45, 54], longSide: 192),
    GoldenCase(name: 'api03_typewriter', plan: typewriter(), frames: const [0, 4, 12, 21, 30, 45], longSide: 128),
    GoldenCase(name: 'api03_grade_lut', plan: gradeLut(), frames: const [0, 30], longSide: 128),
    GoldenCase(name: 'api03_detail', plan: detail(), frames: const [0], longSide: 160),
    GoldenCase(name: 'api03_masks', plan: masks(), frames: const [0, 15, 30], longSide: 128),
    GoldenCase(name: 'api03_chroma_spill', plan: chroma(), frames: const [0, 10], longSide: 128),
    GoldenCase(name: 'api03_place', plan: place(), frames: const [0, 20, 40], longSide: 128),
    GoldenCase(name: 'api03_canvas_masks', plan: canvasMasks(), frames: const [0, 15, 29], longSide: 128),
  ]);

  static const List<GoldenCase> _contract = [
    GoldenCase(name: 'minimal_preview', contractFile: 'minimal_preview.json', frames: [0, 45, 89]),
    GoldenCase(name: 'no_audio_export', contractFile: 'no_audio_export.json', frames: [0, 60, 70]),
    GoldenCase(name: 'export_24_from_30', contractFile: 'export_24_from_30.json', frames: [0, 10, 20, 40]),
    GoldenCase(name: 'export_48_from_24', contractFile: 'export_48_from_24.json', frames: [0, 47, 48, 90]),
    GoldenCase(name: 'grid_cuts_30fps', contractFile: 'grid_cuts_30fps.json', frames: [30, 31, 32, 61, 62]),
    GoldenCase(name: 'speed_ramp_multi_segment', contractFile: 'speed_ramp_multi_segment.json', frames: [0, 30, 59]),
    GoldenCase(name: 'reversed_rendition', contractFile: 'reversed_rendition.json', frames: [0, 45]),
    GoldenCase(name: 'hold_pending_still', contractFile: 'hold_pending_still.json', frames: [15, 30, 90]),
    GoldenCase(name: 'offline_placeholder', contractFile: 'offline_placeholder.json', frames: [0, 30]),
    GoldenCase(name: 'transition_cross_dissolve', contractFile: 'transition_cross_dissolve.json', frames: [50, 54, 60, 66]),
    GoldenCase(name: 'transition_fade', contractFile: 'transition_fade.json', frames: [54, 58, 60, 63]),
    GoldenCase(name: 'transition_dip_to_white', contractFile: 'transition_dip_to_white.json', frames: [54, 58, 60, 63]),
    GoldenCase(name: 'transition_slide', contractFile: 'transition_slide.json', frames: [54, 60, 65]),
    GoldenCase(name: 'transition_wipe', contractFile: 'transition_wipe.json', frames: [54, 60, 65]),
    GoldenCase(name: 'transition_wipe_down_inverted', contractFile: 'transition_wipe_down_inverted.json', frames: [54, 60, 65]),
    GoldenCase(name: 'transition_zoom', contractFile: 'transition_zoom.json', frames: [54, 60, 65]),
    GoldenCase(name: 'effects_every_static_key', contractFile: 'effects_every_static_key.json', frames: [0, 15, 45, 75]),
    GoldenCase(name: 'anim_every_channel', contractFile: 'anim_every_channel.json', frames: [0, 15, 45, 75]),
    GoldenCase(name: 'sprites_export_reveal', contractFile: 'sprites_export_reveal.json', frames: [15, 25, 35, 45, 60]),
    GoldenCase(name: 'audio_gain_envelopes', contractFile: 'audio_gain_envelopes.json', frames: [0]),
    GoldenCase(name: 'backdrop_blur_portrait', contractFile: 'backdrop_blur_portrait.json', frames: [0, 45]),
    GoldenCase(name: 'image_solid_layers', contractFile: 'image_solid_layers.json', frames: [15, 45, 105]),
    GoldenCase(name: 'overlay_pip_chroma_mask', contractFile: 'overlay_pip_chroma_mask.json', frames: [0, 30, 60]),
    GoldenCase(name: 'uhd_60fps', contractFile: 'uhd_60fps.json', frames: [0, 60]),
    GoldenCase(name: 'empty_plan', contractFile: 'empty_plan.json', frames: [0]),
  ];

  // ---------------------------------------------------------------------------------------------
  // API-03's own plans.
  // ---------------------------------------------------------------------------------------------

  static const PlanCanvas _canvas = PlanCanvas(w: 1280, h: 720, fps: 30);

  static const PlanAsset _videoA = PlanAsset(
    kind: PlanAssetKind.video,
    uri: 'file:///fixtures/frame_counter_1080p30.mp4',
    fp: 'api03va',
    w: 1920,
    h: 1080,
    durUs: 8000000,
    hasAudio: true,
  );

  static const PlanAsset _videoB = PlanAsset(
    kind: PlanAssetKind.video,
    uri: 'file:///fixtures/frame_counter_720p25.mp4',
    fp: 'api03vb',
    w: 1280,
    h: 720,
    durUs: 8000000,
    hasAudio: true,
  );

  static const PlanAsset _image =
      PlanAsset(kind: PlanAssetKind.image, uri: 'file:///fixtures/still_4k.jpg', fp: 'api03im', w: 3840, h: 2160);

  static PlanLayer _media(String id, int z, int seq, String asset, TimeUs dur, PlanSize base,
          {PlanTransform xf = PlanTransform.identity, PlanEffects fx = PlanEffects.none, List<CanvasMask> cmasks = const []}) =>
      PlanLayer(
        id: id,
        z: z,
        seq: seq,
        t0: 0,
        t1: dur,
        kind: PlanLayerKind.media,
        asset: asset,
        map: [MapSegment(0, dur, 0, dur)],
        base: base,
        xf: xf,
        fx: fx,
        cmasks: cmasks,
      );

  static PlanLayer _solid(String id, int z, TimeUs dur, int argb) =>
      PlanLayer(id: id, z: z, t0: 0, t1: dur, kind: PlanLayerKind.solid, color: argb);

  /// The 8× scale-keyframed text parity case (ARCH §10.3 raster scale, BUILD_PLAN API-03): a sprite
  /// rasterized at `sscale = 8` (`base` 120 × 24, sprite 960 × 192) whose `xf.s` goes 1 → 8 and
  /// `xf.r` 0 → 10° over 1.5 s above a video.
  static RenderPlan textScale8x() => RenderPlan(
        rev: 1,
        target: PlanTarget.export,
        canvas: _canvas,
        durUs: 2000000,
        assets: const {
          'md_bg0000000001': _videoA,
          'sp_scale8x00001': PlanAsset(
            kind: PlanAssetKind.sprite,
            uri: 'file:///cache/danaview/editor/sprites/api03_scale8x.vsprite',
            sw: 960,
            sh: 192,
            sscale: 8,
          ),
        },
        layers: [
          _media('it_bg0000000001#v', 10, 0, 'md_bg0000000001', 2000000, const PlanSize(1280, 720)),
          PlanLayer(
            id: 'it_title000001#v',
            z: 20010,
            t0: 0,
            t1: 2000000,
            kind: PlanLayerKind.sprite,
            asset: 'sp_scale8x00001',
            base: const PlanSize(120, 24),
            xf: const PlanTransform(cx: 640, cy: 360),
            anim: const {
              'xf.s': [AnimKey(0, 1), AnimKey(1500000, 8)],
              'xf.r': [AnimKey(0, 0), AnimKey(1500000, 10)],
            },
          ),
        ],
      );

  /// Typewriter: one sprite with a glyph-order map and a `reveal` channel 0 → 10 over 1 s
  /// (ARCH §11.6 Sprite, §11.7).
  static RenderPlan typewriter() => RenderPlan(
        rev: 1,
        target: PlanTarget.export,
        canvas: _canvas,
        durUs: 2000000,
        assets: const {
          'sp_typewriter01': PlanAsset(
            kind: PlanAssetKind.sprite,
            uri: 'file:///cache/danaview/editor/sprites/api03_typewriter.vsprite',
            sw: 1100,
            sh: 160,
            sscale: 1,
            reveal: true,
          ),
        },
        layers: [
          _solid('it_bg0000000001#v', 10, 2000000, 0xFF203040),
          PlanLayer(
            id: 'it_typing000001#v',
            z: 20010,
            t0: 0,
            t1: 2000000,
            kind: PlanLayerKind.sprite,
            asset: 'sp_typewriter01',
            base: const PlanSize(1100, 160),
            xf: const PlanTransform(cx: 640, cy: 360),
            anim: const {
              'reveal': [AnimKey(0, 0), AnimKey(1000000, 10)],
            },
          ),
        ],
      );

  /// Every colour adjustment on an image (left) and a 17³ LUT at 60 % with desaturation on a video
  /// (right).
  static RenderPlan gradeLut() => RenderPlan(
        rev: 1,
        target: PlanTarget.preview,
        canvas: _canvas,
        durUs: 2000000,
        assets: const {
          'im_still0000001': _image,
          'lt_api03000017': PlanAsset(kind: PlanAssetKind.lut, uri: 'file:///cache/danaview/editor/looks/api03_17.vlut', n: 17),
          'md_clipA0000001': _videoA,
        },
        layers: [
          PlanLayer(
            id: 'it_still000001#v',
            z: 10,
            t0: 0,
            t1: 2000000,
            kind: PlanLayerKind.image,
            asset: 'im_still0000001',
            base: const PlanSize(640, 360),
            xf: const PlanTransform(cx: 320, cy: 360),
            fx: const PlanEffects(
              adj: PlanAdjust(
                exposure: 0.3,
                brightness: -0.1,
                contrast: 0.25,
                highlights: -0.3,
                shadows: 0.3,
                saturation: 0.4,
                temperature: 0.5,
                tint: -0.3,
              ),
            ),
          ),
          _media(
            'it_clipA000001#v',
            10010,
            0,
            'md_clipA0000001',
            2000000,
            const PlanSize(640, 360),
            xf: const PlanTransform(cx: 960, cy: 360),
            fx: const PlanEffects(adj: PlanAdjust(saturation: -0.5), lut: PlanLut('lt_api03000017', 0.6)),
          ),
        ],
      );

  /// Blur, sharpen, vignette and all three together on four videos over grey.
  static RenderPlan detail() => RenderPlan(
        rev: 1,
        target: PlanTarget.preview,
        canvas: _canvas,
        durUs: 1000000,
        assets: const {'md_clipA0000001': _videoA},
        layers: [
          _solid('it_grey00000001#v', 10, 1000000, 0xFF808080),
          for (final (i, (cx, cy, d)) in const [
            (220.0, 200.0, PlanDetail(blur: 0.4)),
            (640.0, 200.0, PlanDetail(sharpen: 1)),
            (1060.0, 200.0, PlanDetail(vignette: 0.9)),
            (640.0, 540.0, PlanDetail(blur: 0.1, sharpen: 0.5, vignette: 0.5)),
          ].indexed)
            _media(
              'it_detail00000$i#v',
              10010 + 10 * i,
              i,
              'md_clipA0000001',
              1000000,
              const PlanSize(400, 225),
              xf: PlanTransform(cx: cx, cy: cy),
              fx: PlanEffects(detail: d),
            ),
        ],
      );

  /// Rounded, rotated, feathered, inverted, translucent and animated item masks on four images.
  static RenderPlan masks() => RenderPlan(
        rev: 1,
        target: PlanTarget.preview,
        canvas: _canvas,
        durUs: 2000000,
        assets: const {'im_still0000001': _image},
        layers: [
          _solid('it_dark00000001#v', 10, 2000000, 0xFF1E1E1E),
          for (final (i, (cx, cy, m, anim)) in <(double, double, PlanMask, Map<String, List<AnimKey>>)>[
            (320, 180, const PlanMask(shape: PlanMaskShape.rect, w: 0.7, h: 0.6, r: 30, corner: 0.25, feather: 0.2), const {}),
            (960, 180, const PlanMask(shape: PlanMaskShape.ellipse, w: 0.8, h: 0.9, feather: 0.1, inv: true), const {}),
            (320, 540, const PlanMask(shape: PlanMaskShape.rect, w: 0.5, h: 0.5, op: 0.5), const {}),
            (
              960,
              540,
              const PlanMask(shape: PlanMaskShape.ellipse, w: 0.5, h: 0.5, feather: 1),
              const {
                'mask.cx': [AnimKey(0, 0.25), AnimKey(1000000, 0.75)],
              },
            ),
          ].indexed)
            PlanLayer(
              id: 'it_mask0000000$i#v',
              z: 10010 + 10 * i,
              t0: 0,
              t1: 2000000,
              kind: PlanLayerKind.image,
              asset: 'im_still0000001',
              base: const PlanSize(560, 315),
              xf: PlanTransform(cx: cx, cy: cy),
              fx: PlanEffects(mask: m),
              anim: anim,
            ),
        ],
      );

  /// Green-key with strong spill over a magenta solid, and a blue-key picture-in-picture.
  static RenderPlan chroma() => RenderPlan(
        rev: 1,
        target: PlanTarget.preview,
        canvas: _canvas,
        durUs: 1000000,
        assets: const {'md_clipA0000001': _videoA, 'md_clipB0000001': _videoB},
        layers: [
          _solid('it_magenta00001#v', 10, 1000000, 0xFFC03070),
          _media(
            'it_green0000001#v',
            10010,
            0,
            'md_clipA0000001',
            1000000,
            const PlanSize(1280, 720),
            fx: const PlanEffects(chroma: PlanChroma(key: 0x00B140, sim: 0.3, smooth: 0.1, spill: 0.8)),
          ),
          _media(
            'it_blue00000001#v',
            10020,
            1,
            'md_clipB0000001',
            1000000,
            const PlanSize(640, 360),
            xf: const PlanTransform(cx: 960, cy: 540),
            fx: const PlanEffects(chroma: PlanChroma(key: 0x0000FF, sim: 0.2, smooth: 0.3, spill: 0.5)),
          ),
        ],
      );

  /// Rotations (90°, −30°, 180°, animated), flips, scales and opacity on four images.
  static RenderPlan place() => RenderPlan(
        rev: 1,
        target: PlanTarget.preview,
        canvas: _canvas,
        durUs: 2000000,
        assets: const {'im_still0000001': _image},
        layers: [
          _solid('it_navy00000001#v', 10, 2000000, 0xFF102030),
          for (final (i, (xf, anim)) in <(PlanTransform, Map<String, List<AnimKey>>)>[
            (const PlanTransform(cx: 300, cy: 200, s: 0.8, r: 90, fx: true), const {}),
            (const PlanTransform(cx: 900, cy: 200, s: 0.6, r: -30, fy: true), const {}),
            (const PlanTransform(cx: 300, cy: 520, r: 180, fx: true, fy: true, op: 0.6), const {}),
            (
              const PlanTransform(cx: 900, cy: 520),
              const {
                'xf.r': [AnimKey(0, 0), AnimKey(1333333, 360)],
                'xf.s': [AnimKey(0, 0.5), AnimKey(2000000, 1.2)],
              },
            ),
          ].indexed)
            PlanLayer(
              id: 'it_place000000$i#v',
              z: 10010 + 10 * i,
              t0: 0,
              t1: 2000000,
              kind: PlanLayerKind.image,
              asset: 'im_still0000001',
              base: const PlanSize(400, 225),
              xf: xf,
              anim: anim,
            ),
        ],
      );

  /// A rotated, feathered canvas mask and an inverted, animated one (wipe-like).
  static RenderPlan canvasMasks() => RenderPlan(
        rev: 1,
        target: PlanTarget.preview,
        canvas: _canvas,
        durUs: 1000000,
        assets: const {'md_clipA0000001': _videoA, 'md_clipB0000001': _videoB},
        layers: [
          _media('it_under0000001#v', 10, 0, 'md_clipA0000001', 1000000, const PlanSize(1280, 720)),
          _media(
            'it_cmask000001#v',
            10010,
            1,
            'md_clipB0000001',
            1000000,
            const PlanSize(1280, 720),
            cmasks: const [CanvasMask(cx: 640, cy: 360, w: 700, h: 400, r: 20, feather: 30)],
          ),
          _media(
            'it_cmask000002#v',
            10020,
            2,
            'md_clipA0000001',
            1000000,
            const PlanSize(640, 360),
            xf: const PlanTransform(cx: 640, cy: 360, s: 0.9),
            cmasks: const [
              CanvasMask(
                cx: 640,
                cy: 360,
                w: 0,
                h: 720,
                feather: 15,
                inv: true,
                anim: {
                  'w': [AnimKey(0, 0), AnimKey(966667, 1280)],
                },
              ),
            ],
          ),
        ],
      );
}
