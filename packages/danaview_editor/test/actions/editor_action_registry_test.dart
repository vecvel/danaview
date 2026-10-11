// OWNER: UX-15
//
// EditorActionRegistry (ARCH §17.6): one spec per action id, the platform key table (⌘ is Command
// on Apple platforms and Ctrl elsewhere), no two actions on one key, bindings supply handlers and
// predicates, disabled actions explain themselves, invoke never throws, the built-in fallbacks
// (undo, redo, save, zoom, the shortcuts sheet) yield to feature bindings, and the menu, semantics
// and tooltip helpers read the same specs.


import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'action_test_support.dart';

/// A context that reads nothing (the handlers under test don't read providers).
class _Ctx implements EditorActionContext {
  _Ctx({this.source = EditorActionSource.button});

  @override
  final EditorActionSource source;

  @override
  BuildContext get context => throw UnimplementedError();

  @override
  ProjectId get projectId => const ProjectId('pj_x');

  @override
  T read<T>(ProviderListenable<T> provider) => throw UnimplementedError();
}

/// Expected key labels per action: (Apple, other).
const Map<EditorActionId, (List<String>, List<String>)> _labels = {
  EditorActionId.playPause: (['Space', 'K'], ['Space', 'K']),
  EditorActionId.prevFrame: (['←'], ['←']),
  EditorActionId.nextFrame: (['→'], ['→']),
  EditorActionId.back1s: (['⇧←'], ['Shift+←']),
  EditorActionId.forward1s: (['⇧→'], ['Shift+→']),
  EditorActionId.prevEdit: (['↑'], ['↑']),
  EditorActionId.nextEdit: (['↓'], ['↓']),
  EditorActionId.goStart: (['Home'], ['Home']),
  EditorActionId.goEnd: (['End'], ['End']),
  EditorActionId.fullscreenPreview: (['F'], ['F']),
  EditorActionId.split: (['S'], ['S']),
  EditorActionId.delete: (['Delete', 'Backspace'], ['Delete', 'Backspace']),
  EditorActionId.rippleDelete: (['⇧Delete', '⇧Backspace'], ['Shift+Delete', 'Shift+Backspace']),
  EditorActionId.undo: (['⌘Z'], ['Ctrl+Z']),
  EditorActionId.redo: (['⇧⌘Z'], ['Ctrl+Shift+Z', 'Ctrl+Y']),
  EditorActionId.save: (['⌘S'], ['Ctrl+S']),
  EditorActionId.copy: (['⌘C'], ['Ctrl+C']),
  EditorActionId.cut: (['⌘X'], ['Ctrl+X']),
  EditorActionId.paste: (['⌘V'], ['Ctrl+V']),
  EditorActionId.duplicate: (['⌘D'], ['Ctrl+D']),
  EditorActionId.selectAll: (['⌘A'], ['Ctrl+A']),
  EditorActionId.escape: (['Esc'], ['Esc']),
  EditorActionId.toggleSnapping: (['N'], ['N']),
  EditorActionId.toggleRipple: (['R'], ['R']),
  EditorActionId.zoomIn: (['⌘='], ['Ctrl+=']),
  EditorActionId.zoomOut: (['⌘−'], ['Ctrl+−']),
  EditorActionId.zoomFit: (['⇧Z'], ['Shift+Z']),
  EditorActionId.addMarker: (['M'], ['M']),
  EditorActionId.showShortcuts: (['⌘/', '?'], ['Ctrl+/', '?']),
};

