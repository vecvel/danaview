<!-- OWNER: QA-05 -->

# QA-05 · Robustness soak

This report covers BUILD_PLAN QA-05 (M6). The ticket asks for a 1 h random-edit soak on one iOS device and one Android device. The soak runs scripted random commands, gestures, play and scrub, export starts and cancels, and Auto captions with the tiny model. It adds interruptions (calls or Siri, audio route changes, background and foreground), low storage, media going offline mid-session, and process death during each job type (proxy, reverse, freeze, export, captions, autosave).

The acceptance criteria are:

- no crash
- no unhandled exception
- memory growth of 10 % or less over the hour
- every interrupted job recovers, or reports "interrupted" exactly once
- the project always reopens valid

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

## 2. Re-run after the D1, D2 and D3 fixes (QA-05-RERUN)

All runs used the **iPhone 16 simulator on iOS 26.5** (`6663101E-6BE7-47D4-B3B8-055700BF2E02`), with Xcode 26.6, Flutter 3.44 and a debug build, on 2026-10-16, 16:41 to 17:55. The fixes under test are FIX-IOS-EXPORT-STALL (D1, D2: `ReaderWriterPipeline` spacer anchor, bounded writer waits, per-job work queues) and FIX-JOB-RESUME (D3: `createEditorController` reads `tasksControllerProvider` when the session attaches). Runs stayed at 15 minutes on this 8 GB Mac.

**Verdict: not green.** D1 and D2 are fixed: the seeded soak with seed 5150 now passes. The D3 fix is incomplete: proxy, reverse and freeze still do not recover after process death, now because of a new defect, D5. Autosave, export and captions recover.

### 2.1 Random soak, 15 min, seed 5150

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
- audioRoute 0/8 and lowStorage 0/10: refused on the simulator (see §4)
- reopen 34

**D1 is fixed.** Op #165, the export that used to stall at the first "complete" kind, completed in 8.9 s in run b. Every export completed, was cancelled or was correctly blocked: in run b there were 7 completions (2 of them after a background), 7 cancels, and 2 `ExportUiWaiting` blocks while a reverse was pending. Run c had the same mix with 13 exports. No export stalled.

**D2 is fixed.** Exports after a cancel kept succeeding in every run: run b completed 3 exports after the cancel at op #929. There was no `exportFailed.unknown`, and no reverse failed.

**D6 · The preview sometimes does not come back after a background (intermittent).** This happened in run a only, on a loaded Mac (574 ops in 15 min, against 843–1042 in the other runs):

- Ops #430 and #431 (background for 2 s, during playback and idle): the editor was `ready`, but the preview did not reach `ready` with a live session within 60 s, twice in a row. Op #436 (offline) then hit the same wait. The soak's recovery then counted the editor as ready, so it did not reopen it; the preview came back by op #495.
- Ops #45 and #498 (background during playback): the frame was black 1 s after the return.

Runs b and c, with the same seed, did not reproduce it at those ops (they passed in 5–8 s). Run a used the original black-frame check, which could not tell black content from a dead preview, so #45 and #498 are inconclusive. #430 and #431 are not inconclusive: the preview phase stayed short of `ready` for over a minute. The owner is the preview's background and foreground lifecycle: the iOS preview session, and the editor's preview restart in UX-08. The suite now records the editor and preview phases in every stuck line. Its recovery also reopens the project when the preview is not live, so if this happens again it fails one op, not three.

### 2.2 Process death per job type

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

### 2.3 What changed in the suite in this re-run

- **`background` op.** A black frame is compared with a reference frame taken before leaving (§1.1). In run b, the first version of this check failed op #789: playback had stopped at frame 815 in a gap, and the frame it started from was black too. With the reference check, the same op passed in run c ("frame 815 is black content; frame 0 shows a picture"). A preview that stays black after a re-seek is still a failure.
- **Stuck lines.** Each stuck line now carries the editor phase, the preview phase and failure, and whether a preview session is open.
- **Recovery.** After a failed op, the soak reopens the project unless the editor is ready *and* the preview is live.

`flutter analyze integration_test/editor_soak`: no issues.

## 3. First run, before the fixes (QA-05)

All runs below used the **iPhone 16 simulator on iOS 26.5** (`6663101E-6BE7-47D4-B3B8-055700BF2E02`), with Xcode 26.6, Flutter 3.44 and a debug build, on 2026-10-16. On this 8 GB Mac the soak was kept to 15 minutes. The 1 h runs are in §4.

**Verdict: not green.** The tooling works end to end. It found three product defects (D1–D3), and all of them are reproducible with the commands given.

