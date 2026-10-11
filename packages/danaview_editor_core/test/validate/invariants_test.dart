// OWNER: CORE-08
//
// One failing fixture per invariant check (ARCH §6.9 I1–I9) and a repair test for each: the
// fixture is reported with the expected code, `repair()` returns a project that validates clean
// and names the fix in its warnings.

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

const FrameRate rate = FrameRate.fps30;
TimeUs f(int k) => rate.timeOfFrame(k);
TimeUs frames(int k0, int n) => f(k0 + n) - f(k0);

final DateTime when = DateTime.utc(2026, 10, 9);

MediaAsset asset(String id, MediaKind kind, {TimeUs duration = 0, bool hasAudio = false, int? w = 1920, int? h = 1080}) =>
    MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: id,
      locator: AppRelativeLocator(AppRoot.documents, 'media/$id'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 10, quickHash: 'q$id', duration: duration),
      probe: MediaProbe(kind: kind, duration: duration, hasVideo: w != null, hasAudio: hasAudio, width: w, height: h),
      origin: MediaOrigin.files,
      addedAt: when,
    );

final MediaPool pool = MediaPool({
  const MediaId('md_video'): asset('md_video', MediaKind.video, duration: 60 * microsPerSecond, hasAudio: true),
  const MediaId('md_image'): asset('md_image', MediaKind.image),
  const MediaId('md_music'): asset('md_music', MediaKind.audio, duration: 120 * microsPerSecond, hasAudio: true, w: null, h: null),
  const MediaId('md_lut'): asset('md_lut', MediaKind.lut, w: null, h: null),
});

MediaClip vclip(String id, int k0, int n, {TimeUs sourceIn = 0, String media = 'md_video', LinkId? link}) => MediaClip(
      id: ItemId(id),
      start: f(k0),
      duration: frames(k0, n),
      media: MediaId(media),
      sourceIn: sourceIn,
      visual: VisualProps.neutral,
      link: link,
    );

MediaClip aclip(String id, int k0, int n, {String media = 'md_music', TimeUs sourceIn = 0, LinkId? link}) => MediaClip(
      id: ItemId(id),
      start: f(k0),
      duration: frames(k0, n),
      media: MediaId(media),
      sourceIn: sourceIn,
      link: link,
    );

/// A valid base: main lane with two touching clips and a cross dissolve, an overlay image, a
/// text item, a subtitle cue, a linked extracted-audio clip and music, two markers.
EditProject base() {
  const link = LinkId('ln_a');
  return EditProject(
    id: const ProjectId('pr_fixture'),
    meta: ProjectMeta(name: 'Fixture', createdAt: when, updatedAt: when),
    timeline: Timeline(
      settings: const ProjectSettings(),
      tracks: [
        Track(
          id: const TrackId('tr_main'),
          kind: TrackKind.video,
          isMain: true,
          items: [
            vclip('it_a', 0, 90, sourceIn: f(30), link: link),
            vclip('it_b', 90, 60, sourceIn: f(300)),
          ],
          transitions: const [
            Transition(id: TransitionId('tx_ab'), left: ItemId('it_a'), right: ItemId('it_b'), kind: TransitionKind.crossDissolve, durationFrames: 10),
          ],
        ),
        Track(id: const TrackId('tr_over'), kind: TrackKind.overlay, items: [vclip('it_img', 30, 30, media: 'md_image')]),
        Track(id: const TrackId('tr_text'), kind: TrackKind.text, items: [
          TextItem(id: const ItemId('it_txt'), start: f(10), duration: frames(10, 40), text: 'Title'),
        ]),
        Track(id: const TrackId('tr_sub'), kind: TrackKind.subtitle, subtitle: const SubtitleTrackData(), items: [
          SubtitleCue(id: const ItemId('it_cue'), start: f(0), duration: frames(0, 45), text: 'Hello'),
        ]),
        Track(id: const TrackId('tr_orig'), kind: TrackKind.audio, audioRole: AudioRole.original, items: [
          aclip('it_a_audio', 0, 90, media: 'md_video', sourceIn: f(30), link: link),
        ]),
        Track(id: const TrackId('tr_music'), kind: TrackKind.audio, audioRole: AudioRole.music, items: [aclip('it_music', 0, 150)]),
      ],
      markers: [Marker(id: const MarkerId('mk_1'), time: f(15)), Marker(id: const MarkerId('mk_2'), time: f(60))],
    ),
    pool: pool,
  );
}

