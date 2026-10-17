// OWNER: CORE-12
//
// Before/after golden tests for SetSpeed, SetReversed and FreezeFrame (BUILD_PLAN CORE-12):
// ripple, link, lock, clamp, pool and rejection cases. Every applied result validates fully and
// the dry run agrees with the apply (`runCase`). Regenerate with
// `UPDATE_GOLDENS=1 dart test test/ops/speed` and review the diff.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';
import 'speed_fixtures.dart';

typedef Case = (String, EditProject Function(), EditCommand, EditPolicy?);

ItemId id(String s) => ItemId(s);

SpeedRamp ramp(List<(double, double)> p) => SpeedRamp([for (final e in p) SpeedPoint(e.$1, e.$2)]);

final List<Case> speedCases = [
  (
    'speed 2x ripples the lane, the linked audio follows the same spec',
    standard,
    SetSpeed(id('it_a'), const ConstantSpeed(2)),
    null
  ),
  (
    'speed 0.5x on a linked clip grows both and ripples the lanes',
    standard,
    SetSpeed(id('it_a'), const ConstantSpeed(0.5)),
    null
  ),
  (
    'speed set from the audio partner changes the video too',
    standard,
    SetSpeed(id('it_a_au'), const ConstantSpeed(1.5)),
    null
  ),
  (
    'speed 0.5x without ripple clamps at the next clip',
    () => standard(rippleEnabled: false),
    SetSpeed(id('it_a'), const ConstantSpeed(0.5)),
    null
  ),
  (
    'speed 2x without ripple leaves a gap',
    () => standard(rippleEnabled: false),
    SetSpeed(id('it_c'), const ConstantSpeed(2)),
    null
  ),
  (
    'speed explicit ripple:false overrides the project mode',
    standard,
    SetSpeed(id('it_c'), const ConstantSpeed(2), ripple: false),
    null
  ),
  (
    'speed 0.5x of the last clip grows freely without ripple',
    () => standard(rippleEnabled: false),
    SetSpeed(id('it_c'), const ConstantSpeed(0.5)),
    null
  ),
  (
    'speed ramp montage',
    () => single(150, after: [vclip('it_n', 150, 30)]),
    SetSpeed(id('it_v'), SpeedRampPresets.byId('montage')!),
    null
  ),
  (
    'speed ramp flashIn',
    () => single(150, after: [vclip('it_n', 150, 30)]),
    SetSpeed(id('it_v'), SpeedRampPresets.byId('flashIn')!),
    null
  ),
  (
    'speed keys scale with the clip',
    () => single(100, after: [vclip('it_n', 100, 30)]).let((p) => withKeys(p)),
    SetSpeed(id('it_v'), const ConstantSpeed(2)),
    null
  ),
  (
    'speed near the end of the media loses a frame instead of overrunning it',
    () => project([
          lane('tr_main', TrackKind.video, [vclip('it_s', 0, 30, media: 'md_short')], main: true),
        ]),
    SetSpeed(id('it_s'), const ConstantSpeed(0.75)),
    null
  ),
  (
    'speed pulls sourceIn back when the clip sits at the end of the media',
    () => project([
          lane('tr_main', TrackKind.video, [vclip('it_s', 0, 30, media: 'md_video2', sourceIn: sec(9))], main: true),
        ]),
    SetSpeed(id('it_s'), const ConstantSpeed(0.75)),
    null
  ),
  ('speed pitch only', standard, SetSpeed(id('it_a'), const ConstantSpeed(1), maintainPitch: false), null),
  ('speed unchanged is a no-op', standard, SetSpeed(id('it_a'), const ConstantSpeed(1)), null),
  ('speed on a locked lane', () => standard(lockMain: true), SetSpeed(id('it_c'), const ConstantSpeed(2)), null),
  (
    'speed blocked: the partner lane is locked',
    () => project([
          lane('tr_main', TrackKind.video, [vclip('it_a', 0, 60, link: 'ln_a', detachedAudio: true)], main: true),
          lane('tr_orig', TrackKind.audio, [aclip('it_a_au', 0, 60, media: 'md_video', link: 'ln_a')],
              role: AudioRole.original, locked: true),
        ]),
    SetSpeed(id('it_a'), const ConstantSpeed(2)),
    null
  ),
  ('speed on an image', standard, SetSpeed(id('it_p1'), const ConstantSpeed(2)), null),
  ('speed on text', standard, SetSpeed(id('it_t1'), const ConstantSpeed(2)), null),
  ('speed above 10x', standard, SetSpeed(id('it_c'), const ConstantSpeed(10.5)), null),
  ('speed below 0.1x', standard, SetSpeed(id('it_c'), const ConstantSpeed(0.05)), null),
  ('speed unknown item', standard, SetSpeed(id('it_nope'), const ConstantSpeed(2)), null),
  (
    'speed leaves a link partner that does not share the time map alone',
    () => project([
          lane('tr_main', TrackKind.video, [vclip('it_a', 0, 30, link: 'ln_a'), vclip('it_b', 30, 30)], main: true),
          lane('tr_other', TrackKind.video, [vclip('it_o', 0, 60, link: 'ln_a', media: 'md_video2')]),
        ]),
    SetSpeed(id('it_a'), const ConstantSpeed(2)),
    null
  ),
  (
    'speed ripple blocked: a moved clip\'s partner would hit an item of its lane',
    () => project([
          lane('tr_main', TrackKind.video, [vclip('it_a', 0, 30), vclip('it_b', 30, 30, link: 'ln_b')], main: true),
          lane('tr_orig', TrackKind.audio,
              [aclip('it_b_au', 30, 30, media: 'md_video', link: 'ln_b'), aclip('it_x', 65, 30)],
              role: AudioRole.original),
        ]),
    SetSpeed(id('it_a'), const ConstantSpeed(0.5)),
    null
  ),
];

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

