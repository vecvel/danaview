// OWNER: UX-44
//
// No-overflow matrix (ARCH §1.3 rule 5, §17.9; BUILD_PLAN UX-44 acceptance): the Render preview
// settings section, the render marker strip and the range sheet at widths 280–1280 and text
// scales 0.85–1.35 (`SurfaceMatrix.current`; the full matrix with
// `--dart-define=DANAVIEW_SURFACE_MATRIX=full`). Also the range sheet's flow: "Render this part"
// renders the tapped range through the controller.

import 'dart:async';

import 'package:danaview_editor/src/app/strings/render_preview_strings.dart';
import 'package:danaview_editor/src/editor/state/render_preview_controller.dart';
import 'package:danaview_editor/src/editor/timeline/render_marker_strip.dart';
import 'package:danaview_editor/src/settings/render_preview_settings_section.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'support.dart';

const _hash = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

Future<(RenderPreviewController, FakeEditorEngine)> _controller() async {
  final engine = FakeEditorEngine();
  final store = MemoryRenderStore();
  final session = await openSession(engine, basePlan());
  final c = controllerFor(engine, store: store)..attach(session);
  await c.planChanged(basePlan());
  return (c, engine);
}

void main() {
  testSurfaces('settings section fits', (tester, surface) async {
    final store = MemoryRenderStore();
    await store.open();
    await store.put(_hash, store.stagingPathFor(_hash));
    final h = EditorTestHarness(
      engine: FakeEditorEngine(caps: fakeDefaultCapabilities.copyWith(tier: DeviceTier.low)),
      overrides: [renderPreviewStoreProvider.overrideWithValue(store)],
    );
    await h.pumpApp(
      tester,
      const Scaffold(
        backgroundColor: DanaviewColors.background,
        body: SingleChildScrollView(padding: EdgeInsets.all(16), child: RenderPreviewSettingsSection()),
      ),
      surface: surface,
    );
    await tester.pumpAndSettle();
    expectNoOverflow(tester);
    _expectWithinWidth(tester, find.byKey(const ValueKey('render-preview-setting')));
    _expectWithinWidth(tester, find.byKey(const ValueKey('render-preview-clear-button')));
    _expectWithinWidth(tester, find.byKey(const ValueKey('render-preview-hint')));
  });

  testSurfaces('marker strip fits the timeline width', (tester, surface) async {
    final (c, _) = await _controller();
    final width = surface.size.width;
    final duration = c.plan!.durUs;
    applySurface(tester, surface);
    await tester.pumpWidget(surfaceApp(
      surface,
      Scaffold(
        backgroundColor: DanaviewColors.background,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: RenderMarkerStrip(state: c.value, xOf: (t) => t / duration * width),
          ),
        ),
      ),
    ));
    expectNoOverflow(tester);
    expectInside(tester, find.byType(RenderMarkerStrip));
    c.dispose();
  });

  testSurfaces('range sheet fits', (tester, surface) async {
    final (c, _) = await _controller();
    final heavy = c.value.heavyUnrendered.first;
    final h = EditorTestHarness();
    await h.pumpApp(
      tester,
      Scaffold(
        backgroundColor: DanaviewColors.background,
        body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: RenderRangeSheetBody(controller: c, range: heavy)),
      ),
      surface: surface,
    );
    expectNoOverflow(tester);
    _expectWithinWidth(tester, find.byKey(const ValueKey('render-range-this')));
    _expectWithinWidth(tester, find.byKey(const ValueKey('render-range-all')));
    c.dispose();
  });

  testWidgets('tapping an amber range offers Render preview, which renders that range', (tester) async {
    final (c, engine) = await _controller();
    final h = EditorTestHarness();
    await h.pumpApp(
      tester,
      Scaffold(
        backgroundColor: DanaviewColors.background,
        body: Builder(
          builder: (context) => ValueListenableBuilder<RenderPreviewState>(
            valueListenable: c,
            builder: (context, state, _) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                child: RenderMarkerStrip(
                  state: state,
                  xOf: (t) => t / microsPerSecond * 80,
                  onRangeTap: (r) => unawaited(showRenderRangeSheet(context, controller: c, range: r)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tapAt(Offset(f(45) / microsPerSecond * 80, RenderMarkerStrip.defaultHeight / 2));
    await tester.pumpAndSettle();
    expect(find.text(RenderPreviewStrings.rangeTitle(f(30), f(60))), findsOneWidget);
    expect(find.text(RenderPreviewStrings.renderThis), findsOneWidget);
    expect(find.text(RenderPreviewStrings.renderAll), findsOneWidget);

    await tester.tap(find.text(RenderPreviewStrings.renderThis));
    await tester.pumpAndSettle();
    expect(engine.jobs.renderRequests, hasLength(1));
    expect(engine.jobs.renderRequests.single.$1.durUs, f(30));
    expect(c.value.ranges.firstWhere((r) => r.range.start == f(30)).state, RangeState.rendered);
    expect(find.text(RenderPreviewStrings.alreadyRendered), findsOneWidget, reason: 'the open sheet follows the controller');
    expectOwnerUiRules(tester);
    c.dispose();
  });
}

/// Inside the screen horizontally (the content scrolls vertically).
void _expectWithinWidth(WidgetTester tester, Finder finder) {
  final width = screenRect(tester).width;
  final rect = tester.getRect(finder);
  expect(rect.left >= -0.5 && rect.right <= width + 0.5, isTrue, reason: '$rect exceeds the width $width');
}
