// OWNER: UX-24
//
// The colour action bindings (ARCH §17.6): `adjust` and `filters` are bound once, open their panel on
// the selected picture clip or auto-target the main-lane clip under the playhead ("Editing clip at
// playhead"), and explain themselves when disabled; the Effects and Filters tool tiles use them.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/strings/color_strings.dart';
import 'package:vwish_editor/src/editor/actions/bindings/color_bindings.dart';
import 'package:vwish_editor/src/editor/actions/editor_action_registry.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/layout/editor_layout.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/toolbar/tool_strip.dart';
import 'package:vwish_editor/src/editor/wiring/action_bindings.dart';
import 'package:vwish_editor_core/model.dart';

import '../../inspector/inspector_rig.dart' show RegionFrame;
import '../../support/support.dart';
import 'color_rig.dart';

Future<ColorRig> pumpHome(WidgetTester tester, {EditProject Function(FakeProjectRepository repo)? project}) =>
    ColorRig.pump(tester, (_) => const SizedBox.expand(), project: project);

WidgetActionContext ctxOf(ColorRig rig, WidgetTester tester) => WidgetActionContext.container(
      projectId: rig.id,
      context: tester.element(find.byType(SizedBox).first),
      container: rig.container,
      source: EditorActionSource.toolTile,
    );

EditorActionRegistry registryOf(ColorRig rig) => rig.container.read(editorActionRegistryProvider);

