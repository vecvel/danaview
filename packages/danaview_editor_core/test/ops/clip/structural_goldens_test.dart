// OWNER: CORE-10
//
// Before/after golden tests for every structural command (BUILD_PLAN CORE-10): insert, move,
// trim, split, delete and delete gap, including ripple, link, lock, clamp and new-lane cases.
// Every applied result validates fully and the dry run agrees with the apply (`runCase`).
// Regenerate with `UPDATE_GOLDENS=1 dart test test/ops/clip` and review the diff.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';

typedef Case = (String, EditProject Function(), EditCommand, EditPolicy?);

ItemId id(String s) => ItemId(s);
Set<ItemId> ids(List<String> s) => {for (final x in s) ItemId(x)};

/// The standard project with an unlinked clip right after the extracted audio on the original
/// lane, so ripples that move the partner hit it.
EditProject blockedPartner() => standard(extraOriginal: [aclip('it_x', 100, 30, media: 'md_music')]);

final List<Case> insertCases = [
  ('insert ripple at a cut (main lane)', standard, InsertMedia([const MediaId('md_video2')], f(120)), null),
  ('insert ripple inside a clip snaps to the nearest cut', standard, InsertMedia([const MediaId('md_video2')], f(100)), null),
  ('insert ripple at the a|b cut drops the transition', standard, InsertMedia([const MediaId('md_image')], f(60)), null),
  ('insert ripple at 0 moves the linked partner, not the music', standard, InsertMedia([const MediaId('md_image')], 0), null),
  ('insert ripple blocked by a linked partner', blockedPartner, InsertMedia([const MediaId('md_image')], 0), null),
  ('insert two clips back to back (ripple)', standard, InsertMedia([const MediaId('md_image'), const MediaId('md_short')], f(210)), null),
  ('insert newLane into occupied main goes to a new video lane', standard,
      InsertMedia([const MediaId('md_video2')], f(30), mode: InsertMode.newLane), null),
  ('insert newLane into a free gap stays on main', standard, InsertMedia([const MediaId('md_short')], f(120), mode: InsertMode.newLane), null),
  ('insert auto with ripple off behaves as newLane', () => standard(rippleEnabled: false), InsertMedia([const MediaId('md_image')], f(100)), null),
  ('insert overlay on an explicit overlay lane', standard,
      InsertMedia([const MediaId('md_image')], f(90), track: const TrackId('tr_ov1'), mode: InsertMode.newLane), null),
  ('insert music with no lane uses the music lane, occupied -> new music lane', standard,
      InsertMedia([const MediaId('md_music')], 0, mode: InsertMode.newLane), null),
  ('insert a recording creates a voice lane', standard, InsertMedia([const MediaId('md_rec')], f(15), mode: InsertMode.newLane), null),
  ('insert video audio onto the original lane', standard,
      InsertMedia([const MediaId('md_video2')], f(60), track: const TrackId('tr_orig'), mode: InsertMode.newLane), null),
  ('insert with policy reject into occupied space', standard, InsertMedia([const MediaId('md_video2')], f(30), mode: InsertMode.newLane),
      const EditPolicy(overlap: OverlapPolicy.reject)),
  ('insert into a locked lane', () => standard(lockMain: true), InsertMedia([const MediaId('md_image')], f(300)), null),
  ('insert a LUT', standard, InsertMedia([const MediaId('md_lut')], 0), null),
  ('insert missing media', standard, InsertMedia([const MediaId('md_missing')], 0), null),
  ('insert media on a text lane', standard, InsertMedia([const MediaId('md_image')], 0, track: const TrackId('tr_txt')), null),
  ('insert audio media on a video lane', standard, InsertMedia([const MediaId('md_music')], 0, track: const TrackId('tr_main')), null),
  ('insert mixed visual and audio media', standard, InsertMedia([const MediaId('md_image'), const MediaId('md_music')], 0), null),
];

