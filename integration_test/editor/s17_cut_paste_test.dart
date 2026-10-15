// OWNER: QA-00
//
// ARCH §21.2 scenario 17: ⌘X cuts (copy + delete, D-16), then ⌘V pastes it back at the playhead.

import 'package:danaview_editor_core/model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 17: ⌘X cut, then paste', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(tester, name: 'E2E cut ${DateTime.now().millisecondsSinceEpoch % 100000}', media: [E2eMedia.fixture(Fx.frameCounter)]);
    final r = ed.rate;
    await ed.select(ed.mainTrack.items.single.id);
    await ed.seekFrame(60);
    await ed.key(LogicalKeyboardKey.keyS);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 2, what: 'the split');
    final first = ed.mainTrack.items.first as MediaClip;

    await ed.select(first.id);
    await ed.key(LogicalKeyboardKey.keyX, command: true);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 1, what: '⌘X to remove the clip');
    expect(ed.mainTrack.items.single.start, 0, reason: 'the cut ripples on the main track');
    await ed.seekFrame(0);
    expect((await ed.barcode()).index, 60);

    await ed.seekTo(ed.project.duration);
    await ed.key(LogicalKeyboardKey.keyV, command: true);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 2, what: '⌘V to paste the cut clip');
    final pasted = ed.mainTrack.items.last as MediaClip;
    expect((pasted.sourceIn, pasted.duration), (first.sourceIn, first.duration));
    await ed.seekTo(pasted.start + r.timeOfFrame(5));
    expect((await ed.barcode()).index, 5);
    await ed.close();
  });
}
