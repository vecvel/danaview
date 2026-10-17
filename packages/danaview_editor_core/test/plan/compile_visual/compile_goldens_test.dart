// OWNER: CORE-30
//
// One compile golden per visual lowering row of ARCH §11.7 (transitions, text and audio rows are
// CORE-31's). Each case pins `compile(project) == goldens/<name>.json` byte for byte (canonical
// JSON), checks the row's lowering explicitly (so a golden can't silently encode a wrong value),
// validates the plan with CORE-29's PlanValidator, and compares the compiled media layers with
// the packing inputs CORE-36 derives from the model (and their `seq` with the packing's slots).
//
// Regenerate after an intended change with `DANAVIEW_UPDATE_GOLDENS=1 dart test <this file>` and
// review the diff.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import 'support.dart';

/// One golden: a project, how it is compiled, and row-specific checks.
final class GoldenCase {
  GoldenCase(
    this.name,
    this.project, {
    this.target = PlanTarget.preview,
    this.options = const CompileOptions(),
    MapPlanAssetResolver Function(EditProject p)? resolverOf,
    this.packingExclusions = const {},
    required this.check,
  }) : resolver = (resolverOf ?? resolverFor)(project);

  final String name;
  final EditProject project;
  final PlanTarget target;
  final CompileOptions options;
  final MapPlanAssetResolver resolver;

  /// Model-derived packing inputs the plan legitimately lacks (media the resolver reports offline:
  /// `LayerLimits` counts them conservatively, the compiler emits solids).
  final Set<String> packingExclusions;

  final void Function(CompiledPlan c, EditProject p) check;

  CompiledPlan compile() => compilePlan(project, target, resolver, options: options);
}

PlanLayer layer(RenderPlan p, String id) => p.layers.firstWhere((l) => l.id == id, orElse: () => fail('no layer $id'));

const ProjectSettings hd30 = ProjectSettings();
const ProjectSettings portrait30 = ProjectSettings(canvas: CanvasSpec(aspect: AspectRatio.portrait9x16));

final MediaAsset vA = asset('md_videoA00001', MediaKind.video);
final MediaAsset vB = asset('md_videoB00001', MediaKind.video, w: 1280, h: 720, duration: 20000000);
final MediaAsset vPortrait = asset('md_portrait001', MediaKind.video, w: 1080, h: 1920, rotation: 90);
final MediaAsset photo = asset('md_photo000001', MediaKind.image, w: 4000, h: 3000);

