// OWNER: UX-16
//
// Widget tests of the tool strip, the rail and the tool pane (ux.md §9.1, §9.2): top-level tools,
// context tools with the leading chip, the Audio tab, registry-driven enablement, disabled tiles
// that explain themselves, icon-only tiles, the rail and pane placements, and the surface matrix.

import 'package:flutter/material.dart' show Icons, Tooltip;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/debug/rebuild_counters.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_grid.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_rail.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_strip.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_tile.dart';
import 'package:danaview_editor/src/editor/toolbar/toolbar_chip.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../inspector/inspector_rig.dart';
import '../support/support.dart';

/// Bindings the tests control.
class TestBindings {
  final List<(EditorActionId, EditorActionSource)> calls = [];

  late final Map<EditorActionId, EditorActionBinding> map = {
    for (final b in [
      EditorActionBinding(id: EditorActionId.addText, handler: _record(EditorActionId.addText)),
      EditorActionBinding(id: EditorActionId.media, handler: _record(EditorActionId.media)),
      EditorActionBinding(
        id: EditorActionId.captions,
        handler: _record(EditorActionId.captions),
        isEnabled: (_) => false,
        disabledReason: (_) => 'Add a subtitle track first',
      ),
      EditorActionBinding(id: EditorActionId.transform, handler: _record(EditorActionId.transform)),
      EditorActionBinding(id: EditorActionId.duplicate, handler: _record(EditorActionId.duplicate)),
      EditorActionBinding(id: EditorActionId.copy, handler: _record(EditorActionId.copy), isVisible: (_) => false),
      EditorActionBinding(id: EditorActionId.addMusic, handler: _record(EditorActionId.addMusic)),
    ])
      b.id: b,
  };

  EditorActionHandler _record(EditorActionId id) => (ctx) => calls.add((id, ctx.source));
}

Future<(InspectorRig, TestBindings)> pumpTools(WidgetTester tester, {EditorSurface surface = SurfaceMatrix.phone}) async {
  final bindings = TestBindings();
  final rig = await InspectorRig.pump(
    tester,
    (_) => const RegionFrame(regions: {
      EditorRegion.toolStrip: ToolStrip(),
      EditorRegion.rail: ToolRail(),
      EditorRegion.pane: _Pane(),
    }),
    surface: surface,
    overrides: [editorActionBindingsProvider.overrideWithValue(bindings.map)],
  );
  return (rig, bindings);
}

/// What the scaffold puts in the side pane while the inspector is closed.
class _Pane extends StatelessWidget {
  const _Pane();

  @override
  Widget build(BuildContext context) => frameKind(context) == EditorLayoutKind.expanded ? const InspectorHost() : const ToolRail();
}

EditorLayoutKind frameKind(BuildContext context) =>
    EditorLayoutSpec.kindOf(size: MediaQuery.sizeOf(context), padding: MediaQuery.paddingOf(context));

Finder tile(String key) => find.byKey(ValueKey<String>('tile.$key'), skipOffstage: false);

/// The keys of every tile under [within] (default: the whole tree), scrolling lazy lists to build
/// them all, in order.
Future<List<String>> tileKeys(WidgetTester tester, {Finder? within}) async {
  final scope = within ?? find.byType(Stack).first;
  final out = <String>[];
  void collect() {
    for (final t in tester.widgetList<ToolTile>(find.descendant(of: scope, matching: find.byType(ToolTile), skipOffstage: false))) {
      if (!out.contains(t.data.key)) out.add(t.data.key);
    }
  }

  collect();
  final scrollables = find.descendant(of: scope, matching: find.byType(Scrollable), skipOffstage: false);
  for (final state in tester.stateList<ScrollableState>(scrollables).toList()) {
    final p = state.position;
    while (p.pixels < p.maxScrollExtent) {
      p.jumpTo((p.pixels + 120).clamp(0.0, p.maxScrollExtent));
      await tester.pump();
      collect();
    }
    p.jumpTo(0);
    await tester.pump();
  }
  return out;
}

/// Builds the tile [key] by scrolling the lazy lists until it exists.
Future<void> reveal(WidgetTester tester, String key) async {
  if (tile(key).evaluate().isNotEmpty) return;
  for (final state in tester.stateList<ScrollableState>(find.byType(Scrollable, skipOffstage: false)).toList()) {
    final p = state.position;
    p.jumpTo(0);
    await tester.pump();
    while (tile(key).evaluate().isEmpty && p.pixels < p.maxScrollExtent) {
      p.jumpTo((p.pixels + 120).clamp(0.0, p.maxScrollExtent));
      await tester.pump();
    }
    if (tile(key).evaluate().isNotEmpty) return;
  }
}

