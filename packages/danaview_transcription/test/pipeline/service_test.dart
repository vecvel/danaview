// OWNER: AI-13
//
// TranscriptionServiceImpl surface (D-21): offers and support by RAM and ABI, preflight (model
// present, memory >= 1.3 x peak, free space, estimate), one job at a time, delete blocked while a
// job runs, events, storage, downloads, re-split from cached transcripts, memory warnings and the
// startup sweep.

import 'dart:async';
import 'dart:io';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pipeline_fakes.dart';

void main() {
  group('offers and support', () {
    Future<Harness> on(WhisperDeviceProfile profile) async {
      final h = await Harness.create(profile: profile);
      addTearDown(h.dispose);
      return h;
    }

    List<SpeechModelTier> available(Harness h) => [for (final o in h.service.offers) if (o.available) o.spec.tier];
    SpeechModelTier recommended(Harness h) => h.service.offers.singleWhere((o) => o.recommended).spec.tier;

    test('6 GB: every tier, Balanced recommended', () async {
      final h = await on(androidProfile());
      expect(available(h), SpeechModelTier.values);
      expect(recommended(h), SpeechModelTier.balanced);
      expect(h.service.defaultModel, SpeechModelCatalog.balanced);
      expect(await h.service.support(), isA<TranscriptionSupported>());
    });

    test('3 GB phone (2.8 GiB reported): Accurate hidden with a reason', () async {
      final h = await on(androidProfile(ram: (2.8 * gib).round()));
      expect(available(h), [SpeechModelTier.fast, SpeechModelTier.balanced]);
      final accurate = h.service.offers.last;
      expect(accurate.available, isFalse);
      expect(accurate.unavailableReason, isNotNull);
    });

    test('2 GB phone: Fast only and recommended; low-RAM devices: Fast', () async {
      final h = await on(androidProfile(ram: (1.9 * gib).round()));
      expect(available(h), [SpeechModelTier.fast]);
      expect(recommended(h), SpeechModelTier.fast);
      expect(h.service.defaultModel, SpeechModelCatalog.fast);
      final low = await on(androidProfile(lowRam: true));
      expect(available(low), [SpeechModelTier.fast]);
    });

    test('32-bit process: unsupported(abi); unknown RAM offers Fast and Balanced', () async {
      final h = await on(androidProfile(is64: false));
      expect((await h.service.support() as TranscriptionUnsupported).reason, 'abi');
      final unknown = await on(const WhisperDeviceProfile());
      expect(available(unknown), [SpeechModelTier.fast, SpeechModelTier.balanced]);
      expect(recommended(unknown), SpeechModelTier.balanced);
    });

    test('runtime unsupported (desktop) -> unsupported(platform)', () async {
      final h = await Harness.create(runtime: FakeWhisperRuntime(support: const WhisperUnsupported(WhisperUnsupportedReason.platform)));
      addTearDown(h.dispose);
      expect((await h.service.support() as TranscriptionUnsupported).reason, 'platform');
      final pre = await h.service.preflight(h.request());
      expect(pre.ok, isFalse);
      expect(pre.failure, isA<UnsupportedDeviceFailure>());
    });

    test('languages are the 99 whisper languages', () async {
      final h = await on(androidProfile());
      expect(h.service.languages, hasLength(99));
    });
  });

  group('preflight', () {
    test('ok with an estimate when the model is installed', () async {
      final h = await Harness.create(memory: 2 * gib, freeDisk: 10 * gib);
      addTearDown(h.dispose);
      final pre = await h.service.preflight(h.request());
      expect(pre.ok, isTrue);
      expect(pre.downloadBytes, 0);
      expect(pre.estimatedDuration, greaterThan(Duration.zero));
    });

    test('missing model: bytes to download include the VAD model', () async {
      final h = await Harness.create(store: FakeModelStore(ready: {}));
      addTearDown(h.dispose);
      final pre = await h.service.preflight(h.request());
      expect(pre.ok, isTrue);
      expect(pre.downloadBytes, SpeechModelCatalog.balanced.bytes + SpeechModelCatalog.vad.bytes);
    });

    test('memory below 1.3 x the tier peak -> insufficientMemory suggesting Fast', () async {
      final h = await Harness.create(memory: 350 * mib);
      addTearDown(h.dispose);
      final pre = await h.service.preflight(h.request());
      expect(pre.ok, isFalse);
      expect((pre.failure! as InsufficientMemoryFailure).suggestedTier, SpeechModelTier.fast);
      final enough = await Harness.create(memory: 390 * mib);
      addTearDown(enough.dispose);
      expect((await enough.service.preflight(enough.request())).ok, isTrue);
    });

    test('a tier the device does not offer -> insufficientMemory', () async {
      final h = await Harness.create(profile: androidProfile(ram: (2.8 * gib).round()));
      addTearDown(h.dispose);
      final pre = await h.service.preflight(h.request(modelId: SpeechModelCatalog.accurate.id));
      expect(pre.failure, isA<InsufficientMemoryFailure>());
      expect((pre.failure! as InsufficientMemoryFailure).suggestedTier, SpeechModelTier.balanced);
    });

    test('not enough free space for WAVs + 64 MiB -> diskFull', () async {
      final h = await Harness.create(freeDisk: 64 * mib);
      addTearDown(h.dispose);
      final pre = await h.service.preflight(h.request());
      expect(pre.failure, isA<DiskFullFailure>());
    });

    test('no audio in scope -> noAudio; unknown model -> modelMissing', () async {
      final h = await Harness.create();
      addTearDown(h.dispose);
      expect((await h.service.preflight(h.request(scope: const ClipScope(ItemId('x'))))).failure, isA<NoAudioFailure>());
      expect((await h.service.preflight(h.request(modelId: 'x'))).failure, isA<ModelMissingFailure>());
    });

    test('cached units need no time', () async {
      final h = await Harness.create();
      addTearDown(h.dispose);
      await h.start().$1.result;
      final pre = await h.service.preflight(h.request());
      expect(pre.estimatedDuration, Duration.zero);
    });
  });

  group('jobs', () {
    late Harness h;
    setUp(() async => h = await Harness.create());
    tearDown(() async => h.dispose());

    test('one job at a time; delete blocked while it runs; events', () async {
      final events = <TranscriptionEvent>[];
      h.service.events.listen(events.add);
      h.runtime.transcribeScript = (_) {};
      final (job, _) = h.start();
      expect(h.service.activeJob, same(job));
      expect(() => h.service.start(h.request()), throwsStateError);
      await expectLater(h.service.deleteModel(), throwsStateError);
      await expectLater(h.service.deleteModelById(SpeechModelCatalog.balanced.id), throwsStateError);
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      final native = h.runtime.transcribeJobs.single;
      native.succeed(segments: fixtureSegments);
      await job.result;
      await settle();
      expect(h.service.activeJob, isNull);
      expect(events.whereType<JobStarted>().single.job, same(job));
      expect(events.whereType<JobEnded>().single.jobId, job.id);

      await h.service.deleteModelById(SpeechModelCatalog.balanced.id);
      expect(h.store.deleted, [SpeechModelCatalog.balanced.id]);
      await settle();
      expect(events.whereType<ModelStatusChanged>(), isNotEmpty);
      await h.service.deleteModel();
      expect(h.store.deleted.last, '*');
    });

    test('resumableFor ignores the running job', () async {
      h.runtime.transcribeScript = (_) {};
      final (job, _) = h.start();
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      expect(await h.service.resumableFor(h.project.id), isNull);
      job.cancel();
      await expectLater(job.result, throwsA(isA<TranscriptionCancelled>()));
      final r = await h.service.resumableFor(h.project.id);
      expect(r!.jobId, job.id);
      expect(r.doneFraction, 0);
      expect(await h.service.resumableFor(const ProjectId('pr_other0000000')), isNull);
    });

    test('resumableFor counts the checkpointed range of the unit in progress (FIX-QA07-D5)', () async {
      h.runtime.transcribeScript = (j) {
        j.status(fraction: 0.4, chunksCompleted: 1, processed: const Duration(seconds: 4));
        j.chunk(0, [fixtureSegments.first]);
      };
      final (job, _) = h.start();
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      await settle();
      job.cancel();
      await expectLater(job.result, throwsA(isA<TranscriptionCancelled>()));

      final unit = (await h.service.records.read(job.id))!.units.single;
      expect(unit.state, isNot(JobUnitState.done));
      final replay = (await h.service.checkpoints.replay(unit.transcriptKey))!;
      final duration = unit.sourceRange.end - unit.sourceRange.start;
      final expected = (replay.resumeFromUs - unit.sourceRange.start) / duration;
      expect(expected, greaterThan(0.3));

      final r = (await h.service.resumableFor(h.project.id))!;
      expect(r.doneFraction, closeTo(expected, 1e-9));
      expect((r.doneFraction * 100).round(), greaterThan(0), reason: 'the notice shows a percent, not 0 %');
    });

    test('resumableFor ignores a checkpoint of another range and weights finished units by duration', () async {
      h.project = twoClipProject();
      h.runtime.transcribeScript = (j) {
        if (h.runtime.transcribeJobs.length == 1) {
          j.chunk(0, fixtureSegments);
          j.status(fraction: 1, chunksCompleted: 1, processed: const Duration(seconds: 10));
          j.succeed(segments: fixtureSegments);
        }
      };
      final (job, _) = h.start();
      await until(() => h.runtime.transcribeJobs.length == 2);
      await settle();
      job.cancel();
      await expectLater(job.result, throwsA(isA<TranscriptionCancelled>()));

      final units = (await h.service.records.read(job.id))!.units;
      expect(units.first.state, JobUnitState.done);
      int len(JobUnitRecord u) => u.sourceRange.end - u.sourceRange.start;
      final r = (await h.service.resumableFor(h.project.id))!;
      expect(r.doneFraction, closeTo(len(units.first) / (len(units.first) + len(units.last)), 1e-9));

      // A checkpoint whose header names another unit start does not count.
      await h.service.checkpoints.append(units.last.transcriptKey,
          CheckpointChunk(index: 0, startUs: units.last.sourceRange.start + 999999, endUs: units.last.sourceRange.end),
          unitStartUs: units.last.sourceRange.start + 999999);
      final again = (await h.service.resumableFor(h.project.id))!;
      expect(again.doneFraction, closeTo(r.doneFraction, 1e-9));
    });

    test('a memory warning releases idle models now, or after the running job', () async {
      h.device.emit(const MemoryWarning());
      await settle();
      expect(h.runtime.releaseIdleCalls, 0, reason: 'nothing to release before the runtime is opened');
      await h.service.support();
      h.device.emit(const MemoryWarning());
      await settle();
      expect(h.runtime.releaseIdleCalls, 1);
      h.runtime.transcribeScript = (_) {};
      final (job, _) = h.start();
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      h.device.emit(const MemoryWarning());
      await settle();
      expect(h.runtime.releaseIdleCalls, 1);
      h.runtime.transcribeJobs.single.succeed(segments: fixtureSegments);
      await job.result;
      await settle();
      expect(h.runtime.releaseIdleCalls, 2);
    });
  });

  group('downloads', () {
    test('downloadModel forwards progress and closes; failures are typed; cancelDownload', () async {
      final h = await Harness.create(store: FakeModelStore(ready: {}));
      addTearDown(h.dispose);
      final consent = UserConsent.accepted(ConsentDisclosure.of(SpeechModelCatalog.fast, includesVad: true), acceptedAt: DateTime.utc(2026));
      final samples = <ModelDownloadProgress>[];
      final done = Completer<void>();
      h.service.downloadModel(consent: consent).listen(samples.add, onDone: done.complete);
      await settle();
      h.store.download_!.controller.add(const ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: 1, total: 2));
      h.store.finishDownload();
      await done.future;
      expect(samples, hasLength(1));
      expect(h.store.consents.single, same(consent));

      Object? error;
      final failed = Completer<void>();
      h.service.downloadModel(consent: consent).listen((_) {}, onError: (Object e) => error = e, onDone: failed.complete);
      await settle();
      await h.service.cancelDownload();
      await failed.future;
      expect(error, isA<ModelDownloadFailure>().having((f) => f.kind, 'kind', ModelDownloadFailureKind.cancelled));
    });

    test('modelStatus reflects the store', () async {
      final h = await Harness.create(store: FakeModelStore(ready: {}));
      addTearDown(h.dispose);
      expect(await h.service.modelStatus(), isA<SpeechModelMissing>());
      h.store.ready.add(SpeechModelCatalog.balanced.id);
      expect(await h.service.modelStatusOf(SpeechModelCatalog.balanced.id), isA<SpeechModelReady>());
    });
  });

  group('re-split', () {
    late Harness h;
    setUp(() async => h = await Harness.create());
    tearDown(() async => h.dispose());

    test('resegment re-splits cached transcripts with new settings, without whisper', () async {
      final r = await h.start().$1.result;
      final jobs = h.runtime.jobs.length;
      final single = await h.service.resegment(r.provenance, const SegmentationSettings(preset: SegmentationPreset.singleLine), h.view());
      expect(h.runtime.jobs.length, jobs);
      expect(single, isNotEmpty);
      expect(single.every((d) => !d.text.contains('\n')), isTrue);
      final same = await h.service.resegment(r.provenance, r.provenance.segmentation, h.view());
      expect(same.map((d) => (d.range, d.text)), r.drafts.map((d) => (d.range, d.text)));
    });

    test('an evicted transcript -> CachedTranscriptsMissing (fall back to Transcribe again)', () async {
      final r = await h.start().$1.result;
      await h.service.cache.delete(h.key());
      await expectLater(
        h.service.resegment(r.provenance, const SegmentationSettings(), h.view()),
        throwsA(isA<CachedTranscriptsMissing>().having((e) => e.units, 'units', 1)),
      );
    });
  });

  group('storage and startup', () {
    test('storage sums models, transcripts and partial files', () async {
      final h = await Harness.create();
      addTearDown(h.dispose);
      await h.start().$1.result;
      await h.service.checkpoints.append(h.key(media: 'm9'), CheckpointChunk(index: 0, startUs: 0, endUs: 1), unitStartUs: 0);
      final s = await h.service.storage();
      expect(s.modelBytes, 900);
      expect(s.transcriptBytes, greaterThan(0));
      expect(s.partialBytes, greaterThan(100));
    });

    test('initialize sweeps work folders older than 24 h', () async {
      final h = await Harness.create();
      addTearDown(h.dispose);
      final stale = Directory(h.service.paths.workOf('job_old'));
      await stale.create(recursive: true);
      await File('${stale.path}/u0.wav').writeAsBytes([1]);
      final fresh = TranscriptionServiceImpl(
        supportDirectory: h.dir.path,
        store: h.store,
        extractor: h.extractor,
        governor: h.governor,
        openRuntime: () async => h.runtime,
        clock: () => DateTime.now().add(const Duration(days: 2)),
        log: (_, __) {},
      );
      await fresh.initialize();
      expect(stale.existsSync(), isFalse);
      await fresh.dispose();
    });
  });
}
