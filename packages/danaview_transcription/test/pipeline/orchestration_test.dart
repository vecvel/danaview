// OWNER: AI-13
//
// TranscriptionServiceImpl orchestration with fakes for every phase (ARCH §16.4, ai.md §16.1):
// phase order and weights, deterministic results for a fixture transcript, language auto
// (confident vs needsLanguage), cache hit and superset reuse, checkpoints and resume, pipeline
// depth 1, model download wait, fresh-timeline mapping and provenance.

import 'dart:io';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart';
import 'package:flutter_test/flutter_test.dart';

import '../timeline/timeline_fixtures.dart';
import 'support/pipeline_fakes.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.create());
  tearDown(() async => h.dispose());

  group('fixed language run', () {
    test('runs the phases in order with rising progress and returns drafts + provenance', () async {
      final (job, samples) = h.start();
      final result = await job.result;

      expect(phasesOf(samples), [
        TranscriptionPhase.preparing,
        TranscriptionPhase.loadingModel,
        TranscriptionPhase.extractingAudio,
        TranscriptionPhase.transcribing,
        TranscriptionPhase.segmenting,
        TranscriptionPhase.done,
      ]);
      final fractions = [for (final s in samples) s.fraction];
      for (var i = 1; i < fractions.length; i++) {
        expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1] - 1e-9), reason: 'progress never goes back ($i)');
      }
      expect(samples.last.fraction, 1);
      expect(samples.last.paused, isNull);

      expect(result.drafts, isNotEmpty);
      expect(result.drafts.map((d) => d.text).join(' ').replaceAll('\n', ' '), 'Welcome to the harbour tour. We start at the lighthouse.');
      expect(result.target, isA<NewTrackTarget>());
      expect(result.summary.language, 'en');
      expect(result.summary.words, 10);
      expect(result.summary.cues, result.drafts.length);

      final p = result.provenance;
      expect(p.generator, 'whisper.cpp');
      expect(p.engineVersion, '1.9.4');
      expect(p.modelId, SpeechModelCatalog.balanced.id);
      expect(p.modelSha256, SpeechModelCatalog.balanced.sha256);
      expect(p.language, 'en');
      expect(p.languageDetected, isFalse);
      expect(p.languageConfidence, isNull);
      expect(p.transcriptKeys, [h.key()]);
      expect(p.segmentation, const SegmentationSettings());
      expect(h.service.activeJob, isNull);
    });

    test('is deterministic for the fixture transcript (same drafts on a fresh service)', () async {
      final first = await h.start().$1.result;
      final other = await Harness.create();
      addTearDown(other.dispose);
      final second = await other.start().$1.result;
      expect(second.drafts.map((d) => (d.range, d.text)).toList(), first.drafts.map((d) => (d.range, d.text)).toList());
      // Cue edges are on the 30 fps grid and inside the clip.
      for (final d in first.drafts) {
        final rate = h.project.settings.frameRate;
        expect(rate.timeOfFrame(rate.frameIndexNearest(d.range.start)), d.range.start);
        expect(d.range.start, greaterThanOrEqualTo(sec(0.9)));
        expect(d.range.end, lessThanOrEqualTo(sec(10)));
      }
    });

    test('passes the request to whisper: language, threads, VAD, suppress_nst, 180 s chunks', () async {
      await h.start(h.request(sounds: true)).$1.result;
      final req = h.runtime.transcribeJobs.single.transcribe!;
      expect(req.language, 'en');
      expect(req.threads, 4);
      expect(req.vad?.modelPath, '/models/vad.bin');
      expect(req.decode.suppressNonSpeech, isFalse);
      expect(req.decode.tokenTimestamps, isTrue);
      // Decode and VAD values come from SpeechTuning (FIX-AI-TUNING).
      expect(req.decode.temperatureInc, SpeechTuning.temperatureIncrement);
      expect(req.decode.noSpeechThreshold, SpeechTuning.noSpeechThreshold);
      expect(req.vad!.threshold, SpeechTuning.vadThreshold);
      expect(req.vad!.minSpeech, const Duration(milliseconds: SpeechTuning.vadMinSpeechMs));
      expect(req.vad!.minSilence, const Duration(milliseconds: SpeechTuning.vadMinSilenceMs));
      expect(req.vad!.speechPad, const Duration(milliseconds: SpeechTuning.vadSpeechPadMs));
      expect(req.vad!.samplesOverlapSeconds, SpeechTuning.vadSamplesOverlapSeconds);
      expect(req.chunkTarget, const Duration(seconds: 180));
      expect(req.chunkSearch, const Duration(seconds: 15));
      expect(req.rangeStart, Duration.zero);
      expect(h.extractor.extractions.single.request.range, TimeRange(0, sec(10.5)));
      expect(h.extractor.extractions.single.request.outputPath, startsWith(h.service.paths.work));
      expect(h.store.used, [SpeechModelCatalog.balanced.id]);
    });

    test('writes the transcript to the cache, deletes the checkpoint, the WAV and the job record', () async {
      await h.start().$1.result;
      final t = await h.service.cache.read(h.key());
      expect(t, isNotNull);
      expect(t!.source.covered, [TimeRange(0, sec(10.5))]);
      expect(t.wordCount, 10);
      expect(t.language.code, 'en');
      expect(await h.service.checkpoints.replay(h.key()), isNull);
      expect(h.extractor.written, hasLength(1));
      expect(File(h.extractor.written.single).existsSync(), isFalse);
      expect(Directory(h.service.paths.workOf('job_1')).existsSync(), isFalse);
      expect(await h.service.resumableFor(h.project.id), isNull);
      expect(h.runtime.models.single.released, isTrue);
    });

    test('maps on a fresh timeline: edits during the job are honoured', () async {
      h.runtime.transcribeScript = (job) async {
        // The user moves the clip by 5 s while transcription runs.
        h.project = oneClipProject(startMs: 5000);
        job.chunk(0, fixtureSegments);
        job.succeed(segments: fixtureSegments);
      };
      final result = await h.start().$1.result;
      expect(result.drafts.first.range.start, greaterThanOrEqualTo(sec(5.9)));
    });

    test('the result becomes one AddGeneratedCaptionTrack / ReplaceGeneratedCaptions command', () async {
      final result = await h.start().$1.result;
      final add = result.toCommand();
      expect(add, isA<AddGeneratedCaptionTrack>());
      expect((add as AddGeneratedCaptionTrack).trackName, 'Captions (English)');
      expect(add.cues, result.drafts);
      expect(add.provenance, result.provenance);
      final replace = TranscriptionResult(
        drafts: result.drafts,
        provenance: result.provenance,
        target: ReplaceInRangeTarget(const TrackId('tr_sub'), TimeRange(0, sec(5))),
        summary: result.summary,
      ).toCommand();
      expect(replace, isA<ReplaceGeneratedCaptions>());
      expect((replace as ReplaceGeneratedCaptions).range, TimeRange(0, sec(5)));
      final whole = TranscriptionResult(drafts: result.drafts, provenance: result.provenance, target: const ReplaceTrackTarget(TrackId('tr_sub')), summary: result.summary)
          .toCommand() as ReplaceGeneratedCaptions;
      expect(whole.range, isNull);
    });
  });

  group('language', () {
    test('auto: confident detection is used and recorded as detected', () async {
      final (job, samples) = h.start(h.request(language: const AutoLanguage()));
      final result = await job.result;
      expect(phasesOf(samples), containsAllInOrder([TranscriptionPhase.loadingModel, TranscriptionPhase.detectingLanguage, TranscriptionPhase.transcribing]));
      expect(result.provenance.languageDetected, isTrue);
      expect(result.provenance.languageConfidence, closeTo(0.97, 1e-9));
      expect(h.runtime.detectJobs.single.detect!.maxSpeech, const Duration(seconds: 30));
      expect(h.runtime.transcribeJobs.single.transcribe!.language, 'en');
    });

    test('auto: low confidence asks with the top 3 and continues with the answer', () async {
      h.runtime.detectScript = (job) => job.succeed(languages: const [
            WhisperLanguageProbability('es', 0.41),
            WhisperLanguageProbability('pt', 0.33),
            WhisperLanguageProbability('gl', 0.11),
            WhisperLanguageProbability('it', 0.05),
          ]);
      final (job, samples) = h.start(h.request(language: const AutoLanguage()));
      await until(() => samples.any((s) => s.phase == TranscriptionPhase.needsLanguage));
      final ask = samples.firstWhere((s) => s.phase == TranscriptionPhase.needsLanguage);
      expect(ask.languageCandidates!.map((c) => c.code), ['es', 'pt', 'gl']);
      job.provideLanguage('xx'); // unknown codes are ignored
      job.provideLanguage('pt');
      final result = await job.result;
      expect(h.runtime.transcribeJobs.single.transcribe!.language, 'pt');
      expect(result.provenance.language, 'pt');
      expect(result.provenance.languageDetected, isFalse);
    });

    test('auto: no speech in the detection unit tries the next unit; none at all fails noSpeech', () async {
      h.project = twoClipProject();
      var calls = 0;
      h.runtime.detectScript = (job) => ++calls == 1 ? job.fail(WhisperErrorKind.noSpeech) : job.succeed(languages: const [WhisperLanguageProbability('de', 0.9)]);
      final r = await h.start(h.request(language: const AutoLanguage())).$1.result;
      expect(calls, 2);
      expect(r.provenance.language, 'de');

      final other = await Harness.create();
      addTearDown(other.dispose);
      other.runtime.detectScript = (job) => job.fail(WhisperErrorKind.noSpeech);
      await expectLater(other.start(other.request(language: const AutoLanguage())).$1.result, throwsA(isA<NoSpeechFailure>()));
    });
  });

  group('cache', () {
    test('a second run of the same request is a cache hit: no model load, no extraction', () async {
      await h.start().$1.result;
      final loads = h.runtime.loadGpu.length;
      final extractions = h.extractor.extractions.length;
      final (job, samples) = h.start();
      final again = await job.result;
      expect(h.runtime.loadGpu.length, loads);
      expect(h.extractor.extractions.length, extractions);
      expect(phasesOf(samples), [TranscriptionPhase.preparing, TranscriptionPhase.segmenting, TranscriptionPhase.done]);
      expect(again.drafts.length, greaterThan(0));
    });

    test('superset reuse: a trimmed clip reuses the wider cached transcript', () async {
      await h.start().$1.result;
      h.project = project([
        mainTrack([clip('c1', 0, 5000, 'm1', sourceInMs: 2000)]),
      ], [
        asset('m1'),
      ]);
      final r = await h.start().$1.result;
      expect(h.runtime.transcribeJobs, hasLength(1));
      expect(r.drafts.map((d) => d.text).join(' '), contains('start'));
    });

    test('another language misses the cache', () async {
      await h.start().$1.result;
      await h.start(h.request(language: const FixedLanguage('de'))).$1.result;
      expect(h.runtime.transcribeJobs, hasLength(2));
    });
  });

  group('checkpoints and resume', () {
    test('every finished chunk is checkpointed while the job runs', () async {
      TranscriptionJob? running;
      h.runtime.transcribeScript = (job) async {
        job.chunk(0, [fixtureSegments.first]);
        job.status(chunksCompleted: 1, processed: const Duration(seconds: 3), fraction: 0.3);
        // The chunk's checkpoint is appended through real file I/O while the job keeps running:
        // wait for the write itself (a whole chunk line), not a fixed number of event-loop turns.
        final replay = await eventually(() async {
          final r = await h.service.checkpoints.replay(h.key());
          return r == null || r.chunks.isEmpty ? null : r;
        });
        expect(replay.chunks.single.segments.single.text, 'Welcome to the harbour tour.');
        running!.cancel();
      };
      running = h.start().$1;
      await expectLater(running.result, throwsA(isA<TranscriptionCancelled>()));
      // Cancel keeps the checkpoint and the job record ("Resume").
      expect(await h.service.checkpoints.replay(h.key()), isNotNull);
      final resumable = await h.service.resumableFor(h.project.id);
      expect(resumable, isNotNull);
      expect(resumable!.jobId, 'job_1');
      expect(Directory(h.service.paths.workOf('job_1')).existsSync(), isFalse, reason: 'WAVs are deleted');
    });

    test('resume continues at the last checkpointed chunk and keeps its segments', () async {
      final unitStart = 0;
      final firstChunk = [TranscriptSegment.fromRaw(fixtureSegments.first, offsetUs: unitStart)];
      await h.service.checkpoints.append(h.key(), CheckpointChunk(index: 0, startUs: 0, endUs: sec(3.5), segments: firstChunk), unitStartUs: unitStart);
      h.runtime.transcribeScript = (job) {
        final rest = [fixtureSegments.last];
        job.chunk(0, rest);
        job.succeed(segments: rest);
      };
      final r = await h.start().$1.result;
      expect(h.runtime.transcribeJobs.single.transcribe!.rangeStart, const Duration(milliseconds: 3500));
      expect(r.drafts.map((d) => d.text).join(' ').replaceAll('\n', ' '), 'Welcome to the harbour tour. We start at the lighthouse.');
      expect(h.logs.where((l) => l.$1 == 'unit.resume'), hasLength(1));
    });

    test('a checkpoint of another range of the same media is discarded', () async {
      await h.service.checkpoints.append(h.key(), CheckpointChunk(index: 0, startUs: sec(30), endUs: sec(40)), unitStartUs: sec(30));
      await h.start().$1.result;
      expect(h.runtime.transcribeJobs.single.transcribe!.rangeStart, Duration.zero);
    });

    test('a resumed auto-language job reuses the recorded language (no second detection)', () async {
      final auto = h.request(language: const AutoLanguage());
      h.runtime.transcribeScript = (job) => job.fail(WhisperErrorKind.inference);
      await expectLater(h.start(auto).$1.result, throwsA(isA<InferenceFailure>()));
      expect(await h.service.resumableFor(h.project.id), isNotNull, reason: 'retryable failures keep the record');
      expect(h.runtime.detectJobs, hasLength(1));

      h.runtime.transcribeScript = (job) => job.succeed(segments: fixtureSegments);
      await h.start(auto).$1.result;
      expect(h.runtime.detectJobs, hasLength(1));
      expect(await h.service.resumableFor(h.project.id), isNull);
    });

    test('a different request of the same project supersedes the old record', () async {
      h.runtime.transcribeScript = (job) => job.fail(WhisperErrorKind.inference);
      await expectLater(h.start().$1.result, throwsA(isA<InferenceFailure>()));
      expect((await h.service.resumableFor(h.project.id))!.jobId, 'job_1');
      h.runtime.transcribeScript = (job) => job.succeed(segments: fixtureSegments);
      await h.start(h.request(language: const FixedLanguage('fr'))).$1.result;
      expect(await h.service.resumableFor(h.project.id), isNull);
    });

    test('discardResumable drops the record and the checkpoints', () async {
      TranscriptionJob? running;
      h.runtime.transcribeScript = (job) async {
        job.chunk(0, [fixtureSegments.first]);
        await settle();
        running!.cancel();
      };
      running = h.start().$1;
      await expectLater(running.result, throwsA(isA<TranscriptionCancelled>()));
      final r = (await h.service.resumableFor(h.project.id))!;
      expect(await h.service.resumableRequest(r.jobId), containsPair('model', SpeechModelCatalog.balanced.id));
      await h.service.discardResumable(r.jobId);
      expect(await h.service.resumableFor(h.project.id), isNull);
      expect(await h.service.checkpoints.replay(h.key()), isNull);
    });
  });

  group('extraction pipeline', () {
    test('depth 1: unit 2 extracts while unit 1 transcribes, never more than one at a time', () async {
      h.project = twoClipProject();
      var extractedDuringFirst = 0;
      h.runtime.transcribeScript = (job) async {
        await settle();
        if (h.runtime.transcribeJobs.length == 1) extractedDuringFirst = h.extractor.extractions.length;
        job.chunk(0, fixtureSegments);
        job.succeed(segments: fixtureSegments);
      };
      final r = await h.start().$1.result;
      expect(extractedDuringFirst, 2);
      expect(h.extractor.maxActive, 1);
      expect(r.provenance.transcriptKeys, [h.key(), h.key(media: 'm2')]);
      expect(r.summary.words, 20);
    });

    test('progress reports unit index and count, total audio and partial text', () async {
      h.project = twoClipProject();
      final (job, samples) = h.start();
      await job.result;
      expect(samples.map((s) => s.unitCount).toSet(), containsAll([2]));
      expect(samples.map((s) => s.unitIndex).toSet(), containsAll([0, 1]));
      expect(samples.last.total, sec(10.5) * 2);
      expect(samples.where((s) => s.partialText != null), isNotEmpty);
      expect(samples.where((s) => (s.partialText ?? '').length > 80), isEmpty);
    });
  });

  group('model', () {
    test('waits for a running (consented) download, then loads', () async {
      h.store.ready.remove(SpeechModelCatalog.balanced.id);
      final download = h.store.beginDownload(SpeechModelCatalog.balanced.id);
      final (job, samples) = h.start();
      await until(() => samples.any((s) => s.phase == TranscriptionPhase.downloadingModel));
      download.controller.add(const ModelDownloadProgress(phase: ModelDownloadPhase.downloading, received: 5, total: 10));
      h.store.finishDownload();
      await job.result;
      expect(phasesOf(samples), containsAllInOrder([TranscriptionPhase.downloadingModel, TranscriptionPhase.loadingModel]));
    });

    test('model missing without a download fails modelMissing', () async {
      h.store.ready.clear();
      await expectLater(h.start().$1.result, throwsA(isA<ModelMissingFailure>()));
    });

    test('a failed download surfaces as its typed failure', () async {
      h.store.ready.remove(SpeechModelCatalog.balanced.id);
      final download = h.store.beginDownload(SpeechModelCatalog.balanced.id);
      final (job, samples) = h.start();
      // Fail the download while the job waits on it (a fixed settle() raced the job's prologue on
      // a slow runner, so the failure landed before the job listened).
      await until(() => samples.any((s) => s.phase == TranscriptionPhase.downloadingModel));
      download.completer.completeError(const ModelDownloadFailure(ModelDownloadFailureKind.offline));
      await expectLater(job.result, throwsA(isA<ModelDownloadFailure>().having((f) => f.kind, 'kind', ModelDownloadFailureKind.offline)));
    });
  });
}
