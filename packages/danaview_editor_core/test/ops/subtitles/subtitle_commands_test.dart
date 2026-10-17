// OWNER: CORE-15
//
// Subtitle commands (BUILD_PLAN CORE-15): before/after goldens for every command and rejection
// (applied results validate fully, the dry run agrees with the apply) plus targeted checks of
// text handling, timing, notices and flags. Regenerate with
// `UPDATE_GOLDENS=1 dart test test/ops/subtitles` and review the diff.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';
import 'subtitle_fixtures.dart';

ItemId id(String s) => ItemId(s);
Set<ItemId> ids(List<String> s) => {for (final x in s) ItemId(x)};
const TrackId s1 = TrackId('tr_s1');
const TrackId s2 = TrackId('tr_s2');

final List<Case> addCases = [
  ('free space after the last cue', subs, AddCue(f(150), 'New cue', track: s1)),
  ('default length is 2 s', subs, AddCue(f(200), 'Two seconds', track: s1)),
  ('shrinks to the next cue (15 frames)', subs, AddCue(f(75), 'Short', track: s1)),
  ('free span between cues is shorter than 2 s', subs, AddCue(f(60), 'Between', track: s1)),
  ('explicit length', subs, AddCue(f(150), 'One second', track: s1, duration: sec(1))),
  ('at is quantized to the nearest frame', subs, AddCue(f(150) + 7000, 'Quantized', track: s1)),
  ('line breaks are normalized and text trimmed', subs, AddCue(f(150), '  one\r\ntwo \r three ', track: s1)),
  ('inline markup is kept', subs, AddCue(f(150), '<i>Soft</i> and <b>loud</b>', track: s1)),
  ('no lane: topmost unlocked with room', subs, AddCue(f(200), 'Top lane')),
  ('no lane: a lane without room is skipped', subs, AddCue(f(65), 'Elsewhere')),
  ('no lane: no room on any unlocked lane creates one', subs, AddCue(f(10), 'New lane')),
  ('no room anywhere: a new subtitle lane', () {
    final p = subs();
    return p.copyWith(timeline: p.timeline.copyWith(tracks: [for (final t in p.tracks) if (t.id != const TrackId('tr_sl') && t.id != s2) t]));
  }, AddCue(f(10), 'New lane')),
  ('no subtitle lane at all creates one', noSubs, AddCue(f(10), 'First cue')),
  ('inside a cue', subs, AddCue(f(40), 'Inside', track: s1)),
  ('exactly where the next cue starts', subs, AddCue(f(90), 'On the edge', track: s1)),
  ('right after a cue ends', subs, AddCue(f(120), 'After', track: s1)),
  ('empty text', subs, AddCue(f(150), '   ', track: s1)),
  ('negative time', subs, AddCue(-1, 'Before zero', track: s1)),
  ('zero length', subs, AddCue(f(150), 'Zero', track: s1, duration: 0)),
  ('locked lane', subs, AddCue(f(150), 'Locked', track: const TrackId('tr_sl'))),
  ('not a subtitle lane', subs, AddCue(f(150), 'Wrong lane', track: const TrackId('tr_txt'))),
  ('missing lane', subs, AddCue(f(150), 'Nowhere', track: const TrackId('tr_zz'))),
];

final List<Case> textCases = [
  ('change text', subs, SetCueText(id('c1'), 'Hello there')),
  ('line breaks and markup', subs, SetCueText(id('c1'), 'Line <i>one</i>\r\nLine <b>two</b>')),
  ('same text is a no-op', subs, SetCueText(id('c1'), 'Hello world')),
  ('generated cue becomes edited', subs, SetCueText(id('g1'), 'Fixed it')),
  ('already edited stays edited', subs, SetCueText(id('g2'), 'Fixed again')),
  ('same text on a generated cue stays unedited', subs, SetCueText(id('g1'), 'Generated one')),
  ('whitespace only', subs, SetCueText(id('c1'), '  \n ')),
  ('markup only', subs, SetCueText(id('c1'), '<i></i>')),
  ('empty', subs, SetCueText(id('c1'), '')),
  ('missing cue', subs, SetCueText(id('nope'), 'x')),
  ('a text item', subs, SetCueText(id('x'), 'x')),
  ('a video clip', subs, SetCueText(id('v'), 'x')),
  ('locked lane', subs, SetCueText(id('l1'), 'x')),
];

