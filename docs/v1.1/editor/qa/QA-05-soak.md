<!-- OWNER: QA-05 -->

# QA-05 · Robustness soak

This report covers BUILD_PLAN QA-05 (M6). The ticket asks for a 1 h random-edit soak on one iOS device and one Android device. The soak runs scripted random commands, gestures, play and scrub, export starts and cancels, and Auto captions with the tiny model. It adds interruptions (calls or Siri, audio route changes, background and foreground), low storage, media going offline mid-session, and process death during each job type (proxy, reverse, freeze, export, captions, autosave).

The acceptance criteria are:

- no crash
- no unhandled exception
- memory growth of 10 % or less over the hour
- every interrupted job recovers, or reports "interrupted" exactly once
- the project always reopens valid

**Status (2026-10-17 10:27 IST): iOS side green.** The seeded soak (seed 5150) and the process-death
chain both pass on the FIX-IOS-D7 code (§2). D1–D7 are all fixed. **Android side (D11 re-run, 2026-10-22, code d2600495, API 35 emulator):
not certified** (§A000). D11 is fixed: the selftest passes, the death chain passes 7/7, and seeded
run a passes with 0 failures (441 ops, +0.8 % memory, every offline and call op green, #26 and
#271 included). But seeded run b crashed the app at 17:59:35 with a SIGSEGV on the `danaview-pcm`
thread while the reverse job closed its `PcmStream` (**D12**, Android lane, native crash, §A000.4).
A fix agent (Android lane) is working on D12; both seeded soaks run again on the fix code. A
re-run of b was voided because the laptop left mains power and went into standby mid-run.
**Previous Android status (final 1.1 re-run, 2026-10-22, code 8725e25c): not certified** (§A00). The selftest passes (30
checks, W4b included), and the process-death chain passes 7/7 with `soak_host.py` unmodified and
opening the shared folders itself. Op #262 is fixed (f11d4abc). But both seeded soak runs (seed
5150) fail: the editor stays in "preview degraded" ("Preview ¼") and the next ready-wait times out,
at op #271 offline in runs a and b and at op #26 call in run a (D11: the governor stays at quarter
while paused and `waitReady` needs `ready`; Mac decision, §A00.4). Every other criterion is green in both runs.
**Previous Android status (034a0d3): not certified** (§A0). The process-death chain passes 7/7, and seeded run
b passes (0 failures, −1.5 % memory). D8 and D9 are confirmed fixed, and W1–W7 work. But seeded run
a fails one op: #262, a seek right after a reverse acked frame 0 (a D10 residual, Android lane). An
earlier run on the same code (a1) crashed with SIGSEGV during an export cancel, and the cause is not
proven. `soak_host.py` also still needs a manual folder step on Android after its own uninstall (W4b,
Mac). The d680bd3 round (§A) is kept as history. Still deferred: the 1 h runs and the device-only
steps (§6).

## 1. Suite

| Path | What it is |
|---|---|
| `integration_test/editor_soak/soak_test.dart` | The random soak. It is one `testWidgets` that drives the real app for `DV_SOAK_MINUTES` minutes (default 60) with a seeded sequence of 30 op types. It uses QA-00's `E2eApp` and `E2eEditor`, so it has the real app wiring and the production engine. |
| `integration_test/editor_soak/process_death_test.dart` | Process death during each job type. The phases are `die-autosave`, `die-proxy`, `die-reverse`, `die-freeze`, `die-export`, `die-captions` and `verify`. Each `die-*` phase first verifies the job the previous phase killed, then starts its own job and is killed by the host. |
| `integration_test/editor_soak/support/soak.dart` | Shared code: configuration, the `DV_SOAK` report lines and JSON summaries, the RSS sampler and the memory verdict, the framework-error recorder, sheet dismissal, the store-level validity check, and the recovery-aware project open. |
| `integration_test/editor_soak/tool/soak_host.py` | The host driver. It runs the phases and serves QA-00's file handshake (`kill`, `background`, `call`, `audioRoute`, `lowStorage`, `freeStorage`, `screenshot`). It samples the app process from outside every 30 s and flags a process that disappears without a requested kill. |

```sh
# iOS Simulator (this Mac). Fixtures and models are read in place.
python3 -I integration_test/editor_soak/tool/soak_host.py -p ios -d <udid> -m ~/danaview-models death
python3 -I integration_test/editor_soak/tool/soak_host.py -p ios -d <udid> -m ~/danaview-models soak --minutes 60 [--seed N]

# Android emulator or device (Windows lane). Stage the fixtures and models first with QA-00's e2e_host.sh.
integration_test/editor/tool/e2e_host.sh -p android -d emulator-5554 stage
integration_test/editor/tool/e2e_host.sh -p android -d emulator-5554 stage-models ~/danaview-models
python3 -I integration_test/editor_soak/tool/soak_host.py -p android -d emulator-5554 all --minutes 60
```

Evidence lands in `build/soak/<platform>/<device>/`:

- `logs/`: one log per phase, plus `host.log`.
- `screens/`
- `files/soak-summary.json`: ops, outcomes, failures, framework errors, reopen problems, items that were not available, and every RSS sample.
- `files/soak-death.json`: the result per job type.
- `memory-host.csv`: the RSS (iOS) or PSS (Android) measured by the host.
- `summary.txt`

Every in-app event prints a `DV_SOAK <kind> …` line. The kinds are `op`, `fail`, `progress`, `memory`, `death`, `death-result` and `end`. A run replays exactly with `--seed <the seed printed by "DV_SOAK start">`.

### 1.1 The random soak

**Op types.** Weights are in brackets. The warm-up runs each op once, in this order. After that, ops are picked at random by weight.

| Group | Ops |
|---|---|
| Edits | `split` (6), `undo` (6), `redo` (4), `copyPaste` (3, a quarter of them ⌘X), `duplicate` (3), `delete` (3, delete or ripple delete), `text` (3, add text and set its content), `marker` (2), `speed` (3, constant 0.5×/1×/1.5×/2×), `transition` (2, cross dissolve on a cut), `zoom` (3), `selectAll` (1). All of these go through the action registry or the panel's core command. |
| Gestures | `dragMove` (4) and `dragTrim` (4) go through the timeline's drag delegate, with snapping and a ±3 px overshoot. `frameStep` (3) uses hardware ←/→. |
| Playback | `seek` (8, exact), `scrub` (5, `beginScrub` then 15 × `scrubTo` then `endScrub`), `play` (6, 0.3–2 s). |
| Jobs | `export` (2): the export is cancelled, completed, or backgrounded mid-export and then completed or resumed. `captions` (1): the tiny model on the speech clip, completed or cancelled, then undone half the time. `reverse` (2), `freeze` (2) and `proxy` (1): each is waited for, or cancelled from the Tasks controller. |
| Interruptions | `background` (2): the host backgrounds the app for 1–5 s, during playback half the time. One second after the return, the preview must not be black. A black frame counts only when a frame that showed a picture before leaving is black after the return: the playhead frame, or else the first of a few probe frames that is not black. On a black frame the op re-seeks the same frame (a picture then means the preview stayed stale until a seek) and then the reference frame (a picture there means the stopped-on frame is black content, such as a gap). `inactive` (2): the lifecycle goes inactive → resumed, which is what a call banner, Siri or Control Center produce. `call` (1): a host GSM call on the Android emulator; on iOS it falls back to the lifecycle simulation. `audioRoute` (1). `lowStorage` (1): the host fills storage, then the soak does an edit, a manual save and an export, then frees the storage. `offline` (1): a media file used on the timeline is moved away, and the media health must show it offline. The soak keeps seeking, playing, splitting and exporting (the export must be blocked), then moves the file back, and the media must come back. |
| Persistence | `reopen` (every 25 ops and at the end): the editor closes, the project is opened straight from the store and validated (no validator violations, no repairs on open, not read-only), then reopened in the editor and validated again. If a clean close leaves a recovery journal, that is a problem. |

**Project size limit.** Once a project passes 40 items, 10 tracks or 4 minutes, it gets a final store check. It is then deleted and replaced by a fresh one, which exercises create and delete. The media are unique sandbox copies per project, and the delivered export copies are deleted after each export, so the sandbox stays bounded over an hour.

**Verdicts.**

| Criterion | How it is checked |
|---|---|
| No crash | The flutter test connection survives the whole run, and the host sees the same app pid throughout (unless the host itself killed it). |
| No unhandled exception | Every `FlutterError` is recorded against the op that was running and forwarded to the test binding, so it also fails the test. Uncaught zone errors fail the test. An op that throws counts as a failure. |
| Nothing hangs | Every wait has a bound. An op whose wait runs out is a "stuck" failure. The soak recovers (dismisses sheets, reopens the project) and continues, so one defect doesn't hide the rest of the hour. |
| Memory ≤ +10 % | `ProcessInfo.currentRss` is sampled after every op. The baseline is the median of the first tenth (at least 5 samples) after the warm-up. The warm-up has already loaded the speech model, encoder and caches. The end value is the median of the last tenth. The verdict is (end − baseline) / baseline ≤ 0.10. The host's outside samples are a cross-check. |
| Project always reopens valid | The `reopen` op above, and the store check when a project is rotated out. |

### 1.2 Process death per job type

| Job | How it dies | Passes when |
|---|---|---|
| autosave | A text is edited every 40 ms while the host kill request is pending, so the kill lands in the middle of edits and autosaves. | The project reopens valid. When the journal is ahead of the main file, the Projects recovery banner restores it. The text holds one of the killed session's edits. |
| proxy | `requestProxy` starts the job, then a save puts the pending state on disk, and the app is killed. | On open, the pending proxy resumes and becomes `ready`. If the pending state was not on disk, a new request completes. |
| reverse | Reverse on the 8 s 1080p clip, a save, then the kill. | The pending reversed rendition resumes on open and becomes `ready`. If the job finished before the kill, that is recorded, and the project must still be valid. |
| freeze | The freeze sheet's Confirm, a save, then the kill. | The pending still resumes and becomes `ready`, with the same caveat as reverse. |
| export | 32 s at 1080p, killed past 10 %. | `activeJobs()` reports exactly one `ExportInterrupted` or `ExportResumable` record and nothing running. The editor shows it once: a resumable job resumes and completes, while an interrupted one is acknowledged. After that, the record is gone, and a reopened editor's `reattach()` finds nothing. |
| captions | 60 s of speech (6 clips, "Selected clips", Fast tier), killed past 50 % (after the first checkpoint). | `resumableFor(project)` keeps the record. The editor shows "Auto captions were interrupted" once. After Discard, a reopen shows no notice and the record is gone. |

For every job, the project is then opened straight from the store and validated.

## A000. Android half, D11 re-run (Windows lane, 2026-10-22, code d2600495)

