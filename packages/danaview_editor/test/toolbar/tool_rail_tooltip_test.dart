// OWNER: UX-16
//
// QA-01 step 4 (owner, iPad with a pointer): the left tool rail showed no tooltip on hover while the
// top bar and the timeline did. The tiles passed no tooltip while their label was visible; now every
// tile carries its full name (and shortcut) as the tooltip through DanaviewPressable's hover path.
// Also: the rail labels fit in full at text scale 0.85–1.35 ("Transitions" was "Transitio…"), and
// the top-bar buttons keep their hover tooltips.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_lifecycle.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/layout/editor_shell_strings.dart';
import 'package:danaview_editor/src/editor/layout/editor_top_bar.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_grid.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_rail.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_tile.dart';
import 'package:danaview_editor/src/editor/toolbar/toolbar_strings.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../inspector/inspector_rig.dart' show frameSpec;
import '../overflow/overflow_rig.dart' show loadRealFonts;
import '../support/support.dart';
import 'tool_strip_test.dart' show pumpTools, reveal, tile, topLevel;

const EditorSurface _ipadLandscape = EditorSurface(Size(1194, 834), platform: TargetPlatform.iOS);
const EditorSurface _ipadPortrait = EditorSurface(Size(834, 1194), platform: TargetPlatform.iOS);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Whether the tooltip [tip] shows: its text inside Material's tooltip box, faded in (labels and
/// panel headers with the same text do not count).
bool _shown(WidgetTester tester, String tip) {
  final box = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TooltipBox');
  for (final e in find.descendant(of: box, matching: find.text(tip)).evaluate()) {
    final fades = find.ancestor(of: find.byElementPredicate((x) => x == e), matching: find.byType(FadeTransition)).evaluate();
    if (fades.every((f) => (f.widget as FadeTransition).opacity.value == 1.0)) return true;
  }
  return false;
}

String _tipOf(WidgetTester tester, String key) {
  final data = tester.widget<ToolTile>(tile(key)).data;
  return data.tooltip ?? data.label;
}

