// OWNER: UX-11
//
// Which toggles a lane has per kind (ux.md §8.3) and which fit in a header at each width
// (ux.md §8.10): compact at 44 px, inline toggles by priority at 132 to 220 px with 32 px (pointer)
// or 44 px (touch) slots, the rest as status glyphs; checked over every width, input and text
// scale.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:danaview_editor/src/editor/timeline/track_headers.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SetTrackFlags;

import 'track_test_support.dart';

void main() {
  final project = allKindsProject();
  final snapshot = snapshotOfProject(project);
  LaneModel lane(String id) => snapshot.lane(TrackId(id))!;

  group('applicable flags (ux.md §8.3)', () {
    test('main and extra video lanes with audio: lock, visibility, mute, solo', () {
      expect(TrackFlags.applicable(lane('tr_main')), [TrackFlag.lock, TrackFlag.hidden, TrackFlag.muted, TrackFlag.solo]);
      expect(TrackFlags.applicable(lane('tr_video2')), [TrackFlag.lock, TrackFlag.hidden, TrackFlag.muted, TrackFlag.solo]);
    });

    test('overlay lanes with an image have no audio controls until a flag is on', () {
      expect(TrackFlags.applicable(lane('tr_overlay')), [TrackFlag.lock, TrackFlag.hidden]);
      final muted = snapshotOfProject(withTrack(project, 'tr_overlay', (t) => t.copyWith(muted: true))).lane(const TrackId('tr_overlay'))!;
      expect(TrackFlags.applicable(muted), contains(TrackFlag.muted));
      expect(TrackFlags.applicable(muted), contains(TrackFlag.solo));
    });

    test('an empty video lane has no audio controls', () {
      final empty = snapshotOfProject(withTrack(project, 'tr_video2', (t) => t.copyWith(items: const []))).lane(const TrackId('tr_video2'))!;
      expect(TrackFlags.applicable(empty), [TrackFlag.lock, TrackFlag.hidden]);
    });

    test('audio lanes: lock, mute, solo (no visibility)', () {
      expect(TrackFlags.applicable(lane('tr_music')), [TrackFlag.lock, TrackFlag.muted, TrackFlag.solo]);
      expect(TrackFlags.applicable(lane('tr_voice')), [TrackFlag.lock, TrackFlag.muted, TrackFlag.solo], reason: 'also when empty');
    });

    test('text and subtitle lanes: lock and visibility only', () {
      expect(TrackFlags.applicable(lane('tr_text')), [TrackFlag.lock, TrackFlag.hidden]);
      expect(TrackFlags.applicable(lane('tr_subs')), [TrackFlag.lock, TrackFlag.hidden]);
    });

    test('isOn reads the lane', () {
      final l = snapshotOfProject(withTrack(project, 'tr_music', (t) => t.copyWith(locked: true, solo: true))).lane(const TrackId('tr_music'))!;
      expect(TrackFlags.isOn(l, TrackFlag.lock), isTrue);
      expect(TrackFlags.isOn(l, TrackFlag.solo), isTrue);
      expect(TrackFlags.isOn(l, TrackFlag.muted), isFalse);
      expect(TrackFlags.isOn(l, TrackFlag.hidden), isFalse);
    });

    test('toggle builds the CORE-17 command that flips one flag', () {
      final l = lane('tr_music');
      final cmd = TrackFlags.toggle(l, TrackFlag.muted);
      expect(cmd, isA<SetTrackFlags>());
      expect((cmd.track, cmd.muted, cmd.locked, cmd.hidden, cmd.solo), (const TrackId('tr_music'), true, null, null, null));
      final hide = TrackFlags.toggle(l, TrackFlag.hidden);
      expect(hide.hidden, isTrue);
      final unlock = TrackFlags.toggle(snapshotOfProject(withTrack(project, 'tr_music', (t) => t.copyWith(locked: true))).lane(const TrackId('tr_music'))!, TrackFlag.lock);
      expect(unlock.locked, isFalse);
    });
  });

  group('planner', () {
    TrackHeaderPlan plan(String id, double width, {bool touch = false, double scale = 1, Set<TrackFlag> active = const {}}) {
      final l = lane(id);
      return TrackHeaderPlanner.plan(kind: l.kind, applicable: TrackFlags.applicable(l), active: active, width: width, touch: touch, textScale: scale);
    }

    test('44 px is the compact icon header; active flags become glyphs', () {
      final p = plan('tr_music', 44, active: {TrackFlag.lock, TrackFlag.muted});
      expect(p.compact, isTrue);
      expect(p.inline, isEmpty);
      expect(p.glyphs, [TrackFlag.lock, TrackFlag.muted]);
    });

    test('compact with nothing on shows no glyphs', () => expect(plan('tr_main', 44).glyphs, isEmpty));

    test('too narrow for a name beside the icon is compact too', () {
      expect(plan('tr_main', 60).compact, isTrue);
      expect(plan('tr_main', 64).compact, isFalse);
    });

    test('132 px with a pointer: two toggles by priority (video: visibility and mute)', () {
      final p = plan('tr_video2', 132);
      expect(p.compact, isFalse);
      expect(p.toggleSlot, 32);
      expect(p.inline, [TrackFlag.hidden, TrackFlag.muted]);
    });

    test('132 px with touch: one 44 px toggle', () {
      final p = plan('tr_video2', 132, touch: true);
      expect(p.toggleSlot, 44);
      expect(p.inline, [TrackFlag.hidden]);
    });

    test('168 px with a pointer: three toggles; audio gets mute, solo and lock', () {
      expect(plan('tr_music', 168).inline, [TrackFlag.lock, TrackFlag.muted, TrackFlag.solo]);
      expect(plan('tr_main', 168).inline, [TrackFlag.lock, TrackFlag.hidden, TrackFlag.muted]);
    });

    test('220 px with touch: three toggles; text lanes have both of theirs', () {
      expect(plan('tr_main', 220, touch: true).inline.length, 3);
      expect(plan('tr_text', 220, touch: true).inline, [TrackFlag.lock, TrackFlag.hidden]);
    });

    test('flags that do not fit inline show as glyphs while on, and only as many as fit', () {
      final p = plan('tr_main', 132, touch: true, active: {TrackFlag.lock, TrackFlag.muted, TrackFlag.solo});
      expect(p.inline, [TrackFlag.hidden]);
      // 132 - 8 - 56 - 44 = 24 px left: one 14 px glyph.
      expect(p.glyphs.length, 1);
      expect(p.glyphs.first, TrackFlag.lock);
    });

    test('larger text reserves more room for the name', () {
      expect(plan('tr_video2', 132, scale: 1.0).inline.length, 2);
      expect(plan('tr_video2', 132, scale: 1.35).inline.length, 1);
    });

    test('inline toggles keep display order, not priority order', () {
      final p = plan('tr_main', 168);
      expect(p.inline, [TrackFlag.lock, TrackFlag.hidden, TrackFlag.muted]);
    });

    test('matrix: every width, input and scale fits its toggles beside a minimum name', () {
      for (final id in ['tr_main', 'tr_video2', 'tr_overlay', 'tr_text', 'tr_subs', 'tr_music', 'tr_voice']) {
        for (final touch in [false, true]) {
          for (final scale in [0.85, 1.0, 1.35]) {
            for (var width = 30.0; width <= 260; width += 2) {
              final all = TrackFlags.applicable(lane(id)).toSet();
              final p = plan(id, width, touch: touch, scale: scale, active: all);
              if (width <= TimelineMetrics.compactHeaderWidth || width < 2 * TrackHeaderPlanner.padding + TrackHeaderPlanner.nameMinWidth * (scale > 1 ? scale : 1)) {
                expect(p.compact, isTrue, reason: '$id @ $width');
                continue;
              }
              final used = p.inline.length * p.toggleSlot;
              expect(used + 2 * TrackHeaderPlanner.padding + TrackHeaderPlanner.nameMinWidth * (scale > 1 ? scale : 1), lessThanOrEqualTo(width + 0.001),
                  reason: '$id @ $width touch=$touch scale=$scale: ${p.inline}');
              expect(p.inline.toSet().intersection(p.glyphs.toSet()), isEmpty, reason: 'a flag is inline or a glyph, never both');
              final glyphRoom = width - 2 * TrackHeaderPlanner.padding - TrackHeaderPlanner.nameMinWidth * (scale > 1 ? scale : 1) - used;
              expect(p.glyphs.length * TrackHeaderPlanner.glyphWidth, lessThanOrEqualTo(glyphRoom + 0.001));
            }
          }
        }
      }
    });

    test('the header widths of the layouts give the documented counts', () {
      // 132 (medium), 168 (expanded pointer), 220 (expanded touch) for an audio lane at scale 1.
      expect(plan('tr_music', TimelineMetrics.mediumHeaderWidth).inline.length, 2);
      expect(plan('tr_music', TimelineMetrics.expandedPointerHeaderWidth).inline.length, 3);
      expect(plan('tr_music', TimelineMetrics.expandedTouchHeaderWidth, touch: true).inline.length, 3);
    });
  });
}