final List<Case> rangeCases = [
  ('extend the end into free space', subs, SetCueRange(id('c3'), f(90), f(150))),
  ('trim the start', subs, SetCueRange(id('c3'), f(100), f(120))),
  ('move both edges', subs, SetCueRange(id('c3'), f(130), f(160))),
  ('touching the neighbour is fine', subs, SetCueRange(id('c3'), f(60), f(120))),
  ('values are quantized to the nearest frame', subs, SetCueRange(id('c3'), f(91) + 12000, f(121) - 12000)),
  ('unchanged is a no-op', subs, SetCueRange(id('c3'), f(90), f(120))),
  ('end overlaps the next cue', subs, SetCueRange(id('c2'), f(30), f(100))),
  ('start overlaps the previous cue', subs, SetCueRange(id('c2'), f(20), f(60))),
  ('clamp: end stops at the next cue', subs, SetCueRange(id('c2'), f(30), f(100), clamp: true)),
  ('clamp: start stops at the previous cue', subs, SetCueRange(id('c2'), f(20), f(60), clamp: true)),
  ('clamp: start stops at zero', subs, SetCueRange(id('c1'), -f(10), f(30), clamp: true)),
  ('negative start', subs, SetCueRange(id('c1'), -f(10), f(30))),
  ('end before start', subs, SetCueRange(id('c3'), f(100), f(90))),
  ('zero length', subs, SetCueRange(id('c3'), f(100), f(100))),
  ('clamp: end moved before start becomes one frame', subs, SetCueRange(id('c3'), f(100), f(95), clamp: true)),
  ('clamp: start moved after end stops one frame short', subs, SetCueRange(id('c3'), f(125), f(120), clamp: true)),
  ('clamp: both neighbours leave no frame', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 30, 'A'), cueOf('b', 30, 1, 'B'), cueOf('c', 31, 30, 'C')]),
      ]), SetCueRange(id('b'), f(31), f(30), clamp: true)),
  ('generated cue becomes edited by a timing edit', subs, SetCueRange(id('g1'), f(0), f(40))),
  ('a text item', subs, SetCueRange(id('x'), f(0), f(10))),
  ('locked lane', subs, SetCueRange(id('l1'), f(0), f(10))),
  ('missing cue', subs, SetCueRange(id('nope'), f(0), f(10))),
];

final List<Case> splitCases = [
  ('with a text cursor', subs, SplitCue(id('c1'), f(15), textSplit: 5)),
  ('cursor after the space', subs, SplitCue(id('c1'), f(15), textSplit: 6)),
  ('no cursor: the word boundary nearest the middle', subs, SplitCue(id('c1'), f(15))),
  ('no cursor: one word splits the middle grapheme', subs, SplitCue(id('c3'), f(105))),
  ('no cursor: a line break is the boundary', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 60, 'Short top\nA much longer second line here')]),
      ]), SplitCue(id('a'), f(30))),
  ('markup open across the cut is closed and reopened', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 60, '<i>one two three four</i>')]),
      ]), SplitCue(id('a'), f(30))),
  ('nested markup across the cut', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 60, '<b>bold <i>both words</i> bold</b> tail')]),
      ]), SplitCue(id('a'), f(30), textSplit: 15)),
  ('CJK without spaces splits the middle', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 60, '你好，世界朋友')]),
      ]), SplitCue(id('a'), f(30))),
  ('a ZWJ emoji is never cut', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 60, 'ab👨‍👩‍👧‍👦cd')]),
      ]), SplitCue(id('a'), f(30), textSplit: 5)),
  ('generated cue: both halves are edited', subs, SplitCue(id('g1'), f(15))),
  ('split time is floored to its frame start', subs, SplitCue(id('c1'), f(15) + 20000, textSplit: 5)),
  ('at the cue start', subs, SplitCue(id('c1'), f(0), textSplit: 5)),
  ('at the cue end', subs, SplitCue(id('c1'), f(30), textSplit: 5)),
  ('outside the cue', subs, SplitCue(id('c1'), f(80), textSplit: 5)),
  ('cursor at 0', subs, SplitCue(id('c1'), f(15), textSplit: 0)),
  ('cursor at the end', subs, SplitCue(id('c1'), f(15), textSplit: 11)),
  ('cursor past the end', subs, SplitCue(id('c1'), f(15), textSplit: 50)),
  ('a half would be empty (cursor after trailing space)', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 60, 'Word   ')]),
      ]), SplitCue(id('a'), f(30), textSplit: 5)),
  ('a single grapheme cannot split', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 60, 'X')]),
      ]), SplitCue(id('a'), f(30))),
  ('locked lane', subs, SplitCue(id('l1'), f(15))),
  ('a text item', subs, SplitCue(id('x'), f(15))),
  ('missing cue', subs, SplitCue(id('nope'), f(15))),
];

final List<Case> mergeCases = [
  ('two touching cues: space when short', subs, MergeCues(ids(['c1', 'c2']))),
  ('a gap is absorbed', subs, MergeCues(ids(['c2', 'c3']))),
  ('three cues', subs, MergeCues(ids(['c1', 'c2', 'c3']))),
  ('long result joins with a line break', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 30, 'This first line is fairly long already'), cueOf('b', 30, 30, 'and the second one too')]),
      ]), MergeCues(ids(['a', 'b']))),
  ('a cue that already has a line break', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 30, 'one\ntwo'), cueOf('b', 30, 30, 'three')]),
      ]), MergeCues(ids(['a', 'b']))),
  ('markup stays', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 30, '<i>soft</i>'), cueOf('b', 30, 30, '<b>loud</b>')]),
      ]), MergeCues(ids(['a', 'b']))),
  ('generated cues: result is edited', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 30, 'one', origin: CueOrigin.generated), cueOf('b', 30, 30, 'two', origin: CueOrigin.generated)]),
      ]), MergeCues(ids(['a', 'b']))),
  ('not consecutive: another cue lies between', subs, MergeCues(ids(['c1', 'c3']))),
  ('different lanes', subs, MergeCues(ids(['c1', 'g1']))),
  ('only one cue', subs, MergeCues(ids(['c1']))),
  ('no cues', subs, MergeCues(ids([]))),
  ('a non-cue', subs, MergeCues(ids(['c1', 'x']))),
  ('missing cue', subs, MergeCues(ids(['c1', 'nope']))),
  ('locked lane', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_sl', [cueOf('a', 0, 30, 'one'), cueOf('b', 30, 30, 'two')], locked: true),
      ]), MergeCues(ids(['a', 'b']))),
];