List<GoldenCase> cases() => [
      // Fit + crop → base via geometry.baseSize (ARCH §11.7 row "Fit + crop").
      GoldenCase(
        'fit_crop_base',
        project([
          mainLane([
            clip('it_fit00000001', 0, 30, 'md_portrait001'),
            clip('it_fill0000001', 30, 60, 'md_videoA00001',
                visual: const VisualProps(fit: FitMode.fill, crop: CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9))),
            clip('it_stretch0001', 60, 90, 'md_videoB00001',
                visual: const VisualProps(fit: FitMode.stretch, crop: CropRect(left: 0, top: 0.25, right: 1, bottom: 0.75))),
          ]),
          lane('tr_ov1', TrackKind.overlay, [
            clip('it_pipfit00001', 0, 90, 'md_photo000001', visual: const VisualProps(crop: CropRect(left: 0.25, top: 0, right: 0.75, bottom: 1))),
          ]),
        ], assets: [vA, vB, vPortrait, photo]),
        check: (c, project) {
          final p = c.plan;
          expect(layer(p, 'it_fit00000001#v').base, const PlanSize(607.5, 1080)); // 1080×1920 letterboxed in 1920×1080
          expect(layer(p, 'it_fill0000001#v').base, const PlanSize(1920, 1080)); // 1536×864 covers 1920×1080
          expect(layer(p, 'it_fill0000001#v').crop, const PlanCrop(0.1, 0.1, 0.9, 0.9));
          expect(layer(p, 'it_stretch0001#v').base, const PlanSize(1920, 1080));
          expect(layer(p, 'it_pipfit00001#v').base, const PlanSize(720, 1080)); // 2000×3000 crop fits by height
          expect(layer(p, 'it_pipfit00001#v').kind, PlanLayerKind.image);
          expect(p.assets['md_portrait001']!.rot, 90);
          expect(p.assets['md_portrait001']!.w, 1080);
        },
      ),

      // Transform, effects, bundled look, chroma, mask → xf / fx (+ a lut asset).
      GoldenCase(
        'transform_effects',
        project([
          mainLane([
            clip('it_fx000000001', 0, 60, 'md_videoA00001',
                visual: const VisualProps(
                  transform: Transform2D(position: Vec2(0.25, -0.1), scale: 0.5, rotationDeg: 30, flipH: true, flipV: true, opacity: 0.8),
                  adjust: ColorAdjust(exposure: 0.2, brightness: -0.1, contrast: 0.3, highlights: -0.2, shadows: 0.1, saturation: 0.5, temperature: -0.4, tint: 0.05),
                  detail: DetailFx(sharpness: 0.3, blur: 0.1, vignette: 0.4),
                  look: BuiltinLook('tealOrange', intensity: 0.65),
                  chroma: ChromaKey(enabled: true, color: 0x00B140, similarity: 0.45, smoothness: 0.12, spill: 0.35),
                  mask: MaskSpec(shape: MaskShape.rectangle, center: Vec2(0.5, 0.45), size: Vec2(0.7, 0.6), rotationDeg: 12, cornerRadius: 0.2, feather: 0.1, opacity: 0.9, invert: true),
                )),
            clip('it_lookgone001', 60, 90, 'md_videoA00001', visual: const VisualProps(look: BuiltinLook('unknownPreset'))),
          ]),
        ], assets: [vA]),
        check: (c, project) {
          final l = layer(c.plan, 'it_fx000000001#v');
          expect(l.xf, const PlanTransform(cx: 1440, cy: 432, s: 0.5, r: 30, fx: true, fy: true, op: 0.8));
          expect(l.fx.adj, const PlanAdjust(exposure: 0.2, brightness: -0.1, contrast: 0.3, highlights: -0.2, shadows: 0.1, saturation: 0.5, temperature: -0.4, tint: 0.05));
          expect(l.fx.detail, const PlanDetail(sharpen: 0.3, blur: 0.1, vignette: 0.4));
          expect(l.fx.lut, const PlanLut('lk_tealOrange', 0.65));
          expect(c.plan.assets['lk_tealOrange'], const PlanAsset(kind: PlanAssetKind.lut, uri: 'file:///app/assets/looks/tealOrange.vlut', n: 33));
          expect(l.fx.chroma, const PlanChroma(key: 0x00B140, sim: 0.45, smooth: 0.12, spill: 0.35));
          expect(l.fx.mask, const PlanMask(shape: PlanMaskShape.rect, cx: 0.5, cy: 0.45, w: 0.7, h: 0.6, r: 12, corner: 0.2, feather: 0.1, op: 0.9, inv: true));
          // An unknown bundled look is dropped (nothing to relink), not an offline requirement.
          expect(layer(c.plan, 'it_lookgone001#v').fx, PlanEffects.none);
          expect(c.requirements.isEmpty, isTrue);
        },
      ),

      // Imported LUT: a pool LUT asset → lut asset entry; an unavailable one is dropped and listed offline.
      GoldenCase(
        'look_imported_lut',
        project([
          mainLane([
            clip('it_lut00000001', 0, 30, 'md_videoA00001', visual: const VisualProps(look: ImportedLut(MediaId('md_lutteal0001'), intensity: 0.5))),
            clip('it_lutgone0001', 30, 60, 'md_videoA00001', visual: const VisualProps(look: ImportedLut(MediaId('md_lutgone0001')))),
          ]),
        ], assets: [vA, asset('md_lutteal0001', MediaKind.lut), asset('md_lutgone0001', MediaKind.lut)]),
        resolverOf: (p) => resolverFor(p, offline: {'md_lutgone0001'}),
        check: (c, project) {
          expect(layer(c.plan, 'it_lut00000001#v').fx.lut, const PlanLut('md_lutteal0001', 0.5));
          expect(c.plan.assets['md_lutteal0001']!.kind, PlanAssetKind.lut);
          expect(layer(c.plan, 'it_lutgone0001#v').fx.lut, isNull);
          expect(c.plan.assets.containsKey('md_lutgone0001'), isFalse);
          expect(c.requirements.offline, ['md_lutgone0001']);
        },
      ),

      // Item keyframes → absolute anim channels (in-range keys only; values in plan units).
      GoldenCase(
        'keyframes_anim',
        project([
          mainLane([
            clip('it_gap00000001', 0, 30, 'md_videoB00001'),
            clip('it_keys0000001', 30, 90, 'md_videoA00001',
                visual: const VisualProps(mask: MaskSpec(shape: MaskShape.ellipse), adjust: ColorAdjust(contrast: 0.1)),
                keyframes: KeyframeSet({
                  // x only: y keeps its static value. Keys at -1 frame and at the duration are outside.
                  'transform.position.x': KeyframeTrack([Keyframe(-33333, 0.4), Keyframe(0, -0.25), Keyframe(1000000, 0.25), Keyframe(2000000, 0.5)]),
                  'transform.scale': KeyframeTrack([Keyframe(0, 1), Keyframe(1500000, 2)]),
                  'transform.rotation': KeyframeTrack([Keyframe(500000, 0), Keyframe(1500000, 90)]),
                  'transform.opacity': KeyframeTrack([Keyframe(0, 0), Keyframe(500000, 1)]),
                  'adjust.exposure': KeyframeTrack([Keyframe(0, -0.5), Keyframe(1966667, 0.5)]),
                  'detail.blur': KeyframeTrack([Keyframe(1000000, 0.2)]),
                  'mask.center.x': KeyframeTrack([Keyframe(0, 0.3), Keyframe(1000000, 0.7)]),
                  'mask.size.y': KeyframeTrack([Keyframe(0, 0.5), Keyframe(1000000, 1)]),
                  'mask.rotation': KeyframeTrack([Keyframe(0, 0), Keyframe(1000000, 45)]),
                  'mask.feather': KeyframeTrack([Keyframe(0, 0), Keyframe(1000000, 0.5)]),
                  'mask.opacity': KeyframeTrack([Keyframe(0, 1), Keyframe(1000000, 0.5)]),
                  // Every key outside [0, duration): inert.
                  'adjust.tint': KeyframeTrack([Keyframe(2000000, 0.5), Keyframe(3000000, 1)]),
                })),
          ]),
        ], assets: [vA, vB]),
        check: (c, project) {
          final l = layer(c.plan, 'it_keys0000001#v');
          final s = fr(30); // clip start
          expect(l.anim[PlanChannels.xfCx], [AnimKey(s, 480), AnimKey(s + 1000000, 1440)]);
          expect(l.anim.containsKey(PlanChannels.xfCy), isFalse);
          expect(l.anim[PlanChannels.xfS], [AnimKey(s, 1), AnimKey(s + 1500000, 2)]);
          expect(l.anim[PlanChannels.xfR], [AnimKey(s + 500000, 0), AnimKey(s + 1500000, 90)]);
          expect(l.anim[PlanChannels.xfOp], [AnimKey(s, 0), AnimKey(s + 500000, 1)]);
          expect(l.anim['adj.exposure'], [AnimKey(s, -0.5), AnimKey(s + 1966667, 0.5)]);
          expect(l.anim['detail.blur'], [AnimKey(s + 1000000, 0.2)]);
          expect(l.fx.detail, const PlanDetail()); // present because animated
          expect(l.anim['mask.cx'], [AnimKey(s, 0.3), AnimKey(s + 1000000, 0.7)]);
          expect(l.anim['mask.h'], [AnimKey(s, 0.5), AnimKey(s + 1000000, 1)]);
          expect(l.anim.keys, isNot(contains('adj.tint')));
          expect(l.anim.keys.toSet(), {'xf.cx', 'xf.s', 'xf.r', 'xf.op', 'adj.exposure', 'detail.blur', 'mask.cx', 'mask.h', 'mask.r', 'mask.feather', 'mask.op'});
        },
      ),

      // Constant speeds → one map segment at the rate.
      GoldenCase(
        'speed_constant',
        project([
          mainLane([
            clip('it_fast0000001', 0, 30, 'md_videoA00001', sourceIn: 1000000, speed: const ConstantSpeed(2)),
            clip('it_slow0000001', 30, 90, 'md_videoA00001', sourceIn: 4000000, speed: const ConstantSpeed(0.5)),
          ]),
        ], assets: [vA]),
        check: (c, project) {
          expect(layer(c.plan, 'it_fast0000001#v').map, [MapSegment(0, 1000000, 1000000, 3000000)]);
          expect(layer(c.plan, 'it_slow0000001#v').map, [MapSegment(1000000, 3000000, 4000000, 5000000)]);
        },
      ),

      // Speed ramps → multi-segment map from ClipTimeMap.lower (≤ 250 µs, breakpoints on the grid).
      GoldenCase(
        'speed_ramp',
        project([
          mainLane([
            clip('it_ramp0000001', 0, 120, 'md_videoA00001',
                sourceIn: 500000, speed: SpeedRamp(const [SpeedPoint(0, 1), SpeedPoint(0.5, 2), SpeedPoint(1, 1)])),
          ]),
        ], assets: [vA]),
        check: (c, project) {
          final l = layer(c.plan, 'it_ramp0000001#v');
          expect(l.map.length, greaterThan(1));
          final item = project.tracks.first.items.single as MediaClip;
          expect(l.map, item.timeMap(FrameRate.fps30).lower());
        },
      ),

      // Reversed clip → the ready rendition covering its range with an increasing, offset map.
      GoldenCase(
        'reversed_rendition',
        project([
          mainLane([
            clip('it_rev00000001', 0, 60, 'md_videoA00001', sourceIn: 3000000, reversed: true),
          ]),
        ], assets: [
          vA,
          // Covers [2 s, 6 s) of the source: the clip plays [3 s, 5 s) so r = 6 s − s starts at 1 s.
          asset('md_revwide0001', MediaKind.video, duration: 4000000, derived: const ReversedSpec(MediaId('md_videoA00001'), TimeRange(2000000, 6000000), sourceQuickHash: 'qh_md_videoA00001')),
          // Wider but longer: not preferred.
          asset('md_revwider001', MediaKind.video, duration: 10000000, derived: const ReversedSpec(MediaId('md_videoA00001'), TimeRange(0, 10000000), sourceQuickHash: 'qh_md_videoA00001')),
          // Shorter but pending, or not covering, or of other content: never chosen.
          asset('md_revpend0001', MediaKind.video, duration: 2000000, status: const PendingStatus('job_rev'), derived: const ReversedSpec(MediaId('md_videoA00001'), TimeRange(3000000, 5000000), sourceQuickHash: 'qh_md_videoA00001')),
          asset('md_revshort001', MediaKind.video, duration: 1000000, derived: const ReversedSpec(MediaId('md_videoA00001'), TimeRange(3500000, 5000000), sourceQuickHash: 'qh_md_videoA00001')),
          asset('md_revstale001', MediaKind.video, duration: 2000000, derived: const ReversedSpec(MediaId('md_videoA00001'), TimeRange(3000000, 5000000), sourceQuickHash: 'other')),
        ]),
        check: (c, project) {
          final l = layer(c.plan, 'it_rev00000001#v');
          expect(l.asset, 'md_revwide0001');
          expect(l.map, [MapSegment(0, 2000000, 1000000, 3000000)]);
          expect(c.plan.assets.keys, ['md_revwide0001']);
          expect(c.requirements.isEmpty, isTrue);
        },
      ),

      // Pending reverse → forward media layer + req.pendingReverse.
      GoldenCase(
        'pending_reverse',
        project([
          mainLane([clip('it_rev00000001', 0, 60, 'md_videoA00001', sourceIn: 3000000, reversed: true)]),
        ], assets: [
          vA,
          asset('md_revpend0001', MediaKind.video, duration: 2000000, status: const PendingStatus('job_rev'), derived: const ReversedSpec(MediaId('md_videoA00001'), TimeRange(3000000, 5000000), sourceQuickHash: 'qh_md_videoA00001')),
        ]),
        check: (c, project) {
          final l = layer(c.plan, 'it_rev00000001#v');
          expect(l.asset, 'md_videoA00001');
          expect(l.map, [MapSegment(0, 2000000, 3000000, 5000000)]);
          expect(c.plan.req!.pendingReverse, ['it_rev00000001']);
        },
      ),

      // Background BlurOfMain(r) → `#bd` per main-lane clip: same map, fill base, blur r, z − 5.
      GoldenCase(
        'backdrop_blur_of_main',
        project([
          mainLane([
            clip('it_main0000001', 0, 60, 'md_videoA00001', sourceIn: 1000000, visual: const VisualProps(crop: CropRect(left: 0.1, right: 0.9))),
            clip('it_photo000001', 60, 90, 'md_photo000001', visual: const VisualProps(transform: Transform2D(scale: 0.8))),
          ]),
          lane('tr_ov1', TrackKind.overlay, [clip('it_pip00000001', 0, 30, 'md_videoB00001')]),
        ], settings: const ProjectSettings(canvas: CanvasSpec(aspect: AspectRatio.portrait9x16), background: BlurOfMainBackground(0.5)), assets: [vA, vB, photo]),
        check: (c, project) {
          final p = c.plan;
          final bd = layer(p, 'it_main0000001#bd');
          final v = layer(p, 'it_main0000001#v');
          expect(bd.z, 5);
          expect(v.z, 10);
          expect(bd.map, v.map);
          expect(bd.asset, v.asset);
          // The 1536×1080 crop fills 1080×1920: scaled by 1920/1080.
          expect(bd.base!.w, closeTo(1536 * 1920 / 1080, 1e-9));
          expect(bd.base!.h, 1920);
          expect(v.base, const PlanSize(1080, 759.375)); // and fits by width
          expect(bd.fx, const PlanEffects(detail: PlanDetail(blur: 0.5)));
          expect(bd.xf, PlanTransform.identity);
          expect(layer(p, 'it_photo000001#bd').kind, PlanLayerKind.image);
          expect(p.layers.where((l) => l.id.startsWith('it_pip00000001')).map((l) => l.id), ['it_pip00000001#v']);
          expect(p.canvas.bg, 0xFF000000);
          expect(bd.seq, 0);
          expect(v.seq, 1);
        },
      ),

      // Missing media → dark-grey solid + req.offline (not in the pool, and file unavailable).
      GoldenCase(
        'missing_media',
        project([
          mainLane([
            clip('it_gone0000001', 0, 30, 'md_gone0000001'),
            clip('it_offline0001', 30, 60, 'md_videoB00001',
                visual: const VisualProps(transform: Transform2D(position: Vec2(0.1, 0), scale: 0.5), adjust: ColorAdjust(exposure: 1)),
                keyframes: KeyframeSet({
                  'transform.opacity': KeyframeTrack([Keyframe(0, 0), Keyframe(500000, 1)]),
                  'adjust.exposure': KeyframeTrack([Keyframe(0, 0), Keyframe(500000, 1)]),
                })),
            clip('it_present0001', 60, 90, 'md_videoA00001'),
          ]),
        ], assets: [vA, vB]),
        packingExclusions: {'it_offline0001#v'},
        resolverOf: (p) => resolverFor(p, offline: {'md_videoB00001'}),
        check: (c, project) {
          final gone = layer(c.plan, 'it_gone0000001#v');
          expect(gone.kind, PlanLayerKind.solid);
          expect(gone.color, offlinePlaceholderColor);
          expect(gone.base, const PlanSize(1920, 1080));
          final off = layer(c.plan, 'it_offline0001#v');
          expect(off.kind, PlanLayerKind.solid);
          expect(off.base, const PlanSize(1920, 1080));
          expect(off.xf, const PlanTransform(cx: 1152, s: 0.5));
          expect(off.anim.keys, ['xf.op']); // effects are not drawn on solids
          expect(off.fx, PlanEffects.none);
          expect(c.plan.req!.offline, ['md_gone0000001', 'md_videoB00001']);
          expect(c.plan.assets.keys, ['md_videoA00001']);
        },
      ),

      // Pending freeze still → hold media layer over the source + req.pendingStill.
      GoldenCase(
        'pending_still_hold',
        project([
          mainLane([
            clip('it_before00001', 0, 30, 'md_videoA00001'),
            clip('it_freeze00001', 30, 120, 'md_still000001'),
            clip('it_late0000001', 120, 150, 'md_still000002'),
          ]),
        ], assets: [
          vA,
          asset('md_still000001', MediaKind.still, w: null, h: null, status: const PendingStatus('job_still'), derived: const StillSpec(MediaId('md_videoA00001'), 1000000, sourceQuickHash: 'qh_md_videoA00001')),
          // Freezing near the end: a rate-1 range would run past the source, so the map runs at 0.1×.
          asset('md_still000002', MediaKind.still, w: null, h: null, status: const PendingStatus('job_still2'), derived: const StillSpec(MediaId('md_videoA00001'), 9800000, sourceQuickHash: 'qh_md_videoA00001')),
        ]),
        check: (c, project) {
          final l = layer(c.plan, 'it_freeze00001#v');
          expect(l.kind, PlanLayerKind.media);
          expect(l.hold, isTrue);
          expect(l.asset, 'md_videoA00001');
          expect(l.map, [MapSegment(fr(30), fr(120), 1000000, 4000000)]);
          expect(l.base, const PlanSize(1920, 1080));
          expect(layer(c.plan, 'it_late0000001#v').map, [MapSegment(fr(120), fr(150), 9800000, 9900000)]);
          expect(c.plan.req!.pendingStill, ['md_still000001', 'md_still000002']);
        },
      ),

      // Pending freeze still on an engine without holdFrame → neutral solid + req.pendingStill.
      GoldenCase(
        'pending_still_no_hold',
        project([
          mainLane([clip('it_freeze00001', 0, 60, 'md_still000001')]),
        ], assets: [
          vA,
          asset('md_still000001', MediaKind.still, w: null, h: null, status: const PendingStatus('job_still'), derived: const StillSpec(MediaId('md_videoA00001'), 1000000, sourceQuickHash: 'qh_md_videoA00001')),
        ]),
        options: const CompileOptions(holdFrame: false),
        check: (c, project) {
          final l = layer(c.plan, 'it_freeze00001#v');
          expect(l.kind, PlanLayerKind.solid);
          expect(l.color, pendingStillPlaceholderColor);
          expect(c.plan.req!.pendingStill, ['md_still000001']);
          expect(c.plan.assets, isEmpty);
        },
      ),

      // Ready still and photos → image layers (no map, no seq).
      GoldenCase(
        'image_layers',
        project([
          mainLane([
            clip('it_still000001', 0, 30, 'md_still000001'),
            clip('it_photo000001', 30, 90, 'md_photo000001', visual: const VisualProps(transform: Transform2D(rotationDeg: 90))),
          ]),
        ], assets: [
          vA,
          photo,
          asset('md_still000001', MediaKind.still, w: 1920, h: 1080, derived: const StillSpec(MediaId('md_videoA00001'), 2000000, sourceQuickHash: 'qh_md_videoA00001')),
        ]),
        check: (c, project) {
          final still = layer(c.plan, 'it_still000001#v');
          expect(still.kind, PlanLayerKind.image);
          expect(still.seq, isNull);
          expect(still.map, isEmpty);
          expect(c.plan.assets['md_still000001']!.uri, 'file:///media/md_still000001.png');
          expect(layer(c.plan, 'it_photo000001#v').base, const PlanSize(1440, 1080));
          expect(c.packing.slotCount, 0);
        },
      ),

      // Preview plans carry proxyUri when the proxy is ready; export plans never do.
      GoldenCase(
        'proxy_preview',
        _proxyProject,
        resolverOf: _proxyResolver,
        check: (c, project) {
          expect(c.plan.assets['md_videoA00001']!.proxyUri, 'file:///cache/danaview/editor/proxies/md_videoA00001-540.mp4');
          expect(c.plan.assets['md_videoB00001']!.proxyUri, isNull); // proxy not ready in the pool
        },
      ),
      GoldenCase(
        'proxy_export',
        _proxyProject,
        target: PlanTarget.export,
        resolverOf: _proxyResolver,
        check: (c, project) {
          expect(c.plan.target, PlanTarget.export);
          expect(c.plan.assets.values.every((a) => a.proxyUri == null), isTrue);
          expect(c.plan.assets['md_videoA00001']!.bookmark, 'Ym9va21hcms=');
          expect(c.plan.req, isNull);
        },
      ),

      // Track hidden / muted / solo: hidden lanes omitted (z of the others unchanged); mute and
      // solo affect audio only.
      GoldenCase(
        'hidden_muted_solo',
        project([
          mainLane([clip('it_main0000001', 0, 60, 'md_videoA00001')], muted: true, solo: true),
          lane('tr_ov1', TrackKind.overlay, [clip('it_hidden00001', 0, 60, 'md_videoB00001')], hidden: true),
          lane('tr_ov2', TrackKind.overlay, [clip('it_shown000001', 0, 60, 'md_videoB00001')], muted: true),
        ], assets: [vA, vB]),
        check: (c, project) {
          expect(c.plan.layers.map((l) => l.id), ['it_main0000001#v', 'it_shown000001#v']);
          expect(layer(c.plan, 'it_shown000001#v').z, 10020);
        },
      ),

      // Z order and bands; preview plans contain no text or subtitle layers (D-05).
      GoldenCase(
        'z_order_bands',
        project([
          mainLane([clip('it_main0000001', 0, 90, 'md_videoA00001')]),
          lane('tr_v2', TrackKind.video, [clip('it_video200001', 0, 30, 'md_videoB00001')]),
          lane('tr_ov1', TrackKind.overlay, [clip('it_ov100000001', 30, 60, 'md_videoB00001')]),
          lane('tr_ov2', TrackKind.overlay, [clip('it_ov200000001', 30, 60, 'md_photo000001')]),
          lane('tr_tx1', TrackKind.text, [TextItem(id: const ItemId('it_text0000001'), start: 0, duration: fr(30), text: 'Hello')]),
          lane('tr_sub', TrackKind.subtitle, [SubtitleCue(id: const ItemId('it_cue00000001'), start: 0, duration: fr(30), text: 'Hi')], subtitle: const SubtitleTrackData()),
          lane('tr_au1', TrackKind.audio, [MediaClip(id: const ItemId('it_music000001'), start: 0, duration: fr(90), media: const MediaId('md_music000001'))]),
        ], assets: [vA, vB, photo, asset('md_music000001', MediaKind.audio, w: null, h: null)]),
        check: (c, project) {
          expect({for (final l in c.plan.layers) l.id: l.z}, {
            'it_main0000001#v': 10,
            'it_video200001#v': 20,
            'it_ov100000001#v': 10010,
            'it_ov200000001#v': 10020,
          });
          expect(c.plan.layers.every((l) => l.kind != PlanLayerKind.sprite), isTrue);
          expect(c.plan.assets.containsKey('md_music000001'), isFalse);
          expect(c.plan.durUs, fr(90));
        },
      ),

      // Visual packing: six overlay lanes of short, non-overlapping PiPs share two slots.
      GoldenCase(
        'packing_pip_slots',
        project([
          mainLane([clip('it_main0000001', 0, 180, 'md_videoA00001')]),
          for (var i = 0; i < 6; i++)
            lane('tr_ov$i', TrackKind.overlay, [
              clip('it_pip${i}0000001', i * 30, i * 30 + 30, 'md_videoB00001', visual: const VisualProps(transform: Transform2D(scale: 0.3))),
            ]),
        ], assets: [vA, vB]),
        check: (c, project) {
          expect(c.packing.slotCount, 2);
          expect(layer(c.plan, 'it_main0000001#v').seq, 0);
          for (var i = 0; i < 6; i++) {
            expect(layer(c.plan, 'it_pip${i}0000001#v').seq, 1);
          }
          expect(c.packing.peakConcurrentDecoders, 2);
        },
      ),

      // Export to another canvas and rate: letterboxed fit, positions/bases mapped, blur scaled,
      // a content clip on every layer, `gridFps` = project rate.
      GoldenCase(
        'export_letterbox',
        project([
          mainLane([clip('it_main0000001', 0, 60, 'md_videoA00001', visual: const VisualProps(detail: DetailFx(blur: 0.4)))]),
          lane('tr_ov1', TrackKind.overlay, [
            clip('it_pip00000001', 0, 60, 'md_videoB00001',
                visual: const VisualProps(transform: Transform2D(position: Vec2(0.5, 0.5), scale: 0.5)),
                keyframes: KeyframeSet({
                  'transform.position.y': KeyframeTrack([Keyframe(0, 0.5), Keyframe(1000000, 0)]),
                })),
          ]),
        ], settings: const ProjectSettings(canvas: CanvasSpec(aspect: AspectRatio.portrait9x16), background: BlurOfMainBackground(0.6)), assets: [vA, vB]),
        target: PlanTarget.export,
        options: const CompileOptions(output: PlanOutputSpec(width: 1920, height: 1080, fps: 60)),
        check: (c, project) {
          final p = c.plan;
          expect(p.canvas, const PlanCanvas(w: 1920, h: 1080, fps: 60, gridFps: 30));
          // 1080×1920 into 1920×1080: scale 0.5625, content 607.5×1080 at x = 656.25.
          final v = layer(p, 'it_main0000001#v');
          expect(v.base, const PlanSize(607.5, 341.71875));
          expect(layer(p, 'it_main0000001#bd').base, const PlanSize(1920, 1080)); // fill of the 607.5×1080 content
          expect(v.xf.cx, isNull); // centred
          expect(v.fx.detail!.blur, closeTo(0.4 * 0.5625, 1e-12));
          final clipMask = const CanvasMask(cx: 960, cy: 540, w: 607.5, h: 1080);
          expect(p.layers.every((l) => l.cmasks.contains(clipMask)), isTrue);
          final pip = layer(p, 'it_pip00000001#v');
          // Project px (540 + 0.5·1080, 960 + 0.5·1920) = (1080, 1920) → output (656.25 + 0.5625·1080, 0.5625·1920).
          expect(pip.xf.cx, 656.25 + 0.5625 * 1080);
          expect(pip.xf.cy, 1080);
          expect(pip.anim[PlanChannels.xfCy], [const AnimKey(0, 1080), const AnimKey(1000000, 540)]);
          expect(layer(p, 'it_main0000001#bd').fx.detail!.blur, closeTo(0.6 * 0.5625, 1e-12));
        },
      ),

      // Export at another size of the same aspect: scaled, no letterbox and no content clip.
      GoldenCase(
        'export_scaled',
        project([
          mainLane([
            clip('it_main0000001', 0, 60, 'md_videoA00001', visual: const VisualProps(transform: Transform2D(position: Vec2(-0.25, 0.25), scale: 0.5))),
          ]),
        ], assets: [vA]),
        target: PlanTarget.export,
        options: const CompileOptions(output: PlanOutputSpec(width: 1280, height: 720, fps: 24)),
        check: (c, project) {
          final l = layer(c.plan, 'it_main0000001#v');
          expect(l.base!.w, closeTo(1280, 1e-9));
          expect(l.base!.h, closeTo(720, 1e-9));
          expect(l.xf.cx, closeTo(320, 1e-9));
          expect(l.xf.cy, closeTo(540, 1e-9));
          expect(l.cmasks, isEmpty);
          expect(c.plan.canvas.gridFps, 30);
          expect(c.plan.canvas.fps, 24);
        },
      ),
    ];

