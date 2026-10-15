// OWNER: QA-00 (temporary probe, deleted after use)
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('probe', (tester) async {
    await E2eApp.launch(tester);
    final media = [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.toneUnderVideo)];
    await E2eApp.openProjectsFromHome(tester);
    await E2eApp.tapKey(tester, 'projects-new');
    await E2eApp.waitKey(tester, 'new-project-sheet');
    E2eApp.world.engine.picker.queue(media);
    await E2eApp.tapKey(tester, 'new-project-files');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      debugPrint('PROBE after pick $i: ${E2eApp.describeScreen()}');
    }
    await E2eApp.enterText(tester, 'new-project-name', 'probe two');
    await E2eApp.tapKey(tester, 'new-project-create');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 1000));
      debugPrint('PROBE after create $i: ${E2eApp.describeScreen()}');
    }
  });
}
