// OWNER: UX-11
//
// What the track menu offers per lane (TrackMenuModel): the switches of each kind, Move up and
// Move down targets as CORE-17 `MoveTrack` indices (display order is reverse z for visual lanes,
// canonical order for audio lanes, nothing moves below the main lane), the main lane's
// protections, locked lanes, subtitle rows.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/track_strings.dart';
import 'package:danaview_editor/src/editor/timeline/track_menu_sheet.dart';
import 'package:danaview_editor_core/model.dart';

import 'track_test_support.dart';

void main() {
  final project = allKindsProject(extra: [
    Track(id: const TrackId('tr_music2'), kind: TrackKind.audio, audioRole: AudioRole.effects, items: const []),
  ]);
  final snapshot = snapshotOfProject(project);
  TrackMenuModel model(String id, {EditProject? p, bool readOnly = false}) {
    final project0 = p ?? project;
    final snap = p == null ? snapshot : snapshotOfProject(p);
    return TrackMenuModel.of(lane: snap.lane(TrackId(id))!, tracks: project0.tracks, readOnly: readOnly);
  }

  // tracks: main(0) video2(1) overlay(2) text(3) subs(4) music(5) voice(6) music2(7)

  test('switches per kind', () {
    final main = model('tr_main');
    expect((main.showsVisible, main.showsMute, main.showsSolo, main.showsRole, main.isSubtitle), (true, true, true, false, false));
    final overlay = model('tr_overlay');
    expect((overlay.showsVisible, overlay.showsMute, overlay.showsSolo), (true, false, false), reason: 'an image has no audio');
    final text = model('tr_text');
    expect((text.showsVisible, text.showsMute, text.showsSolo, text.showsRole), (true, false, false, false));
    final subs = model('tr_subs');
    expect((subs.showsVisible, subs.showsMute, subs.isSubtitle), (true, false, true));
    final music = model('tr_music');
    expect((music.showsVisible, music.showsMute, music.showsSolo, music.showsRole), (false, true, true, true));
  });

  group('move up and down', () {
    test('visual lanes: up is the next higher index inside the kind group', () {
      final p = allKindsProject(extra: [Track(id: const TrackId('tr_video3'), kind: TrackKind.video, items: const [])]);
      // Canonical order puts new video lanes before overlays: insert tr_video3 after tr_video2.
      final ordered = [
        for (final t in p.tracks.where((t) => t.id.value != 'tr_video3'))
          if (t.id.value == 'tr_video2') ...[t, p.tracks.firstWhere((t) => t.id.value == 'tr_video3')] else t,
      ];
      final proj = EditProject(id: p.id, meta: p.meta, timeline: p.timeline.copyWith(tracks: ordered), pool: p.pool);
      final v2 = model('tr_video2', p: proj);
      expect(v2.moveUpTo, 2, reason: 'tr_video3 sits at index 2');
      expect(v2.moveDownTo, isNull, reason: 'the main lane is below; nothing moves under it');
      expect(v2.moveDownReason, TrackStrings.moveDownBottom);
      final v3 = model('tr_video3', p: proj);
      expect(v3.moveUpTo, isNull);
      expect(v3.moveUpReason, TrackStrings.moveUpTop);
      expect(v3.moveDownTo, 1);
    });

    test('the only lane of a kind can not move', () {
      final overlay = model('tr_overlay');
      expect((overlay.moveUpTo, overlay.moveDownTo), (null, null));
      expect(overlay.moveUpReason, TrackStrings.moveUpTop);
      expect(overlay.moveDownReason, TrackStrings.moveDownBottom);
    });

    test('audio lanes are listed in canonical order: up is the previous index', () {
      final music = model('tr_music');
      expect(music.moveUpTo, isNull, reason: 'first audio lane');
      expect(music.moveDownTo, 6);
      final voice = model('tr_voice');
      expect(voice.moveUpTo, 5);
      expect(voice.moveDownTo, 7);
      final last = model('tr_music2');
      expect(last.moveUpTo, 6);
      expect(last.moveDownTo, isNull);
    });

    test('the main lane never moves', () {
      final main = model('tr_main');
      expect((main.moveUpTo, main.moveDownTo), (null, null));
      expect(main.moveUpReason, TrackStrings.mainCantMove);
      expect(main.moveDownReason, TrackStrings.mainCantMove);
    });

    test('a locked lane does not move or delete until it is unlocked', () {
      final locked = model('tr_music', p: withTrack(project, 'tr_music', (t) => t.copyWith(locked: true)));
      expect((locked.moveUpTo, locked.moveDownTo), (null, null));
      expect(locked.moveDownReason, TrackStrings.unlockFirst);
      expect(locked.canDelete, isFalse);
      expect(locked.deleteReason, TrackStrings.unlockFirst);
      expect(locked.canEditLane, isFalse);
    });
  });

  group('delete', () {
    test('the main lane is protected', () {
      final main = model('tr_main');
      expect(main.canDelete, isFalse);
      expect(main.deleteReason, TrackStrings.mainCantDelete);
    });

    test('other lanes can be deleted; the item count drives the confirmation', () {
      final music = model('tr_music');
      expect(music.canDelete, isTrue);
      expect(music.deleteReason, isNull);
      expect(music.itemCount, 1);
      expect(model('tr_voice').itemCount, 0);
    });
  });

  group('subtitles', () {
    test('burn-in follows the lane and Regenerate needs provenance', () {
      final plain = model('tr_subs');
      expect(plain.burnIn, isTrue);
      expect(plain.regenerate, isFalse);
      final generated = model('tr_subs', p: allKindsProject(generatedSubtitles: true, burnIn: false));
      expect(generated.burnIn, isFalse);
      expect(generated.regenerate, isTrue);
    });
  });

  test('read-only projects can not edit', () {
    final m = model('tr_music', readOnly: true);
    expect(m.canEdit, isFalse);
    expect(m.canEditLane, isFalse);
  });

  test('a lane missing from the project has no moves', () {
    final m = TrackMenuModel.of(lane: snapshot.lane(const TrackId('tr_music'))!, tracks: const []);
    expect((m.moveUpTo, m.moveDownTo), (null, null));
  });
}
