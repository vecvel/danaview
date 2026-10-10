// OWNER: CORE-16
//
// SetTransition and ApplyTransitionToAll (BUILD_PLAN CORE-16): before/after goldens for every
// kind and rejection (`runCase`: applied results validate fully and the dry run agrees with the
// apply), plus targeted checks of notices, ids, clamping and one-command semantics. Regenerate
// with `UPDATE_GOLDENS=1 dart test test/ops/transitions` and review the diff.

import 'package:test/test.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../framework/ops_support.dart';

TransitionRef ref(String track, String l, String r) => TransitionRef(TrackId(track), ItemId(l), ItemId(r));

/// Main lane: a [0,60) and b [60,120) from 10 s into a 60 s video, c [120,150) from the start of
/// a 10 s video (no handle before it), a gap, then images d [200,230) and e [230,260);
/// overlay o1 [0,20) | o2 [20,40) images; a locked video lane; music.
EditProject base({List<Transition> mainTransitions = const []}) => project([
      lane('tr_main', TrackKind.video, [
        vclip('a', 0, 60, sourceIn: sec(10)),
        vclip('b', 60, 60, sourceIn: sec(10)),
        vclip('c', 120, 30, media: 'md_video2'),
        vclip('d', 200, 30, media: 'md_image'),
        vclip('e', 230, 30, media: 'md_image'),
      ], main: true, transitions: mainTransitions),
      lane('tr_ov', TrackKind.overlay, [vclip('o1', 0, 20, media: 'md_image'), vclip('o2', 20, 20, media: 'md_image')]),
      lane('tr_lock', TrackKind.overlay, [vclip('l1', 0, 20, media: 'md_image'), vclip('l2', 20, 20, media: 'md_image')], locked: true),
      lane('tr_txt', TrackKind.text, [text('x', 0, 30)]),
      lane('tr_mus', TrackKind.audio, [aclip('m1', 0, 30), aclip('m2', 30, 30)], role: AudioRole.music),
    ]);

EditProject withAB(TransitionKind kind, int frames) => base(mainTransitions: [transition('tx_ab', 'a', 'b', kind: kind, frames: frames)]);

final TransitionRef ab = ref('tr_main', 'a', 'b');
final TransitionRef bc = ref('tr_main', 'b', 'c');

typedef Case = (String, EditProject Function(), EditCommand);

