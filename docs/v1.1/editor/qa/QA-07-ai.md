<!-- OWNER: QA-07 -->

# QA-07 · Auto captions on-device E2E and the AI device matrix

This report covers BUILD_PLAN QA-07 (M6): the ai.md §16.4 scenarios run against the real app wiring, on the simulator here and on the device matrix later. The result decides whether `DANAVIEW_AUTO_CAPTIONS` can default to on in release builds (INT-05, D-31).

**Verdict (2026-10-16, re-run after FIX-QA07): iOS Simulator green; the flag is not yet cleared for release.** FIX-QA07 fixed D1 to D4. On the iOS Simulator, all 9 default-phase steps pass. job-kill → job-resume passes, and the resume starts from the checkpoint. QA-00 s08 passes.

`DANAVIEW_AUTO_CAPTIONS` may default to on only after the rest of the §6 conditions are met:

- the Android Emulator run (Windows lane);
- one iOS device row and one Android device row green, including Balanced within budget and one real download with resume.

Until then it stays off by default (D-31). Every device and Android item below is deferred.

## 1. Suite

| Path | What it is |
|---|---|
| `integration_test/editor_ai/ai_captions_test.dart` | The QA-07 suite. It uses QA-00's harness (`integration_test/editor/support`): the real `MobileEditorEngine`, the real `TranscriptionServiceImpl` over danaview_whisper, and the real model store. Models are staged with `installFromFile`, so nothing is downloaded unless a download phase is asked for. |
| `integration_test/editor/tool/e2e_host.sh` (QA-00) | Host driver: staging, `--dart-define`s, the file handshake (background, kill, screenshots) and evidence. |
| `integration_test/editor_ai/ai_benchmark_test.dart` (QA-06) | The device benchmark that fills ai-eval.md §5. It is run on the same devices as §5 below. |

### Default phase: one test, one project, steps q01–q09

The default phase is a single `testWidgets`. It creates one project through Projects › New project with `frame_counter_1080p30.mp4`, `speech_10s.m4a` and the 60 s English clip, then runs the steps in order. Each step prints `DV_QA07_STEP <id> PASS|FAIL`. A failed step is recovered (open sheets closed, running job cancelled, edits undone) and the next step still runs. The test fails at the end and lists every failed step. `--dart-define=DV_QA07_ONLY=q03,q06` runs a subset.

The suite uses one project per process. The original reason was D3, and the layout was kept after FIX-QA07 hardened `E2eApp.launch` because one wiring per process is also faster.

