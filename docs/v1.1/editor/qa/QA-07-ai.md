<!-- OWNER: QA-07 -->

# QA-07 · Auto captions on-device E2E and the AI device matrix

This report covers BUILD_PLAN QA-07 (M6): the ai.md §16.4 scenarios run against the real app wiring, on the simulator here and on the device matrix later. The result decides whether `DANAVIEW_AUTO_CAPTIONS` can default to on in release builds (INT-05, D-31).

**Verdict (2026-10-16): not yet.** On the iOS Simulator, 8 of the 9 default-phase steps pass. Two product defects block the rest:

- **D1:** the iOS background pause never happens once a job has run.
- **D2:** the interrupted-job notice is never shown.

All device and Android items are deferred. Keep `DANAVIEW_AUTO_CAPTIONS` off by default until D1 and D2 are fixed, this suite is green on the simulator and on one device per platform, and the device matrix in §5 is filled.

## 1. Suite

| Path | What it is |
|---|---|
| `integration_test/editor_ai/ai_captions_test.dart` | The QA-07 suite. It uses QA-00's harness (`integration_test/editor/support`): the real `MobileEditorEngine`, the real `TranscriptionServiceImpl` over danaview_whisper, and the real model store. Models are staged with `installFromFile`, so nothing is downloaded unless a download phase is asked for. |
| `integration_test/editor/tool/e2e_host.sh` (QA-00) | Host driver: staging, `--dart-define`s, the file handshake (background, kill, screenshots) and evidence. |
| `integration_test/editor_ai/ai_benchmark_test.dart` (QA-06) | The device benchmark that fills ai-eval.md §5. It is run on the same devices as §5 below. |

### Default phase: one test, one project, steps q01–q09

The default phase is a single `testWidgets`. It creates one project through Projects › New project with `frame_counter_1080p30.mp4`, `speech_10s.m4a` and the 60 s English clip, then runs the steps in order. Each step prints `DV_QA07_STEP <id> PASS|FAIL`. A failed step is recovered (open sheets closed, running job cancelled, edits undone) and the next step still runs. The test fails at the end and lists every failed step. `--dart-define=DV_QA07_ONLY=q03,q06` runs a subset.

