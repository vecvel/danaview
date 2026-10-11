// OWNER: AI-12
//
// Planner tests: exclusions, merging, padding and scope (ARCH §16.4 step 1, ai.md §8.2).

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'timeline_fixtures.dart';

void main() {
  final v1 = asset('md_v1');
  final v2 = asset('md_v2');
  final mute = asset('md_mute', hasAudio: false);
  final img = asset('md_img', kind: MediaKind.image);
  final song = asset('md_song', kind: MediaKind.audio);
  final all = [v1, v2, mute, img, song];

  Map<String, String> skippedOf(TranscriptionPlan p) => {for (final s in p.skipped) s.item.value: s.reason};

  group('basics', () {
    test('one clip becomes one unit padded by 0.5 s and clamped to the media', () {
      final p = plan(project([mainTrack([clip('c1', 0, 10000, 'md_v1', sourceInMs: 20000)])], all));
      expect(p.units, hasLength(1));
      final u = p.units.single;
      expect(u.media, const MediaId('md_v1'));
      expect(u.mediaQuickHash, 'qh_md_v1');
      expect(u.audioStream, isNull);
      expect(u.audioStreamIndex, 0);
      expect(u.coreRange, TimeRange(sec(20), sec(30)));
      expect(u.sourceRange, TimeRange(ms(19500), ms(30500)));
      expect(u.duration, ms(11000));
      expect(u.clipIds, {const ItemId('c1')});
      expect(p.skipped, isEmpty);
      expect(p.totalDuration, ms(11000));
    });

    test('padding never goes below 0 or above the media duration', () {
      final short = asset('md_short', duration: sec(10));
      final p = plan(project([mainTrack([clip('c1', 0, 10000, 'md_short')])], [short]));
      expect(p.units.single.sourceRange, TimeRange(0, sec(10)));
      expect(p.units.single.coreRange, TimeRange(0, sec(10)));
    });

    test('an empty timeline yields an empty plan', () {
      final p = plan(project([mainTrack(const [])], all));
      expect(p.isEmpty, isTrue);
      expect(p.units, isEmpty);
      expect(p.detectionUnit, isNull);
      expect(p.totalDuration, 0);
    });

    test('a clip whose media is not in the pool is still planned', () {
      final p = plan(project([mainTrack([clip('c1', 0, 4000, 'md_gone')])], const []));
      expect(p.units.single.sourceRange, TimeRange(0, ms(4500)));
      expect(p.units.single.mediaQuickHash, '');
    });

    test('speed changes the source range: 2x doubles the source a clip shows', () {
      final p = plan(project([mainTrack([clip('c1', 0, 5000, 'md_v1', sourceInMs: 1000, speed: const ConstantSpeed(2))])], all));
      expect(p.units.single.coreRange, TimeRange(ms(1000), ms(11000)));
    });

    test('units are in timeline order of their first clip', () {
      final p = plan(project([
        mainTrack([clip('a', 0, 3000, 'md_v2'), clip('b', 3000, 6000, 'md_v1')]),
      ], all));
      expect([for (final u in p.units) u.media.value], ['md_v2', 'md_v1']);
    });
  });

  group('exclusions', () {
    test('muted clip, zero volume, muted track: skipped as muted', () {
      final p = plan(project([
        mainTrack([clip('ok', 0, 2000, 'md_v1'), clip('m', 2000, 4000, 'md_v1', muted: true), clip('z', 4000, 6000, 'md_v1', volume: 0)]),
        lane('tr_a', TrackKind.audio, [clip('on_muted_track', 0, 2000, 'md_v2')], muted: true),
      ], all));
      expect(clipIds(p.units.single), ['ok']);
      expect(skippedOf(p), {'m': 'muted', 'z': 'muted', 'on_muted_track': 'muted'});
    });

    test('soloed-out tracks are skipped as muted; the soloed track is planned', () {
      final p = plan(project([
        mainTrack([clip('video', 0, 2000, 'md_v1')]),
        lane('tr_a', TrackKind.audio, [clip('voice', 0, 2000, 'md_v2')], role: AudioRole.voice, solo: true),
      ], all));
      expect([for (final u in p.units) u.media.value], ['md_v2']);
      expect(skippedOf(p), {'video': 'muted'});
    });

    test('reversed clips are reported, not planned', () {
      final p = plan(project([mainTrack([clip('r', 0, 2000, 'md_v1', reversed: true), clip('f', 2000, 4000, 'md_v2')])], all));
      expect(clipIds(p.units.single), ['f']);
      expect(skippedOf(p), {'r': 'reversed'});
    });

    test('media without an audio stream is reported', () {
      final p = plan(project([mainTrack([clip('s', 0, 2000, 'md_mute'), clip('f', 2000, 4000, 'md_v2')])], all));
      expect(clipIds(p.units.single), ['f']);
      expect(skippedOf(p), {'s': 'noAudio'});
    });

    test('images and stills are silent: not planned and not reported', () {
      final still = asset('md_still', derived: const StillSpec(MediaId('md_v1'), 1000000, sourceQuickHash: 'qh_md_v1'), hasAudio: false);
      final p = plan(project([
        mainTrack([clip('i', 0, 2000, 'md_img'), clip('s', 2000, 4000, 'md_still'), clip('f', 4000, 6000, 'md_v1')]),
      ], [...all, still]));
      expect(clipIds(p.units.single), ['f']);
      expect(p.skipped, isEmpty);
    });

    test('music tracks are unchecked by default and planned when their track is chosen', () {
      final project0 = project([
        mainTrack([clip('v', 0, 2000, 'md_v1')]),
        lane('tr_music', TrackKind.audio, [clip('m', 0, 8000, 'md_song')], role: AudioRole.music),
      ], all);
      final byDefault = plan(project0);
      expect([for (final u in byDefault.units) u.media.value], ['md_v1']);
      final chosen = plan(project0, TimelineScope(tracks: {const TrackId('tr_music')}));
      expect([for (final u in chosen.units) u.media.value], ['md_song']);
      expect(chosen.units.single.priority, StreamPriority.music);
    });

    test('text and subtitle tracks and detached-audio clips are never planned', () {
      final p = plan(project([
        mainTrack([clip('video', 0, 2000, 'md_v1', detached: true)]),
        lane('tr_t', TrackKind.text, [TextItem(id: const ItemId('t'), start: 0, duration: ms(1000), text: 'Hi')]),
        lane('tr_s', TrackKind.subtitle, [SubtitleCue(id: const ItemId('q'), start: 0, duration: ms(1000), text: 'Hi')]),
        lane('tr_a', TrackKind.audio, [clip('extracted', 0, 2000, 'md_v1')]),
      ], all));
      expect(clipIds(p.units.single), ['extracted']);
      expect(p.skipped, isEmpty);
    });
  });

  group('merging', () {
    test('clips of one media within 5 s merge into one unit (a split clip is one transcription)', () {
      final p = plan(project([
        mainTrack([clip('a', 0, 4000, 'md_v1'), clip('b', 4000, 8000, 'md_v1', sourceInMs: 8000)]),
      ], all));
      expect(p.units, hasLength(1));
      final u = p.units.single;
      expect(clipIds(u), ['a', 'b']);
      expect(u.coreRange, TimeRange(0, ms(12000)));
      expect(u.sourceRange, TimeRange(0, ms(12500)));
    });

    test('the merge gap is 5 s inclusive, 5.001 s separates', () {
      MediaClip second(int gapMs) => clip('b', 4000, 8000, 'md_v1', sourceInMs: 4000 + gapMs);
      final merged = plan(project([mainTrack([clip('a', 0, 4000, 'md_v1'), second(5000)])], all));
      expect(merged.units, hasLength(1));
      final apart = plan(project([mainTrack([clip('a', 0, 4000, 'md_v1'), second(5001)])], all));
      expect(apart.units, hasLength(2));
      expect(apart.units[0].sourceRange, TimeRange(0, ms(4500)));
      expect(apart.units[1].sourceRange, TimeRange(ms(8501), ms(13501)));
    });

    test('overlapping source ranges (a repeated section) merge', () {
      final p = plan(project([
        mainTrack([clip('a', 0, 6000, 'md_v1', sourceInMs: 10000), clip('b', 6000, 12000, 'md_v1', sourceInMs: 12000)]),
      ], all));
      expect(p.units.single.coreRange, TimeRange(ms(10000), ms(18000)));
    });

    test('different media or audio streams never merge', () {
      final p = plan(project([
        mainTrack([
          clip('a', 0, 2000, 'md_v1'),
          clip('b', 2000, 4000, 'md_v2'),
          clip('c', 4000, 6000, 'md_v1', audioStream: 1),
          clip('d', 6000, 8000, 'md_v1', audioStream: 0),
        ]),
      ], all));
      // a (stream null = 0) and d (stream 0) merge: same stream.
      expect(p.units, hasLength(3));
      expect(clipIds(p.units[0]), ['a', 'd']);
      expect(clipIds(p.units[1]), ['b']);
      expect(clipIds(p.units[2]), ['c']);
      expect(p.units[2].audioStreamIndex, 1);
    });

    test('clips on different tracks that show one media merge, and the best priority wins', () {
      final p = plan(project([
        mainTrack([clip('a', 0, 4000, 'md_v1')]),
        lane('tr_a', TrackKind.audio, [clip('b', 0, 4000, 'md_v1', sourceInMs: 2000)], role: AudioRole.voice),
      ], all));
      expect(p.units, hasLength(1));
      expect(p.units.single.priority, StreamPriority.voice);
      expect(p.units.single.clips.map((c) => c.priority).toSet(), {StreamPriority.mainVideo, StreamPriority.voice});
    });

    test('the detection unit is the highest priority, then the longest, then the earliest', () {
      final p = plan(project([
        mainTrack([clip('a', 0, 3000, 'md_v1'), clip('b', 3000, 10000, 'md_v2')]),
        lane('tr_a', TrackKind.audio, [clip('c', 0, 2000, 'md_song')], role: AudioRole.effects),
      ], all));
      expect(p.detectionUnit!.media.value, 'md_v2');
      final voice = plan(project([
        mainTrack([clip('a', 0, 10000, 'md_v1')]),
        lane('tr_a', TrackKind.audio, [clip('c', 0, 2000, 'md_v2')], role: AudioRole.voice),
      ], all));
      expect(voice.detectionUnit!.media.value, 'md_v2');
    });
  });

  group('priority of tracks', () {
    final planner = TranscriptionPlanner.priorityOf;
    TrackView view(Track t) => DomainTimelineView(project([t], const [])).tracks.single;

    test('voice > main video > other video > other audio > music', () {
      final voice = planner(view(lane('a', TrackKind.audio, const [], role: AudioRole.voice)));
      final main = planner(view(mainTrack(const [])));
      final other = planner(view(lane('o', TrackKind.overlay, const [])));
      final audio = planner(view(lane('a', TrackKind.audio, const [], role: AudioRole.effects)));
      final music = planner(view(lane('a', TrackKind.audio, const [], role: AudioRole.music)));
      expect(voice, StreamPriority.voice);
      expect(main, StreamPriority.mainVideo);
      expect(other, StreamPriority.otherVideo);
      expect(audio, StreamPriority.otherAudio);
      expect(music, StreamPriority.music);
      expect(voice, greaterThan(main));
      expect(main, greaterThan(other));
      expect(other, greaterThan(audio));
      expect(audio, greaterThan(music));
    });
  });

  group('scope', () {
    final base = project([
      mainTrack([clip('a', 0, 10000, 'md_v1', sourceInMs: 5000), clip('b', 10000, 20000, 'md_v2')]),
      lane('tr_a', TrackKind.audio, [clip('m', 0, 20000, 'md_song')], role: AudioRole.music),
    ], all);

    test('whole timeline: everything audible except music', () {
      expect([for (final u in plan(base).units) u.media.value], ['md_v1', 'md_v2']);
    });

    test('ClipScope plans one clip', () {
      final p = plan(base, const ClipScope(ItemId('b')));
      expect(clipIds(p.units.single), ['b']);
    });

    test('ItemsScope plans the selected clips, including a selected music clip', () {
      final p = plan(base, ItemsScope({const ItemId('a'), const ItemId('m')}));
      expect({for (final u in p.units) u.media.value}, {'md_v1', 'md_song'});
    });

    test('a selected clip that is excluded is reported, not planned', () {
      final p = plan(
        project([mainTrack([clip('r', 0, 2000, 'md_v1', reversed: true)])], all),
        const ClipScope(ItemId('r')),
      );
      expect(p.units, isEmpty);
      expect(skippedOf(p), {'r': 'reversed'});
    });

    test('unselected clips are not reported even when excluded', () {
      final p = plan(
        project([mainTrack([clip('r', 0, 2000, 'md_v1', reversed: true), clip('ok', 2000, 4000, 'md_v2')])], all),
        const ClipScope(ItemId('ok')),
      );
      expect(p.skipped, isEmpty);
    });

    test('TimelineScope with tracks limits to those tracks', () {
      final p = plan(
        project([
          mainTrack([clip('a', 0, 4000, 'md_v1')]),
          lane('tr_a', TrackKind.audio, [clip('v', 0, 4000, 'md_v2')], role: AudioRole.voice),
        ], all),
        TimelineScope(tracks: {const TrackId('tr_a')}),
      );
      expect([for (final u in p.units) u.media.value], ['md_v2']);
    });

    test('TimelineScope range cuts clips to the range and drops clips outside it', () {
      final p = plan(base, TimelineScope(range: TimeRange(ms(2000), ms(12000))));
      expect(p.units, hasLength(2));
      // Clip a shows source 5 s..15 s at timeline 0..10 s; timeline 2..10 s is source 7..15 s.
      final a = p.units.firstWhere((u) => u.media.value == 'md_v1');
      expect(a.coreRange, TimeRange(ms(7000), ms(15000)));
      expect(a.clips.single.timelineRange, TimeRange(0, ms(10000)));
      expect(a.clips.single.sourceRange, TimeRange(ms(7000), ms(15000)));
      // Clip b shows source 0..10 s at timeline 10..20 s; timeline 10..12 s is source 0..2 s.
      final b = p.units.firstWhere((u) => u.media.value == 'md_v2');
      expect(b.coreRange, TimeRange(0, ms(2000)));
      final none = plan(base, TimelineScope(range: TimeRange(ms(25000), ms(30000))));
      expect(none.units, isEmpty);
    });

    test('TimelineScope range through a 2x clip cuts the source by the speed', () {
      final p = plan(
        project([mainTrack([clip('a', 0, 10000, 'md_v1', sourceInMs: 1000, speed: const ConstantSpeed(2))])], all),
        TimelineScope(range: TimeRange(ms(2000), ms(4000))),
      );
      final core = p.units.single.coreRange;
      expect(core.start, closeTo(ms(1000 + 4000), 2));
      expect(core.end, closeTo(ms(1000 + 8000), 2));
    });

    test('a range covering a clip fully keeps the whole clip', () {
      final p = plan(base, TimelineScope(range: TimeRange(0, ms(10000))));
      expect(p.units.single.coreRange, TimeRange(ms(5000), ms(15000)));
    });
  });

  group('determinism', () {
    test('the same project plans identically', () {
      final p = project([
        mainTrack([clip('a', 0, 4000, 'md_v1'), clip('b', 4000, 8000, 'md_v1', sourceInMs: 4000), clip('c', 8000, 9000, 'md_v2')]),
      ], all);
      expect(plan(p).units, plan(p).units);
    });
  });
}
