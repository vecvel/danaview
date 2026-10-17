// OWNER: CORE-11
//
// Acceptance tests of BUILD_PLAN CORE-11 besides the goldens:
// * a cross-project paste mints fresh ids and imports pool entries exactly once;
// * replace with shorter media clamps and emits `EditNotice(trimmedToFit)`;
// * extracted audio stays in sync with its video at every frame (one shared map), for constant
//   speeds, ramps and reversed clips;
// * `SelectionRules.expand` table test, and the other selection helpers;
// * the clipboard payload is self-contained (items, lanes, offsets, transitions, media closure).

import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';
import 'clipboard_fixtures.dart';

void main() {
  group('copyItems', () {
    test('is self-contained: lanes, offsets, transitions and the media closure', () {
      final payload = otherPayload();
      expect(payload.source, const ProjectId('pr_other'));
      expect(payload.schema, ClipboardPayload.currentSchema);
      expect(payload.itemIds, ids(['it_o1', 'it_o2', 'it_o3', 'it_o4', 'it_o1_au']), reason: 'link partner included');
      expect(payload.lanes.map((l) => (l.kind, l.role)), [(TrackKind.video, null), (TrackKind.audio, AudioRole.original)]);
      expect(payload.anchor, 0);
      expect([for (final i in payload.items) i.offset], [0, f(48), f(72), f(96), 0]);
      expect(payload.transitions.single.transition.id, const TransitionId('tx_o'));
      // md_rev is the reversed rendition the reversed clip it_o4 plays.
      expect(payload.media.keys.toSet(), {const MediaId('md_other'), const MediaId('md_dupe'), const MediaId('md_video'), const MediaId('md_rev')});
      expect(payload.extent, f(120));
    });

    test('unknown ids are ignored; nothing found gives an empty payload', () {
      final p = copyItems(standard(), ids(['it_nope']));
      expect(p.isEmpty, isTrue);
      expect(p.media, isEmpty);
    });

    test('copying from a locked lane is allowed (read-only)', () {
      final p = copyItems(standard(lockMain: true), ids(['it_c']));
      expect(p.itemIds, ids(['it_c']));
    });
  });

  group('cross-project paste', () {
    test('mints fresh ids and imports pool entries exactly once', () {
      final target = standard();
      final payload = otherPayload();
      final first = applyCommand(target, PasteItems(payload, f(300), ripple: false), ctx(seed: 1));
      expect(first.rejection, isNull);
      expectValid(first.project);
      final added = first.project.pool.assets.keys.toSet().difference(target.pool.assets.keys.toSet());
      expect(added, hasLength(3), reason: 'md_other, a re-minted id for the other md_video, md_rev; md_dupe reuses md_video2');
      expect(first.notices.where((n) => n.code == EditNoticeCodes.mediaImported).single.count, 3);

      final second = applyCommand(first.project, PasteItems(payload, f(600), ripple: false), ctx(seed: 2));
      expect(second.rejection, isNull);
      expectValid(second.project);
      expect(second.project.pool.assets.keys.toSet(), first.project.pool.assets.keys.toSet(), reason: 'imported once');
      expect(second.notices.where((n) => n.code == EditNoticeCodes.mediaImported), isEmpty);

      // Fresh, unique ids everywhere; no source id reused.
      final sourceIds = otherProject().tracks.expand((t) => t.items).map((i) => i.id).toSet();
      final all = <ItemId>[for (final t in second.project.tracks) for (final i in t.items) i.id];
      expect(all.toSet(), hasLength(all.length));
      expect(all.toSet().intersection(sourceIds), isEmpty);
      final pasted1 = first.selection!.items;
      final pasted2 = second.selection!.items;
      expect(pasted1.intersection(pasted2), isEmpty);
      // Each paste gets its own link group.
      LinkId? linkOf(EditProject p, Set<ItemId> s) => s.map((id) => p.index.item(id)!.link).whereType<LinkId>().toSet().single;
      expect(linkOf(second.project, pasted1), isNot(linkOf(second.project, pasted2)));
      expect(linkOf(second.project, pasted1), isNot(const LinkId('ln_o')));
    });

    test('the reused and re-minted media are referenced correctly', () {
      final out = applyCommand(standard(), PasteItems(otherPayload(), f(300), ripple: false), ctx());
      final media = {for (final t in out.project.tracks) for (final i in t.items) if (i is MediaClip) i.media};
      expect(media, contains(const MediaId('md_video2')), reason: 'md_dupe has md_video2\'s content');
      expect(media, isNot(contains(const MediaId('md_dupe'))));
      final remint = out.project.pool.assets.values.where((a) => a.fingerprint.quickHash == 'q-not-the-same').single;
      expect(remint.id, isNot(const MediaId('md_video')));
      expect(remint.addedAt, when);
      final rev = out.project.pool[const MediaId('md_rev')]!;
      expect((rev.derived! as ReversedSpec).media, const MediaId('md_other'));
    });
  });

  test('replace with shorter media clamps and emits trimmedToFit', () {
    final before = standard();
    final out = applyCommand(before, const ReplaceMedia(ItemId('it_b'), MediaId('md_short')), ctx());
    expect(out.rejection, isNull);
    expectValid(out.project);
    final b = out.project.index.item(const ItemId('it_b'))! as MediaClip;
    expect(b.start, f(60));
    expect(b.sourceIn, 0);
    expect(b.sourceIn + ClipTimeMap.sourceLengthOf(b.duration, b.speed), lessThanOrEqualTo(sec(1)));
    expect(rate.frameIndexOf(b.end) - rate.frameIndexOf(b.start), 30);
    expect(out.notices.where((n) => n.code == EditNoticeCodes.trimmedToFit).single.items, {const ItemId('it_b')});
  });

  group('extracted audio stays in sync at every frame', () {
    for (var seed = 1; seed <= 120; seed++) {
      test('seed $seed', () {
        final rnd = Random(seed);
        final frames = 1 + rnd.nextInt(300);
        final SpeedSpec speed = switch (rnd.nextInt(3)) {
          0 => const ConstantSpeed(1),
          1 => ConstantSpeed(0.1 + rnd.nextDouble() * 9.9),
          _ => SpeedRamp([const SpeedPoint(0, 1), SpeedPoint(0.4, 0.1 + rnd.nextDouble() * 9.9), SpeedPoint(1, 0.1 + rnd.nextDouble() * 9.9)]),
        };
        final pool = MediaPool({...basePool.assets, const MediaId('md_long'): asset('md_long', MediaKind.video, duration: sec(3600), hasAudio: true)});
        final clip = vclip('it_v', 5 + rnd.nextInt(50), frames,
            media: 'md_long', sourceIn: rnd.nextInt(sec(100)), speed: speed, reversed: rnd.nextBool());
        final before = project([lane('tr_main', TrackKind.video, [clip], main: true)], pool: pool);
        final out = applyCommand(before, ExtractAudio(clip.id), ctx(seed: seed));
        expect(out.rejection, isNull);
        expectValid(out.project);
        final video = out.project.index.item(clip.id)! as MediaClip;
        final audio = out.project.tracks.firstWhere((t) => t.kind == TrackKind.audio).items.single as MediaClip;
        expect(video.detachedAudio, isTrue);
        expect(audio.link, isNotNull);
        expect(audio.link, video.link);
        expect(out.project.tracks.firstWhere((t) => t.kind == TrackKind.audio).audioRole, AudioRole.original);
        final mv = ClipTimeMap.forClip(video, rate);
        final ma = ClipTimeMap.forClip(audio, rate);
        for (var k = rate.frameIndexOf(video.start); k < rate.frameIndexOf(video.end); k++) {
          expect(ma.toSource(f(k)), mv.toSource(f(k)), reason: 'frame $k');
        }
        expect(ma.lower(), mv.lower());
      });
    }
  });

  group('SelectionRules.expand', () {
    // (selection, expected) on the standard project and on a locked variant.
    final table = <(String, EditProject Function(), List<String>, Set<String>)>[
      ('a plain clip', standard, ['it_b'], {'it_b'}),
      ('a linked clip adds its partner', standard, ['it_a'], {'it_a', 'it_a_au'}),
      ('a partner adds the clip', standard, ['it_a_au'], {'it_a', 'it_a_au'}),
      ('both members once', standard, ['it_a', 'it_a_au'], {'it_a', 'it_a_au'}),
      ('three-member group', threeLinked, ['it_o'], {'it_v', 'it_o', 'it_t'}),
      ('unknown ids are dropped', standard, ['it_nope', 'it_c'], {'it_c'}),
      ('items on locked lanes are dropped', () => standard(lockMain: true), ['it_b', 'it_m'], {'it_m'}),
      ('a partner on a locked lane is dropped', () => standard(lockMain: true), ['it_a_au'], {'it_a_au'}),
      ('a clip on a locked lane is dropped, its partner kept', () => standard(lockMain: true), ['it_a'], {'it_a_au'}),
      ('empty stays empty', standard, [], {}),
    ];
    for (final (name, p, input, expected) in table) {
      test(name, () {
        expect(SelectionRules.expand(p(), ids(input)), {for (final s in expected) ItemId(s)});
      });
    }
  });

  group('selection helpers', () {
    test('split targets: selected items under the time, else the main-lane item', () {
      final p = standard();
      expect(SelectionRules.splitTargets(p, f(30), ids(['it_t1'])), ids(['it_t1']));
      expect(SelectionRules.splitTargets(p, f(30), ids(['it_c'])), ids(['it_a']), reason: 'selected item not under the time');
      expect(SelectionRules.splitTargets(p, f(30), const {}), ids(['it_a']));
      expect(SelectionRules.splitTargets(p, f(30), ids(['it_a'])), ids(['it_a', 'it_a_au']));
      expect(SelectionRules.splitTargets(p, f(130), const {}), isEmpty, reason: 'gap');
      expect(SelectionRules.splitTargets(standard(lockMain: true), f(30), const {}), isEmpty);
      expect(SelectionRules.splitTargets(p, f(10), ids(['it_s1'])), ids(['it_a']), reason: 'cues are split by SplitCue');
    });

    test('lanes, single-lane checks and move targets', () {
      final p = standard();
      expect(SelectionRules.lanesOf(p, ids(['it_m', 'it_b'])), [const TrackId('tr_main'), const TrackId('tr_music')]);
      expect(SelectionRules.isSingleLane(p, ids(['it_b', 'it_c'])), isTrue);
      expect(SelectionRules.isSingleLane(p, ids(['it_a', 'it_a_au'])), isFalse);
      expect(SelectionRules.moveTargets(p, ids(['it_c'])), [const TrackId('tr_ov1')]);
      expect(SelectionRules.moveTargets(p, ids(['it_m'])), [const TrackId('tr_orig')]);
      expect(SelectionRules.moveTargets(p, ids(['it_a', 'it_a_au'])), isEmpty);
    });

    test('select all, items at a time, surviving ids and hints', () {
      final p = standard(lockMain: true);
      expect(SelectionRules.allOnLane(p, const TrackId('tr_main')), isEmpty);
      expect(SelectionRules.allOnLane(p, const TrackId('tr_music')), ids(['it_m']));
      expect(SelectionRules.all(p), isNot(contains(const ItemId('it_b'))));
      expect(SelectionRules.itemsAt(standard(), f(35)), [for (final s in ['it_a', 'it_p1', 'it_t1', 'it_a_au', 'it_m']) ItemId(s)]);
      expect(SelectionRules.itemsAt(standard(), f(35), lane: const TrackId('tr_ov1')), [const ItemId('it_p1')]);
      final out = applyCommand(standard(), DuplicateItems(ids(['it_c'])), ctx());
      final hint = SelectionRules.hintAfter(out)!;
      expect(hint.items, hasLength(1));
      expect(hint.primary, hint.items.single);
      final deleted = applyCommand(out.project, DeleteItems(hint.items), ctx());
      expect(SelectionRules.surviving(deleted.project, hint.items), isEmpty);
    });
  });
}
