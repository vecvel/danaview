// OWNER: UX-10
//
// TimelineSnapshotBuilder (ux.md §8.2): display order (D-09), identity reuse of LaneModel and
// ItemModel when the domain objects are identical, lane revisions, item visuals, badges, keyframe
// union, cuts and gaps.

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart' show MediaHealth;
import 'package:vwish_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:vwish_editor_core/model.dart';

import 'canvas_fixtures.dart';

void main() {
  group('display order and models', () {
    final snap = TimelineSnapshotBuilder().build(richProject());

    test('lanes top to bottom: subtitle, text, overlays (front first), extra video, main, audio', () {
      expect(snap.lanes.map((l) => l.id), [
        'tr_subs',
        'tr_text',
        'tr_overlay2',
        'tr_overlay',
        'tr_video2',
        'tr_main',
        'tr_music',
        'tr_voice',
      ]);
      expect(snap.lanes.map((l) => l.displayName), ['Subtitles 1', 'Text 1', 'Overlay 2', 'Overlay 1', 'Video 2', 'Main', 'Music 1', 'Voice 2']);
      expect(snap.frameRate, FrameRate.fps30);
      expect(snap.duration, 17 * s);
      expect(snap.markers.single.id, 'mk_1');
    });

    test('item visual kinds and labels', () {
      ItemModel m(String id) => snap.item(ItemId(id))!;
      expect(m('it_v1').kind, ItemVisualKind.video);
      expect(m('it_v1').label, 'beach.mp4');
      expect(m('it_v2').kind, ItemVisualKind.image);
      expect(m('it_v5').kind, ItemVisualKind.freeze);
      expect(m('it_a1').kind, ItemVisualKind.audio);
      expect(m('it_t1').kind, ItemVisualKind.text);
      expect(m('it_t1').label, 'Hello world', reason: 'first line of the text');
      expect(m('it_c1').kind, ItemVisualKind.cue);
      expect(m('it_v6').label, 'Graded', reason: 'the item label wins over the media name');
    });

    test('badges, audio, speed and offline state', () {
      ItemModel m(String id) => snap.item(ItemId(id))!;
      expect(m('it_v3').badges, ItemBadges.speed);
      expect(m('it_v3').avgSpeed, 2);
      final graded = m('it_v6').badges;
      for (final b in [ItemBadges.ramp, ItemBadges.reversed, ItemBadges.muted, ItemBadges.fx, ItemBadges.color, ItemBadges.lut, ItemBadges.chroma, ItemBadges.mask, ItemBadges.keyframes]) {
        expect(graded & b, isNot(0), reason: 'bit $b');
      }
      expect(graded & ItemBadges.speed, 0);
      expect(m('it_v5').badges & ItemBadges.pending, isNot(0));
      expect(m('it_v5').badges & ItemBadges.freeze, isNot(0));
      expect(m('it_v5').pending, isTrue);
      expect(m('it_v1').hasAudio, isTrue);
      expect(m('it_v1').fadeIn, 1 * s);
      expect(m('it_v2').hasAudio, isFalse);
      expect(m('it_a1').volume, 0.8);
      expect(m('it_a1').volumeKeys.map((k) => k.t), [f(60), f(180)]);
      expect(m('it_v4').offline, isFalse);
      final offline = TimelineSnapshotBuilder().build(richProject(), health: MediaHealth(missing: {const MediaId('m_lost')}));
      expect(offline.item(const ItemId('it_v4'))!.offline, isTrue);
      expect(offline.item(const ItemId('it_v1'))!.offline, isFalse);
    });

    test('keyframe union over channels (vec2 channels map to their property)', () {
      final o1 = snap.item(const ItemId('it_o1'))!;
      expect(o1.keyframeTimes, [0, f(30), f(60)]);
      expect(o1.keyframeProperties, ['transform.position', 'transform.scale', 'transform.position']);
      expect(o1.keyframeAt(1), 1 * s + f(30));
      expect(TimelineSnapshotBuilder.propertyOfChannel('transform.position.y'), 'transform.position');
      expect(TimelineSnapshotBuilder.propertyOfChannel('audio.volume'), 'audio.volume');
    });

    test('cuts with and without transitions, main-lane gaps', () {
      final main = snap.lane(const TrackId('tr_main'))!;
      expect(main.cuts.map((c) => (c.at, c.hasTransition)), [(5 * s, true), (8 * s, false), (15 * s, false)]);
      expect(main.cuts.first.transition!.kind, TransitionKind.crossDissolve);
      expect(main.gaps, [TimeRange(0, 1 * s), TimeRange(11 * s, 12 * s)]);
      expect(main.gapAt(11 * s + 5), TimeRange(11 * s, 12 * s));
      expect(snap.lane(const TrackId('tr_video2'))!.gaps, isEmpty, reason: 'gaps only on the main lane');
      expect(snap.lane(const TrackId('tr_music'))!.cuts, isEmpty, reason: 'no transitions on audio lanes');
    });

    test('lookups', () {
      expect(snap.locate(const ItemId('it_v2')), (lane: 5, index: 1));
      expect(snap.laneOf(const ItemId('it_a1'))!.id, 'tr_music');
      expect(snap.laneIndexOf(const TrackId('tr_voice')), 7);
      final main = snap.lanes[5];
      expect(main.itemIndexAt(5 * s), 1);
      expect(main.itemIndexAt(11 * s), isNull);
      expect(main.firstItemEndingAfter(5 * s), 1);
      expect(main.firstCutFrom(6 * s), 1);
    });
  });

  group('identity reuse', () {
    test('rebuilding the same project returns the same snapshot', () {
      final b = TimelineSnapshotBuilder();
      final p = richProject();
      final a = b.build(p);
      expect(identical(b.build(p), a), isTrue);
      expect(b.lastBuiltLanes, 0);
      expect(b.lastBuiltItems, 0);
    });

    test('a change on one lane rebuilds that lane only and reuses its untouched items', () {
      final b = TimelineSnapshotBuilder();
      final p = richProject();
      final a = b.build(p);
      final main = p.timeline.tracks.firstWhere((t) => t.isMain);
      // Split it_v2 (5..8 s) at 6 s: one item replaced by two.
      final v2 = main.items[1] as MediaClip;
      final split = [
        ...main.items.take(1),
        v2.copyWith(duration: 1 * s),
        clip('it_v2b', 'm_photo', 6 * s, 2 * s),
        ...main.items.skip(2),
      ];
      final next = b.build(withTrackItems(p, main.id, split));
      expect(identical(next, a), isFalse);
      expect(next.revision, greaterThan(a.revision));
      expect(b.lastBuiltLanes, 1);
      expect(b.lastBuiltItems, 2, reason: 'the shortened item and the new one');
      for (var i = 0; i < a.lanes.length; i++) {
        if (a.lanes[i].id == 'tr_main') continue;
        expect(identical(next.lanes[i], a.lanes[i]), isTrue, reason: a.lanes[i].id);
      }
      final oldMain = a.lane(main.id)!, newMain = next.lane(main.id)!;
      expect(newMain.revision, greaterThan(oldMain.revision));
      expect(identical(newMain.items.first, oldMain.items.first), isTrue);
      expect(identical(newMain.items.last, oldMain.items.last), isTrue);
      expect(identical(next.media, a.media), isTrue, reason: 'pool unchanged');
    });

    test('a track object change without visible change keeps the lane model', () {
      final b = TimelineSnapshotBuilder();
      final p = richProject();
      final a = b.build(p);
      final music = p.timeline.tracks.firstWhere((t) => t.id == 'tr_music');
      final next = b.build(withTrackItems(p, music.id, music.items));
      expect(identical(next.lane(music.id), a.lane(music.id)), isTrue);
      expect(identical(next, a), isTrue);
    });

    test('lane flags rebuild the lane but reuse its items', () {
      final b = TimelineSnapshotBuilder();
      final p = richProject();
      final a = b.build(p);
      final tracks = [for (final t in p.timeline.tracks) t.id == 'tr_music' ? t.copyWith(locked: true) : t];
      final next = b.build(EditProject(id: p.id, meta: p.meta, timeline: p.timeline.copyWith(tracks: tracks), pool: p.pool));
      final lane = next.lane(const TrackId('tr_music'))!;
      expect(identical(lane, a.lane(const TrackId('tr_music'))), isFalse);
      expect(lane.locked, isTrue);
      expect(identical(lane.items.single, a.lane(const TrackId('tr_music'))!.items.single), isTrue);
      expect(b.lastBuiltItems, 0);
    });

    test('media health changes rebuild only the items of the affected media', () {
      final b = TimelineSnapshotBuilder();
      final p = richProject();
      final a = b.build(p);
      final next = b.build(p, health: MediaHealth(missing: {const MediaId('m_lost')}));
      expect(b.lastBuiltItems, 1);
      expect(b.lastBuiltLanes, 1);
      expect(next.item(const ItemId('it_v4'))!.offline, isTrue);
      expect(identical(next.lane(const TrackId('tr_music')), a.lane(const TrackId('tr_music'))), isTrue);
      expect(identical(next.item(const ItemId('it_v1')), a.item(const ItemId('it_v1'))), isTrue);
      // Equal health again: nothing rebuilt.
      final again = b.build(p, health: MediaHealth(missing: {const MediaId('m_lost')}));
      expect(identical(again, next), isTrue);
    });

    test('lane height changes rebuild lanes but no items', () {
      final b = TimelineSnapshotBuilder();
      final p = richProject();
      final a = b.build(p);
      final next = b.build(p, laneHeight: LaneHeightPreset.large);
      expect(next.lanes.every((l) => l.height == LaneHeightPreset.large), isTrue);
      expect(b.lastBuiltItems, 0);
      expect(identical(next.lanes.first.items.first, a.lanes.first.items.first), isTrue);
    });

    test('a large project: a one-item change builds one item', () {
      final b = TimelineSnapshotBuilder();
      final p = largeProject();
      b.build(p);
      final main = p.timeline.tracks.first;
      final items = [...main.items];
      items[1000] = (items[1000] as MediaClip).copyWith(label: 'renamed');
      final next = b.build(withTrackItems(p, main.id, items));
      expect(b.lastBuiltItems, 1);
      expect(b.lastBuiltLanes, 1);
      expect(next.item(const ItemId('it_m1000'))!.label, 'renamed');
    });
  });
}