Future<ToolTileData> data(WidgetTester tester, String key) async {
  await reveal(tester, key);
  return tester.widget<ToolTile>(tile(key)).data;
}

Future<void> tap(WidgetTester tester, String key) async {
  await reveal(tester, key);
  await tester.ensureVisible(tile(key));
  await tester.pump();
  await tester.tap(tile(key));
  await tester.pump();
}

/// Taps the leading chip (scrolling back to the start first).
Future<void> tapChip(WidgetTester tester) async {
  for (final state in tester.stateList<ScrollableState>(find.byType(Scrollable, skipOffstage: false)).toList()) {
    state.position.jumpTo(0);
  }
  await tester.pump();
  await tester.tap(find.byType(ToolbarChipView));
  await tester.pump();
}

const topLevel = [
  'tool.media', 'tool.audio', 'tool.text', 'tool.captions', 'tool.overlay', 'tool.effects', 'tool.filters', 'tool.transitions',
  'tool.format', //
];

void main() {
  tearDown(DanaviewToast.dismiss);

  group('bottom strip (compactPortrait)', () {
    testWidgets('nothing selected: the nine top-level tools in ux.md §9.1 order', (tester) async {
      await pumpTools(tester);
      expect(find.byType(ToolStrip), findsOneWidget);
      expect(await tileKeys(tester), topLevel);
      expect(find.byType(ToolbarChipView), findsNothing);
      expect((await data(tester, 'tool.media')).label, 'Media');
      expect((await data(tester, 'tool.media')).icon, Icons.video_library_rounded);
      expectNoOverflow(tester);
    });

    testWidgets('a bound tool runs through the registry with source toolTile and becomes the active tool', (tester) async {
      final (rig, bindings) = await pumpTools(tester);
      await tap(tester, 'tool.text');
      expect(bindings.calls, [(EditorActionId.addText, EditorActionSource.toolTile)]);
      expect(rig.state.tool, ToolId.text);
      expect((await data(tester, 'tool.text')).selected, isTrue);
    });

    testWidgets('disabled tiles stay visible at 40% and explain why when tapped', (tester) async {
      final (rig, bindings) = await pumpTools(tester);
      final captions = await data(tester, 'tool.captions');
      expect(captions.enabled, isFalse);
      expect(captions.reason, 'Add a subtitle track first');
      final opacity = tester.widget<Opacity>(find.descendant(of: tile('tool.captions'), matching: find.byType(Opacity)));
      expect(opacity.opacity, DanaviewColors.disabledOpacity);
      await tap(tester, 'tool.captions');
      expect(find.text('Add a subtitle track first'), findsOneWidget);
      expect(bindings.calls, isEmpty);
      expect(rig.state.tool, isNull);
      // An unbound tool explains itself with the registry's reason.
      await tap(tester, 'tool.overlay');
      expect(find.text('Not available yet'), findsOneWidget);
    });

    testWidgets('semantics: button + label + hint (the reason when disabled)', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpTools(tester);
      final captions = tester.getSemantics(tile('tool.captions')).getSemanticsData();
      expect(captions.label, 'Captions');
      expect(captions.hint, 'Add a subtitle track first');
      expect(captions.flagsCollection.isButton, isTrue);
      final text = tester.getSemantics(tile('tool.text')).getSemanticsData();
      expect(text.label, 'Text');
      expect(text.hint, isEmpty);
      handle.dispose();
    });

    testWidgets('a selection shows [✕ Text] and its context tools; the chip clears the selection', (tester) async {
      final (rig, bindings) = await pumpTools(tester);
      await rig.select(rig.items.textA);
      expect(find.widgetWithText(ToolbarChipView, 'Text'), findsOneWidget);
      // copy is hidden by its binding; the rest follows ux.md §9.2.
      expect(await tileKeys(tester),
          ['text.edit', 'text.font', 'text.style', 'text.animation', 'transform', 'keyframes', 'duplicate', 'delete']);
      expect((await data(tester, 'delete')).enabled, isFalse);
      expect((await data(tester, 'delete')).reason, 'Not available yet');
      await tap(tester, 'transform');
      expect(bindings.calls.single, (EditorActionId.transform, EditorActionSource.toolTile));
      await tapChip(tester);
      expect(rig.state.selection.isEmpty, isTrue);
      expect(await tileKeys(tester), topLevel);
    });

    testWidgets('panel tools open their route and show as active', (tester) async {
      final (rig, _) = await pumpTools(tester);
      await rig.select(rig.items.textA);
      await tap(tester, 'text.font');
      expect(rig.state.inspector, TextInspector(rig.items.textA, tab: TextPanelTab.font));
      expect((await data(tester, 'text.font')).selected, isTrue);
      await rig.select(rig.items.cue);
      expect(find.widgetWithText(ToolbarChipView, 'Caption'), findsOneWidget);
      expect(await tileKeys(tester), ['cue.edit', 'cue.timing', 'split', 'cue.merge', 'cue.style', 'cue.position', 'delete']);
      await tap(tester, 'cue.position');
      expect(rig.state.inspector, isA<SubtitlesInspector>().having((r) => r.section, 'section', SubtitlesPanelSection.position));
    });

    testWidgets('a marker selection shows Rename, Color, Note, Delete', (tester) async {
      final (rig, _) = await pumpTools(tester);
      rig.editor.selectMarker(rig.items.marker);
      await tester.pump();
      expect(find.widgetWithText(ToolbarChipView, 'Marker'), findsOneWidget);
      expect([for (final k in await tileKeys(tester)) (await data(tester, k)).label], ['Rename', 'Color', 'Note', 'Delete']);
    });

    testWidgets('the Audio tool opens its tab; the chip goes back to the tools', (tester) async {
      final (rig, bindings) = await pumpTools(tester);
      await tap(tester, 'tool.audio');
      expect(rig.state.tool, ToolId.audio);
      expect(find.widgetWithText(ToolbarChipView, 'Audio'), findsOneWidget);
      expect(await tileKeys(tester), ['addMusic', 'recordVoiceover', 'extractAudio']);
      await tap(tester, 'addMusic');
      expect(bindings.calls.single, (EditorActionId.addMusic, EditorActionSource.toolTile));
      await tapChip(tester);
      expect(rig.state.tool, isNull);
      expect(await tileKeys(tester), topLevel);
    });

    testWidgets('rebuilds: playhead moves never rebuild the strip; a selection does (ux.md §16.6)', (tester) async {
      final (rig, _) = await pumpTools(tester);
      final moves = await EditorRebuildCounters.record(() async {
        for (final t in [s, 2 * s, 4 * s]) {
          await rig.seek(t);
        }
      });
      expect(moves['ToolStrip'], isNull);
      final selects = await EditorRebuildCounters.record(() => rig.select(rig.items.textA));
      expect(selects['ToolStrip'], 1);
    });

    testWidgets('before the project is open every tile explains that it is opening', (tester) async {
      final bindings = TestBindings();
      final harness = EditorTestHarness(overrides: [editorActionBindingsProvider.overrideWithValue(bindings.map)]);
      final id = harness.repository.seedEmpty('Opening').id;
      await harness.pumpApp(tester, EditorScope(projectId: id, child: const RegionFrame(regions: {EditorRegion.toolStrip: ToolStrip()})));
      final text = await data(tester, 'tool.text');
      expect(text.enabled, isFalse);
      expect(text.reason, 'The project is still opening');
    });
  });

  group('tiles', () {
    testWidgets('width clamp(label + 16, 64, 112); icon-only tiles hide the label and keep it in the tooltip and semantics',
        (tester) async {
      final handle = tester.ensureSemantics();
      final long = ToolTileData(key: 'k', label: 'A very long tool label indeed', icon: Icons.video_library_rounded, onTap: _noop);
      final short = ToolTileData(key: 's', label: 'Hi', icon: Icons.video_library_rounded, onTap: _noop);
      await tester.pumpWidget(surfaceApp(
        SurfaceMatrix.phone,
        Row(mainAxisSize: MainAxisSize.min, children: [
          ToolTile(key: ValueKey('long'), data: long, height: 64),
          ToolTile(key: ValueKey('short'), data: short, height: 64),
          ToolTile(key: ValueKey('icon'), data: long, height: 48, iconOnly: true),
        ]),
      ));
      expect(tester.getSize(find.byKey(const ValueKey('long'))).width, ToolTile.maxWidth);
      expect(tester.getSize(find.byKey(const ValueKey('short'))).width, ToolTile.minWidth);
      expect(tester.getSize(find.byKey(const ValueKey('icon'))), const Size(ToolTile.iconOnlyWidth, 48));
      expect(find.descendant(of: find.byKey(const ValueKey('icon')), matching: find.text(long.label)), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('icon')), matching: find.byType(Tooltip)), findsOneWidget);
      expect(tester.getSemantics(find.byKey(const ValueKey('icon'))).getSemanticsData().label, long.label);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      handle.dispose();
    });

    testWidgets('the strip follows ladder step 3 (iconOnlyTools)', (tester) async {
      // The narrowest phone with the keyboard up is past step 3 in compactPortrait.
      await pumpTools(tester, surface: const EditorSurface(Size(280, 500), textScale: 1.35, keyboardFraction: 0.4));
      final spec = frameSpec(tester);
      expect(spec.iconOnlyTools, isTrue);
      expect(spec.shows(EditorRegion.toolStrip), isTrue);
      final tiles = tester.widgetList<ToolTile>(find.byType(ToolTile, skipOffstage: false));
      expect(tiles, isNotEmpty);
      expect(tiles.every((t) => t.iconOnly && t.height <= spec.toolTileHeight), isTrue);
      expect(find.descendant(of: find.byType(ToolStrip), matching: find.text('Media')), findsNothing);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });

  group('rail and panes', () {
    testWidgets('expanded: the rail lists the top-level tools whatever is selected; the pane shows the context tools', (tester) async {
      final (rig, _) = await pumpTools(tester, surface: const EditorSurface(Size(1194, 834), platform: TargetPlatform.iOS));
      expect(frameSpec(tester).kind, EditorLayoutKind.expanded);
      final rail = find.byType(ToolRail);
      expect(rail, findsOneWidget);
      expect(await tileKeys(tester, within: rail), topLevel);
      // Nothing selected: the pane is the media bin.
      expect(find.byType(ToolGrid), findsNothing);
      await rig.select(rig.items.textA);
      expect(await tileKeys(tester, within: rail), topLevel);
      final grid = find.byType(ToolGrid);
      expect(grid, findsOneWidget);
      expect(find.descendant(of: grid, matching: find.widgetWithText(ToolbarChipView, 'Text')), findsOneWidget);
      expect((await tileKeys(tester, within: grid)).first, 'text.edit');
      expectNoOverflow(tester);
    });

    testSurfaces('compactLandscape and medium: the side pane shows the tools as a grid', (tester, surface) async {
      final (rig, _) = await pumpTools(tester, surface: surface);
      expect(frameSpec(tester).kind, anyOf(EditorLayoutKind.compactLandscape, EditorLayoutKind.medium));
      expect(find.byType(ToolStrip), findsNothing);
      expect(find.byType(ToolGrid), findsOneWidget);
      expect(find.text('Tools'), findsOneWidget);
      expect(await tileKeys(tester), topLevel);
      await rig.select(rig.items.cue);
      expect(find.widgetWithText(ToolbarChipView, 'Caption'), findsOneWidget);
      expect((await tileKeys(tester)).first, 'cue.edit');
      expectNoOverflow(tester);
    }, surfaces: const [EditorSurface(Size(844, 390)), EditorSurface(Size(834, 1194), platform: TargetPlatform.iOS)]);
  });

  group('matrix (ARCH §17.9)', () {
    testSurfaces('strip, rail and pane fit with nothing selected, a selection and the Audio tab', (tester, surface) async {
      final (rig, _) = await pumpTools(tester, surface: surface);
      void check(String what) {
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        for (final element in find.byType(ToolTile).evaluate()) {
          final box = element.renderObject! as RenderBox;
          expect(box.size.height, lessThanOrEqualTo(frameSpec(tester).toolTileHeight + 0.01), reason: what);
        }
      }

      check('top level');
      await rig.select(rig.items.textA);
      check('text selected');
      rig.editor.selectMarker(rig.items.marker);
      await tester.pump();
      check('marker selected');
      rig.editor.clearSelection();
      rig.editor.setTool(ToolId.audio);
      await tester.pump();
      check('audio tab');
    });
  });
}

void _noop() {}
