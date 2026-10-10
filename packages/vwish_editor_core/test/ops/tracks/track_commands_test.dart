// OWNER: CORE-17
//
// Track commands (BUILD_PLAN CORE-17): goldens for AddTrack, DeleteTrack, MoveTrack, RenameTrack,
// SetTrackFlags and SetAudioRole, plus band-ordering and main-lane properties.
// Regenerate with `UPDATE_GOLDENS=1 dart test test/ops/tracks` and review the diff.

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../../support/random_project.dart';
import '../framework/ops_support.dart';
import 'track_fixtures.dart';

TrackId t(String s) => TrackId(s);

final List<Case> addCases = [
  ('video lane goes on top of the video lanes', lanes, const AddTrack(TrackKind.video)),
  ('overlay lane on top of the overlay lanes', lanes, const AddTrack(TrackKind.overlay, name: '  PiP  ')),
  ('text lane', lanes, const AddTrack(TrackKind.text)),
  ('subtitle lane with a language', lanes, const AddTrack(TrackKind.subtitle, language: 'fr')),
  ('audio lane defaults to music', lanes, const AddTrack(TrackKind.audio)),
  ('audio lane with a role', lanes, const AddTrack(TrackKind.audio, audioRole: AudioRole.voice, name: 'Narration')),
  ('role is ignored for visual lanes', lanes, const AddTrack(TrackKind.overlay, audioRole: AudioRole.voice)),
  ('the first video lane of an empty project is the main lane', () => project(const []), const AddTrack(TrackKind.video)),
  ('a lane kind the project has none of', () => project([laneOf('v', TrackKind.video, [vclip('a', 0, 30)], main: true)]), const AddTrack(TrackKind.audio)),
  ('name too long', lanes, AddTrack(TrackKind.text, name: 'x' * 61)),
  ('name of 60 graphemes is fine', lanes, AddTrack(TrackKind.text, name: '👨‍👩‍👧‍👦' * 60)),
];

final List<Case> deleteCases = [
  ('empty overlay lane', () => lanes(), DeleteTrack(t('v3'))),
  ('lane with items', lanes, DeleteTrack(t('ov1'))),
  ('lane with a transition', lanes, DeleteTrack(t('v2'))),
  ('lane with a linked item: the partner loses its link', lanes, DeleteTrack(t('a_orig'))),
  ('the partner lane of a link', () => lanes(), DeleteTrack(t('t1'))),
  ('subtitle lane', lanes, DeleteTrack(t('s1'))),
  ('main lane', lanes, DeleteTrack(t('v_main'))),
  ('main lane even when it is the only lane', () => project([laneOf('v', TrackKind.video, const [], main: true)]), DeleteTrack(t('v'))),
  ('locked lane', lanes, DeleteTrack(t('ov2'))),
  ('missing lane', lanes, DeleteTrack(t('nope'))),
];

final List<Case> moveCases = [
  ('video lane up (v2 -> index 2)', lanes, MoveTrack(t('v2'), 2)),
  ('video lane down (v3 -> index 1)', lanes, MoveTrack(t('v3'), 1)),
  ('overlay lane (ov1 -> index 4)', () {
    final p = lanes();
    return applyCommand(p, SetTrackFlags(t('ov2'), locked: false), ctx()).project;
  }, MoveTrack(t('ov1'), 4)),
  ('audio lane to the bottom', lanes, MoveTrack(t('a_orig'), 9)),
  ('audio lane to the top of the audio group', lanes, MoveTrack(t('a_fx'), 7)),
  ('same index is a no-op', lanes, MoveTrack(t('v2'), 1)),
  ('a video lane below the main lane', lanes, MoveTrack(t('v2'), 0)),
  ('main lane cannot move', lanes, MoveTrack(t('v_main'), 1)),
  ('main lane to its own index is a no-op', lanes, MoveTrack(t('v_main'), 0)),
  ('overlay lane into the video band', lanes, MoveTrack(t('ov1'), 2)),
  ('video lane into the overlay band', lanes, MoveTrack(t('v3'), 3)),
  ('text lane into the subtitle band', lanes, MoveTrack(t('t1'), 6)),
  ('audio lane into the visual bands', lanes, MoveTrack(t('a_music'), 5)),
  ('index out of range', lanes, MoveTrack(t('v2'), 10)),
  ('negative index', lanes, MoveTrack(t('v2'), -1)),
  ('locked lane', lanes, MoveTrack(t('ov2'), 3)),
  ('missing lane', lanes, MoveTrack(t('nope'), 1)),
];

final List<Case> renameCases = [
  ('rename', lanes, RenameTrack(t('v2'), 'B-roll')),
  ('trimmed', lanes, RenameTrack(t('v2'), '  B-roll  ')),
  ('empty restores the derived name', lanes, RenameTrack(t('a_music'), '')),
  ('same name is a no-op', lanes, RenameTrack(t('a_music'), 'Score')),
  ('too long', lanes, RenameTrack(t('v2'), 'y' * 61)),
  ('locked lane', lanes, RenameTrack(t('ov2'), 'x')),
  ('missing lane', lanes, RenameTrack(t('nope'), 'x')),
];