final List<Case> moveCases = [
  ('move later into free space', standard, MoveItems(ids(['it_c']), f(30)), null),
  ('move earlier to touch the previous clip', standard, MoveItems(ids(['it_c']), -f(30)), null),
  ('move into an occupied range -> new video lane', standard, MoveItems(ids(['it_c']), -f(40)), null),
  ('move a linked clip moves its partner; transition dropped', standard, MoveItems(ids(['it_a']), f(10)), null),
  ('move a linked partner moves the clip', standard, MoveItems(ids(['it_a_au']), f(400)), null),
  ('move vertically to an overlay lane', standard, MoveItems(ids(['it_c']), 0, toTrack: const TrackId('tr_ov1')), null),
  ('move vertically into an occupied lane -> nearest free lane', standard,
      MoveItems(ids(['it_p1']), 0, toTrack: const TrackId('tr_main')), null),
  ('move audio onto a video lane', standard, MoveItems(ids(['it_m']), 0, toTrack: const TrackId('tr_main')), null),
  ('move a multi-lane selection vertically', standard, MoveItems(ids(['it_c', 'it_p1']), 0, toTrack: const TrackId('tr_ov1')), null),
  ('move before 0 without clamp', standard, MoveItems(ids(['it_p1']), -f(40)), null),
  ('move before 0 with clamp', standard, MoveItems(ids(['it_p1']), -f(40), clamp: true), null),
  ('move a locked clip', () => standard(lockMain: true), MoveItems(ids(['it_c']), f(10)), null),
  ('move with policy reject into occupied space', standard, MoveItems(ids(['it_c']), -f(40)), const EditPolicy(overlap: OverlapPolicy.reject)),
  ('move with policy reject and clamp stops at the neighbour', standard, MoveItems(ids(['it_c']), -f(40), clamp: true),
      const EditPolicy(overlap: OverlapPolicy.reject)),
  ('move two clips keeps their offsets and their transition', standard, MoveItems(ids(['it_a', 'it_b']), f(400)), null),
  ('ripple move left onto the main lane snaps to a cut', standard, MoveItems(ids(['it_c']), -f(60), ripple: true), null),
  ('ripple move a linked clip right: close at source, insert at target', standard, MoveItems(ids(['it_a']), f(120), ripple: true), null),
  ('ripple move to the end of the main lane', standard, MoveItems(ids(['it_b']), f(300), ripple: true), null),
  ('ripple move on an overlay lane inside a clip snaps out of it', () => project([
        lane('tr_main', TrackKind.video, [vclip('it_v', 0, 300)], main: true),
        lane('tr_ov1', TrackKind.overlay, [
          vclip('it_o1', 0, 30, media: 'md_image'),
          vclip('it_o2', 30, 30, media: 'md_image'),
          vclip('it_o3', 60, 30, media: 'md_image'),
        ]),
      ]), MoveItems(ids(['it_o1']), f(50), ripple: true), null),
  ('ripple move vertically to another lane', standard, MoveItems(ids(['it_c']), -f(150), toTrack: const TrackId('tr_ov1'), ripple: true), null),
  ('move by zero is a no-op', standard, MoveItems(ids(['it_c']), 0), null),
  ('move an unknown item', standard, MoveItems(ids(['it_nope']), f(1)), null),
];

