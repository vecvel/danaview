# AIS-44 · Spike: on-device diarization with sherpa-onnx (Mac half)

- **Ticket:** AIS-44 (AI_STUDIO_PLAN.md "#### AIS-44"; D-70c, V-S17, V-S18, V-S19, RS17, §7.3)
- **Status:** Mac half done; Android half done (§10, Windows lane, 2026-10-23). Real-speech eval set pending an owner decision (§8).
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
| Android install size | Stock package: +27.0 MB installed / +9.9 MB download (arm64). Zero base growth with Play Feature Delivery, verified locally (§10.5, §10.6) |
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
| Android, other ABIs | armeabi-v7a, x86, x86_64 packages also pulled in as dependencies | armeabi-v7a 18.8 MB, x86_64 31.0 MB (x86 is not packaged by Flutter); see §10.5 | armeabi-v7a ≈ 9.1 MB, x86_64 ≈ 11.2 MB |

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
- **Android: done by the Windows lane; the feature module is verified with local testing (§10.6).** The original request: Play Feature Delivery (an on-demand dynamic feature module carrying `libonnxruntime.so` and the sherpa-onnx `.so` files, ≈ 10 MB download for arm64) keeps the base install unchanged. Downloading `.so` files from our own host would break Google Play's policy on executable code. The Windows lane should verify that the module works with Flutter FFI `DynamicLibrary.open` after a split install, and measure the AAB per-ABI delta.

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

## 10. Android half (Windows lane)

