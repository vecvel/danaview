// OWNER: CORE-32
//
// Plan diffs and patches (ARCH §11.2 Patch, §11.8):
//
// * [diffPlans] is identity-first: memoized layers, segments and assets are `identical` when
//   unchanged, so most comparisons are a pointer check; otherwise `==` decides. Objects that
//   differ are upserted whole by id; ids gone from `b` are removed. `canvas` and `durUs` appear
//   only when they change. `req` is informational and not part of the wire patch.
// * [applyPatch] applies a patch the way engines do (pure; used by tests and the fake engine):
//   only when `patch.from` equals the plan's `rev` ([PlanOutOfSync] otherwise), removals then
//   upserts, layers re-sorted by (z, t0, id) and audio by (t0, id). `apply(diff(a, b), a) == b`
//   for plans of one target (with `b.req` carried over from `a`).
// * [classifyPatch] is the engines' structural / param-only split, exactly ARCH §11.2 "Patch
//   classification": structural = layer set change, a layer's `kind`, `z`, `t`, `asset`, `map`,
//   `hold` (and `seq`, which only changes together with those), any audio change except `gain`,
//   canvas, `durUs`, the asset set or an asset entry; param-only = `xf`, `crop`, `base`, `fx`,
//   `anim`, `cmasks`, `color` and audio `gain`. Shared vectors:
//   `test/fixtures/render_plans/classification.json` (IOS-08, AND-08).

import 'package:collection/collection.dart';

import '../time/map_segment.dart';
import 'render_plan.dart';

/// Thrown by [applyPatch] when the patch does not start at the plan's revision (`planOutOfSync`).
final class PlanOutOfSync implements Exception {
  /// Creates the error.
  const PlanOutOfSync(this.planRev, this.patchFrom);

  /// The plan's revision.
  final int planRev;

  /// The patch's `from`.
  final int patchFrom;

  @override
  String toString() => 'PlanOutOfSync(plan rev $planRev, patch from $patchFrom)';
}

/// The patch turning [a] into [b] (file header). Both must have the same target.
RenderPlanPatch diffPlans(RenderPlan a, RenderPlan b) {
  if (a.target != b.target) throw ArgumentError('cannot diff a ${a.target.name} plan against a ${b.target.name} plan');
  // Assets.
  final assetUpserts = <String, PlanAsset>{};
  for (final e in b.assets.entries) {
    final old = a.assets[e.key];
    if (old == null || !(identical(old, e.value) || old == e.value)) assetUpserts[e.key] = e.value;
  }
  final assetRemovals = [
    for (final id in a.assets.keys)
      if (!b.assets.containsKey(id)) id,
  ];

  final (layerUpserts, layerRemovals) = _diffList<PlanLayer>(a.layers, b.layers, (l) => l.id);
  final (audioUpserts, audioRemovals) = _diffList<AudioSeg>(a.audio, b.audio, (s) => s.id);

  return RenderPlanPatch(
    v: b.v,
    from: a.rev,
    to: b.rev,
    canvas: a.canvas == b.canvas ? null : b.canvas,
    durUs: a.durUs == b.durUs ? null : b.durUs,
    assetUpserts: assetUpserts,
    assetRemovals: assetRemovals,
    layers: PatchSet<PlanLayer>(upsert: layerUpserts, remove: layerRemovals),
    audio: PatchSet<AudioSeg>(upsert: audioUpserts, remove: audioRemovals),
  );
}

Map<String, T> _byId<T>(List<T> list, String Function(T) id) => {for (final x in list) id(x): x};

/// Upserts and removals turning [a] into [b] (lists of objects with unique ids). Positional fast
/// path first: compiled plans keep their order, so an unchanged object usually sits at the same
/// index (and is `identical` when memoized); the id maps are built only when ids moved.
(List<T>, List<String>) _diffList<T extends Object>(List<T> a, List<T> b, String Function(T) id) {
  final upserts = <T>[];
  var aligned = a.length == b.length;
  for (var i = 0; i < b.length; i++) {
    final y = b[i];
    if (aligned) {
      final x = a[i];
      if (identical(x, y)) continue;
      if (id(x) == id(y)) {
        if (x != y) upserts.add(y);
        continue;
      }
      aligned = false;
      // Ids moved: restart this index on the general path.
      upserts.clear();
      return _diffById(a, b, id);
    }
  }
  if (aligned) return (upserts, const []);
  return _diffById(a, b, id);
}

(List<T>, List<String>) _diffById<T extends Object>(List<T> a, List<T> b, String Function(T) id) {
  final byId = _byId(a, id);
  final upserts = <T>[];
  final ids = <String>{};
  for (final y in b) {
    final k = id(y);
    ids.add(k);
    final x = byId[k];
    if (x == null || !(identical(x, y) || x == y)) upserts.add(y);
  }
  final removals = [
    for (final x in a)
      if (!ids.contains(id(x))) id(x),
  ];
  return (upserts, removals);
}

