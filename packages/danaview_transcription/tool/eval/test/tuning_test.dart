// OWNER: QA-06
//
// SpeechTuning (lib/src/catalog/tuning.dart) is the decided source of the Auto captions constants.
// These tests pin every constant to the decision table in docs/v1.1/editor/ai-eval.md and check
// that the places that still carry their own copy (the whisper runtime defaults, the shim's GPU
// policy, the normalizer options, the segmenter layout, the governor and the catalog) agree.

import 'dart:io';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Every constant and the literal the decision table shows for it.
final Map<String, String> _decided = {
  'chunkTargetMs': '${SpeechTuning.chunkTargetMs}',
  'chunkSearchMs': '${SpeechTuning.chunkSearchMs}',
  'noSpeechThreshold': '${SpeechTuning.noSpeechThreshold}',
  'entropyThreshold': '${SpeechTuning.entropyThreshold}',
  'logprobThreshold': '${SpeechTuning.logprobThreshold}',
  'temperatureIncrement': '${SpeechTuning.temperatureIncrement}',
  'carryPromptWords': '${SpeechTuning.carryPromptWords}',
  'autoDetectMinProbability': '${SpeechTuning.autoDetectMinProbability}',
  'vadThreshold': '${SpeechTuning.vadThreshold}',
  'vadMinSpeechMs': '${SpeechTuning.vadMinSpeechMs}',
  'vadMinSilenceMs': '${SpeechTuning.vadMinSilenceMs}',
  'vadSpeechPadMs': '${SpeechTuning.vadSpeechPadMs}',
  'vadSamplesOverlapSeconds': '${SpeechTuning.vadSamplesOverlapSeconds}',
  'hallucinationNoSpeech': '${SpeechTuning.hallucinationNoSpeech}',
  'hallucinationLogprob': '${SpeechTuning.hallucinationLogprob}',
  'hallucinationPhraseNoSpeech': '${SpeechTuning.hallucinationPhraseNoSpeech}',
  'standardMaxCharsPerLine': '${SpeechTuning.standardMaxCharsPerLine}',
  'standardMaxCps': '${SpeechTuning.standardMaxCps}',
  'shortPhrasesMaxCps': '${SpeechTuning.shortPhrasesMaxCps}',
  'cjkMaxCps': '${SpeechTuning.cjkMaxCps}',
  'cjkShortPhrasesMaxCps': '${SpeechTuning.cjkShortPhrasesMaxCps}',
  'koreanMaxCps': '${SpeechTuning.koreanMaxCps}',
  'koreanShortPhrasesMaxCps': '${SpeechTuning.koreanShortPhrasesMaxCps}',
  'metalMinAppleGpuFamily': '${SpeechTuning.metalMinAppleGpuFamily}',
  'metalMinIosVersion': '${SpeechTuning.metalMinIosVersion.$1}.${SpeechTuning.metalMinIosVersion.$2}',
  'firstMetalInitAllowanceMs': '${SpeechTuning.firstMetalInitAllowanceMs}',
  'preflightMemoryFactor': '${SpeechTuning.preflightMemoryFactor}',
  'androidBalancedUsesQ8': '${SpeechTuning.androidBalancedUsesQ8}',
};

