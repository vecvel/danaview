// OWNER: AI-12
//
// Word mapping tests (ARCH §16.4 step 7, ai.md §10.1): constant speed, ramps, splits and trims,
// edits during a job, and the overlap priority merge.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import '../transcript/transcript_fixtures.dart' as tf;
import 'timeline_fixtures.dart';

const _mapper = WordMapper();

/// Plans [p] (whole timeline) and maps [words] by media through a fresh view of [fresh] (default
/// [p]).
MappedWords mapWords(
  EditProject p,
  Map<String, List<TranscriptWord>> words, {
  EditProject? fresh,
  TimeRange? window,
  TranscriptionScope scope = const TimelineScope(),
}) {
  final planned = plan(p, scope);
  final inputs = [
    for (final u in planned.units) UnitWords(u, words[u.media.value] ?? const []),
  ];
  return _mapper.map(timeline: DomainTimelineView(fresh ?? p), transcripts: inputs, window: window);
}

List<(String, int, int)> shape(MappedWords m) => [for (final w in m.words) (w.text, w.start ~/ 1000, w.end ~/ 1000)];

void main() {
  final v1 = asset('md_v1');
  final v2 = asset('md_v2');
  final v3 = asset('md_v3');
  final song = asset('md_song', kind: MediaKind.audio);
  final all = [v1, v2, v3, song];

  group('constant speed', () {
    test('1x: words move by the clip offset', () {
      final p = project([mainTrack([clip('c', 3000, 13000, 'md_v1', sourceInMs: 2000)])], all);
      final m = mapWords(p, {'md_v1': [sw('hello', 2500, 3000), sw('world', 4000, 4500)]});
      expect(shape(m), [('hello', 3500, 4000), ('world', 5000, 5500)]);
      expect(m.words.every((w) => w.clip == const ItemId('c')), isTrue);
      expect(m.words.first.p, 0.9);
    });

    test('2x: source seconds play in half the time', () {
      final p = project([mainTrack([clip('c', 0, 5000, 'md_v1', sourceInMs: 10000, speed: const ConstantSpeed(2))])], all);
      final m = mapWords(p, {'md_v1': [sw('fast', 12000, 13000)]});
      expect(shape(m), [('fast', 1000, 1500)]);
    });

    test('0.5x: source seconds take twice the time', () {
      final p = project([mainTrack([clip('c', 0, 4000, 'md_v1', speed: const ConstantSpeed(0.5))])], all);
      final m = mapWords(p, {'md_v1': [sw('slow', 500, 1000)]});
      expect(shape(m), [('slow', 1000, 2000)]);
    });
  });

  group('speed ramps', () {
    final ramp = SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(0.5, 4), const SpeedPoint(1, 0.5)]);

    test('words follow ClipTimeMap.timelineTimeOf exactly and invert toSource', () {
      final c = clip('c', 2000, 12000, 'md_v1', sourceInMs: 3000, speed: ramp);
      final p = project([mainTrack([c])], all);
      final map = ClipTimeMap.forClip(c, FrameRate.fps30);
      final src = map.sourceRange;
      final words = [
        for (var i = 0; i < 20; i++)
          sw('w$i', (src.start ~/ 1000) + i * ((src.end - src.start) ~/ 1000 ~/ 20), (src.start ~/ 1000) + i * ((src.end - src.start) ~/ 1000 ~/ 20) + 40),
      ];
      final m = mapWords(p, {'md_v1': words});
      expect(m.words, hasLength(20));
      for (var i = 0; i < 20; i++) {
        final s0 = words[i].startUs;
        final s1 = words[i].endUs;
        final out = m.words[i];
        expect(out.start, map.timelineTimeOf(s0));
        expect(out.end, map.timelineTimeOf(s1));
        expect(map.toSource(out.start), closeTo(s0, 2000));
      }
      // Strictly monotonic and inside the clip.
      for (var i = 1; i < m.words.length; i++) {
        expect(m.words[i].start, greaterThan(m.words[i - 1].start));
      }
      expect(m.words.first.start, greaterThanOrEqualTo(ms(2000)));
      expect(m.words.last.end, lessThanOrEqualTo(ms(12000)));
    });

    test('the fast section compresses words and the slow section stretches them', () {
      final c = clip('c', 0, 10000, 'md_v1', speed: ramp);
      final p = project([mainTrack([c])], all);
      final map = ClipTimeMap.forClip(c, FrameRate.fps30);
      final len = map.sourceRange.duration;
      final fastAt = len ~/ 2;
      final slowAt = len - 600000; // near the end of the ramp, where it is slowest
      final m = mapWords(p, {
        'md_v1': [
          TranscriptWord(text: 'fast', startUs: fastAt, endUs: fastAt + 400000),
          TranscriptWord(text: 'slow', startUs: slowAt, endUs: slowAt + 400000),
        ],
      });
      final fast = m.words[0].end - m.words[0].start;
      final slow = m.words[1].end - m.words[1].start;
      expect(fast, lessThan(400000));
      expect(slow, greaterThan(400000));
    });
  });

  group('trims', () {
    test('words outside the visible source range are dropped; partly visible words are clamped', () {
      final p = project([mainTrack([clip('c', 0, 4000, 'md_v1', sourceInMs: 5000)])], all);
      final m = mapWords(p, {
        'md_v1': [
          sw('before', 4000, 4500), // outside
          sw('lead', 4800, 5400), // 2/3 visible: kept, clamped to the clip start
          sw('gone', 4600, 5300), // 3/7 visible: dropped
          sw('mid', 6000, 6500),
          sw('tail', 8600, 9200), // 2/3 visible: kept, clamped to the clip end
          sw('after', 9000, 9500), // outside
        ],
      });
      expect(shape(m), [('lead', 0, 400), ('mid', 1000, 1500), ('tail', 3600, 4000)]);
      expect(m.droppedInvisible, 1);
    });

    test('exactly 50% visible is kept, just under is dropped', () {
      final p = project([mainTrack([clip('c', 0, 4000, 'md_v1', sourceInMs: 5000)])], all);
      final half = mapWords(p, {'md_v1': [sw('half', 4800, 5200)]});
      expect(half.words, hasLength(1));
      final under = mapWords(p, {'md_v1': [sw('under', 4799, 5200)]});
      expect(under.words, isEmpty);
    });

    test('a gap cut out of the middle drops the words inside it', () {
      // Source 0..4 s and 8..12 s are kept; 4..8 s is cut out.
      final p = project([
        mainTrack([clip('a', 0, 4000, 'md_v1'), clip('b', 4000, 8000, 'md_v1', sourceInMs: 8000)]),
      ], all);
      final m = mapWords(p, {
        'md_v1': [sw('one', 1000, 1500), sw('cutout', 5000, 5500), sw('two', 9000, 9500)],
      });
      expect(shape(m), [('one', 1000, 1500), ('two', 5000, 5500)]);
    });

    test('a zero-length word inside the clip is kept', () {
      final p = project([mainTrack([clip('c', 0, 4000, 'md_v1', sourceInMs: 5000)])], all);
      expect(shape(mapWords(p, {'md_v1': [sw('tick', 6000, 6000)]})), [('tick', 1000, 1000)]);
      expect(mapWords(p, {'md_v1': [sw('tick', 1000, 1000)]}).words, isEmpty);
    });
  });

  group('splits', () {
    final contiguous = project([
      mainTrack([clip('a', 0, 10000, 'md_v1'), clip('b', 10000, 20000, 'md_v1', sourceInMs: 10000)]),
    ], all);

    test('a split clip maps each half through its own clip and keeps the words in order', () {
      final m = mapWords(contiguous, {
        'md_v1': [sw('one', 1000, 1500), sw('two', 9000, 9500), sw('three', 11000, 11500)],
      });
      expect(shape(m), [('one', 1000, 1500), ('two', 9000, 9500), ('three', 11000, 11500)]);
      expect(m.words.map((w) => w.clip.value), ['a', 'a', 'b']);
    });

    test('a word cut by the split belongs to the clip that shows most of it (never twice)', () {
      final m = mapWords(contiguous, {'md_v1': [sw('across', 9800, 10400)]});
      expect(m.words, hasLength(1));
      expect(m.words.single.clip.value, 'b');
      expect(m.words.single.start, ms(10000));
      expect(m.words.single.end, ms(10400));
      expect(m.droppedInvisible, 1);
    });

    test('rearranged halves: the second half moved before the first', () {
      final p = project([
        mainTrack([clip('b', 0, 10000, 'md_v1', sourceInMs: 10000), clip('a', 10000, 20000, 'md_v1')]),
      ], all);
      final m = mapWords(p, {
        'md_v1': [sw('first-spoken', 1000, 1500), sw('second-spoken', 12000, 12500)],
      });
      expect(shape(m), [('second-spoken', 2000, 2500), ('first-spoken', 11000, 11500)]);
    });

    test('halves with different speeds each use their own map', () {
      final p = project([
        mainTrack([
          clip('a', 0, 5000, 'md_v1', speed: const ConstantSpeed(2)), // source 0..10 s
          clip('b', 5000, 15000, 'md_v1', sourceInMs: 10000), // source 10..20 s at 1x
        ]),
      ], all);
      final m = mapWords(p, {'md_v1': [sw('x', 4000, 6000), sw('y', 12000, 13000)]});
      expect(shape(m), [('x', 2000, 3000), ('y', 7000, 8000)]);
    });

    test('a sentence across the cut becomes one continuous cue, a long passage breaks at the cut', () {
      // 22 words, 600 ms apart, continuous in the source; the clip is split at 6 s, away from the
      // balanced break the segmenter would pick on its own (7.2 s).
      final words = [for (var i = 0; i < 22; i++) sw('word${i % 10}', i * 600, i * 600 + 560)];
      final p = project([
        mainTrack([clip('a', 0, 6000, 'md_v1'), clip('b', 6000, 14000, 'md_v1', sourceInMs: 6000)]),
      ], all);
      final m = mapWords(p, {'md_v1': words});
      expect(m.cutPoints, [ms(6000), ms(14000)]);
      expect(m.words, hasLength(22));
      expect(m.words.map((w) => w.clip.value).toSet(), {'a', 'b'});

      const segmenter = DpCaptionSegmenter();
      final ctx = SegmentationContext.forProject(
        languageCode: 'en',
        settings: const SegmentationSettings(),
        frameRate: FrameRate.fps30,
        cutPoints: m.cutPoints,
      );
      final noCuts = SegmentationContext.forProject(
        languageCode: 'en',
        settings: const SegmentationSettings(),
        frameRate: FrameRate.fps30,
      );
      final withPenalty = segmenter.segment(m.words, ctx);
      // The clip ids are a cut signal too, so the reference run strips them as well.
      final withoutPenalty = segmenter.segment([for (final w in m.words) w.copyWith(clip: const ItemId('a'))], noCuts);
      bool straddles(SubtitleCueDraft c) => c.range.start < ms(6000) && c.range.end > ms(6000) + 200000;
      expect(withoutPenalty.any(straddles), isTrue, reason: 'the fixture must straddle without a cut list');
      expect(withPenalty.any(straddles), isFalse);
      expect([for (final c in withPenalty) c.text.replaceAll('\n', ' ')].join(' ').split(' '), hasLength(22));

      // A short sentence across the cut stays one continuous cue (penalty, not a wall).
      final sentence = project([
        mainTrack([clip('a', 0, 1200, 'md_v1'), clip('b', 1200, 4000, 'md_v1', sourceInMs: 1200)]),
      ], all);
      final short = mapWords(sentence, {
        'md_v1': [
          sw('This', 0, 250),
          sw('sentence', 300, 800),
          sw('keeps', 850, 1150),
          sw('going', 1250, 1600),
          sw('after', 1650, 2000),
          sw('the', 2050, 2200),
          sw('cut.', 2250, 2600),
        ],
      });
      final cues = segmenter.segment(
        short.words,
        SegmentationContext.forProject(languageCode: 'en', settings: const SegmentationSettings(), frameRate: FrameRate.fps30, cutPoints: short.cutPoints),
      );
      expect(cues, hasLength(1));
      expect(cues.single.text.replaceAll('\n', ' '), 'This sentence keeps going after the cut.');
    });
  });

  group('edits during a job are honoured', () {
    final planned = project([mainTrack([clip('c', 0, 10000, 'md_v1')])], all);
    final words = {'md_v1': [sw('early', 1000, 1500), sw('late', 8000, 8500)]};

    test('trimmed shorter: words past the new end are dropped', () {
      final edited = project([mainTrack([clip('c', 0, 5000, 'md_v1')])], all);
      expect(shape(mapWords(planned, words, fresh: edited)), [('early', 1000, 1500)]);
    });

    test('moved later: words follow the clip', () {
      final edited = project([mainTrack([clip('c', 3000, 13000, 'md_v1')])], all);
      expect(shape(mapWords(planned, words, fresh: edited)), [('early', 4000, 4500), ('late', 11000, 11500)]);
    });

    test('sped up after planning: the new speed is used', () {
      final edited = project([mainTrack([clip('c', 0, 5000, 'md_v1', speed: const ConstantSpeed(2))])], all);
      expect(shape(mapWords(planned, words, fresh: edited)), [('early', 500, 750), ('late', 4000, 4250)]);
    });

    test('deleted, muted, reversed or re-sourced clips are reported missing and produce no words', () {
      for (final edited in [
        project([mainTrack(const [])], all),
        project([mainTrack([clip('c', 0, 10000, 'md_v1', muted: true)])], all),
        project([mainTrack([clip('c', 0, 10000, 'md_v1', reversed: true)])], all),
        project([mainTrack([clip('c', 0, 10000, 'md_v2')])], all),
        project([mainTrack([clip('c', 0, 10000, 'md_v1', audioStream: 1)])], all),
      ]) {
        final m = mapWords(planned, words, fresh: edited);
        expect(m.words, isEmpty);
        expect(m.missingClips, [const ItemId('c')]);
      }
    });

    test('a clip added after planning is ignored', () {
      final edited = project([mainTrack([clip('c', 0, 10000, 'md_v1'), clip('new', 10000, 12000, 'md_v1', sourceInMs: 1000)])], all);
      final m = mapWords(planned, words, fresh: edited);
      expect(m.words.every((w) => w.clip == const ItemId('c')), isTrue);
    });
  });

  group('window', () {
    final p = project([mainTrack([clip('c', 0, 20000, 'md_v1')])], all);

    test('words are limited to the window by the same 50% rule and clamped', () {
      final m = mapWords(
        p,
        {'md_v1': [sw('before', 1000, 1500), sw('edge', 4800, 5400), sw('in', 6000, 6500), sw('over', 9600, 10200), sw('after', 12000, 12500)]},
        window: TimeRange(ms(5000), ms(10000)),
      );
      expect(shape(m), [('edge', 5000, 5400), ('in', 6000, 6500), ('over', 9600, 10000)]);
    });

    test('cut points are limited to the window', () {
      final split = project([
        mainTrack([clip('a', 0, 5000, 'md_v1'), clip('b', 5000, 12000, 'md_v1', sourceInMs: 5000), clip('c', 12000, 20000, 'md_v1', sourceInMs: 12000)]),
      ], all);
      final m = mapWords(split, {'md_v1': [sw('x', 6000, 6500)]}, window: TimeRange(ms(4000), ms(13000)));
      expect(m.cutPoints, [ms(5000), ms(12000)]);
      final narrow = mapWords(split, {'md_v1': [sw('x', 6000, 6500)]}, window: TimeRange(ms(5500), ms(9000)));
      expect(narrow.cutPoints, isEmpty);
    });

    test('a scope range maps only the words inside it', () {
      final range = TimeRange(ms(5000), ms(10000));
      final m = mapWords(
        p,
        {'md_v1': [sw('before', 1000, 1500), sw('in', 6000, 6500), sw('after', 12000, 12500)]},
        scope: TimelineScope(range: range),
        window: range,
      );
      expect(shape(m), [('in', 6000, 6500)]);
    });
  });

  group('UnitWords', () {
    test('fromTranscript takes the words of all segments', () {
      final p = project([mainTrack([clip('c', 0, 20000, 'md_v1')])], all);
      final unit = plan(p).units.single;
      final t = tf.transcript('k', segments: [tf.seg(1000, 3000, 'hello brave new world'), tf.seg(10000, 12000, 'second sentence here')]);
      final uw = UnitWords.fromTranscript(unit, t);
      expect(uw.words, hasLength(7));
      final m = _mapper.map(timeline: DomainTimelineView(p), transcripts: [uw]);
      expect(m.words.map((w) => w.text), ['hello', 'brave', 'new', 'world', 'second', 'sentence', 'here']);
    });
  });

  group('priority: voice > main video > other video > other audio > music', () {
    // Two clips overlap on [0, 10 s]; each has a word at 2000..2500 on the timeline.
    EditProject overlapping(List<(String, Track)> lanes) => project([for (final l in lanes) l.$2], all);

    Track video(String id, String media, {bool main = false}) => main
        ? mainTrack([clip(id, 0, 10000, media)], id: 'tr_$id')
        : lane('tr_$id', TrackKind.overlay, [clip(id, 0, 10000, media)]);
    Track audio(String id, String media, AudioRole role) => lane('tr_$id', TrackKind.audio, [clip(id, 0, 10000, media)], role: role);

    Map<String, List<TranscriptWord>> sameWord() => {
          'md_v1': [sw('one', 2000, 2500)],
          'md_v2': [sw('two', 2100, 2600)],
          'md_v3': [sw('three', 2050, 2550)],
          'md_song': [sw('four', 2000, 2500)],
        };

    List<String> survivors(EditProject p, {Set<String>? only}) {
      final w = sameWord();
      if (only != null) w.removeWhere((k, _) => !only.contains(k));
      return [for (final x in mapWords(p, w, scope: TimelineScope(tracks: {for (final t in p.tracks) t.id})).words) x.text];
    }

    test('voice beats main video', () {
      final p = overlapping([('v', video('v', 'md_v1', main: true)), ('a', audio('a', 'md_v2', AudioRole.voice))]);
      expect(survivors(p), ['two']);
    });

    test('main video beats other video', () {
      final p = overlapping([('v', video('v', 'md_v1', main: true)), ('o', video('o', 'md_v2'))]);
      expect(survivors(p), ['one']);
    });

    test('other video beats other audio', () {
      final p = overlapping([('v', video('v', 'md_v1', main: true)), ('o', video('o', 'md_v2')), ('a', audio('a', 'md_v3', AudioRole.effects))]);
      expect(survivors(p), ['one']);
      final p2 = overlapping([('o', video('o', 'md_v2')), ('a', audio('a', 'md_v3', AudioRole.effects))]);
      expect(survivors(p2), ['two']);
    });

    test('other audio beats music', () {
      final p = overlapping([('a', audio('a', 'md_v1', AudioRole.original)), ('m', audio('m', 'md_song', AudioRole.music))]);
      expect(survivors(p), ['one']);
    });

    test('the full chain: only the voice survives', () {
      final p = overlapping([
        ('v', video('v', 'md_v1', main: true)),
        ('o', video('o', 'md_v2')),
        ('a', audio('a', 'md_v3', AudioRole.voice)),
        ('m', audio('m', 'md_song', AudioRole.music)),
      ]);
      expect(survivors(p), ['three']);
    });

    test('words further than 0.3 s from the winner are kept', () {
      final p = overlapping([('v', video('v', 'md_v1', main: true)), ('a', audio('a', 'md_v2', AudioRole.voice))]);
      final m = mapWords(p, {
        'md_v1': [sw('shadowed', 2000, 2500), sw('free', 6000, 6500)],
        'md_v2': [sw('voice', 2100, 2600)],
      });
      expect([for (final w in m.words) w.text], ['voice', 'free']);
      expect(m.droppedOverlap, 1);
    });

    test('clips that only touch do not shadow each other', () {
      final p = project([
        mainTrack([clip('v', 0, 5000, 'md_v1')]),
        lane('tr_a', TrackKind.audio, [clip('a', 5000, 10000, 'md_v2')], role: AudioRole.voice),
      ], all);
      final m = mapWords(p, {
        'md_v1': [sw('left', 4700, 5000)],
        'md_v2': [sw('right', 0, 400)],
      });
      expect([for (final w in m.words) w.text], ['left', 'right']);
      expect(m.droppedOverlap, 0);
    });

    test('words outside the overlap are never shadowed', () {
      // Voice covers 6..10 s; the video word at 5.8..6.0 s is within 0.3 s of a voice word but
      // outside the overlap.
      final p = project([
        mainTrack([clip('v', 0, 10000, 'md_v1')]),
        lane('tr_a', TrackKind.audio, [clip('a', 6000, 10000, 'md_v2')], role: AudioRole.voice),
      ], all);
      final m = mapWords(p, {
        'md_v1': [sw('before', 5800, 6000), sw('inside', 6100, 6400)],
        'md_v2': [sw('voice', 0, 300)],
      });
      expect([for (final w in m.words) w.text], ['before', 'voice']);
    });
  });

  group('mergeStreams', () {
    ClipStream stream(String id, int priority, int rank, List<(int, int)> words, {TimeRange? range}) => ClipStream(
          clip: ItemId(id),
          timelineRange: range ?? TimeRange(0, ms(100000)),
          priority: priority,
          trackRank: rank,
          words: [for (final (s, e) in words) TimedWord(text: '$id$s', start: ms(s), end: ms(e), clip: ItemId(id))],
        );

    test('the 0.3 s window is exclusive at the edge', () {
      final voice = stream('voice', StreamPriority.voice, 0, [(2800, 3000)]);
      final edge = stream('edge', StreamPriority.mainVideo, 0, [(2000, 2500)]);
      expect(WordMapper.mergeStreams([voice, edge]).map((w) => w.text), ['edge2000', 'voice2800']);
      final near = stream('near', StreamPriority.mainVideo, 0, [(2000, 2501)]);
      expect(WordMapper.mergeStreams([voice, near]).map((w) => w.text), ['voice2800']);
      final before = stream('before', StreamPriority.mainVideo, 0, [(3300, 3600)]);
      expect(WordMapper.mergeStreams([voice, before]).map((w) => w.text), ['voice2800', 'before3300']);
      final close = stream('close', StreamPriority.mainVideo, 0, [(3299, 3600)]);
      expect(WordMapper.mergeStreams([voice, close]).map((w) => w.text), ['voice2800']);
    });

    test('ties in priority go to the higher track rank, then the smaller id', () {
      final low = stream('low', StreamPriority.otherVideo, 1, [(1000, 1500)]);
      final high = stream('high', StreamPriority.otherVideo, 2, [(1100, 1600)]);
      expect(WordMapper.mergeStreams([low, high]).map((w) => w.text), ['high1100']);
      final a = stream('a', StreamPriority.otherAudio, 0, [(1000, 1500)]);
      final b = stream('b', StreamPriority.otherAudio, 0, [(1100, 1600)]);
      expect(WordMapper.mergeStreams([b, a]).map((w) => w.text), ['a1000']);
    });

    test('the result is independent of the input order', () {
      final streams = [
        stream('voice', StreamPriority.voice, 0, [(1000, 1400), (5000, 5400)]),
        stream('main', StreamPriority.mainVideo, 0, [(1100, 1500), (3000, 3400), (5100, 5500)]),
        stream('music', StreamPriority.music, 0, [(1000, 1500), (3100, 3500), (8000, 8400)]),
      ];
      final expected = WordMapper.mergeStreams(streams);
      expect(expected.map((w) => w.text), ['voice1000', 'main3000', 'voice5000', 'music8000']);
      for (final perm in [
        [streams[2], streams[0], streams[1]],
        [streams[1], streams[2], streams[0]],
        [streams[2], streams[1], streams[0]],
      ]) {
        expect(WordMapper.mergeStreams(perm), expected);
      }
    });

    test('a shadowed word is not a reason to drop further words of a lower stream', () {
      // Music words are only compared with KEPT words: the dropped main word does not shadow.
      final voice = stream('voice', StreamPriority.voice, 0, [(1000, 1400)]);
      final main = stream('main', StreamPriority.mainVideo, 0, [(1500, 1900)]);
      final music = stream('music', StreamPriority.music, 0, [(2300, 2700)]);
      expect(WordMapper.mergeStreams([voice, main, music]).map((w) => w.text), ['voice1000', 'music2300']);
    });

    test('empty and single streams pass through sorted', () {
      expect(WordMapper.mergeStreams(const []), isEmpty);
      final one = stream('one', StreamPriority.music, 0, [(3000, 3100), (1000, 1100)]);
      expect(WordMapper.mergeStreams([one]).map((w) => w.text), ['one1000', 'one3000']);
    });
  });
}
