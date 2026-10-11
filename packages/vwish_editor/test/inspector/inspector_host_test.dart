// OWNER: UX-16
//
// InspectorHost, InspectorView, InspectorDock and InspectorHeader (ux.md §9.3): route -> panel
// mapping, dock in compactPortrait and side pane elsewhere, re-targeting on selection change,
// header back/done/reset/keyframe-all, and the surface matrix.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/inspector/inspector_dock.dart';
import 'package:vwish_editor/src/editor/inspector/inspector_header.dart';
import 'package:vwish_editor/src/editor/inspector/inspector_host.dart';
import 'package:vwish_editor/src/editor/inspector/keyframe_toggle.dart';
import 'package:vwish_editor/src/editor/layout/editor_layout.dart';
import 'package:vwish_editor/src/editor/panels/adjust_panel.dart';
import 'package:vwish_editor/src/editor/panels/audio_panel.dart';
import 'package:vwish_editor/src/editor/panels/canvas_panel.dart';
import 'package:vwish_editor/src/editor/panels/chroma_panel.dart';
import 'package:vwish_editor/src/editor/panels/clip_info_panel.dart';
import 'package:vwish_editor/src/editor/panels/crop_panel.dart';
import 'package:vwish_editor/src/editor/panels/filters_panel.dart';
import 'package:vwish_editor/src/editor/panels/keyframes_panel.dart';
import 'package:vwish_editor/src/editor/panels/mask_panel.dart';
import 'package:vwish_editor/src/editor/panels/media_panel.dart';
import 'package:vwish_editor/src/editor/panels/overlay_panel.dart';
import 'package:vwish_editor/src/editor/panels/speed_panel.dart';
import 'package:vwish_editor/src/editor/panels/subtitles_panel.dart';
import 'package:vwish_editor/src/editor/panels/text_panel.dart';
import 'package:vwish_editor/src/editor/panels/transform_panel.dart';
import 'package:vwish_editor/src/editor/panels/transitions_panel.dart';
import 'package:vwish_editor/src/editor/panels/voiceover_panel.dart';
import 'package:vwish_editor/src/editor/toolbar/tool_strip.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../support/support.dart';
import 'inspector_rig.dart';

const ItemId _i = ItemId('it_x');

/// Side pane and dock, as the scaffold places them.
Widget _frame(ProjectId id, {bool open = true}) => RegionFrame(
      inspectorOpen: open,
      regions: const {EditorRegion.pane: InspectorHost(), EditorRegion.toolStrip: ToolStrip()},
      dock: const InspectorDock(),
    );

Future<InspectorRig> _pump(WidgetTester tester, {EditorSurface surface = SurfaceMatrix.phone, bool open = true}) =>
    InspectorRig.pump(tester, (id) => _frame(id, open: open), surface: surface);

Future<void> _open(InspectorRig rig, InspectorRoute route) async {
  rig.editor.openInspector(route);
  await rig.tester.pump();
}

