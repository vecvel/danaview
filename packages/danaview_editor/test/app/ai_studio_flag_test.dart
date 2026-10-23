// OWNER: AIS-01
//
// The DANAVIEW_AI_STUDIO build flag (AI_STUDIO_PLAN D-65, §4.2; ARCH v1.2 V2-04): with the flag
// off there is no AI action in the registry (hidden, no shortcut, cannot run), in any tool set, in
// the shortcuts sheet or in the editor settings; with it on the AI actions exist (unbound until
// AIS-32…AIS-35 land). Also pins the AIS-01 contracts: the 1.2.0 root providers and the 1.2.0
// panel sections falling back to the cue list.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_ai_studio/danaview_ai_studio.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor/src/editor/actions/ais_action_meta.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/actions/shortcuts_sheet.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_sets.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../support/support.dart';

const _ai = EditorActionId.aiStudioActions;

/// An action context for predicates that read nothing (the hidden AI bindings).
final class _BareContext implements EditorActionContext {
  const _BareContext();

  @override
  BuildContext get context => throw UnimplementedError();

  @override
  ProjectId get projectId => const ProjectId('pj_flag');

  @override
  T read<T>(ProviderListenable<T> provider) => throw UnimplementedError();

  @override
  EditorActionSource get source => EditorActionSource.button;
}

/// Every action id named by a static tool set (UX-16) or tab.
Set<EditorActionId> _toolSetActions() {
  const a = ItemId('it_a'), b = ItemId('it_b');
  const track = TrackId('tr_sub');
  final lists = <List<ToolEntry>>[
    ToolSets.video,
    ToolSets.image,
    ToolSets.audio,
    ToolSets.multi,
    ToolSets.gap,
    ToolSets.marker,
    ToolSets.text(a),
    ToolSets.subtitleCue(track, a),
    ToolSets.transition(const TransitionRef(TrackId('tr_main'), a, b)),
  ];
  return {
    for (final list in lists)
      for (final e in list)
        if (e is ActionToolEntry) e.action,
    for (final ids in ToolSets.toolTabs.values) ...ids,
    for (final t in ToolId.values) t.primaryAction,
  };
}

