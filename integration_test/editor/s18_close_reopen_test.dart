// OWNER: QA-00
//
// ARCH §21.2 scenario 18: close and reopen a project: the timeline JSON, the playhead and the zoom
// come back equal.

// ignore_for_file: implementation_imports

import 'dart:convert';

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

/// The project body without the parts that legitimately change on a save (meta times, counters).
String timelineJson(EditProject p) {
  final j = ProjectJsonCodec().toJson(p)..remove('meta')..remove('view')..remove('docRev');
  return jsonEncode(j);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 18: close and reopen keeps timeline, playhead and zoom', (tester) async {
    await E2eApp.launch(tester);
    var ed = await E2eEditor.createProject(
      tester,
      name: 'E2E reopen ${DateTime.now().millisecondsSinceEpoch % 100000}',
      media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech)],
    );
    final id = ed.id;
    await ed.select(ed.mainTrack.items.single.id);
    await ed.seekFrame(90);
    await ed.key(LogicalKeyboardKey.keyS);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 2, what: 'the split');
    await ed.key(LogicalKeyboardKey.keyM);
    await ed.invoke(EditorActionId.addText);
    await ed.waitProject((p) => ed.items<TextItem>().isNotEmpty && p.markers.isNotEmpty, what: 'text and marker');
    await ed.invoke(EditorActionId.zoomIn);
    await ed.invoke(EditorActionId.zoomIn);
    await ed.seekFrame(77);
    final json = timelineJson(ed.project);
    final playhead = ed.playhead.value;
    final zoom = ed.viewport.pxPerSecond;
    await ed.close();

    ed = await E2eEditor.openFromProjects(tester, id);
    expect(timelineJson(ed.project), json);
    expect(ed.playhead.value, playhead);
    expect(ed.viewport.pxPerSecond, closeTo(zoom, 0.001));
    expect((await ed.barcode()).index, 77);
    await ed.close();
  });
}