EditProject withKeys(EditProject p) {
  final clip = p.index.locate(id('it_v'))!.item as MediaClip;
  final keys = KeyframeSet({
    'transform.scale': KeyframeTrack(
        [Keyframe(0, 1), Keyframe(f(30) - f(0), 2), Keyframe(f(60) - f(0), 3), Keyframe(f(90) - f(0), 4)]),
  });
  return project([
    lane('tr_main', TrackKind.video, [clip.copyWith(keyframes: keys), vclip('it_n', 100, 30)], main: true),
  ]);
}

final List<Case> reverseCases = [
  ('reverse a clip adds a pending rendition with 2 s handles', standard, SetReversed(id('it_c'), true), null),
  (
    'reverse a linked clip reverses the partner and shares one rendition',
    standard,
    SetReversed(id('it_a'), true),
    null
  ),
  (
    'reverse near the media start clamps the handles',
    () => project([
          lane('tr_main', TrackKind.video, [vclip('it_s', 0, 30, media: 'md_short')], main: true),
        ]),
    SetReversed(id('it_s'), true),
    null
  ),
  (
    'reverse reuses a rendition that covers the range',
    () {
      final p = standard();
      final spec = ReversedSpec(const MediaId('md_video2'), TimeRange(0, sec(5)), sourceQuickHash: 'q-md_video2');
      return p.copyWith(
          pool: p.pool.upsert(asset('md_rev', MediaKind.video, duration: sec(5), hasAudio: true, derived: spec)));
    },
    SetReversed(id('it_c'), true),
    null
  ),
  (
    'reverse a reversed clip again plays forward and keeps the pool',
    () => project([
          lane('tr_main', TrackKind.video, [vclip('it_v', 0, 60, reversed: true)], main: true),
        ]),
    SetReversed(id('it_v'), false),
    null
  ),
  (
    'reverse an already reversed clip is a no-op',
    () => project([
          lane('tr_main', TrackKind.video, [vclip('it_v', 0, 60, reversed: true)], main: true),
        ]),
    SetReversed(id('it_v'), true),
    null
  ),
  ('reverse an image', standard, SetReversed(id('it_p1'), true), null),
  ('reverse text', standard, SetReversed(id('it_t1'), true), null),
  ('reverse on a locked lane', () => standard(lockMain: true), SetReversed(id('it_c'), true), null),
  ('reverse music', standard, SetReversed(id('it_m'), true), null),
];

EditProject withC() => withStill(media: 'md_video2');

