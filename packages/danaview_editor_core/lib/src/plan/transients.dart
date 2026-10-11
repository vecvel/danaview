// OWNER: CORE-32
//
// Gesture transients (ARCH §11.2 Transient, §11.8). While the user drags, scales, rotates or
// scrubs a slider on one item, the UI sends `PlanTransient`s (≤ 60 Hz) built from the **working**
// project (the gesture's uncommitted state) instead of full plans: param fields only (`xf`,
// `crop`, `base`, `fx`, `anim`, `cmasks`) for that item's own layers (`<itemId>#v` and its
// `#bd` backdrop), never timing fields; engines merge them over the current layers.
//
// [transientFor] lowers just that item: the working project reduced to the item's lane holding
// the item and its transition neighbours (every other lane kept but emptied, so lane indexes and
// z stay exact) is compiled with the caller's stages (audio stages are skipped: gain is not a
// transient field), and the item's layers are read back. The cost is a few clips regardless of
// the project size.

import '../ids/ids.dart';
import '../model/items.dart';
import '../model/project.dart';
import '../model/track.dart';
import 'asset_resolver.dart';
import 'compiler.dart';
import 'lowering_audio.dart';
import 'lowering_transitions.dart';
import 'render_plan.dart';

/// The param-only fields of [layer] as a transient override.
TransientLayer transientLayerOf(PlanLayer layer) => TransientLayer(
      id: layer.id,
      xf: layer.xf,
      crop: layer.crop,
      base: layer.base,
      fx: layer.fx,
      anim: layer.anim,
      cmasks: layer.cmasks,
    );

/// Whether [layerId] is one of [item]'s own layers (`#v`, `#bd`, or a burned cue's `#c`), not a
/// transition helper.
bool isOwnLayer(String layerId, ItemId item) =>
    layerId == PlanIds.visual(item) || layerId == PlanIds.backdrop(item) || layerId == PlanIds.cue(item);

/// The transient of [itemId] in [working] (file header), or null when the item does not exist or
/// has no layers in a plan of [target] (audio clips, text in preview, hidden lanes).
PlanTransient? transientFor(
  EditProject working,
  ItemId itemId,
  PlanAssetResolver resolver, {
  CompileOptions options = const CompileOptions(),
  PlanTarget target = PlanTarget.preview,
}) {
  final loc = working.index.locate(itemId);
  if (loc == null) return null;
  final reduced = reduceToItem(working, itemId);
  final compiled = compilePlan(
    reduced,
    target,
    resolver,
    options: CompileOptions(
      rev: options.rev,
      output: options.output,
      holdFrame: options.holdFrame,
      // Audio is not a transient field; stage memos are dropped (the reduced project's layers are
      // throwaway objects).
      stages: [
        for (final s in options.stages)
          if (s is TransitionLoweringStage)
            const TransitionLoweringStage()
          else if (s is! AudioLoweringStage)
            s,
      ],
    ),
  );
  final layers = [
    for (final l in compiled.plan.layers)
      if (isOwnLayer(l.id, itemId)) transientLayerOf(l),
  ];
  if (layers.isEmpty) return null;
  return PlanTransient(item: itemId, layers: layers);
}

/// [project] with every track kept (same order, flags and ids) but only [itemId] and its
/// transition neighbours left on its track (with the transitions touching it); every other track
/// is emptied. The project of [project] unchanged when the item is not found.
EditProject reduceToItem(EditProject project, ItemId itemId) {
  final loc = project.index.locate(itemId);
  if (loc == null) return project;
  final track = loc.track;
  final transitions = [
    for (final t in track.transitions)
      if (t.left == itemId || t.right == itemId) t,
  ];
  final keep = <ItemId>{itemId, for (final t in transitions) t.left, for (final t in transitions) t.right};
  final tracks = <Track>[
    for (final t in project.tracks)
      if (identical(t, track))
        t.copyWith(items: [for (final i in t.items) if (keep.contains(i.id)) i], transitions: transitions)
      else
        t.items.isEmpty && t.transitions.isEmpty ? t : t.copyWith(items: const <TimelineItem>[], transitions: const []),
  ];
  return project.copyWith(timeline: project.timeline.copyWith(tracks: tracks));
}
