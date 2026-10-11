// OWNER: UX-15
//
// Helpers for the action registry, shortcuts and shortcuts-sheet tests: recording bindings for
// every action, platform key sending (⌘ is Command on Apple platforms and Ctrl elsewhere), and a
// harness that mounts `EditorShortcuts` with a focusable tool tile and a text field.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/actions/editor_action_registry.dart';
import 'package:vwish_editor/src/editor/actions/editor_shortcuts.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/editor_scope.dart';
import 'package:vwish_editor/src/editor/wiring/action_bindings.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../support/support.dart';

/// Every call a recording binding received, in order.
class ActionLog {
  /// Ids of the handlers that ran.
  final List<EditorActionId> ran = [];

  /// Sources the handlers saw.
  final List<EditorActionSource> sources = [];

  /// How many times [id] ran.
  int count(EditorActionId id) => ran.where((i) => i == id).length;

  /// Clears the log.
  void clear() {
    ran.clear();
    sources.clear();
  }
}

/// A binding for every action that records into [log]. [disabled] actions are bound but refuse to
/// run, with the reason `Not now: <id>`.
Map<EditorActionId, EditorActionBinding> recordingBindings(ActionLog log, {Set<EditorActionId> disabled = const {}, Set<EditorActionId> skip = const {}}) => {
      for (final id in EditorActionId.values)
        if (!skip.contains(id))
          id: EditorActionBinding(
            id: id,
            handler: (ctx) {
              log.ran.add(id);
              log.sources.add(ctx.source);
            },
            isEnabled: disabled.contains(id) ? (_) => false : null,
            disabledReason: disabled.contains(id) ? (_) => 'Not now: ${id.name}' : null,
          ),
    };

/// Whether `⌘` is Command on [platform].
bool isApple(TargetPlatform platform) => platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

/// Key press helpers for a platform.
class Keys {
  /// Creates the helper for [tester] on [platform].
  Keys(this.tester, this.platform);

  /// The tester.
  final WidgetTester tester;

  /// The platform (decides whether ⌘ is Command or Ctrl).
  final TargetPlatform platform;

  LogicalKeyboardKey get _command => isApple(platform) ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;

  /// Presses [key] (down and up) with the given modifiers held.
  Future<void> press(LogicalKeyboardKey key, {bool command = false, bool shift = false, String? character}) async {
    if (command) await tester.sendKeyDownEvent(_command);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(key, character: character);
    await tester.sendKeyUpEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (command) await tester.sendKeyUpEvent(_command);
    await tester.pump();
  }

  /// Holds [key]: a down event followed by [repeats] repeat events, then up.
  Future<void> hold(LogicalKeyboardKey key, {int repeats = 3}) async {
    await tester.sendKeyDownEvent(key);
    for (var i = 0; i < repeats; i++) {
      await tester.sendKeyRepeatEvent(key);
    }
    await tester.sendKeyUpEvent(key);
    await tester.pump();
  }

  /// Presses one combo of the registry.
  Future<void> pressCombo(EditorKeyCombo combo) async {
    final character = combo.character;
    if (character != null) {
      // `?` is Shift+/ on a US layout.
      await press(LogicalKeyboardKey.slash, shift: true, character: character);
      return;
    }
    await press(combo.key!, command: combo.command, shift: combo.shift);
  }
}

/// Content for `EditorShortcuts`: two tool tiles that take focus when tapped, a text field and a
/// plain area. Presses are counted in [tilePresses].
class ShortcutsPlayground extends StatefulWidget {
  /// Creates the playground.
  const ShortcutsPlayground({super.key, required this.tilePresses, this.controller, this.fieldFocus});

  /// Counts presses of the tiles (`a`, `b`).
  final Map<String, int> tilePresses;

  /// The text field's controller.
  final TextEditingController? controller;

  /// The text field's focus node.
  final FocusNode? fieldFocus;

  @override
  State<ShortcutsPlayground> createState() => ShortcutsPlaygroundState();
}

/// State of the playground: exposes the tiles' focus nodes.
class ShortcutsPlaygroundState extends State<ShortcutsPlayground> {
  /// Focus node of tile `a`.
  final FocusNode tileA = FocusNode(debugLabel: 'tile a');

  /// Focus node of tile `b`.
  final FocusNode tileB = FocusNode(debugLabel: 'tile b');

  @override
  void dispose() {
    tileA.dispose();
    tileB.dispose();
    super.dispose();
  }

  Widget _tile(String name, FocusNode node) => SizedBox(
        width: 120,
        height: 60,
        child: VwishPressable(
          key: ValueKey<String>('tile-$name'),
          focusNode: node,
          semanticLabel: 'Tile $name',
          onTap: () {
            widget.tilePresses[name] = (widget.tilePresses[name] ?? 0) + 1;
            node.requestFocus();
          },
          child: Center(child: Text('Tile $name', style: const TextStyle(fontFamily: VwishFonts.family))),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [_tile('a', tileA), _tile('b', tileB)]),
        SizedBox(
          width: 240,
          child: VwishTextField(
            key: const ValueKey<String>('field'),
            controller: widget.controller,
            focusNode: widget.fieldFocus,
            hint: 'Name',
          ),
        ),
        const SizedBox(width: 100, height: 40, child: Center(child: Icon(Icons.crop_square_rounded))),
      ],
    );
  }
}

/// Pumps `EditorShortcuts` around [child] with [bindings] on [platform].
Future<ProviderContainer> pumpShortcuts(
  WidgetTester tester,
  Widget child, {
  required Map<EditorActionId, EditorActionBinding> bindings,
  required TargetPlatform platform,
  ProjectId projectId = const ProjectId('pj_shortcuts'),
}) async {
  final harness = EditorTestHarness(overrides: [editorActionBindingsProvider.overrideWithValue(bindings)]);
  await harness.pumpApp(
    tester,
    EditorScope(
      projectId: projectId,
      child: EditorShortcuts(child: Center(child: child)),
    ),
    surface: EditorSurface(const Size(600, 400), platform: platform),
  );
  await tester.pump();
  return harness.containerOf(tester);
}
