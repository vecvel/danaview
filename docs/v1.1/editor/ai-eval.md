# Auto captions: accuracy evaluation, benchmarks and tuning

Owner: QA-06 (ai.md §14, §16.5; ARCH §18.2, V-A4, V-A10). This document records the eval harness,
the measured results, the device benchmarks and every tuning decision. The decided constants live
in `packages/danaview_transcription/lib/src/catalog/tuning.dart` (`SpeechTuning`);
`tool/eval/test/tuning_test.dart` pins each of them to the table in §6.7 and checks that the
runtime, shim, normalizer, segmenter, governor and catalog agree with them.

**Status (2026-10-15).**

| Part | State |
|---|---|
| Eval harness (WER/CER, cue boundary error, hallucination rate, CPS distribution, host speed, regression gate) | Done; unit-tested; smoke run green on the host |
| Nightly job `scripts/ci/editor/nightly.d/ai_eval.sh` | Runs: builds the host runner, smoke eval with the fixture model, accuracy eval on every cached tier |
| Accuracy numbers on real models | Pending: the pinned models are not in this host's cache and this run downloads nothing. The first CI nightly (GitHub Actions downloads the pinned files) fills §7 and the baseline |
| Licensed multilingual set (about 40 clips, 10 languages) | Planned in `tool/eval/eval_set.json` (`plan`); clips are pinned as they are selected. Today: jfk.wav (public domain) and 4 synthetic non-speech clips |
| Device benchmarks (§5) | deferred: no device available. The test `integration_test/editor_ai/ai_benchmark_test.dart` is ready |
| Decisions (§6) | Recorded. Values the measurements could still move are marked provisional |

## 1. What is measured

| Metric | Definition | Gate (ai.md §14.2) |
|---|---|---|
| WER | Word edit distance / reference words after the scoring normalizer (lower case, punctuation and symbols removed, apostrophes dropped, whitespace collapsed). Corpus level per tier and language (edit counts are summed, never rates averaged). | Regression ≤ +1.0 point absolute per tier and language vs `tool/eval/baseline.json` |
| CER | Grapheme edit distance without spaces. The gated metric for zh, ja and no-space scripts (th, lo, km, my, bo); reported for every language. | Same as WER for those languages |
| Cue boundary error | Each human-timed reference cue is matched to the generated cue with the largest overlap; `|Δstart|` and `|Δend|` are pooled per tier and language. Reported: median, p90, matched fraction. | Median ≤ 200 ms |
| Hallucination rate | Share of non-speech clips (silence, noise, instrumental music) that still have words after the app's normalizer; the raw whisper rate (before the normalizer) is reported next to it, so the normalizer's effect is visible. Also words per minute. | Reported (tunes VAD and thresholds; not gated) |
| CPS distribution | Reading speed of the generated cues (graphemes, line breaks as spaces, per second) per script profile: p50, p90, max and share over the layout's limit. | Reported (V-A10) |
| Host speed | Whisper compute time / audio time, model load, runner peak RSS on the host CPU. A plumbing figure only; device speed is §5. | — |

The pipeline under test is the app's own: the host runner (`tool/eval/native/dv_eval_runner`) links
the same shim and vendored whisper.cpp 1.9.4 as the apps (CPU backend), receives the
`SpeechTuning` decode and VAD values, and its segments go through `TranscriptNormalizer` and
`DpCaptionSegmenter` (Standard preset, 30 fps landscape project), exactly as `pipeline_job.dart`
does. Reports carry counts and timings only, never transcript text.

## 2. Running it

```sh
scripts/ci/editor/nightly.sh ai_eval                                  # nightly entry (smoke + cached tiers)
scripts/ci/editor/nightly.d/ai_eval.sh --download-models              # fetch the pinned models first (CI does this)
scripts/ci/editor/nightly.d/ai_eval.sh --tiers balanced --write-doc   # rewrite §7 from this run
scripts/ci/editor/nightly.d/ai_eval.sh --update-baseline              # accept this run as the new baseline (reviewed)
DV_EVAL_VAD_THRESHOLD=0.4 scripts/ci/editor/nightly.d/ai_eval.sh      # tuning sweep (never gates a release)
cd packages/danaview_transcription && flutter test tool/eval/test     # harness unit tests (+ smoke when the runner is built)
```

