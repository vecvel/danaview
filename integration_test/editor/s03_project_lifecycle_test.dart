// OWNER: QA-00
//
// ARCH §21.2 scenario 3: create, rename, duplicate and delete a project from the Projects screen.

import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_core/store.dart' show ProjectSummary;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

Future<List<ProjectSummary>> _summaries() => E2eApp.world.runtime.repository.watchSummaries().first;

Future<void> _menu(WidgetTester tester, String name, String item) async {
  await E2eApp.tap(tester, find.bySemanticsLabel('Project actions: $name'), what: 'actions of "$name"');
  await E2eApp.tap(tester, find.text(item).last, what: 'menu item $item');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 3: create, rename, duplicate, delete', (tester) async {
    await E2eApp.launch(tester);
    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    final name = 'E2E create $stamp';
    final ed = await E2eEditor.createProject(tester, name: name, media: [E2eMedia.fixture(Fx.frameCounter)]);
    expect(ed.project.name, name);
    expect(ed.mainTrack.items, hasLength(1));
    final id = ed.id;
    await ed.close();
    await E2eApp.pumpUntil(tester, () => find.byType(ProjectsScreen).evaluate().isNotEmpty, what: 'Projects');
    await E2eApp.waitKey(tester, 'project-card-$id');

    // Rename.
    final renamed = 'E2E renamed $stamp';
    await _menu(tester, name, 'Rename');
    await E2eApp.enterText(tester, 'rename-project-field', renamed);
    await E2eApp.tapKey(tester, 'rename-project-save');
    await E2eApp.pumpUntil(tester, () => find.text('Renamed to "$renamed"').evaluate().isNotEmpty, what: 'the rename toast');
    expect((await _summaries()).firstWhere((s) => s.id == id).name, renamed);

    // Duplicate.
    await _menu(tester, renamed, 'Duplicate');
    await E2eApp.pumpUntil(tester, () => find.text('Duplicated as "$renamed copy"').evaluate().isNotEmpty, what: 'the duplicate toast');
    final copies = (await _summaries()).where((s) => s.name == '$renamed copy').toList();
    expect(copies, hasLength(1));
    await E2eApp.screenshot(tester, 's03_renamed_and_duplicated');

    // Delete both (the deletion commits when the undo bar goes away).
    for (final (n, pid) in [(renamed, id), ('$renamed copy', copies.single.id)]) {
      await _menu(tester, n, 'Delete');
      await E2eApp.pumpUntil(tester, () => find.text('Delete "$n"?').evaluate().isNotEmpty, what: 'the delete confirmation');
      await E2eApp.tap(tester, find.text('Delete').last, what: 'confirm Delete');
      await E2eApp.pumpUntil(tester, () => find.text('Deleted "$n"').evaluate().isNotEmpty, what: 'the delete toast');
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while ((await _summaries()).any((s) => s.id == pid)) {
        if (DateTime.now().isAfter(deadline)) fail('"$n" was not deleted from the repository');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
      }
    }
  });
}
