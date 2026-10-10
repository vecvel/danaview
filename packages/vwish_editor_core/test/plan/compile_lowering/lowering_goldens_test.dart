// OWNER: CORE-31
//
// One compile golden per transition kind and direction, per text animation, for burn-in on and
// off, and for the audio rows of ARCH §11.7. Each case pins `compile(project) ==
// goldens/<name>.json` byte for byte (canonical JSON), checks the lowering explicitly (so a
// golden cannot silently encode a wrong value) and validates the plan with CORE-29's validator.
//
// Regenerate after an intended change with `VWISH_UPDATE_GOLDENS=1 dart test <this file>` and
// review the diff.

import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart';

import 'lowering_support.dart';

const double w = 1920;
const double h = 1080;

final MediaAsset vA = asset('md_videoA00001', MediaKind.video);
final MediaAsset vB = asset('md_videoB00001', MediaKind.video);
final MediaAsset music = asset('md_music000001', MediaKind.audio, w: null, h: null, duration: 60000000);
final MediaAsset photo = asset('md_photo000001', MediaKind.image, w: 4000, h: 3000);

/// The cut is at frame 60 (2 s); 10-frame transitions cover frames [55, 65).
final TimeUs cut = fr(60);
final TimeUs w0 = fr(55);
final TimeUs w1 = fr(65);

/// Two touching main-lane clips with 2 s / 3 s of handle and a transition between them.
EditProject transitionProject(TransitionKind kind, {TransitionDirection? direction, ProjectSettings settings = const ProjectSettings()}) {
  final main = mainLane([
    clip('it_left0000001', 0, 60, 'md_videoA00001', sourceIn: 2000000),
    clip('it_right000001', 60, 120, 'md_videoB00001', sourceIn: 3000000),
  ]).copyWith(transitions: [transition('tn_0000000001', 'it_left0000001', 'it_right000001', kind, 10, direction: direction)]);
  return project([main], assets: [vA, vB], settings: settings);
}

PlanLayer layer(RenderPlan p, String id) => p.layers.firstWhere((l) => l.id == id, orElse: () => fail('no layer $id'));

AudioSeg seg(RenderPlan p, String id) => p.audio.firstWhere((a) => a.id == id, orElse: () => fail('no audio $id'));

double at(List<AnimKey> keys, TimeUs t) => evaluateAnimKeys(keys, t);

/// One golden.
final class LoweringCase {
  LoweringCase(this.name, this.compile, this.check);
  final String name;
  final CompiledPlan Function() compile;
  final void Function(CompiledPlan c) check;
}

