// OWNER: CORE-10
//
// Property tests of the structural commands (BUILD_PLAN CORE-10):
// * split concatenation equals the original time map (and keyframe values) at every frame, for
//   constant speeds, ramps and reversed clips;
// * trim respects the source range and the one-frame minimum (exhaustive edge sweep);
// * ramps stay attached to content when trimmed;
// * ripple never moves items on unrelated lanes (random projects, random ripple commands).

import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../../support/random_project.dart';
import '../framework/ops_support.dart';

final MediaPool longPool = MediaPool({
  ...basePool.assets,
  const MediaId('md_long'): asset('md_long', MediaKind.video, duration: sec(3600), hasAudio: true),
});

SpeedSpec randomSpeed(Random rnd) {
  switch (rnd.nextInt(3)) {
    case 0:
      return ConstantSpeed(speedPresets[rnd.nextInt(speedPresets.length)]);
    case 1:
      return ConstantSpeed(0.1 + rnd.nextDouble() * 9.9);
    default:
      final n = 2 + rnd.nextInt(15);
      final xs = <double>{0, 1};
      while (xs.length < n) {
        xs.add((rnd.nextDouble() * 1000).round() / 1000);
      }
      final sorted = xs.toList()..sort();
      return SpeedRamp([for (final x in sorted) SpeedPoint(x, 0.1 + rnd.nextDouble() * 9.9)]);
  }
}

KeyframeSet randomOpacityKeys(Random rnd, int frames) {
  final times = <int>{};
  final count = rnd.nextInt(4);
  while (times.length < count) {
    times.add(rnd.nextInt(frames));
  }
  if (times.isEmpty) return KeyframeSet.empty;
  final sorted = times.toList()..sort();
  return KeyframeSet({
    'transform.opacity': KeyframeTrack([for (final k in sorted) Keyframe(f(10 + k) - f(10), rnd.nextDouble())]),
  });
}

