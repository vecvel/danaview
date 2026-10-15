// OWNER: QA-00
//
// Android API 28 below-gate checks (ARCH §21.2, QA-02): built with DANAVIEW_EDITOR=true on an API 28
// emulator, the Home edit button shows, Projects shows the `android_too_old` copy, and the player's
// Edit explains instead of opening the editor. The rest of the player suite is the existing
// integration_test/ files. Runs the stock app entry point, since the editor cannot be wired there.

import 'dart:io';

import 'package:danaview/main.dart' as app;
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final below = EditorAvailability.platform is! EditorSupported;

  testWidgets('API 28: Home button, Projects explains, player Edit explains', (tester) async {
    await app.main();
    await E2eApp.pumpUntil(tester, () => find.byType(DanaviewHomeScreen).evaluate().isNotEmpty, what: 'Home');
    expect(find.bySemanticsLabel('Open video editor'), findsOneWidget);
    await E2eApp.tap(tester, find.bySemanticsLabel('Open video editor'), what: 'Home edit button');
    await E2eApp.waitKey(tester, 'projects-unsupported');
    expect(find.textContaining('Android'), findsWidgets, reason: 'the android_too_old copy names the Android version');
    await E2eApp.screenshot(tester, 'api28_projects');
    Navigator.of(tester.element(find.byType(ProjectsScreen))).maybePop();
    await E2eApp.pumpUntil(tester, () => find.byType(DanaviewHomeScreen).hitTestable().evaluate().isNotEmpty, what: 'Home again');

    // Player › Edit explains (a message, no editor).
    final dir = Directory('${E2eConfig.hostSharedDir}/e2e_fixtures');
    final clip = File('${dir.path}/${Fx.frameCounter}');
    expect(clip.existsSync(), isTrue, reason: 'stage the fixtures (tool/e2e_host.sh stage)');
    final c = ProviderScope.containerOf(tester.element(find.byType(DanaviewHomeScreen)), listen: false);
    await c.read(queueControllerProvider.notifier).playFrom([MediaRef(id: 'e2e-api28', title: 'frame counter', pathOrUri: clip.path)]);
    GoRouter.of(tester.element(find.byType(DanaviewHomeScreen))).push('/player');
    await E2eApp.pumpUntil(tester, () => c.read(playerControllerProvider).duration > Duration.zero, what: 'the player');
    final edit = find.byKey(const ValueKey('player-edit-video'));
    if (edit.hitTestable().evaluate().isEmpty) await E2eApp.tap(tester, find.byType(DanaviewPlayerScreen), what: 'player surface');
    await E2eApp.pumpUntil(tester, () => edit.hitTestable().evaluate().isNotEmpty, what: 'the Edit button');
    await E2eApp.tap(tester, edit, what: 'player Edit');
    await E2eApp.pumpUntil(tester, () => find.textContaining('Android').evaluate().isNotEmpty, what: 'the explanation');
    expect(find.byType(EditorScreen), findsNothing);
    await E2eApp.screenshot(tester, 'api28_player_edit');
  }, skip: !Platform.isAndroid || !below);
}