void main() {
  tearDown(() => EditorFlags.debugAiStudioOverride = null);

  test('the compile-time flag defaults to false and the getter honours the test override', () {
    expect(aiStudioFlag, isFalse, reason: 'DANAVIEW_AI_STUDIO defaults to false (D-65); run tests without it');
    expect(EditorFlags.aiStudio, aiStudioFlag);
    expect(EditorFlags.aiStudioEnabled, isFalse);
    EditorFlags.debugAiStudioOverride = true;
    expect(EditorFlags.aiStudioEnabled, isTrue);
  });

  group('DANAVIEW_AI_STUDIO=false', () {
    setUp(() => EditorFlags.debugAiStudioOverride = false);

    test('the registry has no visible, runnable or shortcut-bearing AI action', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final registry = c.read(editorActionRegistryProvider);
      const ctx = _BareContext();
      for (final id in _ai) {
        final spec = registry.spec(id);
        expect(spec.isVisible(ctx), isFalse, reason: id.name);
        expect(spec.isEnabled(ctx), isFalse, reason: id.name);
        expect(spec.combos, isEmpty, reason: id.name);
        expect(registry.invoke(id, ctx), EditorActionResult.hidden, reason: id.name);
      }
      expect(registry.shortcutSpecs.map((s) => s.id).toSet().intersection(_ai), isEmpty);
      final intents = registry.activators.values.whereType<EditorActionIntent>().map((i) => i.id).toSet();
      expect(intents.intersection(_ai), isEmpty);
      // Rich-subtitle actions are not flagged (D-65): they stay visible (unbound until their
      // tickets land).
      expect(registry.spec(EditorActionId.transcriptView).isVisible(ctx), isTrue);
    });

    test('the gate hides AI actions whatever the AI binding files provide', () {
      EditorActionBinding bind(EditorActionId id) => EditorActionBinding(id: id, handler: (_) {});
      final real = {for (final id in _ai) id: bind(id)};
      final gated = gateAiStudioActions(real, aiStudio: false);
      for (final id in _ai) {
        expect(gated[id]!.isVisible!(const _BareContext()), isFalse);
      }
      expect(gateAiStudioActions(real, aiStudio: true), same(real));
      expect(mergeEditorActionBindings(), mergeEditorActionBindings());
      expect(mergeEditorActionBindings(null, true).keys.toSet().intersection(_ai), isEmpty,
          reason: 'with the flag on, AI ids are unbound until AIS-32…AIS-35 bind them');
    });

    test('no tool set or tool tab offers an AI action', () {
      expect(_toolSetActions().intersection(_ai), isEmpty);
    });

    testWidgets('the shortcuts sheet lists no AI action', (tester) async {
      final h = EditorTestHarness();
      await h.pumpApp(
        tester,
        const ColoredBox(
          color: DanaviewColors.surfaceElevated,
          child: SingleChildScrollView(padding: EdgeInsets.all(16), child: ShortcutsSheet()),
        ),
        surface: const EditorSurface(Size(600, 3200)),
      );
      final listed = tester.widgetList<ShortcutRow>(find.byType(ShortcutRow)).map((r) => r.spec.id).toSet();
      expect(listed, isNotEmpty);
      expect(listed.intersection(_ai), isEmpty);
      expect(find.text('Ask AI'), findsNothing);
    });

    testWidgets('the editor settings show no AI Studio row', (tester) async {
      final h = EditorTestHarness();
      await h.pumpApp(tester, EditorSettingsScreen(onBack: () {}));
      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 30; i++) {
        expect(find.textContaining('AI Studio'), findsNothing);
        expect(find.textContaining('AI provider'), findsNothing);
        final position = tester.state<ScrollableState>(scrollable).position;
        if (position.pixels >= position.maxScrollExtent) break;
        await tester.drag(scrollable, const Offset(0, -300));
        await tester.pump(const Duration(milliseconds: 50));
      }
    });
  });

  group('DANAVIEW_AI_STUDIO=true', () {
    setUp(() => EditorFlags.debugAiStudioOverride = true);

    test('AI actions are present (unbound until their tickets land)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final registry = c.read(editorActionRegistryProvider);
      for (final id in _ai) {
        expect(registry.spec(id).isBound, isFalse, reason: id.name);
        expect(registry.spec(id).isVisible(const _BareContext()), isTrue, reason: id.name);
      }
    });
  });

  group('AIS-01 contracts', () {
    test('every 1.2.0 action has metadata, no shortcut yet (S1 looks like 1.1), and 1.1 actions are not delegated', () {
      for (final id in EditorActionId.v12Additions) {
        expect(editorActionMeta(id).label, aisActionMeta(id).label);
        expect(editorActionMeta(id).label, isNotEmpty);
        expect(editorActionMeta(id).combos, isEmpty, reason: '${id.name}: the binding ticket attaches its shortcut');
      }
      expect(() => aisActionMeta(EditorActionId.split), throwsArgumentError);
      final labels = [for (final id in EditorActionId.values) editorActionMeta(id).label];
      expect(labels.toSet(), hasLength(labels.length), reason: 'labels are unique');
    });

    test('the planned 1.2.0 shortcuts collide with no 1.1 shortcut', () {
      for (final apple in [true, false]) {
        final registry = EditorActionRegistry(bindings: const {}, apple: apple);
        final seen = <Object, EditorActionId>{
          for (final (id, c) in [
            (EditorActionId.transcriptView, transcriptViewCombo),
            (EditorActionId.splitCueAtCursor, splitCueAtCursorCombo),
            (EditorActionId.askAi, askAiCombo),
          ])
            (c.key, c.character, c.command, c.shift): id,
        };
        for (final spec in registry.specs) {
          for (final c in spec.combos) {
            final key = (c.key, c.character, c.command, c.shift);
            final other = seen[key];
            expect(other == null || other == spec.id, isTrue, reason: '${c.label(apple)} is bound by $other and ${spec.id}');
            seen[key] = spec.id;
          }
        }
      }
    });

    test('aiStudioServiceProvider defaults to AiStudioOff; font and preset stores need EditorBootstrap', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(aiStudioServiceProvider), const AiStudioOff());
      expect(() => c.read(fontLibraryProvider), throwsA(isA<EditorNotConfiguredError>()));
      expect(() => c.read(subtitlePresetStoreProvider), throwsA(isA<EditorNotConfiguredError>()));
    });

    test('SubtitlesPanelSection gains transcript, review and cue after the 1.1 sections', () {
      expect(SubtitlesPanelSection.values.map((s) => s.name), ['cues', 'style', 'position', 'transcript', 'review', 'cue']);
      expect(SubtitlesPanelSection.v11, [SubtitlesPanelSection.cues, SubtitlesPanelSection.style, SubtitlesPanelSection.position]);
    });
  });
}