void main() {
  test('adjust and filters are bound once, by color_bindings (UX-24), and nothing else is', () {
    expect({for (final b in colorBindings) b.id}, {EditorActionId.adjust, EditorActionId.filters});
    final merged = mergeEditorActionBindings();
    expect(merged[EditorActionId.adjust], isNotNull);
    expect(merged[EditorActionId.filters], isNotNull);
    expect(identical(colorBindings, colorBindings), isTrue);
    expect(editorBindingSources.where((s) => s.file == 'color_bindings').single.owner, 'UX-24');
  });

  group('target', () {
    final project = colorProject(FakeProjectRepository());
    test('a selected picture clip is used as is', () {
      final t = colorTargetOf(project, EditorSelection(items: {ColorIds.b}, primary: ColorIds.b), 0, AdjustInspector.new);
      expect(t, ColorTarget(ColorIds.b, autoTargeted: false, locked: false));
    });
    test('an overlay clip counts too', () {
      final t = colorTargetOf(project, EditorSelection(items: {ColorIds.overlay}, primary: ColorIds.overlay), 0, AdjustInspector.new);
      expect(t?.item, ColorIds.overlay);
      expect(t?.autoTargeted, isFalse);
    });
    test('a text selection or no selection falls back to the main-lane clip under the playhead', () {
      for (final sel in [EditorSelection.empty, EditorSelection(items: {ColorIds.text}, primary: ColorIds.text)]) {
        expect(colorTargetOf(project, sel, 5 * s, AdjustInspector.new)?.item, ColorIds.b);
        expect(colorTargetOf(project, sel, 5 * s, AdjustInspector.new)?.autoTargeted, isTrue);
        expect(colorTargetOf(project, sel, 0, AdjustInspector.new)?.item, ColorIds.a);
        expect(colorTargetOf(project, sel, 8 * s, AdjustInspector.new)?.item, ColorIds.c, reason: 'a clip starts at its first frame');
        expect(colorTargetOf(project, sel, 4 * s - 1, AdjustInspector.new)?.item, ColorIds.a);
      }
    });
    test('the end of the timeline picks the last clip; a gap picks the nearest', () {
      expect(colorTargetOf(project, EditorSelection.empty, 12 * s, AdjustInspector.new)?.item, ColorIds.c);
      expect(colorTargetOf(project, EditorSelection.empty, 99 * s, AdjustInspector.new)?.item, ColorIds.c);
    });
    test('nothing without a picture clip', () {
      final audioOnly = project.copyWith(timeline: project.timeline.copyWith(tracks: [for (final t in project.tracks) if (!t.isMain) t]));
      expect(colorTargetOf(audioOnly, EditorSelection.empty, 0, AdjustInspector.new), isNull);
    });
  });

  group('invoking', () {
    testWidgets('with a clip selected the panel opens on it, without a toast or a selection change', (tester) async {
      final rig = await pumpHome(tester);
      await rig.select(ColorIds.c);
      final registry = registryOf(rig);
      expect(registry.invoke(EditorActionId.adjust, ctxOf(rig, tester)), EditorActionResult.ran);
      expect(rig.state.inspector, AdjustInspector(ColorIds.c));
      expect(rig.state.selection.primary, ColorIds.c);
      await tester.pump();
      expect(find.text(ColorStrings.editingClipAtPlayhead), findsNothing);
      expect(registry.invoke(EditorActionId.filters, ctxOf(rig, tester)), EditorActionResult.ran);
      expect(rig.state.inspector, FiltersInspector(ColorIds.c));
    });

    testWidgets('with nothing selected it selects the clip at the playhead, opens the panel and says so', (tester) async {
      final rig = await pumpHome(tester);
      await rig.seek(5 * s);
      registryOf(rig).invoke(EditorActionId.filters, ctxOf(rig, tester));
      await tester.pump();
      expect(rig.state.selection.primary, ColorIds.b);
      expect(rig.state.inspector, FiltersInspector(ColorIds.b));
      expect(find.text(ColorStrings.editingClipAtPlayhead), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('selection, panel and history: selecting is not an edit', (tester) async {
      final rig = await pumpHome(tester);
      registryOf(rig).invoke(EditorActionId.adjust, ctxOf(rig, tester));
      await tester.pump();
      expect(rig.entries, 0);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('enablement and reasons', () {
    testWidgets('enabled on a project with a picture clip', (tester) async {
      final rig = await pumpHome(tester);
      final spec = registryOf(rig).spec(EditorActionId.adjust);
      final ctx = ctxOf(rig, tester);
      expect(spec.isEnabled(ctx), isTrue);
      expect(spec.isVisible(ctx), isTrue);
      expect(spec.label, 'Adjust');
      expect(registryOf(rig).spec(EditorActionId.filters).label, 'Filters');
    });

    testWidgets('a locked lane disables both and says so', (tester) async {
      final rig = await pumpHome(tester, project: (repo) => colorProject(repo, lockMain: true));
      final registry = registryOf(rig);
      final ctx = ctxOf(rig, tester);
      for (final id in [EditorActionId.adjust, EditorActionId.filters]) {
        expect(registry.spec(id).isEnabled(ctx), isFalse, reason: id.name);
        expect(registry.spec(id).disabledReason(ctx), ColorStrings.trackLocked);
        expect(registry.invoke(id, ctx), EditorActionResult.disabled);
      }
      expect(rig.state.inspector, isNull);
    });

    testWidgets('a project without a picture clip says to add one', (tester) async {
      final rig = await pumpHome(
        tester,
        project: (repo) {
          final p = colorProject(repo);
          final audioOnly = p.copyWith(timeline: p.timeline.copyWith(tracks: [for (final t in p.tracks) if (!t.isMain) t]));
          repo.seed(audioOnly);
          return audioOnly;
        },
      );
      final spec = registryOf(rig).spec(EditorActionId.adjust);
      final ctx = ctxOf(rig, tester);
      expect(spec.isEnabled(ctx), isFalse);
      expect(spec.disabledReason(ctx), ColorStrings.noClip);
    });
  });

  group('tool tiles', () {
    testWidgets('Effects and Filters on the strip open the panels on the clip at the playhead', (tester) async {
      final rig = await ColorRig.pump(
        tester,
        (_) => const RegionFrame(regions: {EditorRegion.toolStrip: ToolStrip()}),
      );
      await rig.seek(9 * s);
      await tester.tap(find.byKey(const ValueKey<String>('tile.tool.effects')));
      await tester.pump();
      expect(rig.state.tool, ToolId.effects);
      expect(rig.state.inspector, AdjustInspector(ColorIds.c));
      expect(rig.state.selection.primary, ColorIds.c);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the Adjust and Filters tiles of a clip\'s context tools run the actions', (tester) async {
      final rig = await ColorRig.pump(
        tester,
        (_) => const RegionFrame(regions: {EditorRegion.toolStrip: ToolStrip()}),
      );
      await rig.select(ColorIds.b);
      final adjust = find.byKey(const ValueKey<String>('tile.adjust'), skipOffstage: false);
      await tester.ensureVisible(adjust);
      await tester.tap(adjust);
      await tester.pump();
      expect(rig.state.inspector, AdjustInspector(ColorIds.b));
    });
  });
}
