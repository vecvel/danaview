# AIS-44 · Spike: on-device diarization with sherpa-onnx (Mac half)

- **Ticket:** AIS-44 (AI_STUDIO_PLAN.md "#### AIS-44"; D-70c, V-S17, V-S18, V-S19, RS17, §7.3)
- **Status:** Mac half done; Android half **pending: Windows lane**. Real-speech eval set pending an owner decision (§8).
- **Host:** `spikes/ais-44-diarization/` (throwaway Dart CLI host, BUILD_PLAN §0.1 rule 8; no product dependency, nothing in any product build)
- **Machine:** MacBook M2, 8 GB, macOS 26, Dart 3.12.2, `sherpa_onnx` 1.13.8 (pub.dev). Other builders were running (load average 4–5), so the speeds below are conservative.
- **Date:** 2026-10-22

## 1. Verdict

| Question | Answer |
|---|---|
| Engine | **GO**: sherpa-onnx offline speaker diarization works, runs offline, and is fast enough on the Mac |
| Segmentation model | **GO**: pyannote segmentation 3.0, **int8** export (1.5 MB). Accuracy matches fp32 at a quarter of the size |
| Embedding model | **Recommend NeMo TitaNet-small** (`nemo_en_titanet_small.onnx`, 40.3 MB). Fallback: WeSpeaker ResNet34-LM (26.5 MB) if TitaNet's licence fails review. **Reject 3D-Speaker CAM++ (en, VoxCeleb)** |
| V-S18: overlap survives | **Yes, closed.** sherpa-onnx's output keeps overlapping segments from different speakers (overlap recall 86–98%). AIS-46 can use the segment list directly and does not need pyannote's per-frame activity |
| V-S19 / RS17: install size on iOS | **NO-GO as specified.** There is no way to ship sherpa-onnx + ONNX Runtime on iOS without growing the app: it is native code, iOS can't download code, and on-demand resources can't carry executables. Measured cost: **+26.4 MB installed, about 9.8 MB compressed download** (arm64). Per §7.3 this goes to the owner **before AIS-45 starts**. Options are in §6 |
| Android install size | pending: Windows lane (package inputs in §6.3) |
| Accuracy caveat | Clearly different voices score DER 3–5%, with overlaps kept. Two similar female voices (Samantha and Karen) are merged by every model, because the pipeline clusters one embedding per pyannote window-speaker and pyannote does not split those two voices. The voices themselves are separable: on clean segments TitaNet sorts them 100% correctly. A real-speech eval set is needed before the AIS-48 gate |

## 2. What was run

- `tool/make_clips.py` builds the clips with macOS `say`: 16 kHz mono 16-bit, with a −55 dBFS noise floor. Each utterance is trimmed to its speech span and placed on a timeline; a negative gap creates overlap. Ground truth is written alongside as RTTM and JSON. No network is used.

| Clip | Length | Speakers (voices) | Overlap |
|---|---|---|---|
| c1_2spk_turns | 31.1 s | 2 (Samantha, Daniel) | 0 s |
| c2_2spk_overlap | 24.8 s | 2 (Samantha, Daniel) | 4.7 s |
| c3_3spk_turns | 34.3 s | 3 (Samantha, Daniel, Karen) | 0 s |
| c4_3spk_overlap | 27.3 s | 3 (Samantha, Daniel, Karen) | 4.8 s |
| c5_2spk_similar | 27.7 s | 2 (Samantha, Karen), similar voices | 1.0 s |
| c6_2spk_male | 32.5 s | 2 (Daniel, Ralph) | 0.8 s |
| l1_4spk_long | 553.7 s | 4 (Samantha, Daniel, Karen, Ralph) | 23.2 s |

