// OWNER: QA-00
//
// ARCH §21.2 scenario 4: split, trim, move with snap, ripple delete, undo/redo, copy/paste and
// duplicate on frame_counter_1080p30.mp4, with barcode checks of what the preview shows.

// ignore_for_file: implementation_imports

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show TrimEdge;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 4: split, trim, move with snap, ripple delete, undo/redo, copy/paste, duplicate', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(tester, name: 'E2E edits ${DateTime.now().millisecondsSinceEpoch % 100000}', media: [E2eMedia.fixture(Fx.frameCounter)]);
    final r = ed.rate;
    expect(r, FrameRate.fps30);
    final clip = ed.mainTrack.items.single as MediaClip;

    // Split at frame 60 (S on the selected clip).
    await ed.select(clip.id);
    await ed.seekFrame(60);
    expect((await ed.barcode()).index, 60);
    await ed.invoke(EditorActionId.split);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 2, what: 'two clips after the split');
    final left = ed.mainTrack.items[0] as MediaClip;
    final right = ed.mainTrack.items[1] as MediaClip;
    expect(left.end, r.timeOfFrame(60));
    expect(right.start, r.timeOfFrame(60));

    // Trim the end of the right clip by one second through its trim handle.
    final trimTo = right.end - 1000000;
    await ed.dragTrim(right.id, TrimEdge.end, trimTo);
    await ed.waitProject((p) => (ed.item(right.id)).end == trimTo, what: 'the trimmed end at $trimTo');
    expect(ed.project.duration, r.timeOfFrame(210));

    // Move with snap: a text item starting at 3 s dragged towards the cut at 2 s, released 4 px
    // short of it, lands exactly on the cut.
    await ed.seekFrame(90);
    await ed.invoke(EditorActionId.addText);
    await ed.waitProject((p) => ed.items<TextItem>().isNotEmpty, what: 'a text item');
    final text = ed.items<TextItem>().single;
    expect(text.start, r.timeOfFrame(90));
    await ed.dragMove(text.id, r.timeOfFrame(60), overshootPx: 4);
    await ed.waitProject((p) => ed.item(text.id).start == r.timeOfFrame(60), what: 'the text snapped to the cut (got ${ed.item(text.id).start})');

    // Ripple delete the left clip: everything after it moves left by two seconds.
    await ed.select(left.id);
    await ed.invoke(EditorActionId.rippleDelete);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 1, what: 'one clip after the ripple delete');
    expect(ed.mainTrack.items.single.start, 0);
    await ed.seekFrame(0);
    expect((await ed.barcode()).index, 60, reason: 'frame 0 now shows source frame 60');

    // Undo / redo / undo.
    await ed.invoke(EditorActionId.undo);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 2, what: 'undo of the ripple delete');
    await ed.invoke(EditorActionId.redo);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 1, what: 'redo of the ripple delete');
    await ed.invoke(EditorActionId.undo);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 2, what: 'second undo');

    // Copy / paste at the end, then duplicate.
    await ed.select(ed.mainTrack.items.first.id);
    await ed.invoke(EditorActionId.copy);
    await ed.seekTo(ed.project.duration);
    await ed.invoke(EditorActionId.paste);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 3, what: 'the pasted clip');
    final pasted = ed.mainTrack.items.last as MediaClip;
    expect(pasted.duration, left.duration);
    expect(pasted.sourceIn, left.sourceIn);
    await ed.select(pasted.id);
    await ed.invoke(EditorActionId.duplicate);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 4, what: 'the duplicate');
    await ed.seekTo(ed.mainTrack.items.last.start);
    expect((await ed.barcode()).index, 0, reason: 'the duplicate starts at source frame 0');
    await E2eApp.screenshot(tester, 's04_after_edits');
    await ed.close();
  });
}