| Step | ai.md §16.4 / QA-07 item | What it drives and asserts |
|---|---|---|
| q01 | Consent before any network access | Starts from no installed model (fresh install). Create → the consent view names the model (disclosure id and bytes). There are 0 dart:io HTTP clients before consent and 0 after "Not now", and no partial download. The model status stays missing. |
| q02 | Language: explicit and detect | English is picked in the language picker: the provenance says `en`, not detected, and the detecting phase is skipped. "Detect automatically": `en` is detected with confidence (if the low-confidence question appears, it is answered English). |
| q03 | Undo, SRT/VTT, Regenerate, burn-in (§16.4 #6, #7, #8) | (a) One undo removes every generated cue; redo restores them. (b) SRT and VTT exports, made through the subtitle export panel, parse back to the same cues. (c) Regenerate › Re-split to another layout applies from the cached transcript in under 2 s, keeps the same words, puts one line per cue, and undoes in one step. (d) Regenerate › Transcribe again replaces the lane (same track count, new `generatedAt`, a transcribing phase seen) and undoes in one step. (e) Burn-in uses QA-00 scenario 7's method. Cue 1 keeps its generated English text, cue 2 is set to Arabic and cue 3 to Japanese. Export A has burn-in on and export B has it off. Frames are pulled at each cue midpoint: the subtitle safe area (bottom 30 %) differs (more than 150 changed pixels) and is identical at a time no cue covers (fewer than 60). Export A also passes conformance (720p H.264 MP4 with AAC, duration ± 1 frame). |
| q04 | Split clip plus 2× speed mapping (§16.4 #5) | `speech_10s` is split at 5 s and the right piece is set to 2×. Both pieces are captioned ("Selected clips"). Every cue starts on the captioned clips and ends no later than the clip end plus the segmenter's linger (≤ 1 s). The 2× piece is captioned, and its cues end with it, so the speed map was applied. Undo returns to one clip. |
| q05 | 60 s English Balanced run within the budget (§16.4 #1) | The 60 s clip is captioned with `DV_QA07_TIER` (falls back to Fast when the Balanced model is not staged, and says so). Asserts run time ≤ budget, cue count in range, and WER ≤ 15 % against the reference text. The result is kept as the reference for q06 and q07. |
| q06 | Thermal and export pausing observed | **Thermal:** thermal critical is injected (`ResourceGovernor.debugDeviceEvent`) before generation starts. The job reports `paused: thermal`, processes nothing and adds nothing for 3 s. Back to nominal, it resumes after the 10 s recovery and gives the same words as q05. **Export:** an export is started through the export sheet, then captions are started. The job reports `waitingForExport`, transcribes nothing until the export finishes, then completes with the same words as q05. |
| q07 | iOS background pause/resume, Android FGS lease (§16.4 #3) | The host backgrounds the app for 8 s mid-job (`e2e_host` `background`). **iOS:** the governor sees the background, generation pauses and resumes, and the result is identical to q05. **Android:** no background pause, and progress advances while in the background (FGS lease). A probe step first records whether the governor sees a background/foreground cycle at all. |
| q08 | Offline after download | Every `HttpClient` creation throws (an `HttpOverrides` that refuses connections). A job still completes, and no client was created. |
| q09 | Deleting the model asks for consent again | Captions run with the model, then the model is deleted (`TranscriptionService.deleteModel`, the call behind Settings › Storage › Speech model). The next Create shows the consent view, with 0 HTTP clients. |

### Host-driven phases (`DV_QA07_PHASE`)

| Phase | What it does |
|---|---|
| `job-kill` | Starts captions on the **long clip** (`DV_QA07_LONG_CLIP`, about 6 min, so more than one ≈ 180 s chunk). At ≥ 215 s transcribed, which is past the first chunk's checkpoint (165–195 s), it saves the project id and asks the host to kill the app (§16.4 #4). A 60 s clip is a single chunk, which has no checkpoint before it ends, so a kill would only test that the record survives. |
| `job-resume` | Relaunches and checks that `resumableFor` holds the record. Opens the project and waits for the interrupted-job notice (`captions-interrupted`, screenshot `qa07_job_resume_notice`), then taps Resume. Asserts the resume point: the first transcribing progress that has audio processed is ≥ 165 s (the first checkpoint's end) and before the kill point. The phase change itself is emitted before the checkpoint is replayed, so it reads 0 and is not used. Also asserts that the result covers the whole clip, from the checkpointed chunk's cues through the end. |
| `download` | **Real network** (`DV_QA07_NETWORK=true`). Starts with no model: consent → Download, then the host kills the app at ≥ 30 % of the bytes. |
| `download-resume` | **Real network.** Checks that the partial file survived. Consent → Download continues from the partial file (`downloadResumed`), the sha256 is verified, the model is installed, and the job runs. |

## 2. Running it

The 60 s English clip, its reference text and the long clip (the same text six times, 362.6 s) are generated on the Mac. They are not committed, and the text is our own:

```sh
mkdir -p ~/danaview-qa07 && cd ~/danaview-qa07
cat > qa07-60s-en.txt <<'EOF'
Good morning, and thank you for joining this short walk through our new video editor. Before we start, make sure the phone has enough free space and that the battery is charged. Today we will open a project, trim the first clip, and add a title at the start. Next we will place some music under the whole video and lower its volume so that the voice stays clear. After that we will create captions automatically. The app listens to the speech on the phone itself, so nothing leaves the device. When the captions are ready, you can read them on the timeline, fix a word by tapping it, or change the layout to one line at a time. If you change your mind, a single undo removes every caption that was added. Finally we will export the video at high quality, with the captions burned into the picture, and save a copy to the photo library. That is all for today. Thank you for watching, and see you next time.
EOF
say -v Samantha -r 100 -o a.aiff -f qa07-60s-en.txt && afconvert -f m4af -d aac -c 1 a.aiff qa07-60s-en.m4a && rm a.aiff   # 60.19 s, mono AAC
(for i in 1 2 3 4 5 6; do cat qa07-60s-en.txt; echo; done) > qa07-long-en.txt
say -v Samantha -r 100 -o b.aiff -f qa07-long-en.txt && afconvert -f m4af -d aac -c 1 b.aiff qa07-long-en.m4a && rm b.aiff   # 362.65 s
```

The models are the approved, SHA-256-verified files in `/Users/besaoct/danaview-models` (tiny q5_1 + silero VAD). They are never downloaded again by this suite and never copied into the repo. For a Balanced run, add `ggml-base-q5_1.bin` to that folder.

```sh
D=<udid>; M=/Users/besaoct/danaview-models; C=~/danaview-qa07/qa07-60s-en.m4a; LC=~/danaview-qa07/qa07-long-en.m4a
H=integration_test/editor/tool/e2e_host.sh
# iOS Simulator (this Mac): default phase (q01–q09)
DV_E2E_PHASE_TIMEOUT=3600 $H -p ios -d $D -m $M -D DV_QA07_CLIP=$C -D DV_QA07_TIER=balanced run integration_test/editor_ai/ai_captions_test.dart
# kill and resume (the job-kill run is reported FAIL by e2e_host because the app ends; check state-qa07-job.json)
$H -p ios -d $D -m $M -D DV_QA07_LONG_CLIP=$LC -D DV_QA07_PHASE=job-kill   run integration_test/editor_ai/ai_captions_test.dart
$H -p ios -d $D -m $M -D DV_QA07_LONG_CLIP=$LC -D DV_QA07_PHASE=job-resume run integration_test/editor_ai/ai_captions_test.dart
# QA-00 scenario 8 (auto captions) on the same simulator
$H -p ios -d $D -m $M run s08
# real download (device on Wi-Fi only, once per platform)
$H -p ios -d $D -D DV_QA07_NETWORK=true -D DV_QA07_PHASE=download        run integration_test/editor_ai/ai_captions_test.dart
$H -p ios -d $D -D DV_QA07_NETWORK=true -D DV_QA07_PHASE=download-resume run integration_test/editor_ai/ai_captions_test.dart
# Android (Windows lane): stage models and the clip, then the same commands with -p android -d emulator-5554
$H -p android -d emulator-5554 stage && $H -p android -d emulator-5554 stage-models <models dir>
adb shell mkdir -p /sdcard/Android/data/com.vecvel.danaview/files/e2e_qa07 && adb push qa07-60s-en.m4a qa07-60s-en.txt qa07-long-en.m4a /sdcard/Android/data/com.vecvel.danaview/files/e2e_qa07/
$H -p android -d emulator-5554 run integration_test/editor_ai/ai_captions_test.dart
```

On a device, `DV_QA07_BUDGET_MS` should be set to the ai-eval.md §5 figure for that device and tier. The default budget is sized for a simulator: Fast ≤ 1× real time, Balanced ≤ 2× real time, plus 20 s.

Evidence lands in `build/e2e/<platform>/<device>/`: `logs/ai_captions_test.log` (the `DV_QA07_STEP` and `DV_QA07_REPORT` lines), `screens/*qa07*`, and `files/` (the exports, the SRT/VTT handoffs and `state-qa07-*.json`).

## 3. Results: iOS Simulator, 2026-10-16 (QA-07-RERUN, after FIX-QA07)

Setup: iPhone 16 simulator on iOS 26.5 (`6663101E-6BE7-47D4-B3B8-055700BF2E02`), Xcode 26.6, Flutter 3.44, debug build. Models were tiny q5_1 + silero v6.2.0, staged from `/Users/besaoct/danaview-models` with `e2e_host.sh stage-models`; nothing was downloaded. base q5_1 is not on this Mac, so q05–q07 ran with **Fast**, and the log says so.

The default phase was run twice in this session, with all 9 steps passing in both runs (2 min 50 s after the build). The figures below come from the last run. The first attempt hung on a white screen before the first frame because `flutter test` never attached to the VM service. It was stopped and re-run, and this is a tooling flake, not a product defect.

| Step | Result | Evidence (`DV_QA07_REPORT`) |
|---|---|---|
| q01 consent before network | **pass** | Consent shown with 33,037,771 B disclosed (tiny + VAD). 0 HTTP clients before and after "Not now". Screenshot `qa07_q01_consent`. |
| q02 language | **pass** | Explicit en: 3 cues. Detect: 3 cues, `en` p = 0.9976 (confident). |
| q03 undo / SRT+VTT / regenerate / burn-in | **pass** | One undo removes all, and redo restores them. SRT and VTT round trip 3 cues. Re-split to Single line in 440 ms (3 → 5 cues, same words). Full regenerate in 1.2 s. Burn-in changed pixels at the cue midpoints 1.0 s / 4.1 s / 8.2 s (English / Arabic / Japanese) = 598 / 284 / 385, and 0 at 10.3 s (no cue). Export A is conformant. |
| q04 split + 2× | **pass** | 3 cues. Left piece 0–5 s, 2× piece 5–7.5 s, and 1 cue in the 2× piece ending within the linger. |
| q05 60 s English | **pass (Fast, plumbing)** | 60.17 s audio, run 4.1 s (budget 80.2 s), 16 cues, 171 words, **WER 0.6 %**. |
| q06 thermal and export pausing | **pass** | Thermal critical before generation: paused `thermal`, 0 µs processed and no captions for 3 s, then resumed with the same words as q05. A job started during an export reported `waitingForExport` and finished with the same words. Screenshots `qa07_q06_thermal` and `qa07_q06_waiting_for_export`. |
| q07 background (iOS) | **pass (D1 fixed)** | Probe: the governor saw the background. Mid-job, the governor went `[background, running]`, the job reported pause `[background]`, and the result was identical to q05. In the first run, processed stayed 0 → 0 across the 8 s in the background. In the second run, the post-return sample (taken 0.5 s after the return) already showed the full 60.19 s, because the single-chunk job finished right after it resumed. |
| q08 offline | **pass** | 3 cues with every connection refused, and 0 HTTP clients. |
| q09 delete → consent | **pass** | Model deleted → consent view again, with 0 HTTP clients. |
| job-kill → job-resume | **pass (D2 fixed)** | Long clip, 362.6 s. Killed at 221.6 s processed (the e2e_host FAIL is expected because the app ends). `<key>.partial.jsonl` held chunk 0 = 0–167.2 s. After relaunch, `resumableFor` returns the record and the editor shows "Auto captions were interrupted. Resume?" (screenshot `qa07_job_resume_notice`). Resume: the first progress with audio processed is **167.2 s**, exactly the checkpoint end, so the work lost is the 54 s after the checkpoint (less than one chunk). The result is 92 cues covering 0–362.6 s. |
| QA-00 s08 | **pass (D4 fixed)** | 3 cues ("Welcome to the video editor test, …"). The SRT exports through the single-track panel and parses back, and one undo removes all. Screenshot `s08_after_undo`. |
| download → download-resume | deferred: real network, device lane | Runnable as written. It never runs on this Mac: the models are approved and pre-staged, and nothing is downloaded again. |

Test-side change in this re-run: job-kill/job-resume moved from the 60 s clip to the long clip. The old run passed on the phase weights alone (fraction 0.2 at the first transcribing sample), with no checkpoint involved, because a 60 s unit is one chunk. The phases now assert the resume point itself.

The first QA-07 run (before FIX-QA07) also fixed test-side issues:

- The subtitle export panel shows its track list only when there is more than one track.
- A selection of several clips is captioned from the tool tile, not from the context menu.
- On a fast device a 60 s unit is a single chunk, so pauses are triggered before generation starts.

## 4. Defects (owned by other tickets)

All four were fixed by FIX-QA07 and re-verified on the iOS Simulator in QA-07-RERUN. D5 is new and minor.

| # | Owner | Defect | Evidence |
|---|---|---|---|
| D1 | AI-13 (`TranscriptionServiceImpl` default `openRuntime`) / AI-07 (`WhisperRuntime.open`) / AI-06 (`WhisperDeviceChannel`) / INT-04 (`createAutoCaptions` wiring) | **The governor stops receiving device events once a job opens the whisper runtime.** `WhisperRuntime.open()` builds its own `WhisperDeviceChannel()` (runtime.dart:37), and `NativeWhisperRuntime` listens to its `events`. That calls `receiveBroadcastStream()` again on the same `EventChannel('danaview_whisper/device/events')`. The new listener replaces the Dart message handler of the governor's stream (main.dart's channel) and makes the plugin run `onCancel`/`onListen` again. From then on, lifecycle, thermal, low-power and memory events reach only the runtime. Consequences: the iOS background pause (ai.md §6.3) never happens, real thermal pauses never happen, and memory warnings never reach the service. **Fix:** share one channel, by passing `openRuntime: () => WhisperRuntime.open(channel: device)` in `createAutoCaptions`, and/or make `WhisperDeviceChannel.events` a process-wide broadcast. **Status: fixed (FIX-QA07, shared device events). q07 passes.** | q07 log: probe before any job "governor saw the background yes" (isolated run), versus "NO" after jobs (full run); job pauses `[]` while backgrounded. |
| D2 | UX-38 (interrupted-job notice) / whoever owns the editor screen hosting it | **`InterruptedNotice` is never mounted.** It exists only in `interrupted_notice.dart` and its widget tests, so "Auto captions were interrupted. Resume?" (ai.md §8.6, §11.5) is never shown, although `resumableFor` returns the record after a kill. **Status: fixed (FIX-QA07, `InterruptedCaptionsBanner` in `editor_screen.dart`). job-resume passes.** | job-resume: `resumableFor` returns the record; `captions-interrupted` is not on screen within 30 s. |
| D3 | QA-00 (E2E harness) / INT-02 (app router) | In one `flutter test` process, a project created through Projects › New project in a **second** `testWidgets` never opens. The sheet closes and no project appears. QA-07 works around it with one project per process, and QA-00's files each create in one test. Suspected cause: the second `DanaviewApp` reuses `appNavigatorKey` and the router state of the first. **Status: fixed in the harness (FIX-QA07, `E2eApp.launch` settles the previous wiring; `test/fix_qa07_second_project_test.dart`). QA-07 keeps one project per process, so this was not re-exercised here.** | Diagnostic screens before the restructure (logs of runs 3–4): sheet with picks → Projects "1 project", 120 s timeout. |
| D4 | QA-00 (`s08_auto_captions_test.dart`) | s08 waits for `subtitleIo.exportTrack.<id>`, but the subtitle export panel shows the track list only when the project has more than one subtitle track. s08 therefore times out on its SRT step. It also taps a language candidate without `captions-continue`. **Status: fixed (FIX-QA07). s08 passes.** | QA-07 q03 hit the same wait. |
| D5 (minor) | AI-13 (`resumableFor` / `doneFraction`) and UX-38 (notice copy) | **The interrupted notice says "The work done so far is kept" with no percent, although 46 % of the clip was checkpointed.** `doneFraction` counts whole finished units only, so a single long unit with checkpointed chunks reads 0 %. Resume itself is correct (it continues at 167.2 s). Suggestion: include the checkpointed range of the unit in progress in `doneFraction`. | job-resume: "service record after the kill: 0% done" (killed at 221.6 s, checkpoint 0–167.2 s); screenshot `qa07_job_resume_notice`. |

## 5. Device matrix (ai.md §16.4, release-candidate gate)

For every device: `ai_captions_test.dart` default phase with `DV_QA07_TIER=balanced` and `DV_QA07_BUDGET_MS` from ai-eval.md §5; the job-kill and job-resume phases; one download and download-resume per platform on Wi-Fi; and `ai_benchmark_test.dart` (QA-06).

| Device | SoC / RAM | Status |
|---|---|---|
| iPhone XR | A12, 3 GB | deferred: no device available |
| iPhone 11 | A13 | deferred: no device available |
| iPhone 13 | A15 | deferred: no device available |
| iPhone 15 | A16 | deferred: no device available |
| iPhone SE 3 | A15 | deferred: no device available |
| Galaxy A15 | Helio G99 | deferred: Windows lane, no device available |
| Pixel 6a | Tensor G1 | deferred: Windows lane, no device available |
| Galaxy A55 | Exynos 1480 | deferred: Windows lane, no device available |
| Redmi Note 13 Pro | SD 7s Gen 2 | deferred: Windows lane, no device available |
| Pixel 8 | Tensor G3 | deferred: Windows lane, no device available |
| armeabi-v7a-only device | — | deferred: Windows lane. Expect the unsupported path (`captions-unsupported`). |
| Android Emulator (API 35 x86_64) | — | deferred: Windows lane. Command: `$H -p android -d emulator-5554 run integration_test/editor_ai/ai_captions_test.dart`, plus the job-kill/job-resume phases (§16.4 #4 is the Android kill case) |

### Items only a device can close

| Item | Status |
|---|---|
| 60 s English **Balanced** within the measured budget (on device, against ai-eval.md §5) | deferred: no device available (simulator ran Fast; base model not staged) |
| Cue edges within ± 300 ms of human timing (§16.4 #1) | deferred: needs a human-timed reference; ai-eval.md cue boundary error covers it nightly |
| 30-minute Accurate soak: thermal, memory, no jetsam, ETA error < 30 % after 25 % (§16.4 #2) | deferred: no device available (needs the small model and a 30 min clip) |
| Real thermal pause observed (not injected) | deferred: no device available (D1 no longer blocks it) |
| iOS background pause/resume with an identical result | **pass** on the simulator (q07); deferred on device |
| Android FGS lease keeps a job running in the background | deferred: Windows lane (q07 Android branch) |
| Real download with resume after a kill | deferred: device lane (`download` / `download-resume`) |
| Burn-in golden frame compare between preview and export (§16.4 #8) | The export side is covered by q03 (Arabic and Japanese cues burned). Preview-vs-export parity is QA-03's method; deferred on device. |

## 6. Release flag

`DANAVIEW_AUTO_CAPTIONS` **must stay off by default** (D-31) until all of the following hold:

1. D1 and D2 are fixed. **Done** (FIX-QA07, re-verified 2026-10-16).
2. This suite's default phase is green on the iOS Simulator and the Android Emulator. **iOS Simulator done**; the Android Emulator is pending (Windows lane).
3. The job-kill/job-resume phases pass. **iOS Simulator done**; the Android Emulator is pending (the §16.4 #4 Android kill case).
4. The device matrix above has at least one iOS and one Android device row green, including Balanced within budget and one real download with resume.

INT-05 should flip the flag only after this report is updated with those results.
