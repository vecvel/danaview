// OWNER: QA-04
//
// Timeline and playback rows of ARCH §18.2 on a 1,000-item project (API-01 fake engine, so only
// the UI is measured):
//
//   ui.timeline.uiP90 / uiP99   fling and pinch: UI thread per frame ≤ 8 (p99 ≤ 14) / ≤ 5 (≤ 10) ms
//   ui.timeline.rasterP90       fling and pinch: raster per frame ≤ 10 / ≤ 7 ms
//   ui.playback.uiP90           playback with centre-follow: UI per frame ≤ 3 ms
//   ui.playback.rebuilds        playback: 0 widget rebuilds except `TimecodeText` (UX-01 counters)
//   ui.scrub.issue              centre-locked drag → scrub seek issued (UI half of the scrub row)
//
// The UI and raster numbers are the engine's FrameTiming build/raster durations (what
// TimelineSummary reports from a `flutter drive --profile` timeline; perf_driver.dart writes both)
// and the pump wall time on hosts where the engine reports no FrameTiming. A miss on the low-tier
// device triggers the ARCH §18.2 remedy order, starting with UX-43's tile cache.
//
//   cd packages/danaview_editor
//   flutter test integration_test/perf/timeline_perf_test.dart -d flutter-tester

import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/debug/debug.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_view.dart';
import 'package:danaview_editor/src/editor/preview/text_overlay_painter.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../../test/support/editor_test_harness.dart';
import '../../test/support/surface_matrix.dart';
import 'perf_support.dart';

/// `TimecodeText`'s rebuild counter (UX-14), the one widget allowed to rebuild per playback frame.
const String _timecode = 'TimecodeText';

