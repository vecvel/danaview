// OWNER: QA-00
//
// ARCH §21.2 scenario 12: hardware keyboard and pointer. Key events go through the engine's
// keyboard pipeline (`sendKeyEvent`: the same `Shortcuts` the hardware keyboard of an iPad
// simulator / tablet emulator reaches); pointer events are real mouse pointer events on the
// timeline canvas. Covered: Space/K, ←/→ frame step (barcode-checked), Shift+←/→, S,
// Delete/Backspace, ⌘/Ctrl+Z, ⌘/Ctrl+Shift+Z, ⌘S inside a text field, ⌘C/⌘V/⌘D, Space after
// tapping a tool tile, wheel / Shift+wheel / ⌘+wheel zoom, right-click menu and marquee.

// ignore_for_file: implementation_imports

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show SavePhase;
import 'package:danaview_editor_core/model.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 12: hardware keyboard and pointer', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(tester, name: 'E2E keyboard ${DateTime.now().millisecondsSinceEpoch % 100000}', media: [E2eMedia.fixture(Fx.frameCounter)]);
    final r = ed.rate;
    int count() => ed.mainTrack.items.length;

    // Space plays, K pauses.
    await ed.seekFrame(30);
    await ed.key(LogicalKeyboardKey.space);
    await ed.waitPlaying(true);
    await ed.key(LogicalKeyboardKey.keyK);
    await ed.waitPlaying(false);

    // ← / → step one frame (barcode-checked), Shift+← / → one second.
    await ed.seekFrame(100);
    await ed.key(LogicalKeyboardKey.arrowRight);
    await E2eApp.pumpUntil(tester, () => ed.playheadFrame == 101 && !ed.playhead.isSeeking, what: 'frame 101');
    expect((await ed.barcode()).index, 101);
    await ed.key(LogicalKeyboardKey.arrowLeft);
    await E2eApp.pumpUntil(tester, () => ed.playheadFrame == 100 && !ed.playhead.isSeeking, what: 'frame 100');
    expect((await ed.barcode()).index, 100);
    await ed.key(LogicalKeyboardKey.arrowRight, shift: true);
    await E2eApp.pumpUntil(tester, () => ed.playheadFrame == 130 && !ed.playhead.isSeeking, what: 'frame 130');
    expect((await ed.barcode()).index, 130);
    await ed.key(LogicalKeyboardKey.arrowLeft, shift: true);
    await E2eApp.pumpUntil(tester, () => ed.playheadFrame == 100 && !ed.playhead.isSeeking, what: 'frame 100 again');

    // S splits the selected clip at the playhead.
    await ed.select(ed.mainTrack.items.single.id);
    await ed.key(LogicalKeyboardKey.keyS);
    await ed.waitProject((p) => count() == 2, what: 'S to split');
    expect(ed.mainTrack.items.first.end, r.timeOfFrame(100));

    // Delete and Backspace delete; ⌘Z / ⌘⇧Z undo and redo.
    await ed.select(ed.mainTrack.items.last.id);
    await ed.key(LogicalKeyboardKey.delete);
    await ed.waitProject((p) => count() == 1, what: 'Delete');
    await ed.key(LogicalKeyboardKey.keyZ, command: true);
    await ed.waitProject((p) => count() == 2, what: '⌘Z');
    await ed.key(LogicalKeyboardKey.keyZ, command: true, shift: true);
    await ed.waitProject((p) => count() == 1, what: '⌘⇧Z');
    await ed.key(LogicalKeyboardKey.keyZ, command: true);
    await ed.waitProject((p) => count() == 2, what: '⌘Z again');
    await ed.select(ed.mainTrack.items.last.id);
    await ed.key(LogicalKeyboardKey.backspace);
    await ed.waitProject((p) => count() == 1, what: 'Backspace');
    await ed.key(LogicalKeyboardKey.keyZ, command: true);
    await ed.waitProject((p) => count() == 2, what: '⌘Z after Backspace');

    // ⌘C / ⌘V / ⌘D.
    await ed.select(ed.mainTrack.items.first.id);
    await ed.key(LogicalKeyboardKey.keyC, command: true);
    await ed.seekTo(ed.project.duration);
    await ed.key(LogicalKeyboardKey.keyV, command: true);
    await ed.waitProject((p) => count() == 3, what: '⌘V');
    await ed.select(ed.mainTrack.items.last.id);
    await ed.key(LogicalKeyboardKey.keyD, command: true);
    await ed.waitProject((p) => count() == 4, what: '⌘D');

    // ⌘S inside a text field saves and types nothing.
    await ed.seekFrame(15);
    await ed.invoke(EditorActionId.addText);
    await ed.waitProject((p) => ed.items<TextItem>().isNotEmpty, what: 'a text item');
    await E2eApp.pumpUntil(tester, () => find.byType(EditableText).evaluate().isNotEmpty, what: 'the text panel field');
    final field = find.byType(EditableText).first;
    await E2eApp.tap(tester, field, what: 'text field');
    final before = tester.widget<EditableText>(field).controller.text;
    await E2eApp.pumpUntil(tester, () => ed.state.save.phase == SavePhase.saved, what: 'the autosave before ⌘S');
    final savedAt = ed.state.save.at;
    await ed.key(LogicalKeyboardKey.keyS, command: true);
    await E2eApp.pumpUntil(tester, () => ed.state.save.phase == SavePhase.saved && ed.state.save.at != savedAt, what: '⌘S to save');
    expect(tester.widget<EditableText>(field).controller.text, before, reason: '⌘S must not type into the field');
    await ed.key(LogicalKeyboardKey.escape);
    await ed.key(LogicalKeyboardKey.escape);
    ed.controller.clearSelection();
    await tester.pump();

    // Space after tapping a tool tile still toggles playback.
    await ed.tapTile('tool.format');
    await ed.key(LogicalKeyboardKey.escape);
    await ed.key(LogicalKeyboardKey.space);
    await ed.waitPlaying(true);
    await ed.key(LogicalKeyboardKey.space);
    await ed.waitPlaying(false);

    // Wheel scrolls, Shift+wheel scrolls in time, ⌘+wheel zooms.
    final main = ed.mainTrack;
    final over = ed.laneAt(main.id, r.timeOfFrame(30));
    final pps0 = ed.viewport.pxPerSecond;
    await ed.wheel(over, 120, command: true);
    await E2eApp.pumpUntil(tester, () => ed.viewport.pxPerSecond != pps0, what: '⌘+wheel zoom');
    await ed.invoke(EditorActionId.zoomIn);
    await ed.invoke(EditorActionId.zoomIn);
    final pps1 = ed.viewport.pxPerSecond;
    final scroll0 = ed.viewport.scrollTimeSec;
    await ed.wheel(ed.laneAt(main.id, r.timeOfFrame(30)), 200, shift: true);
    await E2eApp.pumpUntil(tester, () => ed.viewport.scrollTimeSec != scroll0, what: 'Shift+wheel horizontal scroll');
    final scroll1 = ed.viewport.scrollTimeSec;
    await ed.wheel(ed.laneAt(main.id, r.timeOfFrame(30)), -200);
    await tester.pump(const Duration(milliseconds: 100));
    expect(ed.viewport.pxPerSecond, pps1, reason: 'a plain wheel does not zoom');
    // ignore: avoid_print
    print('DV_E2E_REPORT s12 wheel: zoom $pps0 -> $pps1 px/s, scroll $scroll0 -> $scroll1 -> ${ed.viewport.scrollTimeSec} s');
    await ed.invoke(EditorActionId.zoomFit);

    // Right-click opens the clip's context menu.
    final clip = ed.mainTrack.items.first;
    await ed.rightClick(ed.laneAt(main.id, clip.start + clip.duration ~/ 2));
    await E2eApp.pumpUntil(tester, () => find.text('Split').evaluate().isNotEmpty || find.text('Delete').evaluate().isNotEmpty, what: 'the context menu');
    await E2eApp.screenshot(tester, 's12_context_menu');
    await ed.key(LogicalKeyboardKey.escape);
    ed.controller.clearSelection();
    await tester.pump();

    // Marquee from past the end of the main lane back over the last two clips.
    final items = ed.mainTrack.items;
    final from = ed.laneAt(main.id, ed.project.duration + 500000);
    final to = ed.laneAt(main.id, items[items.length - 2].start + 100000) + const Offset(0, 4);
    await ed.mouseDrag(from, to);
    await E2eApp.pumpUntil(tester, () => ed.state.selection.items.length >= 2, what: 'the marquee selection (got ${ed.state.selection.items})');
    await ed.close();
  });
}