Models are cached in `~/.cache/danaview-ci/whisper` (shared with `whisper_host.sh`), remote clips in
`~/.cache/danaview-ci/ai-eval-clips`; both are size- and sha256-checked. Reports land in
`packages/danaview_transcription/build/ai_eval/{smoke,models}/report.{json,md}`.

The job also runs whenever shim parameters, the normalizer, the segmenter or the catalog change
(ai.md §16.5): those changes must attach the nightly report.

## 3. Eval set

Sources and licences allowed by the manifest validator: Common Voice (CC0-1.0), FLEURS (CC-BY-4.0,
attribution required), LibriVox and US government works (public domain), in-house screen recordings
and generated clips (in-house). Remote clips are pinned by URL, byte size and sha256.

Current clips (`tool/eval/eval_set.json`):

| Id | Language | Kind | Source | Licence |
|---|---|---|---|---|
| en-repo-jfk | en | speech (text reference, no timing reference) | whisper.cpp `samples/jfk.wav` | public domain (J. F. Kennedy, inaugural address, 1961) |
| en-synth-silence-30s | en | silence | generated | in-house |
| en-synth-noise-30s | en | noise | generated (filtered xorshift noise) | in-house |
| en-synth-music-30s | en | music | generated (chords and beat) | in-house |
| ja-synth-music-30s | ja | music | generated | in-house |

Planned licensed set (about 40 clips): 4 clips each of en, es, de, fr, pt, ja, zh, ko, ar and hi
from FLEURS, Common Voice, LibriVox and in-house screen recordings, plus 6 real non-speech clips
(room tone, instrumental music). Each speech clip needs a verbatim reference and, for at least one
clip per language, human-timed reference cues for the boundary metric. FLEURS attribution:
"FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech (Conneau et al., 2022),
Google, CC BY 4.0", listed in `tool/eval/README.md` for every FLEURS clip used.

## 4. Gate and baseline

`tool/eval/baseline.json` holds the accepted per-tier, per-language error rate. It starts empty: the
first full nightly records it (`--update-baseline`, reviewed), after which a WER/CER regression of
more than 1.0 point fails the job. Without a baseline entry only the boundary gate and the
"every clip ran" check apply.

## 5. Device benchmarks (replaces the ai.md §14.1 / ARCH §18.2 estimates)

Measured with `integration_test/editor_ai/ai_benchmark_test.dart` (models and a 60 s English clip
pre-staged with `xcrun devicectl` / `adb push`; see the file header): cold load with the GPU
requested (includes the first Metal compile on a fresh install), warm load, CPU load, and a 60 s
Balanced transcription with the shipped constants (wall, compute, real-time factor, GPU used,
lowest available memory during the run).

| Device | Tier | Cold load (ms) | Warm load (ms) | First Metal init (cold − warm) | 60 s transcription wall (s) | Compute / audio | Memory drop (MB) |
|---|---|---|---|---|---|---|---|
| iPhone XR (A12, 3 GB) | Fast / Balanced | deferred: no device available | | | | | |
| iPhone 11 (A13) | Fast / Balanced / Accurate | deferred: no device available | | | | | |
| iPhone 13 (A15) | Fast / Balanced / Accurate | deferred: no device available | | | | | |
| iPhone 15 (A16) | Fast / Balanced / Accurate | deferred: no device available | | | | | |
| iPhone SE 3 (A15, 4 GB) | Fast / Balanced / Accurate | deferred: no device available | | | | | |
| Galaxy A15 (Helio G99) | Fast / Balanced | deferred: no device available (Android lane) | | | | | |
| Pixel 6a (Tensor G1) | Fast / Balanced / Accurate | deferred: no device available (Android lane) | | | | | |
| Galaxy A55 (Exynos 1480) | Fast / Balanced / Accurate | deferred: no device available (Android lane) | | | | | |
| Redmi Note 13 Pro (SD 7s Gen 2) | Fast / Balanced / Accurate | deferred: no device available (Android lane) | | | | | |
| Pixel 8 | Fast / Balanced / Accurate | deferred: no device available (Android lane) | | | | | |

Until these rows are filled, the ai.md §14.1 estimates stay in force for ETA copy and for
ARCH §18.2 (Balanced, 1 min of speech: 7–15 s Android mid, 3–6 s iPhone 11, 25–50 s Android low).

## 6. Decisions

### 6.1 RAM gating (retained)