final List<Case> freezeCases = [
  (
    'freeze inside a linked clip: split, still inserted with ripple, partner follows',
    withStill,
    FreezeFrame(id('it_a'), f(30), sec(1), const MediaId('md_still')),
    null
  ),
  (
    'freeze at the first frame inserts before the clip',
    withC,
    FreezeFrame(id('it_c'), f(150), sec(2), const MediaId('md_still')),
    null
  ),
  (
    'freeze with a mid-frame time floors it to the frame start',
    withC,
    FreezeFrame(id('it_c'), f(180) + 1000, sec(1), const MediaId('md_still')),
    null
  ),
  (
    'freeze duration is quantized to whole frames',
    withC,
    FreezeFrame(id('it_c'), f(180), 100000, const MediaId('md_still')),
    null
  ),
  (
    'freeze at the clip end finds nothing',
    withC,
    FreezeFrame(id('it_c'), f(210), sec(1), const MediaId('md_still')),
    null
  ),
  (
    'freeze outside every clip finds nothing',
    withC,
    FreezeFrame(id('it_c'), f(130), sec(1), const MediaId('md_still')),
    null
  ),
  ('freeze zero duration', withC, FreezeFrame(id('it_c'), f(180), 0, const MediaId('md_still')), null),
  (
    'freeze with a missing still asset',
    standard,
    FreezeFrame(id('it_c'), f(180), sec(1), const MediaId('md_still')),
    null
  ),
  (
    'freeze with a failed still asset',
    () {
      final p = standard();
      return p.copyWith(pool: p.pool.upsert(stillAsset('md_still', status: const FailedStatus('x'))));
    },
    FreezeFrame(id('it_c'), f(180), sec(1), const MediaId('md_still')),
    null
  ),
  (
    'freeze with a still of other media',
    () {
      final p = standard();
      return p.copyWith(pool: p.pool.upsert(stillAsset('md_still', media: 'md_video2')));
    },
    FreezeFrame(id('it_a'), f(30), sec(1), const MediaId('md_still')),
    null
  ),
  ('freeze a non-still asset', withC, FreezeFrame(id('it_c'), f(180), sec(1), const MediaId('md_image')), null),
  ('freeze an image clip', withStill, FreezeFrame(id('it_p1'), f(40), sec(1), const MediaId('md_still')), null),
  ('freeze an audio clip', withStill, FreezeFrame(id('it_m'), f(40), sec(1), const MediaId('md_still')), null),
  (
    'freeze on a locked lane',
    () => withC().let((p) => p.copyWith(timeline: _lock(p, 'tr_main'))),
    FreezeFrame(id('it_c'), f(180), sec(1), const MediaId('md_still')),
    null
  ),
  (
    'freeze ripple blocked by a linked partner',
    () => withStill(extraOriginal: [aclip('it_x', 60, 30, media: 'md_music')]),
    FreezeFrame(id('it_a'), f(30), sec(1), const MediaId('md_still')),
    null
  ),
  (
    'freeze bakes keyframed visuals into the still',
    () {
      final p = withC();
      final c = p.index.locate(id('it_c'))!.item as MediaClip;
      final keys = KeyframeSet({
        'transform.scale': KeyframeTrack([Keyframe(0, 1), Keyframe(f(50) - f(0), 2)]),
      });
      return project([
        lane('tr_main', TrackKind.video, [c.copyWith(keyframes: keys, start: f(0))], main: true),
      ], pool: p.pool);
    },
    FreezeFrame(id('it_c'), f(30), sec(1), const MediaId('md_still')),
    null
  ),
  (
    'freeze a ramped clip splits it through the time map',
    () => withC().let((p) {
          final c = p.index.locate(id('it_c'))!.item as MediaClip;
          return project([
            lane(
                'tr_main',
                TrackKind.video,
                [
                  c.copyWith(speed: ramp([(0, 1), (0.5, 2), (1, 1)]), start: f(0))
                ],
                main: true),
          ], pool: p.pool);
        }),
    FreezeFrame(id('it_c'), f(20), sec(1), const MediaId('md_still')),
    null
  ),
];

Timeline _lock(EditProject p, String lane) => Timeline(
      settings: p.settings,
      tracks: [for (final t in p.tracks) t.id == TrackId(lane) ? t.copyWith(locked: true) : t],
      markers: p.markers,
    );

void runGroup(String file, List<Case> cases) {
  final golden = GoldenFile('test/ops/speed/goldens/$file');
  tearDownAll(golden.save);
  for (final c in cases) {
    test(c.$1, () {
      golden.check(c.$1, runCase(c.$1, c.$2(), c.$3, policy: c.$4 ?? const EditPolicy()));
    });
  }
}

void main() {
  group('SetSpeed', () => runGroup('speed.golden', speedCases));
  group('SetReversed', () => runGroup('reverse.golden', reverseCases));
  group('FreezeFrame', () => runGroup('freeze.golden', freezeCases));
}
