// OWNER: CORE-31
//
// Sprite requests (ARCH §10.3): raster scale = exportScale × max animated scale, clamped so the
// longer sprite side stays within min(maxTextureSize, 2 × output long side); content keys; which
// items get requests; and how an export plan places the sprite (base from the file and sscale per
// plan px).

import 'package:test/test.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart';

import 'lowering_support.dart';

final MediaAsset vA = asset('md_videoA00001', MediaKind.video);

EditProject scaledTitle({double from = 1, double to = 8, TextAnimation animation = TextAnimation.none}) => project([
      mainLane([clip('it_main0000001', 0, 120, 'md_videoA00001')]),
      lane('tr_text', TrackKind.text, [
        textItem('it_title000001', 0, 90,
            text: 'Big title',
            animation: animation,
            keyframes: keys('transform.scale', [(0, from), (fr(60), to)])),
      ]),
    ], assets: [vA]);

void main() {
  const uhd = Size2(3840, 2160);
  const block = FixedMetrics(Size2(400, 100));

  test('an 8× scale keyframe rasterizes at exportScale × 8 when it fits', () {
    final p = scaledTitle();
    expect(maxAnimatedScale(p.tracks[1].items.single as TextItem), 8);
    // 1080p project → 4K output: exportScale 2; 400 px × 16 = 6400 ≤ min(16384, 7680).
    final r = collectSpriteRequests(p, uhd, 2, maxTextureSize: 16384, metrics: block).single;
    expect(r.scale, 16);
    expect((r.canvasWidth, r.canvasHeight), (3840, 2160));
    expect(r.source, SpriteSource.text);
  });

  test('… and is clamped at maxTextureSize 4096', () {
    final r = collectSpriteRequests(scaledTitle(), uhd, 2, maxTextureSize: 4096, metrics: block).single;
    expect(r.scale, 4096 / 400);
    expect(400 * r.scale, 4096);
  });

  test('… and at twice the output long side when that is smaller', () {
    // 1080p output: limit min(4096, 3840) = 3840.
    const wide = FixedMetrics(Size2(600, 100));
    final r = collectSpriteRequests(scaledTitle(), const Size2(1920, 1080), 1, maxTextureSize: 4096, metrics: wide).single;
    expect(r.scale, 3840 / 600);
  });

  test('keys out of range and static scale; text animations never raise the maximum', () {
    final item = textItem('it_t', 0, 30,
        transform: const Transform2D(scale: 2),
        keyframes: keys('transform.scale', [(-1000, 8), (fr(30), 8)]),
        animation: TextAnimation(inKind: TextAnimKind.scale, inDuration: fr(10)));
    expect(maxAnimatedScale(item), 2, reason: 'keys outside [0, duration) are ignored');
  });

  test('the estimate stands in for metrics (conservative block size)', () {
    final spec = textLayoutSpecOf(textItem('it_t', 0, 30, text: 'Line one\nLine two'), const CanvasSpec());
    final est = estimateTextBlockSize(spec);
    expect(est.height, closeTo(2 * 1.2 * 48, 1e-9));
    expect(est.width, closeTo(8 * 48 * estimatedAdvanceEm, 1e-9));
    final r = collectSpriteRequests(scaledTitle(), uhd, 2, maxTextureSize: 4096).single;
    final b = estimateTextBlockSize(textLayoutSpecOf(scaledTitle().tracks[1].items.single as TextItem, const CanvasSpec()));
    expect(b.longSide * r.scale, lessThanOrEqualTo(4096 + 1e-9));
  });

  test('keys are content keys: equal content shares a key, any input change makes a new one', () {
    final p = scaledTitle();
    final a = collectSpriteRequests(p, uhd, 2).single;
    expect(collectSpriteRequests(p, uhd, 2).single.key, a.key);
    expect(collectSpriteRequests(p, uhd, 2, fontsVersion: 2).single.key, isNot(a.key));
    expect(collectSpriteRequests(p, const Size2(1920, 1080), 1).single.key, isNot(a.key));
    final typed = scaledTitle(animation: TextAnimation(inKind: TextAnimKind.typewriter, inDuration: fr(10)));
    final t = collectSpriteRequests(typed, uhd, 2).single;
    expect(t.reveal, isTrue);
    expect(t.key, isNot(a.key));
    expect(a.key, matches(RegExp(r'^[0-9a-f]{40}$')));
  });

  test('requests cover visible text lanes and burned subtitle tracks only', () {
    final p = project([
      mainLane([clip('it_main0000001', 0, 120, 'md_videoA00001')]),
      lane('tr_text', TrackKind.text, [textItem('it_t1', 0, 30)]),
      lane('tr_hidden', TrackKind.text, [textItem('it_t2', 0, 30)], hidden: true),
      lane('tr_sub_on', TrackKind.subtitle, [cue('it_c1', 0, 30, 'a'), cue('it_c2', 30, 60, 'b')], subtitle: const SubtitleTrackData()),
      lane('tr_sub_off', TrackKind.subtitle, [cue('it_c3', 0, 30, 'c')], subtitle: const SubtitleTrackData(burnIn: false)),
    ], assets: [vA]);
    List<String> ids(Map<TrackId, bool> burnIn) =>
        [for (final r in collectSpriteRequests(p, const Size2(1920, 1080), 1, burnIn: burnIn)) r.itemId];
    expect(ids(const {}), ['it_t1', 'it_c1', 'it_c2']);
    expect(ids({const TrackId('tr_sub_on'): false, const TrackId('tr_sub_off'): true}), ['it_t1', 'it_c3']);
  });

  test('export plan: sprite asset sscale per plan px and base from the file', () {
    final p = scaledTitle();
    final requests = collectSpriteRequests(p, uhd, 2, maxTextureSize: 4096, metrics: block);
    final manifest = fakeManifest(requests, metrics: block);
    final c = compilePlan(p, PlanTarget.export, resolverFor(p),
        options: CompileOptions(
          output: const PlanOutputSpec(width: 3840, height: 2160, fps: 30),
          stages: [TextLoweringStage(sprites: manifest, requests: requests)],
        ));
    expect(c.violations(), isEmpty);
    final l = c.plan.layers.firstWhere((l) => l.id == 'it_title000001#v');
    final a = c.plan.assets[l.asset]!;
    expect(a.sw, 4096);
    expect(a.sscale, closeTo(4096 / 400 / 2, 1e-12), reason: 'sprite px per plan px');
    expect(l.base!.w, closeTo(800, 1e-9), reason: '400 layout px × exportScale 2');
    expect(l.base!.h, closeTo(200, 1e-9));
    expect(l.anim[PlanChannels.xfS], [const AnimKey(0, 1), AnimKey(fr(60), 8)]);
  });
}
