// OWNER: QA-00
//
// ARCH §21.2 scenario 2: player → Edit on frame_counter_1080p30.mp4 at 0:05:10 opens the editor
// with the playhead at 5 s + 10 frames and the captured preview frame's barcode equal to 160.

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 2: player Edit at 0:05:10 opens the editor at frame 160', (tester) async {
    await E2eApp.launch(tester);
    final path = E2eMedia.uniqueCopy(Fx.frameCounter, 's02');
    final c = E2eApp.container(tester);
    await c.read(queueControllerProvider.notifier).playFrom([
      MediaRef(id: 'e2e-s02-${path.hashCode}', title: 'frame counter', pathOrUri: path),
    ]);
    GoRouter.of(tester.element(find.byType(DanaviewHomeScreen))).push('/player');
    await E2eApp.pumpUntil(tester, () => c.read(playerControllerProvider).duration > Duration.zero, what: 'the player to open the file');

    // 0:05:10 = 5 s + 10 frames at 30 fps.
    const at = Duration(microseconds: 5333334);
    final player = c.read(playerControllerProvider.notifier);
    await player.pause();
    await player.seek(at, mode: SeekMode.exact);
    await E2eApp.pumpUntil(
      tester,
      () => (c.read(playerControllerProvider).position - at).abs() < const Duration(milliseconds: 17),
      what: 'the player position to reach 0:05:10',
    );

    final edit = find.byKey(const ValueKey('player-edit-video'));
    if (edit.hitTestable().evaluate().isEmpty) {
      // Controls hidden: a tap on the video shows them.
      await E2eApp.tap(tester, find.byType(DanaviewPlayerScreen), what: 'player surface');
      await E2eApp.pumpUntil(tester, () => edit.hitTestable().evaluate().isNotEmpty, what: 'the Edit button');
    }
    final handedOver = c.read(playerControllerProvider).position;
    await E2eApp.tap(tester, edit, what: 'player Edit');
    final ed = await E2eEditor.attach(tester);
    expect(
      ed.playheadFrame,
      160,
      reason: 'playhead ${ed.playhead.value} us; player position at Edit ${handedOver.inMicroseconds} us; '
          'project view.playhead ${ed.project.view.playhead} us, duration ${ed.project.duration} us, '
          '${ed.mainTrack.items.length} clip(s)',
    );
    final reading = await ed.barcode();
    expect(reading.index, 160, reason: '$reading');
    await E2eApp.screenshot(tester, 's02_editor_at_160');
    await ed.close();
  });
}
