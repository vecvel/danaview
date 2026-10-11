// OWNER: AI-08

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/testing.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

const _gib = 1024 * 1024 * 1024;
const _project = ProjectId('pr_test00000001');

TranscriptionRequest request({SpokenLanguage language = const FixedLanguage('en'), String? model, TranscriptionScope? scope}) => TranscriptionRequest(
      project: _project,
      scope: scope ?? const TimelineScope(),
      language: language,
      modelId: model ?? SpeechModelCatalog.balanced.id,
      segmentation: const SegmentationSettings(),
      target: const NewTrackTarget(),
      timeline: () => throw UnimplementedError('the fake never reads the timeline'),
    );

// Test-only construction; production call sites are restricted to model_consent_view.dart.
UserConsent consentFor(SpeechModelSpec spec, {bool vad = true}) =>
    UserConsent.accepted(ConsentDisclosure.of(spec, includesVad: vad), acceptedAt: DateTime.utc(2026));

Future<List<TranscriptionPhase>> phasesOf(FakeTranscriptionJob job) async {
  await job.result;
  return job.emitted.map((p) => p.phase).toList();
}

void main() {
  group('scripted jobs drive every phase', () {
    test('the full script visits every TranscriptionPhase once, in pipeline order', () async {
      final service = FakeTranscriptionService(physicalRamBytes: 8 * _gib)..autoPlay = true;
      // needsLanguage waits for the UI: answer it as the UI would.
      service.scriptFor = (r) => FakeJobScripts.fullRun(download: true, detect: true, askLanguage: true);
      final job = service.start(request(language: const AutoLanguage())) as FakeTranscriptionJob;
      job.progress.listen((p) {
        if (p.phase == TranscriptionPhase.needsLanguage) {
          expect(p.languageCandidates, hasLength(3));
          job.provideLanguage('hi');
        }
      });
      final result = await job.result;
      final order = job.emitted.map((p) => p.phase).toList();
      expect(order.toSet(), TranscriptionPhase.values.toSet());
      expect(order.first, TranscriptionPhase.preparing);
      expect(order.last, TranscriptionPhase.done);
      final firstIndex = [for (final p in TranscriptionPhase.values) order.indexOf(p)];
      expect(firstIndex, orderedEquals([...firstIndex]..sort()), reason: 'phases appear in enum order');
      expect(job.providedLanguages, ['hi']);
      expect(result.drafts, isNotEmpty);
      expect(result.summary.cues, result.drafts.length);
    });

    test('progress samples are monotonic and the transcribing phase reports an ETA', () async {
      final service = FakeTranscriptionService()..autoPlay = true;
      final job = service.start(request()) as FakeTranscriptionJob;
      await job.result;
      final fractions = job.emitted.map((p) => p.fraction).toList();
      expect(fractions, orderedEquals([...fractions]..sort()));
      expect(job.emitted.where((p) => p.phase == TranscriptionPhase.transcribing).every((p) => p.eta != null), isTrue);
      expect(job.emitted.firstWhere((p) => p.phase == TranscriptionPhase.preparing).eta, isNull);
    });

    test('the default script detects the language only for AutoLanguage', () async {
      final fixed = FakeTranscriptionService()..autoPlay = true;
      expect(await phasesOf(fixed.start(request()) as FakeTranscriptionJob), isNot(contains(TranscriptionPhase.detectingLanguage)));
      final auto = FakeTranscriptionService()..autoPlay = true;
      expect(await phasesOf(auto.start(request(language: const AutoLanguage())) as FakeTranscriptionJob), contains(TranscriptionPhase.detectingLanguage));
    });

    test('manual driving: emit, pause reason, finish', () async {
      final service = FakeTranscriptionService();
      final job = service.start(request()) as FakeTranscriptionJob;
      final seen = <TranscriptionProgress>[];
      job.progress.listen(seen.add);
      job.emit(const TranscriptionProgress(phase: TranscriptionPhase.transcribing, fraction: 0.3, paused: PauseReason.thermal));
      job.finish(service.sampleResult(request()));
      await job.result;
      await Future<void>.delayed(Duration.zero);
      expect(seen.single.paused, PauseReason.thermal);
      job.emit(const TranscriptionProgress(phase: TranscriptionPhase.done, fraction: 1));
      expect(job.emitted, hasLength(1), reason: 'nothing is emitted after the job ended');
    });

    test('needsLanguage: the job waits for provideLanguage', () async {
      final service = FakeTranscriptionService();
      final job = service.start(request(language: const AutoLanguage())) as FakeTranscriptionJob;
      var answered = false;
      final f = job.waitForLanguage(const [LanguageProbability('hi', 0.5), LanguageProbability('ur', 0.3)]).then((c) {
        answered = true;
        return c;
      });
      await Future<void>.delayed(Duration.zero);
      expect(answered, isFalse);
      expect(job.emitted.single.phase, TranscriptionPhase.needsLanguage);
      job.provideLanguage('ur');
      expect(await f, 'ur');
    });
  });

  group('failures', () {
    test('a scripted failure surfaces on result and ends the job', () async {
      final service = FakeTranscriptionService()
        ..autoPlay = true
        ..scriptFor = (r) => FakeJobScripts.failing(const NoSpeechFailure());
      final job = service.start(request());
      await expectLater(job.result, throwsA(isA<NoSpeechFailure>()));
      expect(service.activeJob, isNull);
    });

    test('startFailure fails every started job asynchronously (never synchronously)', () async {
      final service = FakeTranscriptionService()..startFailure = const ModelMissingFailure();
      final job = service.start(request());
      await expectLater(job.result, throwsA(isA<ModelMissingFailure>()));
    });

    test('every TranscriptionFailure can be scripted', () async {
      for (final f in <TranscriptionFailure>[
        const UnsupportedDeviceFailure('platform'),
        const ModelCorruptFailure(),
        const InsufficientMemoryFailure(suggestedTier: SpeechModelTier.fast),
        const DiskFullFailure(),
        const NoAudioFailure(),
        const AudioDecodeFailure(),
        const InferenceFailure('x'),
      ]) {
        final service = FakeTranscriptionService()
          ..autoPlay = true
          ..scriptFor = (r) => FakeJobScripts.failing(f);
        await expectLater(service.start(request()).result, throwsA(same(f)));
      }
    });

    test('cancel ends the job with TranscriptionCancelled and stops a playing script', () async {
      final service = FakeTranscriptionService()
        ..autoPlay = true
        ..scriptFor = (r) => [const FakeWait(Duration(milliseconds: 50)), ...FakeJobScripts.fullRun()];
      final job = service.start(request()) as FakeTranscriptionJob;
      job.cancel();
      await expectLater(job.result, throwsA(isA<TranscriptionCancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(job.cancelled, isTrue);
      expect(job.emitted, isEmpty);
    });

    test('only one job at a time; the next may start after the first ended', () async {
      final service = FakeTranscriptionService();
      final first = service.start(request()) as FakeTranscriptionJob;
      expect(service.activeJob, same(first));
      expect(() => service.start(request()), throwsStateError);
      first.cancel();
      await first.result.then((_) {}, onError: (_) {});
      expect(service.activeJob, isNull);
      expect(() => service.start(request()), returnsNormally);
    });
  });

  group('model download', () {
    test('scripted progress then ready; status and events follow', () async {
      final service = FakeTranscriptionService()
        ..scriptedDownload = const [
          ModelDownloadProgress(phase: ModelDownloadPhase.preparing, received: 0, total: 100),
          ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: 50, total: 100, bytesPerSecond: 1e6),
          ModelDownloadProgress(phase: ModelDownloadPhase.verifying, received: 100, total: 100),
        ];
      final events = <TranscriptionEvent>[];
      service.events.listen(events.add);
      expect(await service.modelStatus(), isA<SpeechModelMissing>());
      final got = await service.downloadModel(consent: consentFor(SpeechModelCatalog.balanced)).toList();
      expect(got.map((p) => p.phase), [ModelDownloadPhase.preparing, ModelDownloadPhase.downloading, ModelDownloadPhase.verifying]);
      final status = await service.modelStatus();
      expect(status, isA<SpeechModelReady>());
      expect((status as SpeechModelReady).model.spec, SpeechModelCatalog.balanced);
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<ModelStatusChanged>().map((e) => e.status.runtimeType), [
        SpeechModelDownloading, SpeechModelDownloading, SpeechModelDownloading, SpeechModelReady,
      ]);
      expect((await service.preflight(request())).downloadBytes, 0);
    });

    test('a consent that is not the catalog disclosure is refused before any progress', () async {
      final service = FakeTranscriptionService()..scriptedDownload = const [ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: 1, total: 2)];
      final forged = _forged;
      await expectLater(
        service.downloadModel(consent: forged).toList(),
        throwsA(isA<ModelDownloadFailure>().having((f) => f.kind, 'kind', ModelDownloadFailureKind.consentMismatch)),
      );
      expect(await service.modelStatus(), isA<SpeechModelMissing>());
    });

    test('every download failure kind can be scripted and leaves the model missing', () async {
      for (final kind in ModelDownloadFailureKind.values) {
        final service = FakeTranscriptionService()
          ..scriptedDownload = const [ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: 1, total: 2)]
          ..downloadFailure = ModelDownloadFailure(kind);
        await expectLater(
          service.downloadModel(consent: consentFor(SpeechModelCatalog.fast)).toList(),
          throwsA(isA<ModelDownloadFailure>().having((f) => f.kind, 'kind', kind)),
        );
        expect(await service.modelStatusOf(SpeechModelCatalog.fast.id), isA<SpeechModelMissing>());
      }
    });

    test('cancelDownload stops between samples with kind cancelled', () async {
      final service = FakeTranscriptionService()
        ..scriptedDownload = [for (var i = 1; i <= 5; i++) ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: i, total: 5)];
      final seen = <int>[];
      final done = Completer<Object?>();
      service.downloadModel(consent: consentFor(SpeechModelCatalog.balanced)).listen(
        (p) {
          seen.add(p.received);
          if (p.received == 2) unawaited(service.cancelDownload());
        },
        onError: (Object e) => done.complete(e),
        onDone: () {
          if (!done.isCompleted) done.complete(null);
        },
      );
      final error = await done.future;
      expect(error, isA<ModelDownloadFailure>().having((f) => f.kind, 'kind', ModelDownloadFailureKind.cancelled));
      expect(seen, [1, 2]);
      expect(await service.modelStatus(), isA<SpeechModelMissing>());
    });

    test('delete clears the status, asks for consent again, and is blocked while a job runs', () async {
      final service = FakeTranscriptionService();
      await service.downloadModel(consent: consentFor(SpeechModelCatalog.balanced)).toList();
      final job = service.start(request());
      await expectLater(service.deleteModel(), throwsStateError);
      await expectLater(service.deleteModelById(SpeechModelCatalog.balanced.id), throwsStateError);
      job.cancel();
      await job.result.then((_) {}, onError: (_) {});
      await service.deleteModelById(SpeechModelCatalog.balanced.id);
      expect(await service.modelStatus(), isA<SpeechModelMissing>());
      expect((await service.preflight(request())).downloadBytes, SpeechModelCatalog.balanced.bytes + SpeechModelCatalog.vad.bytes);
    });
  });

  group('device gating', () {
    test('offers follow RAM: Accurate hidden below 4 GB, recommended Balanced', () async {
      final mid = FakeTranscriptionService(physicalRamBytes: 3 * _gib);
      expect(mid.offers.map((o) => o.available), [true, true, false]);
      expect(mid.offers.singleWhere((o) => o.recommended).spec, SpeechModelCatalog.balanced);
      expect(mid.offers.last.unavailableReason, isNotNull);
      expect(mid.defaultModel, SpeechModelCatalog.balanced);
      final high = FakeTranscriptionService();
      expect(high.offers.map((o) => o.available), [true, true, true]);
      final small = FakeTranscriptionService(physicalRamBytes: 2 * _gib);
      expect(small.offers.map((o) => o.available), [true, false, false]);
      expect(small.defaultModel, SpeechModelCatalog.fast);
      expect(((await small.support()) as TranscriptionSupported).tiers, [SpeechModelTier.fast]);
    });

    test('unsupported devices fail preflight', () async {
      final service = FakeTranscriptionService(supportState: const TranscriptionUnsupported('abi'));
      final p = await service.preflight(request());
      expect(p.ok, isFalse);
      expect(p.failure, isA<UnsupportedDeviceFailure>());
    });

    test('a tier the device cannot hold fails preflight with a smaller suggestion', () async {
      final service = FakeTranscriptionService(physicalRamBytes: 3 * _gib);
      final p = await service.preflight(request(model: SpeechModelCatalog.accurate.id));
      expect(p.ok, isFalse);
      expect((p.failure as InsufficientMemoryFailure).suggestedTier, SpeechModelTier.fast);
    });

    test('preflightOverride wins', () async {
      final service = FakeTranscriptionService()..preflightOverride = const TranscriptionPreflight(ok: false, failure: DiskFullFailure());
      expect((await service.preflight(request())).failure, isA<DiskFullFailure>());
    });
  });

  group('resumable jobs', () {
    test('an interrupted job leaves a resumable record; the next start continues from it and clears it', () async {
      var now = DateTime.utc(2026, 10, 8);
      final service = FakeTranscriptionService(clock: () => now);
      final job = service.start(request()) as FakeTranscriptionJob;
      service.interrupt(job, doneFraction: 0.6);
      await expectLater(job.result, throwsA(isA<TranscriptionInterrupted>()));
      final r = await service.resumableFor(_project);
      expect(r!.doneFraction, 0.6);
      expect(r.jobId, job.id);
      expect(await service.resumableFor(const ProjectId('pr_other0000001')), isNull);

      now = now.add(const Duration(days: 2));
      final resumed = service.start(request()) as FakeTranscriptionJob;
      expect(resumed.resumedFromFraction, 0.6);
      resumed.finish(service.sampleResult(request()));
      await resumed.result;
      await Future<void>.delayed(Duration.zero);
      expect(await service.resumableFor(_project), isNull);
    });

    test('records expire after 7 days', () async {
      var now = DateTime.utc(2026, 10, 8);
      final service = FakeTranscriptionService(clock: () => now);
      service.resumable[_project] = ResumableTranscription(jobId: 'tj-x', project: _project, doneFraction: 0.2, createdAt: now);
      now = now.add(const Duration(days: 7));
      expect(await service.resumableFor(_project), isNotNull);
      now = now.add(const Duration(seconds: 1));
      expect(await service.resumableFor(_project), isNull);
      expect(service.resumable, isEmpty);
    });
  });

  group('results, events, resegment, storage', () {
    test('sampleResult carries provenance of the request', () {
      final service = FakeTranscriptionService(clock: () => DateTime.utc(2026, 10, 8, 9));
      final r = service.sampleResult(request(language: const AutoLanguage(), model: SpeechModelCatalog.fast.id, scope: const ClipScope(ItemId('it_clipA0000001'))));
      expect(r.provenance.generator, 'whisper.cpp');
      expect(r.provenance.engineVersion, '1.9.4');
      expect(r.provenance.modelId, SpeechModelCatalog.fast.id);
      expect(r.provenance.modelSha256, SpeechModelCatalog.fast.sha256);
      expect(r.provenance.languageDetected, isTrue);
      expect(r.provenance.language, 'en');
      expect(r.provenance.scope.clips, [const ItemId('it_clipA0000001')]);
      expect(r.provenance.generatedAt, DateTime.utc(2026, 10, 8, 9));
      expect(r.target, isA<NewTrackTarget>());
      for (final d in r.drafts) {
        expect(d.range.duration, greaterThan(0));
      }
      final fixed = service.sampleResult(request(language: const FixedLanguage('jw')));
      expect(fixed.provenance.language, 'jv', reason: 'BCP-47, not the whisper code');
      expect(fixed.provenance.languageDetected, isFalse);
      expect(fixed.provenance.languageConfidence, isNull);
    });

    test('job events: started then ended', () async {
      final service = FakeTranscriptionService()..autoPlay = true;
      final events = <TranscriptionEvent>[];
      service.events.listen(events.add);
      final job = service.start(request());
      await job.result;
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<JobStarted>().single.job, same(job));
      expect(events.whereType<JobEnded>().single.jobId, job.id);
    });

    test('resegment returns the scripted drafts and records the call', () async {
      final service = FakeTranscriptionService();
      final r = service.sampleResult(request());
      service.resegmentDrafts = r.drafts;
      const settings = SegmentationSettings(preset: SegmentationPreset.singleLine);
      final drafts = await service.resegment(r.provenance, settings, _NoTimeline());
      expect(drafts, r.drafts);
      expect(service.resegmentCalls.single.$2, settings);
    });

    test('storage sums installed models and the extra bytes', () async {
      final service = FakeTranscriptionService()..extraStorage = const SpeechStorageUsage(transcriptBytes: 10, partialBytes: 5);
      await service.downloadModel(consent: consentFor(SpeechModelCatalog.fast)).toList();
      final s = await service.storage();
      expect(s.modelBytes, SpeechModelCatalog.fast.bytes);
      expect(s.transcriptBytes, 10);
      expect(s.partialBytes, 5);
    });

    test('languages are the 99 whisper languages', () {
      expect(FakeTranscriptionService().languages, hasLength(99));
    });
  });
}

final _forged = UserConsent.accepted(
  ConsentDisclosure.forTesting(
    modelId: 'whisper-base-q5_1',
    fileName: 'ggml-base-q5_1.bin',
    host: 'huggingface.co',
    cdnHost: 'hf.co',
    sha256: 'f' * 64,
    totalBytes: 60592723,
    includesVad: true,
  ),
  acceptedAt: DateTime.utc(2026),
);

final class _NoTimeline implements TimelineView {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
