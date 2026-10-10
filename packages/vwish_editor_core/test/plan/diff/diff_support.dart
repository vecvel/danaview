// OWNER: CORE-32
//
// Helpers of the diff tests: memoized standard compiles, plan equality modulo `req` (which is
// informational and not part of the wire patch), and random edit commands.

import 'dart:math';

import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_core/plan.dart';

/// [plan] without `req`.
RenderPlan withoutReq(RenderPlan plan) => RenderPlan(
      v: plan.v,
      rev: plan.rev,
      target: plan.target,
      canvas: plan.canvas,
      durUs: plan.durUs,
      assets: plan.assets,
      layers: plan.layers,
      audio: plan.audio,
    );

/// Compiles a preview plan of [p] with the standard stages, memoized by [memo] when given.
CompiledPlan compileMemo(EditProject p, PlanAssetResolver resolver, {PlanMemo? memo, PlanTarget target = PlanTarget.preview}) =>
    memo == null
        ? compilePlan(p, target, resolver, options: CompileOptions(stages: standardLoweringStages()))
        : memo.compile(p, target, resolver);

/// A random edit command on [p]: move, trim, split, delete, appearance, audio, lane flags or a
/// transition. May be rejected by the command; callers skip those.
EditCommand randomEdit(EditProject p, Random rnd) {
  final clips = <(Track, MediaClip)>[
    for (final t in p.tracks)
      for (final i in t.items)
        if (i is MediaClip) (t, i),
  ];
  final rate = p.settings.frameRate;
  if (clips.isEmpty) return SetTrackFlags(p.tracks.first.id, muted: rnd.nextBool());
  final (track, c) = clips[rnd.nextInt(clips.length)];
  switch (rnd.nextInt(9)) {
    case 0:
      return MoveItems({c.id}, rate.timeOfFrame(rnd.nextInt(20)) * (rnd.nextBool() ? 1 : -1), clamp: true);
    case 1:
      final mid = c.start + rate.timeOfFrame(1 + rnd.nextInt(5));
      return TrimItem(c.id, TrimEdge.start, mid, clamp: true);
    case 2:
      final f = rate.frameIndexOf(c.start) + 1 + rnd.nextInt(10);
      return SplitItems({c.id}, rate.timeOfFrame(f));
    case 3:
      return DeleteItems({c.id}, ripple: rnd.nextBool());
    case 4:
    case 5:
      final v = c.visual ?? VisualProps.neutral;
      return SetVisual([c.id], v.copyWith(transform: v.transform.copyWith(scale: 0.5 + rnd.nextDouble(), opacity: rnd.nextDouble())));
    case 6:
      return SetAudio([c.id], c.audio.copyWith(volume: rnd.nextDouble() * 2, muted: rnd.nextInt(4) == 0));
    case 7:
      return SetTrackFlags(track.id, hidden: track.kind.isVisual ? rnd.nextBool() : null, muted: rnd.nextBool());
    default:
      final cuts = TransitionLimits.cutsOf(track);
      if (cuts.isEmpty) return MoveItems({c.id}, rate.timeOfFrame(1), clamp: true);
      final kinds = TransitionKind.values;
      return SetTransition(cuts[rnd.nextInt(cuts.length)], TransitionSpec(kinds[rnd.nextInt(kinds.length)], 2 + rnd.nextInt(10)), clamp: true);
  }
}
