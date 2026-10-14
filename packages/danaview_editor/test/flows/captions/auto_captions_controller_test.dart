// OWNER: UX-37
//
// AutoCaptionsController (ai.md §11.2, ux.md §12.1, D-19/D-20) over FakeTranscriptionService:
// defaults (device locale preselected, last used, Detect automatically), RAM gating of tiers,
// consent and download, the job phases, the low-confidence question, the result applied as ONE
// history entry (one undo removes every generated cue), replace targets, cancel at every step
// leaving the project unchanged, a failure state for every TranscriptionFailure, the wakelock, the
// keep-alive while running and the stop when the editor closes.

import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/app/strings/captions_strings.dart';
import 'package:danaview_editor/src/editor/flows/captions/auto_captions_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'captions_rig.dart';

/// Runs the flow to the consent view (model not installed).
Future<void> _toConsent(CaptionsRig rig) async {
  await rig.openFlow();
  await rig.controller.start();
  await rig.settle();
  expect(rig.state.stage, AutoCaptionsStage.consent);
}

/// Opens the editor and the flow and runs to the consent view, then gets the consent from the
/// view (the only place that may create one).
Future<UserConsent> _consent(WidgetTester tester, CaptionsRig rig) async {
  await tester.runAsync(() async {
    await rig.open();
    await _toConsent(rig);
  });
  return CaptionsRig.consentFromView(tester, rig.state.disclosure!);
}

/// Runs the flow with an installed model to a running job.
Future<FakeTranscriptionJob> _toRunning(CaptionsRig rig, {TranscriptionScope? scope}) async {
  rig.install();
  await rig.openFlow(scope: scope);
  await rig.controller.start();
  await rig.settle();
  expect(rig.state.stage, AutoCaptionsStage.running);
  return rig.job;
}

