// OWNER: CORE-13
//
// Fixtures of the property and keyframe tests.

import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../framework/ops_support.dart';

ItemId id(String s) => ItemId(s);

/// A key track with keys at the given frames (item-local, from frame [k0] of the item).
KeyframeTrack track(int k0, List<(int, double)> keys) =>
    KeyframeTrack([for (final (k, v) in keys) Keyframe(f(k0 + k) - f(k0), v)]);

/// The project of the property tests (all on the 30 fps grid):
///
/// * main (video): `it_v` [0,90) md_video (with sound) keyed scale 0f=1, 30f=2, 60f=3, position.x/y
///   0f/60f, volume 0f=1, 60f=0.5; `it_s` [90,150) md_noaudio (silent video);
/// * overlay: `it_p` [0,60) md_image; locked overlay `tr_ovl`: `it_l` [0,60) md_image;
/// * text: `it_t` [0,60) "Title" keyed scale 0f=1, 30f=2; `it_t2` [60,120) "Second";
/// * subtitle: `it_c` [0,30);
/// * audio (music): `it_a` [0,90) md_music keyed volume 0f=0.2, 30f=1.2; `it_a2` [90,150) md_music.
EditProject props({bool rippleEnabled = true}) {
  final v = vclip('it_v', 0, 90).copyWith(
    keyframes: KeyframeSet({
      'transform.scale': track(0, [(0, 1), (30, 2), (60, 3)]),
      'transform.position.x': track(0, [(0, 0), (60, 1)]),
      'transform.position.y': track(0, [(0, 0), (60, -1)]),
      'audio.volume': track(0, [(0, 1), (60, 0.5)]),
    }),
  );
  final t = text('it_t', 0, 60).copyWith(
    keyframes: KeyframeSet({
      'transform.scale': track(0, [(0, 1), (30, 2)])
    }),
  );
  final a = aclip('it_a', 0, 90).copyWith(
      keyframes: KeyframeSet({
    'audio.volume': track(0, [(0, 0.2), (30, 1.2)])
  }));
  return project([
    lane('tr_main', TrackKind.video, [v, vclip('it_s', 90, 60, media: 'md_noaudio')], main: true),
    lane('tr_ov', TrackKind.overlay, [vclip('it_p', 0, 60, media: 'md_image')]),
    lane('tr_ovl', TrackKind.overlay, [vclip('it_l', 0, 60, media: 'md_image')], locked: true),
    lane('tr_txt', TrackKind.text, [t, text('it_t2', 60, 60, value: 'Second')]),
    lane('tr_sub', TrackKind.subtitle, [cue('it_c', 0, 30)]),
    lane('tr_music', TrackKind.audio, [a, aclip('it_a2', 90, 60)], role: AudioRole.music),
  ], view: ViewState(rippleEnabled: rippleEnabled));
}

/// The item [item] of [p].
TimelineItem item(EditProject p, String it) => p.index.locate(ItemId(it))!.item;

MediaClip clip(EditProject p, String it) => item(p, it) as MediaClip;
TextItem textOf(EditProject p, String it) => item(p, it) as TextItem;

/// Applies [c] expecting success and a valid result.
EditOutcome ok(EditProject p, EditCommand c, {int seed = 7}) {
  final out = applyCommand(p, c, ctx(seed: seed));
  if (out.rejection != null) throw StateError('rejected: ${out.rejection} for $c');
  expectValid(out.project, c.toString());
  return out;
}

/// The rejection of [c] on [p] (the project must stay identical).
EditRejection? rejection(EditProject p, EditCommand c) {
  final out = applyCommand(p, c, ctx());
  if (!identical(out.project, p)) throw StateError('a rejection changed the project: $c');
  return out.rejection;
}

/// Key frames (nearest frame of the item-local times) of channel [channel] of [i].
List<(int, double)> keysOf(TimelineItem i, String channel) {
  final set = switch (i) {
    MediaClip(:final keyframes) => keyframes,
    TextItem(:final keyframes) => keyframes,
    _ => KeyframeSet.empty,
  };
  final tr = set[channel];
  if (tr == null) return const [];
  return [for (final k in tr.keys) (rate.frameIndexNearest(i.start + k.t) - rate.frameIndexNearest(i.start), k.v)];
}
