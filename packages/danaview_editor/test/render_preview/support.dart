// OWNER: UX-44
//
// Fixtures for the render-preview tests: small preview plans on a 30 fps grid with chroma-keyed
// layers (heavy on every tier), and a render-preview store over CORE-37's real `RenderCacheIndex`
// on an in-memory file system. The fake engine's renders only record a stub path, so the store
// writes the stub bytes at the staged path before `put` moves it into place, like the native
// renderer would have.

import 'dart:async';

import 'package:danaview_editor/src/editor/state/render_preview_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';

/// 30 fps grid.
const FrameRate grid = FrameRate.fps30;

/// Frame [k].
TimeUs f(int k) => grid.timeOfFrame(k);

/// Test roots.
const StoreRoots roots = StoreRoots(support: '/mem/support', cache: '/mem/cache', documents: '/mem/documents');

/// A chroma key effect (makes a range heavy on every tier).
const PlanEffects chroma = PlanEffects(chroma: PlanChroma(key: 0xFF00FF00));

/// A video asset.
PlanAsset video(String fp) =>
    PlanAsset(kind: PlanAssetKind.video, uri: 'file:///media/$fp.mp4', fp: fp, w: 1920, h: 1080, rot: 0, durUs: 600 * microsPerSecond);

/// A media layer on frames `[k0, k1)` from source frame [src].
PlanLayer media(String id, int k0, int k1, String asset,
        {int z = 0, int src = 0, PlanEffects fx = PlanEffects.none, PlanTransform xf = PlanTransform.identity, Map<String, List<AnimKey>> anim = const {}}) =>
    PlanLayer(
      id: id,
      z: z,
      seq: z,
      t0: f(k0),
      t1: f(k1),
      kind: PlanLayerKind.media,
      asset: asset,
      map: [MapSegment(f(k0), f(k1), f(src), f(src) + (f(k1) - f(k0)))],
      base: const PlanSize(1920, 1080),
      xf: xf,
      fx: fx,
      anim: anim,
    );

/// A preview plan of [layers] (sorted by (z, t0, id)).
RenderPlan planOf(List<PlanLayer> layers, {int rev = 1}) {
  final ls = layers.toList()
    ..sort((a, b) {
      final z = a.z.compareTo(b.z);
      if (z != 0) return z;
      final t = a.t0.compareTo(b.t0);
      return t != 0 ? t : a.id.compareTo(b.id);
    });
  final dur = ls.fold<TimeUs>(0, (m, l) => l.t1 > m ? l.t1 : m);
  return RenderPlan(
    rev: rev,
    target: PlanTarget.preview,
    canvas: const PlanCanvas(w: 640, h: 360, fps: 30),
    durUs: dur,
    assets: {for (final l in ls) if (l.asset != null) l.asset!: video('fp_${l.asset}')},
    layers: ls,
  );
}

/// Background A on frames 0–120, chroma-keyed B on 30–60 and C on 90–120.
///
/// Ranges: [0,30) light, [30,60) heavy, [60,90) light, [90,120) heavy.
RenderPlan basePlan({int rev = 1, PlanTransform bXf = PlanTransform.identity}) => planOf([
      media('it_a#v0', 0, 120, 'a'),
      media('it_b#v0', 30, 60, 'b', z: 1, fx: chroma, xf: bXf),
      media('it_c#v0', 90, 120, 'c', z: 2, fx: chroma),
    ], rev: rev);

/// The same plan with B moved (an edit inside the [30,60) range only).
RenderPlan editedPlan({int rev = 2}) => basePlan(rev: rev, bXf: const PlanTransform(s: 0.5));

/// A light plan (one background layer, frames 0–60): every range plays live.
RenderPlan lightPlan({int rev = 1}) => planOf([media('it_a#v0', 0, 60, 'a')], rev: rev);

/// A store over the real index on [memory].
final class MemoryRenderStore implements RenderPreviewStore {
  /// Creates the store.
  MemoryRenderStore._(this.memory, this.index);

  /// A fresh store with an empty `/mem` tree.
  factory MemoryRenderStore() {
    final memory = MemoryStoreFs();
    [roots.support, roots.cache, roots.documents].forEach(memory.mkdirs);
    final deleter = OwnedFileDeleter(roots, fs: memory, assertOnViolation: false);
    return MemoryRenderStore._(memory, RenderCacheIndex(roots: roots, deleter: deleter, fs: memory));
  }

  /// The file system.
  final MemoryStoreFs memory;

  /// The real index.
  final RenderCacheIndex index;

  /// Bytes written for every render.
  static const int renderBytes = 4096;

  /// Hashes put, in order.
  final List<String> puts = [];

  @override
  bool contains(String hash) => index.isOpen && index.contains(hash);

  @override
  Future<void> open() => index.open();

  @override
  String pathFor(String hash) => index.pathFor(hash);

  @override
  String stagingPathFor(String hash) => index.stagingPathFor(hash);

  @override
  Future<void> put(String hash, String renderedFile) async {
    memory.putFile(renderedFile, List<int>.filled(renderBytes, 7));
    puts.add(hash);
    await index.put(hash, renderedFile);
  }

  @override
  Future<void> trim(RenderCacheTrimLevel level) => index.trim(level);

  @override
  Future<void> clear() => index.clear();

  @override
  Future<int> bytes() => index.bytes();
}

/// A controller over [engine] and [store] for [tier] with [setting].
RenderPreviewController controllerFor(
  FakeEditorEngine engine, {
  RenderPreviewStore? store,
  RenderTier tier = RenderTier.mid,
  RenderPreviewSetting? setting,
}) =>
    RenderPreviewController(
      jobs: engine.jobs,
      power: engine.background,
      store: store,
      tier: tier,
      budget: RenderBudget.forTier(tier),
      setting: () => setting ?? RenderPolicy.defaultSetting(tier),
    );

/// Opens a fake preview session with [plan] applied.
Future<FakePreviewSession> openSession(FakeEditorEngine engine, RenderPlan plan) async {
  final session = await engine.openPreview(const PreviewConfig(canvasWidth: 640, canvasHeight: 360, fps: 30)) as FakePreviewSession;
  await session.setPlan(plan);
  return session;
}

/// Lets queued microtasks and zero-time work run (outside fakeAsync).
Future<void> settle([int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The hashes of [ranges].
Set<String> hashesOf(Iterable<RenderedRange> ranges) => {for (final r in ranges) r.hash};

/// Keeps a completer from being reported as unhandled.
void ignore(Future<void> f) => unawaited(f.catchError((Object _) {}));
