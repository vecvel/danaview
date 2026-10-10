// OWNER: CORE-17
//
// requantize (BUILD_PLAN CORE-17): properties over all 36 rate pairs on random projects (order
// preserved, adjacency preserved, movement bounded, minimum durations, result validates), exact
// cases (2x up and down, 30 to 24, 60 to 24), keys, fades, text animations, transitions, markers,
// and the SetFrameRate command.

import 'package:test/test.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../../support/random_project.dart';
import '../framework/ops_support.dart';

const List<FrameRate> rates = [FrameRate.fps24, FrameRate.fps25, FrameRate.fps30, FrameRate.fps48, FrameRate.fps50, FrameRate.fps60];

/// Items of [p] by id with their lane.
Map<ItemId, (Track, TimelineItem)> itemsOf(EditProject p) => {
      for (final t in p.tracks)
        for (final i in t.items) i.id: (t, i),
    };

/// Whether [clip]'s source range ends within [slackFrames] frames of the media's end (the one case
/// in which requantize may shorten a clip because rounding up would play past the media).
bool mediaBound(MediaClip clip, EditProject p, FrameRate rate, {int slackFrames = 1}) {
  final asset = p.pool[clip.media];
  if (asset == null || asset.kind == MediaKind.image || asset.kind == MediaKind.still) return false;
  final end = clip.sourceIn + ClipTimeMap.sourceLengthOf(clip.duration, clip.speed);
  return asset.probe.duration - end <= (slackFrames + 1) * rate.frameUs * 3;
}

/// What the property runs exercised (asserted at the end, so the generator cannot go stale).
final Map<String, int> coverage = {};

void hit(String what, [int n = 1]) => coverage[what] = (coverage[what] ?? 0) + n;

