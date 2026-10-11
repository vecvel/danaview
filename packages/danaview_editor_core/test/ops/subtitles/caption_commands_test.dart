// OWNER: CORE-15
//
// AddGeneratedCaptionTrack and ReplaceGeneratedCaptions (ai.md §10.2, BUILD_PLAN CORE-15):
// goldens, one-history-entry semantics, fresh ids, origin and flags, replace-in-range boundaries,
// locked-lane rejection as data. Regenerate with `UPDATE_GOLDENS=1 dart test test/ops/subtitles`.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';
import 'subtitle_fixtures.dart';

const TrackId s1 = TrackId('tr_s1');
const TrackId s2 = TrackId('tr_s2');

SubtitleCueDraft draft(int k0, int k1, String text) => SubtitleCueDraft(TimeRange(f(k0), f(k1)), text);

AddGeneratedCaptionTrack add(List<SubtitleCueDraft> cues, {String name = 'Captions (English)', String language = 'en', CaptionProvenance? prov}) =>
    AddGeneratedCaptionTrack(trackName: name, language: language, provenance: prov ?? provenance(language: language), cues: cues);

ReplaceGeneratedCaptions replace(TrackId track, List<SubtitleCueDraft> cues, {TimeRange? range, CaptionProvenance? prov}) =>
    ReplaceGeneratedCaptions(track: track, range: range, provenance: prov ?? provenance(model: 'whisper-small-q5_1'), cues: cues);

/// A generated lane with cues at frames 0-30, 40-70, 80-110, 120-150 and a manual lane after it.
EditProject generated() => project([
      lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
      subLane('tr_g', [
        cueOf('g1', 0, 30, 'one', origin: CueOrigin.generated),
        cueOf('g2', 40, 30, 'two', origin: CueOrigin.generated, edited: true),
        cueOf('g3', 80, 30, 'three', origin: CueOrigin.generated),
        cueOf('g4', 120, 30, 'four', origin: CueOrigin.generated),
      ], data: SubtitleTrackData(language: 'en', provenance: provenance())),
      subLane('tr_m', [cueOf('m1', 0, 30, 'manual')]),
    ]);

const TrackId g = TrackId('tr_g');

final List<Case> addCases = [
  ('a new lane on top of the subtitle lanes', subs,
      add([draft(0, 30, 'Hello there'), draft(30, 70, 'General Kenobi')])),
  ('first subtitle lane of the project', noSubs, add([draft(5, 35, 'Only cue')], name: 'Captions (日本語)', language: 'ja')),
  ('off-grid drafts are put on the grid, one frame at least', subs,
      add([SubtitleCueDraft(TimeRange(1000000, 1990000), 'Rounded'), SubtitleCueDraft(TimeRange(2500000, 2500100), 'Tiny')])),
  ('overlapping drafts: the later one starts where the earlier ends', subs, add([draft(0, 60, 'Long'), draft(30, 90, 'Overlaps')])),
  ('a draft inside the previous one is dropped', subs, add([draft(0, 90, 'Long'), draft(30, 60, 'Inside'), draft(90, 120, 'After')])),
  ('unsorted drafts are sorted', subs, add([draft(60, 90, 'B'), draft(0, 30, 'A')])),
  ('blank drafts are dropped', subs, add([draft(0, 30, 'A'), draft(30, 60, '   '), draft(60, 90, 'C')])),
  ('line breaks and markup', subs, add([draft(0, 60, '  <i>first</i>\r\n second  ')])),
  ('no drafts', subs, add([])),
  ('only blank drafts: no empty lane is created', subs, add([draft(0, 30, ' ')])),
];

