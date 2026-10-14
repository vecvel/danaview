// OWNER: UX-37
//
// No-overflow matrix (ARCH §1.3 rule 5, ai.md §16.2, ux.md §21) for every Auto captions state:
// configure with Advanced open and a generated lane, the language picker, consent (damaged model,
// missing space, privacy link), running (partial preview, paused), needs language, failed and
// unsupported. Each surface checks no overflow, the owner UI rules and that the actions stay inside
// the screen.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import '../../support/support.dart';
import 'captions_rig.dart';

Future<void> _check(WidgetTester tester, List<String> keys) async {
  expectNoOverflow(tester);
  expectOwnerUiRules(tester);
  for (final key in keys) {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pump();
    expectInside(tester, finder);
  }
  expectNoOverflow(tester);
}

Future<CaptionsRig> _running(WidgetTester tester, EditorSurface surface) async {
  final rig = CaptionsRig(generated: true)..install();
  await rig.pump(tester, surface: surface);
  await rig.openSheet(tester);
  await rig.tapKey(tester, 'captions-create');
  return rig;
}

void main() {
  testSurfaces('configure with Advanced open, a generated lane and a selected clip', (tester, surface) async {
    final rig = CaptionsRig(generated: true, prefs: {'editor.captions.lastLanguage': 'ml'});
    await rig.pump(tester, surface: surface);
    rig.editor.select(Cap.clip);
    await rig.openSheet(tester);
    await rig.tapKey(tester, 'captions-advanced');
    await _check(tester, [
      'captions-language',
      'captions-tier-accurate',
      'captions-scope',
      'captions-layout',
      'captions-replace',
      'captions-max-chars',
      'captions-reading-speed',
      'captions-sound-descriptions',
      'captions-cancel',
      'captions-create',
    ]);
  });

  testSurfaces('the language picker', (tester, surface) async {
    final rig = CaptionsRig(prefs: {'editor.captions.recentLanguages': 'id,ms,ml'});
    await rig.pump(tester, surface: surface);
    await rig.openSheet(tester);
    await rig.tapKey(tester, 'captions-language');
    await _check(tester, ['captions-language-back', 'captions-language-search', 'captions-language-auto', 'captions-language-recent-id']);
  });

  testSurfaces('consent with a damaged model, missing space and the privacy link', (tester, surface) async {
    final rig = CaptionsRig();
    rig.transcription.statuses[SpeechModelCatalog.accurate.id] = const SpeechModelCorrupt();
    rig.transcription.preflightOverride = TranscriptionPreflight(
      ok: false,
      failure: const DiskFullFailure(),
      downloadBytes: SpeechModelCatalog.accurate.bytes + SpeechModelCatalog.vad.bytes,
    );
    await rig.pump(tester, surface: surface);
    await rig.openSheet(tester);
    await rig.tapKey(tester, 'captions-tier-accurate');
    await rig.tapKey(tester, 'captions-create');
    await _check(tester, ['captions-consent-details', 'captions-consent-space', 'captions-consent-privacy', 'captions-consent-decline', 'captions-consent-accept']);
  });

  testSurfaces('running with a partial preview and a paused line', (tester, surface) async {
    final rig = await _running(tester, surface);
    rig.job.emit(CaptionsRig.sample(
      TranscriptionPhase.transcribing,
      0.42,
      eta: const Duration(minutes: 12),
      paused: PauseReason.thermal,
      partial: 'a rather long partial line of transcript text that must be cut to one single line',
    ));
    await rig.pumpSome(tester, 3);
    await _check(tester, ['captions-phase-line', 'captions-paused', 'captions-progress-bar', 'captions-cancel', 'captions-hide']);
    rig.job.cancel();
    await rig.pumpSome(tester);
  });

  testSurfaces('needs language', (tester, surface) async {
    final rig = await _running(tester, surface);
    rig.job.waitForLanguage(const [LanguageProbability('ml', 0.41), LanguageProbability('ta', 0.39), LanguageProbability('kn', 0.12)]).ignore();
    await rig.pumpSome(tester, 3);
    await _check(tester, ['captions-candidate-ml', 'captions-candidate-kn', 'captions-other-language', 'captions-cancel', 'captions-continue']);
    rig.job.cancel();
    await rig.pumpSome(tester);
  });

  testSurfaces('failed (memory, with the tier fallback)', (tester, surface) async {
    final rig = await _running(tester, surface);
    rig.job.fail(const InsufficientMemoryFailure(suggestedTier: SpeechModelTier.fast));
    await rig.pumpSome(tester);
    await _check(tester, ['captions-message-title', 'captions-message-body', 'captions-back', 'captions-use-tier']);
  });

  testSurfaces('unsupported', (tester, surface) async {
    final rig = CaptionsRig();
    rig.transcription.supportState = const TranscriptionUnsupported('abi');
    await rig.pump(tester, surface: surface);
    await rig.openSheet(tester);
    await _check(tester, ['captions-unsupported', 'captions-message-title']);
  });

  test('the matrix includes the narrowest surface at the largest text scale', () {
    expect(SurfaceMatrix.current, contains(SurfaceMatrix.narrowest));
  });
}