EditProject withTrack(EditProject p, String id, Track Function(Track) update) => p.copyWith(
      timeline: p.timeline.copyWith(tracks: [for (final t in p.tracks) t.id == TrackId(id) ? update(t) : t]),
    );

EditProject withItem(EditProject p, String id, TimelineItem Function(TimelineItem) update) => p.copyWith(
      timeline: p.timeline.copyWith(tracks: [
        for (final t in p.tracks) t.copyWith(items: [for (final i in t.items) i.id == ItemId(id) ? update(i) : i]),
      ]),
    );

EditProject withSettings(EditProject p, ProjectSettings s) => p.copyWith(timeline: p.timeline.copyWith(settings: s));

/// (name, broken project, expected code, expected repair warning code)
typedef Case = (String, EditProject Function(), ViolationCode, String);

final List<Case> cases = [
  // I1
  ('item start off the grid', () => withItem(base(), 'it_img', (i) => (i as MediaClip).copyWith(start: f(30) + 7)), ViolationCode.itemOffGrid, RepairCodes.offGridSnapped),
  ('negative start', () => withItem(base(), 'it_txt', (i) => (i as TextItem).copyWith(start: -f(3), duration: f(3) + f(5))), ViolationCode.itemTooShort, RepairCodes.offGridSnapped),
  ('zero duration', () => withItem(base(), 'it_cue', (i) => (i as SubtitleCue).copyWith(duration: 0)), ViolationCode.itemTooShort, RepairCodes.offGridSnapped),
  ('item beyond 24 h', () => withItem(base(), 'it_txt', (i) {
        final k = rate.frameIndexOf(maxProjectDurationUs) - 2;
        return (i as TextItem).copyWith(start: f(k), duration: frames(k, 10));
      }), ViolationCode.beyondMaxDuration, RepairCodes.offGridSnapped),
  ('keyframe mid-frame', () => withItem(base(), 'it_img', (i) => (i as MediaClip).copyWith(keyframes: KeyframeSet({
        'transform.opacity': KeyframeTrack([Keyframe(f(3) + f(1) ~/ 2, 0.5)]),
      }))), ViolationCode.keyOffGrid, RepairCodes.keyframesRepaired),
  ('marker off the grid', () => base().copyWith(timeline: base().timeline.copyWith(markers: [Marker(id: const MarkerId('mk_1'), time: f(5) + 100)])), ViolationCode.markerOffGrid, RepairCodes.markersRepaired),
  ('negative fade', () => withItem(base(), 'it_music', (i) => (i as MediaClip).copyWith(audio: const AudioProps(fadeIn: -5))), ViolationCode.lengthOffGrid, RepairCodes.valueClamped),
  ('fade mid-frame', () => withItem(base(), 'it_music', (i) => (i as MediaClip).copyWith(audio: AudioProps(fadeOut: f(10) + f(1) ~/ 2))), ViolationCode.lengthOffGrid, RepairCodes.valueClamped),
  ('text animation mid-frame', () => withItem(base(), 'it_txt', (i) => (i as TextItem).copyWith(animation: TextAnimation(inKind: TextAnimKind.fade, inDuration: f(5) + f(1) ~/ 2))), ViolationCode.lengthOffGrid, RepairCodes.offGridSnapped),
  // I2
  ('items unsorted', () => withTrack(base(), 'tr_music', (t) => t.copyWith(items: [aclip('it_m2', 200, 10), aclip('it_music', 0, 150)])), ViolationCode.itemsUnsorted, RepairCodes.itemsSorted),
  ('items overlap', () => withTrack(base(), 'tr_music', (t) => t.copyWith(items: [aclip('it_music', 0, 150), aclip('it_m2', 100, 100)])), ViolationCode.itemsOverlap, RepairCodes.overlapRepaired),
  ('duplicate item id', () => withTrack(base(), 'tr_music', (t) => t.copyWith(items: [aclip('it_music', 0, 150), aclip('it_b', 200, 10)])), ViolationCode.duplicateItemId, RepairCodes.duplicateIdRenamed),
  ('duplicate track id', () => withTrack(base(), 'tr_music', (t) => Track(id: const TrackId('tr_orig'), kind: TrackKind.audio, items: t.items)), ViolationCode.duplicateTrackId, RepairCodes.duplicateIdRenamed),
  ('duplicate transition id', () => withTrack(base(), 'tr_over', (t) => t.copyWith(
        items: [vclip('it_o1', 0, 30), vclip('it_o2', 30, 30, sourceIn: f(200))],
        transitions: const [Transition(id: TransitionId('tx_ab'), left: ItemId('it_o1'), right: ItemId('it_o2'), kind: TransitionKind.fade, durationFrames: 4)],
      )), ViolationCode.duplicateTransitionId, RepairCodes.duplicateIdRenamed),
  ('duplicate marker id', () => base().copyWith(timeline: base().timeline.copyWith(markers: [Marker(id: const MarkerId('mk_1'), time: f(1)), Marker(id: const MarkerId('mk_1'), time: f(2))])), ViolationCode.duplicateMarkerId, RepairCodes.markersRepaired),
  ('markers unsorted', () => base().copyWith(timeline: base().timeline.copyWith(markers: [Marker(id: const MarkerId('mk_1'), time: f(9)), Marker(id: const MarkerId('mk_2'), time: f(2))])), ViolationCode.markersUnsorted, RepairCodes.markersRepaired),
  // I3
  ('text item on a video lane', () => withTrack(base(), 'tr_over', (t) => t.copyWith(items: [
        ...t.items,
        TextItem(id: const ItemId('it_t2'), start: f(100), duration: frames(100, 10), text: 'x'),
      ])), ViolationCode.itemKindMismatch, RepairCodes.itemRelocated),
  ('clip without visual props on a video lane', () => withItem(base(), 'it_img', (i) => (i as MediaClip).copyWith(visual: null)), ViolationCode.itemKindMismatch, RepairCodes.itemKindRepaired),
  ('cue on a text lane', () => withTrack(base(), 'tr_text', (t) => t.copyWith(items: [
        ...t.items,
        SubtitleCue(id: const ItemId('it_c2'), start: f(100), duration: frames(100, 10), text: 'x'),
      ])), ViolationCode.itemKindMismatch, RepairCodes.itemRelocated),
  ('two main tracks', () => withTrack(base(), 'tr_over', (t) => t.copyWith(isMain: true)), ViolationCode.mainTrack, RepairCodes.tracksRepaired),
  ('no main track', () => withTrack(base(), 'tr_main', (t) => t.copyWith(isMain: false)), ViolationCode.mainTrack, RepairCodes.tracksRepaired),
  ('no video track', () => base().copyWith(timeline: base().timeline.copyWith(tracks: base().tracks.where((t) => t.kind != TrackKind.video).toList())), ViolationCode.mainTrack, RepairCodes.tracksRepaired),
  ('band order', () => base().copyWith(timeline: base().timeline.copyWith(tracks: base().tracks.reversed.toList())), ViolationCode.bandOrder, RepairCodes.tracksRepaired),
  // I4
  ('missing media', () => base().copyWith(pool: pool.without({const MediaId('md_image')})), ViolationCode.mediaMissing, RepairCodes.mediaPlaceholderCreated),
  ('audio media on a video lane', () => withTrack(base(), 'tr_over', (t) => t.copyWith(items: [vclip('it_img', 30, 30, media: 'md_music')])), ViolationCode.mediaKindMismatch, RepairCodes.itemRelocated),
  ('LUT media on a lane', () => withTrack(base(), 'tr_over', (t) => t.copyWith(items: [vclip('it_img', 30, 30, media: 'md_lut')])), ViolationCode.mediaKindMismatch, RepairCodes.itemDropped),
  ('look references a missing LUT', () => withItem(base(), 'it_img', (i) => (i as MediaClip).copyWith(visual: const VisualProps(look: ImportedLut(MediaId('md_gone'))))), ViolationCode.mediaMissing, RepairCodes.valueClamped),
  ('negative sourceIn', () => withItem(base(), 'it_b', (i) => (i as MediaClip).copyWith(sourceIn: -1)), ViolationCode.sourceOutOfRange, RepairCodes.sourceRangeClamped),
  ('sourceOut beyond the media', () => withItem(base(), 'it_music', (i) => (i as MediaClip).copyWith(sourceIn: 118 * microsPerSecond)), ViolationCode.sourceOutOfRange, RepairCodes.sourceRangeClamped),
  ('constant speed above 10x', () => withItem(base(), 'it_music', (i) => (i as MediaClip).copyWith(speed: const ConstantSpeed(12))), ViolationCode.speedOutOfRange, RepairCodes.speedRepaired),
  ('invalid ramp', () => withItem(base(), 'it_music', (i) => (i as MediaClip).copyWith(speed: SpeedRamp(const [SpeedPoint(0.2, 1), SpeedPoint(1, 2)]))), ViolationCode.speedOutOfRange, RepairCodes.speedRepaired),
  ('negative audio stream', () => withItem(base(), 'it_music', (i) => (i as MediaClip).copyWith(audioStream: -1)), ViolationCode.audioStreamInvalid, RepairCodes.valueClamped),
  // I5
  ('transition between non-touching clips', () => withTrack(base(), 'tr_main', (t) => t.copyWith(items: [vclip('it_a', 0, 90, sourceIn: f(30), link: const LinkId('ln_a')), vclip('it_b', 95, 60, sourceIn: f(300))])), ViolationCode.transitionNotAdjacent, RepairCodes.transitionDropped),
  ('transition on an audio lane', () => withTrack(base(), 'tr_music', (t) => t.copyWith(
        items: [aclip('it_music', 0, 150), aclip('it_m2', 150, 30)],
        transitions: const [Transition(id: TransitionId('tx_au'), left: ItemId('it_music'), right: ItemId('it_m2'), kind: TransitionKind.fade, durationFrames: 4)],
      )), ViolationCode.transitionNotAdjacent, RepairCodes.transitionDropped),
  ('two transitions on one cut', () => withTrack(base(), 'tr_main', (t) => t.copyWith(transitions: [
        ...t.transitions,
        const Transition(id: TransitionId('tx_ab2'), left: ItemId('it_a'), right: ItemId('it_b'), kind: TransitionKind.fade, durationFrames: 4),
      ])), ViolationCode.transitionDuplicateCut, RepairCodes.transitionDropped),
  ('transition longer than the clips', () => withTrack(base(), 'tr_main', (t) => t.copyWith(transitions: [t.transitions.single.copyWith(kind: TransitionKind.fade, durationFrames: 200)])), ViolationCode.transitionTooLong, RepairCodes.transitionClamped),
  ('overlap transition longer than the handles', () => withItem(base(), 'it_b', (i) => (i as MediaClip).copyWith(sourceIn: f(2))), ViolationCode.transitionTooLong, RepairCodes.transitionClamped),
  ('zero-frame transition', () => withTrack(base(), 'tr_main', (t) => t.copyWith(transitions: [t.transitions.single.copyWith(durationFrames: 0)])), ViolationCode.transitionTooLong, RepairCodes.transitionDropped),
  ('transitions unsorted', () => withTrack(base(), 'tr_main', (t) => t.copyWith(
        items: [...t.items, vclip('it_c', 150, 60, sourceIn: f(600))],
        transitions: [
          const Transition(id: TransitionId('tx_bc'), left: ItemId('it_b'), right: ItemId('it_c'), kind: TransitionKind.fade, durationFrames: 4),
          t.transitions.single,
        ],
      )), ViolationCode.transitionsUnsorted, RepairCodes.itemsSorted),
  // I6
  ('keyframe on a non-keyframable property', () => withItem(base(), 'it_img', (i) => (i as MediaClip).copyWith(keyframes: KeyframeSet({
        'chroma.similarity': KeyframeTrack(const [Keyframe(0, 0.3)]),
      }))), ViolationCode.keyChannelInvalid, RepairCodes.keyframesRepaired),
  ('visual keyframe on an audio clip', () => withItem(base(), 'it_music', (i) => (i as MediaClip).copyWith(keyframes: KeyframeSet({
        'transform.scale': KeyframeTrack(const [Keyframe(0, 1.3)]),
      }))), ViolationCode.keyChannelInvalid, RepairCodes.keyframesRepaired),
  ('empty keyframe track', () => withItem(base(), 'it_img', (i) => (i as MediaClip).copyWith(keyframes: KeyframeSet({'transform.opacity': KeyframeTrack(const [])}))), ViolationCode.keyTrackInvalid, RepairCodes.keyframesRepaired),
  ('unsorted keyframes', () => withItem(base(), 'it_img', (i) => (i as MediaClip).copyWith(keyframes: KeyframeSet({
        'transform.opacity': KeyframeTrack([Keyframe(f(4), 0.2), Keyframe(f(2), 0.8)]),
      }))), ViolationCode.keyTrackInvalid, RepairCodes.keyframesRepaired),
  ('duplicate keyframe time', () => withItem(base(), 'it_img', (i) => (i as MediaClip).copyWith(keyframes: KeyframeSet({
        'transform.opacity': KeyframeTrack([Keyframe(f(4), 0.2), Keyframe(f(4), 0.8)]),
      }))), ViolationCode.keyTrackInvalid, RepairCodes.keyframesRepaired),
  ('keyframe value out of range', () => withItem(base(), 'it_txt', (i) => (i as TextItem).copyWith(keyframes: KeyframeSet({
        'transform.scale': KeyframeTrack(const [Keyframe(0, 20)]),
      }))), ViolationCode.keyValueOutOfRange, RepairCodes.keyframesRepaired),
  ('static value out of range', () => withItem(base(), 'it_img', (i) => PropertyKeys.opacity.write(i, 1.5)), ViolationCode.valueOutOfRange, RepairCodes.valueClamped),
  ('malformed crop', () => withItem(base(), 'it_img', (i) => PropertyKeys.crop.write(i, const CropRect(left: 0.8, right: 0.2))), ViolationCode.valueOutOfRange, RepairCodes.valueClamped),
  ('font size out of range', () => withItem(base(), 'it_txt', (i) => PropertyKeys.fontSize.write(i, 500)), ViolationCode.valueOutOfRange, RepairCodes.valueClamped),
  // I7
  ('link with one member', () => withItem(base(), 'it_a_audio', (i) => (i as MediaClip).copyWith(link: null)), ViolationCode.linkInvalid, RepairCodes.linkRepaired),
  ('link members on one track', () => withItem(base(), 'it_b', (i) => (i as MediaClip).copyWith(link: const LinkId('ln_a'))), ViolationCode.linkInvalid, RepairCodes.linkRepaired),
  // I8
  ('empty cue', () => withItem(base(), 'it_cue', (i) => (i as SubtitleCue).copyWith(text: ' \n ')), ViolationCode.emptyText, RepairCodes.emptyTextRemoved),
  ('empty text item', () => withItem(base(), 'it_txt', (i) => (i as TextItem).copyWith(text: '')), ViolationCode.emptyText, RepairCodes.emptyTextRemoved),
  ('subtitle track without data', () => withTrack(base(), 'tr_sub', (t) => t.copyWith(subtitle: null)), ViolationCode.subtitleData, RepairCodes.tracksRepaired),
  ('subtitle data on a text track', () => withTrack(base(), 'tr_text', (t) => t.copyWith(subtitle: const SubtitleTrackData())), ViolationCode.subtitleData, RepairCodes.tracksRepaired),
  ('subtitle maxLines 5', () => withTrack(base(), 'tr_sub', (t) => t.copyWith(subtitle: const SubtitleTrackData(style: SubtitleStyle(maxLines: 5)))), ViolationCode.subtitleData, RepairCodes.tracksRepaired),
  // I9
  ('odd canvas', () => withSettings(base(), const ProjectSettings(canvas: CanvasSpec(baseShortSide: 1081))), ViolationCode.canvasInvalid, RepairCodes.canvasRepaired),
  ('tiny canvas', () => withSettings(base(), const ProjectSettings(canvas: CanvasSpec(aspect: AspectRatio.square, baseShortSide: 8))), ViolationCode.canvasInvalid, RepairCodes.canvasRepaired),
  ('unsupported frame rate', () => withSettings(base(), const ProjectSettings(frameRate: FrameRate(30000, 1001))), ViolationCode.frameRateUnsupported, RepairCodes.frameRateRepaired),
  ('fade longer than half the clip', () => withItem(base(), 'it_music', (i) => (i as MediaClip).copyWith(audio: AudioProps(fadeIn: f(100)))), ViolationCode.fadeTooLong, RepairCodes.valueClamped),
];