final List<Case> trimCases = [
  ('trim end shorter leaves a gap', standard, TrimItem(id('it_c'), TrimEdge.end, f(180)), null),
  ('trim end longer into free space', standard, TrimItem(id('it_b'), TrimEdge.end, f(140)), null),
  ('trim end into the next clip', standard, TrimItem(id('it_b'), TrimEdge.end, f(160)), null),
  ('trim end into the next clip with clamp', standard, TrimItem(id('it_b'), TrimEdge.end, f(160), clamp: true), null),
  ('trim end past the media', standard, TrimItem(id('it_c'), TrimEdge.end, f(500)), null),
  ('trim end past the media with clamp', standard, TrimItem(id('it_c'), TrimEdge.end, f(500), clamp: true), null),
  ('trim end below one frame', standard, TrimItem(id('it_c'), TrimEdge.end, f(150)), null),
  ('trim end below one frame with clamp', standard, TrimItem(id('it_c'), TrimEdge.end, f(120), clamp: true), null),
  ('trim start later moves sourceIn', standard, TrimItem(id('it_c'), TrimEdge.start, f(160)), null),
  ('trim start earlier than the media start', standard, TrimItem(id('it_c'), TrimEdge.start, f(140)), null),
  ('trim start earlier into the previous clip', standard, TrimItem(id('it_b'), TrimEdge.start, f(50)), null),
  ('trim start earlier restores source (b has 10 s before it)', () => project([
        lane('tr_main', TrackKind.video, [vclip('it_b', 400, 60, sourceIn: sec(10))], main: true),
      ]), TrimItem(id('it_b'), TrimEdge.start, f(200)), null),
  ('trim start past the media head with clamp', () => project([
        lane('tr_main', TrackKind.video, [vclip('it_b', 400, 60, sourceIn: sec(10))], main: true),
      ]), TrimItem(id('it_b'), TrimEdge.start, f(0), clamp: true), null),
  ('trim a linked clip trims its partner with the same edge', standard, TrimItem(id('it_a'), TrimEdge.end, f(50)), null),
  ('ripple trim end shifts the rest of the lane', standard, TrimItem(id('it_b'), TrimEdge.end, f(100), ripple: true), null),
  ('ripple trim end longer pushes the lane', standard, TrimItem(id('it_b'), TrimEdge.end, f(130), ripple: true), null),
  ('ripple trim end of a linked clip keeps partners in sync and the transition', standard,
      TrimItem(id('it_a'), TrimEdge.end, f(50), ripple: true), null),
  ('ripple trim shortens a transition to its new limit', () => project([
        lane('tr_main', TrackKind.video, [vclip('it_a', 0, 60), vclip('it_b', 60, 60, sourceIn: sec(10))],
            main: true, transitions: [transition('tx_ab', 'it_a', 'it_b', frames: 50)]),
      ]), TrimItem(id('it_a'), TrimEdge.end, f(10), ripple: true), null),
  ('trim that breaks adjacency drops the transition', () => project([
        lane('tr_main', TrackKind.video, [vclip('it_a', 0, 60), vclip('it_b', 60, 60, sourceIn: sec(10))],
            main: true, transitions: [transition('tx_ab', 'it_a', 'it_b', frames: 50)]),
      ]), TrimItem(id('it_a'), TrimEdge.end, f(10)), null),
  ('ripple head trim keeps the start and pulls the lane', standard, TrimItem(id('it_b'), TrimEdge.start, f(70), ripple: true), null),
  ('ripple head extend restores content and pushes the lane', standard, TrimItem(id('it_b'), TrimEdge.start, f(50), ripple: true), null),
  ('trim an image end without a source limit', standard, TrimItem(id('it_p1'), TrimEdge.end, f(900)), null),
  ('trim text start', standard, TrimItem(id('it_t1'), TrimEdge.start, f(15)), null),
  ('trim on a locked lane', () => standard(lockMain: true), TrimItem(id('it_c'), TrimEdge.end, f(180)), null),
  ('trim to the same time is a no-op', standard, TrimItem(id('it_c'), TrimEdge.end, f(210)), null),
];

