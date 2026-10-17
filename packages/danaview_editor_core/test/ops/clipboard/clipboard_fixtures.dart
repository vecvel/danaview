// OWNER: CORE-11
//
// Fixtures shared by the clipboard tests: a second project (for cross-project pastes, with its
// own, duplicate-content and id-colliding media and a reversed clip with its rendition), a
// keyframed clip, and a three-member link group.

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';

Set<ItemId> ids(List<String> s) => {for (final x in s) ItemId(x)};

/// Another project: its own media (one new, one with md_video2's content under another id, one
/// reusing the id md_video for different content) and a reversed clip with its rendition.
EditProject otherProject({FrameRate frameRate = rate}) {
  final r = frameRate;
  TimeUs g(int k) => r.timeOfFrame(k);
  final pool = MediaPool({
    for (final a in [
      asset('md_other', MediaKind.video, duration: sec(30), hasAudio: true, hash: 'q-other'),
      asset('md_dupe', MediaKind.video, duration: sec(10), hasAudio: true, hash: 'q-md_video2'),
      asset('md_video', MediaKind.video, duration: sec(45), hasAudio: true, hash: 'q-not-the-same'),
      asset('md_rev', MediaKind.video,
          duration: sec(6),
          hash: 'q-rev',
          derived: ReversedSpec(const MediaId('md_other'), TimeRange(0, sec(6)), sourceQuickHash: 'q-other')),
    ])
      a.id: a,
  });
  return EditProject(
    id: const ProjectId('pr_other'),
    meta: ProjectMeta(name: 'Other', createdAt: when, updatedAt: when),
    timeline: Timeline(settings: ProjectSettings(frameRate: r), tracks: [
      Track(id: const TrackId('tr_m2'), kind: TrackKind.video, isMain: true, items: [
        MediaClip(
          id: const ItemId('it_o1'),
          start: g(0),
          duration: g(48) - g(0),
          media: const MediaId('md_other'),
          visual: VisualProps.neutral,
          link: const LinkId('ln_o'),
          audio: AudioProps(fadeIn: g(12)),
          keyframes: KeyframeSet({
            'transform.opacity': KeyframeTrack([Keyframe(0, 0), Keyframe(g(7), 1)]),
          }),
        ),
        MediaClip(id: const ItemId('it_o2'), start: g(48), duration: g(72) - g(48), media: const MediaId('md_dupe'), visual: VisualProps.neutral),
        MediaClip(
            id: const ItemId('it_o3'),
            start: g(72),
            duration: g(96) - g(72),
            media: const MediaId('md_video'),
            sourceIn: sec(5),
            visual: VisualProps.neutral),
        MediaClip(
            id: const ItemId('it_o4'),
            start: g(96),
            duration: g(120) - g(96),
            media: const MediaId('md_other'),
            reversed: true,
            visual: VisualProps.neutral),
      ], transitions: const [
        Transition(id: TransitionId('tx_o'), left: ItemId('it_o1'), right: ItemId('it_o2'), kind: TransitionKind.fade, durationFrames: 6),
      ]),
      Track(id: const TrackId('tr_a2'), kind: TrackKind.audio, audioRole: AudioRole.original, items: [
        MediaClip(id: const ItemId('it_o1_au'), start: g(0), duration: g(48) - g(0), media: const MediaId('md_other'), link: const LinkId('ln_o')),
      ]),
    ]),
    pool: pool,
  );
}

ClipboardPayload otherPayload({FrameRate frameRate = rate}) =>
    copyItems(otherProject(frameRate: frameRate), ids(['it_o1', 'it_o2', 'it_o3', 'it_o4']));

EditProject withKeys() => project([
      lane('tr_main', TrackKind.video, [
        vclip('it_v', 0, 90, keyframes: KeyframeSet({
          'transform.opacity': KeyframeTrack([Keyframe(0, 0.2), Keyframe(f(30), 1)]),
          'audio.volume': KeyframeTrack([Keyframe(0, 1), Keyframe(f(60), 0.5)]),
        }), audio: AudioProps(volume: 0.8, fadeIn: f(5))),
      ], main: true),
      lane('tr_orig', TrackKind.audio, [aclip('it_busy', 30, 30, media: 'md_music')], role: AudioRole.original),
    ]);

EditProject threeLinked() => project([
      lane('tr_main', TrackKind.video, [vclip('it_v', 0, 60, link: 'ln_3')], main: true),
      lane('tr_ov1', TrackKind.overlay, [vclip('it_o', 0, 60, media: 'md_image', link: 'ln_3')]),
      lane('tr_txt', TrackKind.text, [text('it_t', 0, 60, link: 'ln_3')]),
    ]);
