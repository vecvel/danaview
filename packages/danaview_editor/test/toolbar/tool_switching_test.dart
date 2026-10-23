// OWNER: UX-16
//
// Tool switching (owner report, iPad landscape): after one tool (Captions) the Audio tile of the
// rail lit up but the pane kept the Captions panel. Audio opens a tab of sub-tools and only set the
// active tool, so the open panel stayed. These tests walk every ordered pair of top-level tools on
// the real bindings and check the pane shows the tool tapped last, also from a Captions section page
// and with a selection; and that a new selection closes the Audio tab.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/panels/adjust_panel.dart';
import 'package:danaview_editor/src/editor/panels/canvas_panel.dart';
import 'package:danaview_editor/src/editor/panels/filters_panel.dart';
import 'package:danaview_editor/src/editor/panels/media_panel.dart';
import 'package:danaview_editor/src/editor/panels/overlay_panel.dart';
import 'package:danaview_editor/src/editor/panels/subtitles_panel.dart';
import 'package:danaview_editor/src/editor/panels/text_panel.dart';
import 'package:danaview_editor/src/editor/panels/transitions_panel.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_grid.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_rail.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_sets.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_strip.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_tile.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../inspector/inspector_rig.dart' show RegionFrame;
import '../panels/color/color_rig.dart';
import '../support/support.dart';

/// iPad landscape (the owner's screenshot): the expanded rail and pane.
const EditorSurface _ipad = EditorSurface(Size(1180, 820), platform: TargetPlatform.iOS);

/// The pane as the scaffold places it: InspectorHost in expanded, else InspectorHost while a panel
/// is open and the tool grid otherwise.
class _Pane extends ConsumerWidget {
  const _Pane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = EditorLayoutSpec.kindOf(size: MediaQuery.sizeOf(context), padding: MediaQuery.paddingOf(context));
    if (kind == EditorLayoutKind.expanded) return const InspectorHost();
    final open = ref.watch(editorControllerProvider(EditorScope.idOf(context)).select((s) => s.inspector != null));
    return open ? const InspectorHost() : const ToolRail();
  }
}

Future<ColorRig> _pump(WidgetTester tester, {EditorSurface surface = _ipad}) async {
  final rig = await ColorRig.pump(
    tester,
    (_) => const RegionFrame(regions: {
      EditorRegion.toolStrip: ToolStrip(),
      EditorRegion.rail: ToolRail(),
      EditorRegion.pane: _Pane(),
    }),
    surface: surface,
  );
  // On clip B, 1 s from the cut at 4 s (Transitions targets it; Effects and Filters target B).
  await rig.seek(5 * s);
  await tester.pump();
  return rig;
}

/// The panel each tool's tile shows (Audio: its tab of sub-tools in a ToolGrid).
const Map<ToolId, Type> _panelOf = {
  ToolId.media: MediaPanel,
  ToolId.audio: ToolGrid,
  ToolId.text: TextPanel,
  ToolId.captions: SubtitlesPanel,
  ToolId.overlay: OverlayPanel,
  ToolId.effects: AdjustPanel,
  ToolId.filters: FiltersPanel,
  ToolId.transitions: TransitionsPanel,
  ToolId.format: CanvasPanel,
};

/// The rail tile of [tool] (the expanded rail is the first ToolRail; others show in the strip).
Finder _railTile(ToolId tool) => find.byKey(ValueKey<String>('tile.tool.${tool.name}'), skipOffstage: false);

Future<void> _tapTool(WidgetTester tester, ToolId tool) async {
  final tile = _railTile(tool).first;
  await tester.ensureVisible(tile);
  await tester.pump();
  await tester.tap(tile);
  await tester.pump();
  await tester.pump();
}

/// The pane shows [tool]'s panel and nothing of the other tools; the rail lights [tool] only.
void _expectShows(WidgetTester tester, ColorRig rig, ToolId tool, String why) {
  final pane = find.byType(InspectorHost);
  expect(rig.state.tool, tool, reason: why);
  for (final MapEntry(key: other, value: panel) in _panelOf.entries) {
    final found = find.descendant(of: pane, matching: find.byType(panel));
    expect(found, other == tool ? findsOneWidget : findsNothing, reason: '$why: pane shows ${other.name}?');
  }
  if (tool == ToolId.audio) {
    expect(rig.state.inspector, isNull, reason: why);
    final keys = [for (final t in tester.widgetList<ToolTile>(find.descendant(of: pane, matching: find.byType(ToolTile)))) t.data.key];
    expect(keys, ToolSets.toolTabs[ToolId.audio]!.map((a) => a.name).toList(), reason: why);
  } else {
    expect(rig.state.inspector, isNotNull, reason: why);
  }
  final lit = [
    for (final t in tester.widgetList<ToolTile>(find.descendant(of: find.byType(ToolRail).first, matching: find.byType(ToolTile))))
      if (t.data.selected) t.data.key,
  ];
  expect(lit, ['tool.${tool.name}'], reason: '$why: rail highlight');
}

Future<void> _reset(WidgetTester tester, ColorRig rig) async {
  rig.editor
    ..closeInspector()
    ..clearSelection()
    ..setTool(null);
  await tester.pump();
}