final List<Case> setCases = [
  ('fade', base, SetTransition(ab, const TransitionSpec(TransitionKind.fade, 30))),
  ('cross dissolve', base, SetTransition(ab, const TransitionSpec(TransitionKind.crossDissolve, 20))),
  ('dip to black, odd length', base, SetTransition(ab, const TransitionSpec(TransitionKind.dipToBlack, 21))),
  ('dip to white', base, SetTransition(ab, const TransitionSpec(TransitionKind.dipToWhite, 12))),
  ('slide defaults to left', base, SetTransition(ab, const TransitionSpec(TransitionKind.slide, 15))),
  ('slide up', base, SetTransition(ab, const TransitionSpec(TransitionKind.slide, 15, direction: TransitionDirection.up))),
  ('wipe down', base, SetTransition(ab, const TransitionSpec(TransitionKind.wipe, 15, direction: TransitionDirection.down))),
  ('zoom defaults to in', base, SetTransition(ab, const TransitionSpec(TransitionKind.zoom, 15))),
  ('zoom out', base, SetTransition(ab, const TransitionSpec(TransitionKind.zoom, 15, direction: TransitionDirection.zoomOut))),
  ('direction ignored for a kind without directions', base,
      SetTransition(ab, const TransitionSpec(TransitionKind.fade, 15, direction: TransitionDirection.left))),
  ('on an overlay lane', base, SetTransition(ref('tr_ov', 'o1', 'o2'), const TransitionSpec(TransitionKind.crossDissolve, 20))),
  ('between images', base, SetTransition(ref('tr_main', 'd', 'e'), const TransitionSpec(TransitionKind.crossDissolve, 60))),
  ('replaces the transition of the cut and keeps its id', () => withAB(TransitionKind.fade, 30),
      SetTransition(ab, const TransitionSpec(TransitionKind.wipe, 10, direction: TransitionDirection.right))),
  ('same spec is a no-op', () => withAB(TransitionKind.fade, 30), SetTransition(ab, const TransitionSpec(TransitionKind.fade, 30))),
  ('remove', () => withAB(TransitionKind.fade, 30), SetTransition(ab, null)),
  ('remove where there is none is a no-op', base, SetTransition(ab, null)),
  ('longest fade for 60-frame clips', base, SetTransition(ab, const TransitionSpec(TransitionKind.fade, 120))),
  ('too long: clip lengths', base, SetTransition(ab, const TransitionSpec(TransitionKind.fade, 121))),
  ('too long: clamp shortens and notes it', base, SetTransition(ab, const TransitionSpec(TransitionKind.fade, 500), clamp: true)),
  ('too long: no handle before c, cross dissolve', base, SetTransition(bc, const TransitionSpec(TransitionKind.crossDissolve, 10))),
  ('too long: no handle, clamp still refuses (max 0)', base, SetTransition(bc, const TransitionSpec(TransitionKind.crossDissolve, 10), clamp: true)),
  ('no handle needed for a fade at b|c', base, SetTransition(bc, const TransitionSpec(TransitionKind.fade, 30))),
  ('too long: images 61', base, SetTransition(ref('tr_main', 'd', 'e'), const TransitionSpec(TransitionKind.zoom, 61))),
  ('not adjacent: gap', base, SetTransition(ref('tr_main', 'c', 'd'), const TransitionSpec(TransitionKind.fade, 10))),
  ('not adjacent: not neighbours', base, SetTransition(ref('tr_main', 'a', 'c'), const TransitionSpec(TransitionKind.fade, 10))),
  ('not adjacent: wrong order', base, SetTransition(ref('tr_main', 'b', 'a'), const TransitionSpec(TransitionKind.fade, 10))),
  ('missing left clip', base, SetTransition(ref('tr_main', 'zz', 'b'), const TransitionSpec(TransitionKind.fade, 10))),
  ('missing right clip', base, SetTransition(ref('tr_main', 'a', 'zz'), const TransitionSpec(TransitionKind.fade, 10))),
  ('missing lane', base, SetTransition(ref('tr_zz', 'a', 'b'), const TransitionSpec(TransitionKind.fade, 10))),
  ('locked lane', base, SetTransition(ref('tr_lock', 'l1', 'l2'), const TransitionSpec(TransitionKind.fade, 10))),
  ('remove on a locked lane', base, SetTransition(ref('tr_lock', 'l1', 'l2'), null)),
  ('audio lane', base, SetTransition(ref('tr_mus', 'm1', 'm2'), const TransitionSpec(TransitionKind.fade, 10))),
  ('text lane', base, SetTransition(ref('tr_txt', 'x', 'x'), const TransitionSpec(TransitionKind.fade, 10))),
  ('zero frames', base, SetTransition(ab, const TransitionSpec(TransitionKind.fade, 0))),
  ('direction of the wrong family', base, SetTransition(ab, const TransitionSpec(TransitionKind.slide, 10, direction: TransitionDirection.zoomIn))),
  ('zoom with a slide direction', base, SetTransition(ab, const TransitionSpec(TransitionKind.zoom, 10, direction: TransitionDirection.left))),
  ('too long: the neighbouring transition uses the room of b', () => withAB(TransitionKind.fade, 100),
      SetTransition(bc, const TransitionSpec(TransitionKind.fade, 40))),
  ('fits next to the neighbouring transition', () => withAB(TransitionKind.fade, 100), SetTransition(bc, const TransitionSpec(TransitionKind.fade, 20))),
];

