// OWNER: API-03
//
// The parameters of one plan layer evaluated at one plan time (the Dart twin of the native
// `ParamSnapshot`, ARCH §11.2 `anim`, §11.5, §13.2/§13.3): every animated channel overrides its
// static value with core's linear `evaluateAnimKeys` (absolute µs, held outside the keys).
// Callers holding a platform time map it first with `frameTime` (D-35).

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart' show FrameRate, TimeUs;
import 'package:danaview_editor_core/plan.dart';

/// One layer's effective parameters at one plan time (ARCH §11.2 Animatable channels, D-35).
@immutable
final class LayerParamSnapshot {
  /// Creates a snapshot.
  const LayerParamSnapshot({
    required this.xf,
    this.adj,
    this.detail,
    this.mask,
    this.reveal,
    this.cmasks = const [],
  });

  /// Evaluates [layer] at plan time [t] on [canvas]: `xf` with its centre resolved to canvas px,
  /// `adj` / `detail` present when static or animated, `mask` only when the layer has a static mask
  /// (its shape is not animatable), `reveal` only when the channel exists, and canvas masks with
  /// their `anim` applied (and cleared).
  factory LayerParamSnapshot.at(PlanLayer layer, PlanCanvas canvas, TimeUs t) {
    final anim = layer.anim;
    double v(String channel, double fallback) {
      final keys = anim[channel];
      return keys == null || keys.isEmpty ? fallback : evaluateAnimKeys(keys, t);
    }

    final x = layer.xf;
    final xf = PlanTransform(
      cx: v(PlanChannels.xfCx, x.cx ?? canvas.w / 2),
      cy: v(PlanChannels.xfCy, x.cy ?? canvas.h / 2),
      s: v(PlanChannels.xfS, x.s),
      r: v(PlanChannels.xfR, x.r),
      fx: x.fx,
      fy: x.fy,
      op: v(PlanChannels.xfOp, x.op),
    );

    PlanAdjust? adj = layer.fx.adj;
    if (adj != null || PlanChannels.adjust.any(anim.containsKey)) {
      final a = adj ?? const PlanAdjust();
      adj = PlanAdjust(
        exposure: v('adj.exposure', a.exposure),
        brightness: v('adj.brightness', a.brightness),
        contrast: v('adj.contrast', a.contrast),
        highlights: v('adj.highlights', a.highlights),
        shadows: v('adj.shadows', a.shadows),
        saturation: v('adj.saturation', a.saturation),
        temperature: v('adj.temperature', a.temperature),
        tint: v('adj.tint', a.tint),
      );
    }

    PlanDetail? detail = layer.fx.detail;
    if (detail != null || PlanChannels.detail.any(anim.containsKey)) {
      final d = detail ?? const PlanDetail();
      detail = PlanDetail(
        sharpen: v('detail.sharpen', d.sharpen),
        blur: v('detail.blur', d.blur),
        vignette: v('detail.vignette', d.vignette),
      );
    }

    final m = layer.fx.mask;
    final mask = m == null
        ? null
        : PlanMask(
            shape: m.shape,
            cx: v('mask.cx', m.cx),
            cy: v('mask.cy', m.cy),
            w: v('mask.w', m.w),
            h: v('mask.h', m.h),
            r: v('mask.r', m.r),
            corner: m.corner,
            feather: v('mask.feather', m.feather),
            op: v('mask.op', m.op),
            inv: m.inv,
          );

    final revealKeys = anim[PlanChannels.reveal];
    return LayerParamSnapshot(
      xf: xf,
      adj: adj,
      detail: detail,
      mask: mask,
      reveal: revealKeys == null || revealKeys.isEmpty ? null : evaluateAnimKeys(revealKeys, t),
      cmasks: [for (final c in layer.cmasks) evaluateCanvasMask(c, t)],
    );
  }

  /// Placement with `cx`/`cy` resolved (never null) and animated channels applied.
  final PlanTransform xf;

  /// Colour adjustments, or null when the layer has none.
  final PlanAdjust? adj;

  /// Detail effects, or null when the layer has none.
  final PlanDetail? detail;

  /// Item mask, or null.
  final PlanMask? mask;

  /// The `reveal` channel value (sprites), or null when not animated.
  final double? reveal;

  /// Canvas masks with their animated `cx`, `cy`, `w`, `h` applied.
  final List<CanvasMask> cmasks;

  /// A canvas mask with its `anim` channels evaluated at [t] (the result has no `anim`).
  static CanvasMask evaluateCanvasMask(CanvasMask m, TimeUs t) {
    double v(String c, double fallback) {
      final keys = m.anim[c];
      return keys == null || keys.isEmpty ? fallback : evaluateAnimKeys(keys, t);
    }

    return CanvasMask(cx: v('cx', m.cx), cy: v('cy', m.cy), w: v('w', m.w), h: v('h', m.h), r: m.r, feather: m.feather, inv: m.inv);
  }

  /// The plan time at which an output frame stamped with platform time [tau] is evaluated:
  /// `timeOfFrame(frameIndexNearest(τ))` of the output rate (ARCH §11.5, D-35).
  static TimeUs frameTime(PlanCanvas canvas, TimeUs tau) {
    final rate = FrameRate(canvas.fps, 1);
    return rate.timeOfFrame(rate.frameIndexNearest(tau));
  }
}
