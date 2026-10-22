// OWNER: UX-15
//
// EditorShortcuts (ARCH §17.6, ux.md §15.2): the editor-level Shortcuts/Actions scope.
//
// What it does
// * Maps every key combo of the `EditorActionRegistry` (⌘ is Command on Apple platforms and Ctrl
//   elsewhere) to an `EditorActionIntent` and runs the action through the registry, so a key, a
//   tool tile and a menu item all go through the same enablement and handler.
// * It **overrides Flutter's defaults** for the editor: Space (and Enter when no control has
//   focus) toggle playback instead of pressing the focused control, and the arrow keys step frames
//   and edit points instead of moving focus. The kit's `DanaviewPressable` installs its own
//   Space/Enter -> ActivateIntent shortcut below the focused node, which no ancestor `Shortcuts`
//   can pre-empt, so the scope also registers an *early key event handler*
//   (`FocusManager.addEarlyKeyEventHandler`) that sees the event before the focus tree. That makes
//   "tap a tool tile, press Space" toggle playback and leave the tile alone, and ←/→ step one
//   frame instead of moving focus. The same handler logic also sits in the `Shortcuts` manager for
//   events that reach the tree (text-safe keys inside a text field).
//
// The focus guard
// * A key belongs to the editor only while focus is in the editor's own focus scope. A menu
//   (its own scope), a sheet or a dialog (another route) is left alone. While a kit menu is open
//   the editor leaves every key alone, wherever focus is: Esc closes the menu first.
// * While an `EditableText` has focus the non-text-safe actions are disabled and do not consume
//   the key, so Space, Backspace, the arrows and ⌘C/⌘V reach the text field. Only `save` and
//   `escape` keep working there (ux.md §15.2: ⌘S works in text fields).
// * Key repeat runs only the repeatable actions (frame steps, edit points, undo, redo, zoom);
//   other actions swallow the repeat instead of running again.
// * When nothing has focus (after a sheet or a text field closed) the editor is still in scope,
//   so shortcuts resume at once.

import 'package:flutter/material.dart' show Theme;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart' show DanaviewMenuAnchor;

import '../contracts/contracts.dart';
import '../editor_scope.dart';
import 'editor_action_registry.dart';

/// Where a key event lands relative to the editor.
enum EditorKeyScope {
  /// Focus is in the editor's scope on something that is not a text field.
  inScope,

  /// Focus is in a text field of the editor: only text-safe actions run.
  textFocused,

  /// Focus is in a menu, sheet or dialog, or another route: not the editor's key.
  outOfScope,
}

/// The editor's Shortcuts/Actions scope (ARCH §17.6). Place it below `EditorScope`, around the
/// whole editor.
class EditorShortcuts extends ConsumerStatefulWidget {
  /// Creates the scope around [child].
  const EditorShortcuts({super.key, required this.child});

  /// The editor.
  final Widget child;

  /// Whether [node] is (inside) a text field.
  static bool isTextFocus(FocusNode? node) {
    final context = node?.context;
    if (context == null) return false;
    return context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  ConsumerState<EditorShortcuts> createState() => _EditorShortcutsState();
}

class _EditorShortcutsState extends ConsumerState<EditorShortcuts> {
  final FocusNode _root = FocusNode(debugLabel: 'EditorShortcuts', skipTraversal: true);
  late final _EditorShortcutManager _manager = _EditorShortcutManager(this);
  late final Map<Type, Action<Intent>> _actions = <Type, Action<Intent>>{
    EditorActionIntent: CallbackAction<EditorActionIntent>(onInvoke: (intent) {
      _run(intent.id);
      return null;
    }),
  };

