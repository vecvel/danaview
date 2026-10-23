// Owner rule (clean-cross-platform-ui): no hover or press effect on controls. The editor's tool
// tile, track-header toggle and filter look tile paint the same on hover and press as idle; the
// active tool keeps its fill and the selected look its ring.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/timeline/track_headers.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_tile.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../support/support.dart';
import '../timeline/tracks/track_headers_test.dart' show pumpHeaders;
import '../timeline/tracks/track_test_support.dart' show allKindsProject;

Future<void> _pumpTile(WidgetTester tester, {bool selected = false}) async {
  const surface = EditorSurface(Size(400, 400), platform: TargetPlatform.macOS);
  applySurface(tester, surface);
  await tester.pumpWidget(surfaceApp(
    surface,
    Center(
      child: ToolTile(
        height: 64,
        data: ToolTileData(key: 'split', label: 'Split', icon: Icons.content_cut_rounded, selected: selected, onTap: () {}),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('ToolTile: hover and press paint like idle', (tester) async {
    await _pumpTile(tester);
    await expectNoHoverOrPressEffect(tester, find.byType(ToolTile), what: 'ToolTile');
    expect(tester.takeException(), isNull);
  });

  testWidgets('ToolTile: the active tool still carries its fill, also on hover and press', (tester) async {
    await _pumpTile(tester);
    final pressable = find.descendant(of: find.byType(ToolTile), matching: find.byType(DanaviewPressable));
    final idle = pressableVisualSignature(tester.renderObject(pressable));
    await _pumpTile(tester, selected: true);
    final active = pressableVisualSignature(tester.renderObject(pressable));
    expect(active, isNot(orderedEquals(idle)));
    expect(active.join('\n'), contains('${DanaviewColors.primaryTonal}'));
    await expectNoHoverOrPressEffect(tester, find.byType(ToolTile), what: 'active ToolTile');
  });

  testWidgets('TrackToggle: hover and press paint like idle', (tester) async {
    await pumpHeaders(tester, allKindsProject(), width: 220);
    final toggles = find.byType(TrackToggle);
    expect(toggles, findsWidgets);
    await expectNoHoverOrPressEffect(tester, toggles.first, what: 'TrackToggle');
  });
}