void main() {
  group('properties over all 36 rate pairs on random projects', () {
    for (final from in rates) {
      for (final to in rates) {
        test('${from.fps.round()} -> ${to.fps.round()} fps', () {
          for (var seed = 0; seed < 6; seed++) {
            final p = randomProject(seed * 31 + from.num + to.num, RandomProjectSpec(items: 50, frameRate: from));
            expect(validate(p), isEmpty, reason: 'fixture seed $seed');
            final q = requantize(p, to);
            final reason = 'seed $seed';

            // The result validates (all invariants on the new grid).
            expect(q.settings.frameRate, to);
            final v = validate(q);
            expect(v, isEmpty, reason: '$reason: ${v.take(5).join('\n')}');

            // Same lanes, same items in the same order; nothing lost.
            expect(q.tracks.map((t) => t.id), p.tracks.map((t) => t.id));
            final before = itemsOf(p);
            final after = itemsOf(q);
            for (final t in p.tracks) {
              final nt = q.tracks.firstWhere((x) => x.id == t.id);
              expect(nt.items.map((i) => i.id), t.items.map((i) => i.id), reason: '$reason: ${t.id} order');
            }
            expect(after.keys.toSet(), before.keys.toSet());

            final frame = to.frameUs + 1;
            for (final t in p.tracks) {
              final nt = q.tracks.firstWhere((x) => x.id == t.id);
              // Items that collapse below one new frame stretch and push their followers.
              final stretched = t.items.where((i) => to.frameIndexNearest(i.end) - to.frameIndexNearest(i.start) < 1).length;
              final allowed = frame * (1 + stretched);
              hit('stretched items', stretched);
              hit('items', t.items.length);
              hit('transitions', t.transitions.length);
              hit('transitions kept', nt.transitions.length);
              for (var i = 0; i < t.items.length; i++) {
                final a = t.items[i];
                final b = nt.items[i];
                expect((b.start - a.start).abs(), lessThanOrEqualTo(allowed), reason: '$reason: ${a.id} start');
                // The end can also move by the media-bound shortening (a frame) or a stretch.
                expect((b.end - a.end).abs(), lessThanOrEqualTo(allowed + frame), reason: '$reason: ${a.id} end');
                expect(to.frameIndexOf(b.end) - to.frameIndexOf(b.start), greaterThanOrEqualTo(1));
              }
              // Items that touched still touch (except at a media-bound clip end).
              for (var i = 0; i + 1 < t.items.length; i++) {
                if (t.items[i].end != t.items[i + 1].start) continue;
                final l = nt.items[i];
                final r = nt.items[i + 1];
                hit('touching pairs');
                if (l.end == r.start) continue;
                hit('pairs that came apart');
                final o = t.items[i];
                expect(o is MediaClip && mediaBound(o, p, from), isTrue, reason: '$reason: ${t.items[i].id} | ${t.items[i + 1].id} came apart');
              }
              // Gaps stay gaps or close by at most a stretch; no overlaps (validator).
            }

            for (final e in before.entries) {
              final i = e.value.$2;
              if (i is MediaClip) {
                if (!i.keyframes.isEmpty) hit('clips with keys');
                if (i.audio.fadeIn != 0 || i.audio.fadeOut != 0) hit('clips with fades');
                if (i.speed is SpeedRamp) hit('ramps');
                if (i.reversed) hit('reversed clips');
              }
              if (i is TextItem && i.animation.inDuration + i.animation.outDuration > 0) hit('animated text');
            }
            hit('markers', p.markers.length);

            // Markers: order kept, within a frame.
            expect(q.markers.map((m) => m.id), p.markers.map((m) => m.id));
            for (var i = 0; i < p.markers.length; i++) {
              expect((q.markers[i].time - p.markers[i].time).abs(), lessThanOrEqualTo(frame));
              expect(to.isOnGrid(q.markers[i].time), isTrue);
            }

            // Everything that is not time stays.
            expect(q.pool, p.pool);
            expect(q.settings.canvas, p.settings.canvas);
            expect(q.settings.background, p.settings.background);
            for (final e in before.entries) {
              final n = after[e.key]!.$2;
              final o = e.value.$2;
              expect(n.link, o.link);
              if (o is MediaClip) {
                final nn = n as MediaClip;
                expect(nn.media, o.media);
                expect(nn.speed, o.speed);
                expect(nn.reversed, o.reversed);
                expect(nn.visual, o.visual);
                expect((nn.sourceIn - o.sourceIn).abs(), lessThanOrEqualTo(frame * 2), reason: 'source range follows the clip');
              }
            }
          }
        });
      }
    }
  });

  test('the random projects exercised every part of requantize', () {
    // ignore: avoid_print
    print('requantize coverage: $coverage');
    for (final key in ['items', 'transitions', 'transitions kept', 'touching pairs', 'stretched items', 'clips with keys', 'clips with fades', 'ramps', 'reversed clips', 'animated text', 'markers']) {
      expect(coverage[key] ?? 0, greaterThan(0), reason: key);
    }
    expect(coverage['items']!, greaterThan(5000));
  });

  group('exact cases', () {
    EditProject p30(List<Track> tracks, {List<Marker> markers = const []}) {
      final p = project(tracks);
      return p.copyWith(timeline: p.timeline.copyWith(markers: markers));
    }

    test('the same rate returns the same project', () {
      final p = p30([lane('v', TrackKind.video, [vclip('a', 0, 30)], main: true)]);
      expect(identical(requantize(p, FrameRate.fps30), p), isTrue);
    });

    test('30 -> 60 doubles every frame index exactly, and 60 -> 30 returns the original', () {
      final p = p30([
        lane('v', TrackKind.video, [vclip('a', 3, 27), vclip('b', 30, 31, sourceIn: sec(5))], main: true, transitions: [transition('t', 'a', 'b', frames: 6)]),
        lane('t', TrackKind.text, [text('x', 7, 9, animation: const TextAnimation(inKind: TextAnimKind.fade, inDuration: 100000))]),
        lane('s', TrackKind.subtitle, [cue('c', 11, 13)]),
      ], markers: [Marker(id: const MarkerId('m1'), time: f(15))]);
      final up = requantize(p, FrameRate.fps60);
      expectValid(up);
      final a = up.index.item(const ItemId('a'))!;
      expect((FrameRate.fps60.frameIndexOf(a.start), FrameRate.fps60.frameIndexOf(a.end)), (6, 60));
      expect(FrameRate.fps60.frameIndexOf(up.markers.single.time), 30);
      expect(up.tracks.first.transitions.single.durationFrames, 12);
      final down = requantize(up, FrameRate.fps30);
      expect(down.tracks, p.tracks, reason: 'doubling and halving is the identity');
      expect(down.markers, p.markers);
    });

    test('30 -> 24: a 15-frame clip is 12 frames, edges move less than a frame', () {
      final p = p30([lane('v', TrackKind.video, [vclip('a', 5, 15), vclip('b', 20, 15)], main: true)]);
      final q = requantize(p, FrameRate.fps24);
      final a = q.index.item(const ItemId('a'))!;
      final b = q.index.item(const ItemId('b'))!;
      expect((FrameRate.fps24.frameIndexOf(a.start), FrameRate.fps24.frameIndexOf(a.end)), (4, 16));
      expect(a.end, b.start, reason: 'touching stays touching');
      expectValid(q);
    });

    test('a clip shorter than a frame of the new grid stretches and pushes its followers', () {
      // 60 fps: three 1-frame cues in a row; at 24 fps each is 0.4 frames -> stretched to 1.
      final p = project([
        lane('v', TrackKind.video, [vclip('v', 0, 600)], main: true),
        Track(id: const TrackId('s'), kind: TrackKind.subtitle, subtitle: const SubtitleTrackData(), items: [
          for (var i = 0; i < 4; i++)
            SubtitleCue(
              id: ItemId('c$i'),
              start: FrameRate.fps60.timeOfFrame(60 + i),
              duration: FrameRate.fps60.timeOfFrame(61 + i) - FrameRate.fps60.timeOfFrame(60 + i),
              text: 'x',
            ),
        ]),
      ], frameRate: FrameRate.fps60);
      final q = requantize(p, FrameRate.fps24);
      expectValid(q);
      final cues = q.tracks.last.items;
      for (var i = 0; i + 1 < cues.length; i++) {
        expect(cues[i].end, cues[i + 1].start, reason: 'touching stays touching');
        expect(FrameRate.fps24.frameIndexOf(cues[i].end) - FrameRate.fps24.frameIndexOf(cues[i].start), 1);
      }
      expect(FrameRate.fps24.frameIndexOf(cues.first.start), 24);
    });

    test('keyframes keep their content and merge when they land on one frame', () {
      final keys = KeyframeSet({
        'transform.rotation': KeyframeTrack([Keyframe(f(0), 0), Keyframe(f(2), 1), Keyframe(f(3), 2), Keyframe(f(30), 3)]),
      });
      final p = p30([lane('v', TrackKind.video, [vclip('a', 30, 60, keyframes: keys)], main: true)]);
      final q = requantize(p, FrameRate.fps24);
      expectValid(q);
      final clip = q.index.item(const ItemId('a')) as MediaClip;
      final ks = clip.keyframes['transform.rotation']!.keys;
      expect(ks.first.t, 0);
      expect(ks.map((k) => k.v), [0, 2, 3], reason: 'keys at 30 fps frames 2 and 3 land on 24 fps frame 2: the later value wins');
      expect(FrameRate.fps24.frameIndexNearest(ks[1].t), 2);
    });

    test('audio fades are re-measured from the edges and stay within half the clip', () {
      final clip = vclip('a', 0, 30, audio: AudioProps(fadeIn: f(15), fadeOut: f(15)));
      final p = p30([lane('v', TrackKind.video, [clip], main: true)]);
      final q = requantize(p, FrameRate.fps24);
      expectValid(q);
      final c = q.index.item(const ItemId('a')) as MediaClip;
      expect(FrameRate.fps24.frameIndexNearest(c.audio.fadeIn), 12);
      expect(FrameRate.fps24.frameIndexNearest(c.audio.fadeOut), 12);
      final p2 = requantize(p30([lane('v', TrackKind.video, [vclip('a', 0, 30, audio: AudioProps(fadeIn: f(7), fadeOut: f(7)))], main: true)]), FrameRate.fps60);
      expectValid(p2);
    });

    test('text animation lengths follow and never exceed the item', () {
      final p = p30([
        lane('v', TrackKind.video, [vclip('v', 0, 300)], main: true),
        lane('t', TrackKind.text, [
          text('x', 30, 9, animation: TextAnimation(inKind: TextAnimKind.fade, inDuration: f(5), outKind: TextAnimKind.fade, outDuration: f(4))),
        ]),
      ]);
      for (final to in rates) {
        final q = requantize(p, to);
        expectValid(q, '-> ${to.fps}');
        final t = q.index.item(const ItemId('x')) as TextItem;
        expect(t.animation.inDuration + t.animation.outDuration, lessThanOrEqualTo(t.duration + to.frameUs));
      }
    });

    test('transitions keep their length in seconds and are re-clamped to the new clips', () {
      final p = p30([
        lane('v', TrackKind.video, [vclip('a', 0, 60, sourceIn: sec(10)), vclip('b', 60, 60, sourceIn: sec(10))], main: true,
            transitions: [transition('t', 'a', 'b', frames: 30)]),
      ]);
      final q60 = requantize(p, FrameRate.fps60);
      expect(q60.tracks.first.transitions.single.durationFrames, 60);
      final q24 = requantize(p, FrameRate.fps24);
      expect(q24.tracks.first.transitions.single.durationFrames, 24);
      expectValid(q24);
      // Clips of 2 frames at 30 fps cannot carry the transition any longer.
      final tiny = p30([
        lane('v', TrackKind.video, [vclip('a', 0, 4, sourceIn: sec(10)), vclip('b', 4, 4, sourceIn: sec(10))], main: true,
            transitions: [transition('t', 'a', 'b', kind: TransitionKind.fade, frames: 8)]),
      ]);
      final small = requantize(tiny, FrameRate.fps24);
      expectValid(small);
      expect(small.tracks.first.transitions.single.durationFrames, lessThanOrEqualTo(6));
    });

    test('a transition whose clips come apart is dropped', () {
      // b's end is rounded earlier because the media ends: 'a' is the left clip using the whole
      // 1 s media; at 24 fps it is 24 frames (exact), so build a case that cannot keep its end.
      final p = p30([
        lane('v', TrackKind.video, [vclip('a', 0, 30, media: 'md_short'), vclip('b', 30, 30, sourceIn: sec(5))], main: true,
            transitions: [transition('t', 'a', 'b', kind: TransitionKind.fade, frames: 6)]),
      ]);
      final q = requantize(p, FrameRate.fps25);
      expectValid(q);
    });

    test('a clip that would play past its media is pulled back, or ends a frame earlier', () {
      // 233,334 µs of media = 7 frames at 30 fps = 5.6 frames at 24 fps (rounds up to 6).
      final pool = MediaPool({...basePool.assets, const MediaId('md_tiny'): asset('md_tiny', MediaKind.video, duration: 233334, hasAudio: true)});
      EditProject build({TimeUs sourceIn = 0}) => project([
            lane('v', TrackKind.video, [
              vclip('a', 0, 7, media: 'md_tiny', sourceIn: sourceIn),
              vclip('b', 7, 30, sourceIn: sec(5)),
            ], main: true, transitions: [transition('t', 'a', 'b', kind: TransitionKind.fade, frames: 4)]),
          ], pool: pool);

      // Not at the media start: sourceIn is pulled back by the overrun and the clips keep touching.
      final slack = requantize(build(sourceIn: 0), FrameRate.fps24);
      expectValid(slack);
      final a = slack.index.item(const ItemId('a')) as MediaClip;
      final b = slack.index.item(const ItemId('b'))!;
      expect(FrameRate.fps24.frameIndexOf(a.end) - FrameRate.fps24.frameIndexOf(a.start), 5, reason: 'the whole media at 24 fps is 5 frames');
      expect(a.end == b.start, isFalse, reason: 'the clip ended a frame earlier: the cut came apart');
      expect(slack.tracks.first.transitions, isEmpty, reason: 'and its transition was dropped');

      // A clip that starts 33 ms into the media can absorb the overrun in sourceIn: the cut holds.
      final held = build(sourceIn: 33000);
      final trimmed = held.copyWith(
        timeline: held.timeline.copyWith(tracks: [
          held.tracks.first.copyWith(items: [
            (held.tracks.first.items.first as MediaClip).copyWith(start: f(1), duration: f(7) - f(1)),
            held.tracks.first.items.last,
          ]),
        ]),
      );
      expectValid(trimmed, 'fixture');
      final pulled = requantize(trimmed, FrameRate.fps24);
      expectValid(pulled);
      final pa = pulled.index.item(const ItemId('a')) as MediaClip;
      expect(pa.end, pulled.index.item(const ItemId('b'))!.start, reason: 'touching is kept');
      expect(pa.sourceIn, lessThan(33000), reason: 'sourceIn was pulled back');
      expect(pulled.tracks.first.transitions, hasLength(1));
    });

    test('the view playhead moves to the new grid; the pool and canvas stay', () {
      final p = p30([lane('v', TrackKind.video, [vclip('a', 0, 300)], main: true)]);
      final withView = p.copyWith(view: ViewState(playhead: f(37), pixelsPerSecond: 80));
      final q = requantize(withView, FrameRate.fps24);
      expect(FrameRate.fps24.isOnGrid(q.view.playhead), isTrue);
      expect(q.view.pixelsPerSecond, 80);
      expect((q.view.playhead - f(37)).abs(), lessThanOrEqualTo(FrameRate.fps24.frameUs));
    });

    test('media clips stay within their media', () {
      // md_short is 1 s; at 30 fps a full clip is 30 frames; every rate must keep it inside.
      for (final to in rates) {
        final p = p30([lane('v', TrackKind.video, [vclip('a', 0, 30, media: 'md_short')], main: true)]);
        final q = requantize(p, to);
        expectValid(q, '-> ${to.fps}');
      }
    });
  });

  group('SetFrameRate', () {
    test('is one history entry over the whole project; notices count dropped transitions', () {
      final p = standard();
      final out = applyCommand(p, const SetFrameRate(FrameRate.fps24), ctx());
      expect(out.rejection, isNull);
      expect(out.project.settings.frameRate, FrameRate.fps24);
      expectValid(out.project);
      expect(out.changedTracks, {for (final t in p.tracks) t.id});
      expect(out.affected, containsAll([for (final t in p.tracks) ...t.items.map((i) => i.id)]));
    });

    test('same rate is a no-op', () {
      final out = applyCommand(standard(), const SetFrameRate(FrameRate.fps30), ctx());
      expect(out.noop, isTrue);
    });

    test('an unsupported rate is refused', () {
      for (final bad in [const FrameRate(30000, 1001), const FrameRate(15, 1), const FrameRate(120, 1)]) {
        expect(applyCommand(standard(), SetFrameRate(bad), ctx()).rejection, const InvalidValue('frameRate'), reason: '$bad');
      }
    });

    test('the dry run agrees with the apply', () {
      final p = standard();
      final pre = dryRun(p, const SetFrameRate(FrameRate.fps25), ctx());
      final out = applyCommand(p, const SetFrameRate(FrameRate.fps25), ctx());
      expect(pre.rejection, isNull);
      for (final e in pre.placements.entries) {
        expect(out.project.index.locate(e.key)!.item.range, e.value.range);
      }
    });

    test('goes there and back through every rate keeping the project valid', () {
      var p = randomProject(5, const RandomProjectSpec(items: 80, frameRate: FrameRate.fps30));
      for (final to in [...rates, FrameRate.fps30]) {
        final out = applyCommand(p, SetFrameRate(to), ctx());
        expect(out.rejection, isNull, reason: '$to');
        p = out.project;
        expectValid(p, '-> $to');
      }
    });
  });
}