**Code d2600495** (`editor-android`) is 8725e25c plus both halves of the D11 fix: the Mac's iOS +
Dart half (5ac2cf8, merged from `origin/editor-wip`) and the Android half (d2600495, "fix(editor):
AND-10 the preview returns to the requested quality when playback stops (QA-05 D11, Android)"),
following the semantics in 97ec109e and cbefb080. Every run below is on that exact commit, clean
checkout; only this report commit follows it.

All device runs used the **Pixel_9_Pro_XL_API_35 emulator** (`emulator-5554`, `-port 5554`,
audio, cold boot with `-no-snapshot-load`), a debug build from the main checkout. Zygote heap
576m, equal to `ro.boot.dalvik.vm.heapsize`, so no boot race; the guest was idle after boot
(`guest_top_boot.txt`, `guest_top_boot_soaks.txt`). Commands as in §A00, `soak_host.py`
unmodified, no wrapper, no manual folder step; before each soak `adb uninstall`, then
`e2e_host.sh stage` and `stage-models C:/dev/models`. The selftest and the death chain ran
15:10–15:30 IST; the laptop then went onto battery, so the soaks waited and ran 17:28–17:59 on
mains power (Win32_Battery status 2 checked before each), with **no other emulator running**
(`emulator-5556` was off; both lock dirs held). Evidence of the 8725e25c round is in
`build/soak/android/_before_d2600495/`; everything below is under
`build/soak/android/emulator-5554/` (`CODE_VERSION.txt`, and a `README.txt` in `soak_run_b/` and
`soak_run_b_rerun_INVALID/`).

**Verdict: not certified.** D11 is fixed, but run b found a native crash in our audio decoder (D12).

### A000.1 Selftest

**pass**: `selftest: PASS`, 30 `ok` checks (`selftest/selftest.log`).

### A000.2 Process death per job type

15:11–15:30, **7/7 pass** (autosave, proxy killed at 17.8 %, reverse at 2 %, freeze not running at
the kill (allowed caveat), export killed at 40 % with `ExportInterrupted` once, captions at 56 % with
the 60 s WAV, verify). Evidence: `death_chain/`. The logcat has one ANR, in Google Messages
(`com.google.android.apps.messaging`, 15:11:13, boot settling), none in our app, and no fatal
signal or OutOfMemory line.

### A000.3 Random soak, 15 min, seed 5150

Evidence: `soak_run_a/`, `soak_run_b/` (`soak_runner.log`, `logs/soak_test-soak.log`,
`files/soak-summary.json` (run a only), `memory-host.csv`, `logcat_soak.txt`; run b also
`tombstones/` and `bugreport_after_crash.zip`).

| Run | Time | Ops | Projects | Reopens | Failures | Memory (baseline → end, peak) | Growth |
|---|---|---|---|---|---|---|---|
| a | 17:30–17:46, 916 s | 441 | 3 | 18 of 18 valid | **0** | 651.4 → 656.6 MB, peak 723.4 MB (411 samples) | +0.8 % |
| b | 17:47–17:59 | 260, then the app died | 2 | 10 of 10 valid before the crash | **app crash** after op #260 (D12) | no summary (the app died); host PSS 441–564 MB, one pid | n/a |

| Criterion | Run a | Run b |
|---|---|---|
| No crash | **pass**. One app pid (3915) in 30 host samples (PSS 437–593 MB). No ANR, fatal signal or OOM. | **FAIL**: SIGSEGV on `danaview-pcm` at 17:59:35.718 (D12). |
| No unhandled exception | **pass**: 0 framework errors | n/a (crash) |
| Nothing hangs, every op works | **pass**: 0 failed ops | ops #1–#260 all passed |
| Memory ≤ +10 % | **pass**: +0.8 % | n/a |
| Interrupted jobs recover or report once | **pass**: exports 3 completed (#49, #166, #259 after background), 6 cancelled; low storage #29 and #306 cancelled, #75, #274 and #335 a clean "storage failure after background (low storage)", save saved every time | **pass** up to the crash (#49, #166, #259 completed; #22, #95, #153, #237 cancelled; #29 and #75 as in run a) |
| Project always reopens valid | **pass**: 18 of 18, 0 reopen problems | **pass** before the crash: 10 of 10 |

**D11 is fixed.** Every op that failed on 8725e25c passes in run a: #26 call (5896 ms) and #271
offline (7581 ms), and also every other call (#112, #180, #238) and offline (#28, #240, #284, #430)
op. Run b passed #26 call (5804 ms) and the call/offline ops before the crash (#28, #112, #180,
#238, #240). Op #262 stays fixed (run a: #261 reverse 14.1 s, #262 freeze 3.5 s). 0 "codec handover
timed out" in both runs (D9 stays fixed); "Handler on a dead thread" warnings 122 (a) and 48 (b).
audioRoute skipped 4 times per run (device step). Emulator debug-build numbers.

**Re-run of b: void (environment), not a result.** The one allowed re-run of b (fresh cold boot,
18:03–18:32) started just as the laptop left mains power (Kernel-Power 105 at 18:03:58), and the lid
closed at 18:20:21: Modern Standby until 18:32:13 (Kernel-Power 506/507). It recorded 241 ops in
922 s (run a: 441) and one failure (#240 offline: a seek timed out across the standby). The laptop
was still on battery at 18:33, so no further run was started. Evidence:
`soak_run_b_rerun_INVALID/`.

### A000.4 D12: native crash in `PcmStream.close()` racing the decoder's input callback (Android lane)

**Symptom.** Run b, after op #260 (selectAll); op #261 is a reverse (in run a it completed in
14.1 s). The app (pid 2729) died:

```
17:59:35.717 CCodecBufferChannel: [c2.android.aac.decoder#791] MediaCodec discarded an unknown buffer   (x7)
17:59:35.718 F libc: Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x754a66581000
             in tid 23747 (danaview-pcm), pid 2729 (vecvel.danaview)
backtrace:
  #00 libc.so (memcpy+827)
  #02 libart.so (art::JNI<true>::GetByteArrayRegion(...)+821)
  #04 libart.so (art::CheckJNI::GetPrimitiveArrayRegion(...)+945)
```

The faulting address is the destination of the copy (`rdi` = `rax` = fault address).
`tombstone_08` shows the other side: thread `danaview-job-5` (the reverse job, the same tid that
logged "reverse intermediate"/"reverse: frames of a chunk were not decoded" from 17:59:22) is in
`com.vecvel.danaview.editor.engine.media.PcmStream.close` → `Thread.join`, so `codec.stop()` and
`codec.release()` have already returned.

**Cause (hypothesis, strongly supported).** `PcmDecoder` (AND-04) runs MediaCodec in async mode
with its callbacks on the `danaview-pcm` HandlerThread. `onInputBufferAvailable` calls
`extractor.readSampleData(buffer, 0)`, which copies a Java `byte[]` into the codec's direct input
buffer (`GetByteArrayRegion` into native memory). The consumer thread's `PcmStream.close()` calls
`codec.stop()` and `codec.release()` **first** and only then quits and joins the callback thread.
Feeding runs ahead of the output (up to `end + encoderDelay + preroll`), so when the reader reaches
the range end and closes, the callback can still be inside `readSampleData`. The stop/release
discards and unmaps the input buffers (the seven "discarded an unknown buffer" lines 1 ms before),
and the copy faults. Reverse, `SpeechAudioExtractor` (captions) and `WaveformService` all use
`PcmDecoder`, so any of them can hit it.

**It recurs.** The same emulator's `/data/tombstones` also has `tombstone_01` (2026-10-14 19:40)
and `tombstone_03` (2026-10-15 15:16): the same `danaview-pcm` thread crashing in
`com.vecvel.danaview.editor.engine.test` (the engine instrumentation tests). The a1 crash of the
034a0d3 round (§A0.3, `tombstone_05`) has the same native signature (`memcpy` ←
`GetByteArrayRegion` writing into a codec buffer) on an `ExoPlayer:Playback` thread during an export
cancel, so it is probably the same class of race (a writer into a codec buffer after the codec is
stopped). It is no longer treated as an emulator-only crash. The goldfish H.264 decoder service
crash at 17:50:57 (`tombstone_07`, pid 423, `C2Block2D::handle`) is a separate, earlier emulator
crash. The app survived it.

**FIX (Android lane, in progress).** A fix agent is working on it. Make `PcmStream.close()`
(and the failure paths in `PcmStream.open`) stop the feeding before the codec goes. One way: a
`closed` flag and a lock that `onInputBufferAvailable` holds while it touches the input buffer.
Another: quit and join the callback thread before `codec.stop()`/`release()`. Add an engine test
that closes mid-feed many times. Also check the export path's buffer writers for the a1 signature.
Then run both seeded soaks (seed 5150, 15 min) again on the fix code, alone, on mains power. Run
the death chain too if the fix touches the job paths.

### A000.5 What is needed to certify the Android half

1. D12 fixed (Android lane) and its test green.
2. Both seeded soaks (seed 5150, 15 min) again on the fix code, on mains power, with no other
   emulator running, plus the death chain if the fix touches the job paths.

The 1 h runs and the device-only steps stay deferred, as on iOS (§6).

## A00. Android half, final 1.1 re-run (Windows lane, 2026-10-22, code 8725e25c)

**Code 8725e25c** (`editor-android`) is 034a0d3 plus the Android-lane op #262 fix (f11d4abc: a
superseded plan build in `MultiPlayerEngine` waits for the newest one), the AND-14 test change
(9eebbff0) and `origin/editor-wip` merged again, which brings FIX M-24 (562ccb1) and W4b (befb981:
`soak_host.py` opens the shared folders itself after its own uninstall).

All device runs used the **Pixel_9_Pro_XL_API_35 emulator** (`emulator-5554`, `-port 5554`, audio,
cold boot with `-no-snapshot-load`), a debug build from the main checkout, the laptop on mains
power, 13:10–13:58 IST. Zygote heap 576m, equal to `ro.boot.dalvik.vm.heapsize`, so no boot race.
The guest was idle at boot (`guest_top_boot.txt`), and per-minute `top` samples during run b show
only the app busy (111–176 %), no system service pegged. `emulator-5556` was not running.
`soak_host.py` ran **unmodified, with no wrapper and no manual folder step**:

```sh
python -I -B integration_test/editor_soak/tool/soak_host.py -p android -d SELFTEST selftest
python -I -B integration_test/editor_soak/tool/soak_host.py -p android -d emulator-5554 -m C:/dev/models death
python -I -B integration_test/editor_soak/tool/soak_host.py -p android -d emulator-5554 -m C:/dev/models soak --minutes 15 --seed 5150
```

Before each soak: `adb -s emulator-5554 uninstall com.vecvel.danaview`, then `e2e_host.sh -p android
-d emulator-5554 stage` and `stage-models C:/dev/models` (in Git Bash this needs
`MSYS2_ARG_CONV_EXCL=/sdcard`). No `__pycache__` was written and git status stayed clean. The
evidence of earlier rounds was moved to `build/soak/android/_before_8725e25c/emulator-5554/`.
Everything below is under `build/soak/android/emulator-5554/` (with `CODE_VERSION.txt`).

**Verdict: not certified.** Selftest and death chain green; both seeded runs fail (D11).

### A00.1 Selftest

**pass**: `selftest: PASS`, exit 0, 30 `ok` checks, including W1–W7 and the five W4b checks
(folders created with one `mkdir -p` after the uninstall, `chmod 2777` on every shell-owned folder,
opened before the first push, owner checked with `stat -c %u`, no `run-as`). Evidence:
`selftest/selftest.log`.

### A00.2 Process death per job type

13:12–13:20, exit 0. The script opened the shared folders itself (W4b works on the device too).
Evidence: `death_chain/` (`death-results.txt`, `death_runner.log`, `logcat_death.txt`, `logs/`,
`files/soak-death.json`, `soak_speech_60s.wav`).

| Job | Result | Evidence |
|---|---|---|
| autosave | **pass** | The journal was restored; reopened valid with `SOAK AUTOSAVE 0`. |
| proxy | **pass** | Killed while running (8.9 %), `pending` on reopen, resumed to `ready`. |
| reverse | **pass** | Killed while running (2 %), `pending` on reopen, resumed to `ready`. |
| freeze | **pass** (allowed caveat) | Not running at the kill; the still was already ready on reopen. |
| export | **pass** | Killed at 59 %. `ExportInterrupted` once, nothing on reopen. |
| captions | **pass** | Killed at 56 % with the 60 s WAV. Record at 0 %, notice once, gone after Discard. |
| verify | **pass** | Every job's project opened from the store and validated. |

The logcat has no ANR, fatal signal or OutOfMemory line.

### A00.3 Random soak, 15 min, seed 5150

Both runs from a fresh install on the same cold boot. Evidence: `soak_run_a/` and `soak_run_b/`
(`soak_runner.log`, `logs/soak_test-soak.log`, `files/soak-summary.json`,
`files/soak-summary-log.json`, `memory-host.csv`, `logcat_soak.txt`; run b also
`guest_top_during_b.txt`).

| Run | Time | Ops | Projects | Reopens | Failures | Memory (baseline → end, peak) | Growth |
|---|---|---|---|---|---|---|---|
| a | 13:21–13:38, 921 s | 336 | 2 | 14 of 14 valid | **2**: #26 call, #271 offline (D11) | 631.6 → 641.2 MB, peak 716.7 MB (306 samples) | +1.5 % |
| b | 13:41–13:57, 908 s | 330 | 2 | 14 of 14 valid | **1**: #271 offline (D11) | 667.2 → 664.9 MB, peak 730.8 MB (300 samples) | −0.3 % |

| Criterion | Run a | Run b |
|---|---|---|
| No crash | **pass**. One app pid (17678) in 31 host samples (PSS 445–652 MB). No ANR, fatal signal or OOM. | **pass**. One pid (15154) in 31 samples (about 488–590 MB after a 33 MB first sample at launch). No ANR, fatal signal or OOM. |
| No unhandled exception | **pass**: 0 framework errors | **pass**: 0 framework errors |
| Nothing hangs, every op works | **FAIL**: #26 call and #271 offline (D11) | **FAIL**: #271 offline (D11) |
| Memory ≤ +10 % | **pass**: +1.5 % | **pass**: −0.3 % |
| Interrupted jobs recover or report once | **pass**: exports 3 completed (#49, #166, #259 after background), 5 cancelled; #75 and #274 end as a clean "storage failure after background (low storage)" with the save saved | **pass**: exports 3 completed, 4 cancelled; #75 clean storage failure with the save saved; #274 completed after background |
| Project always reopens valid | **pass**: 14 of 14, 0 reopen problems | **pass**: 14 of 14, 0 reopen problems |

Other checks, both runs: **op #262 is fixed** (#261 reverse completed in 14.1 s and 16.4 s, #262
freeze completed in 3.7 s and 4.6 s, no stale-frame seek). 0 "codec handover timed out" (D9 stays
fixed); "Handler on a dead thread" warnings 100 (a) and 182 (b), scattered. audioRoute skipped 4
times per run (device step). Emulator debug-build numbers, not device numbers. The a1 SIGSEGV of
the 034a0d3 round (§A0.3) did not recur in this round (death chain and both soaks: no fatal
signal); its cause is still not proven.

### A00.4 D11: a preview left at quarter quality while paused never reads as ready

**Symptom.** Both failures read: "stuck: Timed out after 60 s waiting for the editor to be ready
[editor ready, preview degraded, preview session open]", with the "Preview ¼" badge on screen.
#271 (offline) failed in runs a and b, so it repeats on a healthy emulator from a fresh install;
#26 (call) failed in run a and passed in run b (5586 ms). The app did not hang: the following ops
ran normally and the later seeks showed the right frames.

**Cause (code read; confirmed by the badge).** During playback under load (media offline, or the
GSM call), the quality governor stepped the preview down to quarter. Playback then stopped. The
badge reads "¼", which `PreviewStatusStrings.degraded` shows only for quarter, so no step back up
had happened by the time the wait ran out.

- The governor steps back up only after 10 s of clean *playback* (`QualityGovernor.onFrame`, fed
  only by frames shown while playing). A paused preview at quarter stays at quarter, and the
  phase stays `degraded`. iOS behaves the same (`QualityGovernor.playbackStopped` only clears its
  stats), so this is the shared ARCH §13.2 design, not an Android-only fault.
- Dart: `EditorController._onPreviewEvent` sets `PreviewPhase.degraded` for any `PreviewDegraded`;
  only `PreviewRecovered` sets `ready`.
- QA-00: `e2e_editor.waitReady` requires `PreviewPhase.ready`, so it times out after 60 s. The soak's
  own `_recover` already counts `degraded` as a live preview (FIX-QA05-D5), but `_offline` ends with
  `ed.waitReady()`, which does not.

**Secondary parity gap, fixed on the Android lane.** Android reported an automatic step back up to
full only as `DEGRADED(full)` and never sent `RECOVERED`; iOS sends `RECOVERED` too. The Android
engine now does the same (`PreviewSession.applyQuality`, commit "fix(editor): AND-10 a step back to
full preview quality reports RECOVERED"). This does not fix #26 or #271 (they never stepped up).

On 034a0d3 op #271 passed (4194 ms in run a). Whether the step down happens depends on frame drops
on the emulator during the op's playback, so it is load-dependent; no code change between 034a0d3
and 8725e25c is shown to cause it.

**FIX request (Mac, QA-00 / soak):** should `waitReady` (or the soak's `_offline`) accept
`PreviewPhase.degraded` with a live session, as `_recover` does? The alternative is a contract
change on both engines: reset the governor to the requested level when playback stops (or on the
next paused render) and send `RECOVERED`. If the Mac picks that, the Android lane does its half.

### A00.5 What is needed to certify the Android half

1. D11 resolved (Mac decision: `waitReady` accepts a degraded live preview, or both engines reset
   the governor when playback stops; the Android lane does its half if that is chosen).
2. Then the two seeded soaks (seed 5150, 15 min) again on one code version, with the host
   unmodified, and the death chain if the fix touches it.

The 1 h runs and the device-only steps stay deferred, as on iOS (§6).

## A0. Android half, re-run (Windows lane, 2026-10-22, code 034a0d3)

**Code 034a0d3** (`editor-android`) adds these fixes to d680bd3:

- Mac: FIX M-23 (8fb43c2), the D8 Dart half with the soak's low-storage wait (2c09282), and the
  `soak_host.py` fixes W1–W7 (5912db4).
- Android lane: the D8 engine half (c90819a: purged generated images are regenerated, and a cache
  purge is reported as a storage error), D9 (92623ff: codecs of cancelled jobs are released before
  the next codecs start) and D10 (74392c9: an exact seek acks only the frame on screen).

All runs used the **Pixel_9_Pro_XL_API_35 emulator** (`emulator-5554`), a debug build from the main
checkout, and the laptop on mains power, from 10:37 to 11:28 IST. The fixtures and models were
staged with `e2e_host.sh -p android -d emulator-5554 stage` and `stage-models C:/dev/models`.
`soak_host.py` ran **unmodified and with no wrapper**:

```sh
python -I -B integration_test/editor_soak/tool/soak_host.py -p android -d emulator-5554 death
python -I -B integration_test/editor_soak/tool/soak_host.py -p android -d emulator-5554 soak --minutes 15 --seed 5150
```

**Verdict: not certified.**

- **Green:** the death chain (7/7) and seeded run b (0 failures).
- **Not green:**
  - Seeded run a has one failure (#262, a D10 residual).
  - An earlier run on the same code, a1, crashed (SIGSEGV during an export cancel). It is not
    counted as run a, but it is a crash on this code, and its cause is not proven.
  - The host needs one manual step on Android before each run (W4b).

### A0.1 The host (W1–W7, and W4b)

W1–W7 work as intended:

- `flutter.bat` is started by its full path (W1).
- `flutter test` runs with `--no-uninstall` (W3).
- The fixtures and models are staged again after `death()`'s uninstall (W4).
- POST_NOTIFICATIONS is granted by the host (W5, W6).
- The 60 s speech WAV is built and passed (W7): the captions phase was killed at 56 %.
- No `__pycache__` was written, and git status stayed clean.

**W4b (Mac FIX request): unmodified `death` fails on Android.** `death()` uninstalls the app, and
then `adb` recreates the shared folders under `Android/data/com.vecvel.danaview/` as the shell user.
On API 30 and later the app cannot read them. Both unmodified attempts failed `die-autosave`
(`unmodified_death_attempt1/`, `unmodified_death_attempt2/`). The host recorded "the app was not
killed", and the kept phase log is empty. The run agent saw "Fixture frame_counter_1080p30.mp4 is
not staged" on its console, but that line is not in the kept evidence.

The workaround ran outside the script, before every run that counts: uninstall the app, create the
shared folders and open them to the app the way `e2e_android.sh prepare_shared()` does (`chmod
2777`), then stage. `death()`'s own uninstall then finds no app, so the folders stay readable. The
script itself was not changed.

Fix: in `stage_android()`, create `files/{e2e_fixtures,e2e_models,e2e_handshake,e2e_out}` with one
`mkdir -p` and run `chmod 2777` on each folder owned by uid 2000.

### A0.2 Process death per job type

The final chain ran from 11:12 to 11:28 on a cold-booted emulator. Evidence:
`build/soak/android/emulator-5554/death_chain_rerun/` (`death-results.txt`, `death_runner.log`,
`logcat_death.txt`, `soak_speech_60s.wav`, `logs/`).

| Job | Result | Evidence |
|---|---|---|
| autosave | **pass** | The journal was restored, and the project reopened valid with the text `SOAK AUTOSAVE 0`. |
| proxy | **pass** | Killed while running (6.9 %). It was `pending` on reopen and resumed to `ready`. |
| reverse | **pass** | Killed while running (2 %). It was `pending` on reopen, then resumed and became `ready`. |
| freeze | **pass** (allowed caveat) | The task was running at the kill (progress null), but the still was already ready on reopen. The freeze resume was not exercised again. |
| export | **pass** | Killed at 49 %. One `ExportInterrupted` was reported, and nothing was left on reopen. |
| captions | **pass** | Killed at 56 % with the 60 s WAV (W7). The record was kept at 0 %, the notice showed once, and the record was gone after Discard. |
| verify | **pass** | Every job's project opened straight from the store and validated. |

The logcat holds no ANR and no fatal signal for the app.

Attempts that do not count:

- The two unmodified attempts (W4b, above).
- `death_chain_degraded_emulator/`: only reverse failed. It took about 3 min against the 90 s limit
  on a degraded emulator (see A0.5).
- `death_reverse_solo/`: the app took 3 min 10 s to start, and the run failed opening the Projects
  screen.

### A0.3 Random soak, 15 min, seed 5150

Both runs started from a fresh install on the cold-booted emulator. Evidence:
`build/soak/android/emulator-5554/soak_run_a/` and `soak_run_b/` (`soak_runner.log`, `logs/`,
`files/soak-summary.json`, `files/soak-summary-log.json`, `memory-host.csv`, `logcat_soak.txt`,
`summary.txt`).

| Run | Time | Ops | Projects | Reopens | Failures | Memory (baseline → end, peak) | Growth |
|---|---|---|---|---|---|---|---|
| a | 10:37–10:52, 909 s | 306 | 2 | 13 of 13 valid | **1**: #262 freeze, "seek to 13066667: the engine showed frame 0, not 392" | 649.1 → 656.9 MB, peak 739.7 MB (276 samples) | +1.2 % |
| b | 10:55–11:10, 916 s | 266 | 2 | 11 of 11 valid | 0 (host: `soak: ok`) | 647.7 → 638.0 MB, peak 726.5 MB (236 samples) | −1.5 % |

| Criterion | Run a | Run b |
|---|---|---|
| No crash | **pass**. One app pid (17108) in 30 host samples (PSS 427–608 MB), and the flutter connection survived. No ANR. | **pass**. One pid (9796) in 31 samples (378–578 MB). No ANR. |
| No unhandled exception | **pass**: 0 framework errors | **pass**: 0 framework errors |
| Nothing hangs, every op works | **FAIL**: #262 (D10 residual, below) | **pass**: 0 failed ops |
| Memory ≤ +10 % | **pass**: +1.2 % | **pass**: −1.5 % |
| Project always reopens valid | **pass**: 13 of 13, 0 reopen problems | **pass**: 11 of 11, 0 reopen problems |

Both runs rotated projects (2 projects each), so create and delete ran this time. audioRoute was
skipped 4 times in each run (a device step). Exports in run a: 3 completed and 4 cancelled. Exports
in run b: 3 completed (#49, #166, and #259 after background) and 4 cancelled. Emulator debug-build
numbers, not device numbers.

**Run a1 (not counted as run a): app crash.** This was the first soak on the cold-booted emulator.
It ended after 152 ops, at op #153, an export cancel:

1. The Transformer was released at 10:34:27.974.
2. The emulator's goldfish H.264 decoder service (pid 416) crashed on a null pointer in
   `C2Block2D::handle` (via `getClientUsage`).
3. The app (pid 3806) then died with SIGSEGV in `memcpy` (JNI `GetByteArrayRegion`) on an
   `ExoPlayer:Playback` thread of the export.
4. The soak ended with exit 79.

Before the crash there were 0 op failures. This looks like an emulator codec crash that took the app
down, but it is not proven, and a native crash in our process stays open until it is explained. It
did not recur: op #153 passed in runs a and b. Evidence: `soak_run_a1_crash/` (with
`bugreport_after_crash.zip` and its tombstones).

### A0.4 D8, D9, D10 on 034a0d3

| Defect | Status | Evidence |
|---|---|---|
| D8, low-storage cache purge breaks the export | **fixed** (the failure is now a clean storage failure) | `installd` still purges `cache/danaview/editor/` at 199 MB free: 41 purge lines in run a's logcat, 16 in run b's, including `export-jobs.json` and `engine/dv_opaque_*.png`. The export now ends `FAILED (diskFull)`, and the soak accepts it as "storage failure after background (low storage)". This happened for #75 in both runs and for #274 in run a. The save still saves. Whether the job records and work files should move out of `cache/` is still the lead's decision (D8 store roots, §A). |
| D9, export deadlock in the codec reclaim | **fixed on this evidence** | No stall in run a or run b. Op #166's export completed (96 s in run a, 120 s in run b). No "codec handover timed out" in either logcat. "Handler on a dead thread" warnings are scattered (96 in run a, 66 in run b), with no burst. |
| D10, stale frame after a seek | **not fully fixed (residual)** | Run b had none. Run a had one: #262, right after #261 reverse completed (30.5 s): the soak reported "seek to 13066667: the engine showed frame 0, not 392". Hypothesis, not observed in the kept evidence: the preview reloaded with the reverse rendition, the exact seek timed out after 8 s with nothing displayed (-1), and the timeout ack turned that into frame 0 (`SeekController.kt:156`: a timeout with displayed == -1 should fail the ack or ack after the deferred render, not report frame 0). Intermittent: run b passed the same op. Android lane; being fixed on 2026-10-22 (seek during a session reload after a rendition becomes ready), with a regression test. |

### A0.5 Emulator realities in this round

Two soak runs and one death chain are discarded as emulator problems. Their evidence is kept:

- `soak_run_a_contended/`: the other emulator and a Gradle build were busy at the same time. The app
  had an ANR at startup ("failed to complete startup", CPU pressure 82 %) after 23 ops.
- `soak_run_a_degraded_emulator/` and `death_chain_degraded_emulator/`: the guest's sensors service
  used 63–81 % CPU while idle (`guest_top_a.txt`). Every op ran 4–8 times slower (a seek took 7.3 s
  instead of 0.4 s). There were stale seeks, a stuck reverse, proxy and export, and a black preview.
  A cold boot cleared it.

Evidence from the d680bd3 round was moved to `build/soak/android/_before_034a0d3/emulator-5554/`.

### A0.6 What is needed to certify the Android half

1. Android lane: the D10 residual (#262) and an explanation of the a1 SIGSEGV (the app's own codec
   or buffer lifetime during an export cancel, or the emulator's codec only).
2. Mac: W4b in `soak_host.py`, so that the chain and fresh-install soaks run with no manual step.
3. Then the seeded soak (seed 5150) twice and the death chain, on one code version, with the host
   unmodified.

The 1 h runs and the device-only steps stay deferred, as on iOS (§6).

## A. Android half (Windows lane, 2026-10-22, code d680bd3; superseded by §A0)

All runs used the **Pixel_9_Pro_XL_API_35 emulator** (`emulator-5554`, x86_64, `google_apis`,
SwiftShader GLES 3.0, software codecs), on the Windows laptop on mains power, with Flutter 3.44 and
a debug build of `editor-android` **d680bd3** from the main checkout. The run was on 2026-10-22, from
01:03 to 02:59 IST. The fixtures and models were staged first with QA-00's
`e2e_host.sh -p android -d emulator-5554 stage` and `stage-models C:/dev/models` (the models stay
outside the repo).

**Verdict: not green.** The process-death chain passes: all 7 phases come back `ok`. The seeded soak
(seed 5150, 15 min) does not. Run a failed one op: a low-storage export broke because Android
purged the app's cache folder mid-export (D8). The solo re-run b failed the same op, then five seeks
showed stale frames (D10) and an export deadlocked inside the platform codec code, which hung the
soak (D9). Neither run crashed, and every reopen was valid. Run a's memory growth was +7.1 %. Both
the soak and the death chain ran only through a scratch Windows wrapper around `soak_host.py`,
because the host does not run unmodified on Windows/Android (W1–W7 below).

### A.1 The host on Windows

`python -I integration_test/editor_soak/tool/soak_host.py -p android -d emulator-5554 death`, run
unmodified from Git Bash, uninstalled the app and then stopped. Its `host.log` ends at the first
phase's command line. The run agent saw `FileNotFoundError [WinError 2]` there: Python's
`subprocess` cannot start the bare name `flutter`, because on Windows it is `flutter.bat`.
Evidence: `build/soak/android/emulator-5554/unmodified_attempt/`.

Every run below used a scratch wrapper, `build/soak/android/emulator-5554/soak_host_win_SHIM.py`.
It imports `soak_host.py` without editing it and patches only the points that fail on Windows or
Android. Each patch is a FIX request for the Mac (`soak_host.py` is Mac-owned):

| # | What fails | What the wrapper does |
|---|---|---|
| W1 | `subprocess.Popen(["flutter", …])` raises `FileNotFoundError` on Windows (`flutter.bat`) | starts `flutter.bat` by its full path |
| W2 | `stop()` calls `os.killpg`, which does not exist on Windows (`AttributeError`, not caught as `OSError`); `start_new_session` does not make a process group there | `CREATE_NEW_PROCESS_GROUP`, then `taskkill /F /T /PID` |
| W3 | on Android, `flutter test` uninstalls the app at the end of each phase, which deletes the staged fixtures and models and the state the next death phase reads | adds `--no-uninstall` to `flutter test` |
| W4 | `death()` starts with `adb uninstall`, which deletes `Android/data/<app>/files` (the staged fixtures and models) | stages the fixtures and models again after the uninstall |
| W5 | no `grantNotifications` action; `E2eExport.start` asks the host for it on Android | answers it with `pm grant … POST_NOTIFICATIONS` |
| W6 | the soak's own export op does not ask for the grant, so the first export on a fresh install waits behind the POST_NOTIFICATIONS system dialog | grants POST_NOTIFICATIONS from the host once the app is installed |
| W7 | no 60 s speech source on Android: `speech_60s()` uses macOS `afconvert`, and `defines()` passes `DV_SOAK_SPEECH60` on iOS only | builds the 60 s WAV with ffmpeg, pushes it to `e2e_fixtures/` on the device and passes `DV_SOAK_SPEECH60` with the device path |

Commands, from Git Bash after `source ~/danaview_env.sh` at the repo root:

```sh
integration_test/editor/tool/e2e_host.sh -p android -d emulator-5554 stage
integration_test/editor/tool/e2e_host.sh -p android -d emulator-5554 stage-models C:/dev/models
python -I -X utf8 build/soak/android/emulator-5554/soak_host_win_SHIM.py -p android -d emulator-5554 death
python -I -X utf8 build/soak/android/emulator-5554/soak_host_win_SHIM.py -p android -d emulator-5554 soak --minutes 15 --seed 5150
```

### A.2 Process death per job type

The full chain ran twice. The second run (01:49–02:05) came back with all 7 phases `ok`. Evidence is
in `build/soak/android/emulator-5554/death_full_chain2/` (`death_runner2.log`, `death-results.txt`,
`soak-death.json` and one log per phase).

| Job | Result | Evidence |
|---|---|---|
| autosave | **pass** | The journal was restored, and the project reopened valid holding `SOAK AUTOSAVE 0`. |
| proxy | **pass** | Killed while running (8.9 %). The asset was `pending` on reopen and resumed to `ready` with no user action. |
| reverse | **pass** | Killed while running (2 %). The rendition was `pending` on reopen, resumed and became `ready`. |
| freeze | **pass** (allowed caveat) | The task had already finished at the kill (`task running: false`), so the still was "already ready" on reopen. §1.2 allows this when the project is valid, and it was. The same happened in both full chains, so the freeze resume was not exercised on Android. |
| export | **pass** | Killed at 40 % (30 % in the first chain). Exactly one `ExportInterrupted`, reported once, and nothing on reopen. |
| captions | **pass** (with W7) | Killed at 56 %. The record was kept at 0 % (only checkpointed ranges count), the notice showed once, and the record was gone after Discard. |
| verify | **pass** | Every job's project opened straight from the store and validated. |

**Captions without W7 failed twice.** In the first full chain (01:11–01:39, `death_full_chain/`) and
in a solo captions run (01:43, `death_captions_solo1/`), the job was "killed at 95 %", and then
there was "no resumable captions record after the kill". Without a 60 s source, the phase puts six
copies of the 10 s clip on the lane, and on Android that made one 10 s transcription unit, which
finished before the kill landed. With the 60 s WAV (W7) it passed at 56 % in a solo run
(`death_captions_solo2_speech60/`) and in the second full chain. This is a host gap (W7), not an
app defect. The other five phases passed in the first chain too.

### A.3 Random soak, 15 min, seed 5150

`python -I -X utf8 build/soak/android/emulator-5554/soak_host_win_SHIM.py -p android -d emulator-5554 soak --minutes 15 --seed 5150`
ran twice: run a from 02:06 to 02:23, and run b (a solo re-run on a fresh install) from 02:25 until
it was stopped at 02:59. Evidence is in `build/soak/android/emulator-5554/soak_run_a/` (the log,
`soak-summary.json`, `soak-summary-log.json`, `memory-host.csv`, the host log and the full logcat
`soak_logcat_after.txt`) and `soak_run_b/` (the log, `soak-stall-166.json`, `memory-host.csv`, the
thread dump in `stall_b_bugreport/FS/data/anr/trace_11` and `stall_b_bugreport.zip`).

| Run | Ops | Projects | Reopens | Failures | Memory (baseline → end, peak) | Growth |
|---|---|---|---|---|---|---|
| a | 190 | 1 | 8 of 8 valid | **1**: op #75 lowStorage, `ExportFailed(exportFailed.unknown)` (D8) | 633.8 → 678.9 MB, peak 757.4 MB | +7.1 % |
| b | 166 (the last one hung) | 1 | 6 of 6 valid | **7**: #75 (D8, again); #121, #123, #145, #155, #162 stale preview frames (D10); #166 export stalled at 0 % "Preparing…" (D9), then the soak's recovery hung for over 17 min | no summary, because the run was stopped. The host saw 368–618 MB over 64 samples. | n/a |

The emulator ran 190 ops in 15 min, where the iOS Simulator ran 965 (§2.1). One project was enough
for the whole run, so project rotation and delete were not exercised.

Run a, criterion by criterion:

| Criterion | Result | Evidence |
|---|---|---|
| No crash | **pass** | One app pid (26836) across all 31 outside samples (PSS 377–597 MB), and the flutter connection survived. No ANR for the app in the logcat. Run b: one pid (13464) across 64 samples. |
| No unhandled exception | **pass** | 0 framework errors and 0 uncaught zone errors. The only failure was the op failure below. |
| Project always reopens valid | **pass** | 8 of 8 reopens were valid, with 0 reopen problems (run b: 6 of 6 before it was stopped). |
| Memory growth ≤ 10 % | **pass** | +7.1 %: the in-app verdict is "baseline 633.8 MB, end 678.9 MB, peak 757.4 MB, growth 7.1 % (limit 10 %, 160 samples)", from 190 samples. Emulator debug-build numbers, not device numbers. |
| Nothing hangs, every op works | **FAIL** | Run a: 1 failed op, #75 (D8). Run b: #75 again, 5 stale-frame seeks (D10), and an export deadlock that hung the run (D9). |

Ops in run a (ran/skipped/failed):

- seek 12, scrub 3, play 14, frameStep 11
- split 15, undo 17, redo 10, copyPaste 8, duplicate 6, delete 9
- dragMove 9, dragTrim 5
- text 4, marker 6, speed 4, transition 6, zoom 6, selectAll 4
- reverse 6, freeze 5, proxy 2, export 5 (2 completed, 3 cancelled), captions 1
- background 2, inactive 2, call 3 (real GSM calls on the emulator), offline 1
- audioRoute 0/4: no scriptable route change (a device step)
- lowStorage 1/0/1 (the warm-up op #29 passed: export cancelled, save saved)
- reopen 8

**D8 · Under low storage, Android purges the app's cache folder mid-export, and the export fails as
`unknown` (Mac FIX request; the soak's own check also has a gap).** Op #75 asks the host to fill the
emulator to 199 MB free, then edits, saves and exports. At 02:15:10, `installd` was asked for
1,048,576,000 bytes (the requester is not in the log) and purged app caches to make room. That
included the whole of `/data/data/com.vecvel.danaview/cache/danaview/editor/`:
`work/export-*.mp4` (the running export's output), `export-jobs.json`, `engine/dv_opaque_*.png` and
`dv_transparent_*.png` (the generated images the composition references), `proxies/`, `renders/`,
`sprites/` and `thumbs/`. Five seconds later the engine logged
`export ex_34b4199b766747ca: failure … ERROR_CODE_IO_UNSPECIFIED … ImageAssetLoader … FileDataSourceException`
(ENOENT on a generated PNG), which Dart reports as `exportFailed.unknown`. Run b failed the same op
the same way, so it is deterministic with this seed.

This is how Android really behaves when storage runs out (cache files are the first to go), not an
emulator artefact. Two things follow:

1. **Product (Mac, store roots and export job store; the lead decides).** Files a running job needs,
   and the export job records (`export-jobs.json`), live under the cache root, which the system may
   delete at any time under storage pressure. Proposed: keep the running jobs' work files, the job
   records and the engine's generated images under `files/` (or `noBackupFilesDir`), not `cache/`,
   or regenerate them and report a storage failure ("not enough space") instead of `unknown`. The
   Android lane can make the engine regenerate missing generated images and map ENOENT during low
   storage to the storage code, if the lead wants that half.
2. **Soak (Mac, `soak_test.dart` around line 633).** In the `background` branch of `_export`, the
   second wait accepts only `ExportUiCompleted` or `ExportUiInterrupted`, while the first wait also
   accepts `ExportUiFailed` when `_lowStorage` is set. So a failure under low storage counts as an op
   failure only when the export was backgrounded. Make the two waits agree. Whether a clean storage
   failure under low storage is accepted is the Mac's call; an `unknown` failure should stay a
   failure.

**D9 · An export deadlocks while creating its audio encoder (Android lane, candidate, not fixed).**
In run b, op #166's export stayed at 0 % "Preparing…" (0/870 frames) for 120 s, and the soak's
recovery then waited for more than 17 minutes. It was stopped at 02:59, so there is no app summary.
The app's thread dump (SIGQUIT at 02:56, read from a bugreport) shows:

- thread 108 (`pool-93-thread-1`), in `ImageAssetLoader` → `TransformerInternal…onOutputFormat` →
  `DefaultEncoderFactory.createForAudioEncoding` → `MediaCodec.createByCodecName` →
  `BpResourceManagerService::reclaimResourcesFromClientsPendingRemoval` →
  `ResourceManagerClient::reclaimResource` → `MediaCodec::reclaim`, waiting for an answer that never
  comes;
- it holds the Transformer listener lock (`<0x02ad7b7d>`), and 10 other threads are blocked on it.
- two preview-player threads (`ExoPlayer:Playback`, tids 78 and 82) are blocked in the same
  `MediaCodec::reclaim` path while creating codecs, and the app holds about 15 live ExoPlayer playback
  threads and about 17 codec loopers at the stall. So the triage starts with codec lifetime across both
  the export path and the preview session's players (AND-16 decks, AND-10 session), not the export alone.

The reclaim targets a codec in our own process. Run a's logcat shows `MediaCodec$EventHandler …
sending message to a Handler on a dead thread` 57 times in the soak's app process (and in the
death phases' processes). The run agent saw them after cancelled reverse and export jobs; that was
not checked op by op. Taken together, this points to codecs left without
a proper release when an engine job is cancelled, so a later encoder creation tries to reclaim a
codec whose looper is gone. That is a hypothesis, not proven. In run a, the same op #166 export did
complete, but took 191 s. The owner is the Android engine's export and job code
(`packages/danaview_editor_engine/android/`). It was not fixed in this round: it is not a small,
safe change, and the 20-minute budget per root cause ran out. Next step for the Android lane:
replay seed 5150 to op #166, check that every cancelled reverse, export and proxy job stops and
releases its `Transformer` and codecs on the thread that owns them, and keep a thread dump at the
first stall.

**D10 · After a seek, the preview showed an older frame (run b only, cause unproven).** Five ops
failed as "stuck" with the preview phase `ready` (once `degraded`) and a live session: #121 (seek to
frame 664, the engine showed 58), #123 (473, showed 440), #145 copyPaste (144, showed 301, preview
degraded), #155 split (72, showed 249) and #162 split (335, showed 249). Run a, with the same seed,
had none. The frames are tens to hundreds of frames off, so this is not the emulator's software
decoder stale-frame signature (1–5 frames near a stream end, QA-02 "Emulator realities"). They came
after #75 and before the D9 deadlock, so they may share D9's codec state, but that is not shown.
Run b's logcat before 02:56 was lost (see below), so there is no engine trace for these ops. Owner:
the Android lane (preview session) to triage together with D9.

**Emulator realities on Android:**

- **Throughput.** 190 ops in 15 min against 965 on the iOS Simulator: SwiftShader GL, software
  codecs and a debug build. Op times are not performance numbers.
- **Memory.** The in-app RSS baseline is about 634 MB (the iOS Simulator's was about 340 MB); the
  host's PSS stayed at 377–597 MB in run a. Both are emulator debug-build numbers.
- **audioRoute** cannot be changed from a script on the emulator (4 skips per run); it is a device
  step (§6).
- **Real GSM calls** work on the emulator (`call`, 3 per run), unlike the iOS Simulator.
- **lowStorage is real on Android.** The host can fill the emulator's `/data`, so this op runs here
  (it is refused on the iOS Simulator), and it exposed D8.

**Limits of this evidence.** Run b's logcat before 02:56 was lost: the runner cleared it
(`logcat -c`) during the stall. Its test log, host log, memory samples and thread dump are kept. Run
a's full logcat is kept. The first wrapper attempt (`attempt1_shim_restage_bug/`) failed in its own
restage step (MSYS path conversion) and is not a result.

**What stays deferred on Android:** the 1 h emulator run (after D8 and D9 are fixed, and W1–W7
land in `soak_host.py`), the physical-device run with a real audio route change, real calls and real
low storage, and the freeze resume after process death, which both chains skipped because the
freeze finished before the kill (§6).

## 2. Third re-run, after FIX-IOS-D7 (QA-05-RERUN)

FIX-IOS-D7 is under test: every reader is created, read, cancelled and released on one serial queue of
its own, its closures hold the reader, the output and the composition, the audio watchdog only signals
instead of cancelling mid-call, and a hung read resumes on a fresh composition from the frame after the
last delivered buffer. The same fix covers QA-01's FIX-IOS-12-1 (back-to-back exports share nothing).
The unit-level evidence is `packages/danaview_editor_engine/example/ios/RunnerTests/Export/ExportD7Tests.swift`:
all 6 tests pass, and its probe still measures the AVFoundation hang (1 of 8 fresh reads of the soak
composition stopped for good on this run, after 26 buffers at 4.12 s) while every export completes.

All runs used the **iPhone 16 simulator on iOS 26.5** (`6663101E-6BE7-47D4-B3B8-055700BF2E02`), with
Xcode 26.6, Flutter 3.44 and a debug build, on 2026-10-17 from 09:57 to 10:12 IST.

**Verdict: green.** D7 is fixed. The seeded soak (seed 5150) that failed at op #800 with "audio read
hung" and crashed with a SIGSEGV in the same op both passed and ran past it: 965 ops, 0 failed ops, 0
framework errors, 14 exports completed, no crash. The process-death chain also passes on the same code.
What stays deferred is unchanged (§6): the 1 h runs, the Android side and the device-only steps.

### 2.1 Random soak, 15 min, seed 5150

`python3 -I integration_test/editor_soak/tool/soak_host.py -p ios -d 6663101E-6BE7-47D4-B3B8-055700BF2E02 -m ~/danaview-models soak --minutes 15 --seed 5150`

Evidence: `build/soak/ios/6663101E-…/logs/soak_test-soak.log`, `files/soak-summary-log.json`, the host's
`memory-host.csv` and `summary.txt`.

| Run | Ops | Projects | Reopens | Failures | Memory (baseline → end, peak) | Growth |
|---|---|---|---|---|---|---|
| a | 965 | 5 | 39 of 39 valid | 0 | 340.4 → 286.4 MB, peak 521.7 MB | −15.9 % |

| Criterion | Result | Evidence |
|---|---|---|
| No crash | **pass** | One app pid for the whole run (the host's outside samples), and the flutter connection survived. |
| No unhandled exception | **pass** | 0 framework errors and 0 uncaught zone errors. |
| Project always reopens valid | **pass** | 39 of 39 reopens were valid, and each rotated project passed its store check. |
| Memory growth ≤ 10 % | **pass** | −15.9 % (935 samples). The peak comes from captions and export, as before. |
| Nothing hangs, every op works | **pass** | 0 failed ops. The export at op #800 was one of the 14 that completed; the log holds no "audio read hung", no `decodeFailed` and no crash report. |

Ops in run a (ran/skipped/failed):

- seek 77, scrub 56, play 61, frameStep 36
- split 71, undo 85, redo 35, copyPaste 32, duplicate 36, delete 37
- dragMove 35, dragTrim 47
- text 27, marker 21, speed 29, transition 19, zoom 37, selectAll 20
- reverse 25, freeze 19/1/0, proxy 9, export 14/0/0, captions 7/1/0
- background 26, inactive 24, call 8 (simulated), offline 12
- audioRoute 0/9 and lowStorage 0/10: refused on the simulator (see §6)
- reopen 39

The suite was not changed for this re-run; the only code under test is FIX-IOS-D7 in
`packages/danaview_editor_engine/ios/Classes/Export/ReaderWriterPipeline.swift`.

### 2.2 Process death per job type

`python3 -I integration_test/editor_soak/tool/soak_host.py -p ios -d 6663101E-6BE7-47D4-B3B8-055700BF2E02 -m ~/danaview-models death`
ran the full chain on the D7 code from 10:17 to 10:27. All 7 phases came back `ok`; evidence is in
`build/soak/ios/6663101E-…/logs/process_death_test-*.log` and `summary.txt`.

The results are the ones §3.1 recorded for FIX-QA05-D5, unchanged, and now on the D7 code:

| Job | Result | Evidence |
|---|---|---|
| autosave | **pass** | The journal was restored, and the project reopened valid holding `SOAK AUTOSAVE 0`. |
| proxy | **pass** | The asset was `pending` on reopen and resumed to `ready` with no user action. |
| reverse | **pass** | The task was running at the kill; the rendition was `pending` on reopen, resumed and became `ready`. |
| freeze | **pass** | The task was running at the kill; the still was `pending` on reopen, resumed and became `ready`. |
| export | **pass** | Killed at 15 %. Exactly one `ExportInterrupted`, reported once, and nothing on reopen. |
| captions | **pass** | Killed at 56 %. The record was kept at 0 % (only checkpointed ranges count), the notice showed once, and the record was gone after Discard. |
| verify | **pass** | Every job's project opened straight from the store and validated. |

## 3. Second re-run, after FIX-QA05-D5 (QA-05-RERUN)

FIX-QA05-D5 is under test. With it, the Tasks controller waits for the first media resolve pass before it resumes pending jobs, and a preview that stopped while the app was in the background restarts on resume (the Dart side of D6). All runs used an **iPhone 16 simulator on iOS 26.5**, with Xcode 26.6, Flutter 3.44 and a debug build, on 2026-10-16 from 22:09 to 23:18. Runs stayed at 15 minutes on this 8 GB Mac.

**Verdict: not green.** D5 is fixed: every process-death phase passes, including proxy, reverse and freeze. D6 did not come back: 44 of 44 background ops passed. But the seeded soak (seed 5150) found a new iOS export defect, D7, at the same op in both runs. In run a, the export failed with "audio read hung". In run b, the app crashed with a SIGSEGV in the export's audio read.

### 3.1 Process death per job type

The first attempt (22:09, on `6663101E-…`) is **void**. Another builder was running QA-01's `e2e_host.sh` (s12, then s13) on the same simulator at the same time. The two hosts share the app's handshake folder, so each host answered the other's requests: the soak host received a `grantMic`, and the e2e host received the soak's `kill`. The e2e host's `simctl privacy grant` for s13 also terminates a running app, and that killed `die-export` 8 s in. Its logs are kept in `build/soak/ios/6663101E-…/rerun2-death-collided/`. Within that attempt, autosave and proxy had already passed.

The full chain was then re-run on the second iPhone 16 iOS 26.5 simulator (`7DF46AEE-94A0-4105-A226-AAAFB9663838`), which nobody else was using, from 22:27 to 22:37:

`python3 -I integration_test/editor_soak/tool/soak_host.py -p ios -d 7DF46AEE-94A0-4105-A226-AAAFB9663838 -m ~/danaview-models death`

All 7 phases came back `ok`. Evidence is in `build/soak/ios/7DF46AEE-…/rerun2-death/`.

| Job | Result | Evidence |
|---|---|---|
| autosave | **pass** | The journal was restored, and the project reopened valid holding `SOAK AUTOSAVE 0`. |
| proxy | **pass (D5 fixed)** | On reopen the asset was `pending` with no task yet, as expected before the first resolve. It then resumed and became `ready` with no user action. |
| reverse | **pass (D5 fixed)** | The task was running at the kill. The rendition was `pending` on reopen, resumed, and became `ready`. No `mediaOffline` failure. |
| freeze | **pass (D5 fixed)** | The task was running at the kill. The still was `pending` on reopen, resumed, and became `ready`. |
| export | **pass** | Killed at 15 %. Exactly one `ExportInterrupted`, reported once, and nothing on reopen. |
| captions | **pass** | Killed at 56 %. The record was kept, the notice showed once, and the record was gone after Discard. The record now reports 0 % kept: since FIX-QA07-D5, only checkpointed ranges count, and none had been written yet. That is the expected copy ("Resume starts over"). |

Each job's project was then opened straight from the store and passed validation.

### 3.2 Random soak, 15 min, seed 5150

`python3 -I integration_test/editor_soak/tool/soak_host.py -p ios -d 7DF46AEE-94A0-4105-A226-AAAFB9663838 -m ~/danaview-models soak --minutes 15 --seed 5150` ran twice. Evidence is in `build/soak/ios/7DF46AEE-…/rerun2-soak-{a,b}/`: the log, `soak-summary-log.json` (run a), the failing project `soak-failed-800.json` (run a), the host's `memory-host.csv`, and the crash report (run b).

| Run | Ops | Projects | Reopens | Failures | Memory (baseline → end, peak) | Growth |
|---|---|---|---|---|---|---|
| a | 802 | 4 | 33 of 33 valid | **1**: op #800 export, `ExportFailed(exportFailed.unknown)` (D7) | 332.7 → 284.1 MB, peak 691.8 MB | −14.6 % |
| b | 801 before the crash | 4 | 32 of 32 valid | **app crash** right after op #801 (D7) | no summary, because the app died. The host saw 95–663 MB over 27 samples. | n/a |

Run a, criterion by criterion:

| Criterion | Result | Evidence |
|---|---|---|
| No crash | **pass** (run a) / **FAIL** (run b) | Run a: one app pid (43566) across all 30 outside samples. Run b: `EXC_BAD_ACCESS` (SIGSEGV) at 23:18:37, see D7. |
| No unhandled exception | **pass** | 0 framework errors and 0 uncaught zone errors. |
| Project always reopens valid | **pass** | 33 of 33 in run a and 32 of 32 in run b. Each rotated project passed its store check. |
| Memory growth ≤ 10 % | **pass** | −14.6 % (772 samples). The peak comes from captions and export, as before. |
| Nothing hangs, every op works | **FAIL** | 1 failed op: the export at op #800 (D7). |

Ops in run a (ran/skipped/failed):

- seek 64, scrub 45, play 47, frameStep 31
- split 60, undo 68, redo 31, copyPaste 23, duplicate 31, delete 34
- dragMove 27, dragTrim 37
- text 23, marker 18, speed 25, transition 17, zoom 32, selectAll 15
- reverse 19, freeze 17/1/0, proxy 9, export 12/0/1, captions 5
- background 22, inactive 20, call 8 (simulated), offline 9
- audioRoute 0/8 and lowStorage 0/10: refused on the simulator (see §6)
- reopen 33

Run b went through the same sequence, with ops shifted by one (`duplicate` at #800), up to the crash.

**D5 is fixed in the soak too.** Reverse, freeze and proxy ran 19, 17 and 9 times with no failure. Every export blocked by "waiting for reverse" (#468, #687/#688) was blocked correctly.

**D6 did not reproduce.** All 22 background ops passed in each run (1–5 s, half of them during playback). After each return the editor reached `ready` with a live preview session, in 7.5–9 s including the time away. The one black frame (run a, "5 s during playback, frame 751") was black content: the reference frame showed a picture. The preview never stayed at `PreviewPhase.degraded`, so the harness `waitReady` (QA-00's `e2e_editor.dart`) was not changed. Only the soak's own recovery check now counts `degraded` as live (§3.3).

**D7 · iOS export: the audio mix read hangs, and the watchdog's cleanup can crash the app (new).** This reproduced at the same op in both seeded runs: the first "complete" export after about 800 ops, on project #4. That project's main lane has 11 clips, 5 of them reversed at 2×. It also has 4 texts and one audio-lane clip (the project is in `rerun2-soak-a/soak-failed-800.json`).

- **Run a.** The simulator log shows three cycles about 30 s apart (22:57:56, 22:58:26, 22:58:57). Each cycle is an AVFoundation `remakerFamily_renderPipelineRanDry … track source id 4`, then a reader invalidate. Then the engine logs `export ex_1f05…: failed decodeFailed: audio read hung`. That is the watchdog in `MixAudioSource.nextAudio()` (`packages/danaview_editor_engine/ios/Classes/Export/ReaderWriterPipeline.swift`, about line 750) firing on each retry. The Dart side shows it as `exportFailed.unknown` ("The export didn't finish").
- **Run b.** At the same point the app died: `EXC_BAD_ACCESS / SIGSEGV`, `KERN_INVALID_ADDRESS (possible pointer authentication failure)`, on queue `com.vecvel.danaview.editor.export.audioread`. The stack is `pthread_mutex_unlock` ← `FigSemaphoreWaitRelative` ← `assetReader_ExtractAndRetainNextSampleBuffer` ← `-[AVAssetReaderOutput copyNextSampleBuffer]` ← closure in `MixAudioSource.nextAudio()`. The report is in `rerun2-soak-b/Runner-2026-10-16-231837.ips`.

Reading of the code: after the watchdog times out, `nextAudio()` calls `reader.cancelReading()`, waits at most 5 s for the blocked `copyNextSampleBuffer`, and throws (retryable). The closure on `readQueue` holds only the `output`. An `AVAssetReaderOutput` does not keep its reader alive, so when the retry replaces or releases the reader, the still-blocked copy can wake up inside a freed reader. That is a use-after-free, which matches run b's crash. The underlying stall is the D1 family: an audio mix pipeline that "runs dry" on one track of a reversed and speed-changed composition. FIX-IOS-EXPORT-STALL turned the endless hang into a bounded failure, but not into a success. The owner is IOS-12 (`ReaderWriterPipeline.swift`, which has the `// OWNER: IOS-12` header) and the FIX-IOS-EXPORT-STALL follow-up. Two things are needed:

1. Keep the reader alive until the read block has returned. Capture it in the closure, and do not release or replace it while a copy is still outstanding.
2. Fix the run-dry stall on that composition. The failing project above, replayed with `--seed 5150`, reproduces it.

### 3.3 What changed in the suite in this re-run

- **Recovery.** The soak's recovery check (`_recover` in `soak_test.dart`) now counts a `degraded` preview as live. A quality step still shows frames, which is the FIX-QA05-D5 finding. QA-00's `waitReady` was left unchanged, because D6 never showed as `degraded`.
- **One host per simulator.** Two host drivers on one simulator answer each other's handshake requests, and QA-01's `grantMic` terminates the app. Run QA-05 on a simulator that no other builder is using, as in the commands above.

`flutter analyze integration_test/editor_soak`: no issues.

## 4. Re-run after the D1, D2 and D3 fixes (first QA-05-RERUN)

All runs used the **iPhone 16 simulator on iOS 26.5** (`6663101E-6BE7-47D4-B3B8-055700BF2E02`), with Xcode 26.6, Flutter 3.44 and a debug build, on 2026-10-16, 16:41 to 17:55. The fixes under test are FIX-IOS-EXPORT-STALL (D1, D2: `ReaderWriterPipeline` spacer anchor, bounded writer waits, per-job work queues) and FIX-JOB-RESUME (D3: `createEditorController` reads `tasksControllerProvider` when the session attaches). Runs stayed at 15 minutes on this 8 GB Mac.

**Verdict: not green.** D1 and D2 are fixed: the seeded soak with seed 5150 now passes. The D3 fix is incomplete: proxy, reverse and freeze still do not recover after process death, now because of a new defect, D5. Autosave, export and captions recover.

### 4.1 Random soak, 15 min, seed 5150

`soak_host.py -p ios -d 6663101E-… -m ~/danaview-models soak --minutes 15 --seed 5150` ran three times. Evidence is in `build/soak/ios/<udid>/rerun-soak-{a,b,c}/` (the log, `soak-summary-log.json`, and the host's RSS samples in `memory-host.csv`). The CSV accumulates across runs, and each run has its own app pid.

| Run | Ops | Projects | Reopens | Failures | Memory (baseline → end, peak) | Growth |
|---|---|---|---|---|---|---|
| a | 574 | 3 | 23 of 23 valid | 5 (see D6) | 281.1 → 265.4 MB, peak 482.8 MB | −5.6 % |
| b | 1042 | 5 | 42 of 42 valid | 1 (a test artifact, fixed) | 362.9 → 300.2 MB, peak 503.7 MB | −17.3 % |
| c (final suite) | 843 | 4 | 34 of 34 valid | **0** | 325.5 → 275.2 MB, peak 582.3 MB | **−15.5 %** |

Run c, the final suite, passed every criterion:

| Criterion | Result | Evidence |
|---|---|---|
| No crash | **pass** | The host saw one app pid for the whole run (30 outside samples at 104–480 MB), and the flutter connection survived. |
| No unhandled exception | **pass** | 0 framework errors and 0 uncaught zone errors. |
| Project always reopens valid | **pass** | 34 of 34 reopens were valid, and each rotated project passed its store check. |
| Memory growth ≤ 10 % | **pass** | −15.5 % (813 samples). The peaks come from captions and export, as before. |
| Nothing hangs, every op works | **pass** | 0 failed ops. |

Ops in run c (ran/skipped/failed):

- seek 69, scrub 47, play 51, frameStep 32
- split 63, undo 75, redo 33, copyPaste 25, duplicate 31, delete 35
- dragMove 31, dragTrim 38
- text 23, marker 19, speed 25, transition 17, zoom 34, selectAll 16
- reverse 21, freeze 17/1/0, proxy 9, export 13, captions 5/1/0
- background 22, inactive 20, call 8 (simulated), offline 10
- audioRoute 0/8 and lowStorage 0/10: refused on the simulator (see §6)
- reopen 34

**D1 is fixed.** Op #165, the export that used to stall at the first "complete" kind, completed in 8.9 s in run b. Every export completed, was cancelled or was correctly blocked: in run b there were 7 completions (2 of them after a background), 7 cancels, and 2 `ExportUiWaiting` blocks while a reverse was pending. Run c had the same mix with 13 exports. No export stalled.

**D2 is fixed.** Exports after a cancel kept succeeding in every run: run b completed 3 exports after the cancel at op #929. There was no `exportFailed.unknown`, and no reverse failed.

**D6 · The preview sometimes does not come back after a background (intermittent).** This happened in run a only, on a loaded Mac (574 ops in 15 min, against 843–1042 in the other runs):

- Ops #430 and #431 (background for 2 s, during playback and idle): the editor was `ready`, but the preview did not reach `ready` with a live session within 60 s, twice in a row. Op #436 (offline) then hit the same wait. The soak's recovery then counted the editor as ready, so it did not reopen it; the preview came back by op #495.
- Ops #45 and #498 (background during playback): the frame was black 1 s after the return.

Runs b and c, with the same seed, did not reproduce it at those ops (they passed in 5–8 s). Run a used the original black-frame check, which could not tell black content from a dead preview, so #45 and #498 are inconclusive. #430 and #431 are not inconclusive: the preview phase stayed short of `ready` for over a minute. The owner is the preview's background and foreground lifecycle: the iOS preview session, and the editor's preview restart in UX-08. The suite now records the editor and preview phases in every stuck line. Its recovery also reopens the project when the preview is not live, so if this happens again it fails one op, not three.

### 4.2 Process death per job type

`soak_host.py … death`, 16:41 to 16:59. Evidence is in `build/soak/ios/<udid>/rerun-death/`.

| Job | Result | Evidence |
|---|---|---|
| autosave | **pass** | Journal restored. The project reopened valid holding `SOAK AUTOSAVE 0`. |
| export | **pass** | Killed at 10 %. Exactly one `ExportInterrupted`, shown once, gone after acknowledgement. `reattach()` found nothing. |
| captions | **pass** | Killed at 56 %. The record was kept, "Auto captions were interrupted" showed once, and the record was gone after Discard. |
| proxy | **FAIL (D5)** | Killed while running. On reopen the asset was `proxy: pending` with no task, 90 s after the open. Reading `tasksControllerProvider` no longer helps: the controller already exists. |
| reverse | **FAIL (D5)** | Killed while running. On reopen the rendition went straight to `FailedStatus(mediaOffline)`. |
| freeze | **FAIL (D5)** | Same as reverse: the still failed with `mediaOffline`. |

**D5 · Jobs re-queued on open race the first media resolve (the D3 fix is incomplete).** FIX-JOB-RESUME starts the Tasks controller in a microtask right after `session.attach`. Its `_reconcile()` then resolves each source through `session.compiler.resolve(...)`. But INT-02's `DefaultSessionPlanCompiler.resolve` reads `SessionAssetResolver.current`, and before the first `refresh` (the first plan compile, which is async), that snapshot has every media offline (`MapPlanAssetResolver.empty`). So on open:

- `_startDerived` marks a pending reverse rendition or freeze still `FailedStatus(mediaOffline)`. That is permanent, and the user sees a failed task for media that is online.
- `_startProxy(resume: true)` leaves the proxy pending and returns. Nothing re-runs `_reconcile` until the pool changes, so the proxy never resumes.

The FIX-JOB-RESUME unit tests (`test/flows/tasks/job_resume_on_open_test.dart`, `test/layout/editor_job_reattach_test.dart`) pass because their rig's compiler resolves synchronously. The fix belongs to the owners of `editor_controller.dart` (UX-08 / FIX-JOB-RESUME) or `tasks_controller.dart` (UX-35). Either:

- start the controller (or re-run `_reconcile`) after the first plan compile, or after the resolver's first refresh; or
- treat a null resolve on resume as "not yet" rather than offline: keep the asset pending, and reconcile again when the resolver snapshot or the availability report changes.

A rig compiler that resolves only after an async first refresh would reproduce it in a unit test. The QA-05 death phases need no change; they wait 90 s without any user action.

### 4.3 What changed in the suite in this re-run

- **`background` op.** A black frame is compared with a reference frame taken before leaving (§1.1). In run b, the first version of this check failed op #789: playback had stopped at frame 815 in a gap, and the frame it started from was black too. With the reference check, the same op passed in run c ("frame 815 is black content; frame 0 shows a picture"). A preview that stays black after a re-seek is still a failure.
- **Stuck lines.** Each stuck line now carries the editor phase, the preview phase and failure, and whether a preview session is open.
- **Recovery.** After a failed op, the soak reopens the project unless the editor is ready *and* the preview is live.

`flutter analyze integration_test/editor_soak`: no issues.

## 5. First run, before the fixes (QA-05)

All runs below used the **iPhone 16 simulator on iOS 26.5** (`6663101E-6BE7-47D4-B3B8-055700BF2E02`), with Xcode 26.6, Flutter 3.44 and a debug build, on 2026-10-16. On this 8 GB Mac the soak was kept to 15 minutes. The 1 h runs are in §6.

**Verdict: not green.** The tooling works end to end. It found three product defects (D1–D3), and all of them are reproducible with the commands given.

### 5.1 Random soak, 15 min, seed 5150

`soak_host.py -p ios -d 6663101E-… -m ~/danaview-models soak --minutes 15 --seed 5150` was run three times while the diagnostics were being tightened. The last run gave:

- 937 ops in 903 s across 4 projects (three of them rotated out by the size limit)
- 38 reopen checks
- 907 RSS samples

| Criterion | Result | Evidence |
|---|---|---|
| No crash | **pass** | The host saw the same app pid for the whole run, and the flutter connection survived. |
| No unhandled exception | **pass** | 0 framework errors and 0 uncaught zone errors. |
| Project always reopens valid | **pass** | 38 of 38 reopens were valid: no validator violations, no repairs on open, no stray recovery journal. Each rotated project also passed its store check. |
| Memory growth ≤ 10 % | **pass** | Baseline 369.0 MB, end 314.8 MB, peak 615.4 MB (during captions and export). Growth was **−14.7 %**. The earlier two runs gave −15.7 % and −13.9 %. The host's outside RSS samples agree: the app stayed at 200–400 MB after the warm-up. |
| Nothing hangs, every op works | **FAIL** | 13 failed ops. All of them trace back to D1, D2 and D3. |

Ops that ran (ran/skipped/failed):

- seek 72, scrub 51, play 59, frameStep 37
- split 69, undo 85, redo 35, copyPaste 31, duplicate 33, delete 39
- dragMove 37, dragTrim 43
- text 24, marker 20, speed 29, transition 17, zoom 36, selectAll 18
- reverse 23, freeze 19/1/0, proxy 10, export 4/0/10, captions 5/2/0
- background 25/0/2, inactive 25, call 9 (simulated), offline 10/0/1
- audioRoute 0/9 and lowStorage 0/9: refused on the simulator (see §6)
- reopen 38

**D1 · Export stalls forever (iOS export).** This reproduced in all three runs with seed 5150, at the first export of a "complete" kind after about 160 random ops:

- Run 2: stuck at 46.1 % (291/631 frames, phase `rendering`) on a 21.0 s project.
- Run 3: stuck at 95.4 % (888/931 frames) on a 31.0 s project.

The sheet keeps showing "A few seconds left", and progress never moves again: the soak waited 120 s, and 6 min in the first run. The project at the moment of the stall is saved as `build/soak/ios/<udid>/files/soak-stall-165.json`. In that project the video lane ends at 20.0 s, while three 10 s copies of the speech clip run on the audio lane to 31.0 s. The main lane mixes 1.5×, 0.5× and reversed pieces of `frame_counter` with stills and `tone_under_video`. Replay it with `--seed 5150`. The owner is the native iOS export (IOS-13 / IOS-17 segmented writer).

**D2 · After a stalled export is cancelled, every later export fails.** After D1 the soak cancels the stuck job, through the controller as the sheet's Cancel does. From then on, every export in the process ends in `ExportFailed(exportFailed.unknown)`, with "The export didn't finish. Try again". This happened 10 times out of 10 in run 3, including in brand-new projects and minutes later. Each failing project is saved as `files/soak-failed-<op>.json`. Two reverse jobs failed in the same period of run 2 (`the reverse task failed`), and two background ops in run 3 saw a black preview 1 s after the return. The exporter (and possibly the shared writer and encoder) is left in a bad state, and only a relaunch clears it. The owner is the iOS export coordinator (IOS-13).

### 5.2 Process death per job type

`soak_host.py … death`: the full chain ran from 12:28 to 12:41. The captions phase was re-run at 12:47 after the test was fixed (§5.3).

| Job | Result | Evidence |
|---|---|---|
| autosave | **pass** | The kill landed while the text was edited every 40 ms. On relaunch, Projects offered the journal, Restore reopened a valid project holding `SOAK AUTOSAVE 0`, and the store check was clean. |
| export | **pass** | Killed at 13 % (32 s, 1080p). `activeJobs()` reported exactly one `ExportInterrupted` and nothing running. The editor showed it once, and after acknowledgement the record was gone. A reopened editor's `reattach()` found nothing. The simulator's export left no complete segment, so it was not resumable. |
| captions | **pass** | Killed at 56 % of a 60 s speech WAV (the host builds it from `speech_10s.m4a` with `afconvert`). `resumableFor` kept the record. "Auto captions were interrupted" showed once. After Discard, the reopen showed no notice and the record was gone. The project was valid. |
| proxy | **FAIL (D3)** | On reopen the asset still says `proxy: pending`, and no task runs. Nothing changed after 90 s. When the test then reads `tasksControllerProvider`, the proxy starts and completes. |
| reverse | **FAIL (D3)** | Killed at 2 %. The rendition stays `pending` on reopen, and the clip plays its placeholder. It is only rebuilt once `tasksControllerProvider` is read. |
| freeze | **FAIL (D3)** | Same as reverse for the pending still. |

**D3 · Pending reverse, freeze and proxy jobs are not resumed when the editor opens.** `TasksController` re-queues pending assets in `_reconcile()`, as ARCH §15 says ("jobs are re-queued automatically"). But `tasksControllerProvider` is `autoDispose`, and it is first read only by the reverse/freeze/clip-info bindings, the Clip info panel and the Tasks sheet. Nothing reads it when the editor opens, so after a crash (or a normal close mid-job) the pending asset stays pending until the user happens to touch one of those. Until then:

- Export waits forever on `exportBlockersOf` ("waiting for reverse").
- The clip shows its placeholder.

The fix belongs in the editor's open path. Either the editor screen or session (UX-07 / UX-08) reads `tasksControllerProvider(id)` when the session attaches, or UX-35's `createTasksController` is started by the session. The QA-05 death phases will pass unchanged once it lands. They already wait 90 s without any user action.

### 5.3 What changed in the suite while running it

- **The captions wait.** It now treats new cue ids as "done". With "Replace previous captions", the cue count stays the same.
- **No speech.** "No speech found" on an edited-down speech clip counts as an answer, not a failure.
- **Thrown errors in waits.** Errors thrown inside a bounded wait are `TestFailure`s now. `E2eApp.pumpUntil` swallows other exceptions as "not ready yet", which turned failures into 6-minute timeouts.
- **Export.** The export waits now detect a stall (no progress for 120 s) and dump the project.
- **Captions death phase.** It kills only while the job is transcribing, after the job record is written. The record is written only after model load and language detection, so the first run's "no record" was a test artifact.
- **Summary in the log.** The run summary is also printed as a `DV_SOAK summary` line. A failing `flutter test` uninstalls the app before the host can copy the JSON, so the host extracts the line into `files/soak-summary-log.json`.


## 6. Deferred

| Item | Status | How to run it |
|---|---|---|
| 1 h soak on a physical iPhone (plus calls, Siri, a wired or Bluetooth audio route change, and real low storage) | **deferred: no device available** | `flutter test integration_test/editor_soak/soak_test.dart -d <iphone> --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true --dart-define=DV_SOAK_MINUTES=60 --dart-define=DV_E2E_MODELS=<on-device dir>`. During the hour: place two calls to the phone, invoke Siri twice, plug and unplug headphones (or connect and disconnect a Bluetooth headset) during playback, and fill storage to less than 300 MB free with a large file. Then run the death phases with `soak_host.py` adapted to `xcrun devicectl` (kill: `devicectl device process terminate`). Record the summary JSON and Xcode's memory gauge. |
| 1 h soak on the Android emulator (API 35) with GSM calls, low storage and process death | **deferred: the 15 min run is not green yet on 034a0d3 (§A0: D10 residual, the a1 SIGSEGV), and `soak_host.py` needs W4b on Android** | After those land: `python -I -B integration_test/editor_soak/tool/soak_host.py -p android -d emulator-5554 all --minutes 60` from Git Bash (after the `e2e_host.sh stage` and `stage-models` steps above). W1–W7 landed in 5912db4, so no wrapper is needed. Until W4b lands, open the shared folders to the app first (§A0.1). |
| Freeze resume after process death on Android | **not exercised** | In both Android chains the freeze finished before the kill (the allowed caveat), so the resume of a pending still was not seen on Android. A longer freeze source, or a kill timed on the task's start, would exercise it. |
| 1 h soak on a physical Android device (audio route via headset, real calls, low storage) | **deferred: Windows lane / no device available** | `python3 -I integration_test/editor_soak/tool/soak_host.py -p android -d <serial> all --minutes 60`. `call` and `lowStorage` are emulator-only in the host, so on a device do them by hand during the hour, as for the iPhone. |
| Audio route change | **deferred: no device available** | Neither the simulator nor the emulator can change the audio route from a script. The host answers `audioRoute` with ok=false, and the soak records it under `unavailable`. |
| Low storage on iOS | **deferred: no device available** | The iOS Simulator's data container is on the Mac's own disk, so the host refuses to fill it. |
