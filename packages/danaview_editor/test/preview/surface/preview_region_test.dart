// OWNER: UX-18
//
// PreviewRegion, PreviewSurface and the status overlays over FakeEditorEngine (BUILD_PLAN UX-18):
// every status, the touch preview controls (tap play/pause and double-tap ±1 s only without an item
// under the finger), fullscreen enter/exit keeping the playback state, wakelock, surface loss and
// resume, letterboxing, and no overflow on the surface matrix.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/editor_lifecycle.dart';
import 'package:danaview_editor/src/debug/rebuild_counters.dart';
import 'package:danaview_editor/src/editor/preview/fullscreen_preview.dart';
import 'package:danaview_editor/src/editor/preview/preview_region.dart';
import 'package:danaview_editor/src/editor/preview/preview_status.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/transport/transport_strings.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddText;
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'preview_rig.dart';

/// The project plus a text item at 5–7 s (no clip there).
EditProject _longer(FakeProjectRepository repo) => previewProject(repo, extra: const [AddText(5 * s, text: 'Later', duration: 2 * s)]);

Finder get _texture => find.byType(FakeTexturePlaceholder);

PreviewRegionState _region(WidgetTester tester) => tester.state<PreviewRegionState>(find.byType(PreviewRegion, skipOffstage: false));