Fast is offered from 2 GB marketed RAM, Balanced from 3 GB, Accurate from 4 GB, with a 0.8 slack on
the RAM the device reports (`SpeechModelCatalog.ramSlack`); low-RAM Android devices get Fast only.
Preflight needs `SpeechTuning.preflightMemoryFactor` (1.3) × the tier's peak budget available
(tiny 200 MB, base 300 MB, small 650 MB). So 3 GB iPhones (XR, SE 2) do not see Accurate (ai.md
§19.2 Q4: hidden until measured). Evidence needed to change it: §5 memory-drop column on the XR and
the Galaxy A15 staying under the budgets with the editor preview open.

### 6.2 A12 vs A13 Metal policy and first Metal init (V-A4) (retained, provisional)

Metal only on iOS ≥ 16.4 with Apple GPU family ≥ 6 (A13 and newer): `metalMinAppleGpuFamily = 6`,
`metalMinIosVersion = 16.4`, implemented in the shim (`dv_cpu.cpp`, checked by `tuning_test.dart`).
A12 (Apple5) stays on the NEON CPU path. The first Metal initialisation (embedded kernel library
compile) is budgeted at `firstMetalInitAllowanceMs = 5000`, the top of the 1–5 s estimate, for the
first ETA of a session. V-A4 closes when §5 has the XR row (CPU) and the iPhone 11 row (cold − warm
load = first Metal init); enabling Metal on A12 would need a shim build with the family check
lowered, which the benchmark then compares against the CPU row.

### 6.3 q5_1 vs q8_0 on Android (retained)

Balanced stays `ggml-base-q5_1.bin` on Android (`androidBalancedUsesQ8 = false`): q8_0 is 37% larger
(81.8 MB vs 59.7 MB) for a marginal accuracy gain, and no dot-product-CPU measurement exists yet.
The Android lane's benchmark on the Redmi Note 13 Pro and Pixel 8 decides it; the catalog supports a
per-platform override.

### 6.4 VAD and decoding thresholds (retained, provisional)

Decoding: greedy, no-speech 0.6, entropy 2.4, log-probability −1.0, temperature step 0.2, 24 prompt
words carried, chunks of 180 s ± 15 s. VAD (Silero v6.2.0): threshold 0.5, minimum speech 250 ms,
minimum silence 300 ms, padding 100 ms, overlap 0.1 s. Normalizer hallucination gates: drop a segment
with `nsp > 0.5 && lp < −0.8`; drop phrase-list matches when `nsp > 0.3` (or a short unit end).
These are whisper.cpp's defaults and the ai.md §8.3 values; the harness reports the raw and
normalized hallucination rates on the non-speech clips, and the sweep variables
(`DV_EVAL_VAD_THRESHOLD`, `DV_EVAL_NO_SPEECH_THRESHOLD`) move them only with a WER cost recorded
here.

### 6.5 CJK and Korean reading speed (V-A10) (retained, provisional)

Chinese/Japanese 9 cps (Short phrases 10), Korean 12 cps (Short phrases 14), with 16 / 18 characters
per line. Full-width characters count 1. These are conservative starting points: the CPS table of §7
shows how often real recognised speech exceeds them (a high over-limit share means cues get stretched
or merged); V-A10 closes when the licensed ja/zh/ko clips have run and a reader check agrees.

### 6.6 Language quality hint (provisional)

