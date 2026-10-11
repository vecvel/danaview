// OWNER: CORE-32
//
// Gesture transients (ARCH §11.2 Transient, §11.8): transientFor(working, item) carries only the
// item's own layers (`#v`, `#bd`) with param fields only, equal to what a full compile of the
// working project gives those layers — transition helper channels included — and nothing for
// items without layers.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import '../../support/random_project.dart';
import '../compile_lowering/lowering_support.dart';

final MediaAsset vA = asset('md_videoA00001', MediaKind.video);
final MediaAsset vB = asset('md_videoB00001', MediaKind.video);

EditProject working({double scale = 1.5}) => project([
      mainLane([
        clip('it_left0000001', 0, 60, 'md_videoA00001', sourceIn: 2000000),
        clip('it_right000001', 60, 120, 'md_videoB00001',
            sourceIn: 3000000, visual: VisualProps(transform: Transform2D(scale: scale, position: const Vec2(0.1, 0)))),
        clip('it_tail0000001', 120, 150, 'md_videoA00001'),
      ]).copyWith(transitions: [
        transition('tn_0000000001', 'it_left0000001', 'it_right000001', TransitionKind.zoom, 10, direction: TransitionDirection.zoomIn),
        transition('tn_0000000002', 'it_right000001', 'it_tail0000001', TransitionKind.dipToBlack, 6),
      ]),
      lane('tr_ov1', TrackKind.overlay, [clip('it_pip00000001', 0, 30, 'md_videoB00001')]),
      lane('tr_text', TrackKind.text, [textItem('it_text0000001', 0, 30)]),
      lane('tr_music', TrackKind.audio, [audioClip('it_music000001', 0, 30, 'md_videoA00001')]),
    ], assets: [vA, vB], settings: const ProjectSettings(background: BlurOfMainBackground(0.3)));

const Set<String> paramKeys = {'id', 'xf', 'crop', 'base', 'fx', 'anim', 'cmasks'};

void main() {
  final options = CompileOptions(stages: standardLoweringStages());

  test('only the item\'s own layers, param fields only, equal to the full compile', () {
    final p = working();
    final t = transientFor(p, const ItemId('it_right000001'), resolverFor(p), options: options)!;
    expect(t.item, 'it_right000001');
    expect(t.layers.map((l) => l.id), ['it_right000001#bd', 'it_right000001#v'], reason: 'no #tx helper, no neighbours');
    final full = compilePlan(p, PlanTarget.preview, resolverFor(p), options: options).plan;
    for (final tl in t.layers) {
      final l = full.layers.firstWhere((x) => x.id == tl.id);
      expect(tl, transientLayerOf(l));
    }
    // The zoom's helper channels are part of the transient.
    final v = t.layers.last;
    expect(v.anim![PlanChannels.xfS]!.first.v, closeTo(1.5 * 0.8, 1e-12));
    // Wire form: no timing fields.
    final json = PlanJson.encodeTransient(t);
    for (final l in (json['layers']! as List<Object?>).cast<Map<String, Object?>>()) {
      expect(paramKeys.containsAll(l.keys), isTrue, reason: '${l.keys}');
    }
    expect(PlanJson.decodeTransient(json), t);
  });

  test('a gesture changes only param fields of the transient', () {
    final a = transientFor(working(scale: 1.5), const ItemId('it_right000001'), resolverFor(working()), options: options)!;
    final b = transientFor(working(scale: 2.5), const ItemId('it_right000001'), resolverFor(working()), options: options)!;
    expect(a.layers.map((l) => l.id), b.layers.map((l) => l.id));
    expect(a.layers.last.xf!.s, 1.5);
    expect(b.layers.last.xf!.s, 2.5);
  });

  test('items without layers in the plan have no transient', () {
    final p = working();
    final r = resolverFor(p);
    expect(transientFor(p, const ItemId('it_text0000001'), r, options: options), isNull, reason: 'text is drawn by the overlay in preview');
    expect(transientFor(p, const ItemId('it_music000001'), r, options: options), isNull);
    expect(transientFor(p, const ItemId('it_nope'), r, options: options), isNull);
    expect(transientFor(p, const ItemId('it_pip00000001'), r, options: options)!.layers.single.id, 'it_pip00000001#v');
  });

  test('random projects: every visual clip\'s transient equals its layers in the full plan', () {
    for (var seed = 0; seed < 10; seed++) {
      final p = randomProject(seed, const RandomProjectSpec(items: 50));
      final r = resolverFor(p);
      final full = compilePlan(p, PlanTarget.preview, r, options: options).plan;
      final byId = {for (final l in full.layers) l.id: l};
      for (final t in p.tracks) {
        if (t.kind != TrackKind.video && t.kind != TrackKind.overlay) continue;
        for (final i in t.items) {
          final tr = transientFor(p, i.id, r, options: options);
          final expected = [
            for (final id in [PlanIds.backdrop(i.id), PlanIds.visual(i.id)])
              if (byId[id] != null) transientLayerOf(byId[id]!),
          ];
          expect(tr?.layers ?? const <TransientLayer>[], expected, reason: 'seed $seed ${i.id}');
        }
      }
    }
  });
}
