// OWNER: AI-13
//
// Cancel at every phase (WAVs cleaned, checkpoint and record kept), export waiting and pausing,
// iOS background pause/resume, Android background lease, thermal and low-power reactions.

import 'dart:async';
import 'dart:io';

import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pipeline_fakes.dart';

void main() {
  group('cancel at each phase', () {
    late Harness h;
    setUp(() async => h = await Harness.create());
    tearDown(() async => h.dispose());

    Future<void> expectCancelled(TranscriptionJob job) async {
      await expectLater(job.result, throwsA(isA<TranscriptionCancelled>()));
      expect(h.service.activeJob, isNull);
      expect(Directory(h.service.paths.workOf(job.id)).existsSync(), isFalse);
    }

    test('preparing (before the first step)', () async {
      final job = h.start().$1..cancel();
      await expectCancelled(job);
      expect(h.runtime.loadGpu, isEmpty);
    });

    test('waiting for a model download (the download itself goes on)', () async {
      h.store.ready.remove(SpeechModelCatalog.balanced.id);
      final download = h.store.beginDownload(SpeechModelCatalog.balanced.id);
      final (job, samples) = h.start();
      await until(() => samples.any((s) => s.phase == TranscriptionPhase.downloadingModel));
      job.cancel();
      await expectCancelled(job);
      expect(download.cancelled, isFalse);
    });

    test('loading the model (a late model is released)', () async {
      final gate = h.runtime.loadGate = Completer<void>();
      final (job, samples) = h.start();
      await until(() => samples.any((s) => s.phase == TranscriptionPhase.loadingModel));
      job.cancel();
      await expectCancelled(job);
      gate.complete();
      await until(() => h.runtime.models.isNotEmpty && h.runtime.models.single.released);
    });

    test('extracting audio (the extraction is cancelled)', () async {
      h.extractor.hold = true;
      final (job, _) = h.start();
      await until(() => h.extractor.extractions.isNotEmpty);
      job.cancel();
      await expectCancelled(job);
      expect(h.extractor.extractions.single.cancelled, isTrue);
      expect(h.runtime.transcribeJobs, isEmpty);
    });

    test('detecting the language (the native job is cancelled)', () async {
      h.runtime.detectScript = (_) {};
      final (job, _) = h.start(h.request(language: const AutoLanguage()));
      await until(() => h.runtime.detectJobs.isNotEmpty);
      job.cancel();
      await expectCancelled(job);
      expect(h.runtime.detectJobs.single.cancelled, isTrue);
    });

    test('waiting for the language answer', () async {
      h.runtime.detectScript = (j) => j.succeed(languages: const [WhisperLanguageProbability('es', 0.3)]);
      final (job, samples) = h.start(h.request(language: const AutoLanguage()));
      await until(() => samples.any((s) => s.phase == TranscriptionPhase.needsLanguage));
      job.cancel();
      await expectCancelled(job);
    });

    test('transcribing (native job cancelled, checkpoint and record kept)', () async {
      h.runtime.transcribeScript = (j) => j.chunk(0, [fixtureSegments.first]);
      final (job, _) = h.start();
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      await settle();
      job.cancel();
      await expectCancelled(job);
      expect(h.runtime.transcribeJobs.single.cancelled, isTrue);
      expect(await h.service.checkpoints.replay(h.key()), isNotNull);
      expect(await h.service.resumableFor(h.project.id), isNotNull);
      expect(h.runtime.models.single.released, isTrue);
    });

    test('leaving the editor cancels the running job', () async {
      h.runtime.transcribeScript = (_) {};
      final (job, _) = h.start();
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      h.service.onEditorClosed();
      await expectCancelled(job);
    });

    test('cancel after the end is a no-op', () async {
      final job = h.start().$1;
      await job.result;
      job.cancel();
      expect(await job.result, isA<TranscriptionResult>());
    });
  });

  group('export interplay', () {
    late Harness h;
    setUp(() async => h = await Harness.create());
    tearDown(() async => h.dispose());

    test('waits while an export runs (waitingForExport), then starts', () async {
      h.exports.set(true);
      final (job, samples) = h.start();
      await until(() => samples.any((s) => s.paused == PauseReason.waitingForExport));
      await settle();
      expect(h.runtime.loadGpu, isEmpty);
      h.exports.set(false);
      await job.result;
      expect(samples.last.paused, isNull);
    });

    test('an export starting mid-job pauses at a chunk boundary and resumes after', () async {
      late FakeWhisperJob native;
      h.runtime.transcribeScript = (j) => native = j;
      final (job, samples) = h.start();
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      await settle();
      h.exports.set(true);
      expect(native.calls, contains('pause'));
      expect(samples.last.paused, PauseReason.exportRunning);
      expect(samples.last.eta, isNull, reason: 'no ETA while paused');
      h.exports.set(false);
      expect(native.calls.last, 'resume');
      native.chunk(0, fixtureSegments);
      native.succeed(segments: fixtureSegments);
      await job.result;
    });
  });

  group('app lifecycle', () {
    test('iOS: background pauses at once (abort chunk), foreground resumes', () async {
      final h = await Harness.create(profile: iosProfile(), platform: SpeechPlatform.ios);
      addTearDown(h.dispose);
      late FakeWhisperJob native;
      h.runtime.transcribeScript = (j) => native = j;
      final (job, samples) = h.start();
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      await settle();
      h.device.emit(const AppStateChanged(WhisperAppState.background));
      expect(native.calls, contains('pause(abort)'));
      expect(samples.last.paused, PauseReason.background);
      h.device.emit(const AppStateChanged(WhisperAppState.foreground));
      expect(native.calls.last, 'resume');
      native.succeed(segments: fixtureSegments);
      await job.result;
      expect(h.leases.leases, isEmpty, reason: 'iOS pauses instead of holding a lease');
    });

    test('iOS: a job started in the background waits for the foreground', () async {
      final h = await Harness.create(profile: iosProfile(), platform: SpeechPlatform.ios);
      addTearDown(h.dispose);
      h.device.emit(const AppStateChanged(WhisperAppState.background));
      final (job, samples) = h.start();
      await until(() => samples.any((s) => s.paused == PauseReason.background));
      h.device.emit(const AppStateChanged(WhisperAppState.foreground));
      await job.result;
    });

    test('Android: keeps running in the background under a lease released at the end', () async {
      final h = await Harness.create(platform: SpeechPlatform.android);
      addTearDown(h.dispose);
      late FakeWhisperJob native;
      h.runtime.transcribeScript = (j) => native = j;
      final (job, _) = h.start();
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      await settle();
      h.device.emit(const AppStateChanged(WhisperAppState.background));
      expect(native.calls.where((c) => c.startsWith('pause')), isEmpty);
      native.succeed(segments: fixtureSegments);
      await job.result;
      expect(h.leases.titles, ['Creating captions']);
      expect(h.leases.leases.single.released, isTrue);
    });
  });

  group('thermal and power', () {
    late Harness h;
    setUp(() async => h = await Harness.create(platform: SpeechPlatform.android));
    tearDown(() async => h.dispose());

    test('serious halves the threads and cools down 2 s between chunks', () async {
      late FakeWhisperJob native;
      h.runtime.transcribeScript = (j) => native = j;
      final (job, _) = h.start();
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      await settle();
      h.device.emit(const ThermalChanged(ThermalLevel.serious));
      expect(native.threadsSet, 2);
      native.chunk(0, [fixtureSegments.first]);
      expect(h.delays, contains(const Duration(seconds: 2)));
      await settle();
      expect(native.calls, containsAllInOrder(['threads=2', 'pause', 'resume']));
      native.succeed(segments: fixtureSegments);
      await job.result;
    });

    test('critical pauses; resumes only after 10 s at serious or cooler', () async {
      late FakeWhisperJob native;
      h.runtime.transcribeScript = (j) => native = j;
      final (job, samples) = h.start();
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      await settle();
      h.device.emit(const ThermalChanged(ThermalLevel.critical));
      expect(native.calls, contains('pause'));
      expect(samples.last.paused, PauseReason.thermal);
      h.device.emit(const ThermalChanged(ThermalLevel.fair));
      expect(native.calls.last, isNot('resume'));
      expect(h.timers.pending.single.$1, const Duration(seconds: 10));
      h.timers.fireAll();
      expect(native.calls.last, 'resume');
      native.succeed(segments: fixtureSegments);
      await job.result;
    });

    test('low power uses one thread less', () async {
      late FakeWhisperJob native;
      h.runtime.transcribeScript = (j) => native = j;
      final (job, _) = h.start();
      await until(() => h.runtime.transcribeJobs.isNotEmpty);
      await settle();
      h.device.emit(const LowPowerChanged(true));
      expect(native.threadsSet, 3);
      native.succeed(segments: fixtureSegments);
      await job.result;
    });
  });
}