void main() {
  test('the base fixture is valid', () => expect(validate(base()), isEmpty));

  test('every violation code has a fixture', () {
    expect({for (final c in cases) c.$3}, ViolationCode.values.toSet());
  });

  for (final (name, build, code, warning) in cases) {
    group(name, () {
      test('is reported as ${code.invariant.label} ${code.name}', () {
        final v = validate(build());
        expect(v.map((x) => x.code), contains(code), reason: v.join('\n'));
      });

      test('repair validates clean and reports $warning', () {
        final (fixed, warnings) = repair(build(), ids: SeededIdGenerator(9));
        expect(validate(fixed), isEmpty, reason: validate(fixed).join('\n'));
        expect(warnings.map((w) => w.code), contains(warning), reason: warnings.join('\n'));
      });
    });
  }

  group('repair semantics', () {
    test('an overlapping item moves to a new lane of its kind at the top of the band', () {
      final p = withTrack(base(), 'tr_music', (t) => t.copyWith(items: [aclip('it_music', 0, 150), aclip('it_m2', 100, 100)]));
      final (fixed, _) = repair(p, ids: SeededIdGenerator(1));
      final audio = fixed.tracks.where((t) => t.kind == TrackKind.audio).toList();
      expect(audio, hasLength(3));
      expect(audio.last.items.single.id, const ItemId('it_m2'));
      expect(audio.last.items.single.start, f(100));
    });

    test('an overlapping clip uses a free lane of the same kind above before creating one', () {
      final p = withTrack(
        base(),
        'tr_main',
        (t) => t.copyWith(items: [...t.items, vclip('it_x', 140, 20, sourceIn: f(900))]),
      ).copyWith();
      final withSecond = p.copyWith(
        timeline: p.timeline.copyWith(tracks: [
          p.tracks.first,
          Track(id: const TrackId('tr_v2'), kind: TrackKind.video),
          ...p.tracks.skip(1),
        ]),
      );
      final (fixed, _) = repair(withSecond, ids: SeededIdGenerator(1));
      expect(fixed.tracks[1].items.single.id, const ItemId('it_x'));
      expect(fixed.tracks.where((t) => t.kind == TrackKind.video), hasLength(2));
    });

    test('off-grid edges snap to the nearest frame and keep at least one frame', () {
      final p = withItem(base(), 'it_img', (i) => (i as MediaClip).copyWith(start: f(30) + 7, duration: 10));
      final (fixed, _) = repair(p);
      final img = fixed.index.item(const ItemId('it_img'))!;
      expect(img.start, f(30));
      expect(img.end, f(31));
    });

    test('a too-long source range shortens the clip to the media', () {
      final p = withItem(base(), 'it_music', (i) => (i as MediaClip).copyWith(sourceIn: 118 * microsPerSecond));
      final (fixed, _) = repair(p);
      final c = fixed.index.item(const ItemId('it_music'))! as MediaClip;
      expect(c.sourceIn, 118 * microsPerSecond);
      expect(c.sourceOut, lessThanOrEqualTo(120 * microsPerSecond));
      expect(rate.frameIndexOf(c.end), 60); // 2 s at 30 fps
    });

    test('a missing media reference becomes a failed placeholder sized to its clips', () {
      final p = base().copyWith(pool: pool.without({const MediaId('md_video')}));
      final (fixed, _) = repair(p);
      final a = fixed.pool[const MediaId('md_video')]!;
      expect(a.kind, MediaKind.video);
      expect(a.status, const FailedStatus('missing'));
      expect(a.probe.hasAudio, isTrue);
      final b = fixed.index.item(const ItemId('it_b'))! as MediaClip;
      expect(a.probe.duration, greaterThanOrEqualTo(b.sourceOut));
    });

    test('keyframes: off-grid keys snap, later key wins on collision, values clamp, bad channels go', () {
      final p = withItem(base(), 'it_img', (i) => (i as MediaClip).copyWith(keyframes: KeyframeSet({
            'transform.opacity': KeyframeTrack([Keyframe(f(2), 0.1), Keyframe(f(2) + f(1) ~/ 2 + 10, 0.9), Keyframe(f(5), 4)]),
            'nonsense': KeyframeTrack(const [Keyframe(0, 1)]),
          })));
      final (fixed, _) = repair(p);
      final c = fixed.index.item(const ItemId('it_img'))! as MediaClip;
      expect(c.keyframes.byChannel.keys, ['transform.opacity']);
      expect(c.keyframes['transform.opacity']!.keys, [Keyframe(f(2), 0.1), Keyframe(f(3), 0.9), Keyframe(f(5), 1)]);
    });

    test('an over-long transition is clamped to its limit', () {
      final p = withTrack(base(), 'tr_main', (t) => t.copyWith(transitions: [t.transitions.single.copyWith(kind: TransitionKind.fade, durationFrames: 200)]));
      final (fixed, _) = repair(p);
      final main = fixed.tracks.first;
      expect(main.transitions.single.durationFrames, 120); // 2·min(90, 60)
    });

    test('an unsupported frame rate is replaced by the nearest one and everything is requantized', () {
      final p = withSettings(base(), const ProjectSettings(frameRate: FrameRate(30000, 1001)));
      final (fixed, _) = repair(p);
      expect(fixed.settings.frameRate, FrameRate.fps30);
      expect(validate(fixed), isEmpty);
    });

    test('a lone link member loses its link; same-track members keep one', () {
      final p = withItem(base(), 'it_b', (i) => (i as MediaClip).copyWith(link: const LinkId('ln_a')));
      final (fixed, _) = repair(p);
      expect(fixed.index.item(const ItemId('it_a'))!.link, const LinkId('ln_a'));
      expect(fixed.index.item(const ItemId('it_b'))!.link, isNull);
      expect(fixed.index.item(const ItemId('it_a_audio'))!.link, const LinkId('ln_a'));
    });

    test('warnings carry codes and ids, never text content', () {
      final p = withItem(base(), 'it_cue', (i) => (i as SubtitleCue).copyWith(text: ' '));
      final (_, warnings) = repair(p);
      expect(warnings.single.code, RepairCodes.emptyTextRemoved);
      expect(warnings.single.message, contains('it_cue'));
    });
  });

  group('validator details', () {
    test('keys outside [0, duration) are allowed (kept for un-trim)', () {
      final p = withItem(base(), 'it_img', (i) => (i as MediaClip).copyWith(keyframes: KeyframeSet({
            'transform.opacity': KeyframeTrack([Keyframe(-f(10), 0.2), Keyframe(f(80), 0.8)]),
          })));
      expect(validate(p), isEmpty);
    });

    test('item-local lengths within a quarter frame of the grid pass (move drift)', () {
      final p = withItem(base(), 'it_music', (i) => (i as MediaClip).copyWith(audio: AudioProps(fadeIn: f(10) + 2), keyframes: KeyframeSet({
            'audio.volume': KeyframeTrack([Keyframe(f(3) - 1, 0.5)]),
          })));
      expect(validate(p), isEmpty);
      expect(lengthGridToleranceUs(rate), 8333);
    });

    test('fades of half a clip with an even frame count fit (ceil grid)', () {
      final p = withItem(base(), 'it_music', (i) => (i as MediaClip).copyWith(start: 0, duration: f(2), audio: AudioProps(fadeIn: f(1), fadeOut: f(2) - f(1))));
      expect(validate(p), isEmpty);
    });

    test('images and stills have unbounded handles; videos are limited by the media', () {
      final img = vclip('it_i', 0, 30, media: 'md_image');
      final vid = vclip('it_v', 0, 30, sourceIn: f(1));
      expect(TransitionBounds.handleFramesAfter(img, rate, pool), TransitionBounds.unbounded);
      expect(TransitionBounds.handleFramesBefore(vid, rate, pool), 1);
      final reversed = vid.copyWith(reversed: true);
      expect(TransitionBounds.handleFramesAfter(reversed, rate, pool), 1);
      expect(TransitionBounds.handleFramesAfter(vid.copyWith(speed: const ConstantSpeed(2)), rate, pool), (60 * 30 - 1 - 60) ~/ 2); // 2x: the clip used 60 source frames
    });

    test('violation messages contain no text content', () {
      final p = withItem(base(), 'it_txt', (i) => (i as TextItem).copyWith(text: '   ', start: f(10) + 3));
      for (final v in validate(p)) {
        expect(v.toString(), isNot(contains('Title')));
      }
    });
  });
}
