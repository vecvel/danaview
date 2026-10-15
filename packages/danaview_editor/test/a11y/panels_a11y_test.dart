// OWNER: QA-08
//
// Accessibility of every inspector panel (ARCH §17.7, §17.9) inside the real editor screen, in the
// four layout kinds and on the two smallest PR surfaces at text scale 1.35: tap targets ≥ 44×44
// with labels, text contrast ≥ 4.5:1, nothing overflows. Known defects (FIX tickets) are listed in
// a11y_support.dart and QA-08-a11y.md.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';

import '../support/support.dart';
import 'a11y_support.dart';

final List<EditorSurface> _surfaces = [
  for (final l in layoutSurfaces) l.surface,
  const EditorSurface(Size(280, 500), textScale: 1.35),
  const EditorSurface(Size(568, 320), textScale: 1.35),
];

String _name(InspectorRoute route) => route.toString();

void main() {
  for (final surface in _surfaces) {
    group('[$surface]', () {
      for (final route in everyInspectorRoute) {
        testWidgets(_name(route), (tester) async {
          final semantics = tester.ensureSemantics();
          final rig = await A11yEditorRig.pump(tester, surface: surface);
          await rig.openInspector(route);
          expect(takeKnownException(tester, where: 'opening $route'), isNull);
          expect(rig.state.inspector, route);
          expectNoOverflow(tester);
          await expectA11yGuidelines(tester, where: '$route on $surface');
          semantics.dispose();
        });
      }
    });
  }
}