`qualityHint` (recommend Accurate) is set for every language outside the 30 with the lowest published
FLEURS WER for whisper large-v2 (Radford et al., 2022, appendix D): `es`, `it`, `en`, `pt`, `de`,
`ja`, `ru`, `pl`, `ca`, `nl`, `ko`, `fr`, `id`, `tr`, `uk`, `sv`, `ms`, `no`, `fi`, `vi`, `th`, `sk`,
`el`, `cs`, `hr`, `tl`, `da`, `ro`, `zh`, `bg`. The ranking is the large model's; tiny and base are
weaker everywhere, so the list is a floor. Per-language numbers [VERIFY against the paper's table]
and the nightly per-tier WER replace it. Exposed as `SpeechTuning.fleursTop30` /
`SpeechTuning.qualityHintFor(code)`. Since FIX-AI-TUNING, `TranscriptionLanguage.qualityHint` is a
getter that reads `SpeechTuning.qualityHintFor(whisperCode)` (it was a stored field, false for every
language), so the language picker's hint follows this list.

### 6.7 Decided constants (`SpeechTuning`)

| Constant | Value | Status |
|---|---|---|
| `chunkTargetMs` | `180000` | retained (ai.md §4.5) |
| `chunkSearchMs` | `15000` | retained |
| `noSpeechThreshold` | `0.6` | retained, provisional (§6.4) |
| `entropyThreshold` | `2.4` | retained |
| `logprobThreshold` | `-1.0` | retained |
| `temperatureIncrement` | `0.2` | retained |
| `carryPromptWords` | `24` | retained |
| `autoDetectMinProbability` | `0.6` | retained (D-19) |
| `vadThreshold` | `0.5` | retained, provisional (§6.4) |
| `vadMinSpeechMs` | `250` | retained |
| `vadMinSilenceMs` | `300` | retained |
| `vadSpeechPadMs` | `100` | retained |
| `vadSamplesOverlapSeconds` | `0.1` | retained |
| `hallucinationNoSpeech` | `0.5` | retained, provisional (§6.4) |
| `hallucinationLogprob` | `-0.8` | retained, provisional |
| `hallucinationPhraseNoSpeech` | `0.3` | retained, provisional |
| `standardMaxCharsPerLine` | `42` | retained (ai.md §9.2) |
| `standardMaxCps` | `17.0` | retained |
| `shortPhrasesMaxCps` | `20.0` | retained |
| `cjkMaxCps` | `9.0` | retained, provisional (V-A10) |
| `cjkShortPhrasesMaxCps` | `10.0` | retained, provisional (V-A10) |
| `koreanMaxCps` | `12.0` | retained, provisional (V-A10) |
| `koreanShortPhrasesMaxCps` | `14.0` | retained, provisional (V-A10) |
| `metalMinAppleGpuFamily` | `6` | retained, provisional (V-A4) |
| `metalMinIosVersion` | `16.4` | retained |
| `firstMetalInitAllowanceMs` | `5000` | estimate until §5 (V-A4) |
| `preflightMemoryFactor` | `1.3` | retained (§6.1) |
| `androidBalancedUsesQ8` | `false` | retained (§6.3) |

## 7. Results

The section between the markers is rewritten by `ai_eval.sh --write-doc` from the latest model run.

<!-- ai-eval:results:begin -->
No model run recorded yet: the pinned models are not in this host's cache and builder runs do not
download. The first CI nightly (which downloads the pinned files) writes the tables here.

Host smoke run (2026-10-15, fixture model, macOS arm64 CPU): the chain runner → shim → normalizer →
segmenter → scoring → gate completed for all 5 clips; the fixture model "speaks" over any audio, and
the harness flagged 4 of 4 non-speech clips as hallucinations (raw 100%, after the normalizer 100%,
4 words per minute after the normalizer collapsed the repetition loops); jfk scored 100% WER
(2 S / 20 D / 0 I) as expected for the fixture. Gate passed (smoke checks).
<!-- ai-eval:results:end -->

## 8. Follow-ups outside QA-06

Status as of 2026-10-15 (FIX-DOCS), after FIX-AI-TUNING and INT-04 landed.

- Done (FIX-AI-TUNING): the consumers that held their own copy of a constant now read
  `SpeechTuning` directly: `caption_layout.dart` (line length and CPS, incl. CJK/Korean, AI-11),
  `NormalizerOptions` defaults (hallucination thresholds, AI-10), the decode and VAD options built by
  `pipeline_job.dart` (AI-13; no longer `WhisperVadOptions` defaults), and
  `ResourceGovernor.memoryHeadroom` (= `preflightMemoryFactor`, AI-13). `orchestration_test.dart`
  asserts the decode and VAD values; the drift guard in `tool/eval/test/tuning_test.dart` stays.
- Done (FIX-AI-TUNING): `TranscriptionLanguage.qualityHint` changed from a stored field (false for
  every language) into a getter reading `SpeechTuning.qualityHintFor(whisperCode)` (§6.6);
  `languages_test.dart` checks that exactly the FLEURS top 30 carry no hint.
- Done (INT-04): the root `pubspec.yaml` depends on `danaview_whisper` and
  `danaview_transcription` (`lib/main.dart` wires the auto captions service), so the benchmark
  test's imports no longer rely on transitive resolution.
- Open: ARCH §18.2's captions row stays an estimate until §5 is measured on devices (ARCH is edited
  by its owners).