final List<Case> flagCases = [
  ('lock', lanes, SetTrackFlags(t('v2'), locked: true)),
  ('unlock a locked lane', lanes, SetTrackFlags(t('ov2'), locked: false)),
  ('hide a video lane', lanes, SetTrackFlags(t('v2'), hidden: true)),
  ('hide a text lane', lanes, SetTrackFlags(t('t1'), hidden: true)),
  ('hide a subtitle lane', lanes, SetTrackFlags(t('s1'), hidden: true)),
  ('mute an audio lane', lanes, SetTrackFlags(t('a_music'), muted: true)),
  ('mute a video lane (its clips carry audio)', lanes, SetTrackFlags(t('v_main'), muted: true)),
  ('solo an audio lane', lanes, SetTrackFlags(t('a_orig'), solo: true)),
  ('several flags in one command', lanes, SetTrackFlags(t('a_music'), muted: true, solo: true, locked: true)),
  ('unlock and rename-free change on a locked lane', lanes, SetTrackFlags(t('ov2'), locked: false, hidden: true)),
  ('same flags are a no-op', lanes, SetTrackFlags(t('v2'), locked: false, hidden: false)),
  ('no flags is a no-op', lanes, SetTrackFlags(t('v2'))),
  ('hide an audio lane', lanes, SetTrackFlags(t('a_music'), hidden: true)),
  ('unhide an audio lane is harmless', lanes, SetTrackFlags(t('a_music'), hidden: false)),
  ('mute a text lane', lanes, SetTrackFlags(t('t1'), muted: true)),
  ('solo a subtitle lane', lanes, SetTrackFlags(t('s1'), solo: true)),
  ('missing lane', lanes, SetTrackFlags(t('nope'), locked: true)),
];

final List<Case> roleCases = [
  ('set role', lanes, SetAudioRole(t('a_music'), AudioRole.voice)),
  ('same role is a no-op', lanes, SetAudioRole(t('a_music'), AudioRole.music)),
  ('not an audio lane', lanes, SetAudioRole(t('v2'), AudioRole.voice)),
  ('locked audio lane', () => applyCommand(lanes(), SetTrackFlags(t('a_music'), locked: true), ctx()).project, SetAudioRole(t('a_music'), AudioRole.voice)),
  ('missing lane', lanes, SetAudioRole(t('nope'), AudioRole.voice)),
];

