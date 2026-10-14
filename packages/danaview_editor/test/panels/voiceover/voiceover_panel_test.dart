// OWNER: UX-34
//
// The voiceover panel (ux.md §10.5) with the fake recorder, in every state: unavailable, idle,
// the permission explanation → OS prompt, denied (Open Settings, Try again, re-check on resume),
// the 3-2-1 countdown (skip, cancel, reduced motion), recording (level meter from the levels
// stream, elapsed time, project playback), stop (a project-owned recording on a voice-role lane,
// auto-created when needed, at record start + latency, one "Record voiceover" entry), interruption
// (keeps the partial recording with the notice), cancel (discards), failures, read-only, closing the
// panel mid-recording, and the surface matrix.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/voiceover_strings.dart';
import 'package:danaview_editor/src/editor/panels/voiceover_panel.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show EngineErrorCode, EngineFailure, MicPermission, RecordedAsset, RecordingInterruption;

import '../../support/support.dart';
import 'voiceover_rig.dart';

Finder key(String k) => find.byKey(ValueKey<String>(k));

Future<void> tap(VoiceoverRig rig, String k) async {
  await rig.tester.ensureVisible(key(k));
  await rig.tester.pump();
  await rig.tester.tap(key(k));
  await rig.settle();
}

/// Taps Record, runs the countdown out and returns when recording.
Future<void> startRecording(VoiceoverRig rig) async {
  await tap(rig, 'voiceover.record');
  expect(key('voiceover.countdown'), findsOneWidget);
  for (var i = 0; i < 3; i++) {
    await rig.tester.pump(const Duration(seconds: 1));
  }
  await rig.settle();
  expect(key('voiceover.recording'), findsOneWidget);
}

/// A widget test that lets the toast and the throttled announcement timers run out.
void testVo(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 3));
    });

void testVoSurfaces(String description, Future<void> Function(WidgetTester tester, EditorSurface surface) body) =>
    testSurfaces(description, (tester, surface) async {
      await body(tester, surface);
      await tester.pump(const Duration(seconds: 3));
    });

/// Frame-grid start of a clip requested at [t] on the rig's 30 fps grid.
TimeUs onGrid(TimeUs t) => FrameRate.fps30.quantizeNearest(t);

