// OWNER: UX-37
//
// Widget tests of the Auto captions sheet with FakeTranscriptionService (ai.md §16.2, ux.md §21.2):
// every state (checking, unsupported, configure, language picker, consent, downloading, running,
// paused, waiting for an export, needs language, done, failed) and the copy of every failure; the
// consent button shows the exact disclosure size; the language picker filters by English name,
// native name and code; semantics of the progress and of disabled tiers; Hide keeps the job
// running; no Material chrome.

import 'package:flutter/material.dart'
    show AlertDialog, CircularProgressIndicator, LinearProgressIndicator, ListTile, Scaffold, Slider, SnackBar, Switch;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/app/strings/captions_strings.dart';
import 'package:danaview_editor/src/editor/flows/captions/auto_captions_controller.dart';
import 'package:danaview_editor/src/editor/flows/captions/captions_progress_panel.dart';
import 'package:danaview_editor/src/editor/flows/captions/language_picker.dart';
import 'package:danaview_editor/src/editor/state/tasks_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import '../../support/support.dart';
import 'captions_rig.dart';

/// No Material chrome in the tree (ARCH §1.3 rule 1) plus the shared owner rules.
void expectNoMaterialChrome(WidgetTester tester) {
  for (final type in [AlertDialog, ListTile, Slider, LinearProgressIndicator, CircularProgressIndicator, Switch, SnackBar]) {
    expect(find.byType(type), findsNothing, reason: '$type found');
  }
  expectOwnerUiRules(tester);
}

AutoCaptionsState _state(WidgetTester tester, CaptionsRig rig) => rig.harness.containerOf(tester).read(autoCaptionsControllerProvider(rig.id));

Future<void> _toRunning(WidgetTester tester, CaptionsRig rig) async {
  rig.install();
  await rig.pump(tester);
  await rig.openSheet(tester);
  await rig.tapKey(tester, 'captions-create');
  expect(_state(tester, rig).stage, AutoCaptionsStage.running);
}