The suite uses one project because a second project created through the New project sheet in a later `testWidgets` of the same process never opens (see D3).

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
| `job-kill` | Starts captions on the 60 s clip. At ≥ 40 % transcribed, it saves the project id and asks the host to kill the app (§16.4 #4). |
| `job-resume` | Relaunches. Checks that `resumableFor` holds the record, opens the project, waits for the interrupted-job notice (`captions-interrupted`), taps Resume, and asserts that the job continues from its checkpoint rather than from zero. |
| `download` | **Real network** (`DV_QA07_NETWORK=true`). Starts with no model: consent → Download, then the host kills the app at ≥ 30 % of the bytes. |
| `download-resume` | **Real network.** Checks that the partial file survived. Consent → Download continues from the partial file (`downloadResumed`), the sha256 is verified, the model is installed, and the job runs. |

## 2. Running it

The 60 s English clip and its reference text are generated on the Mac. They are not committed, and the text is our own:

```sh
mkdir -p ~/danaview-qa07 && cd ~/danaview-qa07
cat > qa07-60s-en.txt <<'EOF'
Good morning, and thank you for joining this short walk through our new video editor. Before we start, make sure the phone has enough free space and that the battery is charged. Today we will open a project, trim the first clip, and add a title at the start. Next we will place some music under the whole video and lower its volume so that the voice stays clear. After that we will create captions automatically. The app listens to the speech on the phone itself, so nothing leaves the device. When the captions are ready, you can read them on the timeline, fix a word by tapping it, or change the layout to one line at a time. If you change your mind, a single undo removes every caption that was added. Finally we will export the video at high quality, with the captions burned into the picture, and save a copy to the photo library. That is all for today. Thank you for watching, and see you next time.
EOF
say -v Samantha -r 100 -o a.aiff -f qa07-60s-en.txt && afconvert -f m4af -d aac -c 1 a.aiff qa07-60s-en.m4a && rm a.aiff   # 60.19 s, mono AAC
```

The models are the approved, SHA-256-verified files in `/Users/besaoct/danaview-models` (tiny q5_1 + silero VAD). They are never downloaded again by this suite and never copied into the repo. For a Balanced run, add `ggml-base-q5_1.bin` to that folder.

```sh
D=<udid>; M=/Users/besaoct/danaview-models; C=~/danaview-qa07/qa07-60s-en.m4a
H=integration_test/editor/tool/e2e_host.sh
# iOS Simulator (this Mac): default phase (q01–q09)
DV_E2E_PHASE_TIMEOUT=3600 $H -p ios -d $D -m $M -D DV_QA07_CLIP=$C -D DV_QA07_TIER=balanced run integration_test/editor_ai/ai_captions_test.dart
# kill and resume (the job-kill run is reported FAIL by e2e_host because the app ends; check state-qa07-job.json)
$H -p ios -d $D -m $M -D DV_QA07_CLIP=$C -D DV_QA07_PHASE=job-kill   run integration_test/editor_ai/ai_captions_test.dart
$H -p ios -d $D -m $M -D DV_QA07_CLIP=$C -D DV_QA07_PHASE=job-resume run integration_test/editor_ai/ai_captions_test.dart
# real download (device on Wi-Fi only, once per platform)
$H -p ios -d $D -D DV_QA07_NETWORK=true -D DV_QA07_PHASE=download        run integration_test/editor_ai/ai_captions_test.dart
$H -p ios -d $D -D DV_QA07_NETWORK=true -D DV_QA07_PHASE=download-resume run integration_test/editor_ai/ai_captions_test.dart
# Android (Windows lane): stage models and the clip, then the same commands with -p android -d emulator-5554
$H -p android -d emulator-5554 stage && $H -p android -d emulator-5554 stage-models <models dir>
adb shell mkdir -p /sdcard/Android/data/com.vecvel.danaview/files/e2e_qa07 && adb push qa07-60s-en.m4a qa07-60s-en.txt /sdcard/Android/data/com.vecvel.danaview/files/e2e_qa07/
$H -p android -d emulator-5554 run integration_test/editor_ai/ai_captions_test.dart
```

On a device, `DV_QA07_BUDGET_MS` should be set to the ai-eval.md §5 figure for that device and tier. The default budget is sized for a simulator: Fast ≤ 1× real time, Balanced ≤ 2× real time, plus 20 s.

Evidence lands in `build/e2e/<platform>/<device>/`: `logs/ai_captions_test.log` (the `DV_QA07_STEP` and `DV_QA07_REPORT` lines), `screens/*qa07*`, and `files/` (the exports, the SRT/VTT handoffs and `state-qa07-*.json`).

## 3. Results: iOS Simulator, 2026-10-16

Setup: iPhone 16 simulator on iOS 26.5 (`6663101E-6BE7-47D4-B3B8-055700BF2E02`), Xcode 26.6, Flutter 3.44, debug build. Models were tiny q5_1 + silero v6.2.0 from `/Users/besaoct/danaview-models`; base q5_1 was not staged, so q05–q07 ran with **Fast** (reported in the log). The run is the last full default-phase run, 2 min 22 s after the build.

| Step | Result | Evidence (`DV_QA07_REPORT`) |
|---|---|---|
| q01 consent before network | **pass** | Consent shown with 33,037,771 B disclosed (tiny + VAD); 0 HTTP clients before and after "Not now"; screenshot `qa07_q01_consent` |
| q02 language | **pass** | Explicit en: 3 cues. Detect: 3 cues, `en` p = 0.9976 (confident) |
| q03 undo / SRT+VTT / regenerate / burn-in | **pass** | One undo removes all and redo restores them. SRT and VTT round trip of 3 cues. Re-split to Single line in 282 ms (3 → 5 cues, same words). Full regenerate 1.1 s. Burn-in changed pixels at cue midpoints 1.0 s / 4.1 s / 8.2 s (English / Arabic / Japanese) = 598 / 284 / 385, and 0 at 10.3 s (no cue). Export A conformant (VideoToolbox H.264, 70.17 s). |
| q04 split + 2× | **pass** | 3 cues. Left piece 0–5 s, 2× piece 5–7.5 s, 1 cue in the 2× piece ending within the linger |
| q05 60 s English | **pass (Fast, plumbing)** | 60.17 s audio, run 4.6 s (budget 80.2 s), 16 cues, 171 words, **WER 0.6 %** |
| q06 thermal and export pausing | **pass** | Thermal critical before generation: paused `thermal`, 0 µs processed, no captions for 3 s, then resumed with the same words as q05. A job started during an export reported `waitingForExport` and finished with the same words. Screenshots `qa07_q06_thermal`, `qa07_q06_waiting_for_export` |
| q07 background | **FAIL (D1)** | The governor saw no background. The job ran to the end while the app was backgrounded (0 → 60.19 s processed in the 8 s); the result was still identical to q05. In an isolated run of q07 the probe step **did** see the background before any job ran, and did not once the job had opened the whisper runtime. |
| q08 offline | **pass** | 3 cues with every connection refused; 0 HTTP clients |
| q09 delete → consent | **pass** | Model deleted → consent view again, 0 HTTP clients |
| job-kill → job-resume | **FAIL (D2)** | Killed at 48 % (22.8 s processed). After relaunch `resumableFor` returns the record, but the editor never shows `captions-interrupted`: the notice widget is not placed in any screen. |
| download → download-resume | deferred: real network, device lane | Runnable as written. It never runs on this Mac: the models are approved and pre-staged, and nothing is downloaded again. |

Earlier runs during this ticket fixed test-side issues: the subtitle export panel shows its track list only when there is more than one track; a selection of several clips is captioned from the tool tile, not the context menu; a 60 s unit is a single chunk on a fast device, so pauses are triggered before generation starts. None of these were product defects.

## 4. Defects (owned by other tickets)

| # | Owner | Defect | Evidence |
|---|---|---|---|
| D1 | AI-13 (`TranscriptionServiceImpl` default `openRuntime`) / AI-07 (`WhisperRuntime.open`) / AI-06 (`WhisperDeviceChannel`) / INT-04 (`createAutoCaptions` wiring) | **The governor stops receiving device events once a job opens the whisper runtime.** `WhisperRuntime.open()` builds its own `WhisperDeviceChannel()` (runtime.dart:37), and `NativeWhisperRuntime` listens to its `events`. That calls `receiveBroadcastStream()` again on the same `EventChannel('danaview_whisper/device/events')`. The new listener replaces the Dart message handler of the governor's stream (main.dart's channel) and makes the plugin run `onCancel`/`onListen` again. From then on, lifecycle, thermal, low-power and memory events reach only the runtime. Consequences: the iOS background pause (ai.md §6.3) never happens, real thermal pauses never happen, and memory warnings never reach the service. **Fix:** share one channel, by passing `openRuntime: () => WhisperRuntime.open(channel: device)` in `createAutoCaptions`, and/or make `WhisperDeviceChannel.events` a process-wide broadcast. | q07 log: probe before any job "governor saw the background yes" (isolated run), versus "NO" after jobs (full run); job pauses `[]` while backgrounded. |
| D2 | UX-38 (interrupted-job notice) / whoever owns the editor screen hosting it | **`InterruptedNotice` is never mounted.** It exists only in `interrupted_notice.dart` and its widget tests, so "Auto captions were interrupted. Resume?" (ai.md §8.6, §11.5) is never shown, although `resumableFor` returns the record after a kill. | job-resume: `resumableFor` returns the record; `captions-interrupted` is not on screen within 30 s. |
| D3 | QA-00 (E2E harness) / INT-02 (app router) | In one `flutter test` process, a project created through Projects › New project in a **second** `testWidgets` never opens. The sheet closes and no project appears. QA-07 works around it with one project per process, and QA-00's files each create in one test. Suspected cause: the second `DanaviewApp` reuses `appNavigatorKey` and the router state of the first. | Diagnostic screens before the restructure (logs of runs 3–4): sheet with picks → Projects "1 project", 120 s timeout. |
| D4 | QA-00 (`s08_auto_captions_test.dart`) | s08 waits for `subtitleIo.exportTrack.<id>`, but the subtitle export panel shows the track list only when the project has more than one subtitle track. s08 therefore times out on its SRT step. It also taps a language candidate without `captions-continue`. | QA-07 q03 hit the same wait. |

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
| Real thermal pause observed (not injected) | deferred: no device available, and blocked by D1 |
| iOS background pause/resume with an identical result | **failing (D1)** on the simulator; deferred on device |
| Android FGS lease keeps a job running in the background | deferred: Windows lane (q07 Android branch) |
| Real download with resume after a kill | deferred: device lane (`download` / `download-resume`) |
| Burn-in golden frame compare between preview and export (§16.4 #8) | The export side is covered by q03 (Arabic and Japanese cues burned). Preview-vs-export parity is QA-03's method; deferred on device. |

## 6. Release flag

`DANAVIEW_AUTO_CAPTIONS` **must stay off by default** (D-31) until all of the following hold:

1. D1 and D2 are fixed.
2. This suite's default phase is green on the iOS Simulator and the Android Emulator.
3. The job-kill/job-resume phases pass.
4. The device matrix above has at least one iOS and one Android device row green, including Balanced within budget and one real download with resume.

INT-05 should flip the flag only after this report is updated with those results.
