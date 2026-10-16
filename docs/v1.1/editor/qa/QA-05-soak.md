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
| `integration_test/editor_soak/soak_test.dart` | The random soak. It is one `testWidgets` that drives the real app for `DV_SOAK_MINUTES` minutes (default 60) with a seeded sequence of 29 op types. It uses QA-00's `E2eApp` and `E2eEditor`, so it has the real app wiring and the production engine. |
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
| Interruptions | `background` (2): the host backgrounds the app for 1–5 s, during playback half the time. One second after the return, the preview must not be black. `inactive` (2): the lifecycle goes inactive → resumed, which is what a call banner, Siri or Control Center produce. `call` (1): a host GSM call on the Android emulator; on iOS it falls back to the lifecycle simulation. `audioRoute` (1). `lowStorage` (1): the host fills storage, then the soak does an edit, a manual save and an export, then frees the storage. `offline` (1): a media file used on the timeline is moved away, and the media health must show it offline. The soak keeps seeking, playing, splitting and exporting (the export must be blocked), then moves the file back, and the media must come back. |
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

## 2. Results: iOS Simulator

RESULTS_PLACEHOLDER

## 3. Deferred

| Item | Status | How to run it |
|---|---|---|
| 1 h soak on a physical iPhone (plus calls, Siri, a wired or Bluetooth audio route change, and real low storage) | **deferred: no device available** | `flutter test integration_test/editor_soak/soak_test.dart -d <iphone> --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true --dart-define=DV_SOAK_MINUTES=60 --dart-define=DV_E2E_MODELS=<on-device dir>`. During the hour: place two calls to the phone, invoke Siri twice, plug and unplug headphones (or connect and disconnect a Bluetooth headset) during playback, and fill storage to less than 300 MB free with a large file. Then run the death phases with `soak_host.py` adapted to `xcrun devicectl` (kill: `devicectl device process terminate`). Record the summary JSON and Xcode's memory gauge. |
| 1 h soak on the Android emulator (API 35) with GSM calls, low storage and process death | **deferred: Windows lane** | `python3 -I integration_test/editor_soak/tool/soak_host.py -p android -d emulator-5554 all --minutes 60` (after the `e2e_host.sh stage` and `stage-models` steps above). |
| 1 h soak on a physical Android device (audio route via headset, real calls, low storage) | **deferred: Windows lane / no device available** | `python3 -I integration_test/editor_soak/tool/soak_host.py -p android -d <serial> all --minutes 60`. `call` and `lowStorage` are emulator-only in the host, so on a device do them by hand during the hour, as for the iPhone. |
| Audio route change | **deferred: no device available** | Neither the simulator nor the emulator can change the audio route from a script. The host answers `audioRoute` with ok=false, and the soak records it under `unavailable`. |
| Low storage on iOS | **deferred: no device available** | The iOS Simulator's data container is on the Mac's own disk, so the host refuses to fill it. |
