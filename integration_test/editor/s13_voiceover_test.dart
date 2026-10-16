// OWNER: QA-00
//
// ARCH §21.2 scenario 13: voiceover. The host grants the microphone (`xcrun simctl privacy grant
// microphone` / `adb shell pm grant … RECORD_AUDIO`), the panel records 3 s (simulator: the Mac's
// input; emulator: the virtual microphone), the WAV lands on a voice lane at the playhead plus the
// recorder's latency, and it is audible in an export.
//
// Timing (FIX-TESTS-R6, QA-01 s13 / QA-02 M-5): the project plays while recording, so the clip
// start is compared with the playhead read when `voiceover.recording` appears (the recorder has
// started by then), not with the seek target. The device budget is < 100 ms
// (`--dart-define=DV_E2E_DEVICE=true`); simulators and emulators get their measured audio start
// latency. The 3 s window starts when recording appears and includes the host screenshot
// handshake, and the clip length is compared with the window actually recorded, so a slow
// screenshot round trip does not fail the run.
//
// FIX-QA00-R7 (QA-02 M-5): on a loaded emulator the recorder starts about 3 s before the
// `recording` key shows, so "recording shown → Stop" alone undercounts. The clip length must lie
// between the inner window (recording shown → just before the Stop tap) and the outer window (the
// tap that started the recorder, i.e. Record or the explain/countdown tap after it → the Stop tap
// done), both on the device clock, each with the tolerance.

// ignore_for_file: implementation_imports

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

/// A physical device run: the strict start-latency budget applies.
const bool _onDevice = bool.fromEnvironment('DV_E2E_DEVICE');

/// Allowed |clip start - playhead when recording appeared| (device budget: 100 ms).
const int _startToleranceUs = _onDevice ? 100000 : 750000;

/// Allowed distance of the clip length outside the [inner, outer] recorded window.
const int _lengthToleranceUs = _onDevice ? 250000 : 750000;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 13: record a 3 s voiceover onto a voice lane, audible in the export', (tester) async {
    await E2eApp.launch(tester);
    final grant = await E2eHandshake.request(tester, 'grantMic');
    expect(grant.ok, isTrue, reason: '$grant');
    final ed = await E2eEditor.createProject(tester, name: 'E2E voiceover ${DateTime.now().millisecondsSinceEpoch % 100000}', media: [E2eMedia.fixture(Fx.frameCounter)]);
    expect(E2eApp.world.engine.voiceRecorder, isNotNull, reason: 'the engine reports no voice recorder');

    await ed.seekFrame(60);
    final seekAt = ed.playhead.value;
    await ed.invoke(EditorActionId.recordVoiceover);
    await E2eApp.waitKey(tester, 'voiceover.record');
    // The last tap that can start the recorder (Record, then Continue / Skip when they show).
    var startTapAt = DateTime.now();
    await E2eApp.tapKey(tester, 'voiceover.record');
    await E2eApp.pumpUntil(
      tester,
      () => E2eApp.hasKey('voiceover.countdown') || E2eApp.hasKey('voiceover.recording') || E2eApp.hasKey('voiceover.explain') || E2eApp.hasKey('voiceover.denied'),
      what: 'the recorder to start',
    );
    expect(E2eApp.hasKey('voiceover.denied'), isFalse, reason: 'microphone permission denied');
    if (E2eApp.hasKey('voiceover.explain')) {
      startTapAt = DateTime.now();
      await E2eApp.tapKey(tester, 'voiceover.continue');
    }
    if (E2eApp.hasKey('voiceover.countdown')) {
      startTapAt = DateTime.now();
      await E2eApp.tapKey(tester, 'voiceover.skip');
    }
    await E2eApp.waitKey(tester, 'voiceover.recording');
    final started = DateTime.now();
    final at = ed.playhead.value;
    // The window opens when recording shows and includes the screenshot round trip; the recording
    // lasts at least 3 s (the scenario's length, not a wait for something to happen).
    await E2eApp.screenshot(tester, 's13_recording');
    await E2eApp.pumpUntil(tester, () => DateTime.now().difference(started) >= const Duration(seconds: 3), what: '3 s of recording');
    final stopTapAt = DateTime.now();
    await E2eApp.tapKey(tester, 'voiceover.stop');
    final stopDoneAt = DateTime.now();
    final innerUs = stopTapAt.difference(started).inMicroseconds;
    final outerUs = stopDoneAt.difference(startTapAt).inMicroseconds;

    await ed.waitProject(
      (p) => p.tracks.any((t) => t.kind == TrackKind.audio && t.audioRole == AudioRole.voice && t.items.isNotEmpty),
      what: 'the recording on a voice lane',
      timeout: const Duration(seconds: 30),
    );
    final lane = ed.project.tracks.firstWhere((t) => t.kind == TrackKind.audio && t.audioRole == AudioRole.voice);
    final clip = lane.items.single as MediaClip;
    final asset = ed.assetOf(clip);
    expect(asset.kind, MediaKind.recording, reason: 'a voiceover is stored as a recording');
    expect(asset.displayName.toLowerCase(), endsWith('.wav'));
    // ignore: avoid_print
    print('DV_E2E_REPORT s13 timing: seek $seekAt us, playhead at recording $at us, clip ${clip.start}+${clip.duration} us, '
        'window inner $innerUs us (recording shown -> Stop) outer $outerUs us (start tap -> Stop done) (device $_onDevice)');
    expect(clip.start, greaterThanOrEqualTo(seekAt), reason: 'the recording starts at or after the playhead');
    expect((clip.start - at).abs(), lessThan(_startToleranceUs),
        reason: 'start ${clip.start} us vs playhead $at us when recording appeared (budget $_startToleranceUs us)');
    expect(clip.duration, greaterThanOrEqualTo(2500000), reason: 'a 3 s take');
    expect(clip.duration, inInclusiveRange(innerUs - _lengthToleranceUs, outerUs + _lengthToleranceUs),
        reason: 'clip ${clip.duration} us vs recorded window [$innerUs, $outerUs] us (tolerance $_lengthToleranceUs us)');

    final out = await E2eExport.run(ed);
    final (samples, rate) = await E2eExport.pcm(ed, out.video, TimeRange(clip.start, clip.end));
    final level = E2eExport.dbfs(samples);
    // ignore: avoid_print
    print('DV_E2E_REPORT s13 voiceover level in export: ${level.toStringAsFixed(1)} dBFS ($rate Hz)');
    expect(level, greaterThan(-60), reason: 'the voiceover must be audible in the export');
    await ed.close();
  }, skip: !E2eHandshake.available);
}