void main() {
  setUpAll(loadRealFonts);
  tearDown(DanaviewToast.dismiss);

  group('rail tooltips on pointer hover', () {
    testWidgets('a mouse hover over each rail tile shows its full name after the wait, and hides on leave', (tester) async {
      await pumpTools(tester, surface: _ipadLandscape);
      expect(frameSpec(tester).kind, EditorLayoutKind.expanded);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1100, 20));
      addTearDown(mouse.removePointer);
      await tester.pump();
      for (final key in topLevel) {
        await reveal(tester, key);
        final tip = _tipOf(tester, key);
        expect(tip, startsWith(ToolbarStrings.tool(ToolId.values.byName(key.substring('tool.'.length)))), reason: key);
        await tester.ensureVisible(tile(key));
        await tester.pump();
        await mouse.moveTo(tester.getCenter(tile(key)));
        await tester.pump(const Duration(milliseconds: 200));
        expect(_shown(tester, tip), isFalse, reason: '$key: not before the wait');
        await _settle(tester);
        expect(_shown(tester, tip), isTrue, reason: '$key: "$tip" shows on hover');
        await mouse.moveTo(const Offset(1100, 20));
        await _settle(tester);
        expect(_shown(tester, tip), isFalse, reason: '$key: hidden after leaving');
      }
    });

    testWidgets('hover events the mouse tracker ignores (the iPad pointer path) still show the rail tooltip', (tester) async {
      await pumpTools(tester, surface: _ipadLandscape);
      await reveal(tester, 'tool.transitions');
      await tester.ensureVisible(tile('tool.transitions'));
      await tester.pump();
      final tip = _tipOf(tester, 'tool.transitions');
      tester.binding.handlePointerEvent(
          PointerHoverEvent(kind: PointerDeviceKind.trackpad, device: 9, position: tester.getCenter(tile('tool.transitions'))));
      await _settle(tester);
      expect(_shown(tester, tip), isTrue);
      tester.binding.handlePointerEvent(const PointerHoverEvent(kind: PointerDeviceKind.trackpad, device: 9, position: Offset(1100, 20)));
      await _settle(tester);
      expect(_shown(tester, tip), isFalse);
    });

    testWidgets('a touch tap on each rail tile shows no tooltip', (tester) async {
      await pumpTools(tester, surface: _ipadLandscape);
      for (final key in topLevel) {
        await reveal(tester, key);
        await tester.ensureVisible(tile(key));
        await tester.pump();
        final tip = _tipOf(tester, key);
        await tester.tap(tile(key));
        await _settle(tester);
        expect(_shown(tester, tip), isFalse, reason: key);
        DanaviewToast.dismiss();
        await tester.pump();
      }
    });
  });

  group('rail labels fit in full', () {
    for (final surface in [_ipadLandscape, _ipadPortrait]) {
      for (final scale in SurfaceMatrix.textScales) {
        testWidgets('every tool name fits its tile, no ellipsis (${surface.size} @$scale)', (tester) async {
          await pumpTools(tester, surface: surface.copyWith(textScale: scale));
          final owner = find.byType(frameSpec(tester).kind == EditorLayoutKind.expanded ? ToolRail : ToolGrid);
          expect(owner, findsOneWidget);
          for (final key in topLevel) {
            await reveal(tester, key);
            await tester.ensureVisible(tile(key));
            await tester.pump();
            final t = find.descendant(of: owner, matching: tile(key));
            expect(t, findsOneWidget, reason: key);
            final data = tester.widget<ToolTile>(t).data;
            final label = find.descendant(of: t, matching: find.text(data.label));
            expect(label, findsOneWidget, reason: '$key shows its label');
            final text = tester.widget<Text>(label);
            expect(text.overflow, isNot(TextOverflow.ellipsis), reason: key);
            final paragraph = tester.renderObject<RenderParagraph>(find.descendant(of: label, matching: find.byType(RichText)));
            expect(paragraph.didExceedMaxLines, isFalse, reason: key);
            // Painted bounds (after any scale-down) lie inside the tile.
            final tileRect = tester.getRect(t);
            final painted = MatrixUtils.transformRect(paragraph.getTransformTo(null), Offset.zero & paragraph.size);
            expect(painted.left, greaterThanOrEqualTo(tileRect.left - 0.01), reason: key);
            expect(painted.right, lessThanOrEqualTo(tileRect.right + 0.01), reason: key);
            // The whole name is laid out on its line (nothing clipped).
            expect(paragraph.size.width + 0.01, greaterThanOrEqualTo(paragraph.getMaxIntrinsicWidth(double.infinity)), reason: key);
            // Never smaller than the label's nominal size at 1.0 (or the user's smaller scale).
            final fit = painted.width / paragraph.size.width;
            final effective = ToolTile.labelStyle.fontSize! * scale * fit;
            expect(effective, greaterThanOrEqualTo(ToolTile.labelStyle.fontSize! * (scale < 1 ? scale : 1.0) - 0.01),
                reason: '$key renders at ${effective.toStringAsFixed(1)} px');
          }
          expect(fitsFullyProblems(tester, owner).where((p) => p.contains('truncated')), isEmpty);
          expectNoOverflow(tester);
          expectOwnerUiRules(tester);
        });
      }
    }
  });

  group('top bar tooltips (unchanged)', () {
    const tips = [
      (Icons.arrow_back_ios_new_rounded, EditorShellStrings.closeEditor),
      (Icons.undo_rounded, 'Undo Split clip (⌘Z)'),
      (Icons.redo_rounded, 'Redo Trim (⇧⌘Z)'),
    ];

    Future<void> pumpBar(WidgetTester tester) async {
      applySurface(tester, _ipadLandscape);
      await tester.pumpWidget(surfaceApp(
        _ipadLandscape,
        Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: 64,
            child: EditorTopBar(
              kind: EditorLayoutKind.expanded,
              status: const EditorShellStatus(
                phase: EditorShellPhase.ready,
                projectName: 'Goa trip',
                canUndo: true,
                canRedo: true,
                undoLabel: 'Split clip',
                redoLabel: 'Trim',
              ),
              closing: false,
              onClose: () {},
              onUndo: () {},
              onRedo: () {},
              onExport: () {},
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('a mouse hover over Close, Undo and Redo shows the tooltip with the shortcut', (tester) async {
      await pumpBar(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(600, 500));
      addTearDown(mouse.removePointer);
      for (final (icon, tip) in tips) {
        await mouse.moveTo(tester.getCenter(find.byIcon(icon)));
        await _settle(tester);
        expect(_shown(tester, tip), isTrue, reason: tip);
        await mouse.moveTo(const Offset(600, 500));
        await _settle(tester);
        expect(_shown(tester, tip), isFalse, reason: tip);
      }
    });

    testWidgets('a touch tap on Close, Undo and Redo shows no tooltip', (tester) async {
      await pumpBar(tester);
      for (final (icon, tip) in tips) {
        await tester.tap(find.byIcon(icon));
        await _settle(tester);
        expect(_shown(tester, tip), isFalse, reason: tip);
      }
    });
  });
}