final List<Case> splitCases = [
  ('split the main lane under the time (ids empty) splits linked partners', standard, SplitItems(const {}, f(30)), null),
  ('split selected clips; the outgoing transition follows the right half', standard, SplitItems(ids(['it_a']), f(45)), null),
  ('split text keeps in/out animations on the halves', () => project([
        lane('tr_main', TrackKind.video, [vclip('it_v', 0, 300)], main: true),
        lane('tr_txt', TrackKind.text, [
          text('it_t', 0, 90, animation: TextAnimation(inKind: TextAnimKind.fade, inDuration: f(10), outKind: TextAnimKind.scale, outDuration: f(15))),
        ]),
      ]), SplitItems(ids(['it_t']), f(40)), null),
  ('split clamps fades to the halves', () => project([
        lane('tr_main', TrackKind.video, [vclip('it_v', 0, 100, audio: AudioProps(fadeIn: f(40), fadeOut: f(40)))], main: true),
      ]), SplitItems(ids(['it_v']), f(30)), null),
  ('split at a cut finds nothing', standard, SplitItems(const {}, f(60)), null),
  ('split in a gap finds nothing', standard, SplitItems(const {}, f(130)), null),
  ('split on a locked lane', () => standard(lockMain: true), SplitItems(const {}, f(30)), null),
  ('split a cue is SplitCue\'s job', standard, SplitItems(ids(['it_s1']), f(10)), null),
  ('split floors a mid-frame time', standard, SplitItems(ids(['it_c']), f(170) + 1000), null),
];

final List<Case> deleteCases = [
  ('delete leaves a gap and drops the transition', standard, DeleteItems(ids(['it_b'])), null),
  ('ripple delete closes the gap', standard, DeleteItems(ids(['it_b']), ripple: true), null),
  ('delete a linked clip deletes its partner', standard, DeleteItems(ids(['it_a'])), null),
  ('ripple delete a linked clip; music untouched', standard, DeleteItems(ids(['it_a']), ripple: true), null),
  ('ripple delete several clips on two lanes', standard, DeleteItems(ids(['it_b', 'it_c', 'it_p1']), ripple: true), null),
  ('delete on a locked lane', () => standard(lockMain: true), DeleteItems(ids(['it_c'])), null),
  ('delete an unknown item', standard, DeleteItems(ids(['it_nope'])), null),
  ('delete gap', standard, DeleteGap(GapRef(const TrackId('tr_main'), TimeRange(f(120), f(150)))), null),
  ('delete part of a gap', standard, DeleteGap(GapRef(const TrackId('tr_main'), TimeRange(f(130), f(140)))), null),
  ('delete gap moves linked partners', () => project([
        lane('tr_main', TrackKind.video, [vclip('it_a', 0, 30), vclip('it_b', 60, 30, link: 'ln_b')], main: true),
        lane('tr_orig', TrackKind.audio, [aclip('it_b_au', 60, 30, media: 'md_video', link: 'ln_b')], role: AudioRole.original),
      ]), DeleteGap(GapRef(const TrackId('tr_main'), TimeRange(f(30), f(60)))), null),
  ('delete gap blocked by a linked partner', () => project([
        lane('tr_main', TrackKind.video, [vclip('it_a', 0, 30), vclip('it_b', 60, 30, link: 'ln_b')], main: true),
        lane('tr_orig', TrackKind.audio, [aclip('it_x', 20, 30), aclip('it_b_au', 60, 30, media: 'md_video', link: 'ln_b')],
            role: AudioRole.original),
      ]), DeleteGap(GapRef(const TrackId('tr_main'), TimeRange(f(30), f(60)))), null),
  ('delete a gap that overlaps a clip', standard, DeleteGap(GapRef(const TrackId('tr_main'), TimeRange(f(100), f(150)))), null),
  ('delete gap on a locked lane', () => standard(lockMain: true), DeleteGap(GapRef(const TrackId('tr_main'), TimeRange(f(120), f(150)))), null),
];

void runGroup(String file, List<Case> cases) {
  final golden = GoldenFile('test/ops/clip/goldens/$file');
  tearDownAll(golden.save);
  for (final c in cases) {
    test(c.$1, () {
      golden.check(c.$1, runCase(c.$1, c.$2(), c.$3, policy: c.$4 ?? const EditPolicy()));
    });
  }
}

void main() {
  group('InsertMedia', () => runGroup('insert.golden', insertCases));
  group('MoveItems', () => runGroup('move.golden', moveCases));
  group('TrimItem', () => runGroup('trim.golden', trimCases));
  group('SplitItems', () => runGroup('split.golden', splitCases));
  group('DeleteItems / DeleteGap', () => runGroup('delete.golden', deleteCases));
}