/// Whether [patch] changes nothing (an empty diff).
bool isEmptyPatch(RenderPlanPatch patch) =>
    patch.canvas == null &&
    patch.durUs == null &&
    patch.assetUpserts.isEmpty &&
    patch.assetRemovals.isEmpty &&
    patch.layers.isEmpty &&
    patch.audio.isEmpty;

/// [plan] with [patch] applied (file header). Throws [PlanOutOfSync] when `patch.from` is not
/// `plan.rev`.
RenderPlan applyPatch(RenderPlan plan, RenderPlanPatch patch) {
  if (patch.from != plan.rev) throw PlanOutOfSync(plan.rev, patch.from);
  final assets = {...plan.assets};
  for (final id in patch.assetRemovals) {
    assets.remove(id);
  }
  assets.addAll(patch.assetUpserts);

  final layers = _byId(plan.layers, (l) => l.id);
  for (final id in patch.layers.remove) {
    layers.remove(id);
  }
  for (final l in patch.layers.upsert) {
    layers[l.id] = l;
  }
  final sortedLayers = layers.values.toList()..sort(compareLayers);

  final audio = _byId(plan.audio, (s) => s.id);
  for (final id in patch.audio.remove) {
    audio.remove(id);
  }
  for (final s in patch.audio.upsert) {
    audio[s.id] = s;
  }
  final sortedAudio = audio.values.toList()..sort(compareAudio);

  return RenderPlan(
    v: plan.v,
    rev: patch.to,
    target: plan.target,
    canvas: patch.canvas ?? plan.canvas,
    durUs: patch.durUs ?? plan.durUs,
    assets: assets,
    layers: sortedLayers,
    audio: sortedAudio,
    req: plan.req,
  );
}

/// Draw order of layers: (z, t0, id).
int compareLayers(PlanLayer a, PlanLayer b) {
  if (a.z != b.z) return a.z.compareTo(b.z);
  if (a.t0 != b.t0) return a.t0.compareTo(b.t0);
  return a.id.compareTo(b.id);
}

/// Order of audio segments: (t0, id).
int compareAudio(AudioSeg a, AudioSeg b) {
  if (a.t0 != b.t0) return a.t0.compareTo(b.t0);
  return a.id.compareTo(b.id);
}

/// How an engine applies a patch (ARCH §11.2 "Patch classification").
enum PatchClass {
  /// Rebuild the platform composition and restore playhead and play state.
  structural,

  /// Swap the `ParamSnapshot` and redraw (≤ 50 ms low / 30 ms mid).
  paramOnly,
}

/// The classification of [patch] applied to [from] (file header). An empty patch is param-only.
PatchClass classifyPatch(RenderPlan from, RenderPlanPatch patch) =>
    patchIsStructural(from, patch) ? PatchClass.structural : PatchClass.paramOnly;

/// Whether [patch] applied to [from] is structural (file header).
bool patchIsStructural(RenderPlan from, RenderPlanPatch patch) {
  if (patch.canvas != null && patch.canvas != from.canvas) return true;
  if (patch.durUs != null && patch.durUs != from.durUs) return true;
  for (final id in patch.assetRemovals) {
    if (from.assets.containsKey(id)) return true;
  }
  for (final e in patch.assetUpserts.entries) {
    if (from.assets[e.key] != e.value) return true;
  }
  if (patch.layers.remove.isNotEmpty || patch.audio.remove.isNotEmpty) {
    final layerIds = {for (final l in from.layers) l.id};
    if (patch.layers.remove.any(layerIds.contains)) return true;
    final audioIds = {for (final s in from.audio) s.id};
    if (patch.audio.remove.any(audioIds.contains)) return true;
  }
  if (patch.layers.upsert.isNotEmpty) {
    final layers = _byId(from.layers, (l) => l.id);
    for (final l in patch.layers.upsert) {
      final old = layers[l.id];
      if (old == null || layerTimingChanged(old, l)) return true;
    }
  }
  if (patch.audio.upsert.isNotEmpty) {
    final audio = _byId(from.audio, (s) => s.id);
    for (final s in patch.audio.upsert) {
      final old = audio[s.id];
      if (old == null || audioStructureChanged(old, s)) return true;
    }
  }
  return false;
}

/// Whether [a] → [b] changes a structural field of a layer (`kind`, `z`, `t`, `asset`, `map`,
/// `hold`, `seq`).
bool layerTimingChanged(PlanLayer a, PlanLayer b) =>
    a.kind != b.kind ||
    a.z != b.z ||
    a.t0 != b.t0 ||
    a.t1 != b.t1 ||
    a.asset != b.asset ||
    a.hold != b.hold ||
    a.seq != b.seq ||
    !(identical(a.map, b.map) || const ListEquality<MapSegment>().equals(a.map, b.map));

/// Whether [a] → [b] changes anything of an audio segment but its `gain`.
bool audioStructureChanged(AudioSeg a, AudioSeg b) =>
    a.asset != b.asset ||
    a.stream != b.stream ||
    a.t0 != b.t0 ||
    a.t1 != b.t1 ||
    a.pitch != b.pitch ||
    !(identical(a.map, b.map) || const ListEquality<MapSegment>().equals(a.map, b.map));