final List<Case> replaceCases = [
  ('whole lane', generated, replace(g, [draft(0, 40, 'New one'), draft(50, 100, 'New two')])),
  ('whole lane: edited cues are replaced too', generated, replace(g, [draft(10, 20, 'Only')])),
  ('in range: only overlapping cues are replaced', generated,
      replace(g, [draft(45, 65, 'Fresh'), draft(85, 100, 'Fresher')], range: TimeRange(f(45), f(100)))),
  ('in range: a cue straddling the start is replaced', generated, replace(g, [draft(50, 75, 'Fresh')], range: TimeRange(f(60), f(75)))),
  ('in range: a cue ending exactly at the range start stays', generated, replace(g, [draft(70, 78, 'Fresh')], range: TimeRange(f(70), f(78)))),
  ('in range: a cue starting exactly at the range end stays', generated, replace(g, [draft(70, 78, 'Fresh')], range: TimeRange(f(70), f(80)))),
  ('in range: new cues stop at the cues that stay', generated, replace(g, [draft(60, 130, 'Too long')], range: TimeRange(f(70), f(80)))),
  ('in range: a draft with no free frame is dropped', generated, replace(g, [draft(0, 30, 'Where g1 stays')], range: TimeRange(f(75), f(80)))),
  ('in range: nothing overlaps, drafts are just added', generated, replace(g, [draft(112, 118, 'Gap')], range: TimeRange(f(110), f(120)))),
  ('empty range', generated, replace(g, [draft(0, 10, 'x')], range: TimeRange(f(10), f(10)))),
  ('reversed range is impossible; empty drafts', generated, replace(g, [])),
  ('locked lane', () {
    final p = generated();
    return p.copyWith(timeline: p.timeline.copyWith(tracks: [for (final t in p.tracks) t.id == g ? t.copyWith(locked: true) : t]));
  }, replace(g, [draft(0, 10, 'x')])),
  ('a lane without provenance', generated, replace(const TrackId('tr_m'), [draft(10, 20, 'x')], range: TimeRange(f(5), f(25)))),
  ('not a subtitle lane', generated, replace(const TrackId('tr_main'), [draft(10, 20, 'x')])),
  ('missing lane', generated, replace(const TrackId('tr_zz'), [draft(10, 20, 'x')])),
];