void main() {
  group('split concatenation equals the original at every frame', () {
    for (var seed = 1; seed <= 300; seed++) {
      test('seed $seed', () {
        final rnd = Random(seed);
        final frames = 2 + rnd.nextInt(400);
        final speed = randomSpeed(rnd);
        final reversed = rnd.nextBool();
        final sourceIn = rnd.nextInt(sec(600));
        final clip = vclip('it_v', 10, frames,
            media: 'md_long', sourceIn: sourceIn, speed: speed, reversed: reversed, keyframes: randomOpacityKeys(rnd, frames));
        final before = project([lane('tr_main', TrackKind.video, [clip], main: true)], pool: longPool);
        final cut = 10 + 1 + rnd.nextInt(frames - 1);
        final out = applyCommand(before, SplitItems({clip.id}, f(cut)), ctx(seed: seed));
        expect(out.rejection, isNull);
        expectValid(out.project);
        final items = out.project.tracks.single.items.cast<MediaClip>();
        expect(items, hasLength(2));
        final original = ClipTimeMap.forClip(clip, rate);
        for (var k = 10; k < 10 + frames; k++) {
          final t = f(k);
          final half = t < f(cut) ? items[0] : items[1];
          final map = ClipTimeMap.forClip(half, rate);
          expect((map.toSource(t) - original.toSource(t)).abs(), lessThanOrEqualTo(2),
              reason: 'frame $k speed $speed reversed $reversed cut $cut');
          final a = evaluate(clip, PropertyKeys.opacity, t - clip.start);
          final b = evaluate(half, PropertyKeys.opacity, t - half.start);
          expect((a - b).abs(), lessThan(1e-9), reason: 'opacity at frame $k');
        }
        // The halves cover the original source range exactly (± 1 µs).
        final left = ClipTimeMap.forClip(items[0], rate);
        final right = ClipTimeMap.forClip(items[1], rate);
        final lo = reversed ? right.sourceIn : left.sourceIn;
        final hi = reversed ? left.sourceOut : right.sourceOut;
        expect((lo - original.sourceIn).abs(), lessThanOrEqualTo(1));
        expect((hi - original.sourceOut).abs(), lessThanOrEqualTo(2));
      });
    }
  });

  group('trim respects the source range and the one-frame minimum', () {
    for (final reversed in [false, true]) {
      for (final speed in [const ConstantSpeed(1), const ConstantSpeed(2.5), const ConstantSpeed(0.3)]) {
        test('${reversed ? 'reversed' : 'forward'} x${speed.rate}', () {
          // md_video2 is 10 s; the clip plays from 4 s.
          final clip = vclip('it_v', 300, 30, media: 'md_video2', sourceIn: sec(4), speed: speed, reversed: reversed);
          final before = project([lane('tr_main', TrackKind.video, [clip], main: true)]);
          for (final edge in TrimEdge.values) {
            for (var k = 0; k <= 1200; k += 7) {
              final out = applyCommand(before, TrimItem(clip.id, edge, f(k)), ctx());
              final r = out.rejection;
              if (r == null) {
                expectValid(out.project, 'edge $edge to $k');
                final c = out.project.tracks.single.items.single as MediaClip;
                expect(c.sourceIn, greaterThanOrEqualTo(0));
                expect(c.sourceIn + ClipTimeMap.sourceLengthOf(c.duration, c.speed), lessThanOrEqualTo(sec(10)));
                expect(rate.frameIndexOf(c.end) - rate.frameIndexOf(c.start), greaterThanOrEqualTo(1));
                // The untouched edge keeps showing the same source.
                final m0 = ClipTimeMap.forClip(clip, rate);
                final m1 = ClipTimeMap.forClip(c, rate);
                final fixed = edge == TrimEdge.end ? clip.start : f(329);
                expect((m1.toSource(fixed) - m0.toSource(fixed)).abs(), lessThanOrEqualTo(2), reason: 'edge $edge to $k');
              } else {
                expect(r, anyOf(isA<OutOfSourceRange>(), isA<BelowMinDuration>(), isA<InvalidValue>()), reason: 'edge $edge to $k');
                // Clamping gives the nearest valid edge, which itself applies.
                final clamped = applyCommand(before, TrimItem(clip.id, edge, f(k), clamp: true), ctx());
                expect(clamped.rejection, isNull);
                expectValid(clamped.project);
                final p = dryRun(before, TrimItem(clip.id, edge, f(k), clamp: true), ctx());
                expect(p.clampedTo, isNotNull);
              }
            }
          }
        });
      }
    }
  });

  test('a ramp stays attached to its content when trimmed and restored', () {
    final ramp = SpeedRamp(const [SpeedPoint(0, 1), SpeedPoint(0.5, 4), SpeedPoint(1, 0.5)]);
    final clip = vclip('it_v', 30, 120, media: 'md_long', sourceIn: sec(100), speed: ramp);
    final before = project([lane('tr_main', TrackKind.video, [clip], main: true)], pool: longPool);
    final m0 = ClipTimeMap.forClip(clip, rate);
    for (final (edge, k) in [(TrimEdge.end, 100), (TrimEdge.start, 70), (TrimEdge.end, 200), (TrimEdge.start, 5)]) {
      final out = applyCommand(before, TrimItem(clip.id, edge, f(k)), ctx());
      expect(out.rejection, isNull, reason: '$edge $k');
      expectValid(out.project);
      final c = out.project.tracks.single.items.single as MediaClip;
      final m1 = ClipTimeMap.forClip(c, rate);
      // Every frame both versions show agrees.
      final lo = max(c.start, clip.start);
      final hi = min(c.end, clip.end);
      for (var t = lo; t < hi; t = f(rate.frameIndexOf(t) + 1)) {
        expect((m1.toSource(t) - m0.toSource(t)).abs(), lessThanOrEqualTo(3), reason: '$edge $k at $t');
      }
      if (c.end > clip.end) {
        expect(m1.speedAt(c.end - 1), closeTo(0.5, 1e-6), reason: 'extension holds the end speed');
      }
      if (c.start < clip.start) {
        expect(m1.speedAt(c.start), closeTo(1, 1e-6), reason: 'extension holds the start speed');
      }
    }
  });

  group('ripple never moves items on unrelated lanes', () {
    for (var seed = 1; seed <= 60; seed++) {
      test('seed $seed', () {
        final p = randomProject(seed, const RandomProjectSpec(items: 80, frameRate: FrameRate.fps30));
        final rnd = Random(seed);
        final all = [
          for (final t in p.tracks)
            if (!t.locked)
              for (final i in t.items) (t, i),
        ];
        if (all.isEmpty) return;
        for (var n = 0; n < 12; n++) {
          final (lane, item) = all[rnd.nextInt(all.length)];
          final EditCommand cmd = switch (rnd.nextInt(5)) {
            0 => DeleteItems({item.id}, ripple: true),
            1 => TrimItem(item.id, TrimEdge.end, item.end - f(1 + rnd.nextInt(5)), ripple: true, clamp: true),
            2 => TrimItem(item.id, TrimEdge.start, item.start + f(1 + rnd.nextInt(5)), ripple: true, clamp: true),
            3 => MoveItems({item.id}, f(rnd.nextInt(90)) - f(45), ripple: true, clamp: true),
            _ => DeleteGap(GapRef(lane.id, TimeRange(item.end, item.end + f(1)))),
          };
          final out = applyCommand(p, cmd, ctx(seed: seed * 100 + n));
          if (out.rejection != null) {
            expect(out.rejection, isNot(isA<InternalInconsistency>()), reason: '$cmd');
            continue;
          }
          if (out.noop) continue;
          expectValid(out.project, '$cmd');
          // The edited lanes are the lanes of the command's items (plus link partners for
          // deletes and trims); every other lane may only change by link partners moving.
          final idx = p.index;
          final group = <ItemId>{item.id};
          final link = item.link;
          if (link != null) {
            for (final t in p.tracks) {
              for (final i in t.items) {
                if (i.link == link) group.add(i.id);
              }
            }
          }
          final edited = {for (final id in group) idx.locate(id)!.track.id, lane.id};
          // Partners of moved items may move on other lanes, by the same amount as their group.
          for (final t in out.project.tracks) {
            if (edited.contains(t.id)) continue;
            final before = p.tracks.where((x) => x.id == t.id).firstOrNull;
            if (before == null) continue; // a lane the command created
            for (final i in t.items) {
              final old = before.items.where((x) => x.id == i.id).firstOrNull;
              if (old == null) continue; // placed here by the command
              if (old.start == i.start) continue;
              expect(i.link, isNotNull, reason: '$cmd moved an unlinked item ${i.id} on an unrelated lane');
              final mates = [
                for (final tt in out.project.tracks)
                  for (final x in tt.items)
                    if (x.link == i.link && x.id != i.id) x,
              ];
              final shift = rate.frameIndexOf(i.start) - rate.frameIndexOf(old.start);
              expect(
                mates.any((m) {
                  final o = idx.item(m.id);
                  return o != null && rate.frameIndexOf(m.start) - rate.frameIndexOf(o.start) == shift;
                }),
                isTrue,
                reason: '$cmd moved ${i.id} without its group',
              );
            }
          }
        }
      });
    }
  });
}