void main() {
  group('route -> panel (ux.md §9.3)', () {
    final table = <InspectorRoute, (Type, String)>{
      const MediaInspector(): (MediaPanel, 'Media'),
      const VoiceoverInspector(): (VoiceoverPanel, 'Voiceover'),
      const OverlayInspector(): (OverlayPanel, 'Overlay'),
      const CanvasInspector(): (CanvasPanel, 'Format'),
      const TransformInspector(_i): (TransformPanel, 'Transform'),
      const CropInspector(_i): (CropPanel, 'Crop'),
      const MaskInspector(_i): (MaskPanel, 'Mask'),
      const SpeedInspector(_i): (SpeedPanel, 'Speed'),
      const AudioInspector(_i): (AudioPanel, 'Volume'),
      const AudioInspector(_i, focus: AudioPanelFocus.fades): (AudioPanel, 'Fades'),
      const AdjustInspector(_i): (AdjustPanel, 'Adjust'),
      const FiltersInspector(_i): (FiltersPanel, 'Filters'),
      const ChromaInspector(_i): (ChromaPanel, 'Chroma key'),
      const KeyframesInspector(_i): (KeyframesPanel, 'Keyframes'),
      const TextInspector(_i): (TextPanel, 'Text'),
      const ClipInfoInspector(_i): (ClipInfoPanel, 'Clip info'),
      const SubtitlesInspector(): (SubtitlesPanel, 'Captions'),
      const TransitionInspector(TransitionRef(TrackId('t'), ItemId('a'), ItemId('b'))): (TransitionsPanel, 'Transition'),
    };
    for (final MapEntry(key: route, value: (type, title)) in table.entries) {
      test('$route', () {
        final panel = InspectorRoutes.panelFor(route);
        expect(panel.runtimeType, type);
        expect((panel as dynamic).route, route);
        expect(InspectorRoutes.titleOf(route), title);
      });
    }
  });

  group('placement', () {
    testWidgets('compactPortrait: a VwishDockedPanel at the dock height, above the timeline; no side pane', (tester) async {
      final rig = await _pump(tester);
      await _open(rig, TextInspector(rig.items.textA));
      final spec = frameSpec(tester);
      expect(spec.kind, EditorLayoutKind.compactPortrait);
      expect(find.byType(InspectorHost), findsNothing);
      final panel = tester.widget<VwishDockedPanel>(find.byType(VwishDockedPanel));
      expect(panel.standardHeight, spec.dockHeight);
      expect(panel.expandedFraction, InspectorDock.expandedFraction);
      expect(find.byType(TextPanel), findsOneWidget);
      expect(find.descendant(of: find.byType(InspectorHeader), matching: find.text('Text')), findsOneWidget);
      final dock = tester.getRect(find.byType(InspectorDock));
      expect(dock.top, moreOrLessEquals(spec.rectOf(EditorRegion.dock)!.top));
      expect(dock.bottom, moreOrLessEquals(844));
      expectNoOverflow(tester);
    });

    testWidgets('the dock expands to 85% of the screen from its handle and resets for another panel', (tester) async {
      final rig = await _pump(tester);
      await _open(rig, TextInspector(rig.items.textA));
      final standard = tester.getSize(find.byType(InspectorDock)).height;
      await tester.tap(find.bySemanticsLabel('Resize panel'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(InspectorDock)).height, greaterThan(standard));
      expect(tester.getSize(find.byType(InspectorDock)).height, moreOrLessEquals(844 * 0.85, epsilon: 1));
      await _open(rig, const CanvasInspector());
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(InspectorDock)).height, moreOrLessEquals(standard));
    });

    testWidgets('the dock sits above the keyboard', (tester) async {
      final rig = await _pump(tester, surface: const EditorSurface(Size(390, 844), keyboardFraction: 0.4, platform: TargetPlatform.iOS));
      await _open(rig, TextInspector(rig.items.textA));
      final keyboard = (844 * 0.4).roundToDouble();
      final panel = tester.getRect(find.byType(VwishDockedPanel));
      expect(find.byType(TextPanel), findsOneWidget);
      final header = tester.getRect(find.byType(InspectorHeader));
      expect(header.bottom, lessThanOrEqualTo(844 - keyboard));
      expect(panel.bottom, moreOrLessEquals(844));
      expectNoOverflow(tester);
    });

    testWidgets('compactLandscape and medium: the side pane hosts the panel; no dock', (tester) async {
      for (final surface in const [EditorSurface(Size(844, 390)), EditorSurface(Size(744, 1133), platform: TargetPlatform.iOS)]) {
        final rig = await _pump(tester, surface: surface);
        await _open(rig, AdjustInspector(rig.items.textA));
        // Text does not support Adjust: the host closes it (re-targeting rule).
        await tester.pump();
        expect(rig.state.inspector, isNull);
        await _open(rig, TransformInspector(rig.items.textA));
        expect(find.byType(VwishDockedPanel), findsNothing);
        final pane = frameSpec(tester).rectOf(EditorRegion.pane)!;
        expect(tester.getRect(find.byType(InspectorHost)), pane);
        expect(find.descendant(of: find.byType(InspectorHost), matching: find.byType(TransformPanel)), findsOneWidget);
        expectNoOverflow(tester);
      }
    });

    testWidgets('expanded: the pane shows the media bin when idle, the panel when open', (tester) async {
      final rig = await _pump(tester, surface: const EditorSurface(Size(1280, 800), textScale: 0.85));
      expect(frameSpec(tester).kind, EditorLayoutKind.expanded);
      expect(find.byType(MediaPanel), findsOneWidget);
      expect(find.byType(InspectorHeader), findsNothing);
      await _open(rig, const CanvasInspector());
      expect(find.byType(CanvasPanel), findsOneWidget);
      expect(find.byType(InspectorHeader), findsOneWidget);
    });
  });

  group('re-targeting (ux.md §9.3)', () {
    testWidgets('a supported item re-targets the open panel in place', (tester) async {
      final rig = await _pump(tester);
      await rig.select(rig.items.textA);
      await _open(rig, TextInspector(rig.items.textA, tab: TextPanelTab.font));
      final element = tester.element(find.byType(TextPanel));
      await rig.select(rig.items.textB);
      expect(rig.state.inspector, TextInspector(rig.items.textB, tab: TextPanelTab.font));
      expect(tester.widget<TextPanel>(find.byType(TextPanel)).route.item, rig.items.textB);
      // Same panel element: its local state survives the re-target.
      expect(identical(tester.element(find.byType(TextPanel)), element), isTrue);
    });

    testWidgets('an item that does not support the panel closes it and shows its context tools', (tester) async {
      final rig = await _pump(tester);
      await rig.select(rig.items.textA);
      await _open(rig, TransformInspector(rig.items.textA));
      await rig.select(rig.items.cue);
      await tester.pump();
      expect(rig.state.inspector, isNull);
      expect(find.byType(TransformPanel), findsNothing);
      expect(rig.state.selection.primary, rig.items.cue);
    });

    testWidgets('project panels stay when the selection changes or clears', (tester) async {
      final rig = await _pump(tester);
      await _open(rig, const CanvasInspector());
      await rig.select(rig.items.cue);
      rig.editor.clearSelection();
      await tester.pump();
      expect(rig.state.inspector, const CanvasInspector());
      expect(find.byType(CanvasPanel), findsOneWidget);
    });
  });

  group('header', () {
    testWidgets('back closes the panel and keeps the selection; done also leaves the tool', (tester) async {
      final rig = await _pump(tester);
      await rig.select(rig.items.textA);
      rig.editor.setTool(ToolId.text);
      await _open(rig, TextInspector(rig.items.textA));
      await tester.tap(find.byTooltip(InspectorStrings.back));
      await tester.pump();
      expect(rig.state.inspector, isNull);
      expect(rig.state.selection.primary, rig.items.textA);
      expect(rig.state.tool, ToolId.text);
      await _open(rig, TextInspector(rig.items.textA));
      await tester.tap(find.byTooltip(InspectorStrings.done));
      await tester.pump();
      expect(rig.state.inspector, isNull);
      expect(rig.state.tool, isNull);
    });

    testWidgets('panels publish reset and keyframe-all; reset asks only when keyframes would go', (tester) async {
      var resets = 0;
      var keyframeAll = 0;
      final slot = ValueNotifier<InspectorHeaderActions>(InspectorHeaderActions.none);
      var removesKeys = false;
      late StateSetter setOuter;
      await tester.pumpWidget(surfaceApp(
        SurfaceMatrix.phone,
        InspectorHeaderSlot(
          actions: slot,
          child: Column(children: [
            ValueListenableBuilder<InspectorHeaderActions>(
              valueListenable: slot,
              builder: (context, actions, _) => InspectorHeader(title: 'Adjust', actions: actions, onBack: () {}, onDone: () {}),
            ),
            StatefulBuilder(builder: (context, setState) {
              setOuter = setState;
              return InspectorHeaderActions.publish(
                actions: InspectorHeaderActions(
                  onReset: () => resets++,
                  resetRemovesKeyframes: removesKeys,
                  keyframeAll: const KeyframeStatus(KeyframeToggleState.animated),
                  onKeyframeAll: () => keyframeAll++,
                ),
                child: const SizedBox(height: 100),
              );
            }),
          ]),
        ),
      ));
      await tester.pump();
      expect(find.byTooltip(InspectorStrings.reset), findsOneWidget);
      expect(find.byIcon(Icons.diamond_outlined), findsOneWidget);
      await tester.tap(find.byTooltip(InspectorStrings.reset));
      await tester.pumpAndSettle();
      expect(resets, 1);
      await tester.tap(find.byIcon(Icons.diamond_outlined));
      await tester.pump();
      expect(keyframeAll, 1);

      setOuter(() => removesKeys = true);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip(InspectorStrings.reset));
      await tester.pumpAndSettle();
      expect(find.text('Reset Adjust?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(resets, 1);
      await tester.tap(find.byTooltip(InspectorStrings.reset));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(VwishButton, 'Reset'));
      await tester.pumpAndSettle();
      expect(resets, 2);
      slot.dispose();
    });

    testWidgets('a panel that goes away clears its header actions', (tester) async {
      final slot = ValueNotifier<InspectorHeaderActions>(InspectorHeaderActions.none);
      var show = true;
      late StateSetter set;
      await tester.pumpWidget(surfaceApp(
        SurfaceMatrix.phone,
        InspectorHeaderSlot(
          actions: slot,
          child: StatefulBuilder(builder: (context, setState) {
            set = setState;
            return show
                ? InspectorHeaderActions.publish(actions: InspectorHeaderActions(onReset: () {}), child: const SizedBox())
                : const SizedBox();
          }),
        ),
      ));
      await tester.pump();
      expect(slot.value.onReset, isNotNull);
      set(() => show = false);
      await tester.pump();
      await tester.pump();
      expect(slot.value, InspectorHeaderActions.none);
      slot.dispose();
    });
  });

  group('matrix (ARCH §17.9)', () {
    testSurfaces('dock or side pane with a panel open fits', (tester, surface) async {
      final rig = await _pump(tester, surface: surface);
      for (final route in [TextInspector(rig.items.textA), const CanvasInspector(), SubtitlesInspector(cue: rig.items.cue)]) {
        await _open(rig, route);
        await tester.pump();
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        expect(find.byType(InspectorHeader), findsOneWidget, reason: '$route');
        expectInside(tester, find.byType(InspectorHeader));
      }
    });
  });
}