void main() {
  final log = ActionLog();
  tearDown(log.clear);

  EditorActionRegistry registry({bool apple = false, Map<EditorActionId, EditorActionBinding>? bindings}) =>
      EditorActionRegistry(bindings: bindings ?? recordingBindings(log), apple: apple);

  group('specs', () {
    test('one spec per action id, in declaration order, each with a label and an icon', () {
      final r = registry();
      expect(r.specs.map((s) => s.id).toList(), EditorActionId.values);
      for (final s in r.specs) {
        expect(s.label, isNotEmpty, reason: s.id.name);
        expect(s.label.trim(), s.label, reason: s.id.name);
        expect(s.icon, isA<IconData>());
      }
    });

    test('labels are unique, so menus and the sheet never show two identical rows', () {
      final labels = registry().specs.map((s) => s.label).toList();
      expect(labels.toSet().length, labels.length, reason: 'duplicates: ${labels.where((l) => labels.where((m) => m == l).length > 1).toSet()}');
    });

    test('a binding overrides the label and the icon', () {
      final r = registry(bindings: {
        EditorActionId.split: EditorActionBinding(id: EditorActionId.split, handler: (_) {}, label: 'Cut here', icon: Icons.add_rounded),
      });
      expect(r.spec(EditorActionId.split).label, 'Cut here');
      expect(r.spec(EditorActionId.split).icon, Icons.add_rounded);
      expect(r.spec(EditorActionId.delete).label, 'Delete');
    });
  });

  group('shortcut table', () {
    for (final apple in [true, false]) {
      test('${apple ? 'Apple' : 'non-Apple'}: labels of every shortcut', () {
        final r = registry(apple: apple);
        for (final entry in _labels.entries) {
          expect(r.spec(entry.key).shortcutLabels, apple ? entry.value.$1 : entry.value.$2, reason: entry.key.name);
        }
        final listed = _labels.keys.toSet();
        for (final s in r.specs) {
          if (!listed.contains(s.id)) expect(s.shortcutLabels, isEmpty, reason: '${s.id.name} has an unlisted shortcut');
        }
      });

      test('${apple ? 'Apple' : 'non-Apple'}: ⌘ is ${apple ? 'Command' : 'Ctrl'}', () {
        final r = registry(apple: apple);
        final undo = r.spec(EditorActionId.undo).shortcuts.single as SingleActivator;
        expect(undo.trigger, LogicalKeyboardKey.keyZ);
        expect(undo.meta, apple);
        expect(undo.control, !apple);
        final redo = r.spec(EditorActionId.redo).shortcuts.cast<SingleActivator>();
        expect(redo.first.shift, isTrue);
        if (apple) {
          expect(redo, hasLength(1), reason: 'Ctrl+Y is not an Apple shortcut');
        } else {
          expect(redo.last.trigger, LogicalKeyboardKey.keyY);
          expect(redo.last.control, isTrue);
        }
        final save = r.spec(EditorActionId.save).shortcuts.single as SingleActivator;
        expect(save.meta, apple);
        expect(save.control, !apple);
      });

      test('${apple ? 'Apple' : 'non-Apple'}: no two actions share a key', () {
        final r = registry(apple: apple);
        String describe(ShortcutActivator a) => a is SingleActivator
            ? '${a.trigger.keyId}:ctrl=${a.control}:meta=${a.meta}:shift=${a.shift}:alt=${a.alt}'
            : 'char:${(a as CharacterActivator).character}';
        final seen = <String, EditorActionId>{};
        for (final s in r.specs) {
          for (final a in s.shortcuts) {
            final key = describe(a);
            final other = seen[key];
            expect(other, isNull, reason: '${s.id.name} and ${other?.name} both use $key');
            seen[key] = s.id;
          }
        }
        expect(r.activators.length, seen.length);
        for (final entry in r.activators.entries) {
          expect((entry.value as EditorActionIntent).id, seen[describe(entry.key)]);
          expect(r.comboOf(entry.key), isNotNull, reason: 'every activator maps back to its combo');
        }
      });
    }

    test('the Enter aliases of playPause work only with no control focused and are not listed', () {
      final r = registry();
      final combos = r.spec(EditorActionId.playPause).combos;
      expect(combos.where((c) => c.rootOnly).map((c) => c.key), [LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter]);
      expect(r.spec(EditorActionId.playPause).shortcutLabels, ['Space', 'K']);
    });

    test('only save and escape work in text fields; frame steps, edit points, undo, redo and zoom repeat', () {
      final r = registry();
      expect(r.specs.where((s) => s.worksInTextFields).map((s) => s.id).toSet(), {EditorActionId.save, EditorActionId.escape});
      expect(
        r.specs.where((s) => s.repeatable).map((s) => s.id).toSet(),
        {
          EditorActionId.prevFrame,
          EditorActionId.nextFrame,
          EditorActionId.back1s,
          EditorActionId.forward1s,
          EditorActionId.prevEdit,
          EditorActionId.nextEdit,
          EditorActionId.undo,
          EditorActionId.redo,
          EditorActionId.zoomIn,
          EditorActionId.zoomOut,
        },
      );
    });

    test('every ARCH §17.6 shortcut exists', () {
      final r = registry();
      final withKeys = r.shortcutSpecs.map((s) => s.id).toSet();
      expect(
        withKeys,
        containsAll(<EditorActionId>[
          EditorActionId.playPause, EditorActionId.prevFrame, EditorActionId.nextFrame, EditorActionId.back1s, EditorActionId.forward1s,
          EditorActionId.prevEdit, EditorActionId.nextEdit, EditorActionId.goStart, EditorActionId.goEnd, EditorActionId.split,
          EditorActionId.delete, EditorActionId.rippleDelete, EditorActionId.undo, EditorActionId.redo, EditorActionId.save,
          EditorActionId.copy, EditorActionId.cut, EditorActionId.paste, EditorActionId.duplicate, EditorActionId.selectAll,
          EditorActionId.escape, EditorActionId.addMarker, EditorActionId.toggleSnapping, EditorActionId.toggleRipple,
          EditorActionId.zoomIn, EditorActionId.zoomOut, EditorActionId.zoomFit, EditorActionId.fullscreenPreview, EditorActionId.showShortcuts,
        ]),
      );
    });

    test('forPlatformOf returns the same registry for the same family and a cached sibling for the other', () {
      final r = registry(apple: false);
      expect(identical(r.forPlatformOf(TargetPlatform.android), r), isTrue);
      expect(identical(r.forPlatformOf(TargetPlatform.windows), r), isTrue);
      final mac = r.forPlatformOf(TargetPlatform.macOS);
      expect(mac.apple, isTrue);
      expect(identical(r.forPlatformOf(TargetPlatform.iOS), mac), isTrue);
      expect(mac.spec(EditorActionId.undo).primaryShortcut, '⌘Z');
    });

    test('tooltip text carries the primary shortcut', () {
      final r = registry();
      expect(r.tooltip(EditorActionId.undo), 'Undo (Ctrl+Z)');
      expect(r.tooltip(EditorActionId.playPause, 'Pause'), 'Pause (Space)');
      expect(r.tooltip(EditorActionId.addText), 'Add text');
      expect(registry(apple: true).tooltip(EditorActionId.redo), 'Redo (⇧⌘Z)');
    });
  });

  group('bindings and predicates', () {
    test('invoke runs the handler once and reports it', () {
      final r = registry();
      expect(r.invoke(EditorActionId.split, _Ctx(source: EditorActionSource.keyboard)), EditorActionResult.ran);
      expect(log.ran, [EditorActionId.split]);
      expect(log.sources, [EditorActionSource.keyboard]);
    });

    test('an action nobody binds is unbound, disabled and says "Not available yet"', () {
      final r = registry(bindings: recordingBindings(log, skip: {EditorActionId.split}));
      final s = r.spec(EditorActionId.split);
      expect(s.isBound, isFalse);
      expect(s.isEnabled(_Ctx()), isFalse);
      expect(s.disabledReason(_Ctx()), EditorActionStrings.notAvailableYet);
      expect(r.invoke(EditorActionId.split, _Ctx()), EditorActionResult.unbound);
      expect(log.ran, isEmpty);
    });

    test('a disabled binding explains why; without a reason the generic one is used', () {
      final r = registry(bindings: {
        EditorActionId.split: EditorActionBinding(id: EditorActionId.split, handler: (_) => log.ran.add(EditorActionId.split), isEnabled: (_) => false, disabledReason: (_) => 'Select a clip first'),
        EditorActionId.delete: EditorActionBinding(id: EditorActionId.delete, handler: (_) => log.ran.add(EditorActionId.delete), isEnabled: (_) => false),
        EditorActionId.copy: EditorActionBinding(id: EditorActionId.copy, handler: (_) => log.ran.add(EditorActionId.copy)),
      });
      expect(r.spec(EditorActionId.split).disabledReason(_Ctx()), 'Select a clip first');
      expect(r.spec(EditorActionId.delete).disabledReason(_Ctx()), EditorActionStrings.notAvailableNow);
      expect(r.spec(EditorActionId.copy).disabledReason(_Ctx()), isNull, reason: 'enabled actions have no reason');
      expect(r.invoke(EditorActionId.split, _Ctx()), EditorActionResult.disabled);
      expect(r.invoke(EditorActionId.delete, _Ctx()), EditorActionResult.disabled);
      expect(r.invoke(EditorActionId.copy, _Ctx()), EditorActionResult.ran);
      expect(log.ran, [EditorActionId.copy]);
    });

    test('a hidden binding is not run', () {
      final r = registry(bindings: {
        EditorActionId.split: EditorActionBinding(id: EditorActionId.split, handler: (_) => log.ran.add(EditorActionId.split), isVisible: (_) => false),
      });
      expect(r.spec(EditorActionId.split).isVisible(_Ctx()), isFalse);
      expect(r.invoke(EditorActionId.split, _Ctx()), EditorActionResult.hidden);
      expect(log.ran, isEmpty);
    });

    test('a handler that throws is reported and never escapes (ARCH §19 rule 1)', () {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);
      final r = registry(bindings: {
        EditorActionId.split: EditorActionBinding(id: EditorActionId.split, handler: (_) => throw StateError('boom')),
      });
      expect(r.invoke(EditorActionId.split, _Ctx()), EditorActionResult.failed);
      expect(errors, hasLength(1));
      expect(errors.single.exception, isA<StateError>());
    });

    test('an async handler that fails is reported too', () async {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);
      final r = registry(bindings: {
        EditorActionId.split: EditorActionBinding(id: EditorActionId.split, handler: (_) async => throw StateError('later')),
      });
      expect(r.invoke(EditorActionId.split, _Ctx()), EditorActionResult.ran);
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
    });

    test('a predicate that throws counts as disabled and is reported', () {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);
      final r = registry(bindings: {
        EditorActionId.split: EditorActionBinding(id: EditorActionId.split, handler: (_) {}, isEnabled: (_) => throw StateError('bad predicate')),
      });
      expect(r.spec(EditorActionId.split).isEnabled(_Ctx()), isFalse);
      expect(errors, isNotEmpty);
    });
  });

  group('built-in fallbacks', () {
    test('undo, redo, save, zoom and the shortcuts sheet work without a feature binding', () {
      final r = registry(bindings: const {});
      for (final id in [
        EditorActionId.undo,
        EditorActionId.redo,
        EditorActionId.save,
        EditorActionId.zoomIn,
        EditorActionId.zoomOut,
        EditorActionId.zoomFit,
        EditorActionId.showShortcuts,
      ]) {
        expect(r.spec(id).isBound, isTrue, reason: id.name);
      }
      expect(r.spec(EditorActionId.split).isBound, isFalse);
    });

    test('a feature binding wins over the built-in', () {
      final r = registry(bindings: {
        EditorActionId.undo: EditorActionBinding(id: EditorActionId.undo, handler: (_) => log.ran.add(EditorActionId.undo), label: 'Step back'),
      });
      expect(r.spec(EditorActionId.undo).label, 'Step back');
      expect(r.invoke(EditorActionId.undo, _Ctx()), EditorActionResult.ran);
      expect(log.ran, [EditorActionId.undo]);
    });
  });

  group('menus and semantics', () {
    test('menuEntries lists visible actions with enablement, shortcut and reason', () {
      final r = registry(
        bindings: {
          ...recordingBindings(log, disabled: {EditorActionId.delete}),
          EditorActionId.copy: EditorActionBinding(id: EditorActionId.copy, handler: (_) {}, isVisible: (_) => false),
        },
      );
      var ran = 0;
      final entries = r.menuEntries(_Ctx(), const [EditorActionId.split, EditorActionId.delete, EditorActionId.copy], onRun: () => ran++);
      expect(entries.map((e) => (e as DanaviewMenuItem).label), ['Split', 'Delete'], reason: 'the hidden copy is left out');
      final split = entries[0] as DanaviewMenuItem;
      final delete = entries[1] as DanaviewMenuItem;
      expect(split.enabled, isTrue);
      expect(split.trailing, isNotNull);
      expect(delete.enabled, isFalse);
      expect(delete.subtitle, 'Not now: delete');
      split.onTap!();
      expect(log.ran, [EditorActionId.split]);
      expect(ran, 1);
    });

    test('semanticsActions lists the enabled actions and runs them with the semantics source', () {
      final r = registry(bindings: recordingBindings(log, disabled: {EditorActionId.delete}));
      final actions = r.semanticsActions(_Ctx(), const [EditorActionId.split, EditorActionId.delete]);
      expect(actions.keys.map((a) => a.label), ['Split']);
      actions.values.single();
      expect(log.ran, [EditorActionId.split]);
    });
  });
}
