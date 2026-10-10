// OWNER: CORE-31
//
// Properties of the CORE-31 lowering over random valid projects (CORE-08 generator, every lane
// kind, transitions of every kind, ramps, reversed clips, text animations, cues, fades, volume
// keys): compiled plans pass the CORE-29 validator in preview and export; every clip's video
// layer and audio segment share asset, range and map (A/V property, ARCH §11.5); preview plans
// carry no sprites (D-05); export plans carry one sprite layer per text item and burned cue.

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart';

import '../../support/random_project.dart';
import 'lowering_support.dart';

void main() {
  for (var seed = 0; seed < 40; seed++) {
    test('seed $seed: valid plans, A/V boundaries identical, sprites only in export', () {
      final p = randomProject(seed, const RandomProjectSpec(items: 80));
      for (final target in PlanTarget.values) {
        final c = compileStd(p, target);
        expect(c.violations(), isEmpty, reason: '$target ${c.violations()}');
        final layers = {for (final l in c.plan.layers) l.id: l};
        for (final a in c.plan.audio) {
          final v = layers[PlanIds.visual(PlanIds.itemOf(a.id))];
          if (v == null) continue;
          expect(v.kind, PlanLayerKind.media, reason: a.id);
          expect((v.asset, v.t0, v.t1), (a.asset, a.t0, a.t1), reason: a.id);
          expect(v.map, a.map, reason: a.id);
        }
        final sprites = c.plan.layers.where((l) => l.kind == PlanLayerKind.sprite).length;
        if (target == PlanTarget.preview) {
          expect(sprites, 0);
        } else {
          var expected = 0;
          for (final t in p.tracks) {
            if (t.hidden) continue;
            if (t.kind == TrackKind.text) expected += t.items.length;
            if (t.kind == TrackKind.subtitle && (t.subtitle?.burnIn ?? true)) expected += t.items.length;
          }
          expect(sprites, expected);
        }
      }
    });
  }

  test('the random corpus exercises every lowering (coverage guard)', () {
    final kinds = <TransitionKind>{};
    var audio = 0, sprites = 0, reveal = 0, cues = 0, helpers = 0, crossfades = 0;
    for (var seed = 0; seed < 40; seed++) {
      final p = randomProject(seed, const RandomProjectSpec(items: 80));
      for (final t in p.tracks) {
        for (final tr in t.transitions) {
          kinds.add(tr.kind);
        }
      }
      final c = compileStd(p, PlanTarget.export);
      audio += c.plan.audio.length;
      crossfades += c.plan.audio.where((a) => a.gain.length > 20).length;
      for (final l in c.plan.layers) {
        if (l.kind == PlanLayerKind.sprite) sprites++;
        if (l.anim.containsKey(PlanChannels.reveal)) reveal++;
        if (l.id.endsWith('#c')) cues++;
        if (l.id.contains('#tx')) helpers++;
      }
    }
    expect(kinds, TransitionKind.values.toSet());
    expect([audio, sprites, reveal, cues, helpers, crossfades].every((n) => n > 0), isTrue,
        reason: 'audio $audio sprites $sprites reveal $reveal cues $cues helpers $helpers crossfades $crossfades');
  });

  test('letterboxed exports (9:16 and 4:5 outputs of random projects) are valid', () {
    for (var seed = 0; seed < 12; seed++) {
      final p = randomProject(seed, const RandomProjectSpec(items: 60));
      for (final out in const [PlanOutputSpec(width: 1080, height: 1920, fps: 30), PlanOutputSpec(width: 1080, height: 1350, fps: 60)]) {
        final c = compileStd(p, PlanTarget.export, output: out);
        expect(c.violations(), isEmpty, reason: 'seed $seed $out ${c.violations()}');
        expect(c.plan.canvas.gridFps, p.settings.frameRate.num);
      }
    }
  });

  test('hidden visual lanes still play their audio, extended like the picture would be', () {
    for (var seed = 0; seed < 40; seed++) {
      final p = randomProject(seed, const RandomProjectSpec(items: 80));
      final hidden = p.copyWith(
          timeline: p.timeline.copyWith(tracks: [
        for (final t in p.tracks) t.kind == TrackKind.video || t.kind == TrackKind.overlay ? t.copyWith(hidden: true) : t,
      ]));
      final shown = compileStd(p, PlanTarget.preview).plan;
      final hid = compileStd(hidden, PlanTarget.preview).plan;
      expect(hid.layers.where((l) => l.z < 20000), isEmpty);
      final a = {for (final s in shown.audio) s.id: s};
      for (final s in hid.audio) {
        final v = a[s.id];
        if (v == null) continue; // the visible lane showed an offline/placeholder picture
        expect((s.asset, s.t0, s.t1), (v.asset, v.t0, v.t1), reason: 'seed $seed ${s.id}');
        expect(s.map, v.map, reason: 'seed $seed ${s.id}');
        expect(s.gain, v.gain, reason: 'seed $seed ${s.id}');
      }
    }
  });
}