- **Machine:** Windows 11 laptop, Intel Core Ultra 7 155H (22 logical CPUs), 31 GB; Dart 3.12.2, Flutter 3.44.8, NDK 28.2.13676358, `sherpa_onnx` 1.13.8 (the Mac's version). Two other emulators and other agents' Gradle builds shared the host for most runs, so every emulator speed below is noisy and host-bound.
- **Date:** 2026-10-23. **Branch:** `spike-ais44-android` (from `origin/v1.2-android`). Evidence is under `spikes/ais-44-diarization/results/` (git-ignored).
- **Clips used:** the four tracked clips only (c1_2spk_turns, c2_2spk_overlap, c4_3spk_overlap, c5_2spk_similar); c3, c6 and l1 need macOS `say`. For speed and memory, `android/make_long.py` builds **a1_3spk_long** (574.7 s = (c1, c2, c4, c5) × 5 with 1 s noise-floor gaps; Samantha, Daniel and Karen keep one label across the clip) and **a2_3spk_37min** (2299 s = a1 × 4). They stand in for l1 / l2 but have 3 speakers, not 4, so their DER is not comparable with l1's 38%.
- **AVDs:** `Pixel_API_34` (API 34 x86_64, 3 GB, 4 cores) and `Pixel_API_29_2GB` (API 29 x86_64, 2 GB, the MINIMAL tier). Both API 35 x86_64 AVDs were running for other agents (emulator-5554 and -5558), and the emulator refuses a second instance of a running AVD, so API 34 replaced API 35. Nothing here depends on an API level above 24.

### 10.1 What was run

| Piece | What it is |
|---|---|
| Host reference | `bin/diarize.dart`, AOT-compiled on Windows against `sherpa_onnx_windows` 1.13.8. The four DLLs must sit next to the exe: otherwise Windows loads the system `onnxruntime.dll` (ORT 1.17.1, from Windows ML) and sherpa-onnx crashes with "API version [28] is not available". |
| `android/probe/diarize_probe.c` | A native CLI over the sherpa-onnx C API (header from tag v1.13.8, `fetch_header.sh`), built with NDK clang against the `.so` files shipped in `sherpa_onnx_android_*` 1.13.8. It prints the same JSON as `diarize.dart`, scored with the unchanged `tool/score.py`. One process per configuration; peak memory is `VmHWM` from `/proc/self/status` (whole process, one float copy of the audio, no Dart VM). `android/run_device.sh` pushes and runs the grid. |
| `android/size/` | Two throwaway Flutter apps (the `flutter create` template, and the same plus `sherpa_onnx` 1.13.8): release `--split-per-abi` APKs and an AAB each; Play download size from `bundletool get-size total`. The sherpa app also runs one diarization through the **stock Dart package** inside a Flutter release app (FFI smoke). |
| `android/pfd/` | Play Feature Delivery probe: the `.so` files move out of the base into an on-demand dynamic feature module `:diarization`, installed with `bundletool install-apks --local-testing` (FakeSplitInstallManager); Dart then loads and runs sherpa-onnx. |

### 10.2 Accuracy: identical to the Mac

DER is the same on the Mac, the Windows host, API 34 and API 29, clip by clip. (c2 shows 5.0% on Android against 4.9% on the hosts only because the probe prints segment times to 3 decimals.) Nothing Android-specific changes accuracy.

| Embedding (int8 seg) | Clustering | c1 | c2 | c4 | c5 | Mean of 4 (collar) | Right speaker count |
|---|---|---|---|---|---|---|---|
| **TitaNet-small** | threshold 0.5 or 0.7 | 2.9% | 5.0% | 37.7% | 54.9% | **25.1% (18.8%)** | 3/4 |
| TitaNet-small | oracle k | 2.9% | 5.0% | 37.7% | 54.9% | 25.1% (18.8%) | k forced; c4 still merges Karen |
| WeSpeaker ResNet34-LM | threshold 0.5 | 2.9% | 5.0% | 37.7% | 58.7% | 26.1% (19.4%) | 2/4 |
| WeSpeaker ResNet34-LM | threshold 0.7 | 58.0% | 55.6% | 73.3% | 58.7% | 61.4% | 0/4 (one speaker) |
| CAM++ (en VoxCeleb) | oracle k | 58.0% | 38.2% | 59.4% | 54.9% | 52.6% | n/a |

- The Mac's per-clip TitaNet values (c1 2.9%, c2 4.9%, c4 37.7%, c5 54.9%) are reproduced exactly. On c2, overlap recall is 98% and "both speakers right" 98%: V-S18 holds on Android.
- Long clip a1 (3 speakers, 9.6 min): TitaNet at 0.5 or 0.7 gives **22.9%** (collar 16.9%), 4 speakers found for 3, overlap recall 91%. WeSpeaker gives 26.8% at 0.5 (Windows host) and falls to 2 speakers / 59.1% at 0.7. a2 (38.3 min), TitaNet at 0.7: 24.0%. Again almost all of the error is the Samantha + Karen merge.

### 10.3 Speed (RTF, 2 threads unless noted)

| Where | TitaNet-small | WeSpeaker ResNet34-LM | WeSpeaker / TitaNet |
|---|---|---|---|
| Windows host, a1 | 0.134–0.143 | 0.414–0.466 | 3.1× |
| API 34 emulator, short clips | 0.23–0.35 | 0.29–0.57 | ≈ 1.4× |
| API 34 emulator, a1, 1 / 2 / 4 threads | 0.318 / **0.273** / 0.521 | 0.960 / **0.549** / 0.582 | 3.0× / 2.0× / 1.1× |
| API 34 emulator, a2 (38.3 min) | 0.329 | n/a | |
| API 29 2 GB emulator, short clips | 0.10–0.58 | 0.21–0.74 | |
| API 29 2 GB emulator, a1 | **0.183** | **0.382** | 2.1× |
| API 29 2 GB emulator, a2 (38.3 min) | 0.171 | n/a | |
| Flutter release app, stock Dart package, c2 (API 34) | 0.125 | n/a | |

- An x86_64 emulator on a shared laptop says nothing about ARM phone tiers: the same config moved between 0.17 and 0.33 with host load, and 4 threads was *slower* than 2 on API 34 because the host was saturated. Only the ratio is useful: **WeSpeaker is 2–3× slower than TitaNet on Android x86_64 too**, as on the Mac. Mid- and low-tier ARM RTF still needs a physical device (AIS-45).
- Model load: 0.35–1.1 s for TitaNet, 0.3–1.7 s for WeSpeaker (a cold page cache is the high end).
- Speed is linear in length: a2 (38.3 min) ran at the same RTF as a1.

### 10.4 Peak memory (VmHWM; native probe: no Dart VM, one float copy of the audio)

| Case | API 34 (3 GB) | API 29 (2 GB) |
|---|---|---|
| Models loaded, no audio: TitaNet / WeSpeaker / CAM++ | 102 / 88 / 106 MB | 98 / 82 / 94 MB |
| Short clips (25–31 s): TitaNet / WeSpeaker | 194–258 / 149–179 MB | 198–257 / 147–180 MB |
| a1, 9.6 min: TitaNet / WeSpeaker | 331 / 234 MB | 323 / 224 MB |
| **a2, 38.3 min, TitaNet** | **728 MB** | **629 MB, completed (no low-memory kill)** |
| Whole Flutter release app, c2, stock Dart package | 300 MB | n/a |

- The 38-minute run finished on the 2 GB AVD (about 0.9 GB MemAvailable at the start). Its lower peak there is the kernel reclaiming under pressure, not lower use.
- At 38 min the audio is only about 147 MB of the 728 MB, so most of the growth is sherpa-onnx's per-window state and clustering, as the Mac found. **Process long media in blocks of about 10 minutes on Android too** (about 330 MB peak per block with TitaNet), link speakers across blocks by centroid cosine (§6.2), and don't hold Dart-list copies of the samples.

### 10.5 Install and download size per ABI (stock `sherpa_onnx` 1.13.8)

Per ABI, the `.so` set is `libonnxruntime.so` + `libsherpa-onnx-c-api.so` + `libsherpa-onnx-cxx-api.so`:

| ABI | Raw | gzip -9 | Release APK (split): template → + sherpa_onnx | Install delta | Play download (bundletool): template → + sherpa_onnx | Download delta |
|---|---|---|---|---|---|---|
| **arm64-v8a** | 27,186,552 B | 10,001,372 B | 15,261,722 → 42,277,859 B | **+27.0 MB** | 7,161,222 → 17,090,102 B | **+9.9 MB** |
| armeabi-v7a | 18,839,444 B | 9,109,945 B | 12,494,122 → 31,123,401 B | +18.6 MB | 6,564,129 → 15,604,057 B | +9.0 MB |
| x86_64 | 31,007,520 B | 11,154,442 B | 16,670,400 → 47,440,820 B | +30.8 MB | 7,321,896 → 18,439,817 B | +11.1 MB |
| x86 | 32,045,876 B | 11,412,717 B | not packaged (Flutter builds arm, arm64 and x64 only) | 0 | 0 | 0 |

- The APK delta is about the raw `.so` size because AGP stores native libraries uncompressed (page-aligned). So the **installed** growth on a phone is the raw size (arm64 +27.0 MB), and the Play **download** is the compressed size (+9.9 MB). The AAB grows from 43.7 to 97.6 MB (three ABIs).
- The Dart side is negligible. The whole cost is ONNX Runtime (22.2 MB arm64) plus sherpa-onnx (4.9 MB arm64); the ASR, TTS, KWS and VAD code comes along because the prebuilt `.so` is all-in-one.

### 10.6 Zero base growth on Android: Play Feature Delivery works (verified locally)

The Mac's §6.4 proposal holds. The three `.so` files go into an on-demand dynamic feature module (`dist:on-demand`, `dist:fusing include="false"`, `hasCode="false"`) and are excluded from the base:

| Module | arm64-v8a | armeabi-v7a | x86_64 |
|---|---|---|---|
| base (download) | 7,102,860 B (template 7,161,222 B: **no growth**) | 6,510,800 B | 7,266,952 B |
| `diarization` module (download, base subtracted) | **10,028,456 B** | 9,133,457 B | 11,209,478 B |

Verified on the 2 GB API 29 AVD with `bundletool install-apks --local-testing` (FakeSplitInstallManager plus SplitCompat):

1. Only `base.apk` and `split_config.x86_64.apk` are installed, and `DynamicLibrary.open('libsherpa-onnx-c-api.so')` **fails**.
2. `SplitInstallManager.startInstall` installs the module (4.2 s locally). **dlopen still fails** at this point.
3. Kotlin calls `SplitInstallHelper.loadLibrary(ctx, "onnxruntime")`, then `"sherpa-onnx-c-api"`. After that, the stock Dart package's `initBindings()` opens the library by name, and diarizing c2 returns the same 8 segments as the Mac's §5 table.

Rules for AIS-45 on Android:

1. Ship the `.so` files only in the on-demand module and exclude them from the base (`packaging.jniLibs.excludes`). Module titles must be strings in the base module.
2. After install, load the libraries from Kotlin with `SplitInstallHelper.loadLibrary` in dependency order (onnxruntime first), then open them from Dart by name. Use `SplitCompatApplication` (or `SplitCompat.install`), plus `SplitCompat.installActivity` in the activity.
3. This needs `com.google.android.play:feature-delivery` (2.1.0 here, spike-only). That is a **new app dependency** for the owner to approve, and it adds a Play library to the Licences screen.
4. Still to check on a Play-installed build (internal app sharing): a real split install rather than SplitCompat emulation, uninstall and deferred uninstall, and that "Detect speakers" stays hidden until the module is present. Local testing cannot prove the real Play path.

### 10.7 Model choice: TitaNet-small confirmed on Android

- TitaNet-small is as accurate as WeSpeaker on every tracked clip.
- It is flat from threshold 0.5 to 0.7, while WeSpeaker falls to one speaker at 0.7.
- It is 2–3× faster on Android x86_64.
- Its costs: about 100 MB more peak memory per 10-minute block (331 against 234 MB) and a 14 MB bigger model download. Both fit the MINIMAL tier with 10-minute blocks.

**Keep the Mac's recommendation:** pyannote seg 3.0 int8 plus TitaNet-small, threshold 0.7, 2 threads. WeSpeaker stays the licence fallback; with it, use threshold 0.4–0.5, never 0.7. CAM++ stays rejected.

### 10.8 Verdict (Android)

| Question | Answer |
|---|---|
| Engine on Android | **GO.** Stock `sherpa_onnx` 1.13.8 runs on API 29 and API 34 x86_64, from a native probe and from the Dart FFI package in a Flutter release app, with the same output as the Mac and Windows |
| Model pair | **GO.** pyannote int8 plus TitaNet-small confirmed (§10.7) |
| MINIMAL tier (2 GB) | **GO with 10-minute blocks** (about 330 MB peak per block). A single 38-minute pass also finished (629 MB), but leaves little headroom |
| Speed on phones | **[VERIFY on ARM hardware, AIS-45].** Emulator RTF of 0.17–0.33 for TitaNet is host-bound, not a tier figure |
| Android install size | Stock package in the base: **+27.0 MB installed / +9.9 MB download (arm64)**, +18.6 / +9.0 MB (armeabi-v7a), +30.8 / +11.1 MB (x86_64). With Play Feature Delivery: **base +0**; the on-demand module is a 10.0 MB download and 27.2 MB installed (arm64), only once the user turns the feature on. Recommendation: the feature module (needs the owner to approve `feature-delivery`) |

### 10.9 Downloads made on this machine (owner-approved 2026-10-23)

| What | Source | Bytes | SHA-256 | Where |
|---|---|---|---|---|
| Diarization models (4, plus the segmentation tarball) | `docs/v1.2/spikes/WINDOWS_DOWNLOADS.md` §1 (downloaded by the lead) | as listed there | all match the Mac's `SHA256SUMS` | `C:/dev/models/diarization/` |
| `sherpa_onnx` 1.13.8 and its platform packages (incl. `sherpa_onnx_android_{arm64,armeabi,x86,x86_64}`, `sherpa_onnx_windows`) | pub.dev (`dart pub get`) | arm64 `.so` set 27,186,552 | per-`.so` hashes in the commit message | pub cache |
| `c-api.h` (sherpa-onnx v1.13.8) | https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/c-api/c-api.h | 167,657 | `2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce` | spike `build/` |
| bundletool 1.17.2 | https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar | 32,519,278 | `2d4ad908faea64047c1cc9cb747e6aa667c6ab192e09607bd16b67246a8cd6ae` | spike `build/tools/` |
| `com.google.android.play:feature-delivery:2.1.0` (plus `core-common`) | Google Maven (Gradle) | 312,128 (aar) | `085bd4632ccf96ceafcbfb10219ae57d604c5f680a2ea3bf860fe2b289afe5ad` | Gradle cache; spike app only |
| numpy 2.5.4 (for `tool/score.py`) | PyPI (pip, spike venv) | n/a | n/a | spike `build/venv/` |

Nothing was committed except scripts and this section. To reproduce:

1. `dart pub get`
2. `android/probe/fetch_header.sh && android/probe/build.sh x86_64`
3. `python -I -B android/make_long.py`
4. `android/run_device.sh <serial> <tag> all`
5. `python -I -B tool/score.py results/android/<tag>/*.json`
6. `android/size/measure_size.sh`, then `android/size/smoke.sh <serial>`
7. `android/pfd/build_pfd.sh && android/pfd/run_pfd.sh <serial>`
