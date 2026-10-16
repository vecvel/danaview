// OWNER: FIX-UX-14-1
//
// QA-01 s18: closing and reopening a project restores the saved view playhead (ARCH §17.1: the
// view state is persisted, not history) and seeks the preview there. A seek right before "Close
// editor" is still debounced (UX-14 settles frame steps after 150 ms), so the editor writes it
// before its close save.

import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'playhead_provider_test.dart' show Wired;

void main() {
  test('seek, close at once, reopen: the playhead and the preview are back on the saved frame', () async {
    final w = Wired.create();
    await w.editor.open();
    await w.settle();
    final rate = w.editor.session.committedProject!.settings.frameRate;
    final t = rate.timeOfFrame(77);
    await w.playhead.seekExact(t);
    await w.settle();
    expect(w.playhead.value, t);
    // Close inside the settle debounce: the pending write must reach the close save.
    await w.editor.close();
    await w.settle();
    expect(w.repo.projects[w.id]?.view.playhead, t, reason: 'the close save holds the playhead');

    await w.editor.open();
    await w.settle();
    expect(w.editor.session.committedProject!.view.playhead, t);
    expect(w.playhead.value, t);
    expect(w.preview.time, t, reason: 'the reopened preview is seeked to the saved playhead');
    await w.editor.close();
  });

  test('a fresh container (the app restarted) reopens on the saved frame', () async {
    final w = Wired.create();
    final first = ProviderContainer(overrides: w.harness.overrides);
    addTearDown(first.dispose);
    final sub = first.listen(playheadProvider(w.id), (a, b) {});
    await first.read(editorControllerProvider(w.id).notifier).open();
    await w.settle();
    final rate = first.read(editorControllerProvider(w.id).notifier).session.committedProject!.settings.frameRate;
    final t = rate.timeOfFrame(77);
    await first.read(playheadProvider(w.id)).seekExact(t);
    await first.read(editorControllerProvider(w.id).notifier).close();
    sub.close();
    await w.settle();

    final second = ProviderContainer(overrides: w.harness.overrides);
    addTearDown(second.dispose);
    final PlayheadController playhead = second.read(playheadProvider(w.id)); // before the open, like the screen
    expect(playhead.value, 0);
    await second.read(editorControllerProvider(w.id).notifier).open();
    await w.settle();
    expect(second.read(playheadProvider(w.id)).value, t);
    expect(w.preview.time, t);
    await second.read(editorControllerProvider(w.id).notifier).close();
  });

  test('a seek still debounced when the app is hidden is in the lifecycle save', () async {
    final w = Wired.create();
    await w.editor.open();
    await w.settle();
    final t = w.editor.session.committedProject!.settings.frameRate.timeOfFrame(40);
    await w.playhead.seekExact(t);
    await w.settle();
    w.editor.onAppHidden();
    await w.settle();
    expect(w.repo.projects[w.id]?.view.playhead, t);
    await w.editor.close();
  });
}
