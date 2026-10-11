// OWNER: UX-10
//
// timelineSnapshotProvider (buildTimelineSnapshot): empty until open, follows commits, keeps the
// committed project while a transaction is open (ghosts are drawn by the interaction layer),
// reuses unchanged lanes across commits, and follows media health and the lane height mode.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/state/editor_controller.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' hide MediaUnavailable;

import '../../support/support.dart';
import '../../state/state_support.dart';

void main() {
  test('follows the committed project through commits and transactions', () async {
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('Snapshot');
    final rig = ControllerRig(repository: repo, id: empty.id);
    final container = ProviderContainer(overrides: [
      editorSessionProvider.overrideWith((ref, id) => rig.session),
      editorControllerProvider.overrideWith((ref, id) => rig.controller),
    ]);
    addTearDown(container.dispose);

    final seen = <TimelineSnapshot>[];
    final sub = container.listen(timelineSnapshotProvider(empty.id), (_, next) => seen.add(next), fireImmediately: true);
    addTearDown(sub.close);
    expect(identical(sub.read(), TimelineSnapshot.empty), isTrue, reason: 'not open yet');

    await rig.open();
    final opened = sub.read();
    expect(identical(opened, TimelineSnapshot.empty), isFalse);
    expect(opened.lanes, isEmpty, reason: 'a new empty project');

    expect(rig.controller.apply(const AddText(0)), isA<EditApplied>());
    final one = sub.read();
    final text = one.lanes.firstWhere((l) => l.kind == TrackKind.text);
    expect(text.items.single.kind, ItemVisualKind.text);

    // An open transaction shows the committed project.
    final tx = rig.controller.beginTransaction('Add text');
    tx.update(AddText(FrameRate.fps30.timeOfFrame(120)));
    rig.frames.flush();
    expect(rig.controller.state.inTransaction, isTrue);
    expect(identical(sub.read(), one), isTrue);
    tx.commit();
    rig.frames.flush();
    final two = sub.read();
    expect(identical(two, one), isFalse);
    expect(two.lanes.where((l) => l.kind == TrackKind.text).expand((l) => l.items).length, 2);

    // Undo returns to the first project's content, reusing the untouched item's model.
    expect(rig.controller.undo(), isTrue);
    final undone = sub.read().lanes.where((l) => l.kind == TrackKind.text).expand((l) => l.items).toList();
    expect(undone.length, 1);
    expect(identical(undone.single, text.items.single), isTrue);

    // Lane height mode and media health.
    rig.controller.setModes((m) => m.copyWith(laneHeight: LaneHeightPreset.large));
    expect(sub.read().lanes.every((l) => l.height == LaneHeightPreset.large), isTrue);
    final before = sub.read();
    rig.controller.setMediaHealth(MediaHealth(missing: {const MediaId('m_none')}));
    expect(identical(sub.read(), before), isTrue, reason: 'no item uses that media');

    // Selection changes do not rebuild the snapshot.
    final count = seen.length;
    rig.controller.selectAll();
    rig.controller.clearSelection();
    expect(seen.length, count);
  });
}