final List<Case> allCases = [
  ('all cuts of the main lane: fade 30', base, ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 30))),
  ('all cuts, explicit lane', base, ApplyTransitionToAll(const TransitionSpec(TransitionKind.crossDissolve, 10), track: const TrackId('tr_ov'))),
  ('all cuts clamp per cut (handles, images, clip lengths)', base,
      ApplyTransitionToAll(const TransitionSpec(TransitionKind.crossDissolve, 100))),
  ('all cuts with a directional kind', base,
      ApplyTransitionToAll(const TransitionSpec(TransitionKind.slide, 10, direction: TransitionDirection.right))),
  ('all cuts replace existing transitions and keep their ids', () => withAB(TransitionKind.fade, 30),
      ApplyTransitionToAll(const TransitionSpec(TransitionKind.dipToBlack, 20))),
  ('all cuts, a cut without room keeps what it has', () => base(mainTransitions: [transition('tx_bc', 'b', 'c', kind: TransitionKind.fade, frames: 10)]),
      ApplyTransitionToAll(const TransitionSpec(TransitionKind.crossDissolve, 20))),
  ('remove all', () => withAB(TransitionKind.fade, 30), ApplyTransitionToAll(null)),
  ('remove all where there are none is a no-op', base, ApplyTransitionToAll(null)),
  ('same spec everywhere is a no-op', () {
    final p = base();
    return applyCommand(p, ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 20)), ctx()).project;
  }, ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 20))),
  ('lane without cuts is a no-op', () {
    final p = base();
    return p.copyWith(
      timeline: p.timeline.copyWith(tracks: [
        ...p.tracks.take(2),
        lane('tr_ov0', TrackKind.overlay, [vclip('q1', 0, 20, media: 'md_image'), vclip('q2', 40, 20, media: 'md_image')]),
        ...p.tracks.skip(2),
      ]),
    );
  }, ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 10), track: const TrackId('tr_ov0'))),
  ('locked lane', base, ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 10), track: const TrackId('tr_lock'))),
  ('audio lane', base, ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 10), track: const TrackId('tr_mus'))),
  ('missing lane', base, ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 10), track: const TrackId('tr_zz'))),
  ('zero frames', base, ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 0))),
  ('direction of the wrong family', base, ApplyTransitionToAll(const TransitionSpec(TransitionKind.wipe, 10, direction: TransitionDirection.zoomOut))),
  ('no video lane at all', () => project([lane('tr_mus', TrackKind.audio, [aclip('m1', 0, 30)], role: AudioRole.music)]),
      ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 10))),
];