- `bin/diarize.dart` calls `OfflineSpeakerDiarization` from the `sherpa_onnx` package, AOT-compiled (`dart compile exe`), one process per configuration, with peak RSS from `/usr/bin/time -l`.
- `tool/run_grid.sh` runs 3 embedding models × {fp32, int8} segmentation × {oracle speaker count, threshold 0.3–0.9} over the six short clips. `tool/run_rtf.sh` measures the long clip at 1, 2 and 4 threads.
- `tool/score.py` computes frame-level DER at 10 ms frames with overlap scored and an optimal 1:1 speaker mapping, with no collar and with a 0.25 s collar. It also reports speaker count and overlap recall, precision and "both right".
- `bin/embed.dart` and `tool/verify.py` test the embeddings on their own: one embedding per ground-truth segment (overlap-free part), then same/different cosine, EER and oracle-count clustering purity.
- `bin/embed.dart --regions` and `tool/chunks.py` run an experiment that re-labels speakers from fixed 1.5 s chunk embeddings (§4.3).

Models come from `$DANAVIEW_DIARIZATION_MODELS` (default `~/danaview-models/diarization`, checked against `SHA256SUMS` there) and are not copied into the repo. To reproduce: `dart pub get && dart compile exe bin/diarize.dart -o build/diarize && dart compile exe bin/embed.dart -o build/embed && python3 tool/make_clips.py && tool/run_grid.sh && tool/run_rtf.sh && python3 tool/summarize.py`. Set `SHERPA_LIB_DIR` to `…/pub-cache/hosted/pub.dev/sherpa_onnx_macos-1.13.8/macos` for the AOT exe.

## 3. Models, sizes, licences (V-S17)

