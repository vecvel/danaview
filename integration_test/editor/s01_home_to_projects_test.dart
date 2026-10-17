// OWNER: QA-00
//
// ARCH §21.2 scenario 1: the Home edit button sits left of the Settings gear and opens Projects.

import 'package:danaview_editor/danaview_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 1: Home edit button left of the gear opens Projects', (tester) async {
    await E2eApp.launch(tester);
    final edit = find.bySemanticsLabel('Open video editor');
    final gear = find.byTooltip('Settings');
    expect(edit, findsOneWidget);
    expect(gear, findsWidgets);
    final e = tester.getRect(edit);
    final g = tester.getRect(gear.first);
    expect(e.right, lessThanOrEqualTo(g.left + 0.5), reason: 'edit button $e must be left of the gear $g');
    expect((e.center.dy - g.center.dy).abs(), lessThan(4), reason: 'same row');
    await E2eApp.openProjectsFromHome(tester);
    expect(find.byType(ProjectsScreen), findsOneWidget);
    await E2eApp.screenshot(tester, 's01_projects');
  });
}
