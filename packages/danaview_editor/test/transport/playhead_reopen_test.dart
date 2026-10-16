// OWNER: FIX-UX-14-1
//
// QA-01 s18: closing and reopening a project restores the saved view playhead (ARCH §17.1,
// ViewState is persisted), and the preview is seeked there.

import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';

import 'playhead_provider_test.dart' show Wired;
import 'transport_rig.dart';

void main() {
  test('seek, close, reopen: the playhead and the preview are back on the saved frame', () async {
    final w = Wired.create();
    await w.editor.open();
    await w.settle();
    final rate = w.editor.session.committedProject!.settings.frameRate;
    final t = rate.timeOfFrame(77);
    await w.playhead.seekExact(t);
    await w.settle();
    expect(w.playhead.value, t);
    // Close right away: the debounced settle must still reach the saved view state.
    await w.editor.close();
    await w.settle();
    expect(w.repo.projects[w.id]?.view.playhead, t);

    await w.editor.open();
    await w.settle();
    expect(w.editor.session.committedProject!.view.playhead, t);
    expect(w.playhead.value, t);
    expect(w.preview.time, t);
  });
}