List<LoweringCase> cases() {
  final out = <LoweringCase>[];

  // --- Transitions ---------------------------------------------------------------------------
  out.add(LoweringCase('transition_fade', () => compileStd(transitionProject(TransitionKind.fade), PlanTarget.preview), (c) {
    final l = layer(c.plan, 'it_left0000001#v');
    final r = layer(c.plan, 'it_right000001#v');
    expect((l.t0, l.t1, r.t0, r.t1), (0, cut, cut, fr(120)), reason: 'fade does not extend');
    expect(l.anim[PlanChannels.xfOp], [AnimKey(w0, 1), AnimKey(cut, 0)]);
    expect(r.anim[PlanChannels.xfOp], [AnimKey(cut, 0), AnimKey(w1, 1)]);
    // Audio dips the same way.
    expect(at(seg(c.plan, 'it_left0000001#a').gain, w0), 1);
    expect(at(seg(c.plan, 'it_left0000001#a').gain, cut), 0);
    expect(at(seg(c.plan, 'it_right000001#a').gain, cut), 0);
    expect(at(seg(c.plan, 'it_right000001#a').gain, w1), 1);
  }));

  out.add(LoweringCase('transition_cross_dissolve', () => compileStd(transitionProject(TransitionKind.crossDissolve), PlanTarget.preview), (c) {
    final l = layer(c.plan, 'it_left0000001#v');
    final r = layer(c.plan, 'it_right000001#v');
    expect((l.t1, r.t0), (w1, w0), reason: 'both extended over the window');
    expect(l.map.last.s1, 2000000 + (w1 - 0), reason: 'left handle at the edge speed (1×)');
    expect(r.map.first.s0, 3000000 - (cut - w0), reason: 'right handle before sourceIn');
    expect(r.anim[PlanChannels.xfOp], [AnimKey(w0, 0), AnimKey(w1, 1)]);
    expect(l.anim.containsKey(PlanChannels.xfOp), isFalse);
    expect(c.plan.layers.indexOf(r), greaterThan(c.plan.layers.indexOf(l)), reason: 'incoming on top');
    expect(r.seq, isNot(l.seq), reason: 'overlapping media layers take two slots');
    // Equal-power crossfade, ≤ 0.1 dB from cos/sin.
    final ga = seg(c.plan, 'it_left0000001#a').gain;
    final gb = seg(c.plan, 'it_right000001#a').gain;
    for (var t = w0; t <= w1; t += 1000) {
      final x = (t - w0) / (w1 - w0);
      final eo = math.cos(math.pi / 2 * x);
      final ei = math.sin(math.pi / 2 * x);
      if (eo > 1e-3) expect(20 * math.log(at(ga, t) / eo) / math.ln10, closeTo(0, 0.1));
      if (ei > 1e-3) expect(20 * math.log(at(gb, t) / ei) / math.ln10, closeTo(0, 0.1));
    }
  }));

  for (final kind in [TransitionKind.dipToBlack, TransitionKind.dipToWhite]) {
    out.add(LoweringCase('transition_${kind == TransitionKind.dipToBlack ? 'dip_to_black' : 'dip_to_white'}',
        () => compileStd(transitionProject(kind), PlanTarget.preview), (c) {
      final tx = layer(c.plan, 'it_left0000001#tx0');
      expect(tx.kind, PlanLayerKind.solid);
      expect(tx.z, 15);
      expect(tx.color, kind == TransitionKind.dipToBlack ? 0xFF000000 : 0xFFFFFFFF);
      expect((tx.t0, tx.t1), (w0, w1));
      expect(tx.base, const PlanSize(w, h));
      expect(tx.anim[PlanChannels.xfOp], [AnimKey(w0, 0), AnimKey(cut, 1), AnimKey(w1, 0)]);
      expect(layer(c.plan, 'it_left0000001#v').t1, cut, reason: 'no overlap');
      expect(layer(c.plan, 'it_right000001#v').t0, cut);
    }));
  }

  for (final d in [TransitionDirection.left, TransitionDirection.right, TransitionDirection.up, TransitionDirection.down]) {
    out.add(LoweringCase('transition_slide_${d.name}', () => compileStd(transitionProject(TransitionKind.slide, direction: d), PlanTarget.preview), (c) {
      final l = layer(c.plan, 'it_left0000001#v');
      final r = layer(c.plan, 'it_right000001#v');
      expect((l.t1, r.t0), (w1, w0));
      final horizontal = d == TransitionDirection.left || d == TransitionDirection.right;
      final ch = horizontal ? PlanChannels.xfCx : PlanChannels.xfCy;
      final centre = horizontal ? w / 2 : h / 2;
      final dist = horizontal ? w : h;
      final sign = d == TransitionDirection.left || d == TransitionDirection.up ? -1 : 1;
      expect(l.anim[ch]!.length, 9, reason: '8 linear segments');
      expect(at(l.anim[ch]!, w0), centre);
      expect(at(l.anim[ch]!, w1), centre + sign * dist, reason: 'outgoing leaves along the direction');
      expect(at(r.anim[ch]!, w0), centre - sign * dist, reason: 'incoming enters from the opposite side');
      expect(at(r.anim[ch]!, w1), centre);
      // Ease-in-out cubic at the window's midpoint sample.
      final mid = slideSampleTimes(w0, w1)[4];
      expect(at(r.anim[ch]!, mid), closeTo(centre - sign * dist * (1 - easeInOutCubic((mid - w0) / (w1 - w0))), 1e-9));
    }));
  }

  for (final d in [TransitionDirection.left, TransitionDirection.right, TransitionDirection.up, TransitionDirection.down]) {
    out.add(LoweringCase('transition_wipe_${d.name}', () => compileStd(transitionProject(TransitionKind.wipe, direction: d), PlanTarget.preview), (c) {
      final l = layer(c.plan, 'it_left0000001#v');
      final r = layer(c.plan, 'it_right000001#v');
      expect((l.t1, r.t0), (w1, w0));
      expect(l.cmasks, isEmpty);
      final m = r.cmasks.single;
      final horizontal = d == TransitionDirection.left || d == TransitionDirection.right;
      final f = 0.02 * (horizontal ? w : h);
      expect(m.feather, f);
      final key = horizontal ? 'cx' : 'cy';
      final half = (horizontal ? m.w : m.h) / 2;
      final from = m.anim[key]!.first.v;
      final to = m.anim[key]!.last.v;
      // At w0 the rect lies entirely beyond the far edge (nothing visible); at w1 it covers.
      final size = horizontal ? w : h;
      switch (d) {
        case TransitionDirection.left || TransitionDirection.up:
          expect(from - half, closeTo(size + f, 1e-9));
          expect(to - half, closeTo(-f, 1e-9));
        default:
          expect(from + half, closeTo(-f, 1e-9));
          expect(to + half, closeTo(size + f, 1e-9));
      }
      expect(m.anim[key]!.map((k) => k.tUs), [w0, w1]);
    }));
  }

  for (final d in [TransitionDirection.zoomIn, TransitionDirection.zoomOut]) {
    out.add(LoweringCase('transition_zoom_${d == TransitionDirection.zoomIn ? 'in' : 'out'}',
        () => compileStd(transitionProject(TransitionKind.zoom, direction: d), PlanTarget.preview), (c) {
      final l = layer(c.plan, 'it_left0000001#v');
      final r = layer(c.plan, 'it_right000001#v');
      expect((l.t1, r.t0), (w1, w0));
      final zin = d == TransitionDirection.zoomIn;
      expect(l.anim[PlanChannels.xfS], [AnimKey(w0, 1), AnimKey(w1, zin ? 1.25 : 0.8)]);
      expect(r.anim[PlanChannels.xfS], [AnimKey(w0, zin ? 0.8 : 1.25), AnimKey(w1, 1)]);
      expect(l.anim[PlanChannels.xfOp], [AnimKey(w0, 1), AnimKey(w1, 0)]);
      expect(r.anim[PlanChannels.xfOp], [AnimKey(w0, 0), AnimKey(w1, 1)]);
    }));
  }

  // Helper channels × user keyframes: opacity multiplies on a merged breakpoint set.
  out.add(LoweringCase('transition_merged_keyframes', () {
    final main = mainLane([
      clip('it_left0000001', 0, 60, 'md_videoA00001', sourceIn: 2000000),
      clip('it_right000001', 60, 120, 'md_videoB00001',
          sourceIn: 3000000, keyframes: keys('transform.opacity', [(0, 0.5), (fr(30), 1.0)])),
    ]).copyWith(transitions: [transition('tn_0000000001', 'it_left0000001', 'it_right000001', TransitionKind.crossDissolve, 10)]);
    return compileStd(project([main], assets: [vA, vB]), PlanTarget.preview);
  }, (c) {
    final r = layer(c.plan, 'it_right000001#v');
    final op = r.anim[PlanChannels.xfOp]!;
    // user(t) holds 0.5 before the clip start (t = 60 frames), so the product is 0.5·x over [w0, cut].
    for (var k = 55; k <= 65; k++) {
      final t = fr(k);
      final x = (t - w0) / (w1 - w0);
      final user = t <= cut ? 0.5 : 0.5 + 0.5 * (t - cut) / (fr(90) - cut);
      expect(at(op, t), closeTo(user * x, 1e-12), reason: 'frame $k');
    }
    expect(at(op, fr(90)), 1);
  }));

  // --- Text animations (export only) ---------------------------------------------------------
  EditProject textProject(TextAnimation a, {KeyframeSet keyframes = KeyframeSet.empty, String text = 'Hello'}) => project([
        mainLane([clip('it_main0000001', 0, 120, 'md_videoA00001')]),
        lane('tr_text', TrackKind.text, [textItem('it_text0000001', 15, 105, text: text, animation: a, keyframes: keyframes)]),
      ], assets: [vA]);
  final inD = fr(15);
  final outD = fr(15);
  final s = fr(15);
  final e = fr(105);

  out.add(LoweringCase('text_fade',
      () => compileStd(textProject(TextAnimation(inKind: TextAnimKind.fade, inDuration: inD, outKind: TextAnimKind.fade, outDuration: outD)), PlanTarget.export),
      (c) {
    final l = layer(c.plan, 'it_text0000001#v');
    expect(l.kind, PlanLayerKind.sprite);
    expect(l.z, 20010);
    final op = l.anim[PlanChannels.xfOp]!;
    expect((at(op, s), at(op, s + inD), at(op, e - outD), at(op, e)), (0, 1, 1, 0));
    expect(op.length, 14, reason: '7 in + 7 out samples');
  }));

  for (final dir in TextSlideDirection.values) {
    out.add(LoweringCase('text_slide_${dir.name}',
        () => compileStd(textProject(TextAnimation(inKind: TextAnimKind.slide, inDirection: dir, inDuration: inD, outKind: TextAnimKind.slide, outDirection: dir, outDuration: outD)), PlanTarget.export),
        (c) {
      final l = layer(c.plan, 'it_text0000001#v');
      final dist = 0.1 * 1080;
      final v = slideVector(dir);
      final cx = l.anim[PlanChannels.xfCx];
      final cy = l.anim[PlanChannels.xfCy];
      final ch = v.dx != 0 ? cx! : cy!;
      final centre = v.dx != 0 ? w / 2 : h / 2;
      final sign = v.dx != 0 ? v.dx : v.dy;
      expect(at(ch, s), closeTo(centre + sign * dist, 1e-9));
      expect(at(ch, s + inD), centre);
      expect(at(ch, e), closeTo(centre + sign * dist, 1e-9));
      expect(v.dx != 0 ? cy : cx, isNull, reason: 'only the slide axis animates');
      expect(at(l.anim[PlanChannels.xfOp]!, s), 0);
    }));
  }

  out.add(LoweringCase('text_scale',
      () => compileStd(textProject(TextAnimation(inKind: TextAnimKind.scale, inDuration: inD)), PlanTarget.export), (c) {
    final l = layer(c.plan, 'it_text0000001#v');
    final sc = l.anim[PlanChannels.xfS]!;
    expect((at(sc, s), at(sc, s + inD), at(sc, e)), (0.6, 1, 1));
    // The plan reproduces evaluateTextAnimation at every frame of the in phase.
    final item = textItem('it_text0000001', 15, 105, animation: TextAnimation(inKind: TextAnimKind.scale, inDuration: inD));
    for (var k = 15; k <= 30; k++) {
      expect(at(sc, fr(k)), closeTo(evaluateTextAnimation(item, fr(k), const CanvasSpec()).scale, 1e-12));
    }
  }));

  out.add(LoweringCase('text_typewriter',
      () => compileStd(textProject(TextAnimation(inKind: TextAnimKind.typewriter, inDuration: inD), text: 'Hello 👋🏽'), PlanTarget.export),
      (c) {
    final l = layer(c.plan, 'it_text0000001#v');
    final asset = c.plan.assets[l.asset]!;
    expect(asset.reveal, isTrue);
    expect(l.anim[PlanChannels.reveal], [AnimKey(s, 0), AnimKey(s + inD, 7)], reason: '7 grapheme clusters');
    expect(l.anim.containsKey(PlanChannels.xfOp), isFalse);
  }));

  out.add(LoweringCase('text_keyframes_with_animation', () {
    return compileStd(
        textProject(TextAnimation(inKind: TextAnimKind.fade, inDuration: inD),
            keyframes: KeyframeSet({
              'transform.opacity': KeyframeTrack([const Keyframe(0, 0.5), Keyframe(fr(30), 1)]),
              'transform.position.x': KeyframeTrack([const Keyframe(0, -0.25), Keyframe(fr(60), 0.25)]),
            })),
        PlanTarget.export);
  }, (c) {
    final l = layer(c.plan, 'it_text0000001#v');
    final op = l.anim[PlanChannels.xfOp]!;
    final item = textItem('it_text0000001', 15, 105, animation: TextAnimation(inKind: TextAnimKind.fade, inDuration: inD));
    for (var k = 15; k <= 45; k++) {
      final t = fr(k);
      final user = 0.5 + 0.5 * ((t - s) / fr(30)).clamp(0, 1);
      expect(at(op, t), closeTo(user * evaluateTextAnimation(item, t, const CanvasSpec()).opacity, 1e-9), reason: 'frame $k');
    }
    expect(at(l.anim[PlanChannels.xfCx]!, s), w / 2 - 0.25 * w);
  }));

  // --- Burned subtitles ----------------------------------------------------------------------
  EditProject subtitleProject() => project([
        mainLane([clip('it_main0000001', 0, 120, 'md_videoA00001')]),
        lane('tr_sub_bottom', TrackKind.subtitle, [cue('it_cue00000001', 0, 30, 'Hi <i>there</i>'), cue('it_cue00000002', 45, 90, 'Two\nlines')],
            subtitle: const SubtitleTrackData()),
        lane('tr_sub_top', TrackKind.subtitle, [cue('it_cue00000003', 30, 60, 'Top')],
            subtitle: const SubtitleTrackData(position: SubtitlePosition.top)),
      ], assets: [vA]);

  out.add(LoweringCase('burn_in_on', () => compileStd(subtitleProject(), PlanTarget.export), (c) {
    final c1 = layer(c.plan, 'it_cue00000001#c');
    final c3 = layer(c.plan, 'it_cue00000003#c');
    expect((c1.z, c3.z), (30010, 30020));
    expect(c1.xf.cx, isNull, reason: 'horizontally centred');
    // Bottom: the sprite's bottom edge sits 6% of the height above the canvas bottom.
    expect(c1.xf.cy! + c1.base!.h / 2, closeTo(h - 0.06 * h, 1e-9));
    expect(c3.xf.cy! - c3.base!.h / 2, closeTo(0.06 * h, 1e-9));
    expect(c.violations(), isEmpty);
  }));

  out.add(LoweringCase('burn_in_off', () {
    final p = subtitleProject();
    return compileStd(p, PlanTarget.export, burnIn: {const TrackId('tr_sub_bottom'): false});
  }, (c) {
    expect(c.plan.layers.map((l) => l.id), ['it_main0000001#v', 'it_cue00000003#c']);
  }));

  out.add(LoweringCase('preview_has_no_sprites', () => compileStd(subtitleProject(), PlanTarget.preview), (c) {
    expect(c.plan.layers.map((l) => l.id), ['it_main0000001#v']);
  }));

  // --- Audio ---------------------------------------------------------------------------------
  out.add(LoweringCase('audio_volume_200_fades', () {
    return compileStd(
        project([
          mainLane([clip('it_main0000001', 0, 300, 'md_videoA00001')]),
          lane('tr_music', TrackKind.audio, [
            audioClip('it_music000001', 0, 300, 'md_music000001', audio: AudioProps(volume: 2, fadeIn: fr(30), fadeOut: fr(60))),
          ]),
        ], assets: [vA, music]),
        PlanTarget.preview);
  }, (c) {
    final g = seg(c.plan, 'it_music000001#a').gain;
    expect(at(g, fr(150)), 2, reason: '200% = +6.02 dB');
    expect(20 * math.log(at(g, fr(150))) / math.ln10, closeTo(6.02, 0.01));
    expect(g, [AnimKey(0, 0), AnimKey(fr(30), 2), AnimKey(fr(240), 2), AnimKey(fr(300), 0)], reason: 'linear products need no extra samples');
    final main = seg(c.plan, 'it_main0000001#a');
    expect(main.gain, [const AnimKey(0, 1)], reason: 'constant envelope is one key');
    expect(main.asset, 'md_videoA00001');
  }));

  out.add(LoweringCase('audio_volume_keys_times_fade', () {
    return compileStd(
        project([
          mainLane([clip('it_main0000001', 0, 90, 'md_videoA00001')]),
          lane('tr_music', TrackKind.audio, [
            audioClip('it_music000001', 0, 90, 'md_music000001',
                audio: AudioProps(fadeIn: fr(30)), keyframes: keys('audio.volume', [(0, 0.2), (fr(30), 2.0)])),
          ]),
        ], assets: [vA, music]),
        PlanTarget.preview);
  }, (c) {
    final g = seg(c.plan, 'it_music000001#a').gain;
    // Two linear factors vary over [0, 1 s]: sampled every 20 ms at least, within 0.1 dB.
    final inside = g.where((k) => k.tUs > 0 && k.tUs < fr(30)).length;
    expect(inside, greaterThanOrEqualTo(49));
    for (var t = 1000; t < fr(30); t += 997) {
      final exact = (0.2 + 1.8 * t / fr(30)) * (t / fr(30));
      if (exact > 1e-3) expect((20 * math.log(at(g, t) / exact) / math.ln10).abs(), lessThanOrEqualTo(0.1));
    }
  }));

  out.add(LoweringCase('audio_mute_solo_preview', () {
    return compileStd(
        project([
          mainLane([clip('it_main0000001', 0, 60, 'md_videoA00001')]),
          lane('tr_music', TrackKind.audio, [audioClip('it_music000001', 0, 60, 'md_music000001')], solo: true),
          lane('tr_fx', TrackKind.audio, [audioClip('it_fx0000000001', 0, 60, 'md_music000001')]),
        ], assets: [vA, music]),
        PlanTarget.preview);
  }, (c) {
    expect(seg(c.plan, 'it_music000001#a').gain, [const AnimKey(0, 1)]);
    expect(seg(c.plan, 'it_fx0000000001#a').gain, [const AnimKey(0, 0)], reason: 'soloed out: silent, kept (param-only toggle)');
    expect(seg(c.plan, 'it_main0000001#a').gain, [const AnimKey(0, 0)]);
  }));

  out.add(LoweringCase('audio_mute_solo_export', () {
    return compileStd(
        project([
          mainLane([clip('it_main0000001', 0, 60, 'md_videoA00001')]),
          lane('tr_music', TrackKind.audio, [audioClip('it_music000001', 0, 60, 'md_music000001')], solo: true),
          lane('tr_fx', TrackKind.audio, [audioClip('it_fx0000000001', 0, 60, 'md_music000001')]),
        ], assets: [vA, music]),
        PlanTarget.export);
  }, (c) {
    expect(c.plan.audio.map((a) => a.id), ['it_music000001#a'], reason: 'export omits silent segments');
  }));

  out.add(LoweringCase('audio_speed_above_max_muted', () {
    return compileStd(
        project([
          mainLane([clip('it_fast00000001', 0, 30, 'md_videoA00001', speed: const ConstantSpeed(5))]),
          lane('tr_music', TrackKind.audio, [audioClip('it_music000001', 0, 30, 'md_music000001', speed: const ConstantSpeed(2), maintainPitch: false)]),
        ], assets: [vA, music]),
        PlanTarget.preview);
  }, (c) {
    expect(seg(c.plan, 'it_fast00000001#a').gain, [const AnimKey(0, 0)], reason: '5× > maxAudioSpeed 4×');
    final m = seg(c.plan, 'it_music000001#a');
    expect(m.gain, [const AnimKey(0, 1)]);
    expect(m.pitch, isFalse);
    expect(m.map.single.rate, 2);
  }));

  return out;
}

void main() {
  final dir = Directory('test/plan/compile_lowering/goldens');
  for (final k in cases()) {
    test(k.name, () {
      final c = k.compile();
      expect(c.violations(), isEmpty, reason: '${c.violations()}');
      k.check(c);
      final file = File('${dir.path}/${k.name}.json');
      final text = canonical(c.plan);
      if (updateGoldens || !file.existsSync()) {
        dir.createSync(recursive: true);
        file.writeAsStringSync(text);
        if (!updateGoldens) fail('golden ${file.path} was missing and has been written; rerun');
      }
      expect(text, file.readAsStringSync(), reason: 'golden ${k.name} differs (VWISH_UPDATE_GOLDENS=1 to accept)');
    });
  }
}
