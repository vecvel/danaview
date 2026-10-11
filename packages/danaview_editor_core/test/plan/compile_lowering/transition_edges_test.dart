// OWNER: CORE-31
//
// Transition lowering edge cases: one-frame windows, image and offline clips (no map), pending
// stills (hold layers extended), overlay lanes, hidden lanes, letterboxed exports and the window
// arithmetic shared with CORE-36's packing inputs.

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import 'lowering_support.dart';

final MediaAsset vA = asset('md_videoA00001', MediaKind.video);
final MediaAsset vB = asset('md_videoB00001', MediaKind.video);
final MediaAsset photo = asset('md_photo000001', MediaKind.image, w: 4000, h: 3000);

EditProject pair(String a, String b, TransitionKind kind, int n, {TrackKind lane = TrackKind.video, List<MediaAsset>? assets, bool hidden = false}) {
  final items = [clip('it_a', 0, 60, a, sourceIn: 2000000), clip('it_b', 60, 120, b, sourceIn: 3000000)];
  final t = [transition('tn_1', 'it_a', 'it_b', kind, n)];
  final tracks = lane == TrackKind.video
      ? [mainLane(items, hidden: hidden).copyWith(transitions: t)]
      : [mainLane(const []), Track(id: const TrackId('tr_ov'), kind: TrackKind.overlay, items: items, transitions: t, hidden: hidden)];
  return project(tracks, assets: assets ?? [vA, vB, photo]);
}

PlanLayer layer(RenderPlan p, String id) => p.layers.firstWhere((l) => l.id == id);

void main() {
  test('one-frame fade and dip: the window is [cut, cut + 1 frame)', () {
    final fade = compileStd(pair('md_videoA00001', 'md_videoB00001', TransitionKind.fade, 1), PlanTarget.preview);
    expect(fade.violations(), isEmpty);
    expect(layer(fade.plan, 'it_a#v').anim, isEmpty);
    expect(layer(fade.plan, 'it_b#v').anim[PlanChannels.xfOp], [AnimKey(fr(60), 0), AnimKey(fr(61), 1)]);
    final dip = compileStd(pair('md_videoA00001', 'md_videoB00001', TransitionKind.dipToWhite, 1), PlanTarget.preview);
    expect(dip.violations(), isEmpty);
    expect(layer(dip.plan, 'it_a#tx0').anim[PlanChannels.xfOp], [AnimKey(fr(60), 1), AnimKey(fr(61), 0)]);
  });

  test('odd lengths put the extra frame after the cut', () {
    final c = compileStd(pair('md_videoA00001', 'md_videoB00001', TransitionKind.crossDissolve, 7), PlanTarget.preview);
    expect((layer(c.plan, 'it_b#v').t0, layer(c.plan, 'it_a#v').t1), (fr(57), fr(64)));
  });

  test('images extend without a map; overlay lanes use their own z', () {
    final c = compileStd(pair('md_photo000001', 'md_videoA00001', TransitionKind.wipe, 10, lane: TrackKind.overlay), PlanTarget.preview);
    expect(c.violations(), isEmpty);
    final a = layer(c.plan, 'it_a#v');
    expect((a.kind, a.t1), (PlanLayerKind.image, fr(65)));
    expect(a.map, isEmpty);
    expect(layer(c.plan, 'it_b#v').z, 10010);
    expect(layer(c.plan, 'it_b#v').cmasks, hasLength(1));
  });

  test('offline clips (solids) still get the transition', () {
    final p = pair('md_videoA00001', 'md_videoB00001', TransitionKind.zoom, 10);
    final c = compileStd(p, PlanTarget.preview, resolver: resolverFor(p, offline: {'md_videoA00001'}));
    expect(c.violations(), isEmpty);
    final a = layer(c.plan, 'it_a#v');
    expect((a.kind, a.t1), (PlanLayerKind.solid, fr(65)));
    expect(a.anim[PlanChannels.xfS]!.last.v, 1.25);
    expect(c.requirements.offline, ['md_videoA00001']);
    expect(c.plan.audio.map((s) => s.id), ['it_b#a'], reason: 'an offline clip has no audio');
  });

  test('pending stills: the hold layer is re-covered over the extended range', () {
    final still = asset('md_still000001', MediaKind.still,
        w: null, h: null, status: const PendingStatus('job'), derived: const StillSpec(MediaId('md_videoA00001'), 1000000, sourceQuickHash: 'qh_md_videoA00001'));
    final c = compileStd(pair('md_still000001', 'md_videoB00001', TransitionKind.crossDissolve, 10, assets: [vA, vB, still]), PlanTarget.preview);
    expect(c.violations(), isEmpty);
    final a = layer(c.plan, 'it_a#v');
    expect((a.hold, a.t1, a.map.single.t1, a.map.single.s0), (true, fr(65), fr(65), 1000000));
  });

  test('hidden lanes: no layers, no helpers', () {
    final c = compileStd(pair('md_videoA00001', 'md_videoB00001', TransitionKind.dipToBlack, 10, hidden: true), PlanTarget.preview);
    expect(c.plan.layers, isEmpty);
    expect(c.plan.audio, hasLength(2), reason: 'hidden is visual only');
  });

  test('letterboxed export: off-canvas means off the content rect; helpers cover the content', () {
    final p = pair('md_videoA00001', 'md_videoB00001', TransitionKind.slide, 10);
    final c = compileStd(p, PlanTarget.export, output: const PlanOutputSpec(width: 1080, height: 1920, fps: 30));
    expect(c.violations(), isEmpty);
    final b = layer(c.plan, 'it_b#v');
    expect(evaluateAnimKeys(b.anim[PlanChannels.xfCx]!, fr(55)), 540 + 1080, reason: 'enters from the right of the content');
    final dip = compileStd(pair('md_videoA00001', 'md_videoB00001', TransitionKind.dipToBlack, 10), PlanTarget.export,
        output: const PlanOutputSpec(width: 1080, height: 1920, fps: 30));
    final tx = layer(dip.plan, 'it_a#tx0');
    expect(tx.base, const PlanSize(1080, 607.5));
  });

  test('extents agree with CORE-36 packing inputs on random projects', () {
    for (var seed = 0; seed < 5; seed++) {
      final p = pair('md_videoA00001', 'md_videoB00001', TransitionKind.values[seed % 7], 2 + seed);
      final c = compileStd(p, PlanTarget.preview);
      final inputs = {for (final i in packingInputsOf(p)) i.id: i};
      for (final l in c.plan.layers.where((l) => l.kind == PlanLayerKind.media)) {
        expect((inputs[l.id]!.t0, inputs[l.id]!.t1), (l.t0, l.t1));
      }
    }
  });
}
