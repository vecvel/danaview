// OWNER: AI-07

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_whisper/src/runtime/codec.dart';
import 'package:vwish_whisper/src/runtime/vw_bindings.dart';
import 'package:vwish_whisper/vwish_whisper.dart';

import 'fake_vw_bindings.dart';

void main() {
  group('segment JSON (schema 1)', () {
    test('decodes every key, escaping and non-ASCII text', () {
      final doc = '[${segmentJson(i: 7, c: 2, t0: 1200, t1: 3400, text: 'say "hi"\n\\ café 日本 \u{1F600}', nsp: 0.12, lp: -0.35, words: [
            {'t': ' say', 't0': 1200, 't1': 1500, 'p': 0.81},
            {'t': ' "hi"', 't0': 1500, 't1': 2000, 'p': 0.5},
          ])}]';
      final d = decodeSegmentsJson(doc);
      expect(d.count, 1);
      final s = d.segments.single;
      expect(s.index, 7);
      expect(s.chunk, 2);
      expect(s.start, const Duration(milliseconds: 1200));
      expect(s.end, const Duration(milliseconds: 3400));
      expect(s.text, 'say "hi"\n\\ café 日本 \u{1F600}');
      expect(s.noSpeechProb, 0.12);
      expect(s.avgLogProb, -0.35);
      expect(s.words.map((w) => w.text), [' say', ' "hi"']);
      expect(s.words.first.start, const Duration(milliseconds: 1200));
      expect(s.words.first.end, const Duration(milliseconds: 1500));
      expect(s.words.first.probability, 0.81);
    });

    test('unknown keys are ignored and missing optional keys default', () {
      final d = decodeSegmentsJson('[{"t0":0,"t1":10,"text":"a","future":{"x":[1]},"i":3}, {"t0":5,"t1":9}]', firstIndex: 40);
      expect(d.count, 2);
      expect(d.segments[0].index, 3);
      expect(d.segments[0].words, isEmpty);
      expect(d.segments[1].index, 41, reason: 'falls back to the absolute position');
      expect(d.segments[1].text, '');
      expect(d.segments[1].noSpeechProb, 0);
    });

    test('malformed elements are skipped but counted; malformed documents report -1', () {
      final d = decodeSegmentsJson('[1, "x", {"t0":"a","t1":2}, {"t0":5,"t1":2}, null, {"t0":0,"t1":1,"text":"ok","w":[{"t":1},{"t":"w","t0":0,"t1":1,"p":7}]}]');
      expect(d.count, 6);
      expect(d.segments.single.text, 'ok');
      expect(d.segments.single.words.single.probability, 1.0, reason: 'clamped');
      expect(decodeSegmentsJson('[{"t0":').count, -1);
      expect(decodeSegmentsJson('{"t0":1}').count, -1);
      expect(decodeSegmentsJson(null).count, -1);
      expect(decodeSegmentsJson('[]').count, 0);
    });

    test('float times are rounded', () {
      final s = decodeSegmentsJson('[{"t0":1.6,"t1":2.4,"text":"x"}]').segments.single;
      expect(s.start, const Duration(milliseconds: 2));
      expect(s.end, const Duration(milliseconds: 2));
    });
  });

  group('language JSON', () {
    test('decodes candidates best first and the speech start', () {
      final r = decodeLanguageJson('{"lang":[{"code":"de","p":0.1},{"code":"en","p":0.8},{"bad":1}],"speechStartMs":1500}')!;
      expect(r.top.map((l) => l.code), ['en', 'de']);
      expect(r.top.first.p, 0.8);
      expect(r.speechStart, const Duration(milliseconds: 1500));
    });

    test('negative speech start, null and malformed documents', () {
      expect(decodeLanguageJson('{"lang":[],"speechStartMs":-1}')!.speechStart, isNull);
      expect(decodeLanguageJson(null), isNull);
      expect(decodeLanguageJson('nope'), isNull);
      expect(decodeLanguageJson('[1]'), isNull);
    });
  });

  test('every vw_status maps to a typed error kind', () {
    expect(errorKindOf(VwStatus.invalidArg), WhisperErrorKind.internal);
    expect(errorKindOf(VwStatus.modelLoad), WhisperErrorKind.modelLoadFailed);
    expect(errorKindOf(VwStatus.wavFormat), WhisperErrorKind.invalidAudio);
    expect(errorKindOf(VwStatus.io), WhisperErrorKind.io);
    expect(errorKindOf(VwStatus.oom), WhisperErrorKind.outOfMemory);
    expect(errorKindOf(VwStatus.cancelled), WhisperErrorKind.cancelled);
    expect(errorKindOf(VwStatus.inference), WhisperErrorKind.inference);
    expect(errorKindOf(VwStatus.busy), WhisperErrorKind.busy);
    expect(errorKindOf(VwStatus.vadModel), WhisperErrorKind.vadModelMissing);
    expect(errorKindOf(VwStatus.noSpeech), WhisperErrorKind.noSpeech);
    expect(errorKindOf(VwStatus.internal), WhisperErrorKind.internal);
    expect(errorKindOf(1234), WhisperErrorKind.internal);
    expect(exceptionOf(VwStatus.oom, 'job start').detail, 'job start: VW_ERR_OOM');
  });

  test('job state and phase codes', () {
    expect(jobStateOf(VwJobState.running), WhisperJobState.running);
    expect(jobStateOf(VwJobState.paused), WhisperJobState.paused);
    expect(jobStateOf(VwJobState.succeeded), WhisperJobState.succeeded);
    expect(jobStateOf(VwJobState.failed), WhisperJobState.failed);
    expect(jobStateOf(VwJobState.cancelled), WhisperJobState.cancelled);
    expect(jobStateOf(42), WhisperJobState.running);
    expect([0, 1, 2, 3, 9].map(phaseOf), [
      WhisperPhase.preparing,
      WhisperPhase.vad,
      WhisperPhase.encoding,
      WhisperPhase.decoding,
      WhisperPhase.preparing,
    ]);
    final s = statusOf(const VwJobStatusData(state: 1, progressPermille: 1500, processedMs: -5, computeMs: 70, language: 'en'));
    expect(s.fraction, 1.0);
    expect(s.processed, Duration.zero);
    expect(s.computeTime, const Duration(milliseconds: 70));
  });

  group('request mapping', () {
    test('transcribe request -> vw_job_params with the ai.md defaults', () {
      final p = transcribeParamsOf(const WhisperTranscribeRequest(wavPath: '/a.wav', language: 'ja', threads: 12));
      expect(p.mode, VwJobMode.transcribe);
      expect(p.wavPath, '/a.wav');
      expect(p.language, 'ja');
      expect(p.nThreads, 8, reason: 'clamped to 1..8');
      expect(p.rangeStartMs, 0);
      expect(p.rangeEndMs, -1);
      expect(p.chunkTargetMs, 180000);
      expect(p.chunkSearchMs, 15000);
      expect(p.chunkMinMs, 10000);
      expect(p.vadEnabled, isFalse);
      expect(p.vadModelPath, isNull);
      expect(p.tokenTimestamps, isTrue);
      expect(p.noSpeechThold, 0.6);
      expect(p.entropyThold, 2.4);
      expect(p.logprobThold, -1.0);
      expect(p.temperatureInc, 0.2);
      expect(p.beamSize, 1);
      expect(p.bestOf, 5);
      expect(p.suppressNst, isTrue);
      expect(p.carryPromptWords, 24);
      expect(p.initialPrompt, isNull);
    });

    test('ranges, VAD, decoder options and clamps', () {
      final p = transcribeParamsOf(const WhisperTranscribeRequest(
        wavPath: 'w',
        language: 'en',
        threads: 0,
        rangeStart: Duration(seconds: 3),
        rangeEnd: Duration(seconds: 9),
        vad: WhisperVadOptions(modelPath: 'vad.bin', threshold: 0.4, minSpeech: Duration(milliseconds: 200)),
        decode: WhisperDecodeOptions(beamSize: 5, suppressNonSpeech: false, tokenTimestamps: false),
        carryPromptWords: 99,
        initialPrompt: 'Hi.',
      ));
      expect(p.nThreads, 1);
      expect(p.rangeStartMs, 3000);
      expect(p.rangeEndMs, 9000);
      expect(p.vadEnabled, isTrue);
      expect(p.vadModelPath, 'vad.bin');
      expect(p.vadThreshold, 0.4);
      expect(p.vadMinSpeechMs, 200);
      expect(p.vadMinSilenceMs, 300);
      expect(p.vadSpeechPadMs, 100);
      expect(p.vadSamplesOverlapS, 0.1);
      expect(p.beamSize, 5);
      expect(p.suppressNst, isFalse);
      expect(p.tokenTimestamps, isFalse);
      expect(p.carryPromptWords, 40);
      expect(p.initialPrompt, 'Hi.');
    });

    test('detect request -> DETECT mode, language auto', () {
      final p = detectParamsOf(const WhisperDetectRequest(wavPath: 'w', threads: 4, vad: WhisperVadOptions(modelPath: 'v')));
      expect(p.mode, VwJobMode.detectLanguage);
      expect(p.language, 'auto');
      expect(p.detectMaxSpeechMs, 30000);
      expect(p.detectSearchMs, 600000);
      expect(p.vadEnabled, isTrue);
    });

    test('model options; DTW forces flash attention off', () {
      expect(modelParamsOf(const WhisperModelOptions()), const VwModelParams());
      expect(modelParamsOf(const WhisperModelOptions(preferGpu: false, flashAttention: false)),
          const VwModelParams(useGpu: false, flashAttn: false));
      expect(modelParamsOf(const WhisperModelOptions(dtwPreset: WhisperDtwPreset.base)),
          const VwModelParams(flashAttn: false, dtwPreset: 6));
    });
  });

  test('native UTF-8: valid text decodes, invalid UTF-8 asserts (the shim guarantees validity)', () {
    expect(decodeNativeUtf8(utf8.encode('héllo \u{1F600}')), 'héllo \u{1F600}');
    expect(() => decodeNativeUtf8([0x68, 0xff, 0x69]), throwsA(isA<AssertionError>()));
  });
}