void main() {
  group('surface', () {
    testWidgets('shows the session texture in the letterboxed canvas rect', (tester) async {
      final rig = await PreviewRig.pump(
        tester,
        home: (id) => const Align(alignment: Alignment.topLeft, child: SizedBox(width: 300, height: 300, child: PreviewRegion())),
      );
      expect(_texture, findsOneWidget);
      expect(tester.widget<FakeTexturePlaceholder>(_texture).textureId, rig.preview.textureId);
      final r = tester.getRect(_texture);
      // 1920×1080 in 300×300: 300×168.75 centred vertically.
      expect(r.width, moreOrLessEquals(300));
      expect(r.height, moreOrLessEquals(168.75));
      expect(r.top, moreOrLessEquals(65.625));
      expect(tester.takeException(), isNull);
    });

    testWidgets('semantics: "Preview, W by H, timecode"', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = await PreviewRig.pump(tester);
      await rig.real(() => rig.transport.seekTo(1 * s));
      expect(find.bySemanticsLabel(RegExp(r'^Preview, 1920 by 1080, 00:01:00')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('no project yet: black, no texture', (tester) async {
      await PreviewRig.pump(tester, open: false);
      expect(_texture, findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('statuses', () {
    testWidgets('starting: spinner until the first frame', (tester) async {
      final rig = await PreviewRig.pump(tester, forcible: true);
      rig.forcible.force(rig.state.copyWith(preview: rig.state.preview.copyWith(phase: PreviewPhase.starting)));
      await tester.pump();
      expect(find.byType(DanaviewSpinner), findsOneWidget);
      rig.forcible.force(rig.state.copyWith(preview: rig.state.preview.copyWith(phase: PreviewPhase.ready)));
      await tester.pump();
      expect(find.byType(DanaviewSpinner), findsNothing);
    });

    testWidgets('failed: "Preview stopped" and Restart preview resends the plan', (tester) async {
      final rig = await PreviewRig.pump(tester);
      expect(rig.state.preview.phase, PreviewPhase.ready);
      rig.preview.emitEvent(PreviewFailedEvent(EngineFailure.of(EngineErrorCode.decodeFailed)));
      await rig.settle();
      expect(rig.state.preview.phase, PreviewPhase.failed);
      expect(find.text(PreviewStrings.stopped), findsOneWidget);
      expect(find.text(PreviewStrings.restart), findsOneWidget);
      final before = rig.engine.log.calls.where((c) => c == 'preview.setPlan').length;
      await tester.tap(find.text(PreviewStrings.restart));
      await rig.settle();
      await rig.settle();
      expect(rig.engine.log.calls.where((c) => c == 'preview.setPlan').length, greaterThan(before));
      expect(rig.engine.log.calls, contains('preview.refresh'));
      expect(rig.state.preview.phase, isNot(PreviewPhase.failed));
      expect(find.text(PreviewStrings.stopped), findsNothing);
    });

    testWidgets('failed before the session opened: Restart preview opens one', (tester) async {
      final rig = await PreviewRig.pump(tester, open: false);
      rig.engine.failNext['openPreview'] = EngineFailure.of(EngineErrorCode.decodeFailed);
      await rig.openEditor();
      expect(rig.state.preview.phase, PreviewPhase.failed);
      expect(_texture, findsNothing);
      await tester.tap(find.text(PreviewStrings.restart));
      await rig.settle();
      await rig.settle();
      expect(rig.engine.sessions, hasLength(1));
      expect(rig.state.preview.phase, isNot(PreviewPhase.failed));
      expect(_texture, findsOneWidget);
    });

    testWidgets('offline media at the playhead: Media missing with Relink…', (tester) async {
      final rig = await PreviewRig.pump(tester, project: _longer);
      await rig.real(() => rig.transport.seekTo(1 * s));
      rig.editor.setMediaHealth(MediaHealth(missing: {const MediaId('md_a')}));
      await tester.pump();
      expect(find.text(PreviewStrings.mediaMissing), findsOneWidget);
      expect(find.text(PreviewStrings.relink), findsOneWidget);
      // The relink flow (UX-40) is not bound yet: the button is disabled, not missing.
      final button = tester.widget<DanaviewButton>(find.widgetWithText(DanaviewButton, PreviewStrings.relink));
      expect(button.onPressed, isNull);
      // No clip at 6 s: the card goes away with the playhead.
      await rig.real(() => rig.transport.seekTo(6 * s));
      expect(find.text(PreviewStrings.mediaMissing), findsNothing);
      await rig.real(() => rig.transport.seekTo(2 * s));
      expect(find.text(PreviewStrings.mediaMissing), findsOneWidget);
    });

    testWidgets('degraded: Preview ½ badge with the quality tooltip', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.preview.emitEvent(const PreviewDegraded(PreviewQuality.half));
      await rig.settle();
      expect(find.text('Preview ½'), findsOneWidget);
      final tooltip = tester.widget<DanaviewPressable>(find.ancestor(of: find.text('Preview ½'), matching: find.byType(DanaviewPressable)));
      expect(tooltip.tooltip, PreviewStrings.degradedTooltip);
      rig.preview.emitEvent(const PreviewDegraded(PreviewQuality.quarter));
      await rig.settle();
      expect(find.text('Preview ¼'), findsOneWidget);
      rig.preview.emitEvent(const PreviewRecovered());
      await rig.settle();
      expect(find.textContaining('Preview ¼'), findsNothing);
    });

    testWidgets('pending jobs: a task badge while background tasks run', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.editor.setTasks(const [
        EditorTaskInfo(id: 'j1', kind: EditorTaskKind.proxy, label: 'Optimizing a clip', progress: 0.3),
        EditorTaskInfo(id: 'j2', kind: EditorTaskKind.waveform, label: 'Reading audio'),
        EditorTaskInfo(id: 'j3', kind: EditorTaskKind.reverse, label: 'Reversing a clip', failed: true),
      ]);
      await tester.pump();
      expect(find.text('2 tasks'), findsOneWidget);
      rig.editor.setTasks(const []);
      await tester.pump();
      expect(find.text('2 tasks'), findsNothing);
    });

    testSurfaces('cards and badges never overflow', (tester, surface) async {
      final rig = await PreviewRig.pump(
        tester,
        surface: surface,
        forcible: true,
        home: (id) => const Column(children: [
          SizedBox(height: 120, child: PreviewRegion()),
          Expanded(child: SizedBox.expand()),
        ]),
      );
      rig.editor.setTasks(const [EditorTaskInfo(id: 'j1', kind: EditorTaskKind.proxy, label: 'Optimizing a clip')]);
      rig.forcible.force(rig.state.copyWith(
        preview: const PreviewStatus(PreviewPhase.failed, quality: PreviewQuality.half, failure: PreviewFailed(recoverable: true)),
      ));
      await tester.pump();
      expect(find.text(PreviewStrings.stopped), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      rig.forcible.force(rig.state.copyWith(preview: const PreviewStatus(PreviewPhase.degraded, quality: PreviewQuality.half)));
      rig.editor.setMediaHealth(MediaHealth(missing: {const MediaId('md_a')}));
      await tester.pump();
      expect(find.text(PreviewStrings.mediaMissing), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });

  group('touch preview controls', () {
    testWidgets('tap on empty canvas toggles play/pause (after the double-tap window)', (tester) async {
      final rig = await PreviewRig.pump(tester);
      await tester.tapAt(rig.at(const Offset(20, 20)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(rig.preview.playing, isFalse, reason: 'waits for a possible double tap');
      await tester.pump(const Duration(milliseconds: 300));
      await rig.settle();
      expect(rig.preview.playing, isTrue);
      expect(rig.transport.playing.value, isTrue);
      await tester.tapAt(rig.at(const Offset(20, 20)));
      await tester.pump(const Duration(milliseconds: 400));
      await rig.settle();
      expect(rig.preview.playing, isFalse);
    });

    testWidgets('double tap seeks −1 s on the left half and +1 s on the right half', (tester) async {
      final rig = await PreviewRig.pump(tester);
      await rig.real(() => rig.transport.seekTo(2 * s));
      await tester.tapAt(rig.at(const Offset(20, 200)));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(rig.at(const Offset(20, 200)));
      await rig.settle();
      await tester.pump(const Duration(milliseconds: 400));
      await rig.settle();
      expect(rig.playhead.value, 1 * s);
      expect(rig.preview.playing, isFalse, reason: 'a double tap never toggles playback');
      await tester.tapAt(rig.at(const Offset(370, 200)));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(rig.at(const Offset(370, 200)));
      await rig.settle();
      await tester.pump(const Duration(milliseconds: 400));
      await rig.settle();
      expect(rig.playhead.value, 2 * s);
    });

    testWidgets('with an item under the finger the tap selects it (no playback, no seek)', (tester) async {
      final rig = await PreviewRig.pump(tester);
      await rig.real(() => rig.transport.seekTo(2 * s));
      // Canvas (600, 350): inside the clip (480–1440 × 270–810), outside the text.
      await tester.tapAt(rig.canvas(600, 350));
      await tester.pump(const Duration(milliseconds: 400));
      await rig.settle();
      expect(rig.state.selection.primary, PreviewIds.clip);
      expect(rig.preview.playing, isFalse);
      // Double tap on the clip: no seek.
      await tester.tapAt(rig.canvas(600, 350));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(rig.canvas(600, 350));
      await tester.pump(const Duration(milliseconds: 400));
      await rig.settle();
      expect(rig.playhead.value, 2 * s);
      expect(rig.preview.playing, isFalse);
    });

    testWidgets('tap on empty canvas while an item shows handles clears the selection', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.editor.select(PreviewIds.clip);
      await tester.pump();
      await tester.tapAt(rig.at(const Offset(20, 20)));
      await tester.pump(const Duration(milliseconds: 400));
      await rig.settle();
      expect(rig.state.selection.isEmpty, isTrue);
      expect(rig.preview.playing, isFalse);
    });
  });

  group('fullscreen', () {
    testWidgets('enter and exit keep playback running; one texture at a time', (tester) async {
      final rig = await PreviewRig.pump(tester);
      await rig.real(() => rig.transport.play());
      expect(rig.preview.playing, isTrue);
      final calls = rig.engine.log.calls.length;

      rig.transport.setFullscreen(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FullscreenPreview), findsOneWidget);
      expect(_region(tester).fullscreenOpen, isTrue);
      expect(_texture, findsOneWidget);
      expect(find.byType(FakeTexturePlaceholder, skipOffstage: false), findsOneWidget,
          reason: 'the editor surface unmounts its texture while fullscreen shows it');
      expect(tester.widget<FakeTexturePlaceholder>(_texture).textureId, rig.preview.textureId);
      await rig.playFrames(3);
      expect(rig.preview.playing, isTrue);
      expect(rig.transport.playing.value, isTrue);

      await tester.tap(find.bySemanticsLabel(PreviewStrings.exitFullscreen));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FullscreenPreview), findsNothing);
      expect(rig.transport.fullscreen.value, isFalse);
      expect(_texture, findsOneWidget);
      expect(rig.preview.playing, isTrue);
      final during = rig.engine.log.calls.sublist(calls);
      expect(during.where((c) => c == 'preview.pause' || c == 'preview.seek'), isEmpty, reason: 'fullscreen never pauses or seeks: $during');
    });

    testWidgets('clearing the flag (F again) closes the route; Esc closes it too', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.transport.toggleFullscreen();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FullscreenPreview), findsOneWidget);
      rig.transport.toggleFullscreen();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FullscreenPreview), findsNothing);

      rig.transport.setFullscreen(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FullscreenPreview), findsNothing);
      expect(rig.transport.fullscreen.value, isFalse);
    });

    testWidgets('controls: tap toggles them; they hide after 3 s while playing; double tap seeks', (tester) async {
      final rig = await PreviewRig.pump(tester);
      await rig.real(() => rig.transport.seekTo(2 * s));
      rig.transport.setFullscreen(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final state = tester.state<FullscreenPreviewState>(find.byType(FullscreenPreview));
      expect(state.controlsVisible, isTrue);
      await rig.real(() => rig.transport.play());
      // Tap hides the controls; tap again shows them and restarts the 3 s timer.
      await tester.tapAt(const Offset(195, 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.controlsVisible, isFalse);
      await tester.tapAt(const Offset(195, 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.controlsVisible, isTrue);
      await tester.pump(const Duration(seconds: 3));
      expect(state.controlsVisible, isFalse, reason: 'hidden after 3 s while playing');
      await tester.tapAt(const Offset(195, 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.controlsVisible, isTrue);
      await rig.real(() => rig.transport.pause());
      await tester.pump(const Duration(seconds: 4));
      expect(state.controlsVisible, isTrue, reason: 'paused: controls stay');
      await tester.tapAt(const Offset(20, 400));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(const Offset(20, 400));
      await rig.settle();
      expect(rig.playhead.value, 1 * s);
      expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testWidgets('quality menu: Auto/Full/Half/Quarter and the proxies toggle reach the session', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.transport.setFullscreen(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      Future<void> pick(String label) async {
        await tester.tap(find.bySemanticsLabel(TransportStrings.quality));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text(TransportStrings.qualityNote), findsOneWidget);
        await tester.tap(find.text(label).last);
        await tester.pump();
        await rig.settle();
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(rig.preview.quality, PreviewQuality.auto);
      await pick(TransportStrings.qualityHalf);
      expect(rig.preview.quality, PreviewQuality.half);
      expect(rig.state.preview.quality, PreviewQuality.half);
      await pick(TransportStrings.qualityQuarter);
      expect(rig.preview.quality, PreviewQuality.quarter);
      await pick(TransportStrings.qualityAuto);
      expect(rig.preview.quality, PreviewQuality.auto);

      final proxies = rig.preview.useProxies;
      await pick(TransportStrings.useProxies);
      expect(rig.preview.useProxies, !proxies);
      expect(rig.state.preview.useProxies, !proxies);
      expect(rig.engine.log.calls, containsAll(<String>['preview.setQuality', 'preview.setUseProxies']));
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testSurfaces('fullscreen fits every surface', (tester, surface) async {
      final rig = await PreviewRig.pump(tester, surface: surface);
      rig.transport.setFullscreen(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FullscreenPreview), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });

  group('back order', () {
    testWidgets('the back step "exit fullscreen" closes the route (after clearing the selection)', (tester) async {
      final rig = await PreviewRig.pump(
        tester,
        open: false,
        home: (id) => Consumer(
          builder: (context, ref, _) => EditorLifecycle(
            delegate: ref.read(editorControllerProvider(id).notifier),
            onExit: () {},
            child: regionHome(id),
          ),
        ),
      );
      await rig.openEditor();
      await rig.real(() => rig.transport.play());
      rig.editor.select(PreviewIds.clip);
      rig.transport.setFullscreen(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final dispatcher = EditorBackDispatcher.of(tester.element(find.byType(PreviewRegion, skipOffstage: false)));
      expect(await dispatcher.handleBack(), EditorBackStep.clearSelection);
      expect(find.byType(FullscreenPreview), findsOneWidget);
      expect(await dispatcher.handleBack(), EditorBackStep.exitFullscreen);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FullscreenPreview), findsNothing);
      expect(rig.transport.fullscreen.value, isFalse);
      expect(rig.preview.playing, isTrue, reason: 'leaving fullscreen keeps playback');
    });
  });

  group('lifecycle', () {
    testWidgets('wakelock while playing', (tester) async {
      final rig = await PreviewRig.pump(tester);
      expect(rig.wakelock.held, isFalse);
      await rig.real(() => rig.transport.play());
      expect(rig.wakelock.held, isTrue);
      await rig.real(() => rig.transport.pause());
      expect(rig.wakelock.held, isFalse);
      await rig.real(() => rig.transport.play());
      expect(rig.wakelock.held, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(rig.wakelock.held, isFalse, reason: 'released when the region goes away');
    });

    testWidgets('surface loss refreshes the session and re-creates the texture widget', (tester) async {
      final rig = await PreviewRig.pump(tester);
      final before = _region(tester).textureGeneration;
      final element = tester.element(_texture);
      rig.preview.emitEvent(const PreviewSurfaceLost());
      await rig.settle();
      expect(rig.engine.log.calls, contains('preview.refresh'));
      expect(_region(tester).textureGeneration, before + 1);
      expect(identical(tester.element(_texture), element), isFalse);
    });

    testWidgets('resume re-creates the texture widget', (tester) async {
      await PreviewRig.pump(tester);
      final before = _region(tester).textureGeneration;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(_region(tester).textureGeneration, before + 1);
    });

    testWidgets('playback does not rebuild the region', (tester) async {
      final rig = await PreviewRig.pump(tester);
      await rig.real(() => rig.transport.play());
      final counts = await EditorRebuildCounters.record(() => rig.playFrames(30));
      expect(counts['PreviewRegion'], isNull, reason: '$counts');
    });
  });
}
