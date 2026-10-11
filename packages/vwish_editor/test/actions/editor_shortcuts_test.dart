// OWNER: UX-15
//
// EditorShortcuts (ARCH §17.6, ux.md §15): every binding on iOS-, Android- and macOS-targeted
// platforms (⌘ is Command on Apple platforms, Ctrl elsewhere); the editor scope overrides Flutter's
// defaults (after a tool tile took focus, Space toggles playback and does not press the tile, and
// ←/→ step frames instead of moving focus); inside a text field Space and the arrows edit text and
// ⌘S still saves; the focus guard; key repeat; disabled actions swallow the key without running.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/actions/editor_action_registry.dart';
import 'package:vwish_editor/src/editor/actions/editor_shortcuts.dart';
import 'package:vwish_editor/src/editor/actions/shortcuts_sheet.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import 'action_test_support.dart';

const List<TargetPlatform> _platforms = [TargetPlatform.iOS, TargetPlatform.android, TargetPlatform.macOS];

Finder tile(String name) => find.byKey(ValueKey<String>('tile-$name'));

ShortcutsPlaygroundState playground(WidgetTester tester) => tester.state<ShortcutsPlaygroundState>(find.byType(ShortcutsPlayground));

void main() {
  final log = ActionLog();
  final presses = <String, int>{};
  setUp(() {
    log.clear();
    presses.clear();
  });

  Future<Keys> pump(WidgetTester tester, TargetPlatform platform, {Map<EditorActionId, EditorActionBinding>? bindings, TextEditingController? controller, FocusNode? field}) async {
    await pumpShortcuts(
      tester,
      ShortcutsPlayground(tilePresses: presses, controller: controller, fieldFocus: field),
      bindings: bindings ?? recordingBindings(log),
      platform: platform,
    );
    return Keys(tester, platform);
  }

  for (final platform in _platforms) {
    group('every binding on ${platform.name}', () {
      final registry = EditorActionRegistry(bindings: const {}, apple: isApple(platform));
      for (final spec in registry.shortcutSpecs) {
        for (final combo in spec.combos) {
          if (combo.rootOnly) continue;
          testWidgets('${spec.id.name}: ${combo.label(isApple(platform))}', (tester) async {
            final keys = await pump(tester, platform);
            await keys.pressCombo(combo);
            expect(log.ran, [spec.id], reason: '${combo.label(isApple(platform))} runs exactly ${spec.id.name}');
            expect(log.sources.single, EditorActionSource.keyboard);
          });
        }
      }

      testWidgets('⌘ is ${isApple(platform) ? 'Command' : 'Ctrl'}: the other modifier does nothing', (tester) async {
        final keys = await pump(tester, platform);
        final wrong = isApple(platform) ? LogicalKeyboardKey.controlLeft : LogicalKeyboardKey.metaLeft;
        await tester.sendKeyDownEvent(wrong);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(wrong);
        expect(log.ran, isEmpty);
        await keys.press(LogicalKeyboardKey.keyZ, command: true);
        expect(log.ran, [EditorActionId.undo]);
      });

      testWidgets('redo: ⇧⌘Z${isApple(platform) ? '' : ' and Ctrl+Y'}', (tester) async {
        final keys = await pump(tester, platform);
        await keys.press(LogicalKeyboardKey.keyZ, command: true, shift: true);
        expect(log.ran, [EditorActionId.redo]);
        log.clear();
        await keys.press(LogicalKeyboardKey.keyY, command: true);
        expect(log.ran, isApple(platform) ? isEmpty : [EditorActionId.redo]);
      });

      testWidgets('plain letters do not trigger ⌘ shortcuts and shifted letters do not trigger plain ones', (tester) async {
        final keys = await pump(tester, platform);
        await keys.press(LogicalKeyboardKey.keyS, shift: true);
        expect(log.ran, isEmpty, reason: 'Shift+S is not split');
        await keys.press(LogicalKeyboardKey.keyZ);
        expect(log.ran, isEmpty);
      });
    });
  }

  group('the editor scope overrides Flutter defaults', () {
    for (final platform in _platforms) {
      testWidgets('${platform.name}: after tapping a tool tile, Space toggles playback and does not press the tile', (tester) async {
        final keys = await pump(tester, platform);
        await tester.tap(tile('a'));
        await tester.pump();
        expect(presses['a'], 1);
        expect(playground(tester).tileA.hasPrimaryFocus, isTrue, reason: 'the tile holds focus after the tap');
        await keys.press(LogicalKeyboardKey.space);
        expect(log.ran, [EditorActionId.playPause]);
        expect(presses['a'], 1, reason: 'the tile was not pressed again');
        expect(playground(tester).tileA.hasPrimaryFocus, isTrue);
      });

      testWidgets('${platform.name}: after tapping a tool tile, ←/→ step one frame instead of moving focus', (tester) async {
        final keys = await pump(tester, platform);
        await tester.tap(tile('a'));
        await tester.pump();
        await keys.press(LogicalKeyboardKey.arrowRight);
        await keys.press(LogicalKeyboardKey.arrowLeft);
        expect(log.ran, [EditorActionId.nextFrame, EditorActionId.prevFrame]);
        expect(playground(tester).tileA.hasPrimaryFocus, isTrue, reason: 'Flutter\'s DirectionalFocusIntent did not move focus to the next tile');
        await keys.press(LogicalKeyboardKey.arrowDown);
        await keys.press(LogicalKeyboardKey.arrowUp);
        expect(playground(tester).tileA.hasPrimaryFocus, isTrue);
        expect(log.ran.sublist(2), [EditorActionId.nextEdit, EditorActionId.prevEdit]);
      });

      testWidgets('${platform.name}: Enter activates the focused tile; with no control focused it plays', (tester) async {
        final keys = await pump(tester, platform);
        await tester.tap(tile('b'));
        await tester.pump();
        await keys.press(LogicalKeyboardKey.enter);
        expect(presses['b'], 2, reason: 'Enter pressed the focused tile (accessibility)');
        expect(log.ran, isEmpty);
        playground(tester).tileB.unfocus();
        await tester.pump();
        await keys.press(LogicalKeyboardKey.enter);
        expect(log.ran, [EditorActionId.playPause]);
      });
    }

    testWidgets('Tab still moves focus between controls', (tester) async {
      final keys = await pump(tester, TargetPlatform.macOS);
      await tester.tap(tile('a'));
      await tester.pump();
      await keys.press(LogicalKeyboardKey.tab);
      expect(playground(tester).tileB.hasPrimaryFocus, isTrue);
      expect(log.ran, isEmpty);
    });

    testWidgets('shortcuts work when nothing has focus (after a sheet closed)', (tester) async {
      final keys = await pump(tester, TargetPlatform.android);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await keys.press(LogicalKeyboardKey.keyK);
      expect(log.ran, [EditorActionId.playPause]);
    });
  });

  group('the focus guard', () {
    for (final platform in _platforms) {
      testWidgets('${platform.name}: in a text field Space and the arrows edit text, ⌘S still saves', (tester) async {
        final controller = TextEditingController(text: 'abc');
        addTearDown(controller.dispose);
        final keys = await pump(tester, platform, controller: controller);
        await tester.tap(find.byKey(const ValueKey<String>('field')));
        await tester.pump();
        expect(EditorShortcuts.isTextFocus(FocusManager.instance.primaryFocus), isTrue);
        controller.selection = const TextSelection.collapsed(offset: 3);
        await keys.press(LogicalKeyboardKey.space);
        await keys.press(LogicalKeyboardKey.arrowLeft);
        await keys.press(LogicalKeyboardKey.keyK);
        await keys.press(LogicalKeyboardKey.backspace);
        await keys.press(LogicalKeyboardKey.delete);
        await keys.press(LogicalKeyboardKey.keyS);
        await keys.press(LogicalKeyboardKey.arrowDown);
        await keys.press(LogicalKeyboardKey.home);
        expect(log.ran, isEmpty, reason: 'no editor action ran while typing');
        expect(controller.selection.baseOffset, lessThan(3), reason: 'the arrow moved the caret (the field handled it)');
        await keys.press(LogicalKeyboardKey.keyS, command: true);
        expect(log.ran, [EditorActionId.save], reason: '⌘S works even in a text field');
        await keys.press(LogicalKeyboardKey.escape);
        expect(log.ran, [EditorActionId.save, EditorActionId.escape]);
        log.clear();
        // Cut, copy, paste and select all belong to the text field here.
        for (final key in [LogicalKeyboardKey.keyC, LogicalKeyboardKey.keyX, LogicalKeyboardKey.keyV, LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyZ]) {
          await keys.press(key, command: true);
        }
        expect(log.ran, isEmpty);
      });
    }

    testWidgets('typed text reaches the field while the editor scope is active', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, TargetPlatform.android, controller: controller);
      await tester.tap(find.byKey(const ValueKey<String>('field')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey<String>('field')), 'a b');
      expect(controller.text, 'a b');
      expect(log.ran, isEmpty);
    });

    testWidgets('leaving the field resumes shortcuts', (tester) async {
      final keys = await pump(tester, TargetPlatform.android);
      await tester.tap(find.byKey(const ValueKey<String>('field')));
      await tester.pump();
      await keys.press(LogicalKeyboardKey.space);
      expect(log.ran, isEmpty);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await keys.press(LogicalKeyboardKey.space);
      expect(log.ran, [EditorActionId.playPause]);
    });

    testWidgets('keys in another route (a sheet or dialog) are not the editor\'s', (tester) async {
      final keys = await pump(tester, TargetPlatform.android);
      final context = tester.element(find.byType(ShortcutsPlayground));
      final pressedInSheet = <int>[0];
      // ignore: unawaited_futures
      showVwishSheet<void>(
        context,
        title: 'Sheet',
        builder: (context) => VwishPressable(
          autofocus: true,
          semanticLabel: 'Sheet action',
          onTap: () => pressedInSheet[0]++,
          child: const SizedBox(width: 100, height: 48, child: Center(child: Text('Press'))),
        ),
      );
      await tester.pumpAndSettle();
      await keys.press(LogicalKeyboardKey.space);
      await keys.press(LogicalKeyboardKey.arrowRight);
      await keys.press(LogicalKeyboardKey.keyS);
      expect(log.ran, isEmpty, reason: 'no editor action ran under the sheet');
      expect(pressedInSheet[0], 1, reason: 'Space pressed the sheet\'s own focused button');
    });

    testWidgets('an open menu keeps its keys', (tester) async {
      final keys = await pump(tester, TargetPlatform.android);
      // A menu is its own focus scope inside the editor's subtree.
      final context = tester.element(find.byType(ShortcutsPlayground));
      final scope = FocusScopeNode(debugLabel: 'menu');
      addTearDown(scope.dispose);
      late FocusNode inner;
      await tester.pumpWidget(Container()); // reset
      await pumpShortcuts(
        tester,
        FocusScope(
          node: scope,
          child: Focus(
            autofocus: true,
            child: Builder(builder: (c) {
              inner = Focus.of(c);
              return const SizedBox(width: 50, height: 50);
            }),
          ),
        ),
        bindings: recordingBindings(log),
        platform: TargetPlatform.android,
      );
      scope.requestFocus(inner);
      await tester.pump();
      expect(context, isNotNull);
      await keys.press(LogicalKeyboardKey.space);
      await keys.press(LogicalKeyboardKey.arrowDown);
      expect(log.ran, isEmpty, reason: 'focus is in a nested scope (an open menu): the menu owns the keys');
    });
  });

  group('key repeat', () {
    testWidgets('frame steps, edit points, undo and zoom repeat; other actions run once', (tester) async {
      final keys = await pump(tester, TargetPlatform.android);
      await keys.hold(LogicalKeyboardKey.arrowRight, repeats: 3);
      expect(log.count(EditorActionId.nextFrame), 4, reason: 'the press and 3 repeats');
      log.clear();
      await keys.hold(LogicalKeyboardKey.keyK, repeats: 3);
      expect(log.count(EditorActionId.playPause), 1, reason: 'holding K must not toggle playback again and again');
      log.clear();
      await keys.hold(LogicalKeyboardKey.keyS, repeats: 3);
      expect(log.count(EditorActionId.split), 1);
      log.clear();
      await keys.hold(LogicalKeyboardKey.backspace, repeats: 3);
      expect(log.count(EditorActionId.delete), 1);
      log.clear();
      await keys.hold(LogicalKeyboardKey.arrowDown, repeats: 2);
      expect(log.count(EditorActionId.nextEdit), 3);
    });
  });

  group('disabled and unbound actions', () {
    testWidgets('a disabled action swallows its key without running', (tester) async {
      final keys = await pump(tester, TargetPlatform.android, bindings: recordingBindings(log, disabled: {EditorActionId.playPause}));
      await tester.tap(tile('a'));
      await tester.pump();
      await keys.press(LogicalKeyboardKey.space);
      expect(log.ran, isEmpty);
      expect(presses['a'], 1, reason: 'the focused tile is not pressed by a key the editor owns');
    });

    testWidgets('an unbound action does nothing', (tester) async {
      final keys = await pump(tester, TargetPlatform.android, bindings: recordingBindings(log, skip: {EditorActionId.split}));
      await keys.press(LogicalKeyboardKey.keyS);
      expect(log.ran, isEmpty);
    });

    testWidgets('the built-in shortcuts sheet opens with ? and ⌘/', (tester) async {
      final keys = await pump(tester, TargetPlatform.macOS, bindings: const {});
      await keys.pressCombo(const EditorKeyCombo.character('?'));
      await tester.pumpAndSettle();
      expect(find.byType(ShortcutsSheet), findsOneWidget);
    });
  });

  group('actions by intent', () {
    testWidgets('Actions.invoke(EditorActionIntent) runs the action through the registry', (tester) async {
      await pump(tester, TargetPlatform.android);
      final context = tester.element(find.byType(ShortcutsPlayground));
      Actions.invoke(context, const EditorActionIntent(EditorActionId.split));
      expect(log.ran, [EditorActionId.split]);
    });
  });

  testWidgets('the focus root does not become a tab stop', (tester) async {
    final keys = await pump(tester, TargetPlatform.android);
    await keys.press(LogicalKeyboardKey.tab);
    final primary = FocusManager.instance.primaryFocus;
    expect(primary?.debugLabel, isNot('EditorShortcuts'));
  });

  testWidgets('an icon stays an icon (sanity of the playground)', (tester) async {
    await pump(tester, TargetPlatform.android);
    expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
  });
}