| File | Size | Role | Licence | Source in model metadata |
|---|---|---|---|---|
| pyannote segmentation 3.0 `model.int8.onnx` | **1,540,506 B** | segmentation (recommended) | **MIT**, © 2022 CNRS (LICENSE file read locally) | huggingface.co/pyannote/segmentation-3.0; mirror huggingface.co/csukuangfj/pyannote-models/tree/main/segmentation-3.0 |
| pyannote segmentation 3.0 `model.onnx` | 5,992,913 B | segmentation fp32 | MIT | same |
| `nemo_en_titanet_small.onnx` | **40,257,283 B** | embedding (recommended), 192-d | **[VERIFY]**: NVIDIA NGC model card for `titanet_small`. TitaNet-Large on HF is CC-BY-4.0; I could not confirm titanet_small's terms locally | catalog.ngc.nvidia.com/orgs/nvidia/teams/nemo/models/titanet_small |
| `wespeaker_en_voxceleb_resnet34_LM.onnx` | 26,530,550 B | embedding (fallback), 256-d | **[VERIFY]**: WeSpeaker code is Apache-2.0; its pretrained VoxCeleb models are documented as following the dataset licence (CC BY 4.0) | wespeaker-1256283475.cos.ap-shanghai.myqcloud.com (Tencent COS) |
| `3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx` | 29,596,978 B | embedding (rejected), 512-d | **[VERIFY]**: ModelScope `iic/speech_campplus_sv_en_voxceleb_16k`, believed Apache-2.0 | modelscope.cn |
| sherpa-onnx 1.13.8 | n/a | engine | **Apache-2.0** (LICENSE in the pub packages, read) | pub.dev `sherpa_onnx` |
| ONNX Runtime (statically inside sherpa-onnx's iOS/macOS binary; separate `.so` on Android) | n/a | runtime | MIT **[VERIFY: notice text and version bundled in 1.13.8]** | n/a |

- **Download pack (recommended):** 1.54 MB + 40.26 MB = **≈ 41.8 MB** (that is the N for the privacy-policy sentence in §16). The fallback pack is ≈ 28.1 MB.
- **pyannote gate:** `pyannote/segmentation-3.0` on Hugging Face is gated: users must accept conditions and share contact details. The gate is an access condition, not a licence term; the MIT licence allows redistribution with the notice. The k2-fsa mirror `csukuangfj/pyannote-models` is believed ungated **[VERIFY]**. Owner decision 3 below.
- **Hugging Face mirror for the embedding model:** sherpa-onnx ships its embedding ONNX files as GitHub release assets, which is a new host for the privacy policy. Whether a pinned Hugging Face copy exists is **[VERIFY]**. If none does, the owner's own pinned HF repo, re-hosting allowed licences only, keeps the hosts unchanged (decision 4).
- Training data for all three embedding models is VoxCeleb (YouTube-sourced audio, CC BY 4.0 metadata). **[VERIFY]** with legal whether that affects use in a commercial app.

## 4. Accuracy

### 4.1 Grid on the six short clips (DER means; int8 segmentation unless noted; 2 threads)

| Embedding | Clustering | DER | DER, 0.25 s collar | Right speaker count | Overlap recall | Overlap, both speakers right | RTF | Peak RSS |
|---|---|---|---|---|---|---|---|---|
| **TitaNet-small** | oracle k | **23.2%** | **17.7%** | 4/6 | 94% | 78% | **0.067** | 274 MB |
| **TitaNet-small** | threshold 0.4–0.7 (flat) | **23.2%** | **17.7%** | 4/6 | 94% | 78% | 0.067–0.070 | 236–307 MB |
| TitaNet-small, fp32 seg | threshold 0.5 | 24.3% | 18.0% | 4/6 | 93% | 77% | 0.070 | 302 MB |
| WeSpeaker ResNet34-LM | oracle k | 24.2% | 18.7% | 4/6 | 94% | 78% | 0.183 | 177 MB |
| WeSpeaker ResNet34-LM | threshold 0.3–0.4 | 24.2% | 18.7% | 4/6 | 94% | 78% | 0.185 | 156–165 MB |
| WeSpeaker ResNet34-LM | threshold ≥ 0.6 | 47–63% | 38–53% | 0–2/6 | 0–47% | 0–47% | 0.19 | n/a |
| CAM++ (en VoxCeleb) | oracle k | 52.7% | 44.2% | 5/6 | 94% | 89% | 0.090 | 169 MB |
| CAM++ (en VoxCeleb) | best threshold (0.4) | 43.7% | 37.5% | 1/6 | 95% | 57% | 0.096 | 154 MB |

Per clip, TitaNet-small int8 at threshold 0.5 gives: c1 2.9%, c2 4.9%, c6 3.6% (0.0–1.2% with a collar), all with the right speaker count. The clips containing Samantha and Karen give c5 54.9%, c3 35.2% and c4 37.7%: Samantha and Karen end up as one speaker.

### 4.2 Embeddings alone (clean ground-truth segments, 50 segments, 5 voices)

| Embedding | Same-speaker cosine | Different-speaker cosine | EER | Oracle-count clustering purity |
|---|---|---|---|---|
| **TitaNet-small** | 0.836 | 0.251 | **1.1%** | **100%** |
| WeSpeaker ResNet34-LM | 0.896 | 0.555 | 6.5% | 100% |
| CAM++ (en VoxCeleb) | 0.528 | 0.415 | 40.9% | 64% |

The hardest pair is Samantha and Karen. With TitaNet their cross-speaker cosine is 0.59, against 0.84 within the same speaker, so they are separable. With WeSpeaker the cross-speaker cosine is 0.79, against about 0.89, which is close. CAM++ barely separates any voice; it may suffer a feature-normalisation mismatch in this export **[VERIFY]**, but the result is the same either way.

### 4.3 Why similar voices merge, and what AIS-46 can do

sherpa-onnx makes one embedding per (10 s window, pyannote local speaker) and clusters those. All three embedding models give the *same* result on c5 (DER 54.9%, confusion 42.1%). That points to segmentation: pyannote assigns Samantha and Karen to one local speaker, and no embedding can split a mixed unit. On the long clip the confusion matrix confirms it: Karen and Samantha land in one cluster (105 s and 128 s), while Daniel and Ralph are split.

Experiment (`tool/chunks.py`): keep sherpa-onnx's speech and overlap activity, but cluster 1.5 s chunk embeddings instead. With TitaNet and the oracle count, mean DER falls from 23.2% to **18.2%** (collar 12.0%), and c5 falls from 54.9% to 21.4%. c3 still merges. That direction suits AIS-46 (§7), but it needs a real-speech eval set before anyone tunes it.

### 4.4 Long clip (9.2 min, 4 speakers, int8 segmentation)

| Embedding | Clustering | DER | Collar | Speakers found | Overlap recall | RTF (2 threads) |
|---|---|---|---|---|---|---|
| TitaNet-small | threshold 0.7 or 0.8, or k = 4 | 38.0% | 34.2% | 4/4 | 86% | 0.094 (2 threads), 0.11 (4 threads, under load) |
| TitaNet-small | threshold 0.5 | 47.4% | 44.0% | 9/4 | 86% | 0.094 |
| WeSpeaker ResNet34-LM | k = 4 or threshold 0.5 | 35.2% | 31.6% | 4/4 | 86% | 0.261 |
| WeSpeaker ResNet34-LM | threshold 0.4 | 44.8% | 42.2% | 5/4 | 86% | 0.235 |
| CAM++ | threshold 0.5 | 77.1% | 74.1% | 20/4 | 86% | 0.113 |

Nearly all of the error is the Samantha+Karen merge. With TitaNet, use **threshold 0.7** as the default: it is flat from 0.4 to 0.7 on short clips and correct at 0.7–0.8 on long ones. WeSpeaker's usable threshold window is narrow (0.3–0.5) and it falls to one speaker at 0.6 or above, which makes it the more fragile default.

## 5. Overlap (V-S18): closed, overlaps survive

The output segment list contains time-overlapping segments for different speakers. TitaNet int8 on c2 gives:

| Ground truth | sherpa-onnx output |
|---|---|
| Samantha 0.50–3.70 / Daniel 2.50–5.69 | S1 0.03–3.79 / S0 2.39–5.84 |
| Samantha 6.19–8.93 / Daniel 7.43–11.63 | S1 6.12–8.94 / S0 7.39–11.59 |
| Samantha 12.23–15.50 / Daniel 13.50–16.59 | S1 12.20–15.51 / S0 13.58–16.59 |

- Overlap recall was 86–98% and precision 82–100% across every config. "Both speakers right" in overlap frames reaches 89–98% on clips with distinct voices.
- `minDurationOn 0.2` / `minDurationOff 0.5` (the defaults) were kept. AIS-46 should keep `minDurationOff` ≤ 0.5 s, or short overlap interjections merge.
- AIS-46 does **not** need to read pyannote's per-frame activity directly. The documented fallback is unnecessary for sherpa-onnx 1.13.8.

## 6. Speed, memory and install size (V-S19, RS17)

### 6.1 Speed (Mac M2; mid and low tier phones pending)

| Config | RTF, 1 thread | 2 threads | 4 threads | 10-min video at 2 threads |
|---|---|---|---|---|
| pyannote int8 + TitaNet-small | 0.144 | **0.094** | 0.075 | ≈ 56 s |
| pyannote int8 + WeSpeaker | 0.487 | 0.261 | 0.173 | ≈ 2 min 37 s |
| pyannote int8 + CAM++ | 0.170 | 0.113 | 0.111 | n/a |

- Model load takes about 110 ms. Speed scales linearly: 37 min of audio ran at RTF 0.094 too.
- The §7.3 target is ≤ 0.3 on the mid tier. TitaNet has about 3× headroom on M2-class hardware; WeSpeaker is already at 0.26 on the Mac and will probably miss the target on mid-tier phones. Phone tiers are **[VERIFY: AIS-45 device runs]**. My rough estimate is that A15-class iPhones reach about 0.15–0.25 with TitaNet; low-tier Android may miss the target and hide "Detect speakers" (D-70c).

### 6.2 Memory (whole process, including the Dart VM and the host's audio copies)

| Case | Peak RSS |
|---|---|
| Models loaded, no audio (TitaNet / WeSpeaker) | 121 MB / 86 MB |
| 25–35 s clips | 140–380 MB |
| 9.2 min, TitaNet, 2 threads | 380 MB |
| **37 min, TitaNet, 2 threads** | **705 MB RSS, 1.08 GB peak footprint** |

- Memory grows with media length. Part of that is this host: it holds three float copies of the audio (Dart list, `Float32List`, native buffer), which is about 425 MB at 37 min. Part is sherpa-onnx's per-window state and clustering, which grows with the number of window-speaker embeddings.
- **Risk for AIS-45/46:** on 3–4 GB phones the jetsam limit is around 1.4–2 GB. The plugin must pass one native buffer, ideally mmap'd from the speech WAV, and should process long media in blocks of about 10 minutes, linking speakers across blocks by centroid cosine. RTF and memory for 60-minute media go to AIS-46.

### 6.3 Binary size added by sherpa-onnx (measured from the pub packages)

| Platform | What gets bundled | Uncompressed | gzip -9 (download estimate) |
|---|---|---|---|
| iOS arm64 (device) | `SherpaOnnxC.framework`, a dynamic framework with ONNX Runtime linked in statically; links CoreML | **26.4 MB** (`__TEXT` 25.3 MB) | **≈ 9.8 MB** |
| macOS (not shipped) | `libsherpa-onnx-c-api.dylib`, arm64 slice | 27.1 MB | n/a |
| Android arm64-v8a | `libonnxruntime.so` 22.2 MB + `libsherpa-onnx-c-api.so` 4.5 MB + `libsherpa-onnx-cxx-api.so` 0.4 MB | 27.2 MB | ≈ 10.0 MB |
| Android, other ABIs | armeabi-v7a, x86, x86_64 packages also pulled in as dependencies | pending: Windows lane | pending: Windows lane |

- The `sherpa_onnx` Dart package is all-or-nothing. It depends on every platform package (Android ×4 ABIs, iOS, macOS, Linux, Windows, web), and its binary includes the whole of sherpa-onnx (ASR, TTS, KWS, VAD) plus a full ONNX Runtime.

### 6.4 Is there a zero-growth runtime path?

**iOS: not with sherpa-onnx or ONNX Runtime.**
- Executable code can't be downloaded: App Review guideline 2.5.2 forbids it.
- On-demand resources may only hold data, not executables.
- The model files can be downloaded (D-70c), but the runtime can't.

The owner has to choose one of these:

| Option | iOS install growth | Effort and risk |
|---|---|---|
| **A. Size budget, stock package**: `sherpa_onnx` 1.13.8 as-is | +26.4 MB installed, ≈ +9.8 MB download | Lowest effort. Breaks the 2026-10-16 rule |
| **B. Size budget, slim build**: sherpa-onnx built with diarization only, against an ONNX Runtime *minimal* build (ORT format, op set reduced to these two models), shipped as our own xcframework inside `danaview_diarization` | estimate **≈ 4–8 MB installed, ≈ 2–3 MB download [VERIFY: needs a source build]** | Medium effort: needs a CMake build of sherpa-onnx plus ORT, done offline with approved source. Still growth, just smaller |
| **C. Zero growth: Core ML** (recommended to evaluate) | ≈ 0 (Core ML is a system framework; our Swift code for fbank features, pyannote powerset decoding and clustering is tens of KB) | Medium-high effort. Convert pyannote seg 3.0 (SincNet + LSTM) and TitaNet to Core ML, download the `.mlpackage` with the other models (data, after consent), compile on device with `MLModel.compileModel(at:)`. Needs a follow-up spike (AIS-44b) and `coremltools`, which is a download that needs approval. The Core ML pack replaces the ONNX pack on iOS, so iOS and Android get different model files from the same pinned repo |
| **D. Zero growth: ggml**: run both models on the ggml that whisper.cpp already ships (`WhisperCore.xcframework`) | ≈ 0 (code only) | High effort: hand-port both networks (LSTM, SincNet, ResNet-style blocks) to ggml. Only if C fails |

- My recommendation is **C, with B as the fallback** if Core ML conversion or accuracy fails. A is acceptable only if the owner lifts the rule for iOS. Whatever is picked, the Licences screen gains sherpa-onnx (Apache-2.0) and ONNX Runtime (MIT) under A or B only, plus the model licences under every option.
- **Android: pending: Windows lane.** For that lane: Play Feature Delivery (an on-demand dynamic feature module carrying `libonnxruntime.so` and the sherpa-onnx `.so` files, ≈ 10 MB download for arm64) keeps the base install unchanged. Downloading `.so` files from our own host would break Google Play's policy on executable code. The Windows lane should verify that the module works with Flutter FFI `DynamicLibrary.open` after a split install, and measure the AAB per-ABI delta.

## 7. Recommendations for AIS-45 / AIS-46

1. Model pair: pyannote segmentation 3.0 **int8** plus **TitaNet-small** (fallback WeSpeaker ResNet34-LM). Clustering threshold **0.7** when the count is unknown; pass the count when the user gives it (≤ 8).
2. Feed the same 16 kHz mono WAV as whisper. Pass one native buffer rather than a Dart list copy, and use blocks of about 10 minutes for long media (§6.2).
3. Keep sherpa-onnx's overlapping segments as they come (V-S18). In AIS-46, consider chunk-level re-labelling (§4.3) to fix similar-voice merges, gated on the real eval set.
4. Run on a background isolate or thread with progress (`processWithCallback` exists) and 2 threads. 4 threads gave only about 20% more speed.
5. Do not use the stock `sherpa_onnx` Dart package in the app, because of its size and all-platform dependencies (§6.3). Use our own plugin over the C API, built per option B or C.

## 8. Open owner decisions

1. **iOS install size (blocks AIS-45 iOS):** pick option C (Core ML follow-up spike, zero growth), B (a growth budget of about 4–8 MB), or A (+26 MB). This spike recommends **C, falling back to B**. The Core ML spike needs approval to install `coremltools` offline.
2. **TitaNet-small licence:** confirm the NGC terms for `titanet_small` (or redistribution from a mirror). If they fail, the fallback is WeSpeaker ResNet34-LM: weaker on similar voices, about 2.8× slower, 14 MB smaller.
3. **pyannote gate:** confirm that downloading the MIT-licensed segmentation model from the ungated `csukuangfj/pyannote-models` mirror (or our own copy, with the MIT notice) is acceptable without users accepting pyannote's HF gate.
4. **Host for model files:** decide on a pinned Hugging Face repo under our own org, holding the segmentation int8 and embedding (and later the Core ML) files, so the privacy policy keeps naming only huggingface.co / hf.co. The alternative is GitHub release assets, which add a host.
5. **Real-speech eval set:** owner-recorded clips (2–4 people, with real overlaps and two similar voices) or named CC-licensed clips; see `docs/v1.2/ai-studio/qa/diarization_eval.md`. The synthetic `say` set here is enough to compare models but not to gate AIS-48.

## 9. Housekeeping

- Spike files are under `spikes/ais-44-diarization/`. The generated WAVs over 1 MB and `results/` are meant to be git-ignored. **However, a WIP backup commit made before the `.gitignore` existed already tracks `data/l1_4spk_long.wav` (17.7 MB), the other WAVs and `results/*.json`.** Someone with git rights needs to run `git rm --cached` on `spikes/ais-44-diarization/data/{c3_3spk_turns,c6_2spk_male,l1_4spk_long}.wav` and `spikes/ais-44-diarization/results/`; this spike does not run state-changing git commands.
- Nothing in any product package references this spike.