void main() {
  tearDown(DanaviewToast.dismiss);

  test('ToolId.opensTab names exactly the tools of ToolSets.toolTabs', () {
    expect({for (final t in ToolId.values) if (t.opensTab) t}, ToolSets.toolTabs.keys.toSet());
  });

  group('every pair of top-level tools (iPad landscape, expanded rail)', () {
    testWidgets('A then B shows B for all 81 ordered pairs', (tester) async {
      final rig = await _pump(tester);
      var pairs = 0;
      for (final a in ToolId.stripOrder) {
        for (final b in ToolId.stripOrder) {
          await _reset(tester, rig);
          await rig.seek(5 * s);
          await _tapTool(tester, a);
          _expectShows(tester, rig, a, '${a.name} first');
          await _tapTool(tester, b);
          _expectShows(tester, rig, b, '${a.name} then ${b.name}');
          pairs++;
        }
      }
      expect(pairs, 81);
      expectNoOverflow(tester);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('one long walk through every tool after every other, without resets', (tester) async {
      final rig = await _pump(tester);
      for (final a in ToolId.stripOrder) {
        for (final b in ToolId.stripOrder) {
          await rig.seek(5 * s);
          await _tapTool(tester, a);
          _expectShows(tester, rig, a, 'walk ${a.name}');
          await _tapTool(tester, b);
          _expectShows(tester, rig, b, 'walk ${a.name} -> ${b.name}');
        }
      }
      expectNoOverflow(tester);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a tool tapped while a Captions section page is open shows that tool', (tester) async {
      final rig = await _pump(tester);
      for (final b in ToolId.stripOrder) {
        await _reset(tester, rig);
        await _tapTool(tester, ToolId.captions);
        rig.editor.openInspector(const SubtitlesInspector(section: SubtitlesPanelSection.style));
        await tester.pump();
        expect(find.byType(SubtitlesPanel), findsOneWidget);
        await rig.seek(5 * s);
        await _tapTool(tester, b);
        _expectShows(tester, rig, b, 'captions style page then ${b.name}');
      }
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('Audio shows its tab over a selected clip; a new selection closes the tab', (tester) async {
      final rig = await _pump(tester);
      rig.editor.select(ColorIds.b);
      await tester.pump();
      await _tapTool(tester, ToolId.audio);
      _expectShows(tester, rig, ToolId.audio, 'audio over a selection');
      expect(rig.state.selection.primary, ColorIds.b, reason: 'Extract audio still targets the clip');
      rig.editor.select(ColorIds.c);
      await tester.pump();
      expect(rig.state.tool, isNull);
      expect(find.descendant(of: find.byType(InspectorHost), matching: find.byKey(const ValueKey<String>('tile.extractAudio'))),
          findsOneWidget, reason: 'the clip\'s context tools show');
      expect(find.descendant(of: find.byType(InspectorHost), matching: find.byKey(const ValueKey<String>('tile.addMusic'))),
          findsNothing);
    });
  });

  group('the rail highlight follows the pane (verify pass on the iPad)', () {
    /// Tiles of the expanded rail that read as active.
    List<String> lit(WidgetTester tester) => [
          for (final t in tester.widgetList<ToolTile>(find.descendant(of: find.byType(ToolRail).first, matching: find.byType(ToolTile))))
            if (t.data.selected) t.data.key,
        ];

    testWidgets('closing a panel leaves no tool lit while the pane shows the media bin', (tester) async {
      final rig = await _pump(tester);
      for (final tool in ToolId.stripOrder.where((t) => !t.opensTab)) {
        await _reset(tester, rig);
        await rig.seek(5 * s);
        await _tapTool(tester, tool);
        expect(lit(tester), ['tool.${tool.name}'], reason: '${tool.name} open');
        rig.editor.closeInspector();
        await tester.pump();
        expect(rig.state.inspector, isNull);
        expect(lit(tester), isEmpty, reason: '${tool.name} closed: nothing open, nothing lit');
      }
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('undo removing the text the Text tool added un-lights Text', (tester) async {
      final rig = await _pump(tester);
      await _tapTool(tester, ToolId.text);
      expect(find.byType(TextPanel), findsOneWidget);
      expect(lit(tester), ['tool.text']);
      expect(rig.editor.undo(), isTrue);
      await tester.pump();
      await tester.pump();
      expect(find.byType(TextPanel), findsNothing);
      expect(lit(tester), isEmpty, reason: 'the pane no longer shows the Text panel');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the Audio tab stays lit while its tab shows', (tester) async {
      final rig = await _pump(tester);
      await _tapTool(tester, ToolId.audio);
      expect(rig.state.inspector, isNull);
      expect(lit(tester), ['tool.audio']);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('other expanded surfaces', () {
    testSurfaces('Captions then Audio shows the Audio tab, no overflow', (tester, surface) async {
      final rig = await _pump(tester, surface: surface);
      await _tapTool(tester, ToolId.captions);
      expect(rig.state.inspector, isA<SubtitlesInspector>());
      await _tapTool(tester, ToolId.audio);
      expect(rig.state.tool, ToolId.audio);
      expect(rig.state.inspector, isNull);
      expect(find.byType(SubtitlesPanel), findsNothing);
      expect(find.byKey(const ValueKey<String>('tile.addMusic'), skipOffstage: false), findsWidgets);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await tester.pump(const Duration(seconds: 3));
    }, surfaces: const [
      EditorSurface(Size(1280, 800), textScale: 0.85),
      EditorSurface(Size(1366, 1024), platform: TargetPlatform.iOS),
      EditorSurface(Size(1180, 820), textScale: 1.35, platform: TargetPlatform.iOS),
    ]);
  });
}