void main() {
  final golden = GoldenFile('test/ops/subtitles/goldens/captions.golden');
  tearDownAll(golden.save);

  group('AddGeneratedCaptionTrack goldens', () => goldenCases(golden, 'add', addCases));
  group('ReplaceGeneratedCaptions goldens', () => goldenCases(golden, 'replace', replaceCases));

  group('AddGeneratedCaptionTrack', () {
    test('is one history entry: one outcome, one new lane, every cue generated and unedited', () {
      final p = subs();
      final out = applyCommand(p, add([draft(0, 30, 'a'), draft(30, 60, 'b'), draft(60, 90, 'c')]), ctx());
      expect(out.rejection, isNull);
      expect(out.createdTracks, hasLength(1));
      expect(out.changedTracks, out.createdTracks);
      final lane = out.project.tracks.firstWhere((t) => out.createdTracks.contains(t.id));
      expect(lane.kind, TrackKind.subtitle);
      expect(lane.name, 'Captions (English)');
      expect(lane.subtitle!.language, 'en');
      expect(lane.subtitle!.provenance, provenance());
      expect(lane.items.cast<SubtitleCue>().map((c) => (c.origin, c.editedAfterGeneration)), everyElement((CueOrigin.generated, false)));
      expectValid(out.project);
    });

    test('goes on top of the subtitle lanes and is the suggested selection', () {
      final out = applyCommand(subs(), add([draft(0, 30, 'a')]), ctx());
      final subtitleLanes = out.project.tracks.where((t) => t.kind == TrackKind.subtitle).toList();
      expect(out.createdTracks.single, subtitleLanes.last.id);
      expect(out.selection?.lane, subtitleLanes.last.id);
      expect(out.selection?.items, isEmpty);
    });

    test('cue ids are fresh, never reused across two runs', () {
      final p = subs();
      final a = applyCommand(p, add([draft(0, 30, 'a'), draft(30, 60, 'b')]), ctx(seed: 1));
      final b = applyCommand(a.project, add([draft(0, 30, 'a'), draft(30, 60, 'b')]), ctx(seed: 2));
      final all = [for (final t in b.project.tracks) for (final i in t.items) i.id];
      expect(all.toSet().length, all.length);
    });

    test('the dry run reports the new lane', () {
      final pre = dryRun(subs(), add([draft(0, 30, 'a')]), ctx());
      expect(pre.createsTracks.single.kind, TrackKind.subtitle);
      expect(pre.placements, hasLength(1));
    });

    test('skipped drafts are reported', () {
      final out = applyCommand(subs(), add([draft(0, 60, 'a'), draft(10, 20, 'inside'), draft(60, 90, ' ')]), ctx());
      expect(out.notices, [EditNotice(SubtitleNoticeCodes.cuesSkipped, count: 2)]);
    });

    test('undoing is restoring the previous project: nothing but the lane differs', () {
      final p = subs();
      final out = applyCommand(p, add([draft(0, 30, 'a')]), ctx());
      final without = [for (final t in out.project.tracks) if (!out.createdTracks.contains(t.id)) t];
      expect(without, p.tracks);
    });
  });

  group('ReplaceGeneratedCaptions', () {
    test('whole lane: the lane keeps its id, position and settings; provenance is the new one', () {
      final p = generated();
      final out = applyCommand(p, replace(g, [draft(0, 40, 'New')]), ctx());
      final lane = out.project.tracks.firstWhere((t) => t.id == g);
      expect(out.project.tracks.map((t) => t.id), p.tracks.map((t) => t.id));
      expect(lane.subtitle!.provenance!.modelId, 'whisper-small-q5_1');
      expect(lane.subtitle!.language, 'en');
      expect(lane.items.cast<SubtitleCue>().single.text, 'New');
      expect(out.changedTracks, {g});
      expect(out.createdTracks, isEmpty);
      expect(out.affected, containsAll([for (final i in ['g1', 'g2', 'g3', 'g4']) ItemId(i)]));
    });

    test('new cues are fresh, generated and unedited', () {
      final out = applyCommand(generated(), replace(g, [draft(0, 40, 'a'), draft(50, 100, 'b')]), ctx());
      final cues = cuesOf(out.project, 'tr_g');
      for (final c in cues) {
        expect(c.origin, CueOrigin.generated);
        expect(c.editedAfterGeneration, isFalse);
        expect(['g1', 'g2', 'g3', 'g4'].contains(c.id.value), isFalse);
      }
    });

    test('replace in range: the boundaries (touching is not overlapping)', () {
      // Cues: g1 [0,30) g2 [40,70) g3 [80,110) g4 [120,150).
      List<String> keptBy(TimeRange r) {
        final out = applyCommand(generated(), replace(g, [draft(900, 910, 'x')], range: r), ctx());
        return [for (final c in cuesOf(out.project, 'tr_g')) if (c.text != 'x') c.text];
      }

      expect(keptBy(TimeRange(f(30), f(40))), ['one', 'two', 'three', 'four'], reason: 'the gap between g1 and g2');
      expect(keptBy(TimeRange(f(70), f(80))), ['one', 'two', 'three', 'four'], reason: 'the gap between g2 and g3');
      expect(keptBy(TimeRange(f(29), f(41))), ['three', 'four'], reason: 'overlaps both ends');
      expect(keptBy(TimeRange(f(69), f(70))), ['one', 'three', 'four'], reason: 'one frame inside g2');
      expect(keptBy(TimeRange(f(0), f(1))), ['two', 'three', 'four']);
      expect(keptBy(TimeRange(f(149), f(1000))), ['one', 'two', 'three']);
      expect(keptBy(TimeRange(f(150), f(1000))), ['one', 'two', 'three', 'four'], reason: 'starts at the end of g4');
      expect(keptBy(TimeRange(f(0), f(1000))), isEmpty);
    });

    test('replaced cues that were edited are gone; kept cues keep their flags and ids', () {
      final out = applyCommand(generated(), replace(g, [draft(85, 100, 'new')], range: TimeRange(f(80), f(110))), ctx());
      final cues = cuesOf(out.project, 'tr_g');
      expect(cues.map((c) => c.text), ['one', 'two', 'new', 'four']);
      expect(cues[1].editedAfterGeneration, isTrue);
      expect(cues[1].id, const ItemId('g2'));
    });

    test('is one entry that touches only its lane', () {
      final p = generated();
      final out = applyCommand(p, replace(g, [draft(0, 10, 'a')], range: TimeRange(f(0), f(50))), ctx());
      expect(out.changedTracks, {g});
      expect(identical(out.project.tracks.firstWhere((t) => t.id == const TrackId('tr_m')), p.tracks.firstWhere((t) => t.id == const TrackId('tr_m'))), isTrue);
    });

    test('a locked lane is refused as data and nothing changes', () {
      final p = generated();
      final locked = p.copyWith(timeline: p.timeline.copyWith(tracks: [for (final t in p.tracks) t.id == g ? t.copyWith(locked: true) : t]));
      final out = applyCommand(locked, replace(g, [draft(0, 10, 'a')]), ctx());
      expect(out.rejection, const TrackLocked(g));
      expect(identical(out.project, locked), isTrue);
      expect(dryRun(locked, replace(g, [draft(0, 10, 'a')]), ctx()).rejection, const TrackLocked(g));
    });

    test('the language comes from the provenance only when the lane has none', () {
      final noLang = generated().copyWith(
        timeline: generated().timeline.copyWith(tracks: [
          for (final t in generated().tracks)
            t.id == g ? t.copyWith(subtitle: t.subtitle!.copyWith(language: null)) : t,
        ]),
      );
      final out = applyCommand(noLang, replace(g, [draft(0, 10, 'a')], prov: provenance(language: 'de')), ctx());
      expect(out.project.tracks.firstWhere((t) => t.id == g).subtitle!.language, 'de');
      final out2 = applyCommand(generated(), replace(g, [draft(0, 10, 'a')], prov: provenance(language: 'de')), ctx());
      expect(out2.project.tracks.firstWhere((t) => t.id == g).subtitle!.language, 'en');
    });
  });
}