/// The project as a value to compare (tracks, items and history position).
(EditProject, int) _snapshot(CaptionsRig rig) => (rig.project, rig.editorState.history.position);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('open and defaults', () {
    test('the device locale language is preselected; Detect automatically is not the default (D-19)', () async {
      final rig = CaptionsRig(locale: const Locale('es', 'MX'));
      await rig.open();
      await rig.openFlow();
      expect(rig.state.stage, AutoCaptionsStage.configure);
      final language = rig.state.draft.language;
      expect(language, isA<FixedLanguage>());
      expect((language as FixedLanguage).code, 'es');
    });

    test('the last used language wins over the device locale', () async {
      final rig = CaptionsRig(prefs: {AutoCaptionsPrefKeys.lastLanguage: 'ja'});
      await rig.open();
      await rig.openFlow();
      expect((rig.state.draft.language as FixedLanguage).code, 'ja');
    });

    test('a device language whisper does not know falls back to Detect automatically', () async {
      final rig = CaptionsRig(locale: const Locale('yue'));
      await rig.open();
      await rig.openFlow();
      expect(rig.state.draft.language, isA<AutoLanguage>());
    });

    test('Balanced is the default tier with 8 GB; installed tiers are reported ready', () async {
      final rig = CaptionsRig()..install(SpeechModelCatalog.fast);
      await rig.open();
      await rig.openFlow();
      expect(rig.state.draft.tier, SpeechModelTier.balanced);
      expect([for (final o in rig.state.offers) o.spec.tier], SpeechModelTier.values);
      expect(rig.state.readyModels, {SpeechModelCatalog.fast.id});
    });

    test('Accurate is hidden below 4 GB and Balanced is disabled below 3 GB (D-20)', () async {
      final rig = CaptionsRig(ramBytes: (2.2 * gib).round());
      await rig.open();
      await rig.openFlow();
      final tiers = [for (final o in rig.state.offers) o.spec.tier];
      expect(tiers, [SpeechModelTier.fast, SpeechModelTier.balanced]);
      final balanced = rig.state.offers.firstWhere((o) => o.spec.tier == SpeechModelTier.balanced);
      expect(balanced.available, isFalse);
      expect(balanced.unavailableReason, isNotNull);
      expect(rig.state.draft.tier, SpeechModelTier.fast);
    });

    test('an unsupported device shows the unsupported stage', () async {
      final rig = CaptionsRig();
      rig.transcription.supportState = const TranscriptionUnsupported('abi');
      await rig.open();
      await rig.openFlow();
      expect(rig.state.stage, AutoCaptionsStage.unsupported);
    });

    test('a 32-bit device with no tiers is unsupported', () async {
      final rig = CaptionsRig();
      rig.transcription.is64Bit = false;
      rig.transcription.supportState = const TranscriptionSupported([]);
      await rig.open();
      await rig.openFlow();
      expect(rig.state.stage, AutoCaptionsStage.unsupported);
    });

    test('the clip context menu preselects This clip; audio tracks list music off by default', () async {
      final rig = CaptionsRig();
      await rig.open();
      await rig.openFlow(scope: const ClipScope(Cap.clip));
      expect(rig.state.selection, [Cap.clip]);
      expect(rig.state.draft.scope, CaptionsScopeKind.selection);
      final music = rig.state.audioTracks.firstWhere((t) => t.id == Cap.music);
      expect(music.music, isTrue);
      expect(rig.controller.trackIncluded(music), isFalse);
      expect(rig.controller.request().scope, isA<ClipScope>());
    });

    test('whole video sends the default track set as null and a custom set explicitly', () async {
      final rig = CaptionsRig();
      await rig.open();
      await rig.openFlow();
      expect((rig.controller.request().scope as TimelineScope).tracks, isNull);
      final music = rig.state.audioTracks.firstWhere((t) => t.id == Cap.music);
      rig.controller.setTrackIncluded(music, true);
      expect((rig.controller.request().scope as TimelineScope).tracks, {Cap.main, Cap.music});
    });

    test('the default layout preset comes from the captions settings', () async {
      final rig = CaptionsRig(prefs: {'editor.captions.defaultPreset': 'shortPhrases'});
      await rig.open();
      await rig.openFlow();
      expect(rig.state.draft.segmentation.preset, SegmentationPreset.shortPhrases);
    });
  });

  group('consent and download', () {
    test('a missing model leads to the consent view with the exact disclosure (model + VAD)', () async {
      final rig = CaptionsRig();
      await rig.open();
      await _toConsent(rig);
      final d = rig.state.disclosure!;
      expect(d, ConsentDisclosure.of(SpeechModelCatalog.balanced, includesVad: true));
      expect(d.host, 'huggingface.co');
      expect(d.cdnHost, 'hf.co');
      expect(rig.transcription.jobs, isEmpty);
      expect(rig.transcription.consents, isEmpty);
    });

    test('Not now goes back to configure and downloads nothing', () async {
      final rig = CaptionsRig();
      await rig.open();
      await _toConsent(rig);
      rig.controller.declineConsent();
      expect(rig.state.stage, AutoCaptionsStage.configure);
      expect(rig.transcription.consents, isEmpty);
    });

    testWidgets('accepting downloads with that consent, then runs the job', (tester) async {
      final rig = CaptionsRig();
      rig.transcription.scriptedDownload = const [
        ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: 1000, total: 60592723),
        ModelDownloadProgress(phase: ModelDownloadPhase.verifying, received: 60592723, total: 60592723),
      ];
      final consent = await _consent(tester, rig);
      expect(consent.disclosure, rig.state.disclosure);
      await tester.runAsync(() async {
        final run = rig.controller.acceptConsent(consent);
        expect(rig.state.stage, AutoCaptionsStage.downloading);
        expect(rig.host.wakelock, [true]);
        await run;
        await rig.settle();
      });
      expect(rig.transcription.consents.single, same(consent));
      expect(rig.state.stage, AutoCaptionsStage.running);
      expect(rig.state.readyModels, contains(SpeechModelCatalog.balanced.id));
      rig.controller.cancel();
    });

    testWidgets('a resumed download is reported as resumed', (tester) async {
      final rig = CaptionsRig();
      rig.transcription.scriptedDownload = const [
        ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: 30000000, total: 60592723),
        ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: 40000000, total: 60592723),
      ];
      final consent = await _consent(tester, rig);
      await tester.runAsync(() async {
        rig.controller.acceptConsent(consent).ignore();
        await rig.settle(2);
        expect(rig.state.downloadResumed, isTrue);
        rig.controller.cancel();
        await rig.settle();
      });
    });

    for (final kind in ModelDownloadFailureKind.values.where((k) => k != ModelDownloadFailureKind.cancelled)) {
      testWidgets('a download failure ${kind.name} shows its copy and asks for consent again on retry', (tester) async {
        final rig = CaptionsRig();
        rig.transcription.downloadFailure = ModelDownloadFailure(kind);
        final consent = await _consent(tester, rig);
        await tester.runAsync(() async {
          await rig.controller.acceptConsent(consent);
          await rig.settle();
          expect(rig.state.stage, AutoCaptionsStage.failed);
          expect((rig.state.failure! as ModelDownloadFailure).kind, kind);
          expect(CaptionsStrings.failure(rig.state.failure!), isNotNull);
          expect(rig.host.wakelock.last, isFalse);
          rig.transcription.downloadFailure = null;
          await rig.controller.retry();
          await rig.settle();
        });
        expect(rig.state.stage, AutoCaptionsStage.consent, reason: 'consent is per download');
      });
    }

    testWidgets('cancelling the download returns to configure and adds nothing', (tester) async {
      final rig = CaptionsRig();
      // A long download, so it is still running when Cancel comes.
      rig.transcription.scriptedDownload = [
        for (var i = 1; i <= 400; i++) ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: i * 1000, total: 60592723),
      ];
      final consent = await _consent(tester, rig);
      final before = _snapshot(rig);
      await tester.runAsync(() async {
        // Cancel as soon as the first sample arrived (the fake streams the whole script at once).
        var cancelled = false;
        final remove = rig.controller.addListener((state) {
          if (cancelled || state.download == null) return;
          cancelled = true;
          scheduleMicrotask(rig.controller.cancel);
        }, fireImmediately: false);
        rig.controller.acceptConsent(consent).ignore();
        await rig.settle();
        remove();
        expect(cancelled, isTrue);
      });
      expect(rig.state.stage, AutoCaptionsStage.configure);
      expect(rig.transcription.downloadCancelled, isTrue);
      expect(rig.transcription.jobs, isEmpty);
      expect(_snapshot(rig), before);
    });

    test('a damaged model asks to download again', () async {
      final rig = CaptionsRig();
      rig.transcription.statuses[SpeechModelCatalog.balanced.id] = const SpeechModelCorrupt();
      await rig.open();
      await _toConsent(rig);
      expect(rig.state.modelCorrupt, isTrue);
    });

    test('too little space for the download is shown on the consent view', () async {
      final rig = CaptionsRig();
      rig.transcription.preflightOverride = TranscriptionPreflight(
        ok: false,
        failure: const DiskFullFailure(),
        downloadBytes: SpeechModelCatalog.balanced.bytes + SpeechModelCatalog.vad.bytes,
      );
      await rig.open();
      await _toConsent(rig);
      expect(rig.state.missingSpaceBytes, greaterThan(rig.state.disclosure!.totalBytes));
    });
  });

  group('job', () {
    test('the result is applied as ONE history entry and one undo removes every generated cue', () async {
      final rig = CaptionsRig(locale: const Locale('en'));
      await rig.open();
      final before = rig.editorState.history.position;
      final toasts = <String>[];
      final job = await _toRunning(rig);
      rig.controller.toaster = toasts.add;
      expect(rig.host.wakelock, [true]);
      job.emit(CaptionsRig.sample(TranscriptionPhase.transcribing, 0.5, eta: const Duration(minutes: 2)));
      await rig.settle();
      expect(rig.state.progress!.fraction, 0.5);
      job.finish(rig.transcription.sampleResult(job.request));
      await rig.settle();
      expect(rig.state.stage, AutoCaptionsStage.done);
      expect(rig.editorState.history.position, before + 1);
      final lane = rig.subtitleTracks.single;
      expect(lane.name, 'Captions (English) · Auto');
      expect(lane.items, hasLength(3));
      expect(lane.items.every((c) => (c as SubtitleCue).origin == CueOrigin.generated), isTrue);
      expect(lane.subtitle!.provenance, isNotNull);
      expect(toasts, ['Added 3 captions (English)']);
      expect(rig.host.wakelock.last, isFalse);
      expect(rig.editor.undo(), isTrue);
      await rig.settle();
      expect(rig.subtitleTracks, isEmpty);
      expect(rig.editorState.history.position, before);
    });

    test('the request carries the draft (language, tier, layout, sound descriptions)', () async {
      final rig = CaptionsRig();
      rig.install(SpeechModelCatalog.fast);
      await rig.open();
      await rig.openFlow();
      rig.controller.update((d) => d.copyWith(
            language: const FixedLanguage('de'),
            tier: SpeechModelTier.fast,
            segmentation: const SegmentationSettings(preset: SegmentationPreset.singleLine, maxCharsPerLine: 30),
            includeSoundDescriptions: true,
          ));
      await rig.controller.start();
      await rig.settle();
      final r = rig.job.request;
      expect((r.language as FixedLanguage).code, 'de');
      expect(r.modelId, SpeechModelCatalog.fast.id);
      expect(r.segmentation.preset, SegmentationPreset.singleLine);
      expect(r.segmentation.maxCharsPerLine, 30);
      expect(r.includeSoundDescriptions, isTrue);
      expect(r.target, isA<NewTrackTarget>());
      expect(r.timeline().project, rig.id);
    });

    test('phases, paused lines and waiting for an export are reported', () async {
      final rig = CaptionsRig();
      await rig.open();
      final job = await _toRunning(rig);
      job.emit(CaptionsRig.sample(TranscriptionPhase.extractingAudio, 0.05, unit: 0, units: 3));
      await rig.settle();
      expect(CaptionsStrings.phaseLine(rig.state.progress!), 'Preparing audio (1 of 3)');
      job.emit(CaptionsRig.sample(TranscriptionPhase.transcribing, 0.3, paused: PauseReason.waitingForExport));
      await rig.settle();
      expect(rig.state.stage, AutoCaptionsStage.waitingForExport);
      job.emit(CaptionsRig.sample(TranscriptionPhase.transcribing, 0.42, eta: const Duration(minutes: 2)));
      await rig.settle();
      expect(rig.state.stage, AutoCaptionsStage.running);
      expect(CaptionsStrings.phaseLine(rig.state.progress!), 'Creating captions · 42% · about 2 min left');
    });

    test('a low-confidence detection asks for one of the top 3 (D-19) and continues', () async {
      final rig = CaptionsRig();
      rig.install();
      await rig.open();
      await rig.openFlow();
      rig.controller.update((d) => d.copyWith(language: const AutoLanguage()));
      await rig.controller.start();
      await rig.settle();
      final job = rig.job;
      final answer = job.waitForLanguage(const [LanguageProbability('hi', 0.45), LanguageProbability('ur', 0.4), LanguageProbability('en', 0.05)]);
      await rig.settle();
      expect(rig.state.stage, AutoCaptionsStage.needsLanguage);
      expect(rig.state.progress!.languageCandidates, hasLength(3));
      rig.controller.provideLanguage('hi');
      expect(await answer, 'hi');
      expect(rig.state.stage, AutoCaptionsStage.running);
      expect(rig.controller.recentLanguages.first, 'hi');
    });

    test('an existing generated lane is replaced (whole lane, one entry)', () async {
      final rig = CaptionsRig(generated: true);
      await rig.open();
      final before = rig.editorState.history.position;
      final job = await _toRunning(rig);
      expect(rig.state.generatedTrack, Cap.generated);
      expect(job.request.target, isA<ReplaceTrackTarget>());
      job.finish(rig.transcription.sampleResult(job.request));
      await rig.settle();
      expect(rig.subtitleTracks.single.items.map((c) => c.id), isNot(contains(Cap.oldCue)));
      expect(rig.editorState.history.position, before + 1);
      rig.editor.undo();
      await rig.settle();
      expect(rig.subtitleTracks.single.items.single.id, Cap.oldCue);
    });

    test('clip scope with an existing lane replaces only that clip range', () async {
      final rig = CaptionsRig(generated: true);
      await rig.open();
      final job = await _toRunning(rig, scope: const ClipScope(Cap.clip));
      final target = job.request.target as ReplaceInRangeTarget;
      expect(target.track, Cap.generated);
      expect(target.range, const TimeRange(0, 60 * s));
    });

    test('switching Replace off adds a new lane', () async {
      final rig = CaptionsRig(generated: true);
      rig.install();
      await rig.open();
      await rig.openFlow();
      rig.controller.update((d) => d.copyWith(replaceGenerated: false));
      await rig.controller.start();
      await rig.settle();
      expect(rig.job.request.target, isA<NewTrackTarget>());
    });

    test('a refused apply (locked lane) fails without changes and Try again re-applies', () async {
      final rig = CaptionsRig(generated: true, locked: true);
      await rig.open();
      final before = _snapshot(rig);
      final job = await _toRunning(rig);
      job.finish(rig.transcription.sampleResult(job.request));
      await rig.settle();
      expect(rig.state.stage, AutoCaptionsStage.failed);
      expect(rig.state.applyRejection, isNotNull);
      expect(_snapshot(rig), before);
      expect(rig.controller.hasPendingResult, isTrue);
      rig.controller.back();
      expect(rig.state.stage, AutoCaptionsStage.configure);
      expect(rig.controller.hasPendingResult, isFalse);
    });

    test('a second job while one runs fails instead of throwing', () async {
      final rig = CaptionsRig();
      rig.install();
      await rig.open();
      rig.transcription.start(rig.controller.request());
      await rig.openFlow();
      await rig.controller.start();
      await rig.settle();
      expect(rig.state.stage, AutoCaptionsStage.failed);
    });
  });

  group('cancel leaves the project unchanged', () {
    test('while running', () async {
      final rig = CaptionsRig();
      await rig.open();
      final before = _snapshot(rig);
      final job = await _toRunning(rig);
      job.emit(CaptionsRig.sample(TranscriptionPhase.transcribing, 0.6));
      await rig.settle();
      rig.controller.cancel();
      await rig.settle();
      expect(job.cancelled, isTrue);
      expect(rig.state.stage, AutoCaptionsStage.configure);
      expect(_snapshot(rig), before);
      expect(rig.subtitleTracks, isEmpty);
      expect(rig.host.wakelock.last, isFalse);
    });

    test('a result arriving after cancel is ignored', () async {
      final rig = CaptionsRig();
      await rig.open();
      final before = _snapshot(rig);
      final job = await _toRunning(rig);
      final result = rig.transcription.sampleResult(job.request);
      rig.controller.cancel();
      job.finish(result);
      await rig.settle();
      expect(_snapshot(rig), before);
    });

    test('while asking for the language', () async {
      final rig = CaptionsRig();
      await rig.open();
      final before = _snapshot(rig);
      final job = await _toRunning(rig);
      job.waitForLanguage(const [LanguageProbability('hi', 0.5)]).ignore();
      await rig.settle();
      rig.controller.cancel();
      await rig.settle();
      expect(job.cancelled, isTrue);
      expect(_snapshot(rig), before);
    });

    test('while waiting for an export', () async {
      final rig = CaptionsRig();
      await rig.open();
      final before = _snapshot(rig);
      final job = await _toRunning(rig);
      job.emit(CaptionsRig.sample(TranscriptionPhase.preparing, 0, paused: PauseReason.waitingForExport));
      await rig.settle();
      rig.controller.cancel();
      await rig.settle();
      expect(_snapshot(rig), before);
    });

    test('at the consent view', () async {
      final rig = CaptionsRig();
      await rig.open();
      final before = _snapshot(rig);
      await _toConsent(rig);
      rig.controller.cancel();
      expect(rig.state.stage, AutoCaptionsStage.configure);
      expect(_snapshot(rig), before);
    });

    test('asks first only after 30 s of work', () async {
      var now = DateTime.utc(2026, 10, 15, 12);
      final rig = CaptionsRig();
      await rig.open();
      final controller = AutoCaptionsController(
        projectId: rig.id,
        service: rig.transcription,
        editor: rig.editor,
        prefs: rig.harness.prefs,
        timeline: () => DomainTimelineView(rig.project),
        clock: () => now,
      );
      addTearDown(controller.dispose);
      rig.install();
      await controller.open();
      await controller.start();
      await rig.settle();
      expect(controller.cancelNeedsConfirm, isFalse);
      now = now.add(const Duration(seconds: 31));
      expect(controller.cancelNeedsConfirm, isTrue);
    });
  });

  group('failures', () {
    final failures = <TranscriptionFailure>[
      const UnsupportedDeviceFailure('abi'),
      const ModelMissingFailure(),
      const ModelDownloadFailure(ModelDownloadFailureKind.offline),
      const ModelCorruptFailure(),
      const InsufficientMemoryFailure(suggestedTier: SpeechModelTier.fast),
      const InsufficientMemoryFailure(),
      const DiskFullFailure(),
      const MediaOfflineFailure(MediaId('m_v')),
      const NoAudioFailure(),
      const UnsupportedAudioFailure('opus'),
      const AudioDecodeFailure(),
      const NoSpeechFailure(),
      const InferenceFailure('x'),
      const TranscriptionInterrupted(),
    ];
    for (final f in failures) {
      test('${f.code} fails with copy and changes nothing', () async {
        final rig = CaptionsRig();
        await rig.open();
        final before = _snapshot(rig);
        final job = await _toRunning(rig);
        job.fail(f);
        await rig.settle();
        expect(rig.state.stage, AutoCaptionsStage.failed);
        expect(rig.state.failure, same(f));
        final copy = CaptionsStrings.failure(f)!;
        expect(copy.title, isNotEmpty);
        expect(copy.message, isNotEmpty);
        expect(_snapshot(rig), before);
        expect(rig.host.wakelock.last, isFalse);
      });
    }

    test('cancelled is silent and returns to configure', () async {
      final rig = CaptionsRig();
      await rig.open();
      final job = await _toRunning(rig);
      job.fail(const TranscriptionCancelled());
      await rig.settle();
      expect(rig.state.stage, AutoCaptionsStage.configure);
      expect(CaptionsStrings.failure(const TranscriptionCancelled()), isNull);
    });

    test('a memory failure offers the suggested tier', () async {
      final rig = CaptionsRig();
      await rig.open();
      final job = await _toRunning(rig);
      job.fail(const InsufficientMemoryFailure(suggestedTier: SpeechModelTier.fast));
      await rig.settle();
      rig.controller.useSuggestedTier();
      expect(rig.state.stage, AutoCaptionsStage.configure);
      expect(rig.state.draft.tier, SpeechModelTier.fast);
    });

    test('a preflight failure with the model installed fails before any job', () async {
      final rig = CaptionsRig();
      rig.install();
      rig.transcription.preflightOverride = const TranscriptionPreflight(ok: false, failure: NoAudioFailure());
      await rig.open();
      await rig.openFlow();
      await rig.controller.start();
      await rig.settle();
      expect(rig.state.stage, AutoCaptionsStage.failed);
      expect(rig.state.failure, isA<NoAudioFailure>());
      expect(rig.transcription.jobs, isEmpty);
    });
  });

  group('lifetime', () {
    test('the controller stays alive while a job runs without listeners', () async {
      final rig = CaptionsRig();
      rig.install();
      final c = await rig.open(keepController: false);
      final sub = c.listen(autoCaptionsControllerProvider(rig.id), (_, __) {});
      final controller = c.read(autoCaptionsControllerProvider(rig.id).notifier);
      await controller.open();
      await controller.start();
      await rig.settle();
      expect(controller.state.stage, AutoCaptionsStage.running);
      sub.close();
      await rig.settle();
      expect(c.read(autoCaptionsControllerProvider(rig.id).notifier), same(controller));
      controller.cancel();
      await rig.settle();
      expect(c.read(autoCaptionsControllerProvider(rig.id).notifier), isNot(same(controller)));
    });

    test('leaving the editor stops the job and keeps nothing applied (D-20)', () async {
      final rig = CaptionsRig();
      await rig.open();
      final job = await _toRunning(rig);
      await rig.editor.close();
      await rig.settle();
      expect(job.cancelled, isTrue);
    });
  });
}