Future<void> _finishToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  group('configure', () {
    testWidgets('step 1 of 2 with the language, tiers with sizes, layout and the on-device note', (tester) async {
      final rig = CaptionsRig()..install(SpeechModelCatalog.fast);
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.byKey(const ValueKey('captions-configure')), findsOneWidget);
      expect(find.text('Step 1 of 2'), findsOneWidget);
      expect(find.text(CaptionsStrings.title), findsWidgets);
      expect(find.descendant(of: find.byKey(const ValueKey('captions-language')), matching: find.text('English')), findsOneWidget);
      expect(find.text('Fast · Ready'), findsOneWidget);
      expect(find.text('Balanced · 57 MB'), findsOneWidget);
      expect(find.text('Accurate · 181 MB'), findsOneWidget);
      expect(find.text(CaptionsStrings.presetName(SegmentationPreset.standard)), findsOneWidget);
      expect(find.text(CaptionsStrings.onDeviceNote), findsOneWidget);
      expect(find.text(CaptionsStrings.createCaptions), findsOneWidget);
      expect(find.text(CaptionsStrings.replacePrevious), findsNothing);
      expectNoMaterialChrome(tester);
    });

    testWidgets('a disabled tier exposes its reason; Accurate is hidden below 4 GB', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = CaptionsRig(ramBytes: (2.2 * gib).round());
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.textContaining('Accurate'), findsNothing);
      final balanced = tester.getSemantics(find.byKey(const ValueKey('captions-tier-balanced-semantics')));
      expect(balanced.getSemanticsData().hint, 'Needs a device with more memory');
      handle.dispose();
    });

    testWidgets('a generated lane shows Replace; Advanced lists tracks with music off', (tester) async {
      final rig = CaptionsRig(generated: true);
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.text(CaptionsStrings.replacePrevious), findsOneWidget);
      expect(find.text(CaptionsStrings.replacePreviousHint), findsOneWidget);
      await rig.tapKey(tester, 'captions-advanced');
      expect(find.byKey(const ValueKey('captions-advanced-section')), findsOneWidget);
      expect(find.text(CaptionsStrings.musicTrack), findsOneWidget);
      final c = rig.harness.containerOf(tester).read(autoCaptionsControllerProvider(rig.id).notifier);
      final music = _state(tester, rig).audioTracks.firstWhere((t) => t.music);
      expect(c.trackIncluded(music), isFalse);
      await rig.tapKey(tester, 'captions-sound-descriptions');
      expect(_state(tester, rig).draft.includeSoundDescriptions, isTrue);
      expectNoMaterialChrome(tester);
    });

    testWidgets('choosing a tier and a layout updates the draft', (tester) async {
      final rig = CaptionsRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'captions-tier-fast');
      await tester.ensureVisible(find.text(CaptionsStrings.presetName(SegmentationPreset.shortPhrases)));
      await tester.tap(find.text(CaptionsStrings.presetName(SegmentationPreset.shortPhrases)));
      await rig.pumpSome(tester);
      expect(_state(tester, rig).draft.tier, SpeechModelTier.fast);
      expect(_state(tester, rig).draft.segmentation.preset, SegmentationPreset.shortPhrases);
    });

    testWidgets('Cancel closes the sheet without changes', (tester) async {
      final rig = CaptionsRig();
      await rig.pump(tester);
      final before = rig.project;
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'captions-cancel');
      await rig.pumpSome(tester);
      expect(find.byKey(const ValueKey('captions-sheet')), findsNothing);
      expect(identical(rig.project, before), isTrue);
    });
  });

  group('language picker', () {
    testWidgets('filters by English name, native name and code; Detect automatically is secondary', (tester) async {
      final rig = CaptionsRig(prefs: {AutoCaptionsPrefKeys.recentLanguages: 'fr'});
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'captions-language');
      expect(find.byKey(const ValueKey('captions-language-picker')), findsOneWidget);
      expect(find.text(CaptionsStrings.recent), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-language-recent-fr')), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-language-device-en')), findsOneWidget);
      final auto = find.byKey(const ValueKey('captions-language-auto'));
      expect(auto, findsOneWidget);
      expect(tester.getTopLeft(auto).dy, greaterThan(tester.getTopLeft(find.byKey(const ValueKey('captions-language-device-en'))).dy));

      Future<void> search(String q) async {
        await tester.enterText(find.descendant(of: find.byKey(const ValueKey('captions-language-search')), matching: find.byType(EditableText)), q);
        await rig.pumpSome(tester, 4);
      }

      await search('Deutsch');
      expect(find.byKey(const ValueKey('captions-language-de')), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-language-en')), findsNothing);
      expect(auto, findsNothing);
      await search('spanish');
      expect(find.byKey(const ValueKey('captions-language-es')), findsOneWidget);
      await search('ja');
      expect(find.byKey(const ValueKey('captions-language-ja')), findsOneWidget);
      await search('zzzz');
      expect(find.byKey(const ValueKey('captions-language-none')), findsOneWidget);
      await search('日本語');
      await rig.tapKey(tester, 'captions-language-ja');
      expect(find.byKey(const ValueKey('captions-configure')), findsOneWidget);
      expect((_state(tester, rig).draft.language as FixedLanguage).code, 'ja');
    });

    test('languageMatches covers names and codes', () {
      final hindi = languageForWhisperCode('hi')!;
      expect(languageMatches(hindi, 'hin'), isTrue);
      expect(languageMatches(hindi, 'हिन्दी'), isTrue);
      expect(languageMatches(hindi, 'HI'), isTrue);
      expect(languageMatches(hindi, 'h'), isTrue);
      expect(languageMatches(hindi, 'urdu'), isFalse);
    });

    testWidgets('choosing Detect automatically', (tester) async {
      final rig = CaptionsRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'captions-language');
      await rig.tapKey(tester, 'captions-language-auto');
      expect(_state(tester, rig).draft.language, isA<AutoLanguage>());
      expect(find.descendant(of: find.byKey(const ValueKey('captions-language')), matching: find.text(CaptionsStrings.detectAutomatically)), findsOneWidget);
    });
  });

  group('consent', () {
    testWidgets('shows the disclosure; the primary button shows its exact size; Not now goes back', (tester) async {
      final rig = CaptionsRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'captions-create');
      final d = _state(tester, rig).disclosure!;
      expect(find.byKey(const ValueKey('captions-consent')), findsOneWidget);
      expect(find.text('Step 2 of 2'), findsOneWidget);
      expect(find.text(CaptionsStrings.consentTitle), findsOneWidget);
      expect(find.textContaining('huggingface.co'), findsWidgets);
      expect(find.textContaining('hf.co'), findsWidgets);
      expect(find.text(d.sha256), findsOneWidget);
      expect(find.textContaining(d.fileName), findsOneWidget);
      final label = 'Download ${(d.totalBytes / (1024 * 1024)).round()} MB';
      expect(CaptionsStrings.download(d), label);
      expect(find.text(label), findsOneWidget);
      expect(label, 'Download 58 MB', reason: 'Balanced (59,707,625 B) + VAD (885,098 B)');
      await rig.tapKey(tester, 'captions-consent-privacy');
      expect(rig.host.privacy, 1);
      expect(rig.transcription.consents, isEmpty);
      await rig.tapKey(tester, 'captions-consent-decline');
      expect(find.byKey(const ValueKey('captions-configure')), findsOneWidget);
      expectNoMaterialChrome(tester);
    });

    testWidgets('Download hands the view-made consent to the service and the job starts', (tester) async {
      final rig = CaptionsRig();
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'captions-create');
      final d = _state(tester, rig).disclosure!;
      await rig.tapKey(tester, 'captions-consent-accept');
      expect(rig.transcription.consents.single.disclosure, d);
      expect(_state(tester, rig).stage, AutoCaptionsStage.running);
      expect(find.byKey(const ValueKey('captions-running')), findsOneWidget);
      rig.job.cancel();
      await rig.pumpSome(tester);
    });

    testWidgets('a damaged model says Download again; missing space disables Download', (tester) async {
      final rig = CaptionsRig();
      rig.transcription.statuses[SpeechModelCatalog.balanced.id] = const SpeechModelCorrupt();
      rig.transcription.preflightOverride = TranscriptionPreflight(
        ok: false,
        failure: const DiskFullFailure(),
        downloadBytes: SpeechModelCatalog.balanced.bytes + SpeechModelCatalog.vad.bytes,
      );
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'captions-create');
      final d = _state(tester, rig).disclosure!;
      expect(find.text(CaptionsStrings.consentTitleCorrupt), findsOneWidget);
      expect(find.text(CaptionsStrings.downloadAgain(d)), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-consent-space')), findsOneWidget);
      await rig.tapKey(tester, 'captions-consent-accept');
      expect(rig.transcription.consents, isEmpty);
    });

    testWidgets('a download failure shows its copy and Try again asks for consent again', (tester) async {
      final rig = CaptionsRig();
      rig.transcription.downloadFailure = const ModelDownloadFailure(ModelDownloadFailureKind.offline);
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'captions-create');
      await rig.tapKey(tester, 'captions-consent-accept');
      expect(find.text("You're offline"), findsOneWidget);
      expect(find.text('Connect to the internet to download the speech model.'), findsOneWidget);
      rig.transcription.downloadFailure = null;
      await rig.tapKey(tester, 'captions-retry');
      expect(find.byKey(const ValueKey('captions-consent')), findsOneWidget);
    });
  });

  group('progress', () {
    testWidgets('the download panel shows received of total, rate and Cancel', (tester) async {
      var cancelled = 0;
      await tester.pumpWidget(surfaceApp(
        SurfaceMatrix.phone,
        Scaffold(
          body: CaptionsProgressPanel.download(
            download: const ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: 23 * 1048576 + 5, total: 60592723, bytesPerSecond: 2.5 * 1048576),
            onCancel: () => cancelled++,
          ),
        ),
      ));
      expect(find.text('Downloading speech model… 23 of 58 MB'), findsOneWidget);
      expect(find.text('2.5 MB/s'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('captions-cancel')));
      expect(cancelled, 1);
      expectNoMaterialChrome(tester);
    });

    testWidgets('a resumed download says so before the first byte', (tester) async {
      await tester.pumpWidget(surfaceApp(
        SurfaceMatrix.phone,
        Scaffold(body: CaptionsProgressPanel.download(download: null, resumed: true, onCancel: () {})),
      ));
      expect(find.text(CaptionsStrings.resumingDownload), findsOneWidget);
    });

    testWidgets('running: phases, percent and ETA, spoken progress, partial preview, paused lines', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = CaptionsRig();
      await _toRunning(tester, rig);
      final job = rig.job;
      job.emit(CaptionsRig.sample(TranscriptionPhase.extractingAudio, 0.05, unit: 1, units: 3));
      await rig.pumpSome(tester, 2);
      expect(find.text('Preparing audio (2 of 3)'), findsOneWidget);
      job.emit(CaptionsRig.sample(TranscriptionPhase.loadingModel, 0.08));
      await rig.pumpSome(tester, 2);
      expect(find.text('Loading speech model'), findsOneWidget);
      job.emit(CaptionsRig.sample(TranscriptionPhase.detectingLanguage, 0.1));
      await rig.pumpSome(tester, 2);
      expect(find.text('Detecting language'), findsOneWidget);
      job.emit(CaptionsRig.sample(TranscriptionPhase.transcribing, 0.42, eta: const Duration(minutes: 2), partial: 'and so we went down to the river'));
      await rig.pumpSome(tester, 2);
      expect(find.text('Creating captions · 42% · about 2 min left'), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-partial')), findsOneWidget);
      expect(tester.getSemantics(find.byKey(const ValueKey('captions-progress-bar'))).getSemanticsData().value, 'Creating captions, 42 percent');
      job.emit(CaptionsRig.sample(TranscriptionPhase.transcribing, 0.5, paused: PauseReason.background));
      await rig.pumpSome(tester, 2);
      expect(find.text('Paused while Danaview is in the background'), findsOneWidget);
      job.emit(CaptionsRig.sample(TranscriptionPhase.transcribing, 0.5, paused: PauseReason.thermal));
      await rig.pumpSome(tester, 2);
      expect(find.text('Paused while your device cools down'), findsOneWidget);
      job.emit(CaptionsRig.sample(TranscriptionPhase.transcribing, 0.5, paused: PauseReason.waitingForExport));
      await rig.pumpSome(tester, 2);
      expect(_state(tester, rig).stage, AutoCaptionsStage.waitingForExport);
      expect(find.text('Waiting for the export to finish'), findsOneWidget);
      job.emit(CaptionsRig.sample(TranscriptionPhase.segmenting, 1));
      await rig.pumpSome(tester, 2);
      expect(find.text('Finishing up'), findsOneWidget);
      expectNoMaterialChrome(tester);
      handle.dispose();
      job.cancel();
      await rig.pumpSome(tester);
    });

    testWidgets('Hide closes the sheet, the job keeps running in Tasks, reopening shows it', (tester) async {
      final rig = CaptionsRig();
      await _toRunning(tester, rig);
      final c = rig.harness.containerOf(tester);
      final rows = c.read(tasksControllerProvider(rig.id)).tasks;
      expect(rows.single.label, CaptionsStrings.jobTask);
      await rig.tapKey(tester, 'captions-hide');
      await rig.pumpSome(tester);
      expect(find.byKey(const ValueKey('captions-sheet')), findsNothing);
      expect(rig.job.cancelled, isFalse);
      rig.job.emit(CaptionsRig.sample(TranscriptionPhase.transcribing, 0.7));
      await rig.pumpSome(tester, 2);
      await rig.openSheet(tester);
      expect(find.byKey(const ValueKey('captions-running')), findsOneWidget);
      expect(find.text('Creating captions · 70%'), findsOneWidget);
      rig.job.cancel();
      await rig.pumpSome(tester);
    });

    testWidgets('Cancel stops the job, closes the sheet and adds nothing', (tester) async {
      final rig = CaptionsRig();
      await _toRunning(tester, rig);
      final before = rig.project;
      await rig.tapKey(tester, 'captions-cancel');
      await rig.pumpSome(tester);
      expect(rig.job.cancelled, isTrue);
      expect(find.byKey(const ValueKey('captions-sheet')), findsNothing);
      expect(identical(rig.project, before), isTrue);
      expect(rig.subtitleTracks, isEmpty);
    });
  });

  group('needs language (D-19)', () {
    testWidgets('top-3 chips with percentages; Continue answers the job', (tester) async {
      final rig = CaptionsRig();
      await _toRunning(tester, rig);
      final answer = rig.job.waitForLanguage(const [LanguageProbability('hi', 0.45), LanguageProbability('ur', 0.4), LanguageProbability('en', 0.05)]);
      await rig.pumpSome(tester, 3);
      expect(find.text(CaptionsStrings.whichLanguage), findsOneWidget);
      expect(find.text('Hindi 45%'), findsOneWidget);
      expect(find.text('Urdu 40%'), findsOneWidget);
      expect(find.text('English 5%'), findsOneWidget);
      expect(find.text(CaptionsStrings.otherLanguage), findsOneWidget);
      await rig.tapKey(tester, 'captions-continue');
      expect(rig.job.providedLanguages, isEmpty, reason: 'Continue is disabled until a language is chosen');
      await rig.tapKey(tester, 'captions-candidate-ur');
      await rig.tapKey(tester, 'captions-continue');
      expect(await answer, 'ur');
      expect(_state(tester, rig).stage, AutoCaptionsStage.running);
      expectNoMaterialChrome(tester);
      rig.job.cancel();
      await rig.pumpSome(tester);
    });

    testWidgets('Other language opens the picker without Detect automatically', (tester) async {
      final rig = CaptionsRig();
      await _toRunning(tester, rig);
      rig.job.waitForLanguage(const [LanguageProbability('hi', 0.45)]).ignore();
      await rig.pumpSome(tester, 3);
      await rig.tapKey(tester, 'captions-other-language');
      expect(find.byKey(const ValueKey('captions-language-picker')), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-language-auto')), findsNothing);
      // English was used to start, so it is a recent language now.
      await rig.tapKey(tester, 'captions-language-recent-en');
      expect(rig.job.providedLanguages, ['en']);
      rig.job.cancel();
      await rig.pumpSome(tester);
    });
  });

  group('done', () {
    testWidgets('the sheet closes, the toast counts the captions and one entry was added', (tester) async {
      final rig = CaptionsRig();
      await _toRunning(tester, rig);
      final before = rig.editorState.history.position;
      rig.job.finish(rig.transcription.sampleResult(rig.job.request));
      await rig.pumpSome(tester);
      expect(find.byKey(const ValueKey('captions-sheet')), findsNothing);
      expect(find.text('Added 3 captions (English)'), findsOneWidget);
      expect(rig.editorState.history.position, before + 1);
      expect(rig.subtitleTracks.single.items, hasLength(3));
      await _finishToasts(tester);
    });

    test('the toast mentions skipped clips', () {
      const summary = TranscriptionSummary(cues: 128, words: 900, language: 'en', skipped: [SkippedClip(ItemId('a'), 'reversed'), SkippedClip(ItemId('b'), 'muted')]);
      expect(CaptionsStrings.added(summary), 'Added 128 captions. 2 clips were skipped');
    });
  });

  group('failures', () {
    final cases = <TranscriptionFailure, String>{
      const UnsupportedDeviceFailure('abi'): "Auto captions aren't available on this device",
      const ModelMissingFailure(): "The speech model isn't downloaded",
      const ModelDownloadFailure(ModelDownloadFailureKind.checksumMismatch): 'The download was damaged',
      const ModelCorruptFailure(): 'The speech model is damaged',
      const InsufficientMemoryFailure(suggestedTier: SpeechModelTier.fast): 'Not enough memory for this quality',
      const DiskFullFailure(): 'Not enough free space',
      const MediaOfflineFailure(MediaId('m_v')): "A clip's media is missing",
      const NoAudioFailure(): 'No audio to caption',
      const UnsupportedAudioFailure('opus'): "This audio format isn't supported",
      const AudioDecodeFailure(): "The audio couldn't be read",
      const NoSpeechFailure(): 'No speech found',
      const InferenceFailure(): 'Auto captions stopped',
      const TranscriptionInterrupted(): 'Auto captions were interrupted',
    };
    for (final entry in cases.entries) {
      testWidgets('${entry.key.code} shows its copy and Back', (tester) async {
        final rig = CaptionsRig();
        await _toRunning(tester, rig);
        rig.job.fail(entry.key);
        await rig.pumpSome(tester);
        expect(find.byKey(const ValueKey('captions-failed')), findsOneWidget);
        expect(find.text(entry.value), findsOneWidget);
        expect(find.text(CaptionsStrings.failure(entry.key)!.message), findsOneWidget);
        expect(rig.subtitleTracks, isEmpty);
        expectNoMaterialChrome(tester);
        await rig.tapKey(tester, 'captions-back');
        expect(find.byKey(const ValueKey('captions-configure')), findsOneWidget);
      });
    }

    testWidgets('No speech found uses the dialog copy', (tester) async {
      final rig = CaptionsRig();
      await _toRunning(tester, rig);
      rig.job.fail(const NoSpeechFailure());
      await rig.pumpSome(tester);
      expect(find.text('No speech found'), findsOneWidget);
      expect(find.text("We couldn't hear anyone speaking in the selected clips."), findsOneWidget);
      await rig.tapKey(tester, 'captions-close');
      expect(find.byKey(const ValueKey('captions-sheet')), findsNothing);
    });

    testWidgets('a memory failure offers Use Fast', (tester) async {
      final rig = CaptionsRig();
      await _toRunning(tester, rig);
      rig.job.fail(const InsufficientMemoryFailure(suggestedTier: SpeechModelTier.fast));
      await rig.pumpSome(tester);
      await rig.tapKey(tester, 'captions-use-tier');
      expect(_state(tester, rig).draft.tier, SpeechModelTier.fast);
      expect(find.byKey(const ValueKey('captions-configure')), findsOneWidget);
    });

    testWidgets('a refused apply (locked lane) shows the rejection copy', (tester) async {
      final rig = CaptionsRig(generated: true, locked: true);
      await _toRunning(tester, rig);
      rig.job.finish(rig.transcription.sampleResult(rig.job.request));
      await rig.pumpSome(tester);
      expect(find.byKey(const ValueKey('captions-failed')), findsOneWidget);
      expect(find.text('This track is locked'), findsOneWidget);
      await _finishToasts(tester);
    });

    testWidgets('an unsupported device shows the unsupported view', (tester) async {
      final rig = CaptionsRig();
      rig.transcription.supportState = const TranscriptionUnsupported('osVersion');
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.byKey(const ValueKey('captions-unsupported')), findsOneWidget);
      expect(find.text(CaptionsStrings.unsupported.title), findsOneWidget);
      expectNoMaterialChrome(tester);
    });
  });
}
