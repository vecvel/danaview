// OWNER: UX-36
//
// The media bin and the timeline drop target together in the real editor screen (expanded layout:
// the idle side pane is the bin): a long press on a card carries it to a lane, the ghost shows
// where it lands and the drop commits one history entry exactly there.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart' show isTestGroup;
import 'package:danaview_editor/src/editor/editor_screen.dart';
import 'package:danaview_editor/src/editor/panels/media_panel.dart';
import 'package:danaview_editor/src/editor/timeline/render_timeline_canvas.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_drop_target.dart';
import 'package:danaview_editor_core/model.dart';

import '../../timeline/gestures/gesture_support.dart' show gestureProject;
import 'media_support.dart';

@isTestGroup
void _test(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    });

void main() {
  const tablet = EditorSurface(Size(1194, 834), platform: TargetPlatform.iOS);

  _test('the editor screen wraps its timeline in the drop target and shows the bin in the idle pane', (tester) async {
    await MediaRig.pump(
      tester,
      (id) => EditorScreen(projectId: id, onClose: () {}),
      project: (repo) {
        final base = gestureProject();
        final project = base.copyWith(pool: base.pool.upsert(binAsset('m_free', duration: 3 * s, name: 'free.mp4')));
        repo.seed(project);
        return project;
      },
      surface: tablet,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TimelineDropTarget), findsOneWidget);
    expect(find.byType(MediaPanel), findsOneWidget);
    expect(find.byKey(const ValueKey('media-card-m_free')), findsOneWidget);
  });

  _test('a card long-pressed and dragged from the bin lands where the ghost showed', (tester) async {
    final rig = await MediaRig.pump(
      tester,
      (id) => EditorScreen(projectId: id, onClose: () {}),
      project: (repo) {
        final base = gestureProject();
        final project = base.copyWith(pool: base.pool.upsert(binAsset('m_free', duration: 3 * s, name: 'free.mp4')));
        repo.seed(project);
        return project;
      },
      surface: tablet,
    );
    await tester.pump(const Duration(milliseconds: 300));
    rig.editor.setModes((m) => m.copyWith(ripple: false));
    rig.viewport
      ..setPxPerSecond(60, anchorX: 0)
      ..jumpTo(scrollTimeSec: 0, scrollY: 0);
    await tester.pump();
    final canvas = tester.renderObject<RenderTimelineCanvas>(find.byType(TimelineCanvas));
    final g0 = canvas.geometry;
    final li = g0.snapshot.laneIndexOf(const TrackId('tr_main'))!;
    final target = canvas.localToGlobal(Offset(rig.viewport.xOf(15 * s), g0.laneTop(li) + g0.stack.heights[li] / 2));

    final card = find.byKey(const ValueKey('media-card-m_free'));
    final press = await tester.startGesture(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 600)); // the long press that lifts the card
    await press.moveBy(const Offset(-30, 0));
    await tester.pump();
    await press.moveTo(target);
    await tester.pump();
    final state = tester.state<TimelineDropTargetState>(find.byType(TimelineDropTarget));
    final ghost = state.ghost!;
    expect(ghost.valid, isTrue);
    final placement = ghost.placements.values.single;
    expect(placement.range, const TimeRange(15 * s, 18 * s));
    final depth = rig.historyDepth;
    await press.up();
    await tester.pump();
    final main = rig.project.timeline.tracks.firstWhere((t) => t.id == const TrackId('tr_main'));
    expect(main.items.last.range, placement.range, reason: 'the clip is where the ghost was');
    expect((main.items.last as MediaClip).media, const MediaId('m_free'));
    expect(rig.historyDepth, depth + 1);
    expect(state.ghost, isNull);
  });
}
