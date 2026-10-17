// OWNER: QA-06
//
// Runner output parsing, shim segment decoding, the app pipeline view (normalizer + segmenter) and
// the decode arguments (tool/eval/src/runner.dart).

import 'dart:convert';

import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:flutter_test/flutter_test.dart';

import '../src/runner.dart';

const _fixtureOutput = '{"abi":1,"engine":"1.9.4","model":{"loadMs":24,"gpu":0,"gpuFallback":0,"type":0,"ftype":1,'
    '"multilingual":1},"job":{"state":"succeeded","error":0,"timedOut":false,"wallMs":73,"computeMs":66,'
    '"processedMs":11000,"chunks":1,"threads":4,"language":"en","languageP":0.0},"peakRssBytes":41549824,'
    '"segments":[{"i":0,"c":0,"t0":0,"t1":1980,"text":"hello world","nsp":0,"lp":0,"w":[{"t":"hello","t0":340,'
    '"t1":980,"p":1},{"t":" world","t0":1020,"t1":1970,"p":1}]},{"bad":true},{"i":2,"c":0,"t0":5,"t1":1}]}';

Map<String, Object?> _seg(int t0, int t1, List<(String, int, int)> words, {double nsp = 0.01, double lp = -0.2}) => {
      't0': t0,
      't1': t1,
      'text': words.map((w) => w.$1).join(' '),
      'nsp': nsp,
      'lp': lp,
      'w': [for (final w in words) {'t': w.$1, 't0': w.$2, 't1': w.$3, 'p': 0.9}],
    };

void main() {
  test('parses a finished runner document and skips malformed segments', () {
    final out = RunnerOutput.parse(_fixtureOutput, 0);
    expect(out.finished, isTrue);
    expect(out.engine, '1.9.4');
    expect(out.loadMs, 24);
    expect(out.computeMs, 66);
    expect(out.peakRssBytes, 41549824);
    expect(out.segments, hasLength(1));
    expect(out.segments.single.words.map((w) => w.text), ['hello', 'world']);
    expect(out.segments.single.words.last.startUs, 1020000);
  });

  test('NO_SPEECH is a finished job; load failures and garbage are not', () {
    expect(RunnerOutput.parse('{"job":{"state":"failed","error":10},"segments":[]}', 0).finished, isTrue);
    expect(RunnerOutput.parse('{"job":{"state":"failed","error":7}}', 4).finished, isFalse);
    final load = RunnerOutput.parse('{"abi":1,"error":"model_load","model":{"loadMs":3}}', 3);
    expect(load.finished, isFalse);
    expect(load.state, 'model_load');
    expect(RunnerOutput.parse('Segmentation fault', 139).state, 'unparseable');
  });

  test('the app pipeline view: normalized words, Standard cues and the script limit', () {
    final segments = decodeShimSegments(jsonDecode(jsonEncode([
      _seg(0, 3000, [('And', 0, 300), ('so,', 300, 600), ('my', 700, 900), ('fellow', 900, 1300), ('Americans,', 1300, 2100)]),
      _seg(3200, 7000, [('ask', 3200, 3500), ('not', 3500, 3900), ('what', 3900, 4200), ('your', 4200, 4500),
        ('country', 4500, 5100), ('can', 5100, 5300), ('do', 5300, 5500), ('for', 5500, 5700), ('you.', 5700, 6500)]),
      // A trailing whisper hallucination on silence: dropped by the normalizer's nsp/lp gate.
      _seg(9000, 10000, [('Thank', 9000, 9400), ('you.', 9400, 10000)], nsp: 0.95, lp: -1.5),
    ])));
    final r = processTranscript(segments, language: 'en', durationMs: 10000);
    expect(r.rawWords, hasLength(16));
    expect(r.words, hasLength(14));
    expect(r.report.silenceHallucinationsDropped, 1);
    expect(r.cues, isNotEmpty);
    expect(r.text, 'And so, my fellow Americans, ask not what your country can do for you.');
    expect(r.cpsLimit, SpeechTuning.standardMaxCps);
    for (var i = 1; i < r.cues.length; i++) {
      expect(r.cues[i].startMs, greaterThanOrEqualTo(r.cues[i - 1].endMs));
    }
    expect(processTranscript(const [], language: 'ja', durationMs: 1000).cpsLimit, SpeechTuning.cjkMaxCps);
    expect(processTranscript(const [], language: 'ko', durationMs: 1000).cpsLimit, SpeechTuning.koreanMaxCps);
  });

  test('the runner receives the SpeechTuning constants by default', () {
    final args = const DecodeConfig().toArgs();
    String value(String flag) => args[args.indexOf(flag) + 1];
    expect(double.parse(value('--no-speech-thold')), SpeechTuning.noSpeechThreshold);
    expect(double.parse(value('--entropy-thold')), SpeechTuning.entropyThreshold);
    expect(double.parse(value('--logprob-thold')), SpeechTuning.logprobThreshold);
    expect(double.parse(value('--temperature-inc')), SpeechTuning.temperatureIncrement);
    expect(double.parse(value('--vad-threshold')), SpeechTuning.vadThreshold);
    expect(int.parse(value('--vad-min-speech-ms')), SpeechTuning.vadMinSpeechMs);
    expect(int.parse(value('--vad-min-silence-ms')), SpeechTuning.vadMinSilenceMs);
    expect(int.parse(value('--vad-speech-pad-ms')), SpeechTuning.vadSpeechPadMs);
    expect(int.parse(value('--chunk-target-ms')), SpeechTuning.chunkTargetMs);
    expect(int.parse(value('--chunk-search-ms')), SpeechTuning.chunkSearchMs);
    expect(int.parse(value('--carry-prompt-words')), SpeechTuning.carryPromptWords);
    expect(args, isNot(contains('--vad-model')));
    expect(const DecodeConfig(vadModelPath: '/m/vad.bin').toArgs(), containsAllInOrder(['--vad-model', '/m/vad.bin']));
  });
}
