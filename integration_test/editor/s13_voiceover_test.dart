// OWNER: QA-00
//
// ARCH §21.2 scenario 13: voiceover. The host grants the microphone (`xcrun simctl privacy grant
// microphone` / `adb shell pm grant … RECORD_AUDIO`), the panel records 3 s (simulator: the Mac's
// input; emulator: the virtual microphone), the WAV lands on a voice lane at the playhead plus the
// recorder's latency, and it is audible in an export.

// ignore_for_file: implementation_imports

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 13: record a 3 s voiceover onto a voice lane, audible in the export', (tester) async {
    await E2eApp.launch(tester);
    final grant = await E2eHandshake.request(tester, 'grantMic');
    expect(grant.ok, isTrue, reason: '$grant');
    final ed = await E2eEditor.createProject(tester, name: 'E2E voiceover ${DateTime.now().millisecondsSinceEpoch % 100000}', media: [E2eMedia.fixture(Fx.frameCounter)]);
    expect(E2eApp.world.engine.voiceRecorder, isNotNull, reason: 'the engine reports no voice recorder');

    await ed.seekFrame(60);
    final at = ed.playhead.value;
    await ed.invoke(EditorActionId.recordVoiceover);
    await E2eApp.waitKey(tester, 'voiceover.record');
    await E2eApp.tapKey(tester, 'voiceover.record');
    await E2eApp.pumpUntil(
      tester,
      () => E2eApp.hasKey('voiceover.countdown') || E2eApp.hasKey('voiceover.recording') || E2eApp.hasKey('voiceover.explain') || E2eApp.hasKey('voiceover.denied'),
      what: 'the recorder to start',
    );
    expect(E2eApp.hasKey('voiceover.denied'), isFalse, reason: 'microphone permission denied');
    if (E2eApp.hasKey('voiceover.explain')) await E2eApp.tapKey(tester, 'voiceover.continue');
    if (E2eApp.hasKey('voiceover.countdown')) await E2eApp.tapKey(tester, 'voiceover.skip');
    await E2eApp.waitKey(tester, 'voiceover.recording');
    final started = DateTime.now();
    // The recording itself lasts 3 s (the scenario's length, not a wait for something to happen).
    await E2eApp.pumpUntil(tester, () => DateTime.now().difference(started) >= const Duration(seconds: 3), what: '3 s of recording');
    await E2eApp.screenshot(tester, 's13_recording');
    await E2eApp.tapKey(tester, 'voiceover.stop');

    await ed.waitProject(
      (p) => p.tracks.any((t) => t.kind == TrackKind.audio && t.audioRole == AudioRole.voice && t.items.isNotEmpty),
      what: 'the recording on a voice lane',
      timeout: const Duration(seconds: 30),
    );
    final lane = ed.project.tracks.firstWhere((t) => t.kind == TrackKind.audio && t.audioRole == AudioRole.voice);
    final clip = lane.items.single as MediaClip;
    final asset = ed.assetOf(clip);
    expect(asset.kind, MediaKind.audio);
    expect(asset.displayName.toLowerCase(), endsWith('.wav'));
    expect(clip.start, greaterThanOrEqualTo(at));
    expect(clip.start - at, lessThan(500000), reason: 'start latency ${clip.start - at} us');
    expect(clip.duration, inInclusiveRange(2500000, 4000000));

    final out = await E2eExport.run(ed);
    final (samples, rate) = await E2eExport.pcm(ed, out.video, TimeRange(clip.start, clip.end));
    final level = E2eExport.dbfs(samples);
    // ignore: avoid_print
    print('DV_E2E_REPORT s13 voiceover level in export: ${level.toStringAsFixed(1)} dBFS ($rate Hz)');
    expect(level, greaterThan(-60), reason: 'the voiceover must be audible in the export');
    await ed.close();
  }, skip: !E2eHandshake.available);
}