### 3.1 Random soak, 15 min, seed 5150

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
- audioRoute 0/9 and lowStorage 0/9: refused on the simulator (see §4)
- reopen 38

**D1 · Export stalls forever (iOS export).** This reproduced in all three runs with seed 5150, at the first export of a "complete" kind after about 160 random ops:

- Run 2: stuck at 46.1 % (291/631 frames, phase `rendering`) on a 21.0 s project.
- Run 3: stuck at 95.4 % (888/931 frames) on a 31.0 s project.

The sheet keeps showing "A few seconds left", and progress never moves again: the soak waited 120 s, and 6 min in the first run. The project at the moment of the stall is saved as `build/soak/ios/<udid>/files/soak-stall-165.json`. In that project the video lane ends at 20.0 s, while three 10 s copies of the speech clip run on the audio lane to 31.0 s. The main lane mixes 1.5×, 0.5× and reversed pieces of `frame_counter` with stills and `tone_under_video`. Replay it with `--seed 5150`. The owner is the native iOS export (IOS-13 / IOS-17 segmented writer).

**D2 · After a stalled export is cancelled, every later export fails.** After D1 the soak cancels the stuck job, through the controller as the sheet's Cancel does. From then on, every export in the process ends in `ExportFailed(exportFailed.unknown)`, with "The export didn't finish. Try again". This happened 10 times out of 10 in run 3, including in brand-new projects and minutes later. Each failing project is saved as `files/soak-failed-<op>.json`. Two reverse jobs failed in the same period of run 2 (`the reverse task failed`), and two background ops in run 3 saw a black preview 1 s after the return. The exporter (and possibly the shared writer and encoder) is left in a bad state, and only a relaunch clears it. The owner is the iOS export coordinator (IOS-13).

### 3.2 Process death per job type

`soak_host.py … death`: the full chain ran from 12:28 to 12:41. The captions phase was re-run at 12:47 after the test was fixed (§3.3).

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

### 3.3 What changed in the suite while running it

- **The captions wait.** It now treats new cue ids as "done". With "Replace previous captions", the cue count stays the same.
- **No speech.** "No speech found" on an edited-down speech clip counts as an answer, not a failure.
- **Thrown errors in waits.** Errors thrown inside a bounded wait are `TestFailure`s now. `E2eApp.pumpUntil` swallows other exceptions as "not ready yet", which turned failures into 6-minute timeouts.
- **Export.** The export waits now detect a stall (no progress for 120 s) and dump the project.
- **Captions death phase.** It kills only while the job is transcribing, after the job record is written. The record is written only after model load and language detection, so the first run's "no record" was a test artifact.
- **Summary in the log.** The run summary is also printed as a `DV_SOAK summary` line. A failing `flutter test` uninstalls the app before the host can copy the JSON, so the host extracts the line into `files/soak-summary-log.json`.


## 4. Deferred

| Item | Status | How to run it |
|---|---|---|
| 1 h soak on a physical iPhone (plus calls, Siri, a wired or Bluetooth audio route change, and real low storage) | **deferred: no device available** | `flutter test integration_test/editor_soak/soak_test.dart -d <iphone> --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true --dart-define=DV_SOAK_MINUTES=60 --dart-define=DV_E2E_MODELS=<on-device dir>`. During the hour: place two calls to the phone, invoke Siri twice, plug and unplug headphones (or connect and disconnect a Bluetooth headset) during playback, and fill storage to less than 300 MB free with a large file. Then run the death phases with `soak_host.py` adapted to `xcrun devicectl` (kill: `devicectl device process terminate`). Record the summary JSON and Xcode's memory gauge. |
| 1 h soak on the Android emulator (API 35) with GSM calls, low storage and process death | **deferred: Windows lane** | `python3 -I integration_test/editor_soak/tool/soak_host.py -p android -d emulator-5554 all --minutes 60` (after the `e2e_host.sh stage` and `stage-models` steps above). |
| 1 h soak on a physical Android device (audio route via headset, real calls, low storage) | **deferred: Windows lane / no device available** | `python3 -I integration_test/editor_soak/tool/soak_host.py -p android -d <serial> all --minutes 60`. `call` and `lowStorage` are emulator-only in the host, so on a device do them by hand during the hour, as for the iPhone. |
| Audio route change | **deferred: no device available** | Neither the simulator nor the emulator can change the audio route from a script. The host answers `audioRoute` with ok=false, and the soak records it under `unavailable`. |
| Low storage on iOS | **deferred: no device available** | The iOS Simulator's data container is on the Mac's own disk, so the host refuses to fill it. |