void main() {
  final golden = GoldenFile('test/ops/tracks/goldens/tracks.golden');
  tearDownAll(golden.save);

  group('AddTrack', () => goldenCases(golden, 'add', addCases));
  group('DeleteTrack', () => goldenCases(golden, 'delete', deleteCases));
  group('MoveTrack', () => goldenCases(golden, 'move', moveCases));
  group('RenameTrack', () => goldenCases(golden, 'rename', renameCases));
  group('SetTrackFlags', () => goldenCases(golden, 'flags', flagCases));
  group('SetAudioRole', () => goldenCases(golden, 'role', roleCases));

  group('details', () {
    test('every new lane lands at the top of its kind, in canonical order, and is selected', () {
      for (final kind in TrackKind.values) {
        final p = lanes();
        final out = applyCommand(p, AddTrack(kind), ctx());
        expect(out.rejection, isNull, reason: kind.name);
        final created = out.createdTracks.single;
        expect(TrackOrder.isCanonical(out.project.tracks), isTrue, reason: kind.name);
        expect(TrackOrder.bandsAscend(out.project.tracks), isTrue);
        final sameKind = out.project.tracks.where((x) => x.kind == kind).toList();
        expect(sameKind.last.id, created, reason: '${kind.name}: on top of its kind');
        expect(out.selection?.lane, created);
        expect(out.project.tracks.where((x) => x.isMain), hasLength(1));
        expectValid(out.project, kind.name);
      }
    });

    test('the main lane stays the first video lane after adds', () {
      var p = lanes();
      for (var i = 0; i < 3; i++) {
        p = applyCommand(p, const AddTrack(TrackKind.video), ctx(seed: 10 + i)).project;
      }
      expect(p.tracks.first.id, t('v_main'));
      expect(p.tracks.first.isMain, isTrue);
      expect(p.tracks.where((x) => x.isMain), hasLength(1));
    });

    test('deleting a lane drops its items and transitions and keeps the rest identical', () {
      final p = lanes();
      final out = applyCommand(p, DeleteTrack(t('v2')), ctx());
      expect(out.project.tracks.map((x) => x.id), [for (final x in p.tracks) if (x.id != t('v2')) x.id]);
      expect(out.affected, {const ItemId('c'), const ItemId('d')});
      expect(out.changedTracks, {t('v2')});
      for (final x in out.project.tracks) {
        expect(identical(x, trackIn(p, x.id.value)), isTrue, reason: '${x.id} is the same object');
      }
    });

    test('deleting a linked lane clears the lonely partner link (I7)', () {
      final out = applyCommand(lanes(), DeleteTrack(t('a_orig')), ctx());
      final a = out.project.index.item(const ItemId('a'))!;
      expect(a.link, isNull);
      expectValid(out.project);
    });

    test('moving a lane keeps every item and only reorders', () {
      final p = lanes();
      final out = applyCommand(p, MoveTrack(t('v2'), 2), ctx());
      expect(out.project.tracks.map((x) => x.id.value), ['v_main', 'v3', 'v2', 'ov1', 'ov2', 't1', 's1', 'a_orig', 'a_music', 'a_fx']);
      expect(out.project.tracks.firstWhere((x) => x.id == t('v2')).items, trackIn(p, 'v2').items);
      expect(out.changedTracks, {t('v2'), t('v3')});
    });

    test('no move within or across the video band ever displaces the main lane', () {
      final p = lanes();
      for (var to = 0; to < p.tracks.length; to++) {
        for (final id in ['v2', 'v3']) {
          final out = applyCommand(p, MoveTrack(t(id), to), ctx());
          if (out.rejection == null && !out.noop) {
            expect(out.project.tracks.first.id, t('v_main'), reason: '$id -> $to');
            expect(TrackOrder.isCanonical(out.project.tracks), isTrue);
            expectValid(out.project, '$id -> $to');
          }
        }
      }
    });

    test('exhaustive: every lane to every index keeps band order or refuses', () {
      final p = lanes();
      var moved = 0;
      var refused = 0;
      for (final lane in p.tracks) {
        for (var to = -1; to <= p.tracks.length; to++) {
          final out = applyCommand(p, MoveTrack(lane.id, to), ctx());
          if (out.rejection != null) {
            refused++;
            expect(identical(out.project, p), isTrue);
            continue;
          }
          if (out.noop) continue;
          moved++;
          expect(TrackOrder.isCanonical(out.project.tracks), isTrue, reason: '${lane.id} -> $to');
          expect(out.project.tracks.indexWhere((x) => x.id == lane.id), to);
          expect(out.project.tracks.where((x) => x.isMain).single.id, t('v_main'));
          expectValid(out.project, '${lane.id} -> $to');
        }
      }
      expect(moved, greaterThan(5));
      expect(refused, greaterThan(50));
    });

    test('flags: hidden, muted and solo are exactly what the lane stores; changedAt is stamped', () {
      final out = applyCommand(lanes(), SetTrackFlags(t('a_music'), muted: true, solo: true), ctx(stamp: 9));
      final lane = trackIn(out.project, 'a_music');
      expect((lane.muted, lane.solo, lane.hidden, lane.locked), (true, true, false, false));
      expect(lane.changedAt, 9);
      expect(trackIn(out.project, 'a_orig').changedAt, 0);
    });

    test('a locked lane refuses everything except SetTrackFlags', () {
      final p = lanes();
      for (final c in <EditCommand>[
        DeleteTrack(t('ov2')),
        MoveTrack(t('ov2'), 3),
        RenameTrack(t('ov2'), 'x'),
        DeleteItems({const ItemId('o2')}),
      ]) {
        expect(applyCommand(p, c, ctx()).rejection, TrackLocked(t('ov2')), reason: '$c');
      }
      expect(applyCommand(p, SetTrackFlags(t('ov2'), locked: false, muted: true), ctx()).rejection, isNull);
    });

    test('random sequences of track commands keep the project valid', () {
      var p = randomProject(21, const RandomProjectSpec(items: 60));
      var step = 0;
      var applied = 0;
      EditCommand next() {
        final lanes = p.tracks;
        final lane = lanes[(step * 7) % lanes.length];
        step++;
        switch (step % 7) {
          case 0:
            return AddTrack(TrackKind.values[step % TrackKind.values.length]);
          case 1:
            return DeleteTrack(lane.id);
          case 2:
            return MoveTrack(lane.id, (step * 3) % lanes.length);
          case 3:
            return RenameTrack(lane.id, 'lane $step');
          case 4:
            return SetTrackFlags(lane.id, muted: step.isEven, hidden: step % 3 == 0, locked: step % 11 == 0);
          case 5:
            return SetAudioRole(lane.id, AudioRole.values[step % 4]);
          default:
            return SetTrackFlags(lane.id, locked: false);
        }
      }

      for (var i = 0; i < 300; i++) {
        final out = applyCommand(p, next(), ctx(seed: 500 + i));
        if (out.rejection != null || out.noop) continue;
        p = out.project;
        applied++;
        expectValid(p, 'step $i');
        expect(TrackOrder.bandsAscend(p.tracks), isTrue);
      }
      expect(applied, greaterThan(100));
    });
  });
}