void main() {
  final golden = GoldenFile('test/ops/transitions/goldens/transitions.golden');
  tearDownAll(golden.save);

  group('SetTransition goldens', () {
    for (final (name, make, command) in setCases) {
      test(name, () => golden.check('set: $name', runCase('set: $name', make(), command)));
    }
  });

  group('ApplyTransitionToAll goldens', () {
    for (final (name, make, command) in allCases) {
      test(name, () => golden.check('all: $name', runCase('all: $name', make(), command)));
    }
  });

  group('SetTransition details', () {
    test('stores kind, frames and direction on the lane, sorted by cut', () {
      final out = applyCommand(base(), SetTransition(bc, const TransitionSpec(TransitionKind.fade, 20)), ctx());
      final out2 = applyCommand(out.project, SetTransition(ab, const TransitionSpec(TransitionKind.slide, 10, direction: TransitionDirection.down)), ctx(seed: 99));
      final trs = out2.project.tracks.first.transitions;
      expect(trs.map((t) => (t.left.value, t.kind, t.durationFrames, t.direction)), [
        ('a', TransitionKind.slide, 10, TransitionDirection.down),
        ('b', TransitionKind.fade, 20, null),
      ]);
      expect(out2.changedTracks, {const TrackId('tr_main')});
      expect(out2.affected, {const ItemId('a'), const ItemId('b')});
    });

    test('directions: stored, defaulted per kind, dropped for kinds without one', () {
      TransitionDirection? stored(TransitionSpec spec) {
        final out = applyCommand(base(), SetTransition(ab, spec), ctx());
        expect(out.rejection, isNull, reason: '$spec');
        return out.project.tracks.first.transitions.single.direction;
      }

      expect(stored(const TransitionSpec(TransitionKind.slide, 10)), TransitionDirection.left);
      expect(stored(const TransitionSpec(TransitionKind.wipe, 10)), TransitionDirection.left);
      expect(stored(const TransitionSpec(TransitionKind.zoom, 10)), TransitionDirection.zoomIn);
      expect(stored(const TransitionSpec(TransitionKind.slide, 10, direction: TransitionDirection.up)), TransitionDirection.up);
      expect(stored(const TransitionSpec(TransitionKind.wipe, 10, direction: TransitionDirection.right)), TransitionDirection.right);
      expect(stored(const TransitionSpec(TransitionKind.zoom, 10, direction: TransitionDirection.zoomOut)), TransitionDirection.zoomOut);
      for (final k in [TransitionKind.fade, TransitionKind.crossDissolve, TransitionKind.dipToBlack, TransitionKind.dipToWhite]) {
        expect(stored(TransitionSpec(k, 10, direction: TransitionDirection.up)), isNull, reason: k.name);
      }
      expect(TransitionSpec.directionsOf(TransitionKind.fade), isEmpty);
      expect(TransitionSpec.defaultDirection(TransitionKind.zoom), TransitionDirection.zoomIn);
    });

    test('replacing keeps the transition id', () {
      final p = withAB(TransitionKind.fade, 30);
      final out = applyCommand(p, SetTransition(ab, const TransitionSpec(TransitionKind.wipe, 10)), ctx());
      expect(out.project.tracks.first.transitions.single.id, const TransitionId('tx_ab'));
    });

    test('TransitionTooLong carries the limit of the kind', () {
      final p = base();
      final fade = applyCommand(p, SetTransition(ab, const TransitionSpec(TransitionKind.fade, 999)), ctx());
      expect(fade.rejection, const TransitionTooLong(120));
      expect(TransitionLimits.of(p, ab, kind: TransitionKind.fade), 120);
      final dissolve = applyCommand(p, SetTransition(bc, const TransitionSpec(TransitionKind.crossDissolve, 10)), ctx());
      expect(dissolve.rejection, const TransitionTooLong(0));
    });

    test('the limit reported is accepted, one more is refused, for every kind', () {
      final p = base();
      for (final kind in TransitionKind.values) {
        final max = TransitionLimits.of(p, ab, kind: kind);
        expect(max, greaterThan(0), reason: kind.name);
        expect(applyCommand(p, SetTransition(ab, TransitionSpec(kind, max)), ctx()).rejection, isNull, reason: kind.name);
        expect(applyCommand(p, SetTransition(ab, TransitionSpec(kind, max + 1)), ctx()).rejection, TransitionTooLong(max), reason: kind.name);
      }
    });

    test('clamp shortens to the limit and says so', () {
      final out = applyCommand(base(), SetTransition(ab, const TransitionSpec(TransitionKind.fade, 500), clamp: true), ctx());
      expect(out.project.tracks.first.transitions.single.durationFrames, 120);
      expect(out.notices, [EditNotice(EditNoticeCodes.transitionsShortened, count: 1)]);
    });

    test('the neighbouring transition uses up room: the limit shrinks to what is left of b', () {
      final p = withAB(TransitionKind.fade, 100);
      // b is 60 frames; ceil(100/2) = 50 of them belong to a|b, so b|c fits 2 * 10 = 20 frames.
      expect(TransitionLimits.of(p, bc, kind: TransitionKind.fade), 20);
      final refused = applyCommand(p, SetTransition(bc, const TransitionSpec(TransitionKind.fade, 40)), ctx());
      expect(refused.rejection, const TransitionTooLong(20));
      final out = applyCommand(p, SetTransition(bc, const TransitionSpec(TransitionKind.fade, 40), clamp: true), ctx());
      expect(out.project.tracks.first.transitions.map((t) => t.durationFrames), [100, 20]);
      expect(validate(out.project), isEmpty);
    });

    test('dry run reports both clips and the lane, no new lanes', () {
      final pre = dryRun(base(), SetTransition(ab, const TransitionSpec(TransitionKind.fade, 30)), ctx());
      expect(pre.rejection, isNull);
      expect(pre.placements.keys, {const ItemId('a'), const ItemId('b')});
      expect(pre.createsTracks, isEmpty);
      expect(dryRun(base(), SetTransition(ab, const TransitionSpec(TransitionKind.fade, 999)), ctx()).rejection, const TransitionTooLong(120));
    });

    test('a rejection is data and leaves the project untouched', () {
      final p = base();
      final out = applyCommand(p, SetTransition(ref('tr_main', 'a', 'c'), const TransitionSpec(TransitionKind.fade, 10)), ctx());
      expect(out.rejection, const NotAdjacent());
      expect(identical(out.project, p), isTrue);
    });

    test('stamps the changed lane only', () {
      final out = applyCommand(base(), SetTransition(ab, const TransitionSpec(TransitionKind.fade, 30)), ctx(stamp: 5));
      expect(out.project.tracks.first.changedAt, 5);
      expect(out.project.tracks[1].changedAt, 0);
      expect(out.project.revision, 5);
    });
  });

  group('ApplyTransitionToAll details', () {
    test('is one command: one outcome, one lane change, valid result', () {
      final out = applyCommand(base(), ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 30)), ctx());
      final trs = out.project.tracks.first.transitions;
      expect(trs.map((t) => '${t.left}|${t.right}'), ['a|b', 'b|c', 'd|e']);
      expect(trs.map((t) => t.durationFrames), [30, 30, 30]);
      expect(out.changedTracks, {const TrackId('tr_main')});
      expect(validate(out.project), isEmpty);
    });

    test('clamps each cut to its own limit', () {
      final p = base();
      final out = applyCommand(p, ApplyTransitionToAll(const TransitionSpec(TransitionKind.crossDissolve, 100)), ctx());
      final trs = {for (final t in out.project.tracks.first.transitions) '${t.left}|${t.right}': t.durationFrames};
      // a|b: clips 60 frames each (b|c also loads b's end); b|c has no handle before c -> none;
      // d|e images of 30 frames -> 60 at most (less for the chained neighbours: none here).
      expect(trs.containsKey('b|c'), isFalse);
      expect(trs['d|e'], 60);
      expect(trs['a|b'], lessThanOrEqualTo(120));
      expect(validate(out.project), isEmpty);
      // Every cut got at most what the standalone limit says.
      for (final e in trs.entries) {
        final parts = e.key.split('|');
        expect(e.value, lessThanOrEqualTo(TransitionLimits.of(p, ref('tr_main', parts[0], parts[1]), kind: TransitionKind.crossDissolve)));
      }
      expect(out.notices.map((n) => n.code), containsAll([EditNoticeCodes.transitionsShortened, EditNoticeCodes.itemsSkipped]));
      final skipped = out.notices.firstWhere((n) => n.code == EditNoticeCodes.itemsSkipped);
      expect(skipped.items, {const ItemId('c')});
    });

    test('equal clips share a long transition evenly (3 clips of 20 frames, 30 requested)', () {
      final p = project([
        lane('v', TrackKind.video, [vclip('a', 0, 20), vclip('b', 20, 20), vclip('c', 40, 20)], main: true),
      ]);
      final out = applyCommand(p, ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 30)), ctx());
      expect(out.project.tracks.first.transitions.map((t) => t.durationFrames), [20, 20]);
      expect(validate(out.project), isEmpty);
    });

    test('defaults to the main lane; an explicit lane is used otherwise', () {
      final out = applyCommand(base(), ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 10), track: const TrackId('tr_ov')), ctx());
      expect(out.project.tracks.first.transitions, isEmpty);
      expect(out.project.tracks[1].transitions, hasLength(1));
    });

    test('affected lists only the clips of cuts that changed', () {
      final p = withAB(TransitionKind.fade, 20);
      final out = applyCommand(p, ApplyTransitionToAll(const TransitionSpec(TransitionKind.fade, 20)), ctx());
      // a|b already is fade 20; b|c and d|e are new.
      expect(out.affected, {const ItemId('b'), const ItemId('c'), const ItemId('d'), const ItemId('e')});
    });

    test('a null spec removes every transition of the lane and nothing else', () {
      final p = withAB(TransitionKind.fade, 20);
      final out = applyCommand(p, ApplyTransitionToAll(null), ctx());
      expect(out.project.tracks.first.transitions, isEmpty);
      expect(out.project.tracks.skip(1).toList(), p.tracks.skip(1).toList());
    });
  });

  group('edits that break adjacency drop the transition (CORE-10 commands)', () {
    EditProject chain() => project([
          lane('v', TrackKind.video, [vclip('a', 0, 60, sourceIn: sec(10)), vclip('b', 60, 60, sourceIn: sec(10)), vclip('c', 120, 60, sourceIn: sec(10))],
              main: true,
              transitions: [
                transition('t1', 'a', 'b', kind: TransitionKind.crossDissolve, frames: 20),
                transition('t2', 'b', 'c', kind: TransitionKind.crossDissolve, frames: 20),
              ]),
        ]);

    List<String> kept(EditOutcome o) => [for (final t in o.project.tracks.first.transitions) t.id.value];

    test('moving the right clip away drops both of its transitions', () {
      final out = applyCommand(chain(), MoveItems({const ItemId('b')}, f(500)), ctx());
      expect(out.rejection, isNull);
      expect(kept(out), isEmpty);
      expect(out.notices.map((n) => n.code), contains(EditNoticeCodes.transitionsRemoved));
    });

    test('trimming the end of the left clip creates a gap and drops the transition', () {
      final out = applyCommand(chain(), TrimItem(const ItemId('a'), TrimEdge.end, f(50)), ctx());
      expect(out.rejection, isNull);
      expect(kept(out), ['t2']);
    });

    test('deleting a clip drops the transitions touching it', () {
      final out = applyCommand(chain(), DeleteItems({const ItemId('b')}), ctx());
      expect(kept(out), isEmpty);
    });

    test('ripple delete closes the gap: the neighbours touch but have no transition', () {
      final out = applyCommand(chain(), DeleteItems({const ItemId('b')}, ripple: true), ctx());
      expect(kept(out), isEmpty);
      expect(out.project.tracks.first.items.map((i) => i.id.value), ['a', 'c']);
    });

    test('a ripple trim keeps the cut touching: the transition stays, re-clamped', () {
      // a shrinks from 60 to 10 frames: the transition at its end can be at most 20 frames.
      final out = applyCommand(chain(), TrimItem(const ItemId('a'), TrimEdge.end, f(10), ripple: true), ctx());
      expect(out.rejection, isNull);
      final t1 = out.project.tracks.first.transitions.firstWhere((t) => t.id.value == 't1');
      expect(t1.durationFrames, 20);
      final out2 = applyCommand(chain(), TrimItem(const ItemId('a'), TrimEdge.end, f(8), ripple: true), ctx());
      final t1b = out2.project.tracks.first.transitions.firstWhere((t) => t.id.value == 't1');
      expect(t1b.durationFrames, 16);
      expect(out2.notices.map((n) => n.code), contains(EditNoticeCodes.transitionsShortened));
      expect(validate(out2.project), isEmpty);
    });

    test('moving a clip within its lane to touch another creates no transition', () {
      final out = applyCommand(chain(), MoveItems({const ItemId('c')}, f(30)), ctx());
      expect(kept(out), ['t1']);
    });

    test('undo-style restore: applying the old project again brings the transition back', () {
      final p = chain();
      final moved = applyCommand(p, MoveItems({const ItemId('b')}, f(500)), ctx()).project;
      expect(moved.tracks.first.transitions, isEmpty);
      // Snapshots restore the transition (the session keeps `p`); nothing in the command layer
      // needs to remember it.
      expect(p.tracks.first.transitions, hasLength(2));
    });
  });
}
