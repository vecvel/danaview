// OWNER: CORE-14
//
// Tests of AddText, SetText, SetTextStyle and SetTextAnimation (BUILD_PLAN CORE-14): lane
// selection, style range validation, animation duration clamping and the command-level coalescing
// hook (the session behaviour is verified in CORE-19's tests).

import 'package:test/test.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../framework/ops_support.dart';

ItemId id(String s) => ItemId(s);

TextItem textAt(EditProject p, String it) => p.index.locate(ItemId(it))!.item as TextItem;

EditOutcome ok(EditProject p, EditCommand c, {EditPolicy policy = const EditPolicy(), int seed = 7}) {
  final out = applyCommand(p, c, ctx(policy: policy, seed: seed));
  expect(out.rejection, isNull, reason: 'unexpected rejection ${out.rejection} for $c');
  expectValid(out.project, c.toString());
  return out;
}

EditRejection? reject(EditProject p, EditCommand c, {EditPolicy policy = const EditPolicy()}) {
  final out = applyCommand(p, c, ctx(policy: policy));
  expect(identical(out.project, p), isTrue, reason: 'a rejection must leave the project unchanged');
  expect(dryRun(p, c, ctx(policy: policy)).rejection, out.rejection, reason: 'dry run agrees');
  return out.rejection;
}

/// The lane of item [it].
Track laneOf(EditProject p, String it) => p.index.locate(ItemId(it))!.track;

/// Text lanes of [p] from bottom to top.
List<Track> textLanes(EditProject p) => [
      for (final t in p.tracks)
        if (t.kind == TrackKind.text) t
    ];

/// A project with text lanes `tr_t1` (bottom), `tr_t2` (top) holding the given spans (frames).
EditProject lanes(
        {List<(int, int)> bottom = const [],
        List<(int, int)> top = const [],
        bool lockTop = false,
        bool lockBottom = false}) =>
    project([
      lane('tr_main', TrackKind.video, [vclip('it_v', 0, 600)], main: true),
      lane('tr_t1', TrackKind.text, [for (final (i, s) in bottom.indexed) text('it_b$i', s.$1, s.$2)],
          locked: lockBottom),
      lane('tr_t2', TrackKind.text, [for (final (i, s) in top.indexed) text('it_u$i', s.$1, s.$2)], locked: lockTop),
      lane('tr_sub', TrackKind.subtitle, [cue('it_s1', 0, 30)]),
      lane('tr_music', TrackKind.audio, [aclip('it_m', 0, 300)], role: AudioRole.music),
    ]);

