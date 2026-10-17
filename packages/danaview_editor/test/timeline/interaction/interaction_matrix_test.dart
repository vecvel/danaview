// OWNER: UX-13
//
// The interaction layer's pills (drag, snap, "New track") fit from 280 to 1280 px wide at text
// scale 1.35 without overflow, stay on screen, and follow the owner UI rules (Figtree, solid
// surfaces).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_hit.dart';

import '../../support/owner_ui_rules.dart';
import '../../support/surface_matrix.dart';
import 'interaction_support.dart';

const List<EditorSurface> _surfaces = [
  EditorSurface(Size(280, 500), textScale: 1.35),
  EditorSurface(Size(568, 320), textScale: 1.35),
  EditorSurface(Size(834, 1194), textScale: 1.35, platform: TargetPlatform.iOS),
  EditorSurface(Size(1280, 800), textScale: 1.35, platform: TargetPlatform.macOS),
];

void main() {
  testSurfaces('trim and snap pills fit', (tester, surface) async {
    final t = await pumpTimeline(tester,
        project: interactionProject(), size: surface.size, textScale: surface.textScale, platform: surface.platform, pxPerSecond: 40);
    final i = interactionOf(t);
    unawaited(t.container.read(playheadProvider(t.id)).seekExact(2 * s + s ~/ 2));
    await tester.tapAt(t.at(tester, 1500000, 'tr_subs'));
    await tester.pump();
    final g = await tester.startGesture(trimHandleAt(tester, t, 'cue_1', TrimEdge.end));
    await g.moveBy(const Offset(10, 0));
    await g.moveBy(const Offset(9, 0)); // ~2.47 s: in reach of the playhead at 2.5 s.
    await tester.pump();
    expect(i.pill, isNotNull);
    expect(find.byKey(const ValueKey('drag-pill')), findsOneWidget);
    expect(find.byKey(const ValueKey('snap-pill')), findsOneWidget);
    expectNoOverflow(tester);
    expectInside(tester, find.byKey(const ValueKey('drag-pill')));
    expectInside(tester, find.byKey(const ValueKey('snap-pill')));
    expectOwnerUiRules(tester);
    await g.up();
    await tester.pump();
    expect(t.historyDepth, 1);
    await tester.pump(const Duration(seconds: 2));
  }, surfaces: _surfaces);
}
