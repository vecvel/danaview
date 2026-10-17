// OWNER: CORE-12
//
// Rule tests for SetSpeed, SetReversed and FreezeFrame (BUILD_PLAN CORE-12): duration math for
// every preset and ramp preset, exact key scaling, link sync, clamping, reverse round trips and
// the pool entries, freeze placement, and the InvalidValue ranges.

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';
import 'speed_fixtures.dart';

ItemId id(String s) => ItemId(s);

MediaClip clipOf(EditProject p, String item) => p.index.locate(id(item))!.item as MediaClip;

EditOutcome apply(EditProject p, EditCommand c, {EditPolicy policy = const EditPolicy(), int seed = 7}) {
  final out = applyCommand(p, c, ctx(policy: policy, seed: seed));
  expect(out.rejection, isNull, reason: 'unexpected rejection ${out.rejection}');
  expectValid(out.project, c.toString());
  return out;
}

EditRejection? reject(EditProject p, EditCommand c) {
  final out = applyCommand(p, c, ctx());
  expect(identical(out.project, p), isTrue);
  return out.rejection;
}

int frames(MediaClip c) => rate.frameIndexOf(c.end) - rate.frameIndexOf(c.start);

void main() {
  group('SetSpeed duration math', () {
    for (final preset in speedPresets) {
      test('preset ${preset}x: duration = quantizeNearest(T), source range kept', () {
        final p = single(100, after: [vclip('it_n', 100, 10)]);
        final before = clipOf(p, 'it_v');
        final out = apply(p, SetSpeed(id('it_v'), ConstantSpeed(preset)));
        final after = clipOf(out.project, 'it_v');
        // T = L / preset on the 30 fps grid (no half-frame ties for 100 frames).
        expect(frames(after), (100 / preset).round(), reason: 'frames at ${preset}x');
        expect(after.speed, ConstantSpeed(preset));
        expect(after.sourceIn, before.sourceIn);
        final oldOut = before.sourceOut;
        expect((after.sourceOut - oldOut).abs(), lessThanOrEqualTo((preset * rate.frameUs / 2).ceil() + 1),
            reason: 'the source range is kept to within half a frame of source');
        expect(rate.isOnGrid(after.end), isTrue);
        // Ripple: the next clip follows the end of the edited one.
        expect(clipOf(out.project, 'it_n').start, after.end);
      });
    }

    test('custom speeds at both ends of [0.1, 10]', () {
      final fast = apply(single(100), SetSpeed(id('it_v'), const ConstantSpeed(10)));
      expect(frames(clipOf(fast.project, 'it_v')), 10);
      final slow = apply(single(100), SetSpeed(id('it_v'), const ConstantSpeed(0.1)));
      expect(frames(clipOf(slow.project, 'it_v')), 1000);
    });

    test('a very fast speed keeps at least one frame', () {
      final out = apply(single(2), SetSpeed(id('it_v'), const ConstantSpeed(10)));
      expect(frames(clipOf(out.project, 'it_v')), 1);
    });

    test('speeds outside [0.1, 10] and non-finite speeds are InvalidValue', () {
      final p = single(100);
      for (final bad in [0.099, 0.0, -1.0, 10.001, 11.0, double.nan, double.infinity, double.negativeInfinity]) {
        expect(reject(p, SetSpeed(id('it_v'), ConstantSpeed(bad))), const InvalidValue('speed'), reason: '$bad');
      }
    });

    test('every ramp preset: valid ramp, duration = quantizeNearest(L·K)', () {
      expect(SpeedRampPresets.ids, hasLength(6));
      for (final presetId in SpeedRampPresets.ids) {
        final ramp = SpeedRampPresets.byId(presetId)!;
        expect(ramp.presetId, presetId);
        expect(speedRampIssues(ramp), isEmpty, reason: presetId);
        expect(ramp.points.length, inInclusiveRange(2, 16));
        expect(SpeedRampPresets.byId(presetId), ramp, reason: 'presets are values');

        final p = single(150, after: [vclip('it_n', 150, 10)]);
        final before = clipOf(p, 'it_v');
        final out = apply(p, SetSpeed(id('it_v'), ramp));
        final after = clipOf(out.project, 'it_v');
        final expected = ((before.sourceOut - before.sourceIn) * speedTimeFactor(ramp) * 30 / 1e6).round();
        expect(frames(after), expected, reason: presetId);
        expect(after.speed, ramp);
        // The map of the result covers the new range exactly like the ramp says.
        final map = after.timeMap(rate);
        expect(map.toSource(after.start), after.sourceIn);
        expect(clipOf(out.project, 'it_n').start, after.end, reason: 'ripple follows');
      }
      expect(SpeedRampPresets.byId('nope'), isNull);
    });

    test('ramps of 2 to 16 points are accepted, others are InvalidValue', () {
      final p = single(100);
      SpeedRamp pts(int n, {double y = 2}) => SpeedRamp([for (var i = 0; i < n; i++) SpeedPoint(i / (n - 1), y)]);
      expect(apply(p, SetSpeed(id('it_v'), pts(2))).rejection, isNull);
      expect(apply(p, SetSpeed(id('it_v'), pts(16))).rejection, isNull);
      expect(reject(p, SetSpeed(id('it_v'), pts(17))), const InvalidValue('speed'));
      expect(reject(p, SetSpeed(id('it_v'), SpeedRamp([const SpeedPoint(0, 1)]))), const InvalidValue('speed'));
      expect(reject(p, SetSpeed(id('it_v'), SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(0.5, 1)]))),
          const InvalidValue('speed'),
          reason: 'must end at 1');
      expect(reject(p, SetSpeed(id('it_v'), SpeedRamp([const SpeedPoint(0.1, 1), const SpeedPoint(1, 1)]))),
          const InvalidValue('speed'),
          reason: 'must start at 0');
      expect(
          reject(
              p,
              SetSpeed(
                  id('it_v'),
                  SpeedRamp([
                    const SpeedPoint(0, 1),
                    const SpeedPoint(0.5, 1),
                    const SpeedPoint(0.5, 2),
                    const SpeedPoint(1, 1)
                  ]))),
          const InvalidValue('speed'),
          reason: 'x must increase strictly');
      expect(reject(p, SetSpeed(id('it_v'), SpeedRamp([const SpeedPoint(0, 0.05), const SpeedPoint(1, 1)]))),
          const InvalidValue('speed'));
      expect(reject(p, SetSpeed(id('it_v'), SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(1, 12)]))),
          const InvalidValue('speed'));
    });

    test('a ramp back to a constant speed restores the duration', () {
      final p = single(100);
      final ramped = apply(p, SetSpeed(id('it_v'), SpeedRampPresets.byId('hero')!)).project;
      final back = apply(ramped, SetSpeed(id('it_v'), const ConstantSpeed(1)));
      final c = clipOf(back.project, 'it_v');
      expect(frames(c), closeTo(100, 1));
      expect(c.speed, SpeedSpec.normal);
    });

    test('speed never overruns the media; the range is pulled back or a frame is lost', () {
      // md_short is exactly 30 frames long and the clip plays all of it.
      final p = project([
        lane('tr_main', TrackKind.video, [vclip('it_s', 0, 30, media: 'md_short')], main: true),
      ]);
      final out = apply(p, SetSpeed(id('it_s'), const ConstantSpeed(0.75)));
      final c = clipOf(out.project, 'it_s');
      expect(c.sourceIn + ClipTimeMap.sourceLengthOf(c.duration, c.speed), lessThanOrEqualTo(sec(1)));
      expect(frames(c), 39, reason: 'one frame lost instead of playing past the media');
      // Sitting at the end of a longer media the range is pulled back instead.
      final q = project([
        lane('tr_main', TrackKind.video, [vclip('it_s', 0, 30, media: 'md_video2', sourceIn: sec(9))], main: true),
      ]);
      final o2 = apply(q, SetSpeed(id('it_s'), const ConstantSpeed(0.75)));
      final c2 = clipOf(o2.project, 'it_s');
      expect(frames(c2), 40);
      expect(c2.sourceIn, lessThan(sec(9)));
      expect(c2.sourceIn + ClipTimeMap.sourceLengthOf(c2.duration, c2.speed), lessThanOrEqualTo(sec(10)));
    });

    test('the speed of an audio clip changes the same way', () {
      final out = apply(standard(), SetSpeed(id('it_m'), const ConstantSpeed(2)));
      expect(frames(clipOf(out.project, 'it_m')), 150);
    });

    test('speed then back to 1x returns to the original duration', () {
      final p = single(90, after: [vclip('it_n', 90, 10)]);
      final fast = apply(p, SetSpeed(id('it_v'), const ConstantSpeed(2))).project;
      final back = apply(fast, SetSpeed(id('it_v'), const ConstantSpeed(1))).project;
      expect(frames(clipOf(back, 'it_v')), 90);
      expect(clipOf(back, 'it_n').start, clipOf(p, 'it_n').start);
    });
  });

  group('SetSpeed keys', () {
    KeyframeSet keys(List<int> fs) => KeyframeSet({
          'transform.scale': KeyframeTrack([for (var i = 0; i < fs.length; i++) Keyframe(f(fs[i]) - f(0), 1.0 + i)]),
          'audio.volume': KeyframeTrack([Keyframe(f(20) - f(0), 0.5), Keyframe(f(80) - f(0), 1.5)]),
        });

    EditProject withKeys(List<int> fs, {int n = 100}) => project([
          lane('tr_main', TrackKind.video, [vclip('it_v', 0, n, keyframes: keys(fs)), vclip('it_n', n, 10)],
              main: true),
        ]);

    test('keys scale exactly with the duration (2x halves their frames)', () {
      final p = withKeys([0, 20, 40, 60, 80]);
      final out = apply(p, SetSpeed(id('it_v'), const ConstantSpeed(2)));
      final c = clipOf(out.project, 'it_v');
      expect(frames(c), 50);
      final scale = c.keyframes['transform.scale']!.keys;
      expect([for (final k in scale) rate.frameIndexNearest(k.t)], [0, 10, 20, 30, 40]);
      expect([for (final k in scale) k.v], [1.0, 2.0, 3.0, 4.0, 5.0]);
      final vol = c.keyframes['audio.volume']!.keys;
      expect([for (final k in vol) rate.frameIndexNearest(k.t)], [10, 40]);
      for (final k in [...scale, ...vol]) {
        expect((c.start + k.t - rate.quantizeNearest(c.start + k.t)).abs(), lessThanOrEqualTo(rate.frameUs ~/ 4),
            reason: 'keys stay on the grid');
      }
    });

    test('keys scale exactly with a slow down (0.5x doubles them)', () {
      final p = withKeys([0, 10, 20, 30, 40], n: 100);
      final out = apply(p, SetSpeed(id('it_v'), const ConstantSpeed(0.5)));
      final c = clipOf(out.project, 'it_v');
      expect(frames(c), 200);
      expect([for (final k in c.keyframes['transform.scale']!.keys) rate.frameIndexNearest(k.t)], [0, 20, 40, 60, 80]);
    });

    test('keys equal KeyframeOps.scale of the old keys', () {
      final p = withKeys([0, 7, 33, 61, 90]);
      final before = clipOf(p, 'it_v');
      final out = apply(p, SetSpeed(id('it_v'), const ConstantSpeed(1.5)));
      final after = clipOf(out.project, 'it_v');
      expect(
          after.keyframes,
          KeyframeOps.scale(before.keyframes,
              oldDuration: before.duration, newDuration: after.duration, rate: rate, itemStart: before.start));
    });

    test('keys evaluate to the same values at the same content (value at the scaled time)', () {
      final p = withKeys([0, 40, 80]);
      final before = clipOf(p, 'it_v');
      final out = apply(p, SetSpeed(id('it_v'), const ConstantSpeed(2)));
      final after = clipOf(out.project, 'it_v');
      for (final k in [0, 20, 40, 60, 80]) {
        final v0 = evaluate(before, PropertyKeys.scale, f(k) - f(0));
        final v1 = evaluate(after, PropertyKeys.scale, f(k ~/ 2) - f(0));
        expect(v1, closeTo(v0, 1e-5), reason: 'content at ${k}f');
      }
    });

    test('a pitch-only change leaves keys alone', () {
      final p = withKeys([0, 20]);
      final out = apply(p, SetSpeed(id('it_v'), const ConstantSpeed(1), maintainPitch: false));
      expect(clipOf(out.project, 'it_v').keyframes, clipOf(p, 'it_v').keyframes);
      expect(clipOf(out.project, 'it_v').maintainPitch, isFalse);
    });
  });

  group('SetSpeed links, ripple and clamping', () {
    test('linked audio gets the same spec and stays in sync at every frame', () {
      final out = apply(standard(), SetSpeed(id('it_a'), const ConstantSpeed(1.5)));
      final v = clipOf(out.project, 'it_a');
      final a = clipOf(out.project, 'it_a_au');
      expect(a.speed, v.speed);
      expect(a.duration, v.duration);
      expect(a.sourceIn, v.sourceIn);
      final mv = v.timeMap(rate);
      final ma = a.timeMap(rate);
      for (var k = rate.frameIndexOf(v.start); k < rate.frameIndexOf(v.end); k++) {
        expect(ma.toSource(f(k)), mv.toSource(f(k)), reason: 'frame $k');
      }
    });

    test('a partner with a different range is not touched but still follows the ripple', () {
      final p = project([
        lane('tr_main', TrackKind.video, [vclip('it_a', 0, 30, link: 'ln_a'), vclip('it_b', 30, 30, link: 'ln_b')],
            main: true),
        lane(
            'tr_orig',
            TrackKind.audio,
            [
              aclip('it_a_au', 0, 30, media: 'md_video', link: 'ln_a'),
              aclip('it_b_au', 30, 30, media: 'md_video', link: 'ln_b'),
            ],
            role: AudioRole.original),
      ]);
      final out = apply(p, SetSpeed(id('it_a'), const ConstantSpeed(2)));
      expect(clipOf(out.project, 'it_b').start, f(15));
      expect(clipOf(out.project, 'it_b_au').start, f(15),
          reason: 'the partner of a moved clip follows (it also shares the lane)');
      expect(clipOf(out.project, 'it_b_au').speed, SpeedSpec.normal);
    });

    test('ripple never moves items on unrelated lanes', () {
      final out = apply(standard(), SetSpeed(id('it_c'), const ConstantSpeed(0.5)));
      for (final laneId in ['tr_ov1', 'tr_txt', 'tr_sub', 'tr_orig', 'tr_music']) {
        expect(out.project.tracks.firstWhere((t) => t.id == TrackId(laneId)),
            standard().tracks.firstWhere((t) => t.id == TrackId(laneId)),
            reason: laneId);
      }
    });

    test('ripple off: growth clamps at the next item and reports it', () {
      final p = standard(rippleEnabled: false);
      final cmd = SetSpeed(id('it_a'), const ConstantSpeed(0.5));
      final out = apply(p, cmd);
      final a = clipOf(out.project, 'it_a');
      expect(a.end, f(60), reason: 'stops at it_b');
      expect(a.speed, const ConstantSpeed(0.5));
      expect(a.sourceIn + ClipTimeMap.sourceLengthOf(a.duration, a.speed), sec(1),
          reason: 'the clip plays the first second of source only');
      expect(clipOf(out.project, 'it_a_au').end, f(60));
      expect(out.notices.map((n) => n.code), contains(EditNoticeCodes.trimmedToFit));
      expect(dryRun(p, cmd, ctx()).clampedTo, TimeRange(f(0), f(60)));
      expect(clipOf(out.project, 'it_b').start, f(60), reason: 'nothing moved');
    });

    test('ripple off: a slow-down with room does not clamp', () {
      final p = standard(rippleEnabled: false);
      final out = apply(p, SetSpeed(id('it_b'), const ConstantSpeed(0.75)));
      expect(clipOf(out.project, 'it_b').end, f(60 + 80));
      expect(out.notices.where((n) => n.code == EditNoticeCodes.trimmedToFit), isEmpty);
      expect(dryRun(p, SetSpeed(id('it_b'), const ConstantSpeed(0.75)), ctx()).clampedTo, isNull);
    });

    test('ripple off, speeding up leaves a gap and moves nothing', () {
      final out = apply(standard(rippleEnabled: false), SetSpeed(id('it_b'), const ConstantSpeed(2)));
      expect(clipOf(out.project, 'it_b').end, f(90));
      expect(clipOf(out.project, 'it_c').start, f(150));
    });

    test('an explicit ripple argument wins over the project mode', () {
      final rippled = apply(standard(rippleEnabled: false), SetSpeed(id('it_b'), const ConstantSpeed(2), ripple: true));
      expect(clipOf(rippled.project, 'it_c').start, f(120));
      final held = apply(standard(), SetSpeed(id('it_b'), const ConstantSpeed(2), ripple: false));
      expect(clipOf(held.project, 'it_c').start, f(150));
    });

    test('transitions are re-clamped when a speed change shortens a clip', () {
      final p = project([
        lane('tr_main', TrackKind.video, [vclip('it_a', 0, 60), vclip('it_b', 60, 60, sourceIn: sec(10))],
            main: true, transitions: [transition('tx_ab', 'it_a', 'it_b', frames: 50)]),
      ]);
      final out = apply(p, SetSpeed(id('it_a'), const ConstantSpeed(4)));
      final tr = out.project.tracks.single.transitions;
      expect(tr.length, lessThanOrEqualTo(1));
      for (final t in tr) {
        expect(t.durationFrames, lessThan(50));
      }
    });

    test('fades are clamped to half the new duration', () {
      final p = project([
        lane('tr_main', TrackKind.video, [vclip('it_v', 0, 90, audio: AudioProps(fadeIn: f(40), fadeOut: f(40)))],
            main: true),
      ]);
      final out = apply(p, SetSpeed(id('it_v'), const ConstantSpeed(3)));
      final c = clipOf(out.project, 'it_v');
      expect(frames(c), 30);
      expect(rate.frameIndexNearest(c.audio.fadeIn), lessThanOrEqualTo(15));
      expect(rate.frameIndexNearest(c.audio.fadeOut), lessThanOrEqualTo(15));
    });

    test('rejections: kinds, media, locks', () {
      final p = standard();
      expect(reject(p, SetSpeed(id('it_p1'), const ConstantSpeed(2))), const UnsupportedForKind('image'));
      expect(reject(p, SetSpeed(id('it_t1'), const ConstantSpeed(2))), const UnsupportedForKind('text'));
      expect(reject(p, SetSpeed(id('it_s1'), const ConstantSpeed(2))), const UnsupportedForKind('subtitle'));
      expect(reject(p, SetSpeed(id('it_zzz'), const ConstantSpeed(2))), const ItemNotFound('it_zzz'));
      expect(reject(standard(lockMain: true), SetSpeed(id('it_c'), const ConstantSpeed(2))),
          const TrackLocked(TrackId('tr_main')));
      final missing = project([
        lane('tr_main', TrackKind.video, [vclip('it_v', 0, 30, media: 'md_gone')], main: true),
      ]);
      expect(reject(missing, SetSpeed(id('it_v'), const ConstantSpeed(2))), const MediaUnavailable(MediaId('md_gone')));
    });

    test('identical speed and pitch is a no-op', () {
      final out = applyCommand(standard(), SetSpeed(id('it_a'), const ConstantSpeed(1)), ctx());
      expect(out.noop, isTrue);
    });

    test('purity: same input and ids give an equal result', () {
      final a = applyCommand(standard(), SetSpeed(id('it_a'), const ConstantSpeed(2)), ctx());
      final b = applyCommand(standard(), SetSpeed(id('it_a'), const ConstantSpeed(2)), ctx());
      expect(a.project.timeline, b.project.timeline);
    });
  });

  group('SetReversed', () {
    test('only the flag flips; the pool gets a pending rendition covering the range with handles', () {
      final p = standard();
      final before = clipOf(p, 'it_b');
      final out = apply(p, SetReversed(id('it_b'), true));
      final after = clipOf(out.project, 'it_b');
      expect(after, before.copyWith(reversed: true));
      final added = out.project.pool.assets.values.where((a) => !p.pool.contains(a.id)).toList();
      expect(added, hasLength(1));
      final r = added.single;
      final spec = r.derived! as ReversedSpec;
      expect(spec.media, const MediaId('md_video'));
      expect(spec.range, TimeRange(sec(8), sec(14)), reason: 'source [10,12) s with 2 s handles');
      expect(spec.sourceQuickHash, 'q-md_video');
      expect(r.status, const PendingStatus(unstartedJobId));
      expect(r.ownership, MediaOwnership.projectOwned);
      expect(r.origin, MediaOrigin.derived);
      expect(r.kind, MediaKind.video);
      expect(r.probe.duration, sec(6));
      expect(r.locator, isA<AppRelativeLocator>());
      expect((r.locator as AppRelativeLocator).relPath, endsWith('${spec.specHash}.mp4'));
      expect(out.notices.single.code, ReverseNoticeCodes.renditionPending);
    });

    test('handles are limited to the media', () {
      final p = project([
        lane('tr_main', TrackKind.video, [vclip('it_s', 0, 30, media: 'md_short')], main: true),
      ]);
      final out = apply(p, SetReversed(id('it_s'), true));
      final spec = out.project.pool.assets.values.firstWhere((a) => a.derived != null).derived! as ReversedSpec;
      expect(spec.range, TimeRange(0, sec(1)));
    });

    test('reverse twice equals the original timeline (and adds only one rendition)', () {
      final p = standard();
      final once = apply(p, SetReversed(id('it_b'), true)).project;
      final twice = apply(once, SetReversed(id('it_b'), false));
      expect(twice.project.timeline, p.timeline);
      expect(twice.project.pool, once.pool, reason: 'turning it off leaves the pool alone');
      final again = apply(twice.project, SetReversed(id('it_b'), true));
      expect(again.project.pool, once.pool, reason: 'the pending rendition is reused');
      expect(again.notices, isEmpty);
    });

    test('a linked pair reverses together and shares one rendition', () {
      final out = apply(standard(), SetReversed(id('it_a'), true));
      expect(clipOf(out.project, 'it_a').reversed, isTrue);
      expect(clipOf(out.project, 'it_a_au').reversed, isTrue);
      expect(out.project.pool.assets.values.where((a) => a.derived is ReversedSpec), hasLength(1));
      final back = apply(out.project, SetReversed(id('it_a_au'), false));
      expect(clipOf(back.project, 'it_a').reversed, isFalse);
      expect(clipOf(back.project, 'it_a_au').reversed, isFalse);
    });

    test('reversing keeps range, speed, keys and fades', () {
      final p = project([
        lane(
            'tr_main',
            TrackKind.video,
            [
              vclip('it_v', 0, 90,
                  speed: SpeedRampPresets.byId('hero')!,
                  sourceIn: sec(5),
                  audio: AudioProps(fadeIn: f(10), fadeOut: f(12)),
                  keyframes: KeyframeSet({
                    'transform.scale': KeyframeTrack([Keyframe(f(30) - f(0), 2)])
                  })),
            ],
            main: true),
      ]);
      final out = apply(p, SetReversed(id('it_v'), true));
      expect(clipOf(out.project, 'it_v'), clipOf(p, 'it_v').copyWith(reversed: true));
    });

    test('an existing rendition (pending or ready) that covers the range is reused', () {
      for (final status in [AssetStatus.ready, const PendingStatus('job_9')]) {
        final spec = ReversedSpec(const MediaId('md_video2'), TimeRange(0, sec(5)), sourceQuickHash: 'q-md_video2');
        final p0 = standard();
        final p = p0.copyWith(
            pool: p0.pool.upsert(asset('md_rev', MediaKind.video, duration: sec(5), derived: spec, status: status)));
        final out = apply(p, SetReversed(id('it_c'), true));
        expect(out.project.pool, p.pool, reason: '$status');
        expect(out.notices, isEmpty);
      }
    });

    test('a rendition that does not cover the range, was made from other content or failed is not reused', () {
      for (final (spec, status) in [
        (
          ReversedSpec(const MediaId('md_video2'), TimeRange(0, sec(1)), sourceQuickHash: 'q-md_video2'),
          AssetStatus.ready
        ),
        (ReversedSpec(const MediaId('md_video2'), TimeRange(0, sec(5)), sourceQuickHash: 'other'), AssetStatus.ready),
        (
          ReversedSpec(const MediaId('md_video2'), TimeRange(0, sec(5)), sourceQuickHash: 'q-md_video2'),
          const FailedStatus('x')
        ),
        (
          ReversedSpec(const MediaId('md_video'), TimeRange(0, sec(5)), sourceQuickHash: 'q-md_video'),
          AssetStatus.ready
        ),
      ]) {
        final p0 = standard();
        final p = p0.copyWith(
            pool: p0.pool.upsert(asset('md_rev', MediaKind.video, duration: sec(5), derived: spec, status: status)));
        final out = apply(p, SetReversed(id('it_c'), true));
        expect(out.project.pool.length, p.pool.length + 1, reason: '$spec $status');
        expect(out.notices.single.code, ReverseNoticeCodes.renditionPending);
      }
    });

    test('a failed rendition of exactly the wanted range is retried (reset to pending), not duplicated', () {
      final spec = ReversedSpec(const MediaId('md_video2'), TimeRange(0, sec(4)), sourceQuickHash: 'q-md_video2');
      final p0 = standard();
      final p = p0.copyWith(
          pool: p0.pool.upsert(
              asset('md_rev', MediaKind.video, duration: sec(4), derived: spec, status: const FailedStatus('x'))));
      final out = apply(p, SetReversed(id('it_c'), true));
      expect(out.project.pool.length, p.pool.length);
      expect(out.project.pool[const MediaId('md_rev')]!.status, const PendingStatus(unstartedJobId));
    });

    test('rejections and no-ops', () {
      final p = standard();
      expect(reject(p, SetReversed(id('it_p1'), true)), const UnsupportedForKind('image'));
      expect(reject(p, SetReversed(id('it_t1'), true)), const UnsupportedForKind('text'));
      expect(reject(p, SetReversed(id('it_s1'), true)), const UnsupportedForKind('subtitle'));
      expect(reject(p, SetReversed(id('it_x'), true)), const ItemNotFound('it_x'));
      expect(reject(standard(lockMain: true), SetReversed(id('it_c'), true)), const TrackLocked(TrackId('tr_main')));
      expect(applyCommand(p, SetReversed(id('it_c'), false), ctx()).noop, isTrue);
    });

    test('a reversed clip splits and plays through the time map', () {
      final out = apply(standard(), SetReversed(id('it_c'), true));
      final split = apply(out.project, SplitItems({id('it_c')}, f(180)));
      expect(split.project.tracks.first.items.where((i) => i is MediaClip && i.reversed), hasLength(2));
    });
  });

  group('FreezeFrame', () {
    final still = const MediaId('md_still');

    test('splits at the cut, inserts the still with ripple and keeps everything else', () {
      final p = withStill();
      final out = apply(p, FreezeFrame(id('it_b'), f(90), sec(2), still));
      final lane0 = out.project.tracks.firstWhere((t) => t.isMain).items.cast<MediaClip>();
      expect(lane0.map((c) => (rate.frameIndexOf(c.start), rate.frameIndexOf(c.end), c.media.value)), [
        (0, 60, 'md_video'),
        (60, 90, 'md_video'),
        (90, 150, 'md_still'),
        (150, 180, 'md_video'),
        (210, 270, 'md_video2'),
      ]);
      final left = lane0[1];
      final freeze = lane0[2];
      final right = lane0[3];
      expect(left.sourceIn, sec(10));
      expect(right.sourceIn, left.sourceIn + ClipTimeMap.sourceLengthOf(left.duration, left.speed),
          reason: 'the halves are contiguous in the source');
      expect(freeze.visual, VisualProps.neutral);
      expect(freeze.audio, AudioProps.unity);
      expect(freeze.sourceIn, 0);
      expect(freeze.duration, f(150) - f(90));
      expect(out.selection!.primary, freeze.id);
      // The halves play the same source as the original at every frame.
      final orig = clipOf(p, 'it_b').timeMap(rate);
      for (var k = 60; k < 90; k++) {
        expect(left.timeMap(rate).toSource(f(k)), orig.toSource(f(k)), reason: 'left $k');
      }
      for (var k = 90; k < 120; k++) {
        expect(right.timeMap(rate).toSource(f(k + 60)), orig.toSource(f(k)), reason: 'right $k');
      }
    });

    test('the still time is the source time at the cut (FreezeFrame.sourceTimeAt) for ramped, fast and reversed clips',
        () {
      final c = clipOf(standard(), 'it_b');
      expect(FreezeFrame.sourceTimeAt(c, f(90), rate), c.timeMap(rate).toSource(f(90)));
      expect(FreezeFrame.sourceTimeAt(c, f(90) + 1000, rate), c.timeMap(rate).toSource(f(90)),
          reason: 'floored to the frame');
      final fast = c.copyWith(speed: const ConstantSpeed(2));
      expect(FreezeFrame.sourceTimeAt(fast, f(70), rate), fast.timeMap(rate).toSource(f(70)));
      final rev = c.copyWith(reversed: true);
      expect(FreezeFrame.sourceTimeAt(rev, f(70), rate), rev.timeMap(rate).toSource(f(70)));
      expect(FreezeFrame.sourceTimeAt(c, f(0), rate), c.timeMap(rate).toSource(f(60)), reason: 'limited to the clip');
      final ramp = c.copyWith(speed: SpeedRampPresets.byId('montage')!);
      expect(FreezeFrame.sourceTimeAt(ramp, f(100), rate), ramp.timeMap(rate).toSource(f(100)));
    });

    test('later items on the lane and the linked partners shift by the still length', () {
      final out = apply(withStill(), FreezeFrame(id('it_a'), f(30), sec(1), still));
      final orig = out.project.tracks.firstWhere((t) => t.id == const TrackId('tr_orig')).items;
      expect(orig.map((i) => (rate.frameIndexOf(i.start), rate.frameIndexOf(i.end))), [(0, 30), (60, 90)]);
      final main = out.project.tracks.firstWhere((t) => t.isMain).items;
      expect(rate.frameIndexOf(main.firstWhere((i) => i.id == id('it_b')).start), 90);
      expect(rate.frameIndexOf(main.firstWhere((i) => i.id == id('it_c')).start), 180);
      // The music lane has no link to the clip: unmoved.
      expect(out.project.tracks.firstWhere((t) => t.id == const TrackId('tr_music')),
          standard().tracks.firstWhere((t) => t.id == const TrackId('tr_music')));
      // The split right halves share a new link, the left halves keep the old one.
      final right = main.whereType<MediaClip>().firstWhere((c) => c.start == f(60));
      expect(right.link, isNot(const LinkId('ln_a')));
      expect(orig.last.link, right.link);
    });

    test('at the first frame the still goes before the clip without a split', () {
      final out = apply(withStill(), FreezeFrame(id('it_b'), f(60), sec(1), still));
      final main = out.project.tracks.firstWhere((t) => t.isMain).items.cast<MediaClip>();
      expect(main.map((c) => (rate.frameIndexOf(c.start), c.media.value)),
          [(0, 'md_video'), (60, 'md_still'), (90, 'md_video'), (180, 'md_video2')]);
      expect(main[2].id, const ItemId('it_b'));
      expect(out.project.tracks.firstWhere((t) => t.isMain).transitions, isEmpty, reason: 'a|b no longer touch');
    });

    test('the still copies the visual properties and bakes keyframed values at the cut', () {
      final base = withStill();
      final c = clipOf(base, 'it_c').copyWith(
        start: f(0),
        visual:
            VisualProps(transform: Transform2D(scale: 3, position: Vec2(0.1, 0.2)), adjust: ColorAdjust(contrast: 0.4)),
        keyframes: KeyframeSet({
          'transform.scale': KeyframeTrack([Keyframe(0, 1), Keyframe(f(50) - f(0), 2)]),
          'transform.position.x': KeyframeTrack([Keyframe(0, 0), Keyframe(f(60) - f(0) - 1, 1)]),
        }),
      );
      final p = project([
        lane('tr_main', TrackKind.video, [c], main: true)
      ], pool: withStill(media: 'md_video2').pool);
      final out = apply(p, FreezeFrame(id('it_c'), f(30), sec(1), still));
      final freeze = out.project.tracks.single.items.cast<MediaClip>().firstWhere((c) => c.media == still);
      expect(freeze.keyframes.isEmpty, isTrue);
      expect(freeze.visual!.transform.scale, closeTo(1.6, 1e-5));
      expect(freeze.visual!.transform.position.y, 0.2, reason: 'static channels stay');
      expect(freeze.visual!.transform.position.x, closeTo(evaluate(c, PropertyKeys.position, f(30) - f(0)).x, 1e-12));
      expect(freeze.visual!.adjust.contrast, 0.4);
    });

    test('the right half keeps the outgoing transition and the left the incoming one', () {
      final p0 = withStill();
      final p = p0.copyWith(
        timeline: Timeline(
          settings: p0.settings,
          tracks: [
            for (final t in p0.tracks)
              t.isMain
                  ? t.copyWith(
                      items: [...t.items.where((i) => i.id != id('it_c')), vclip('it_z', 120, 30, media: 'md_video2')],
                      transitions: [transition('tx_bz', 'it_b', 'it_z', kind: TransitionKind.fade)])
                  : t,
          ],
        ),
      );
      final out = apply(p, FreezeFrame(id('it_b'), f(90), sec(1), still));
      final main = out.project.tracks.firstWhere((t) => t.isMain);
      expect(main.transitions, hasLength(1));
      expect(main.transitions.single.right, id('it_z'));
      expect(main.transitions.single.left, isNot(id('it_b')), reason: 'moves to the right half');
    });

    test('a freeze past the media duration of a ramp still validates', () {
      final p0 = withStill();
      final c = clipOf(p0, 'it_b').copyWith(speed: SpeedRampPresets.byId('jumpCut'));
      final p = project([
        lane('tr_main', TrackKind.video, [c], main: true)
      ], pool: p0.pool);
      final out = apply(p, FreezeFrame(id('it_b'), f(80), sec(3), still));
      expect(out.project.tracks.single.items, hasLength(3));
    });

    test('rejections: time, duration, still, kind, locks, ripple', () {
      final p = withStill();
      final dur = sec(1);
      expect(reject(p, FreezeFrame(id('it_b'), f(120), dur, still)), NothingAtTime(f(120)),
          reason: 'the end is outside');
      expect(reject(p, FreezeFrame(id('it_b'), f(59), dur, still)), NothingAtTime(f(59)));
      expect(reject(p, FreezeFrame(id('it_b'), f(90), 0, still)), const InvalidValue('duration'));
      expect(reject(p, FreezeFrame(id('it_b'), f(90), -5, still)), const InvalidValue('duration'));
      expect(
          reject(standard(), FreezeFrame(id('it_b'), f(90), dur, still)), const MediaUnavailable(MediaId('md_still')));
      expect(reject(p, FreezeFrame(id('it_b'), f(90), dur, const MediaId('md_video'))),
          const MediaUnavailable(MediaId('md_video')));
      expect(reject(p, FreezeFrame(id('it_p1'), f(40), dur, still)), const UnsupportedForKind('image'));
      expect(reject(p, FreezeFrame(id('it_m'), f(40), dur, still)), const UnsupportedForKind('audio'));
      expect(reject(p, FreezeFrame(id('it_t1'), f(10), dur, still)), const UnsupportedForKind('text'));
      expect(reject(p, FreezeFrame(id('it_zzz'), f(10), dur, still)), const ItemNotFound('it_zzz'));
      expect(reject(withStill(media: 'md_video2'), FreezeFrame(id('it_b'), f(90), dur, still)),
          const InvalidValue('stillMedia'));
      expect(
          reject(withStill(extraOriginal: [aclip('it_x', 60, 30, media: 'md_music')]),
              FreezeFrame(id('it_a'), f(30), dur, still)),
          isA<RippleBlockedByLinkedItem>());
    });

    test('a locked lane, including a locked partner lane, rejects as data', () {
      final p = withStill();
      final lockedMain = p.copyWith(
          timeline: Timeline(
              settings: p.settings, tracks: [for (final t in p.tracks) t.isMain ? t.copyWith(locked: true) : t]));
      expect(reject(lockedMain, FreezeFrame(id('it_b'), f(90), sec(1), still)), const TrackLocked(TrackId('tr_main')));
      final lockedOrig = p.copyWith(
          timeline: Timeline(
              settings: p.settings,
              tracks: [for (final t in p.tracks) t.id == const TrackId('tr_orig') ? t.copyWith(locked: true) : t]));
      expect(reject(lockedOrig, FreezeFrame(id('it_a'), f(30), sec(1), still)), const TrackLocked(TrackId('tr_orig')));
    });

    test('the freeze lengthens the project and is subject to the limits', () {
      final p = withStill();
      final tooLong = reject(p, FreezeFrame(id('it_b'), f(90), 25 * 3600 * 1000000, still));
      expect(tooLong, isA<LimitExceeded>());
    });
  });
}