  EditorActionRegistry? _registry;
  bool _routeIsCurrent = true;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onEarlyKey);
    _manager.dispose();
    _root.dispose();
    super.dispose();
  }

  KeyEventResult _onEarlyKey(KeyEvent event) {
    if (!mounted) return KeyEventResult.ignored;
    return _manager.handle(event, early: true);
  }

  /// Where a key event lands right now.
  EditorKeyScope scopeNow() {
    if (!mounted) return EditorKeyScope.outOfScope;
    // An open menu owns the keyboard even when its focus scope does not hold focus (FIX-QA02-M2-2).
    if (DanaviewMenuAnchor.anyOpen) return EditorKeyScope.outOfScope;
    final scope = Focus.maybeOf(context, scopeOk: true, createDependency: false)?.nearestScope;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary == scope) {
      return _routeIsCurrent ? EditorKeyScope.inScope : EditorKeyScope.outOfScope;
    }
    if (!_root.hasFocus || primary.nearestScope != scope) return EditorKeyScope.outOfScope;
    return EditorShortcuts.isTextFocus(primary) ? EditorKeyScope.textFocused : EditorKeyScope.inScope;
  }

  /// Whether no control holds focus (the root node, the scope or nothing).
  bool get _noControlFocused {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary == _root) return true;
    return primary == Focus.maybeOf(context, scopeOk: true, createDependency: false)?.nearestScope;
  }

  EditorActionResult _run(EditorActionId id) {
    final registry = _registry;
    final projectId = EditorScope.maybeIdOf(context);
    if (registry == null || projectId == null) return EditorActionResult.unbound;
    final ctx = WidgetActionContext(projectId: projectId, context: context, ref: ref, source: EditorActionSource.keyboard);
    return registry.invoke(id, ctx);
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final registry = ref.watch(editorActionRegistryProvider).forPlatformOf(platform);
    _registry = registry;
    _routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    _manager.update(registry);
    return Shortcuts.manager(
      manager: _manager,
      child: Actions(
        actions: _actions,
        child: Focus(
          focusNode: _root,
          autofocus: true,
          debugLabel: 'EditorShortcuts',
          child: widget.child,
        ),
      ),
    );
  }
}

/// The shortcut manager of the editor: the key lookup of `ShortcutManager` plus the focus guard,
/// the Enter rule and the key-repeat rule.
class _EditorShortcutManager extends ShortcutManager {
  _EditorShortcutManager(this._owner);

  final _EditorShortcutsState _owner;
  EditorActionRegistry? _registry;
  Map<LogicalKeyboardKey?, List<MapEntry<ShortcutActivator, Intent>>> _index = const {};

  void update(EditorActionRegistry registry) {
    if (identical(registry, _registry)) return;
    _registry = registry;
    final index = <LogicalKeyboardKey?, List<MapEntry<ShortcutActivator, Intent>>>{};
    registry.activators.forEach((activator, intent) {
      for (final LogicalKeyboardKey? trigger in activator.triggers ?? <LogicalKeyboardKey?>[null]) {
        index.putIfAbsent(trigger, () => []).add(MapEntry(activator, intent));
      }
    });
    _index = index;
    shortcuts = registry.activators;
  }

  Intent? _find(KeyEvent event) {
    final candidates = [...?_index[event.logicalKey], ...?_index[null]];
    for (final c in candidates) {
      if (c.key.accepts(event, HardwareKeyboard.instance)) return c.value;
    }
    return null;
  }

  ShortcutActivator? _activatorOf(KeyEvent event) {
    final candidates = [...?_index[event.logicalKey], ...?_index[null]];
    for (final c in candidates) {
      if (c.key.accepts(event, HardwareKeyboard.instance)) return c.key;
    }
    return null;
  }

  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) => handle(event, early: false);

  /// Handles [event]: [early] when it comes from the early key handler (before the focus tree).
  KeyEventResult handle(KeyEvent event, {required bool early}) {
    final registry = _registry;
    if (registry == null || event is KeyUpEvent) return KeyEventResult.ignored;
    final scope = _owner.scopeNow();
    if (scope == EditorKeyScope.outOfScope) return KeyEventResult.ignored;
    final intent = _find(event);
    if (intent is! EditorActionIntent) return KeyEventResult.ignored;
    final spec = registry.spec(intent.id);
    if (scope == EditorKeyScope.textFocused) {
      // The text field owns the key, except the text-safe actions, which run from the tree.
      if (!spec.worksInTextFields || early) return KeyEventResult.ignored;
    }
    final activator = _activatorOf(event);
    final combo = activator == null ? null : registry.comboOf(activator);
    if (combo != null && combo.rootOnly && !_owner._noControlFocused) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent && !spec.repeatable) return KeyEventResult.handled;
    _owner._run(spec.id);
    return KeyEventResult.handled;
  }
}
