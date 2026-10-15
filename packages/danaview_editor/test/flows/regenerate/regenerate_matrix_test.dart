// OWNER: UX-38
//
// No-overflow matrix (ARCH §1.3 rule 5, ux.md §21) for UX-38: the Regenerate sheet in both modes and
// with a refusal shown, the edited-cues confirmation, the interrupted-job notice and the captions
// settings section (installed, damaged and in-use rows). Each surface checks no overflow, the owner
// UI rules and that the actions stay inside the screen.

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/settings/captions_settings_section.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'regenerate_rig.dart';

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

void main() {
  testSurfaces('the Regenerate sheet: re-split with a refusal shown', (tester, surface) async {
    final rig = RegenRig(project: (id) => regenProject(id, locked: true));
    await rig.pump(tester, surface: surface);
    rig.transcription.resegmentDrafts = drafts(0, 60 * s);
    await rig.openSheet(tester);
    await rig.tapKey(tester, 'regenerate-apply');
    await tester.runAsync(rig.settle);
    await rig.pumpSome(tester);
    await _check(tester, [
      'regenerate-track',
      'regenerate-summary',
      'regenerate-mode-resplit',
      'regenerate-mode-transcribe',
      'regenerate-layout',
      'regenerate-scope',
      'regenerate-error',
      'regenerate-cancel',
      'regenerate-apply',
    ]);
  });

  testSurfaces('the Regenerate sheet: Transcribe again', (tester, surface) async {
    final rig = RegenRig(project: (id) => regenProject(id, twoClips: true, scopeClips: const [Regen.second]));
    await rig.pump(tester, surface: surface);
    await rig.openSheet(tester);
    await rig.tapKey(tester, 'regenerate-mode-transcribe');
    await _check(tester, ['regenerate-mode-transcribe', 'regenerate-scope', 'regenerate-cancel', 'regenerate-apply']);
  });

  testSurfaces('the edited-cues confirmation', (tester, surface) async {
    final rig = RegenRig(project: (id) => regenProject(id, edited: {0, 1, 2}));
    await rig.pump(tester, surface: surface);
    await rig.openSheet(tester);
    await rig.tapKey(tester, 'regenerate-apply');
    await _check(tester, ['regenerate-edited-new', 'regenerate-edited-replace']);
  });

  testSurfaces('the interrupted-job notice', (tester, surface) async {
    final rig = RegenRig();
    final job = rig.transcription.start(rigRequest(rig.id)) as FakeTranscriptionJob;
    rig.transcription.interrupt(job, doneFraction: 0.73);
    await tester.runAsync(rig.settle);
    await rig.pump(tester, surface: surface);
    await _check(tester, ['captions-interrupted', 'captions-interrupted-discard', 'captions-interrupted-resume']);
  });

  testSurfaces('the captions settings section', (tester, surface) async {
    final f = FakeTranscriptionService(physicalRamBytes: 8 * gib, clock: () => DateTime.utc(2026, 10, 15));
    f.statuses[SpeechModelCatalog.balanced.id] = SpeechModelReady(InstalledSpeechModel(spec: SpeechModelCatalog.balanced, installedAt: DateTime.utc(2026, 10, 1)));
    f.statuses[SpeechModelCatalog.fast.id] = const SpeechModelCorrupt();
    f.statuses[SpeechModelCatalog.accurate.id] = const SpeechModelDownloading(ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: 50 << 20, total: 190 << 20));
    final h = EditorTestHarness(transcription: f);
    await h.pumpApp(
      tester,
      Scaffold(
        backgroundColor: DanaviewColors.background,
        body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: const [CaptionsSettingsSection()])),
      ),
      surface: surface,
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 100));
    await _check(tester, [
      'captions-settings-model-fast',
      'captions-settings-delete-fast',
      'captions-settings-model-balanced',
      'captions-settings-delete-balanced',
      'captions-settings-model-accurate',
      'captions-settings-layout',
      'captions-settings-privacy',
    ]);
    // In use by a job: every row says so.
    final job = f.start(rigRequest(const ProjectId('p')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 100));
    await _check(tester, ['captions-settings-delete-balanced']);
    job.cancel();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 100));
  });

  test('the matrix includes the narrowest surface at the largest text scale', () {
    expect(SurfaceMatrix.current, contains(SurfaceMatrix.narrowest));
  });
}