void main() {
  test('the clip start is the record start plus the measured latency', () {
    const asset = RecordedAsset(path: '/x.wav', durationUs: 3 * s, startLatencyUs: 45000);
    expect(voiceoverClipStart(2 * s, asset), 2 * s + 45000);
    expect(voiceoverClipStart(0, const RecordedAsset(path: '/x.wav', durationUs: s, startLatencyUs: -5)), 0);
  });

  group('availability', () {
    testVo('without a voice recorder the panel says so and offers no record button', (tester) async {
      await VoiceoverRig.pump(tester, voiceRecording: false);
      expect(key('voiceover.unavailable'), findsOneWidget);
      expect(find.text(VoiceoverStrings.unavailable), findsOneWidget);
      expect(key('voiceover.record'), findsNothing);
    });

    testVo('idle: record button, start time at the playhead and "Play project" on by default', (tester) async {
      final rig = await VoiceoverRig.pump(tester, playhead: 5 * s);
      expect(key('voiceover.idle'), findsOneWidget);
      expect(key('voiceover.record'), findsOneWidget);
      expect(find.text(VoiceoverStrings.recordsFrom(5 * s)), findsOneWidget);
      expect(find.text('Records from 0:05'), findsOneWidget);
      expect(find.text(VoiceoverStrings.playProject), findsOneWidget);
      expect(find.bySemanticsLabel(VoiceoverStrings.record), findsOneWidget);
      expect(rig.recorder.sessions, isEmpty);
    });

    testVo('read-only projects can\'t record (disabled button with the reason)', (tester) async {
      final rig = await VoiceoverRig.pump(tester, readOnly: true);
      expect(rig.editor.readOnly, isTrue);
      expect(find.text(VoiceoverStrings.readOnly), findsOneWidget);
      await tap(rig, 'voiceover.record');
      expect(key('voiceover.countdown'), findsNothing);
      expect(rig.engine.calls, isNot(contains('recorder.start')));
    });
  });

  group('permission', () {
    testVo('undetermined: the explanation first, Continue asks the OS, granted starts the countdown', (tester) async {
      final rig = await VoiceoverRig.pump(tester, permission: MicPermission.undetermined, afterRequest: MicPermission.granted);
      expect(rig.engine.calls, isNot(contains('recorder.requestPermission')), reason: 'nothing is asked before the first tap');
      await tap(rig, 'voiceover.record');
      expect(key('voiceover.explain'), findsOneWidget);
      expect(find.text(VoiceoverStrings.explainBody), findsOneWidget);
      expect(rig.engine.calls, isNot(contains('recorder.requestPermission')), reason: 'the explanation comes before the OS prompt');
      await tap(rig, 'voiceover.continue');
      expect(rig.engine.calls, contains('recorder.requestPermission'));
      expect(key('voiceover.countdown'), findsOneWidget);
      await tap(rig, 'voiceover.cancel');
      expect(key('voiceover.idle'), findsOneWidget);
    });

    testVo('Not now leaves the explanation without asking', (tester) async {
      final rig = await VoiceoverRig.pump(tester, permission: MicPermission.undetermined);
      await tap(rig, 'voiceover.record');
      await tap(rig, 'voiceover.notNow');
      expect(key('voiceover.idle'), findsOneWidget);
      expect(rig.engine.calls, isNot(contains('recorder.requestPermission')));
    });

    testVo('denied at the prompt: the message with Open Settings and Try again', (tester) async {
      final rig = await VoiceoverRig.pump(tester, permission: MicPermission.undetermined, afterRequest: MicPermission.denied);
      await tap(rig, 'voiceover.record');
      await tap(rig, 'voiceover.continue');
      expect(key('voiceover.denied'), findsOneWidget);
      expect(find.text(VoiceoverStrings.denied), findsOneWidget);
      expect(key('voiceover.tryAgain'), findsOneWidget);
      await tap(rig, 'voiceover.openSettings');
      expect(rig.engine.calls, contains('recorder.openSystemSettings'));
      // Allowed on the second request: the countdown starts.
      rig.recorder.permissionAfterRequest = MicPermission.granted;
      await tap(rig, 'voiceover.tryAgain');
      expect(key('voiceover.countdown'), findsOneWidget);
      await tap(rig, 'voiceover.cancel');
    });

    testVo('permanently denied: the denied state as soon as the panel opens, Open Settings only', (tester) async {
      final rig = await VoiceoverRig.pump(tester, permission: MicPermission.permanentlyDenied);
      expect(key('voiceover.denied'), findsOneWidget);
      expect(key('voiceover.openSettings'), findsOneWidget);
      expect(key('voiceover.tryAgain'), findsNothing);
      expect(rig.recorder.sessions, isEmpty);
    });

    testVo('returning from Settings re-checks the permission', (tester) async {
      final rig = await VoiceoverRig.pump(tester, permission: MicPermission.permanentlyDenied);
      expect(key('voiceover.denied'), findsOneWidget);
      rig.recorder.permissionState = MicPermission.granted;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await rig.settle();
      expect(key('voiceover.idle'), findsOneWidget);
    });

    testVo('a denied tap goes to the denied state without recording', (tester) async {
      final rig = await VoiceoverRig.pump(tester);
      rig.recorder.permissionState = MicPermission.denied;
      await tap(rig, 'voiceover.record');
      expect(key('voiceover.denied'), findsOneWidget);
      expect(rig.engine.calls, isNot(contains('recorder.start')));
    });
  });

  group('countdown', () {
    testVo('3-2-1 then recording; the recorder writes into the project\'s recordings folder', (tester) async {
      final rig = await VoiceoverRig.pump(tester);
      await tap(rig, 'voiceover.record');
      expect(key('voiceover.count.3'), findsOneWidget);
      expect(find.bySemanticsLabel(VoiceoverStrings.countdown(3)), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(key('voiceover.count.2'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(key('voiceover.count.1'), findsOneWidget);
      expect(rig.recorder.sessions, isEmpty, reason: 'not recording during the countdown');
      await tester.pump(const Duration(seconds: 1));
      await rig.settle();
      expect(key('voiceover.recording'), findsOneWidget);
      expect(rig.recorder.sessions, hasLength(1));
      expect(rig.recording.path, startsWith('${recordingsDirOf(rig.id)}/'));
      expect(rig.recording.path, endsWith('.wav'));
      await tap(rig, 'voiceover.discard');
    });

    testVo('skippable: Start now records at once', (tester) async {
      final rig = await VoiceoverRig.pump(tester);
      await tap(rig, 'voiceover.record');
      await tap(rig, 'voiceover.skip');
      expect(key('voiceover.recording'), findsOneWidget);
      expect(rig.recorder.sessions, hasLength(1));
      await tap(rig, 'voiceover.discard');
    });

    testVo('cancel during the countdown never starts the recorder', (tester) async {
      final rig = await VoiceoverRig.pump(tester);
      await tap(rig, 'voiceover.record');
      await tap(rig, 'voiceover.cancel');
      expect(key('voiceover.idle'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(rig.recorder.sessions, isEmpty);
    });

    testVo('animated digits normally, still digits with reduced motion', (tester) async {
      var rig = await VoiceoverRig.pump(tester);
      await tap(rig, 'voiceover.record');
      expect(key('voiceover.countAnimated'), findsOneWidget);
      expect(key('voiceover.countStill'), findsNothing);
      await tap(rig, 'voiceover.cancel');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));

      rig = await VoiceoverRig.pump(tester, reducedMotion: true);
      await tap(rig, 'voiceover.record');
      expect(key('voiceover.countStill'), findsOneWidget);
      expect(key('voiceover.countAnimated'), findsNothing);
      expect(find.byType(AnimatedSwitcher), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(key('voiceover.count.2'), findsOneWidget, reason: 'the digit changes without a transition frame');
      expect(key('voiceover.count.3'), findsNothing);
      await tap(rig, 'voiceover.cancel');
    });
  });

  group('recording', () {
    testVo('the level meter follows the levels stream and the elapsed time runs', (tester) async {
      final rig = await VoiceoverRig.pump(tester);
      await startRecording(rig);
      expect(find.text('0:00'), findsOneWidget);
      rig.recording.emitLevel(0.8);
      await rig.settle();
      expect(tester.getSemantics(key('voiceover.meter')).value, '80%');
      rig.recording.emitLevel(0.25);
      await rig.settle();
      expect(tester.getSemantics(key('voiceover.meter')).value, '25%');
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.text('0:02'), findsOneWidget);
      expect(find.bySemanticsLabel(VoiceoverStrings.stop), findsOneWidget);
      await tap(rig, 'voiceover.discard');
    });

    testVo('plays the project from the playhead while recording, and pauses at stop', (tester) async {
      final rig = await VoiceoverRig.pump(tester, playhead: 2 * s);
      await startRecording(rig);
      expect(rig.engine.calls, contains('preview.play'));
      expect(rig.playhead.playing.value, isTrue);
      await tap(rig, 'voiceover.stop');
      expect(rig.playhead.playing.value, isFalse);
    });

    testVo('with "Play project" off the project stays paused', (tester) async {
      final rig = await VoiceoverRig.pump(tester);
      await tap(rig, 'voiceover.playProject');
      await startRecording(rig);
      expect(rig.engine.calls, isNot(contains('preview.play')));
      expect(rig.playhead.playing.value, isFalse);
      await tap(rig, 'voiceover.discard');
    });
  });

  group('stop', () {
    testVo('imports a project-owned recording and places it at record start + latency on a new voice lane', (tester) async {
      final rig = await VoiceoverRig.pump(tester, playhead: 2 * s);
      final before = rig.entries;
      expect(rig.voiceLanes, isEmpty);
      await startRecording(rig);
      final path = rig.recording.path;
      await tap(rig, 'voiceover.stop');
      expect(rig.recording.stopped, isTrue);
      expect(key('voiceover.idle'), findsOneWidget);

      // Imported as a recording from the recorder's file.
      expect(rig.pool.picks.single.uri, path);
      expect(rig.pool.picks.single.origin, MediaOrigin.recorded);
      expect(rig.pool.picks.single.displayName, VoiceoverStrings.displayName(1));

      // On an auto-created voice lane at record start + latency (fake latency 20 ms), on the grid.
      final placed = rig.recordedClips.single;
      expect(placed.$1.audioRole, AudioRole.voice);
      expect(rig.voiceLanes, hasLength(1));
      expect(placed.$2.start, onGrid(2 * s + 20000));
      expect(placed.$2.duration, 3 * s);
      final asset = rig.project.pool[placed.$2.media]!;
      expect(asset.kind, MediaKind.recording);
      expect(asset.ownership, MediaOwnership.projectOwned);
      expect((asset.locator as AppRelativeLocator).relPath, contains('/assets/recordings/'));

      // One labelled entry; undo removes the clip in one step (the media stays in the bin).
      expect(rig.entries, before + 1);
      expect(rig.undoLabel, VoiceoverStrings.history);
      rig.editor.undo();
      await rig.settle();
      expect(rig.recordedClips, isEmpty);
      expect(rig.project.pool[placed.$2.media], isNotNull);
    });

    testVo('a free existing voice lane is used; a busy one gets a new voice lane', (tester) async {
      final rig = await VoiceoverRig.pump(tester, voiceLane: true, playhead: 6 * s);
      await startRecording(rig);
      await tap(rig, 'voiceover.stop');
      expect(rig.recordedClips.single.$1.id, VoIds.voiceLane, reason: '6 s is free on the existing voice lane');
      expect(rig.voiceLanes, hasLength(1));

      await rig.seek(s);
      await startRecording(rig);
      await tap(rig, 'voiceover.stop');
      expect(rig.voiceLanes, hasLength(2), reason: '1 s overlaps the voice clip at 0-4 s');
      final second = rig.recordedClips.where((p) => p.$2.start == onGrid(s + 20000)).single;
      expect(second.$1.id, isNot(VoIds.voiceLane));
      expect(second.$1.audioRole, AudioRole.voice);
      expect(rig.pool.picks.last.displayName, VoiceoverStrings.displayName(2));
    });

    testVo('ripple on never pushes the timeline: the main lane is unchanged', (tester) async {
      final rig = await VoiceoverRig.pump(tester, ripple: true, playhead: 2 * s);
      final main = rig.project.timeline.tracks.first.items.single;
      await startRecording(rig);
      await tap(rig, 'voiceover.stop');
      expect(rig.project.timeline.tracks.first.items.single, main);
      expect(rig.project.index.item(VoIds.music)!.start, 0);
    });
  });

  group('interruption, cancel and failures', () {
    testVo('an interruption keeps the partial recording, places it and shows the notice', (tester) async {
      final rig = await VoiceoverRig.pump(tester, playhead: s);
      await startRecording(rig);
      rig.recording.durationUs = 12 * s;
      rig.pool.duration = 12 * s;
      rig.recording.interrupt(RecordingInterruption.routeChanged);
      await rig.settle();
      expect(key('voiceover.idle'), findsOneWidget);
      expect(rig.recording.cancelled, isFalse);
      expect(find.text(VoiceoverStrings.interrupted(12 * s)), findsOneWidget);
      expect(find.text('Recording stopped. 0:12 saved.'), findsOneWidget);
      final placed = rig.recordedClips.single.$2;
      expect(placed.start, onGrid(s + 20000));
      expect(placed.duration, 12 * s);
      expect(rig.undoLabel, VoiceoverStrings.history);
    });

    testVo('cancel discards the recording: nothing imported, no history entry', (tester) async {
      final rig = await VoiceoverRig.pump(tester);
      final before = rig.entries;
      await startRecording(rig);
      await tap(rig, 'voiceover.discard');
      expect(rig.recording.cancelled, isTrue);
      expect(rig.recording.stopped, isFalse);
      expect(rig.pool.calls, isNot(contains('import')));
      expect(rig.entries, before);
      expect(rig.recordedClips, isEmpty);
      expect(key('voiceover.idle'), findsOneWidget);
      expect(rig.playhead.playing.value, isFalse);
    });

    testVo('the recorder failing to start returns to idle with an explanation', (tester) async {
      final rig = await VoiceoverRig.pump(tester);
      rig.engine.failNext['recorder.start'] = EngineFailure.of(EngineErrorCode.permissionDenied);
      await tap(rig, 'voiceover.record');
      await tap(rig, 'voiceover.skip');
      expect(key('voiceover.idle'), findsOneWidget);
      expect(find.text(VoiceoverStrings.startFailed), findsOneWidget);
    });

    testVo('an import refused for space explains it and adds no clip', (tester) async {
      final rig = await VoiceoverRig.pump(tester, pool: RecordingPool()..rejectWith = 'diskFull');
      await startRecording(rig);
      await tap(rig, 'voiceover.stop');
      expect(find.text(VoiceoverStrings.diskFull), findsOneWidget);
      expect(rig.recordedClips, isEmpty);
      expect(key('voiceover.idle'), findsOneWidget);
    });

    testVo('an import failure explains it and adds no clip', (tester) async {
      final rig = await VoiceoverRig.pump(tester, pool: RecordingPool()..throws = true);
      await startRecording(rig);
      await tap(rig, 'voiceover.stop');
      expect(find.text(VoiceoverStrings.saveFailed), findsOneWidget);
      expect(rig.recordedClips, isEmpty);
    });

    testVo('closing the panel while recording keeps the recording', (tester) async {
      final rig = await VoiceoverRig.pump(tester, playhead: 2 * s);
      await startRecording(rig);
      rig.editor.closeInspector();
      await rig.settle();
      expect(find.byType(VoiceoverPanel), findsNothing);
      expect(rig.recording.stopped, isTrue);
      expect(rig.recording.cancelled, isFalse);
      expect(rig.recordedClips.single.$2.start, onGrid(2 * s + 20000));
    });

  });

  group('matrix (no overflow, owner UI rules)', () {
    Future<void> check(WidgetTester tester, EditorSurface surface, String state) async {
      await tester.ensureVisible(key(state));
      await tester.pump();
      expect(key(state), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      final r = tester.getRect(key(state));
      expect(r.left, greaterThanOrEqualTo(0), reason: state);
      expect(r.right, lessThanOrEqualTo(surface.size.width), reason: state);
    }

    testVoSurfaces('idle, countdown and recording', (tester, surface) async {
      final rig = await VoiceoverRig.pump(tester, surface: surface, playhead: 2 * s);
      await check(tester, surface, 'voiceover.idle');
      await tap(rig, 'voiceover.record');
      await check(tester, surface, 'voiceover.countdown');
      await tap(rig, 'voiceover.skip');
      await check(tester, surface, 'voiceover.recording');
      rig.recording.emitLevel(0.95);
      await rig.settle();
      expectNoOverflow(tester);
      await tap(rig, 'voiceover.discard');
    });

    testVoSurfaces('explanation and denied', (tester, surface) async {
      final rig = await VoiceoverRig.pump(tester, surface: surface, permission: MicPermission.undetermined, afterRequest: MicPermission.denied);
      await tap(rig, 'voiceover.record');
      await check(tester, surface, 'voiceover.explain');
      await tap(rig, 'voiceover.continue');
      await check(tester, surface, 'voiceover.denied');
    });

    testVoSurfaces('unavailable and read-only', (tester, surface) async {
      await VoiceoverRig.pump(tester, surface: surface, voiceRecording: false);
      await check(tester, surface, 'voiceover.unavailable');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      await VoiceoverRig.pump(tester, surface: surface, readOnly: true);
      await check(tester, surface, 'voiceover.idle');
      expect(key('voiceover.blocker'), findsOneWidget);
    });
  });
}