final List<Case> deleteCases = [
  ('one cue', subs, DeleteCues(ids(['c2']))),
  ('several cues over two lanes in one command', subs, DeleteCues(ids(['c1', 'c3', 'g2']))),
  ('every cue of a lane leaves the lane', subs, DeleteCues(ids(['c1', 'c2', 'c3']))),
  ('nothing selected is a no-op', subs, DeleteCues(ids([]))),
  ('a non-cue', subs, DeleteCues(ids(['x']))),
  ('one locked cue refuses all', subs, DeleteCues(ids(['c1', 'l1']))),
  ('missing cue', subs, DeleteCues(ids(['c1', 'nope']))),
];

final List<Case> shiftCases = [
  ('whole lane +2.5 s', subs, ShiftCues(s1, sec(2.5))),
  ('whole lane -1 s (first cue at 0 stops it)', subs, ShiftCues(s1, -sec(1))),
  ('whole lane -2.5 s from a lane that starts later', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 600)], main: true),
        subLane('tr_s1', [cueOf('a', 120, 30, 'A'), cueOf('b', 150, 30, 'B'), cueOf('c', 300, 30, 'C')]),
      ]), ShiftCues(s1, -sec(2.5))),
  ('whole lane -5 s clamps at 0 with a notice', () => project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 600)], main: true),
        subLane('tr_s1', [cueOf('a', 60, 30, 'A'), cueOf('b', 100, 30, 'B')]),
      ]), ShiftCues(s1, -sec(5))),
  ('range: only the cues that start inside', subs, ShiftCues(s1, sec(1), range: TimeRange(f(60), f(200)))),
  ('range: the shifted cue would hit the one that stays', subs, ShiftCues(s1, sec(2), range: TimeRange(f(0), f(31)))),
  ('range: moving left into the gap', subs, ShiftCues(s1, -sec(1), range: TimeRange(f(80), f(200)))),
  ('range without cues is a no-op', subs, ShiftCues(s1, sec(1), range: TimeRange(f(200), f(300)))),
  ('delta is quantized to whole frames', subs, ShiftCues(s1, 20000, range: TimeRange(f(80), f(200)))),
  ('delta below half a frame is a no-op', subs, ShiftCues(s1, 10000)),
  ('zero delta is a no-op', subs, ShiftCues(s1, 0)),
  ('generated cues become edited', subs, ShiftCues(s2, sec(1))),
  ('locked lane', subs, ShiftCues(const TrackId('tr_sl'), sec(1))),
  ('not a subtitle lane', subs, ShiftCues(const TrackId('tr_txt'), sec(1))),
  ('missing lane', subs, ShiftCues(const TrackId('tr_zz'), sec(1))),
];

final List<Case> styleCases = [
  ('style', subs, SetSubtitleStyle(s1, const SubtitleStyle(fontSizePt: 60, bold: true, maxLines: 3))),
  ('style: font size too small', subs, SetSubtitleStyle(s1, const SubtitleStyle(fontSizePt: 7))),
  ('style: font size too large', subs, SetSubtitleStyle(s1, const SubtitleStyle(fontSizePt: 201))),
  ('style: font size NaN', subs, SetSubtitleStyle(s1, SubtitleStyle(fontSizePt: double.nan))),
  ('style: max lines 0', subs, SetSubtitleStyle(s1, const SubtitleStyle(maxLines: 0))),
  ('style: max lines 4', subs, SetSubtitleStyle(s1, const SubtitleStyle(maxLines: 4))),
  ('style: max width 0', subs, SetSubtitleStyle(s1, const SubtitleStyle(maxWidth: 0))),
  ('style: max width above 1', subs, SetSubtitleStyle(s1, const SubtitleStyle(maxWidth: 1.2))),
  ('style: same style is a no-op', subs, SetSubtitleStyle(s1, const SubtitleStyle())),
  ('style on a generated lane keeps its provenance and cue flags', subs, SetSubtitleStyle(s2, const SubtitleStyle(italic: true))),
  ('style: locked lane', subs, SetSubtitleStyle(const TrackId('tr_sl'), const SubtitleStyle(italic: true))),
  ('style: text lane', subs, SetSubtitleStyle(const TrackId('tr_txt'), const SubtitleStyle(italic: true))),
  ('position top', subs, SetSubtitlePosition(s1, SubtitlePosition.top)),
  ('position custom', subs, SetSubtitlePosition(s1, const CustomSubtitlePosition(0.25))),
  ('position custom below 0', subs, SetSubtitlePosition(s1, const CustomSubtitlePosition(-0.1))),
  ('position custom above 1', subs, SetSubtitlePosition(s1, const CustomSubtitlePosition(1.5))),
  ('position same is a no-op', subs, SetSubtitlePosition(s1, SubtitlePosition.bottom)),
  ('burn-in off', subs, SetBurnIn(s1, false)),
  ('burn-in same is a no-op', subs, SetBurnIn(s1, true)),
  ('burn-in on a locked lane', subs, SetBurnIn(const TrackId('tr_sl'), false)),
  ('language', subs, SetSubtitleLanguage(s1, 'pt-BR')),
  ('language trimmed', subs, SetSubtitleLanguage(s1, ' fr ')),
  ('language cleared', subs, SetSubtitleLanguage(s2, null)),
  ('language blank clears', subs, SetSubtitleLanguage(s2, '  ')),
  ('language not a tag', subs, SetSubtitleLanguage(s1, 'english language')),
  ('language same is a no-op', subs, SetSubtitleLanguage(s2, 'en')),
  ('language on a video lane', subs, SetSubtitleLanguage(const TrackId('tr_main'), 'en')),
];