void main() {
  final root = p.normalize(p.join(Directory.current.path, '..', '..'));

  test('every constant is recorded in the ai-eval.md decision table with its value', () {
    final doc = File(p.join(root, 'docs', 'v1.1', 'editor', 'ai-eval.md')).readAsStringSync();
    for (final e in _decided.entries) {
      expect(doc, contains('| `${e.key}` | `${e.value}` |'), reason: 'ai-eval.md decision row for ${e.key}');
    }
    for (final code in SpeechTuning.fleursTop30) {
      expect(doc, contains('`$code`'), reason: 'quality-hint list in ai-eval.md');
    }
  });

  test('the whisper runtime defaults equal the decided decode and VAD values', () {
    const d = WhisperDecodeOptions();
    expect(d.noSpeechThreshold, SpeechTuning.noSpeechThreshold);
    expect(d.entropyThreshold, SpeechTuning.entropyThreshold);
    expect(d.logprobThreshold, SpeechTuning.logprobThreshold);
    expect(d.temperatureInc, SpeechTuning.temperatureIncrement);
    expect(d.beamSize, 1, reason: 'greedy decoding (ai.md §4.5)');
    const v = WhisperVadOptions(modelPath: 'x');
    expect(v.threshold, SpeechTuning.vadThreshold);
    expect(v.minSpeech.inMilliseconds, SpeechTuning.vadMinSpeechMs);
    expect(v.minSilence.inMilliseconds, SpeechTuning.vadMinSilenceMs);
    expect(v.speechPad.inMilliseconds, SpeechTuning.vadSpeechPadMs);
    expect(v.samplesOverlapSeconds, SpeechTuning.vadSamplesOverlapSeconds);
  });

  test('the normalizer gates equal the decided hallucination thresholds', () {
    const o = NormalizerOptions();
    expect(o.noSpeechDropThreshold, SpeechTuning.hallucinationNoSpeech);
    expect(o.logprobDropThreshold, SpeechTuning.hallucinationLogprob);
    expect(o.phraseNoSpeechThreshold, SpeechTuning.hallucinationPhraseNoSpeech);
  });

  test('the segmenter layout resolves to the decided reading speeds', () {
    double cps(SegmentationPreset preset, ScriptProfile script) =>
        CaptionLayout.resolve(SegmentationSettings(preset: preset), script).maxCps;
    expect(cps(SegmentationPreset.standard, ScriptProfile.spaceDelimited), SpeechTuning.standardMaxCps);
    expect(cps(SegmentationPreset.shortPhrases, ScriptProfile.spaceDelimited), SpeechTuning.shortPhrasesMaxCps);
    for (final preset in [SegmentationPreset.standard, SegmentationPreset.singleLine]) {
      expect(cps(preset, ScriptProfile.cjk), SpeechTuning.cjkMaxCps);
      expect(cps(preset, ScriptProfile.korean), SpeechTuning.koreanMaxCps);
    }
    expect(cps(SegmentationPreset.shortPhrases, ScriptProfile.cjk), SpeechTuning.cjkShortPhrasesMaxCps);
    expect(cps(SegmentationPreset.shortPhrases, ScriptProfile.korean), SpeechTuning.koreanShortPhrasesMaxCps);
    expect(CaptionLayout.resolve(const SegmentationSettings(), ScriptProfile.spaceDelimited).maxCharsPerLine,
        SpeechTuning.standardMaxCharsPerLine);
  });

  test('the governor and the catalog apply the decided memory policy', () {
    expect(ResourceGovernor.memoryHeadroom, SpeechTuning.preflightMemoryFactor);
    expect(SpeechModelCatalog.balanced.fileName, SpeechTuning.androidBalancedUsesQ8 ? isNot(contains('q5_1')) : 'ggml-base-q5_1.bin');
    // RAM gating (ai.md §5.1, retained): Fast 2 GB, Balanced 3 GB, Accurate 4 GB marketed RAM, 0.8 slack.
    const gib = 1024 * 1024 * 1024;
    expect(SpeechModelCatalog.ramSlack, 0.8);
    expect([for (final m in SpeechModelCatalog.models) m.minDeviceRamBytes ~/ gib], [2, 3, 4]);
    expect(SpeechModelCatalog.availableTiers(physicalRamBytes: (2.8 * gib).round(), is64Bit: true),
        [SpeechModelTier.fast, SpeechModelTier.balanced], reason: '3 GB iPhones (XR, SE 3) do not get Accurate');
  });

  test('the shim GPU policy is the decided Metal policy (iOS >= 16.4, Apple GPU family >= 6)', () {
    final cpu = File(p.join(root, 'packages', 'danaview_whisper', 'src', 'dv_cpu.cpp')).readAsStringSync();
    expect(SpeechTuning.metalMinAppleGpuFamily, 6);
    expect(cpu, contains('kMTLGPUFamilyApple6 = 1006'), reason: 'MTLGPUFamilyApple6 raw value');
    final (major, minor) = SpeechTuning.metalMinIosVersion;
    expect(cpu, contains('__builtin_available(iOS $major.$minor, *)'));
  });

  test('the nightly script downloads exactly the catalog pins', () {
    final script = File(p.join(root, 'scripts', 'ci', 'editor', 'nightly.d', 'ai_eval.sh')).readAsStringSync();
    for (final m in [...SpeechModelCatalog.models, SpeechModelCatalog.vad]) {
      expect(script, contains('${m.fileName}|${m.url}|${m.bytes}|${m.sha256}'), reason: m.id);
    }
  });

  test('quality hint: 30 known languages; everything else recommends Accurate', () {
    expect(SpeechTuning.fleursTop30, hasLength(30));
    for (final code in SpeechTuning.fleursTop30) {
      expect(languageForWhisperCode(code), isNotNull, reason: code);
      expect(SpeechTuning.qualityHintFor(code), isFalse);
    }
    final hinted = whisperLanguages.where((l) => SpeechTuning.qualityHintFor(l.whisperCode)).length;
    expect(hinted, whisperLanguages.length - 30);
    expect(SpeechTuning.qualityHintFor('sw'), isTrue);
    expect(SpeechTuning.qualityHintFor('en'), isFalse);
  });
}