Future<(EditorTestHarness, ProjectId)> _open(WidgetTester tester) async {
  final h = EditorTestHarness(engine: FakeEditorEngine(validatePlans: false));
  final project = perfProject(items: 1000);
  final id = h.repository.seed(project);
  await h.pumpEditor(tester, projectId: id, surface: SurfaceMatrix.phone);
  final ready = await pumpUntil(tester, () {
    final s = h.engine.sessions;
    return s.isNotEmpty && s.last.plan != null && h.containerOf(tester).read(editorControllerProvider(id)).phase == EditorPhase.ready;
  }, timeout: const Duration(seconds: 60));
  expect(ready, isTrue);
  expect(find.byType(TimelineView), findsOneWidget);
  // Park the playhead mid-project so flings have room both ways.
  await h.containerOf(tester).read(transportProvider(id)).seekTo(FrameRate.fps30.timeOfFrame(30 * 600));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return (h, id);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Engine-driven frames: pumps wait for real vsync frames, so FrameTiming carries real build and
  // raster durations (the benchmark setup of Flutter's own scrolling perf tests).
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('timeline fling and pinch on 1,000 items: UI and raster per frame', (tester) async {
    final (h, id) = await _open(tester);
    final viewport = h.containerOf(tester).read(viewportProvider(id));
    final zoom0 = viewport.pxPerSecond;
    final pxStart = viewport.centerTimeSec;
    var scrolled = false, zoomed = false;
    final timeline = find.byType(TimelineView);
    final rect = tester.getRect(timeline);
    final centre = rect.center;
    final rec = FrameRecorder()..start();

    Future<void> scenario() async {
      for (final dx in [-500.0, 600.0, -700.0]) {
        await tester.flingFrom(centre, Offset(dx, 0), 3000);
        for (var i = 0; i < 50; i++) {
          await rec.pump(tester);
        }
        scrolled |= (viewport.centerTimeSec - pxStart).abs() > 1;
      }
      for (final spread in [1.0, -1.0, 1.0]) {
        final a = await tester.startGesture(centre - const Offset(40, 0), pointer: 7);
        final b = await tester.startGesture(centre + const Offset(40, 0), pointer: 8);
        for (var i = 0; i < 20; i++) {
          await a.moveBy(Offset(-6 * spread, 0));
          await b.moveBy(Offset(6 * spread, 0));
          await rec.pump(tester);
        }
        await a.up();
        await b.up();
        for (var i = 0; i < 10; i++) {
          await rec.pump(tester);
        }
        zoomed |= viewport.pxPerSecond != zoom0;
      }
    }

    if (isHostRun) {
      await scenario();
    } else {
      // On phones also capture a timeline for TimelineSummary (perf_driver.dart writes it).
      await binding.traceAction(scenario, reportKey: 'timeline_fling_pinch');
    }
    await rec.stop(tester);
    expect(tester.takeException(), isNull);
    expect(scrolled, isTrue, reason: 'the flings scrolled the timeline');
    expect(zoomed, isTrue, reason: 'the pinches zoomed the timeline');
    final ui = rec.uiMs;
    expect(ui, isNotEmpty);
    final s = rec.summary();
    UiBudgets.timelineUiP90.check(percentile(ui, 90), s);
    UiBudgets.timelineUiP99.check(percentile(ui, 99), s);
    if (rec.fromEngine) {
      UiBudgets.timelineRasterP90.check(percentile(rec.rasterMs, 90), s);
    } else {
      qa04('ui.timeline.rasterP90', {'value': 'n/a', 'run': runKind, 'note': 'no engine FrameTiming on this host'});
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('playback with centre-follow: UI per frame and rebuild counts', (tester) async {
    final (h, id) = await _open(tester);
    final transport = h.containerOf(tester).read(transportProvider(id));
    final session = h.engine.sessions.last;
    final rec = FrameRecorder();
    await transport.play();
    for (var i = 0; i < 10; i++) {
      session.advanceFrames(1);
      await tester.pump(const Duration(milliseconds: 33));
    }
    rec.start();
    final counts = await EditorRebuildCounters.record(() async {
      // 3 s at 30 fps: one 10 Hz clock sample every third frame (as the engines send), the display
      // link in between.
      for (var i = 0; i < 90; i++) {
        session.advanceFrames(1);
        await rec.pump(tester, const Duration(milliseconds: 33));
      }
    });
    await rec.stop(tester);
    await transport.pause();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(session.time, greaterThan(FrameRate.fps30.timeOfFrame(30 * 600)), reason: 'playback advanced');
    final others = {
      for (final e in counts.entries)
        if (e.key != _timecode && e.key != TextOverlayPainter.paintCounter) e.key: e.value,
    };
    UiBudgets.playbackRebuilds.check(others.values.fold<int>(0, (a, b) => a + b), {
      'timecode': counts[_timecode] ?? 0,
      'others': others.isEmpty ? 'none' : others.entries.map((e) => '${e.key}:${e.value}').join(','),
    });
    // The contract holds on every build (debug included): only the timecode rebuilds.
    expect(others, isEmpty, reason: 'playback must rebuild only TimecodeText (ARCH §17.3)');
    UiBudgets.playbackUi.check(percentile(rec.uiMs, 90), rec.summary());
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('centre-locked drag: scrub seek issue latency', (tester) async {
    final (h, _) = await _open(tester);
    final centre = tester.getRect(find.byType(TimelineView)).center;
    int seeks() => h.engine.calls.where((c) => c == 'preview.seek').length;
    final gesture = await tester.startGesture(centre, kind: PointerDeviceKind.touch);
    await gesture.moveBy(const Offset(-30, 0)); // past the touch slop
    await tester.pump(const Duration(milliseconds: 16));
    final lag = <num>[];
    for (var i = 0; i < 30; i++) {
      final before = seeks();
      final sw = Stopwatch()..start();
      await gesture.moveBy(const Offset(-8, 0));
      var issued = false;
      for (var j = 0; j < 30 && !issued; j++) {
        await tester.pump(const Duration(milliseconds: 4));
        issued = seeks() > before;
      }
      if (issued) lag.add(sw.elapsedMicroseconds / 1000);
    }
    await gesture.up();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(lag, isNotEmpty, reason: 'dragging the timeline scrubs');
    UiBudgets.scrubIssue.check(percentile(lag, 90), {
      'p50': percentile(lag, 50).toStringAsFixed(2),
      'issued': lag.length,
      'moves': 30,
      'note': 'UI half; add preview.scrubDrag of the engine suite',
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