void main() {
  group('AddText', () {
    test('defaults: Figtree 48 pt white centred, 3 s, at the time, selected', () {
      final p = lanes();
      final cmd = AddText(f(30));
      final out = ok(p, cmd);
      final added = out.affected.single;
      final t = textAt(out.project, added);
      expect(t.start, f(30));
      expect(t.duration, 3 * microsPerSecond);
      expect(t.end, f(120));
      expect(t.text, AddText.placeholder);
      expect(t.style, const TextStyleSpec());
      expect(t.style.fontFamily, 'figtree');
      expect(t.style.fontSizePt, 48);
      expect(t.style.color, 0xFFFFFFFF);
      expect(t.style.align, TextAlignH.center);
      expect(t.animation, TextAnimation.none);
      expect(t.transform, Transform2D.identity);
      expect(out.selection!.primary, added);
      expect(out.selection!.items, {added});
      expect(out.selection!.lane, laneOf(out.project, added.value).id);
    });

    test('the default length follows the policy', () {
      final out = ok(lanes(), AddText(0), policy: const EditPolicy(defaultTextUs: 5 * microsPerSecond));
      expect(textAt(out.project, out.affected.single).duration, 5 * microsPerSecond);
    });

    test('text, duration and style are used; the time and length are put on the grid', () {
      final style = const TextStyleSpec(fontSizePt: 72, bold: true, color: 0xFFFF0000);
      final out = ok(lanes(), AddText(f(10) + 9000, text: 'Hello\r\nworld', duration: 1000000 + 7000, style: style));
      final t = textAt(out.project, out.affected.single);
      expect(t.start, f(10), reason: 'nearest frame');
      expect(t.duration, f(10 + 30) - f(10));
      expect(t.text, 'Hello\nworld');
      expect(t.style, style);
    });

    test('negative times start at 0 and short durations last one frame', () {
      final out = ok(lanes(), AddText(-5000, duration: 1));
      final t = textAt(out.project, out.affected.single);
      expect(t.start, 0);
      expect(t.duration, f(1));
    });

    group('lane selection', () {
      test('no text lane: one is created in the text band (above the video, below the subtitles)', () {
        final p = project([
          lane('tr_main', TrackKind.video, [vclip('it_v', 0, 300)], main: true),
          lane('tr_sub', TrackKind.subtitle, [cue('it_s1', 0, 30)]),
          lane('tr_music', TrackKind.audio, [aclip('it_m', 0, 300)], role: AudioRole.music),
        ]);
        final cmd = AddText(0);
        final out = ok(p, cmd);
        expect(out.createdTracks, hasLength(1));
        expect([for (final t in out.project.tracks) t.kind],
            [TrackKind.video, TrackKind.text, TrackKind.subtitle, TrackKind.audio]);
        final prev = dryRun(p, cmd, ctx());
        expect(prev.createsTracks.single.kind, TrackKind.text);
        expect(prev.placements.values.single.newTrack, isNotNull);
      });

      test('the topmost free lane wins when several are free', () {
        final out = ok(lanes(), AddText(f(10)));
        expect(laneOf(out.project, out.affected.single.value).id, const TrackId('tr_t2'));
      });

      test('an occupied top lane falls back to the free lane below it', () {
        final out = ok(lanes(top: [(0, 100)]), AddText(f(10)));
        expect(laneOf(out.project, out.affected.single.value).id, const TrackId('tr_t1'));
        expect(out.createdTracks, isEmpty);
      });

      test('a text that does not overlap anything stays on the top lane even when the lower one is emptier', () {
        final out = ok(lanes(top: [(0, 30)], bottom: [(0, 300)]), AddText(f(60)));
        expect(laneOf(out.project, out.affected.single.value).id, const TrackId('tr_t2'));
      });

      test('when every lane is occupied a new lane is created on top of the text group', () {
        final p = lanes(top: [(0, 100)], bottom: [(0, 100)]);
        final out = ok(p, AddText(f(10)));
        final created = out.createdTracks.single;
        expect(laneOf(out.project, out.affected.single.value).id, created);
        final text = textLanes(out.project);
        expect(text.map((t) => t.id).toList(), [const TrackId('tr_t1'), const TrackId('tr_t2'), created]);
        expect(out.project.tracks.indexWhere((t) => t.id == created),
            lessThan(out.project.tracks.indexWhere((t) => t.kind == TrackKind.subtitle)));
      });

      test('overlap with the end of a lane item counts: touching is free, one frame of overlap is not', () {
        final touch = ok(lanes(top: [(0, 30)]), AddText(f(30)));
        expect(laneOf(touch.project, touch.affected.single.value).id, const TrackId('tr_t2'));
        final over = ok(lanes(top: [(0, 31)], bottom: [(0, 31)]), AddText(f(30), duration: sec(1)));
        expect(over.createdTracks, hasLength(1));
      });

      test('locked lanes are skipped', () {
        final a = ok(lanes(lockTop: true), AddText(f(10)));
        expect(laneOf(a.project, a.affected.single.value).id, const TrackId('tr_t1'));
        final b = ok(lanes(lockTop: true, lockBottom: true), AddText(f(10)));
        expect(b.createdTracks, hasLength(1), reason: 'a new lane when every lane is locked');
      });

      test('policy reject: an occupied text group refuses, no lanes at all still creates one', () {
        const strict = EditPolicy(overlap: OverlapPolicy.reject);
        expect(reject(lanes(top: [(0, 100)], bottom: [(0, 100)]), AddText(f(10)), policy: strict), const NoRoom());
        final free = ok(lanes(top: [(0, 100)]), AddText(f(10)), policy: strict);
        expect(laneOf(free.project, free.affected.single.value).id, const TrackId('tr_t1'));
        final none = project([
          lane('tr_main', TrackKind.video, [vclip('it_v', 0, 300)], main: true)
        ]);
        expect(ok(none, AddText(0), policy: strict).createdTracks, hasLength(1));
      });

      test('an explicit free lane is used', () {
        final out = ok(lanes(), AddText(f(10), track: const TrackId('tr_t1')));
        expect(laneOf(out.project, out.affected.single.value).id, const TrackId('tr_t1'));
        expect(out.notices, isEmpty);
      });

      test('an explicit occupied lane falls back to the nearest free text lane with a notice (D-11)', () {
        final out = ok(lanes(bottom: [(0, 100)]), AddText(f(10), track: const TrackId('tr_t1')));
        expect(laneOf(out.project, out.affected.single.value).id, const TrackId('tr_t2'));
        expect(out.notices.single.code, EditNoticeCodes.placedOnOtherLane);
      });

      test('explicit lane rejections', () {
        final p = lanes(bottom: [(0, 100)], lockTop: true);
        expect(reject(p, AddText(f(10), track: const TrackId('tr_t2'))), const TrackLocked(TrackId('tr_t2')));
        expect(reject(p, AddText(f(10), track: const TrackId('tr_main'))), const IncompatibleTrack(TrackId('tr_main')));
        expect(reject(p, AddText(f(10), track: const TrackId('tr_sub'))), const IncompatibleTrack(TrackId('tr_sub')));
        expect(reject(p, AddText(f(10), track: const TrackId('tr_nope'))), const ItemNotFound('tr_nope'));
        expect(
            reject(p, AddText(f(10), track: const TrackId('tr_t1')),
                policy: const EditPolicy(overlap: OverlapPolicy.reject)),
            isA<WouldOverlap>());
      });
    });

    test('rejections: empty text, durations, style values', () {
      final p = lanes();
      expect(reject(p, AddText(0, text: '')), const EmptyText());
      expect(reject(p, AddText(0, text: ' \n\t ')), const EmptyText());
      expect(reject(p, AddText(0, duration: 0)), const InvalidValue('duration'));
      expect(reject(p, AddText(0, duration: -1)), const InvalidValue('duration'));
      expect(reject(p, AddText(0, style: const TextStyleSpec(fontSizePt: 7))), const InvalidValue('text.fontSize'));
      expect(reject(p, AddText(0, style: const TextStyleSpec(lineHeight: 4))), const InvalidValue('text.lineHeight'));
      expect(reject(p, AddText(0, style: const TextStyleSpec(fontFamily: ''))), const InvalidValue('text.fontFamily'));
      expect(reject(p, AddText(0, style: const TextStyleSpec(color: -1))), const InvalidValue('text.color'));
    });

    test('ids are minted by the context: equal seeds, equal results', () {
      final a = applyCommand(lanes(), AddText(f(5)), ctx());
      final b = applyCommand(lanes(), AddText(f(5)), ctx());
      expect(a.project.timeline, b.project.timeline);
      final c = applyCommand(lanes(), AddText(f(5)), ctx(seed: 99));
      expect(c.affected.single, isNot(a.affected.single));
    });

    test('adding text is subject to the item limit', () {
      final out = applyCommand(lanes(), AddText(0), ctx(policy: const EditPolicy(maxItems: 3)));
      expect(out.rejection, const LimitExceeded(LimitExceeded.items, 3));
    });
  });

  group('SetText', () {
    final p = standard();

    test('sets the text, keeps the rest', () {
      final out = ok(p, SetText(id('it_t1'), 'New title'));
      final t = textAt(out.project, 'it_t1');
      expect(t.text, 'New title');
      expect(t, textAt(p, 'it_t1').copyWith(text: 'New title'));
      expect(out.affected, {id('it_t1')});
      expect(out.changedTracks, {const TrackId('tr_txt')});
    });

    test('the text is stored as typed: spaces, emoji, line breaks; CRLF becomes LF', () {
      final out = ok(p, SetText(id('it_t1'), '  Hé 👩‍👩‍👧 世界 \r\nline 2\n'));
      expect(textAt(out.project, 'it_t1').text, '  Hé 👩‍👩‍👧 世界 \nline 2\n');
    });

    test('whitespace-only and empty texts are EmptyText', () {
      for (final bad in ['', ' ', '\n', ' \t\r\n ', ' '.trim().isEmpty ? ' ' : '   ']) {
        expect(reject(p, SetText(id('it_t1'), bad)), const EmptyText(), reason: '"$bad"');
      }
    });

    test('the same text is a no-op', () {
      expect(applyCommand(p, SetText(id('it_t1'), 'Title'), ctx()).noop, isTrue);
    });

    test('kind and lock rejections', () {
      expect(reject(p, SetText(id('it_a'), 'x')), const UnsupportedForKind('media'));
      expect(reject(p, SetText(id('it_p1'), 'x')), const UnsupportedForKind('media'));
      expect(reject(p, SetText(id('it_s1'), 'x')), const UnsupportedForKind('subtitle'));
      expect(reject(p, SetText(id('it_nope'), 'x')), const ItemNotFound('it_nope'));
      final locked = project([
        lane('tr_txt', TrackKind.text, [text('it_t', 0, 30)], locked: true)
      ]);
      expect(reject(locked, SetText(id('it_t'), 'x')), const TrackLocked(TrackId('tr_txt')));
    });

    test('coalescing hook: the key is text:<item id> and the command is a CoalescingCommand', () {
      final c = SetText(id('it_t1'), 'a');
      expect(c, isA<CoalescingCommand>());
      expect(c.coalesceKey, 'text:it_t1');
      expect(SetText(id('it_t1'), 'abc').coalesceKey, c.coalesceKey, reason: 'typing in one text merges');
      expect(SetText(id('it_t2'), 'a').coalesceKey, isNot(c.coalesceKey));
      expect(SetTextStyle([id('it_t1')], bold: true), isNot(isA<CoalescingCommand>()));
      // Applying the commands one after the other is what the session merges: the end state is the last text.
      var q = p;
      for (final s in ['T', 'Ti', 'Tit', 'Titl', 'Title!']) {
        q = ok(q, SetText(id('it_t1'), s)).project;
      }
      expect(textAt(q, 'it_t1').text, 'Title!');
    });
  });

  group('SetTextStyle', () {
    final p = standard();

    test('each field changes only itself', () {
      final base = textAt(p, 'it_t1').style;
      final cases = <(SetTextStyle, TextStyleSpec)>[
        (SetTextStyle([id('it_t1')], fontFamily: 'inter'), base.copyWith(fontFamily: 'inter')),
        (SetTextStyle([id('it_t1')], fontSizePt: 96), base.copyWith(fontSizePt: 96)),
        (SetTextStyle([id('it_t1')], bold: true), base.copyWith(bold: true)),
        (SetTextStyle([id('it_t1')], italic: true), base.copyWith(italic: true)),
        (SetTextStyle([id('it_t1')], align: TextAlignH.right), base.copyWith(align: TextAlignH.right)),
        (SetTextStyle([id('it_t1')], color: 0xFF112233), base.copyWith(color: 0xFF112233)),
        (SetTextStyle([id('it_t1')], letterSpacing: 12), base.copyWith(letterSpacing: 12)),
        (SetTextStyle([id('it_t1')], lineHeight: 2), base.copyWith(lineHeight: 2)),
        (SetTextStyle([id('it_t1')], maxWidth: 0.5), base.copyWith(maxWidth: 0.5)),
        (
          SetTextStyle([id('it_t1')], background: const BoxStyle(color: 0xFF0000FF, opacity: 0.3)),
          base.copyWith(background: const BoxStyle(color: 0xFF0000FF, opacity: 0.3))
        ),
        (
          SetTextStyle([id('it_t1')], stroke: const StrokeStyle(widthPt: 5)),
          base.copyWith(stroke: const StrokeStyle(widthPt: 5))
        ),
        (
          SetTextStyle([id('it_t1')], shadow: const ShadowStyle(blurPt: 10)),
          base.copyWith(shadow: const ShadowStyle(blurPt: 10))
        ),
      ];
      for (final (cmd, expected) in cases) {
        final out = ok(p, cmd);
        expect(textAt(out.project, 'it_t1').style, expected, reason: '$cmd');
        expect(textAt(out.project, 'it_t1').text, 'Title');
        expect(textAt(out.project, 'it_t1').animation, TextAnimation.none);
      }
    });

    test('several fields at once; several items as one outcome', () {
      final q = ok(p, AddText(f(100), text: 'Second')).project;
      final ids = [
        id('it_t1'),
        ...textLanes(q).expand((t) => t.items).where((i) => i.id != id('it_t1')).map((i) => i.id)
      ];
      final out = ok(q, SetTextStyle(ids, bold: true, fontSizePt: 80, color: 0xFFFF00FF));
      expect(out.affected, ids.toSet());
      for (final i in ids) {
        final s = textAt(out.project, i.value).style;
        expect([s.bold, s.fontSizePt, s.color], [true, 80.0, 0xFFFF00FF]);
      }
    });

    test('boundaries of every range are accepted', () {
      for (final cmd in [
        SetTextStyle([id('it_t1')], fontSizePt: 8),
        SetTextStyle([id('it_t1')], fontSizePt: 200),
        SetTextStyle([id('it_t1')], letterSpacing: -20),
        SetTextStyle([id('it_t1')], letterSpacing: 100),
        SetTextStyle([id('it_t1')], lineHeight: 0.6),
        SetTextStyle([id('it_t1')], lineHeight: 3),
        SetTextStyle([id('it_t1')], maxWidth: 0.1),
        SetTextStyle([id('it_t1')], maxWidth: 1),
        SetTextStyle([id('it_t1')], stroke: const StrokeStyle(widthPt: 0)),
        SetTextStyle([id('it_t1')], stroke: const StrokeStyle(widthPt: 20)),
        SetTextStyle([id('it_t1')], shadow: const ShadowStyle(blurPt: 40, distancePt: 40, opacity: 1)),
        SetTextStyle([id('it_t1')], shadow: const ShadowStyle(blurPt: 0, distancePt: 0, opacity: 0)),
        SetTextStyle([id('it_t1')], background: const BoxStyle(opacity: 0, paddingPt: 0, cornerRadiusPt: 0)),
        SetTextStyle([id('it_t1')], color: 0),
        SetTextStyle([id('it_t1')], color: 0xFFFFFFFF),
      ]) {
        ok(p, cmd);
      }
    });

    test('values outside the ranges are InvalidValue naming the property', () {
      final bad = <(SetTextStyle, String)>[
        (SetTextStyle([id('it_t1')], fontSizePt: 7.99), 'text.fontSize'),
        (SetTextStyle([id('it_t1')], fontSizePt: 200.01), 'text.fontSize'),
        (SetTextStyle([id('it_t1')], fontSizePt: double.nan), 'text.fontSize'),
        (SetTextStyle([id('it_t1')], fontSizePt: double.infinity), 'text.fontSize'),
        (SetTextStyle([id('it_t1')], letterSpacing: -20.01), 'text.letterSpacing'),
        (SetTextStyle([id('it_t1')], letterSpacing: 100.01), 'text.letterSpacing'),
        (SetTextStyle([id('it_t1')], lineHeight: 0.59), 'text.lineHeight'),
        (SetTextStyle([id('it_t1')], lineHeight: 3.01), 'text.lineHeight'),
        (SetTextStyle([id('it_t1')], maxWidth: 0.05), 'text.maxWidth'),
        (SetTextStyle([id('it_t1')], maxWidth: 1.5), 'text.maxWidth'),
        (SetTextStyle([id('it_t1')], stroke: const StrokeStyle(widthPt: 20.5)), 'text.stroke.width'),
        (SetTextStyle([id('it_t1')], stroke: const StrokeStyle(widthPt: -1)), 'text.stroke.width'),
        (SetTextStyle([id('it_t1')], shadow: const ShadowStyle(blurPt: 41)), 'text.shadow.blur'),
        (SetTextStyle([id('it_t1')], shadow: const ShadowStyle(distancePt: -1)), 'text.shadow.distance'),
        (SetTextStyle([id('it_t1')], shadow: const ShadowStyle(opacity: 1.5)), 'text.shadow.opacity'),
        (SetTextStyle([id('it_t1')], background: const BoxStyle(opacity: 1.5)), 'text.background.opacity'),
        (SetTextStyle([id('it_t1')], background: const BoxStyle(paddingPt: -1)), 'text.background.padding'),
        (SetTextStyle([id('it_t1')], fontFamily: ''), 'text.fontFamily'),
        (SetTextStyle([id('it_t1')], color: -1), 'text.color'),
        (SetTextStyle([id('it_t1')], color: 0x100000000), 'text.color'),
        (SetTextStyle([id('it_t1')], background: const BoxStyle(color: -5)), 'text.background.color'),
        (SetTextStyle([id('it_t1')], stroke: const StrokeStyle(color: 0x100000000)), 'text.stroke.color'),
        (SetTextStyle([id('it_t1')], shadow: const ShadowStyle(color: -1)), 'text.shadow.color'),
      ];
      for (final (cmd, property) in bad) {
        expect(reject(p, cmd), InvalidValue(property), reason: '$cmd');
      }
    });

    test('box, stroke and shadow are set and removed', () {
      var q = ok(
              p,
              SetTextStyle([id('it_t1')],
                  background: const BoxStyle(), stroke: const StrokeStyle(), shadow: const ShadowStyle()))
          .project;
      expect(textAt(q, 'it_t1').style.background, const BoxStyle());
      expect(textAt(q, 'it_t1').style.stroke, const StrokeStyle());
      expect(textAt(q, 'it_t1').style.shadow, const ShadowStyle());
      q = ok(q, SetTextStyle([id('it_t1')], removeStroke: true)).project;
      expect(textAt(q, 'it_t1').style.stroke, isNull);
      expect(textAt(q, 'it_t1').style.background, const BoxStyle());
      q = ok(q, SetTextStyle([id('it_t1')], removeBackground: true, removeShadow: true)).project;
      expect(textAt(q, 'it_t1').style, textAt(p, 'it_t1').style);
    });

    test('replace copies a whole style to several items', () {
      final q = ok(p, AddText(f(100), text: 'Second')).project;
      final other = textLanes(q).expand((t) => t.items).firstWhere((i) => i.id != id('it_t1')).id;
      const style = TextStyleSpec(fontSizePt: 90, italic: true, background: BoxStyle(), shadow: ShadowStyle());
      final out = ok(q, SetTextStyle.replace([id('it_t1'), other], style));
      expect(textAt(out.project, 'it_t1').style, style);
      expect(textAt(out.project, other.value).style, style);
      final back = ok(out.project, SetTextStyle.replace([id('it_t1')], const TextStyleSpec()));
      expect(textAt(back.project, 'it_t1').style, const TextStyleSpec());
      expect(reject(p, SetTextStyle.replace([id('it_t1')], const TextStyleSpec(fontSizePt: 5))),
          const InvalidValue('text.fontSize'));
    });

    test('kind, lock and item rejections; one bad item rejects the batch', () {
      expect(reject(p, SetTextStyle([id('it_a')], bold: true)), const UnsupportedForKind('media'));
      expect(reject(p, SetTextStyle([id('it_s1')], bold: true)), const UnsupportedForKind('subtitle'));
      expect(reject(p, SetTextStyle([id('it_nope')], bold: true)), const ItemNotFound('it_nope'));
      expect(reject(p, SetTextStyle(const <ItemId>[], bold: true)), const InvalidValue('items'));
      expect(reject(p, SetTextStyle([id('it_t1'), id('it_a')], bold: true)), const UnsupportedForKind('media'));
      final locked = project([
        lane('tr_txt', TrackKind.text, [text('it_t', 0, 30)], locked: true)
      ]);
      expect(reject(locked, SetTextStyle([id('it_t')], bold: true)), const TrackLocked(TrackId('tr_txt')));
    });

    test('the same style is a no-op', () {
      expect(applyCommand(p, SetTextStyle([id('it_t1')], bold: false, fontSizePt: 48), ctx()).noop, isTrue);
    });
  });

  group('SetTextAnimation', () {
    EditProject one(int frames) => project([
          lane('tr_main', TrackKind.video, [vclip('it_v', 0, 300)], main: true),
          lane('tr_txt', TrackKind.text, [text('it_t', 0, frames), text('it_u', 100, 90)]),
        ]);

    TextAnimation anim({
      TextAnimKind inKind = TextAnimKind.none,
      int inFrames = 0,
      TextAnimKind outKind = TextAnimKind.none,
      int outFrames = 0,
      TextSlideDirection inDir = TextSlideDirection.up,
      TextSlideDirection outDir = TextSlideDirection.down,
    }) =>
        TextAnimation(
            inKind: inKind,
            inDirection: inDir,
            inDuration: f(inFrames),
            outKind: outKind,
            outDirection: outDir,
            outDuration: f(outFrames));

    test('sets kinds, directions and lengths when they fit', () {
      final p = one(60);
      final a = anim(
          inKind: TextAnimKind.slide,
          inFrames: 15,
          outKind: TextAnimKind.scale,
          outFrames: 10,
          inDir: TextSlideDirection.left,
          outDir: TextSlideDirection.right);
      final out = ok(p, SetTextAnimation([id('it_t')], a));
      final t = textAt(out.project, 'it_t');
      expect(t.animation.inKind, TextAnimKind.slide);
      expect(t.animation.inDirection, TextSlideDirection.left);
      expect(rate.frameIndexNearest(t.animation.inDuration), 15);
      expect(t.animation.outKind, TextAnimKind.scale);
      expect(t.animation.outDirection, TextSlideDirection.right);
      expect(rate.frameIndexNearest(t.animation.outDuration), 10);
    });

    test('every in kind is accepted; typewriter only as an in animation', () {
      final p = one(60);
      for (final k in TextAnimKind.values) {
        ok(p, SetTextAnimation([id('it_t')], anim(inKind: k, inFrames: 10)));
        if (k != TextAnimKind.typewriter) ok(p, SetTextAnimation([id('it_t')], anim(outKind: k, outFrames: 10)));
      }
      expect(reject(p, SetTextAnimation([id('it_t')], anim(outKind: TextAnimKind.typewriter, outFrames: 10))),
          const InvalidValue('outKind'));
    });

    test('in + out never exceed the duration: the in animation keeps its length first', () {
      final p = one(30);
      var out = ok(
          p,
          SetTextAnimation(
              [id('it_t')], anim(inKind: TextAnimKind.fade, inFrames: 20, outKind: TextAnimKind.fade, outFrames: 20)));
      var t = textAt(out.project, 'it_t');
      expect(
          [rate.frameIndexNearest(t.animation.inDuration), rate.frameIndexNearest(t.animation.outDuration)], [20, 10]);
      out = ok(
          p,
          SetTextAnimation(
              [id('it_t')], anim(inKind: TextAnimKind.fade, inFrames: 45, outKind: TextAnimKind.fade, outFrames: 5)));
      t = textAt(out.project, 'it_t');
      expect(
          [rate.frameIndexNearest(t.animation.inDuration), rate.frameIndexNearest(t.animation.outDuration)], [30, 0]);
      out = ok(p, SetTextAnimation([id('it_t')], anim(outKind: TextAnimKind.scale, outFrames: 99)));
      t = textAt(out.project, 'it_t');
      expect(
          [rate.frameIndexNearest(t.animation.inDuration), rate.frameIndexNearest(t.animation.outDuration)], [0, 30]);
    });

    test('each item is fitted to its own duration', () {
      final p = one(30); // it_t 30 frames, it_u 90 frames
      final out = ok(
          p,
          SetTextAnimation([id('it_t'), id('it_u')],
              anim(inKind: TextAnimKind.fade, inFrames: 20, outKind: TextAnimKind.fade, outFrames: 20)));
      final t = textAt(out.project, 'it_t');
      final u = textAt(out.project, 'it_u');
      expect(
          [rate.frameIndexNearest(t.animation.inDuration), rate.frameIndexNearest(t.animation.outDuration)], [20, 10]);
      expect(
          [rate.frameIndexNearest(u.animation.inDuration), rate.frameIndexNearest(u.animation.outDuration)], [20, 20]);
      expect(out.affected, {id('it_t'), id('it_u')});
    });

    test('lengths are on the grid; both fit in one frame at the extreme', () {
      final p = one(1);
      final out = ok(
          p,
          SetTextAnimation(
              [id('it_t')],
              TextAnimation(
                  inKind: TextAnimKind.fade, inDuration: 17000, outKind: TextAnimKind.fade, outDuration: 90000)));
      final t = textAt(out.project, 'it_t');
      expect(t.animation.inDuration + t.animation.outDuration, lessThanOrEqualTo(t.duration));
      final q = ok(
          one(60),
          SetTextAnimation(
              [id('it_t')],
              TextAnimation(
                  inKind: TextAnimKind.fade,
                  inDuration: 500000 + 3000,
                  outKind: TextAnimKind.scale,
                  outDuration: 300000 - 2000)));
      final tt = textAt(q.project, 'it_t');
      expect(tt.animation.inDuration, f(15));
      expect(tt.end - tt.animation.outDuration, f(60 - 9));
    });

    test('a none kind has no length', () {
      final out = ok(
          one(60),
          SetTextAnimation(
              [id('it_t')],
              TextAnimation(
                  inKind: TextAnimKind.none, inDuration: f(10), outKind: TextAnimKind.fade, outDuration: f(10))));
      final t = textAt(out.project, 'it_t');
      expect(t.animation.inDuration, 0);
      expect(rate.frameIndexNearest(t.animation.outDuration), 10);
    });

    test('removing animations and no-ops', () {
      final p = ok(one(60), SetTextAnimation([id('it_t')], anim(inKind: TextAnimKind.fade, inFrames: 10))).project;
      final cleared = ok(p, SetTextAnimation([id('it_t')], TextAnimation.none));
      expect(textAt(cleared.project, 'it_t').animation, TextAnimation.none);
      expect(applyCommand(one(60), SetTextAnimation([id('it_t')], TextAnimation.none), ctx()).noop, isTrue);
    });

    test('rejections', () {
      final p = standard();
      expect(reject(p, SetTextAnimation([id('it_t1')], TextAnimation(inKind: TextAnimKind.fade, inDuration: -1))),
          const InvalidValue('inDuration'));
      expect(reject(p, SetTextAnimation([id('it_t1')], TextAnimation(outKind: TextAnimKind.fade, outDuration: -1))),
          const InvalidValue('outDuration'));
      expect(reject(p, SetTextAnimation([id('it_a')], TextAnimation.none)), const UnsupportedForKind('media'));
      expect(reject(p, SetTextAnimation([id('it_s1')], TextAnimation.none)), const UnsupportedForKind('subtitle'));
      expect(reject(p, SetTextAnimation([id('it_nope')], TextAnimation.none)), const ItemNotFound('it_nope'));
      expect(reject(p, SetTextAnimation(const <ItemId>[], TextAnimation.none)), const InvalidValue('items'));
      final locked = project([
        lane('tr_txt', TrackKind.text, [text('it_t', 0, 30)], locked: true)
      ]);
      expect(reject(locked, SetTextAnimation([id('it_t')], TextAnimation.none)), const TrackLocked(TrackId('tr_txt')));
    });

    test('the evaluated animation reaches its extremes at the clamped lengths', () {
      final out = ok(
          one(30),
          SetTextAnimation(
              [id('it_t')], anim(inKind: TextAnimKind.fade, inFrames: 20, outKind: TextAnimKind.fade, outFrames: 20)));
      final t = textAt(out.project, 'it_t');
      final canvas = out.project.settings.canvas;
      expect(evaluateTextAnimation(t, 0, canvas).opacity, 0);
      expect(evaluateTextAnimation(t, f(20), canvas).opacity, 1);
      expect(evaluateTextAnimation(t, f(30) - 1, canvas).opacity, lessThan(0.05));
    });
  });

  group('text edits and the rest of the model', () {
    test('a split keeps the style and text; SetProperty edits the transform of a text (CORE-13)', () {
      final p = standard();
      final styled = ok(p, SetTextStyle([id('it_t1')], bold: true, fontSizePt: 90)).project;
      final split = ok(styled, SplitItems({id('it_t1')}, f(20)));
      final halves = textLanes(split.project).expand((t) => t.items).whereType<TextItem>().toList();
      expect(halves, hasLength(2));
      for (final h in halves) {
        expect(h.style.bold, isTrue);
        expect(h.style.fontSizePt, 90);
      }
      final moved = ok(styled, SetProperty([id('it_t1')], PropertyKeys.position, const Vec2(0.1, 0.2)));
      expect(textAt(moved.project, 'it_t1').transform.position, const Vec2(0.1, 0.2));
    });

    test('random style and animation edits keep every invariant', () {
      var p = standard();
      final rnd = [0.5, 8.0, 200.0, 9999.0, -3.0];
      var applied = 0;
      for (var n = 0; n < 200; n++) {
        final size = rnd[n % rnd.length];
        final c = n.isEven
            ? SetTextStyle([id('it_t1')], fontSizePt: size, letterSpacing: size / 10, lineHeight: size / 100)
            : SetTextAnimation(
                [id('it_t1')],
                TextAnimation(
                    inKind: TextAnimKind.fade,
                    inDuration: (size * 1e4).round(),
                    outKind: TextAnimKind.scale,
                    outDuration: (size * 7e3).round().abs()));
        final out = applyCommand(p, c, ctx(seed: 500 + n));
        if (out.rejection == null) {
          applied++;
          p = out.project;
          expectValid(p, '$c');
        } else {
          expect(out.rejection, isNot(isA<InternalInconsistency>()), reason: '$c -> ${out.rejection}');
        }
      }
      expect(applied, greaterThan(40));
    });
  });
}
