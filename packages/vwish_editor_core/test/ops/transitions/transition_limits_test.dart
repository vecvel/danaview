// OWNER: CORE-16
//
// TransitionLimits.of (BUILD_PLAN CORE-16): handles, speed at the edge, reversed clips, images,
// neighbouring transitions, non-cuts; and agreement with the validator's I5 on random projects.

import 'package:test/test.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';

import '../../support/random_project.dart';
import '../framework/ops_support.dart';

TransitionRef ref(String track, String l, String r) => TransitionRef(TrackId(track), ItemId(l), ItemId(r));

EditProject twoClips(MediaClip a, MediaClip b, {List<Transition> transitions = const []}) =>
    project([lane('v', TrackKind.video, [a, b], main: true, transitions: transitions)]);

int of(EditProject p, [TransitionKind? kind, String l = 'a', String r = 'b']) =>
    TransitionLimits.of(p, ref('v', l, r), kind: kind);

void main() {
  group('clip frames bound every kind', () {
    final p = twoClips(vclip('a', 0, 300, sourceIn: sec(5)), vclip('b', 300, 90, sourceIn: sec(5)));

    test('fade, dips: 2 * min(leftAvail, rightAvail)', () {
      for (final k in [TransitionKind.fade, TransitionKind.dipToBlack, TransitionKind.dipToWhite]) {
        expect(of(p, k), 180, reason: k.name);
      }
    });

    test('overlap kinds: the same bound when handles are long', () {
      for (final k in [TransitionKind.crossDissolve, TransitionKind.slide, TransitionKind.wipe, TransitionKind.zoom]) {
        expect(of(p, k), 180, reason: k.name);
      }
    });
  });

  group('handles', () {
    // b starts 1 s (30 frames) into the media: only 30 frames of handle before it.
    final p = twoClips(vclip('a', 0, 300), vclip('b', 300, 300, sourceIn: sec(1)));

    test('overlap kinds are limited to 2 * min(leftHandle, rightHandle)', () {
      expect(of(p, TransitionKind.crossDissolve), 60);
      expect(of(p, TransitionKind.slide), 60);
      expect(of(p, TransitionKind.wipe), 60);
      expect(of(p, TransitionKind.zoom), 60);
    });

    test('fade and dips ignore handles', () {
      expect(of(p, TransitionKind.fade), 600);
      expect(of(p, TransitionKind.dipToBlack), 600);
      expect(of(p, TransitionKind.dipToWhite), 600);
    });

    test('no handle at all: overlap kinds are 0', () {
      final q = twoClips(vclip('a', 0, 300), vclip('b', 300, 300));
      expect(of(q, TransitionKind.crossDissolve), 0);
      expect(of(q, TransitionKind.fade), 600);
    });

    test('the left handle counts whole frames after the left clip (media end)', () {
      // md_video2 is 10 s; the left clip uses [0, 9.5 s) -> 0.5 s = 15 frames after it.
      final q = twoClips(vclip('a', 0, 285, media: 'md_video2'), vclip('b', 285, 300, sourceIn: sec(20)));
      expect(of(q, TransitionKind.crossDissolve), 30);
    });

    test('a missing asset has no handle', () {
      final q = twoClips(vclip('a', 0, 60, media: 'md_gone'), vclip('b', 60, 60, sourceIn: sec(5)));
      expect(of(q, TransitionKind.crossDissolve), 0);
    });
  });

  group('speed at the edge divides the handle', () {
    test('2x on the right clip halves the handle before it', () {
      final q = twoClips(vclip('a', 0, 300), vclip('b', 300, 300, sourceIn: sec(1), speed: const ConstantSpeed(2)));
      // 1 s of source before b at 2x -> 0.5 s = 15 frames.
      expect(of(q, TransitionKind.crossDissolve), 30);
    });

    test('0.5x on the left clip doubles the handle after it', () {
      // The left clip plays [0, 5 s) of md_video2 (10 s) at 0.5x: 10 s of timeline; 5 s of source
      // remain after it = 10 s of timeline at 0.5x = 300 frames.
      final q = twoClips(vclip('a', 0, 300, media: 'md_video2', speed: const ConstantSpeed(0.5)), vclip('b', 300, 300, sourceIn: sec(20)));
      expect(of(q, TransitionKind.crossDissolve), 600);
    });

    test('a ramp uses the speed at the edge that touches the cut', () {
      final ramp = SpeedRamp([const SpeedPoint(0, 0.5), const SpeedPoint(1, 2)]);
      final b = vclip('b', 300, 120, sourceIn: sec(1), speed: ramp);
      final q = twoClips(vclip('a', 0, 300), b);
      // 1 s of source before b at the ramp's start speed 0.5x -> 2 s = 60 frames.
      expect(of(q, TransitionKind.crossDissolve), 120);
    });
  });

  group('reversed clips mirror the handles', () {
    test('a reversed left clip continues into the source before its range', () {
      final a = vclip('a', 0, 300, sourceIn: sec(1), reversed: true);
      final q = twoClips(a, vclip('b', 300, 300, sourceIn: sec(30)));
      // The reversed end edge plays the range's start: 1 s = 30 frames before it.
      expect(of(q, TransitionKind.crossDissolve), 60);
    });

    test('a reversed right clip starts at the source after its range', () {
      // b plays [50 s, 60 s) of the 60 s video backwards: nothing after it -> no handle.
      final b = vclip('b', 300, 300, sourceIn: sec(50), reversed: true);
      final q = twoClips(vclip('a', 0, 300), b);
      expect(of(q, TransitionKind.crossDissolve), 0);
      // The forward clip would have 50 s of handle before it.
      final fwd = twoClips(vclip('a', 0, 300), vclip('b', 300, 300, sourceIn: sec(50)));
      expect(of(fwd, TransitionKind.crossDissolve), 600);
    });
  });

  group('images and stills are unbounded', () {
    test('a cut between images is limited only by the clip lengths', () {
      final q = twoClips(vclip('a', 0, 30, media: 'md_image'), vclip('b', 30, 90, media: 'md_image'));
      for (final k in TransitionKind.values) {
        expect(of(q, k), 60, reason: k.name);
      }
    });

    test('an image next to a video uses the video handle', () {
      final q = twoClips(vclip('a', 0, 300, media: 'md_image'), vclip('b', 300, 300, sourceIn: sec(1)));
      expect(of(q, TransitionKind.crossDissolve), 60);
    });
  });

  group('neighbouring transitions use up room', () {
    test('a transition at the left clip start and one at the right clip end are subtracted', () {
      final p = project([
        lane('v', TrackKind.video, [vclip('a', 0, 60), vclip('b', 60, 60), vclip('c', 120, 60)], main: true, transitions: [
          transition('t1', 'a', 'b', kind: TransitionKind.fade, frames: 40),
        ]),
      ]);
      // b|c: b's start holds ceil(40/2)=20 frames of t1 -> leftAvail 40; right has no neighbour.
      expect(TransitionLimits.of(p, ref('v', 'b', 'c'), kind: TransitionKind.fade), 80);
      final q = project([
        lane('v', TrackKind.video, [vclip('a', 0, 60), vclip('b', 60, 60), vclip('c', 120, 60)], main: true, transitions: [
          transition('t2', 'b', 'c', kind: TransitionKind.fade, frames: 41),
        ]),
      ]);
      // a|b: b's end holds floor(41/2)=20 frames -> rightAvail 40 -> 80.
      expect(TransitionLimits.of(q, ref('v', 'a', 'b'), kind: TransitionKind.fade), 80);
    });

    test('the transition at the cut itself is not counted against itself', () {
      final p = twoClips(vclip('a', 0, 60), vclip('b', 60, 60), transitions: [transition('t', 'a', 'b', kind: TransitionKind.fade, frames: 100)]);
      expect(of(p, TransitionKind.fade), 120);
      expect(of(p), 120, reason: 'default kind is the existing transition kind');
    });
  });

  group('default kind and ofAll', () {
    test('without a transition the default is the most restrictive kind', () {
      final p = twoClips(vclip('a', 0, 300), vclip('b', 300, 300, sourceIn: sec(1)));
      expect(of(p), 60);
      final all = TransitionLimits.ofAll(p, ref('v', 'a', 'b'));
      expect(all[TransitionKind.fade], 600);
      expect(all[TransitionKind.crossDissolve], 60);
      expect(all.length, TransitionKind.values.length);
    });
  });

  group('not a cut', () {
    final p = project([
      lane('v', TrackKind.video, [vclip('a', 0, 60), vclip('b', 70, 60), vclip('c', 130, 60)], main: true),
      lane('ov', TrackKind.overlay, [vclip('o1', 0, 30, media: 'md_image'), vclip('o2', 30, 30, media: 'md_image')]),
      lane('t', TrackKind.text, [text('x', 0, 30), text('y', 30, 30)]),
      lane('au', TrackKind.audio, [aclip('m1', 0, 30), aclip('m2', 30, 30)], role: AudioRole.music),
    ]);

    test('gap, non-neighbours, wrong order, unknown ids and lanes', () {
      expect(TransitionLimits.of(p, ref('v', 'a', 'b')), 0, reason: 'gap');
      expect(TransitionLimits.of(p, ref('v', 'a', 'c')), 0, reason: 'not neighbours');
      expect(TransitionLimits.of(p, ref('v', 'c', 'b')), 0, reason: 'wrong order');
      expect(TransitionLimits.of(p, ref('v', 'a', 'zz')), 0);
      expect(TransitionLimits.of(p, ref('zz', 'a', 'b')), 0);
      expect(TransitionLimits.isCut(p, ref('v', 'b', 'c')), isTrue);
      expect(TransitionLimits.isCut(p, ref('v', 'a', 'b')), isFalse);
    });

    test('overlay lanes take transitions; text and audio lanes do not', () {
      expect(TransitionLimits.of(p, ref('ov', 'o1', 'o2'), kind: TransitionKind.fade), 60);
      expect(TransitionLimits.of(p, ref('t', 'x', 'y')), 0);
      expect(TransitionLimits.of(p, ref('au', 'm1', 'm2')), 0);
    });

    test('cutsOf lists touching media pairs of visual lanes only', () {
      expect(TransitionLimits.cutsOf(p.tracks[0]).map((r) => '${r.left}|${r.right}'), ['b|c']);
      expect(TransitionLimits.cutsOf(p.tracks[1]).length, 1);
      expect(TransitionLimits.cutsOf(p.tracks[2]), isEmpty);
      expect(TransitionLimits.cutsOf(p.tracks[3]), isEmpty);
    });

    test('at() finds the transition on a cut', () {
      final q = twoClips(vclip('a', 0, 60), vclip('b', 60, 60), transitions: [transition('t', 'a', 'b')]);
      expect(TransitionLimits.at(q, ref('v', 'a', 'b'))?.id, TransitionId('t'));
      expect(TransitionLimits.at(q, ref('v', 'b', 'a')), isNull);
    });
  });

  group('agrees with the validator (I5)', () {
    test('max passes, max + 1 fails, on every transition of 60 random projects', () {
      var checked = 0;
      for (var seed = 0; seed < 60; seed++) {
        final p = randomProject(seed);
        for (final track in p.tracks) {
          for (final tr in track.transitions) {
            final r = TransitionRef(track.id, tr.left, tr.right);
            final max = TransitionLimits.of(p, r);
            expect(max, greaterThanOrEqualTo(tr.durationFrames), reason: 'seed $seed ${tr.id}: a valid transition fits its own limit');
            for (final (frames, valid) in [(max, true), (max + 1, false)]) {
              final changed = p.copyWith(
                timeline: p.timeline.copyWith(tracks: [
                  for (final t in p.tracks)
                    t.id != track.id
                        ? t
                        : t.copyWith(transitions: [for (final x in t.transitions) x.id == tr.id ? x.copyWith(durationFrames: frames) : x]),
                ]),
              );
              final bad = [for (final v in validate(changed)) if (v.code == ViolationCode.transitionTooLong && v.subject == tr.id) v];
              expect(bad.isEmpty, valid, reason: 'seed $seed ${tr.id} at $frames (max $max): $bad');
            }
            checked++;
          }
        }
      }
      expect(checked, greaterThan(40));
    });
  });
}
