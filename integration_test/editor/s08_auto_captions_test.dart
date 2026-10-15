// OWNER: QA-00
//
// ARCH §21.2 scenario 8: Auto captions with the tiny model (pre-staged through
// `ModelStore.installFromFile`, no network) on speech_10s.m4a: at least one cue, the exported SRT
// parses back to the same cues, and one undo removes them all.

// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/formats.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 8: auto captions with the tiny model', (tester) async {
    expect(E2eConfig.autoCaptionsFlag, isTrue, reason: 'build with --dart-define=DANAVIEW_AUTO_CAPTIONS=true');
    await E2eApp.launch(tester);
    final staged = await E2eApp.stageSpeechModel();
    expect(staged, isTrue,
        reason: 'stage ggml-tiny-q5_1.bin and ggml-silero-v6.2.0.bin in ${E2eConfig.modelsDir} (tool/e2e_host.sh stage-models)');

    final ed = await E2eEditor.createProject(
      tester,
      name: 'E2E captions ${DateTime.now().millisecondsSinceEpoch % 100000}',
      media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech)],
    );
    final subtitleTracks = ed.tracksOf(TrackKind.subtitle).length;

    await ed.invoke(EditorActionId.autoCaptions);
    await E2eApp.waitKey(tester, 'captions-sheet');
    await E2eApp.waitKey(tester, 'captions-configure', timeout: const Duration(seconds: 30));
    if (E2eApp.hasKey('captions-tier-fast')) await E2eApp.tapKey(tester, 'captions-tier-fast');
    await E2eApp.tapKey(tester, 'captions-create');
    bool generated() => ed.tracksOf(TrackKind.subtitle).length > subtitleTracks && ed.items<SubtitleCue>().isNotEmpty;
    bool asksLanguage() => E2eApp.hasKey('captions-needs-language') && E2eApp.hasKey('captions-candidate-en');
    while (!generated()) {
      await E2eApp.pumpUntil(
        tester,
        () {
          if (E2eApp.hasKey('captions-consent')) throw TestFailure('the consent view showed: the staged model was not used');
          if (E2eApp.hasKey('captions-failed')) throw TestFailure('Auto captions failed');
          return generated() || asksLanguage();
        },
        what: 'generated captions',
        timeout: const Duration(minutes: 5),
        step: const Duration(milliseconds: 250),
      );
      // Low-confidence language question: the clip is English.
      if (!generated()) await E2eApp.tapKey(tester, 'captions-candidate-en');
    }
    final track = ed.tracksOf(TrackKind.subtitle).last;
    final cues = [for (final i in track.items) i as SubtitleCue];
    expect(cues, isNotEmpty);
    expect(cues.every((c) => c.origin == CueOrigin.generated), isTrue);
    expect(track.subtitle?.provenance?.modelId, 'whisper-tiny-q5_1');
    // ignore: avoid_print
    print('DV_E2E_REPORT s08 ${cues.length} cues: ${[for (final c in cues) c.text].join(' | ')}');

    // SRT export of the generated track parses back to the same cues.
    await ed.select(cues.first.id);
    final handoffs = E2eApp.world.engine.files.records.length;
    await ed.invoke(EditorActionId.exportSubtitles);
    await E2eApp.waitKey(tester, 'subtitleIo.export');
    await E2eApp.tapKey(tester, 'subtitleIo.exportTrack.${track.id.value}');
    await E2eApp.tapKey(tester, 'subtitleIo.saveToFiles');
    await E2eApp.pumpUntil(tester, () => E2eApp.world.engine.files.records.length > handoffs, what: 'the SRT handoff');
    final parsed = SubtitleCodec.parse(File(E2eApp.world.engine.files.records.last.copyPath).readAsBytesSync(), hint: SubtitleFormat.srt);
    int ms(int us) => (us / 1000).round();
    expect([for (final c in parsed.cues) (ms(c.startUs), ms(c.endUs), c.text)], [for (final c in cues) (ms(c.start), ms(c.end), c.text)]);

    // One undo removes every generated caption.
    await ed.invoke(EditorActionId.undo);
    await ed.waitProject((p) => ed.items<SubtitleCue>().isEmpty, what: 'undo to remove all captions');
    await E2eApp.screenshot(tester, 's08_after_undo');
    await ed.close();
  });
}