void main() {
  final golden = GoldenFile('test/ops/subtitles/goldens/subtitles.golden');
  tearDownAll(golden.save);

  group('AddCue', () => goldenCases(golden, 'add', addCases));
  group('SetCueText', () => goldenCases(golden, 'text', textCases));
  group('SetCueRange', () => goldenCases(golden, 'range', rangeCases));
  group('SplitCue', () => goldenCases(golden, 'split', splitCases));
  group('MergeCues', () => goldenCases(golden, 'merge', mergeCases));
  group('DeleteCues', () => goldenCases(golden, 'delete', deleteCases));
  group('ShiftCues', () => goldenCases(golden, 'shift', shiftCases));
  group('Style, position, burn-in, language', () => goldenCases(golden, 'settings', styleCases));

  group('AddCue details', () {
    test('lands on the lane at the frame with the defaults, selects the new cue', () {
      final out = applyCommand(subs(), AddCue(f(150), 'New', track: s1), ctx());
      final c = cuesOf(out.project, 'tr_s1').last;
      expect((rate.frameIndexOf(c.start), rate.frameIndexOf(c.end)), (150, 210));
      expect(c.origin, CueOrigin.manual);
      expect(c.editedAfterGeneration, isFalse);
      expect(out.selection?.primary, c.id);
      expect(out.selection?.lane, s1);
      expect(out.affected, {c.id});
    });

    test('the policy default length applies', () {
      final out = applyCommand(subs(), AddCue(f(200), 'x', track: s1), ctx(policy: const EditPolicy(defaultCueUs: 3 * microsPerSecond)));
      expectFrames(out.project, 'tr_s1', [(0, 30), (30, 60), (90, 120), (200, 290)]);
    });

    test('a new lane goes on top of the subtitle lanes, dry run reports it', () {
      final p = noSubs();
      final pre = dryRun(p, AddCue(f(10), 'x'), ctx());
      expect(pre.createsTracks.single.kind, TrackKind.subtitle);
      final out = applyCommand(p, AddCue(f(10), 'x'), ctx());
      expect(out.createdTracks, hasLength(1));
      expect(out.project.tracks.last.kind, TrackKind.subtitle);
    });

    test('keeps working until the lane is full: a cue per call fills the free space', () {
      var p = subs();
      for (var i = 0; i < 4; i++) {
        final out = applyCommand(p, AddCue(f(60), 'fill $i', track: s1), ctx(seed: 100 + i));
        if (out.rejection != null) {
          expect(out.rejection, const NoRoom());
          break;
        }
        p = out.project;
        expectValid(p, 'after fill $i');
      }
      expect(cuesOf(p, 'tr_s1').length, 4, reason: 'the 30-frame hole takes one cue, then it is full');
    });
  });

  group('text and timing edits mark generated cues', () {
    final edits = <String, EditCommand Function()>{
      'SetCueText': () => SetCueText(id('g1'), 'changed'),
      'SetCueRange': () => SetCueRange(id('g1'), f(0), f(40)),
      'SplitCue': () => SplitCue(id('g1'), f(15)),
      'MergeCues': () => MergeCues(ids(['g1', 'g2'])),
      'ShiftCues': () => ShiftCues(s2, sec(1)),
    };
    for (final e in edits.entries) {
      test('${e.key} sets editedAfterGeneration, origin stays generated', () {
        final out = applyCommand(subs(), e.value(), ctx());
        expect(out.rejection, isNull);
        final cues = cuesOf(out.project, 'tr_s2');
        expect(cues, isNotEmpty);
        for (final c in cues) {
          expect(c.origin, CueOrigin.generated);
          expect(c.editedAfterGeneration, isTrue, reason: '${e.key}: ${c.id}');
        }
      });
    }

    test('manual and imported cues are never marked', () {
      final p = project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 30, 'ab cd', origin: CueOrigin.imported), cueOf('b', 30, 30, 'b')]),
      ]);
      for (final c in [SetCueText(id('a'), 'z'), SetCueRange(id('b'), f(30), f(50)), SplitCue(id('a'), f(15)), ShiftCues(s1, sec(1))]) {
        final out = applyCommand(p, c, ctx());
        expect(out.rejection, isNull, reason: '$c');
        for (final cue in cuesOf(out.project, 'tr_s1')) {
          expect(cue.editedAfterGeneration, isFalse, reason: '$c');
        }
      }
    });

    test('style, position, burn-in and language changes do not touch cue flags', () {
      var p = subs();
      for (final c in [
        SetSubtitleStyle(s2, const SubtitleStyle(bold: true)),
        SetSubtitlePosition(s2, SubtitlePosition.top),
        SetBurnIn(s2, false),
        SetSubtitleLanguage(s2, 'fr'),
      ]) {
        p = applyCommand(p, c, ctx()).project;
      }
      expect(cuesOf(p, 'tr_s2').map((c) => c.editedAfterGeneration), [false, true], reason: 'g2 was edited before');
    });
  });

  group('SetCueText', () {
    test('coalesce key is per cue', () {
      expect(SetCueText.coalesceKey(id('c1')), 'cue:c1');
      expect(SetCueText.coalesceKey(id('c2')), isNot(SetCueText.coalesceKey(id('c1'))));
    });

    test('keeps the markup and line breaks exactly', () {
      final out = applyCommand(subs(), SetCueText(id('c1'), '<i>a</i>\nb\r\nc'), ctx());
      expect(cueIn(out.project, 'c1').text, '<i>a</i>\nb\nc');
    });
  });

  group('SetCueRange', () {
    test('clamp reports the clamped range for the drag ghost', () {
      final pre = dryRun(subs(), SetCueRange(id('c2'), f(30), f(100), clamp: true), ctx());
      expect(pre.rejection, isNull);
      expect(pre.clampedTo, TimeRange(f(30), f(90)));
      final fits = dryRun(subs(), SetCueRange(id('c2'), f(30), f(80), clamp: true), ctx());
      expect(fits.clampedTo, isNull);
    });

    test('WouldOverlap names the lane and the overlapping part', () {
      final out = applyCommand(subs(), SetCueRange(id('c2'), f(30), f(100)), ctx());
      expect(out.rejection, WouldOverlap(s1, TimeRange(f(90), f(100))));
      final out2 = applyCommand(subs(), SetCueRange(id('c2'), f(20), f(60)), ctx());
      expect(out2.rejection, WouldOverlap(s1, TimeRange(f(20), f(30))));
    });

    test('results are on the grid and at least one frame', () {
      final out = applyCommand(subs(), SetCueRange(id('c3'), f(91) + 12000, f(92) + 3000), ctx());
      expect(out.rejection, isNull);
      final c = cueIn(out.project, 'c3');
      expect(rate.isOnGrid(c.start) && rate.isOnGrid(c.end), isTrue);
      expect(rate.frameIndexOf(c.end) - rate.frameIndexOf(c.start), greaterThanOrEqualTo(1));
    });
  });

  group('SplitCue', () {
    test('the left half keeps the id, the right one gets a fresh id, ranges tile the original', () {
      final out = applyCommand(subs(), SplitCue(id('c1'), f(12), textSplit: 5), ctx());
      final cues = cuesOf(out.project, 'tr_s1');
      expect(cues[0].id, id('c1'));
      expect(cues[1].id, isNot(id('c1')));
      expect(cues[1].id.value.length, 15);
      expect((cues[0].start, cues[0].end, cues[1].start, cues[1].end), (f(0), f(12), f(12), f(30)));
      expect(cues[0].text, 'Hello');
      expect(cues[1].text, 'world');
      expect(out.selection?.items, {cues[0].id, cues[1].id});
    });

    test('texts rejoin to the original (no characters lost) for every cursor position', () {
      const text = 'Hello <i>brave new</i> world, again';
      final p = project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 60, text)]),
      ]);
      for (var cursor = 1; cursor < text.length; cursor++) {
        final out = applyCommand(p, SplitCue(id('a'), f(30), textSplit: cursor), ctx());
        if (out.rejection != null) {
          expect(out.rejection, const EmptyText(), reason: 'cursor $cursor');
          continue;
        }
        final cues = cuesOf(out.project, 'tr_s1');
        expect(cues, hasLength(2), reason: 'cursor $cursor');
        final visible = [for (final c in cues) c.text.replaceAll(RegExp(r'</?[ib]>'), '')].join();
        expect(visible.replaceAll(RegExp(r'\s+'), ''), 'Hellobravenewworld,again', reason: 'cursor $cursor');
        for (final c in cues) {
          final opens = RegExp(r'<i>').allMatches(c.text).length;
          final closes = RegExp(r'</i>').allMatches(c.text).length;
          expect(opens, closes, reason: 'cursor $cursor: ${c.text}');
        }
        expectValid(out.project, 'cursor $cursor');
      }
    });

    test('a cursor inside a tag moves to the nearest boundary outside it', () {
      final p = project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
        subLane('tr_s1', [cueOf('a', 0, 60, 'one <i>two</i> three')]),
      ]);
      final out = applyCommand(p, SplitCue(id('a'), f(30), textSplit: 6), ctx());
      expect(out.rejection, isNull);
      final cues = cuesOf(out.project, 'tr_s1');
      expect(cues.every((c) => !c.text.contains('<i') || c.text.contains('<i>')), isTrue);
    });
  });

  group('MergeCues', () {
    test('keeps the first id and the union range; the others are gone', () {
      final out = applyCommand(subs(), MergeCues(ids(['c2', 'c3'])), ctx());
      final cues = cuesOf(out.project, 'tr_s1');
      expect(cues.map((c) => c.id.value), ['c1', 'c2']);
      expect((cues[1].start, cues[1].end), (f(30), f(120)));
      expect(cues[1].text, 'Second one Third');
      expect(out.affected, ids(['c2', 'c3']));
      expect(out.selection?.primary, id('c2'));
    });

    test('the space join limit is 42 graphemes of visible text', () {
      String joined(String a, String b) {
        final p = project([
          lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
          subLane('tr_s1', [cueOf('a', 0, 30, a), cueOf('b', 30, 30, b)]),
        ]);
        return cueIn(applyCommand(p, MergeCues(ids(['a', 'b'])), ctx()).project, 'a').text;
      }

      expect(joined('x' * 20, 'y' * 21), '${'x' * 20} ${'y' * 21}', reason: '42 graphemes exactly');
      expect(joined('x' * 20, 'y' * 22), '${'x' * 20}\n${'y' * 22}', reason: '43 graphemes');
      expect(joined('<i>${'x' * 20}</i>', 'y' * 21), '<i>${'x' * 20}</i> ${'y' * 21}', reason: 'tags are not counted');
      expect(joined('👨‍👩‍👧‍👦' * 20, 'ab'), '${'👨‍👩‍👧‍👦' * 20} ab', reason: 'graphemes, not code units');
    });

    test('the order of the ids does not matter', () {
      final a = applyCommand(subs(), MergeCues({id('c2'), id('c1')}), ctx());
      final b = applyCommand(subs(), MergeCues({id('c1'), id('c2')}), ctx());
      expect(a.project, b.project);
    });
  });

  group('ShiftCues', () {
    EditProject imported() {
      final out = applyCommand(
        project([lane('tr_main', TrackKind.video, [vclip('v', 0, 1200)], main: true)]),
        ImportSubtitles([
          for (var i = 0; i < 20; i++) SubtitleCueDraft(TimeRange(f(100 + i * 30), f(125 + i * 30)), 'Line $i'),
        ]),
        ctx(),
      );
      return out.project;
    }

    test('a whole imported lane by +2.5 s and -2.5 s is one entry and exact', () {
      final p = imported();
      final lane = p.tracks.last.id;
      final before = cuesOf(p, lane.value);
      final up = applyCommand(p, ShiftCues(lane, sec(2.5)), ctx());
      expect(up.rejection, isNull);
      final shifted = cuesOf(up.project, lane.value);
      for (var i = 0; i < before.length; i++) {
        expect(shifted[i].start - before[i].start, sec(2.5));
        expect(shifted[i].duration, before[i].duration);
        expect(shifted[i].id, before[i].id);
      }
      expect(up.changedTracks, {lane});
      final down = applyCommand(up.project, ShiftCues(lane, -sec(2.5)), ctx());
      expect(cuesOf(down.project, lane.value), before, reason: 'a round trip is exact');
      expectValid(up.project);
    });

    test('clamping at zero reports the applied frames', () {
      final p = project([
        lane('tr_main', TrackKind.video, [vclip('v', 0, 600)], main: true),
        subLane('tr_s1', [cueOf('a', 60, 30, 'A'), cueOf('b', 100, 30, 'B')]),
      ]);
      final out = applyCommand(p, ShiftCues(s1, -sec(5)), ctx());
      expectFrames(out.project, 'tr_s1', [(0, 30), (40, 70)]);
      expect(out.notices, [EditNotice(SubtitleNoticeCodes.shiftClampedAtZero, count: 60)]);
    });

    test('shifting left when the first cue is at 0 changes nothing but still tells', () {
      final out = applyCommand(subs(), ShiftCues(s1, -sec(1)), ctx());
      expect(out.noop, isTrue);
      expect(out.notices.map((n) => n.code), [SubtitleNoticeCodes.shiftClampedAtZero]);
    });

    test('a shifted range cannot jump over cues that stay', () {
      final out = applyCommand(subs(), ShiftCues(s1, sec(2), range: TimeRange(f(0), f(31))), ctx());
      expect(out.rejection, WouldOverlap(s1, TimeRange(f(90), f(120))));
      // One second is fine: c2 ends exactly where c3 starts.
      expect(applyCommand(subs(), ShiftCues(s1, sec(1), range: TimeRange(f(0), f(31))), ctx()).rejection, isNull);
    });

    test('the same delta on the whole lane keeps every gap', () {
      final out = applyCommand(subs(), ShiftCues(s1, sec(0.5)), ctx());
      expectFrames(out.project, 'tr_s1', [(15, 45), (45, 75), (105, 135)]);
    });
  });

  group('ImportSubtitles', () {
    EditProject empty() => noSubs();
    SubtitleCueDraft draft(num fromSec, num toSec, String text) => SubtitleCueDraft(TimeRange(sec(fromSec), sec(toSec)), text);

    test('a new lane of imported cues, rounded to frames, one entry', () {
      final out = applyCommand(
        empty(),
        ImportSubtitles([draft(1.0, 2.5, 'One'), draft(2.5, 4.0, 'Two'), draft(5.001, 5.002, 'Tiny')], name: 'English', language: 'en'),
        ctx(),
      );
      expect(out.rejection, isNull);
      final lane = out.project.tracks.last;
      expect(lane.kind, TrackKind.subtitle);
      expect(lane.name, 'English');
      expect(lane.subtitle!.language, 'en');
      expect(lane.subtitle!.provenance, isNull);
      final cues = lane.items.cast<SubtitleCue>();
      expect(cues.map((c) => c.origin), everyElement(CueOrigin.imported));
      expect(cues.map((c) => c.editedAfterGeneration), everyElement(isFalse));
      expect([for (final c in cues) (rate.frameIndexOf(c.start), rate.frameIndexOf(c.end))], [(30, 75), (75, 120), (150, 151)]);
      expect(out.createdTracks, {lane.id});
      expect(out.selection?.lane, lane.id);
      expect(out.selection?.items, {for (final c in cues) c.id});
      expectValid(out.project);
    });

    test('unsorted input is sorted; ids are fresh and unique', () {
      final out = applyCommand(empty(), ImportSubtitles([draft(4, 5, 'C'), draft(0, 1, 'A'), draft(2, 3, 'B')]), ctx());
      final cues = out.project.tracks.last.items.cast<SubtitleCue>();
      expect(cues.map((c) => c.text), ['A', 'B', 'C']);
      expect({for (final c in cues) c.id}.length, 3);
    });

    test('overlapping cues spill onto a second lane; nothing is lost', () {
      final out = applyCommand(
        empty(),
        ImportSubtitles([draft(0, 3, 'A'), draft(2, 5, 'B'), draft(4, 6, 'C'), draft(6, 8, 'D')], name: 'Subs'),
        ctx(),
      );
      expect(out.rejection, isNull);
      final lanes = out.project.tracks.where((t) => t.kind == TrackKind.subtitle).toList();
      expect(lanes, hasLength(2));
      expect(lanes.map((l) => l.name), ['Subs', 'Subs 2']);
      expect(lanes[0].items.cast<SubtitleCue>().map((c) => c.text), ['A', 'C', 'D']);
      expect(lanes[1].items.cast<SubtitleCue>().map((c) => c.text), ['B']);
      expect(out.notices, [EditNotice(SubtitleNoticeCodes.cuesSpilled, count: 1)]);
      expect(out.createdTracks, hasLength(2));
      expectValid(out.project);
    });

    test('triple overlap needs three lanes', () {
      final out = applyCommand(empty(), ImportSubtitles([draft(0, 5, 'A'), draft(1, 5, 'B'), draft(2, 5, 'C')]), ctx());
      expect(out.project.tracks.where((t) => t.kind == TrackKind.subtitle), hasLength(3));
      expect(out.notices.single.count, 2);
    });

    test('touching cues do not spill', () {
      final out = applyCommand(empty(), ImportSubtitles([draft(0, 1, 'A'), draft(1, 2, 'B')]), ctx());
      expect(out.project.tracks.where((t) => t.kind == TrackKind.subtitle), hasLength(1));
      expect(out.notices, isEmpty);
    });

    test('blank cues are skipped with a notice', () {
      final out = applyCommand(empty(), ImportSubtitles([draft(0, 1, 'A'), draft(1, 2, '  '), draft(2, 3, '<i></i>')]), ctx());
      expect(out.project.tracks.last.items, hasLength(1));
      expect(out.notices, [EditNotice(SubtitleNoticeCodes.cuesSkipped, count: 2)]);
    });

    test('replace swaps every cue of the lane and keeps its settings', () {
      final p = subs();
      final custom = applyCommand(p, SetSubtitleStyle(s1, const SubtitleStyle(bold: true)), ctx()).project;
      final out = applyCommand(custom, ImportSubtitles([draft(10, 11, 'Fresh')], mode: SubtitleImportMode.replace, track: s1), ctx());
      expect(out.rejection, isNull);
      final lane = out.project.tracks.firstWhere((t) => t.id == s1);
      expect(lane.items.map((i) => (i as SubtitleCue).text), ['Fresh']);
      expect(lane.subtitle!.style.bold, isTrue);
      expect(out.affected, containsAll(ids(['c1', 'c2', 'c3'])));
      expect(out.createdTracks, isEmpty);
    });

    test('replacing a generated lane clears its provenance (the cues are not generated any more)', () {
      final out = applyCommand(subs(), ImportSubtitles([draft(0, 1, 'x')], mode: SubtitleImportMode.replace, track: s2), ctx());
      final lane = out.project.tracks.firstWhere((t) => t.id == s2);
      expect(lane.subtitle!.provenance, isNull);
      expect(lane.subtitle!.language, 'en');
    });

    test('replace with overlapping cues spills onto new lanes with the same settings', () {
      final out = applyCommand(subs(), ImportSubtitles([draft(0, 3, 'A'), draft(1, 4, 'B')], mode: SubtitleImportMode.replace, track: s1), ctx());
      final lanes = out.project.tracks.where((t) => t.kind == TrackKind.subtitle).toList();
      expect(lanes, hasLength(4)); // s1, s2, sl, spill
      expect(out.createdTracks, hasLength(1));
      expectValid(out.project);
    });

    test('rejections', () {
      expect(applyCommand(empty(), ImportSubtitles([]), ctx()).rejection, const InvalidValue('cues'));
      expect(applyCommand(empty(), ImportSubtitles([draft(0, 1, ' ')]), ctx()).rejection, const InvalidValue('cues'));
      expect(applyCommand(subs(), ImportSubtitles([draft(0, 1, 'x')], mode: SubtitleImportMode.replace), ctx()).rejection, const InvalidValue('track'));
      expect(applyCommand(subs(), ImportSubtitles([draft(0, 1, 'x')], mode: SubtitleImportMode.replace, track: const TrackId('tr_sl')), ctx()).rejection,
          const TrackLocked(TrackId('tr_sl')));
      expect(applyCommand(subs(), ImportSubtitles([draft(0, 1, 'x')], mode: SubtitleImportMode.replace, track: const TrackId('tr_txt')), ctx()).rejection,
          const IncompatibleTrack(TrackId('tr_txt')));
      expect(applyCommand(subs(), ImportSubtitles([draft(0, 1, 'x')], mode: SubtitleImportMode.replace, track: const TrackId('tr_zz')), ctx()).rejection,
          const ItemNotFound('tr_zz'));
    });

    test('3,000 cues import and validate', () {
      final out = applyCommand(
        empty(),
        ImportSubtitles([for (var i = 0; i < 3000; i++) draft(i * 2.0, i * 2.0 + 1.5, 'Cue number $i')]),
        ctx(policy: const EditPolicy(maxItems: 5000)),
      );
      expect(out.rejection, isNull);
      expect(out.project.tracks.last.items, hasLength(3000));
      expectValid(out.project);
    });
  });

  group('Style, position, burn-in, language', () {
    test('values land on the lane, other lanes and cues are untouched', () {
      final p = subs();
      final out = applyCommand(p, SetSubtitleStyle(s1, const SubtitleStyle(fontSizePt: 60, maxLines: 3)), ctx());
      final lane = out.project.tracks.firstWhere((t) => t.id == s1);
      expect(lane.subtitle!.style.fontSizePt, 60);
      expect(lane.items, p.tracks.firstWhere((t) => t.id == s1).items);
      expect(out.changedTracks, {s1});
      expect(identical(out.project.tracks.firstWhere((t) => t.id == s2), p.tracks.firstWhere((t) => t.id == s2)), isTrue);
    });

    test('language tags: accepted and refused shapes', () {
      for (final ok in ['en', 'pt-BR', 'zh-Hant', 'fil', 'es-419', 'sr-Latn-RS']) {
        expect(applyCommand(subs(), SetSubtitleLanguage(s1, ok), ctx()).rejection, isNull, reason: ok);
      }
      for (final bad in ['e', 'english', 'en_US', 'en-', '12', 'en US']) {
        expect(applyCommand(subs(), SetSubtitleLanguage(s1, bad), ctx()).rejection, const InvalidValue('language'), reason: bad);
      }
    });
  });

  group('every applied command keeps the project valid on a random project', () {
    // Random sequences of subtitle commands on a project with subtitle lanes: the framework
    // validates after every step; here the full validator runs too.
    test('200 steps', () {
      var p = subs();
      final lanes = [s1, s2];
      var step = 0;
      var seed = 1000;
      EditCommand next(int i) {
        final laneId = lanes[i % 2];
        final cues = cuesOf(p, laneId.value);
        final c = cues.isEmpty ? null : cues[(i * 7) % cues.length];
        switch (i % 9) {
          case 0:
            return AddCue(f((i * 37) % 600), 'cue $i', track: laneId);
          case 1:
            return c == null ? AddCue(f(5), 'x', track: laneId) : SetCueText(c.id, 'edited $i');
          case 2:
            return c == null ? AddCue(f(5), 'x', track: laneId) : SetCueRange(c.id, c.start - f(i % 5), c.end + f(i % 7), clamp: true);
          case 3:
            return c == null ? AddCue(f(5), 'x', track: laneId) : SplitCue(c.id, c.start + (c.duration ~/ 2));
          case 4:
            return cues.length < 2 ? AddCue(f(5), 'x', track: laneId) : MergeCues({cues[0].id, cues[1].id});
          case 5:
            return c == null ? AddCue(f(5), 'x', track: laneId) : DeleteCues({c.id});
          case 6:
            return ShiftCues(laneId, f(i % 11) - f(5));
          case 7:
            return ShiftCues(laneId, f(i % 3), range: TimeRange(f(40), f(400)));
          default:
            return ImportSubtitles([SubtitleCueDraft(TimeRange(f(i), f(i + 20)), 'imp $i')], mode: SubtitleImportMode.replace, track: laneId);
        }
      }

      var applied = 0;
      for (; step < 200; step++) {
        final out = applyCommand(p, next(step), ctx(seed: seed++));
        if (out.rejection != null) continue;
        p = out.project;
        applied++;
        expectValid(p, 'step $step');
      }
      expect(applied, greaterThan(80));
    });
  });
}