final EditProject _proxyProject = project([
  mainLane([
    clip('it_clipA000001', 0, 30, 'md_videoA00001'),
    clip('it_clipB000001', 30, 60, 'md_videoB00001'),
  ]),
], assets: [
  asset('md_videoA00001', MediaKind.video, proxy: ProxyState.ready, transfer: ColorTransfer.hlg),
  asset('md_videoB00001', MediaKind.video, w: 1280, h: 720, duration: 20000000, proxy: ProxyState.pending),
]);

MapPlanAssetResolver _proxyResolver(EditProject p) => resolverFor(p,
    proxied: {'md_videoA00001', 'md_videoB00001'}, bookmarks: {'md_videoA00001': Uint8List.fromList('bookmark'.codeUnits)});

CompiledPlan compileCase(GoldenCase g) => g.compile();

void main() {
  final all = cases();
  final names = all.map((c) => c.name).toList();

  test('every case has a unique name and the golden directory holds exactly these goldens', () {
    expect(names.toSet().length, names.length);
    if (updateGoldens) return;
    final files = Directory('test/plan/compile_visual/goldens')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.json'))
        .toSet();
    expect(files, {for (final n in names) '$n.json'});
  });

  for (final g in all) {
    group(g.name, () {
      late CompiledPlan compiled;
      setUpAll(() => compiled = compileCase(g));


      test('matches goldens/${g.name}.json', () {
        final file = File('test/plan/compile_visual/goldens/${g.name}.json');
        final text = canonical(compiled.plan);
        if (updateGoldens) {
          file
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
          return;
        }
        expect(text, file.readAsStringSync());
        // The golden decodes back to the compiled plan (a valid contract document).
        expect(PlanJson.decodePlanBytes(file.readAsBytesSync()), compiled.plan);
      });

      test('passes the CORE-29 validator', () => expect(compiled.violations(), isEmpty));

      test('row lowering', () => g.check(compiled, g.project));

      test('model-derived packing inputs equal the compiled media layers', () {
        final derived = packingInputsOf(g.project, holdFrame: g.options.holdFrame)
            .where((i) => !g.packingExclusions.contains(i.id))
            .toList();
        expect(mediaInputsOf(compiled.plan), derived);
        final packed = packVisualLayers(derived);
        for (final l in compiled.plan.layers.where((l) => l.kind == PlanLayerKind.media)) {
          expect(l.seq, packed.seqOf(l.id), reason: l.id);
        }
      });

      test('is deterministic', () => expect(compileCase(g).plan, compiled.plan));
    });
  }
}
