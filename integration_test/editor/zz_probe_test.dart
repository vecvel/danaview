// OWNER: QA-00 (temporary probe, deleted after use)
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('focus probe', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(tester, name: 'probe focus', media: [E2eMedia.fixture(Fx.frameCounter)]);
    debugPrint('PROBE focus primary=${FocusManager.instance.primaryFocus} highlight=${FocusManager.instance.highlightMode}');
    final seen = <String>[];
    bool h(KeyEvent e) { seen.add('${e.runtimeType} ${e.logicalKey.keyLabel}'); return false; }
    HardwareKeyboard.instance.addHandler(h);
    FocusManager.instance.addEarlyKeyEventHandler((e) { seen.add('early ${e.runtimeType}'); return KeyEventResult.ignored; });
    await ed.key(LogicalKeyboardKey.space);
    debugPrint('PROBE seen=$seen');
    await tester.sendKeyEvent(LogicalKeyboardKey.space, platform: 'ios');
    await tester.pump(const Duration(seconds: 1));
    debugPrint('PROBE after ios-platform key: playing=${ed.playhead.playing.value} seen=$seen');
    await tester.pump(const Duration(seconds: 1));
    final node = tester.widgetList<Focus>(find.byType(Focus)).map((f) => f.focusNode).whereType<FocusNode>().firstWhere((n) => n.debugLabel == 'EditorShortcuts');
    debugPrint('PROBE editor node scope=${node.nearestScope} primaryIsAncestorScope=${FocusManager.instance.primaryFocus == node.nearestScope}');
    node.requestFocus();
    await tester.pump();
    await ed.key(LogicalKeyboardKey.space);
    await tester.pump(const Duration(seconds: 1));
    debugPrint('PROBE after focusing the editor node: playing=${ed.playhead.playing.value}');
    debugPrint('PROBE playing=${ed.playhead.playing.value} primary=${FocusManager.instance.primaryFocus}');
  });
}
