// OWNER: QA-00
//
// ARCH §21.2 scenario 16: add a marker (M) and snap a clip to it with a timeline drag.

// ignore_for_file: implementation_imports

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 16: add a marker and snap a clip to it', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(tester, name: 'E2E marker ${DateTime.now().millisecondsSinceEpoch % 100000}', media: [E2eMedia.fixture(Fx.frameCounter)]);
    final r = ed.rate;

    await ed.seekFrame(75);
    await ed.key(LogicalKeyboardKey.keyM);
    await ed.waitProject((p) => p.markers.isNotEmpty, what: 'the marker (M)');
    expect(ed.project.markers.single.time, r.timeOfFrame(75));

    // An overlay-free item to move: a text at 4 s, dragged so its start lands 5 px past the marker.
    await ed.seekFrame(120);
    await ed.invoke(EditorActionId.addText);
    await ed.waitProject((p) => ed.items<TextItem>().isNotEmpty, what: 'the text');
    final text = ed.items<TextItem>().single;
    await ed.seekFrame(0);
    await ed.dragMove(text.id, r.timeOfFrame(75), overshootPx: 5);
    await ed.waitProject((p) => ed.item(text.id).start == r.timeOfFrame(75), what: 'the text snapped to the marker (at ${ed.item(text.id).start})');
    await E2eApp.screenshot(tester, 's16_snapped_to_marker');
    await ed.close();
  });
}
