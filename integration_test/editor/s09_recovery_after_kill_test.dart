// OWNER: QA-00
//
// ARCH §21.2 scenario 9: recovery after the app is killed. Two phases driven by tool/e2e_host.sh:
//
//   DV_E2E_PHASE=edit     create a project, make an edit, wait until the autosave journal has it
//                         (AutosavePhase.saved, nothing saved to the main file yet), then ask the
//                         host to kill the app (`xcrun simctl terminate` / `adb shell am force-stop`)
//                         while the editor is open in the foreground;
//   DV_E2E_PHASE=recover  relaunch: Projects offers the recovery, Restore brings the edit back.
//
// Run without a phase (or without a host driver) the test explains how to run it and passes no
// verdict on recovery.

// ignore_for_file: implementation_imports

import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show SavePhase;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SetText;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 9 (phase edit): edit, then the app is killed', (tester) async {
    await E2eApp.launch(tester);
    final stamp = DateTime.now().millisecondsSinceEpoch % 1000000;
    final ed = await E2eEditor.createProject(tester, name: 'E2E recovery $stamp', media: [E2eMedia.fixture(Fx.frameCounter)]);
    await ed.seekFrame(45);
    await ed.invoke(EditorActionId.addText);
    await ed.waitProject((p) => ed.items<TextItem>().isNotEmpty, what: 'the text');
    final marker = 'RECOVER $stamp';
    ed.apply(SetText(ed.items<TextItem>().single.id, marker));
    await E2eApp.pumpUntil(tester, () => ed.state.save.phase == SavePhase.saved, what: 'the autosave journal', timeout: const Duration(seconds: 30));
    E2eHandshake.saveState('s09', {'project': ed.id.value, 'marker': marker});
    await E2eHandshake.requestAndDie(tester, 'kill');
  }, skip: E2eConfig.phase != 'edit' || !E2eHandshake.available);

  testWidgets('scenario 9 (phase recover): Projects restores the killed session', (tester) async {
    final saved = E2eHandshake.loadState('s09');
    expect(saved, isNotNull, reason: 'run phase "edit" first');
    final id = ProjectId(saved!['project']! as String);
    final marker = saved['marker']! as String;
    await E2eApp.launch(tester);
    await E2eApp.openProjectsFromHome(tester);
    await E2eApp.waitKey(tester, 'recovery-$id');
    await E2eApp.screenshot(tester, 's09_recovery_offer');
    await E2eApp.tapKey(tester, 'recovery-restore-$id');
    if (find.byType(EditorScreen).evaluate().isEmpty) {
      await E2eApp.pumpUntil(tester, () => !E2eApp.hasKey('recovery-$id'), what: 'the restore to finish');
      await E2eApp.tapKey(tester, 'project-card-$id');
    }
    final ed = await E2eEditor.attach(tester);
    expect(ed.id, id);
    expect([for (final t in ed.items<TextItem>()) t.text], contains(marker));
    await ed.close();
  }, skip: E2eConfig.phase != 'recover');

  testWidgets('scenario 9 needs the host driver', (tester) async {
    // ignore: avoid_print
    print('DV_E2E_REPORT s09 skipped: run `integration_test/editor/tool/e2e_host.sh run s09` (phases edit, then recover)');
  }, skip: E2eConfig.phase == 'edit' || E2eConfig.phase == 'recover');
}
