// OWNER: CORE-10
//
// Source ranges never overshoot the media by a rounding microsecond (nightly fuzz I4
// sourceOutOfRange, seeds 8491927 and 8491590; fixtures in test/fuzz/regressions/):
//
// * SplitItems: the half that plays the end of the source range ends exactly at the clip's
//   sourceOut, also when its cropped ramp re-rounds its derived length;
// * MoveItems (and every command that re-times by whole frames: paste, duplicate, delete gap,
//   ripple): a clip that plays its whole media from 0 stays inside it on a 24 fps grid, where
//   frames are 41666 or 41667 µs long;
// * projects saved with such a 1 µs overshoot still open: repair pulls sourceIn back (no frame
//   lost) or, at sourceIn 0, drops the last frame.

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../../time_map/speed_math_test.dart' show randomRamp;
import '../framework/ops_support.dart';

const FrameRate r24 = FrameRate.fps24;

MediaPool tightPool(TimeUs duration) =>
    MediaPool({const MediaId('md_tight'): asset('md_tight', MediaKind.video, duration: duration, hasAudio: true)});

MediaClip clip24(int k0, int n, {TimeUs sourceIn = 0, SpeedSpec speed = SpeedSpec.normal, bool reversed = false}) =>
    MediaClip(
      id: const ItemId('it_v'),
      start: r24.timeOfFrame(k0),
      duration: r24.timeOfFrame(k0 + n) - r24.timeOfFrame(k0),
      media: const MediaId('md_tight'),
      sourceIn: sourceIn,
      speed: speed,
      reversed: reversed,
      visual: VisualProps.neutral,
    );

void main() {
  test('SplitItems: the far half ends exactly at sourceOut (ramps, forward and reversed, media cut to the clip)', () {
    final rnd = math.Random(8491927);
    for (var trial = 0; trial < 400; trial++) {
      final frames = 20 + rnd.nextInt(400);
      final reversed = rnd.nextBool();
      final c = vclip('it_v', 10, frames, media: 'md_tight', sourceIn: rnd.nextInt(sec(300)), speed: randomRamp(rnd), reversed: reversed);
      final out0 = c.sourceOut;
      final before = project([lane('tr_main', TrackKind.video, [c], main: true)], pool: tightPool(out0));
      final cut = 11 + rnd.nextInt(frames - 1);
      final out = applyCommand(before, SplitItems({c.id}, f(cut)), ctx(seed: trial));
      expect(out.rejection, isNull, reason: 'trial $trial');
      expectValid(out.project, 'trial $trial');
      final halves = out.project.tracks.single.items.cast<MediaClip>();
      final far = reversed ? halves.first : halves.last;
      expect(far.sourceOut, out0, reason: 'trial $trial');
    }
  });

  test('MoveItems: a clip playing its whole media stays inside it on the 24 fps grid', () {
    var grew = 0;
    for (var k0 = 0; k0 < 24; k0++) {
      final c = clip24(k0, 98);
      final media = c.duration; // the clip plays the media from 0 to its end
      final before = project([lane('tr_main', TrackKind.video, [c], main: true)], pool: tightPool(media), frameRate: r24);
      for (var s = 1; s < 24; s++) {
        final delta = r24.timeOfFrame(k0 + s) - r24.timeOfFrame(k0);
        final out = applyCommand(before, MoveItems({c.id}, delta), ctx());
        expect(out.rejection, isNull, reason: 'from frame $k0 by $s');
        expectValid(out.project, 'from frame $k0 by $s');
        final moved = out.project.tracks.single.items.single as MediaClip;
        expect(moved.start, r24.timeOfFrame(k0 + s));
        expect(moved.sourceIn, 0);
        expect(moved.sourceOut, lessThanOrEqualTo(media));
        final span = r24.timeOfFrame(k0 + s + 98) - r24.timeOfFrame(k0 + s);
        if (span > media) {
          grew++;
          expect(moved.duration, r24.timeOfFrame(k0 + s + 97) - r24.timeOfFrame(k0 + s), reason: 'drops the last frame');
        } else {
          expect(moved.duration, span);
        }
      }
    }
    expect(grew, greaterThan(0), reason: 'the sweep meets the 1 µs longer spans');
  });

  group('projects saved with a 1 µs overshoot still open', () {
    EditProject saved(MediaClip c, TimeUs media) {
      final p = project([lane('tr_main', TrackKind.video, [c], main: true)], pool: tightPool(media), frameRate: r24);
      final decoded = ProjectJsonCodec().decode(ProjectJsonCodec().encode(p));
      expect(validate(decoded.project).map((v) => v.code), contains(ViolationCode.sourceOutOfRange));
      return decoded.project;
    }

    test('sourceIn > 0: repair pulls sourceIn back by the overshoot and keeps every frame', () {
      final c = clip24(3, 98, sourceIn: sec(5), speed: SpeedRamp([const SpeedPoint(0, 0.7), const SpeedPoint(1, 2.3)]));
      final (fixed, warnings) = repair(saved(c, c.sourceOut - 1));
      expect(validate(fixed), isEmpty);
      expect(warnings.map((w) => w.code), contains(RepairCodes.sourceRangeClamped));
      final m = fixed.tracks.single.items.single as MediaClip;
      expect(m.duration, c.duration);
      expect(m.sourceIn, sec(5) - 1);
      expect(m.sourceOut, c.sourceOut - 1);
    });

    test('sourceIn 0: repair drops the last frame', () {
      final c = clip24(3, 98);
      final (fixed, warnings) = repair(saved(c, c.duration - 1));
      expect(validate(fixed), isEmpty);
      expect(warnings.map((w) => w.code), contains(RepairCodes.sourceRangeClamped));
      final m = fixed.tracks.single.items.single as MediaClip;
      expect(m.duration, r24.timeOfFrame(3 + 97) - r24.timeOfFrame(3));
    });
  });
}
