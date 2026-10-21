<!-- OWNER: QA-02 -->

# QA-02: E2E suite on the Android Emulator

This report covers QA-00's app-level suite (`integration_test/editor`, ARCH §21.2) run on Android
Emulators on the Windows laptop (BUILD_PLAN QA-02). It also holds the API 28 below-gate checks, the
Android export extra on API 34 and API 35, the tablet run of scenario 12, and the manual tablet
steps for the owner (hardware keyboard, mouse, drag from Files and Photos).

**Status (2026-10-21, 23:00 IST): not certified.** The clean pass on code E (`editor-android`
**88469c0**) ran on every device in the matrix. No Android-lane code change was made during or
after it, so every result in this report's matrix ran on 88469c0. Most items now pass. Four are
still open: two are environment items, one is a Mac fix, and one is an owner step.

- **API 35 phone (`emulator-5554`, one command, fresh install, audio, models):** 20 of 22 batches
  pass, with 0 emulator restarts. **16 of 18 scenarios and all 7 extra phases pass in the batch**,
  s08 included. fgs-check and swipe-check both return `finished` with `detached=true`, so the
  **AND-12 detached export is proven on API 35**. M-21 is fixed: the swipe removes the app's own
  task by id.
  - **s07** timed out in the batch because the host laptop hibernated on critical battery
    (19:08:29–20:10:21) mid-export. It **passes alone** on the same code.
  - **s13** fails on the export level in the batch (-66.3 dBFS) and in 2 of 3 solo runs (-76.2 and
    -69.4 dBFS; it needs > -60); the third solo run failed differently (Stop not applied, flaky). The cause is the laptop microphone, which feeds the emulator
    near-silence. This is an emulator reality.
- **API 34 (`emulator-5556`, from `dv2`):** **all 7 extra phases pass**. Notification Cancel
  passes, so M-7 is fixed. The fgs pair was in the batch when the same host hibernation hit, and
  passed alone right after. With that, **AND-12 is proven on API 34** for both fgs and swipe.
- **API 29 (GLES 3, tier LOW):** s01–s04 and s18 **all pass in one batch**. s02 passing means M-9
  is fixed.
- **API 29 2 GB (tier MINIMAL):** s01–s04 pass. **s18 fails** 2 of 3 runs on the barcode after the
  reopen (0 instead of 77). The cause is a race in the open sequence (FIX M-22, Mac).
- **API 28:** `x_android_api28` really runs and **passes**, so M-10 is fixed.
- **Tablet:** **s12 passes**, so M-3 and M-4 are fixed. The owner's manual checklist M1–M4 has
  not been run.
- **s09 owner check:** "leaving the editor" is always followed by "exit callback". The Android
  native preview release does not block the main thread, and no Android-lane fix was needed.

"What remains for certification" at the end lists the open items with their owners. Older results
(codes A–D) are summarised in a short history note under "Results matrix".

## Scope

From BUILD_PLAN QA-02:

- **API 35** x86_64 Pixel phone: the full suite (s01–s18 and the Android extra).
- **API 29**: the editor gate and the core flows, with GLES 3.
- **API 29, 2 GB RAM**: the low-RAM configuration for the minimal tier (D-40).
- **API 34**: dataSync FGS export with the activity destroyed, notification Cancel, swipe from
  recents mid-export.
- **API 28**: Home edit button shows, Projects shows the `android_too_old` copy, the player's Edit
  explains, the existing player tests stay green.
- **Tablet** with keyboard and mouse: scenario 12, and the manual cross-app drag and drop.

Emulator realities are reported, not failed.

## How to run

Use Git Bash. Start each window with `source ~/danaview_env.sh` and `cd` to the repo root.

```bash
scripts/ci/editor/e2e_android.sh                          # Pixel_9_Pro_XL_API_35, every batch
scripts/ci/editor/e2e_android.sh Pixel_API_34             # another AVD, booted when not running
scripts/ci/editor/e2e_android.sh emulator-5554            # an already running emulator
DANAVIEW_E2E_ONLY="s01 s07 x_android_export_background" scripts/ci/editor/e2e_android.sh
DANAVIEW_E2E_DRY_RUN=1 scripts/ci/editor/e2e_android.sh   # print batches and commands only
```

The certifying API 35 command:

```bash
DANAVIEW_E2E_FRESH=1 DANAVIEW_E2E_AUDIO=1 DANAVIEW_E2E_MODELS=<models dir> scripts/ci/editor/e2e_android.sh
```

Useful settings (the full list is in the script header):

| Setting | Effect |
|---|---|
| `DANAVIEW_E2E_MODELS=<models dir>` | stages the speech models for s08; without it, s08 is PENDING |
| `DANAVIEW_E2E_AUDIO=1` | boots with audio and turns the host mic on (`adb emu avd hostmicon`), for s13 |
| `DANAVIEW_E2E_FRESH=1` | uninstalls the app first; also turns on `DANAVIEW_E2E_RESET` |
| `DANAVIEW_E2E_RESET=1` | clears app data (`pm clear`) and restages before every batch except the first |
| `DANAVIEW_E2E_BATCH_TIMEOUT` / `DANAVIEW_E2E_PHASE_TIMEOUT` | per batch (2400 s) / per flutter run (1200 s) |

The script boots the AVD headless, stages the fixtures (and the models), and runs each scenario
file as its own batch, so one crash cannot sink the rest. The Android extra runs as four phase
pairs (`fgs`, `cancel`, `swipe`, `death`). An emulator that stops answering is booted again (at
most 3 times), and the batch it died in is marked `*` in `summary.txt`. On API < 29 only
`x_android_api28` runs.

**POST_NOTIFICATIONS.** The app asks the host for the `grantNotifications` action when an export
starts (QA-00, e0fa7e8). That happens after `flutter test` has installed the app, so the grant is
never lost to a reinstall. On API 35 every export of the reruns started; none waited at
"Preparing…".

Evidence goes to `build/e2e/android/<serial>/`, with `logs/` (a log and a logcat per batch),
`screens/`, `files/` and `summary.txt`. Manual evidence goes to `build/e2e/android/manual/`.
`build/` is not committed. The folders this report cites are listed under "Evidence".

### Two emulators at once

The owner approved running a second emulator in parallel, under these rules:

- **Separate checkouts.** Two `flutter` builds in one checkout clash in
  `:app:compressDebugAssets` (`kernel_blob.bin`), and the single Gradle worker does not prevent
  it. The second emulator builds only from a plain copy of the tracked files (a sibling folder, `dv2`), which
  is refreshed from the main checkout before each round. Its evidence is copied back to
  `build/e2e/android/` in the main checkout.
- **Separate serials and locks.** `emulator-5554` (lock `build/danaview_locks/emulator`) and
  `emulator-5556`, booted with `-port 5556` (lock `build/danaview_locks/emulator2`). Every `adb`
  command carries `-s <serial>`. `e2e_android.sh` never runs `adb kill-server` (since
  2026-10-21), so a restart of one emulator cannot cut off the other.
- **Stray host loops (Windows).** `e2e_host.sh serve` loops can outlive their phase and then handle
  the next phase's host request 2–3 times. `e2e_android.sh` now stops leftover loops of its own
  serial before and after each extra phase (`kill_stray_serve`). Before a manual batch, kill only
  your own serial's loops (`ps -ef | grep e2e_host.sh | grep <serial>`).
- Both emulators run slower in parallel. On 2026-10-16 at 20:53 both emulators died at the same
  moment (see "Emulator realities"). Run the certifying API 35 pass and the manual tablet steps
  with only one emulator running.

### Single Gradle worker

Since 2026-10-15, Gradle builds on this laptop hung in `WindowsNativeDispatcher.CreateFile0` while
creating cache lock files under parallel workers. The suspected cause is the Seqrite filter driver.
`~/.gradle/gradle.properties` (user-level, outside the repo) sets `org.gradle.workers.max=1` and
`org.gradle.parallel=false`. Builds are slower but do not hang. Remove the setting once IT adds
antivirus exclusions for the repo, `~/.gradle`, the SDK and the JBR.

## Environment

Collected 2026-10-16 with read-only commands on the Windows laptop (Git Bash after
`source ~/danaview_env.sh`, plus PowerShell `Get-CimInstance`).

**Host**

| Item | Value |
|---|---|
| Machine | HP ProBook 440 14 inch G11 Notebook PC |
| OS | Windows 11 Pro, 64-bit, version 10.0.26300.9711 |
| CPU | Intel Core Ultra 7 155H, 16 cores / 22 threads |
| RAM | 31.5 GB |
| GPU | Intel Arc Graphics (driver 32.0.101.8508) |
| Hypervisor | WHPX 10.0.26300, "installed and usable" (`emulator -accel-check`) |
| Antivirus | Seqrite Endpoint Security (active); Microsoft Defender passive |
| Microphone | Built-in Microphone Array (Intel Smart Sound Technology for Digital Microphones). The AVDs have `hw.audioInput=yes`. `DANAVIEW_E2E_AUDIO=1` turns the host mic on for s13. |

**Toolchain**

| Item | Value |
|---|---|
| Flutter | 3.44.8 stable, framework 058e0af2c2 (2026-07-23), engine 13ffd72b2f |
| Dart | 3.12.2 |
| JDK | Android Studio JBR, OpenJDK 21.0.10 |
| Platforms | android-35, -36, -36.1, -37.0 (app: compileSdk 36, targetSdk 36) |
| Build-tools / NDK / CMake | 36.0.0 / 28.2.13676358 / 3.22.1 |
| Platform-tools (adb) | 37.0.0 |
| Emulator | 36.6.11.0 (build 15507667). `VirtioMouse` is on by default. |
| System images | android-28, -29, -34, -35 `google_apis` x86_64 |

**Speech models for s08.** Staged from a models folder outside the repo (`<models dir>`; never copied in). The suite
downloads nothing. The SHA-256 values were checked on 2026-10-16, and both match the catalog.

| File | Size (bytes) | SHA-256 |
|---|---|---|
| `ggml-tiny-q5_1.bin` | 32 152 673 | `818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7` |
| `ggml-silero-v6.2.0.bin` | 885 098 | `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987` |

**Test media.** The ENG-05 fixtures from `packages/danaview_editor_engine/test_fixtures/media/`.
`e2e_host.sh stage` pushes them to `Android/data/com.vecvel.danaview/files/e2e_fixtures/`.

**Builds.** Debug builds, the build `flutter test` makes for integration tests. They use the
editor dart-defines `DANAVIEW_EDITOR=true` and `DANAVIEW_AUTO_CAPTIONS=true`, plus the suite's
test-only `DV_E2E_*` defines. BUILD_PLAN says the suite runs "with the release dart-defines". The
editor defines are the release ones. The build mode is debug, because `flutter test` builds that
way.

## Device matrix

All AVDs: x86_64, `google_apis` (no Play Store), GPU `auto` (SwiftShader, GLES 3.0; the tablet is
booted with `-gpu host`), audio input on, 16 GB data. The RAM column is the effective `hw.ramSize` from `hardware-qemu.ini`. On the
API 35 images the emulator raises the 3072 MB of `config.ini` to 4096 MB, which matches the
`ram=4110…` value the app logs.

| AVD | API | Profile | Screen | RAM | Certifies (BUILD_PLAN QA-02) |
|---|---|---|---|---|---|
| Pixel_9_Pro_XL_API_35 | 35 | pixel_9_pro_xl | 1344×2992, 480 dpi | 4096 MB | full suite: s01–s18 and the 4 export phase pairs |
| Pixel_Tablet_API_35 | 35 | pixel_tablet | 2560×1600, 320 dpi | 4096 MB | s12; manual keyboard, mouse, drag from Files and Photos (`hw.keyboard=yes`, set 2026-10-16) |
| Pixel_API_34 | 34 | pixel_6 | 1080×2400, 420 dpi | 3072 MB | dataSync FGS export with the activity destroyed, notification Cancel, swipe from recents |
| Pixel_API_29 | 29 | pixel_6 | 1080×2400, 420 dpi | 3072 MB | editor gate and core flows (s01–s04, s18); GLES 3; booted with `-feature GLESDynamicVersion` |
| Pixel_API_29_2GB | 29 | pixel_6 | 1080×2400, 420 dpi | 2048 MB | low-RAM, minimal tier (D-40) |
| Pixel_API_28 | 28 | pixel_6 | 1080×2400, 420 dpi | 3072 MB | below-gate checks |

## Code versions

**Current: E = 88469c0** (`editor-android`, 2026-10-21). This is editor-wip merged again: c336899
(the Mac fixes for M-1..M-17 and the QA-00 harness changes for M-6/M-7) and 88469c0 (FIX M-21:
`swipeFromRecents` removes the app's own task by id). It also brings the Mac's round 9 Dart fixes
in editor_controller, editor_session, relink and preview_status, and an s13 test change. It
contains every earlier Android-lane fix (M-11, M-12, M-16..M-20, and the capture fix ae6cda2).

| Where | Code as run |
|---|---|
| API 35 phone, main checkout `C:/dev/danaview`, `emulator-5554`, 18:31–22:15 | 88469c0, plus one uncommitted runner change: `e2e_android.sh` never restarts the adb server (later committed unchanged by the backup loop as 8e6a403). That change touches neither the app nor the tests. |
| API 34, API 29, API 29 2 GB and API 28, copy `C:/dev/dv2`, `emulator-5556`, 18:52–22:33 | 88469c0 app and tests, plus the same runner-only change as the API 35 run (`e2e_android.sh` no longer runs `adb kill-server`; later committed as 8e6a403). `dv2` (a plain copy, not a git repository) was refreshed from the main checkout's tracked files at 18:29:42. |
| Tablet, copy `C:/dev/dv2`, `emulator-5556`, 22:37–22:40 | 88469c0 app and tests. `dv2` matched HEAD 70a855a, which differs from 88469c0 only in this report and in the runner change above. |

**No Android-lane code change** was made during or after the pass, so no scenario needed a rerun
on fixed code.

Earlier labels, used only in the history note:

- **A:** 542dcc6, before e0fa7e8.
- **B:** d723c10 up to 0ad2477, with e0fa7e8 and AND-14.
- **C:** 0cfc691.
- **C+:** C plus the `debugCaptureFrame` fix.
- **D:** 3d38ef2, editor-wip c336899 with the Android-lane fixes. All of these ran on
  2026-10-16/17.

## Results matrix

This is the clean pass of 2026-10-21. **Every result below ran on code E (88469c0).** Every device
started from a fresh install. Each run used the §4.3 command. `emulator-5554` ran from the main
checkout, and `emulator-5556` ran from `dv2`. The gate AVDs and the tablet add their serial, and
the tablet run adds `DANAVIEW_E2E_ONLY=s12`:

`DANAVIEW_E2E_FRESH=1 DANAVIEW_E2E_AUDIO=1 DANAVIEW_E2E_MODELS=C:/dev/models scripts/ci/editor/e2e_android.sh [serial]`

The two serials ran at the same time, from separate checkouts: `emulator-5554` ran from 18:31 to
22:15, and `emulator-5556` ran one AVD at a time from 18:52 to 22:40. No emulator restarted in any
run. Each failed batch was rerun alone on a fresh install: s07 and the API 34 fgs pair once, s18
on the 2 GB AVD twice, and s13 three times. The "Batch" column is the clean-pass result; the
"Alone" column is the rerun on the same code.

### Overview

| # | API 35 phone | API 29 | API 29 2 GB | Tablet | API 34 |
|---|---|---|---|---|---|
| s01 | **pass** | **pass** | **pass** | — | — |
| s02 | **pass** | **pass** | **pass** | — | — |
| s03 | **pass** | **pass** | **pass** | — | — |
| s04 | **pass** | **pass** | **pass** | — | — |
| s05, s06 | **pass** | — | — | — | — |
| s07 | **timeout** (host hibernated); alone **pass** | — | — | — | — |
| s08 | **pass** (3 cues) | — | — | — | — |
| s09 | **pass** | — | — | — | — |
| s10, s11 | **pass** | — | — | — | — |
| s12 | **pass** | — | — | **pass** | — |
| s13 | **fail** (host mic); alone **fail** ×3 | — | — | — | — |
| s14–s17 | **pass** | — | — | — | — |
| s18 | **pass** | **pass** | **fail**; alone **fail**, then **pass** (FIX M-22) | — | — |
| x: fgs / fgs-check | **pass** / **pass** | — | — | — | **pass** / **timeout** (host hibernated); pair alone **pass** / **pass** |
| x: cancel | **pass** | — | — | — | **pass** |
| x: swipe / swipe-check | **pass** / **pass** | — | — | — | **pass** / **pass** |
| x: death / death-check | **pass** / **pass** | — | — | — | **pass** / **pass** |

API 28 is in its own table below.

### API 35 phone (Pixel_9_Pro_XL_API_35, `emulator-5554`)

The run used the main checkout, from 18:31 to 21:37. Of 22 batches, 20 passed, with 0 emulator
restarts. Evidence is in `emulator-5554/full/`, and the solo reruns are in `emulator-5554/solo/`.

| Batch | Batch (time) | Alone (fresh install) | Note |
|---|---|---|---|
| s01–s06 | **pass** (409, 189, 203, 219, 243, 361 s) | | |
| s07 | **timeout** (4129 s) | **pass** (482 s; both exports verified) | the host laptop hibernated mid-export (see below) |
| s08 | **pass** (449 s) | | in the batch, with the models: 3 cues |
| s09 | **pass** (357 s; edit + recover) | | close trace below |
| s10–s12 | **pass** (195, 158, 394 s) | | s12 marquee passes on the phone |
| s13 | **fail** (369 s): -66.3 dBFS | **fail** ×3: (a) Stop not applied within 30 s; (b) -76.2 dBFS; (c) -69.4 dBFS (tone on the laptop speakers) | host microphone silence, an emulator reality |
| s14–s18 | **pass** (296, 263, 401, 388, 169 s) | | s18 with the capture fix, in the batch |
| x: fgs + fgs-check | **pass** + **pass** (389 s) | | `destroyActivity: no ActivityRecord left (attempt 1)`; FGS `types=0x00002000`; `export ex_0500…: done … detached=true`; the relaunch shows the finished card |
| x: cancel | **pass** (158 s) | | |
| x: swipe + swipe-check | **pass** + **pass** (366 s) | | `swipeFromRecents: task 822 removed by id (attempt 1)`; `export ex_295c…: done … detached=true`; the relaunch shows the finished card |
| x: death + death-check | **pass** + **pass** (349 s) | | |

**s07: a host power event, not the app.** The first export passed (`E2E export 18229.mp4`,
4,305,971 B). The second export started at 19:07:46.

- Logcat: the last line from any process is at 19:08:32, and the next is at 20:10:21.
- Windows System log:
  - 19:08:25: Kernel-Power 524, "Critical Battery Trigger Met".
  - 19:08:29: Kernel-Power 42, "Sleep Reason: Battery".
  - 20:10:21: resume from hibernate.
- The test then hit its 360 s wait at 93 %, and the batch timeout ended it.

The batch's own s07 logs were overwritten by the solo rerun, because a move of `logs/` was refused
first. The excerpts are kept in `full/s07_batch_note.txt`.

**s13: the host microphone.**

- **What passes:** every take recorded, and the clip reached the voice lane. In the batch, the
  length check passed: the length was within the Record-to-Stop window, 0 µs outside it.
- **What fails:** the export level is -66 to -76 dBFS, against a bar of -60 dBFS.
- **Why:** the laptop microphone fed the emulator near-silence. That held even with a tone played
  on the laptop's speakers (`solo/s13_tone/`, -69.4 dBFS).
- **History:** on code D, s13 passed alone at -53.1 dBFS. The level depends on the room and the
  host input, not on the code.
- **Solo rerun (a) failed differently** (`solo/s13/`). After Stop, the sheet still showed
  "recording", and the clip did not reach the voice lane within 30 s. Two `activeJobs` calls (the
  export lane) timed out meanwhile. There was no ANR, no app error line, and no thread dump. It did
  not happen again in reruns (b) and (c), which took thread dumps (`solo/s13_diag/s13_threads/`,
  `solo/s13_tone/s13_threads/`). It is classified as flaky, with one occurrence. Note that the
  recorder's stop waits at most 5 s for its capture thread (`VoiceRecorder.finish`).

#### s09 close trace (owner's check)

The owner asked: "leaving the editor" without "exit callback" would mean that the Android native
preview release blocks the main thread. **It does not.** The trace below is from
`emulator-5554/full/logs/s09_recovery_after_kill_test-recover.log` (also in
`full/s09_close_trace.txt`):

```
[EditorLifecycle] close requested (shell: ready)
[EditorLifecycle] flushBeforeClose: saved
[EditorLifecycle] release: start
[EditorClose] pr_QYo0BGJu8FtY: start (attached: true, open pending: true)
[EditorClose] pr_QYo0BGJu8FtY: open still finishing (first plan / seek): not awaited
[EditorClose] pr_QYo0BGJu8FtY: flushBeforeClose: saved
[EditorClose] pr_QYo0BGJu8FtY: release: start
[EditorClose] pr_QYo0BGJu8FtY: release: session detached (EditorSession closed)
[EditorClose] pr_QYo0BGJu8FtY: release: plan sync dispose
[EditorClose] pr_QYo0BGJu8FtY: release: preview dispose
[EditorClose] pr_QYo0BGJu8FtY: release: repository close
[EditorClose] pr_QYo0BGJu8FtY: release: end
[EditorClose] pr_QYo0BGJu8FtY: done (CloseOutcome(saved: true))
[EditorLifecycle] release: end
[EditorLifecycle] leaving the editor
[EditorLifecycle] exit callback
```

The rest of the pass agrees:

- Every scenario that closes the editor logs "leaving the editor" and "exit callback" the same
  number of times: s02–s06, s08–s12 and s14–s18 once each, and s10 and s18 twice each.
- No close step logged "timed out".
- No batch logcat has an ANR for the app.

No Android-lane change was needed.

### API 34 (Pixel_API_34, `emulator-5556`, from `dv2`)

| Phase | Batch (18:52–20:34) | Alone (20:35–20:42) | Note |
|---|---|---|---|
| fgs | **pass** | **pass** | FGS `isForeground=true types=00000001` (dataSync) |
| fgs-check | **timeout** (1200 s phase limit) | **pass** | see below; alone: `export ex_791a…: done … detached=true`, `completed while detached; savedToGallery=true notified=true` |
| cancel | **pass** (255 s) | | `cancel sent for ex_f7bd… (su 0)` (M-7 fixed) |
| swipe | **pass** (659 s with swipe-check) | | `swipeFromRecents: task 65 removed by id (attempt 1)` |
| swipe-check | **pass** | | `export ex_3590…: done … detached=true`, `completed while detached`; finished card (`screens/202709-android_swipe_finished_card.png`) |
| death + death-check | **pass** + **pass** (394 s) | | exactly one interrupted record |

**fgs-check timeout: the same host hibernation.** The fgs phase's `destroyActivity` acked at
19:02:40 (`host.log`), and fgs-check then started its build. The host slept from 19:08:29 to
20:10:21. The next host line is 20:11:04, when the timed-out batch collected its files. The phase
limit counts wall-clock time, so it ran out while the laptop was asleep. The run's earlier note,
which blamed a silent Gradle build, is superseded by this timeline. The pair rerun alone passed:
its build took 87 s.

### API 29 and API 29 2 GB (`emulator-5556`, from `dv2`, `-feature GLESDynamicVersion`)

| Scenario | API 29 (20:47–21:12) | API 29 2 GB (21:44–22:08) |
|---|---|---|
| s01 | **pass** (453 s, includes the first build) | **pass** (186 s) |
| s02 | **pass** (220 s) (M-9 fixed) | **pass** (201 s) |
| s03 | **pass** (222 s) | **pass** (204 s) |
| s04 | **pass** (217 s) | **pass** (237 s) |
| s18 | **pass** (225 s) | **fail** (269 s): `s18_close_reopen_test.dart:55`, barcode `Expected: <77> Actual: <0>` after the reopen. Alone, rerun 1 (22:18–22:20): **fail**, same. Alone, rerun 2 (unchanged test, 22:28–22:30): **pass** (137 s) |

The tier is LOW on API 29 and MINIMAL on the 2 GB AVD; both have GLES 3 (see "GLES 3 and tier").

**s18 on the 2 GB AVD is a race in the open sequence (FIX M-22), not an Android-lane defect.**

- On the failed runs, the timeline JSON, the playhead and the zoom all matched after the reopen,
  and the close trace was clean. Only the captured frame was frame 0.
- A diagnostic run used a test temporarily instrumented in `dv2` only. It got barcode 77 at once.
  It is not counted as a result, and the file was restored and checked identical with `cmp`.
- The order of events:
  1. `EditorController.open` moves the preview to `ready` on `PreviewFirstFrame`, which is frame 0
     of the first applied plan.
  2. That can happen before `open` has sent its opening `preview.seek(t)`
     (`editor_controller.dart` around lines 372 and 660).
  3. `E2eEditor.waitReady` returns on that phase, so `barcode()` can run before the opening seek
     exists.
  4. The native `debugCaptureFrame` waits only for a seek that is already in flight (the capture
     fix ae6cda2), so it reads frame 0.
- On the slower MINIMAL-tier device the window is wide enough to hit 2 of 3 times.

### API 28 (Pixel_API_28, `emulator-5556`, from `dv2`)

| Check | Result |
|---|---|
| `x_android_api28` automated | **pass** (129 s, 22:31–22:33). It now really runs (M-10 fixed): "x_android_api28: SDK 28, device verdict EditorUnsupported(android_too_old)", "+1: All tests passed!", no skip. Engine: `capabilities: supported=false reason=android_too_old … api=28`. |
| Home edit button, Projects copy, player Edit (manual) | not rerun on E. They passed on code A, and the automated test now covers the device verdict. |

### Tablet (Pixel_Tablet_API_35, `emulator-5556`, from `dv2`, `-gpu host`, `hw.keyboard=yes`)

| Item | Result |
|---|---|
| s12 automated | **pass**, first attempt (158 s, 22:37–22:40). The wheel zoom and marquee reports were logged, so M-3 and M-4 are fixed on the tablet. |
| Editor screenshot at tablet size | `emulator-5556_Pixel_Tablet_API_35/clean_88469c0/tablet_editor_2560x1600.png`. It is the two-pane editor with the tool rail scrolled to Format, the preview, the timeline and the clip context menu with Ctrl shortcuts. |
| Manual M1–M4 | **not run** (owner; see the checklist) |

### History (codes A–D, 2026-10-16/17; superseded by the clean pass above)

- **A to C+ (2026-10-16):** the API 35 batch pass rate went from 6 scenarios on A, through 11 on C,
  to 17 on D. The failures led to FIX M-1..M-15 and to the Android-lane capture fix for s18. Gate
  devices on A/B:
  - API 29 and API 29 2 GB passed s01/s03/s04; s02 failed (M-9).
  - The API 28 automated test skipped itself (M-10).
  - The tablet's s12 failed (M-3, M-4).
  - The API 34 fgs-check, cancel and swipe-check failed on the harness (M-6, M-7).
- **D (3d38ef2, 2026-10-17, API 35 only):** 17 of 18 scenarios and 6 of 7 extra phases passed in
  the batch.
  - s13 failed only on host-mic silence (-114.6 dBFS) and passed alone (-53.1 dBFS).
  - swipe-check failed because the swipe removed another app's task (M-21).
  - The s09 close trace already showed "exit callback".
- **Evidence** for these runs is under `_before_88469c0/`, `_before_3d38ef2/`, `_before_c93ad22/`
  and `_prev/` (see "Evidence"). The full per-run tables are in this file's git history before
  2026-10-21.

## Measured values

All values come from emulators with software codecs and SwiftShader GL, except the tablet, which
was booted with `-gpu host`. They are **not** performance numbers; QA-04 measures on devices. All
values are from code E (88469c0). The paths are under `build/e2e/android/emulator-5554/` unless
another device is named.

| What | Value | Where |
|---|---|---|
| Encoders | every export: video `c2.android.avc.encoder` (`hardware=false`), audio `c2.android.aac.encoder` | `DanaviewEngine: export … done, encoder …` in `full/logs/batch-*.logcat.txt` |
| s07 exports | batch: the first export was 4,305,971 B and the second stalled at 93 % (host hibernated). Alone: 4,305,971 B and 4,259,887 B, 8.0 s each. HEVC/MOV are not offered (`hevcEncode false`) | `full/s07_batch_note.txt`, `solo/s07/logs/s07_export_verified_test.log` |
| s07 burned captions | t1a 313 and t1b 293 changed samples (the bar is now > 180 at 720 px, M-2) | same |
| s08 captions | 3 cues from whisper-tiny ("Welcome to the video editor test, \| the quick brown fox jumps over the …"); batch 449 s | `full/logs/s08_auto_captions_test.log` |
| s12 wheel and marquee (phone) | Ctrl+wheel zoom 45.45 → 75.76 px/s; scroll −1.33 → 1.30 s; the marquee drag hits `HitEmpty` on the lane | `full/logs/s12_keyboard_pointer_test.log` |
| s12 wheel and marquee (tablet) | zoom 119.25 → 198.77 px/s; scroll −1.80 → −0.80 s; marquee `HitEmpty` | `emulator-5556_Pixel_Tablet_API_35/clean_88469c0/logs/s12_keyboard_pointer_test.log` |
| s13 timing and level | batch: start latency 0.57 s (device budget 0.1 s, reported); clip 9.33 s inside a Record→Stop window of 7.23 s inner / 11.27 s outer (0 µs outside); level −66.3 dBFS. Alone: −76.2 and −69.4 dBFS. Export "E2E voiceover", 4,479,939 B, 11.57 s | `full/logs/s13_voiceover_test.log`, `solo/s13_diag/`, `solo/s13_tone/` |
| s13 microphone | AVD booted with audio, `adb emu avd hostmicon` on; host input: the laptop's Built-in Microphone Array (Intel Smart Sound Technology) | `full/runner.log` ("host microphone: on") |
| s14 export | "E2E pip", 4,771,418 B, 8.0 s | `full/logs/s14_pip_overlay_test.log` |
| s15 export and levels | "E2E audio", 4,511,851 B, 10.0 s; head −15.1 dBFS, body −9.0 dBFS | `full/logs/s15_extract_audio_music_test.log` |
| Extra exports (API 35) | 7,789,785 B, `detached=true` (fgs and swipe) | `full/logs/batch-x_android_export_background-{fgs,swipe}.logcat.txt` |
| Extra exports (API 34) | 7,785,197 B, `detached=true`, `completed while detached; savedToGallery=true notified=true` (swipe in the batch, fgs alone) | `emulator-5556_Pixel_API_34/logs/` |
| FGS on API 35 | `isForeground=true types=0x00002000` (mediaProcessing) | `DV_E2E_FGS` lines, `full/logs/batch-x_android_export_background-*.log` |
| FGS on API 34 | `isForeground=true types=00000001` (dataSync), channel `danaview_editor_export`, category progress, 1 action | `emulator-5556_Pixel_API_34/runner_full_88469c0.log` |
| Batch times | API 35 in the "Results matrix"; emulator restarts 0 on every device | each `summary.txt` |

`DV_E2E_*` values of this pass:

- **Build defines:** `DANAVIEW_EDITOR=true`, `DANAVIEW_AUTO_CAPTIONS=true`, `DV_E2E_HOST=true`, and
  `DV_E2E_PHASE=<phase>` (for the extra and s09).
- **Runner:** `DV_E2E_PHASE_TIMEOUT=1200`.

### GLES 3 and tier

The engine logs one capabilities line per process (`core/Capabilities.kt`). All lines are from
code E.

| Device | Line (abridged) | Tier | Verdict |
|---|---|---|---|
| API 35 phone | `supported=true tier=LOW api=35 ram=4110278656 lowRam=false gles3=true gl=OpenGL ES 3.0 SwiftShader 4.0.0.1 maxTexture=8192` | LOW | ok |
| API 35 tablet (`-gpu host`) | `supported=true tier=LOW api=35 ram=4110266368 lowRam=false gles3=true gl=OpenGL ES 3.0 (4.5.0 - Build 32.0.101.8508) maxTexture=16384` | LOW | ok (host Intel Arc GL) |
| API 34 | `supported=true tier=LOW api=34 ram=3123421184 lowRam=false gles3=true … maxTexture=8192` | LOW | ok |
| API 29 | `supported=true tier=LOW api=29 ram=3143041024 lowRam=false gles3=true gl=OpenGL ES 3.0 SwiftShader 4.0.0.1 maxTexture=8192` | LOW | ok; GLES 3 confirmed |
| API 29 2 GB | `supported=true tier=MINIMAL api=29 ram=2089222144 lowRam=false gles3=true …` | MINIMAL | ok, as D-40 expects |
| API 28 | `supported=false reason=android_too_old … api=28` | — | ok |

- API 29 offers GLES 3 only with `-feature GLESDynamicVersion`. `e2e_android.sh` adds that flag
  for the API 29 AVDs it boots. The gate runs booted the AVDs by hand with the flag.
- `lowRam=false` on the 2 GB AVD: the emulator does not set the low-RAM flag. The tier comes from
  the RAM size alone, which is what D-40 needs here.

## Emulator realities (reported, not failed)

- **The host laptop hibernated on critical battery (code E, 2026-10-21).** The Windows System
  log shows Kernel-Power 524 "Critical Battery Trigger Met" at 19:08:25, then sleep (Kernel-Power
  42, "Sleep Reason: Battery") at 19:08:29, and resume from hibernate at 20:10:21. Both emulators
  froze. No logcat line from any process falls in that gap. Two batches were running then:
  - API 35 s07 (second export at 93 %);
  - the API 34 fgs pair (fgs-check's build). Its 1200 s phase limit runs on wall-clock time, so it
    expired during the sleep.

  Both passed alone on the same code. Run certifying passes on mains power.
- **The host microphone feeds the emulator (near) silence (s13).** On code E the export level was
  -66.3 dBFS in the batch, and -76.2 and -69.4 dBFS in two solo runs, against a bar of -60 dBFS.
  The last run had a tone playing on the laptop speakers. On code D the batch had pure silence
  (-114.6 dBFS: 437 × "inserting 16000 us of silence" from the ranchu audio HAL over the 7 s
  clip). The solo run passed at -53.1 dBFS on a freshly booted emulator. The level depends on the
  host input and the room, not on the app. The recording, the clip length and the voice lane pass
  every time. Evidence: `emulator-5554/full/logs/batch-s13.logcat.txt`, `s13_voiceover_test.log`,
  `emulator-5554/solo/s13*/`, and `_before_88469c0/emulator-5554/`.
- **Emulator process deaths during s07 (cause unproven).** The API 35 emulator died during s07
  three times:
  - 10:35–10:38, an early-morning full run on code older than A (`_rerun4_cert/summary.txt`:
    `s07 FAIL*`, "emulator restarts: 1"). No evidence shows a second emulator running then; the
    earliest `emulator-5556` evidence is from 14:18.
  - 19:36, batched rerun 1 on B (from the run-1 runner log, which is not kept under `build/`).
    The API 34 runs on `emulator-5556` were going at the time (19:33–20:21).
  - 20:53, batched rerun 2 on B (`emulator-5554/summary_run2.txt`: `s07 FAIL*`). At 20:53:07 the
    tablet emulator on `emulator-5556` died at the same moment (`gpu_host/run2`).

  The qemu log ends at a crash report that was not kept (no consent), and there is no logcat. s07
  ran to the end without an emulator death three times: pass 1 at 13:29–13:37 (A, export timed
  out), pass 2 at 14:52–14:59 (A, export failed) and alone at 21:41–21:44 (B, the only solo s07 run
  on B, `solo/s07/runner.log`). The cause of the deaths is not proven; parallel load may play a
  part but does not explain the 10:35 death. The deaths do not explain s07's real failure on B
  (FIX M-2).
  On code C, with only `emulator-5554` running, s07 ran twice (batch 22:21–22:24, alone 23:22–23:26)
  and the whole pass had 0 emulator restarts. No emulator died on any device on codes D or E.
- **Imports refused right after an emulator reboot.** In both batched runs s08 ran directly after
  the runner rebooted the emulator. Both fixtures were refused at import as "This file is empty.",
  although the files on the device had their full sizes (from the run-1 and run-2 test logs, since
  overwritten; the runner logs show s08 starting 19:40 and 20:57, right after the s07 restarts).
  Alone, on a fresh install, s08 passed (`solo/s08/`). This was seen only right after a reboot; the
  cause is not proven.
- **s08 depends on the app state left by earlier phases.** Run alone at 21:30–21:32 without a fresh
  install or a reset (`solo/s08_nofresh/`, no `reset.log`), right after the death and death-check
  phases (21:22–21:26), s08 made its 3 captions and then failed at `ed.close()`
  (`s08_auto_captions_test.dart:118`, `e2e_editor.dart:165`): "Timed out after 30 s waiting for
  the editor to close", with "The export was interrupted / Start it again. Your project is
  unchanged." on screen. The likely source is the interrupted-export record the death phase leaves
  on purpose. The certifying command clears app data before every batch, and the extra runs after
  s08, so this does not hit that run. `E2eEditor.close` now dismisses the sheet (M-14, fixed on
  the Mac).
- **`always_finish_activities` has no effect** on the API 34 and API 35 images. After
  `settings put global always_finish_activities 1` and HOME, `dumpsys activity` still shows
  MainActivity STOPPED and in history, even with the setting held for 8–10 s. The harness now
  destroys the activity another way (M-6, fixed), and fgs-check sees the detached export.
- **`uiautomator dump` fails while a progress notification updates** ("could not get idle
  state"). The harness now sends the Cancel intent directly (M-7, fixed).
- **API 34 shared-storage crash after uninstall.** Right after the app was uninstalled, the system
  shared-storage service crashed (SIGABRT `Check failed: active_nodes_.find(node)`). Then
  `/sdcard/Android` gave "Permission denied" or "Transport endpoint is not connected" and staging
  failed. Fix: reboot that emulator and stage again without uninstalling.
- **Software codecs.** Exports use `c2.android.avc.encoder` and `c2.android.aac.encoder`. There is
  no hardware HEVC encoder. Export speed means nothing here.
- **Software decoder stale frames (3ef16a0, AND-18).** The emulator's software H.264 decoder,
  writing into a GL-sampled Surface, has no acquire fence. Near the end of a decoder stream, GL can
  sample a frame that is 1–5 frames old. It reproduces with bare MediaCodec + SurfaceTexture + GL
  (3/160 and 4/160 decodes). It never reproduces with the goldfish hardware decoder (0/12) or a
  CPU consumer (0/160). Production uses hardware decoders first. A barcode a few frames off near a
  clip end, with this signature, is this reality. None of this round's failures has that signature.
- **Slow software rendering.** Davey frames of 726–818 ms appear during structural edits on
  API 35. This widens timing windows: the 3 s save-before-close in s06/s16/s18 and the host
  handshake round trip of 4–8 s in s13.
- **AutoCaptions poll timeouts.** `[AutoCaptions] Export state unavailable: TimeoutException`
  lines appear while the emulator is loaded. They are harmless (INT-04's 3 s poll with a 2 s
  timeout).
- **Host keyboard and mouse.** Emulator 36.6.11 has `VirtioMouse` on by default. Ctrl shortcuts
  reach the tablet only with Extended controls > Settings > General > "Send keyboard shortcuts to:
  Virtual device".
- **GPU modes (tablet).** `-gpu angle_indirect` is not a valid mode in emulator 36.6.11 (it falls
  back to SwiftShader). `-gpu host` (Intel Arc) and `-gpu swiftshader_indirect` gave the same s12
  result as the default. `-gpu swiftshader_indirect` survived 1 of 2 runs. `-gpu host` survived 3
  of 4 (`gpu_host/run1`, `gpu_host_patched` run1 and run2; it died in `gpu_host/run2`, together
  with `emulator-5554`). **Recommended tablet boot flag: `-gpu host`.** Evidence:
  `_before_3d38ef2/emulator-5556_Pixel_Tablet_API_35/gpu_*` and `gpu_trials_README.txt`. The code E
  tablet run used `-gpu host` and passed s12 on the first attempt.

## Android-lane fixes this round

Android-lane commits of the 2026-10-16/17 rounds, all on `editor-android` and all contained in code
E. No Android-lane code changed during the code E pass.

| Commit | What |
|---|---|
| 0f15c97 | AND-14: the notification-permission request always returns (landing record) |
| 9ef20b8 | AND-16: no crash when a recording mutes a preview that is still opening |
| 696fe0b | AND-15: copied file names capped in UTF-8 bytes, not only characters |
| 0cfc691 | AND-18: `RangeTouchVectorTest` replays the shared range-touch vectors (FIX-AND-18-1) |
| 550b8ac (WIP), ae6cda2 | `PreviewSession.debugCaptureFrame` waits for a seek in flight (s18) |

### `debugCaptureFrame` waits for a seek in flight (s18, code C+)

**Defect.** s18 reopens a project and reads the frame barcode at once. On C it failed 2 of 2
(batch 22:50, alone 23:12) with `EngineFailure(internal: nothing composed)` from
`PreviewHostApi.debugCaptureFrame`, thrown by `FallbackGl.capture` (`preview/fallback`). The
editor's opening exact seek hands the Surface from the paused renderer to the contingency backend
(`ensureOwner(BACKEND)`), and the backend composes only when the seek's frame arrives. A capture
queued in that window read the backend's canvas, which did not exist yet, although the Surface
still showed the renderer's frame. iOS reads the frame on screen (`TextureBridge.captureRGBA`), so
this was an Android-only gap (AND-16/ENG-08 area, the preview session).

**Fix.** `preview/PreviewSession.kt` `debugCaptureFrame`: while a seek is in flight
(`SeekController.isBusy`), the capture waits, polling every 20 ms, up to the seek's own exact
timeout plus 500 ms, then reads the Surface's owner as before. Only this debug/QA call changes; no
assertion or test changed. Landed in WIP backup 550b8ac.

**Proof.**

- s18 alone on C+: **pass** (23:46, `solo/s18_capturefix/`), including the barcode of frame 77
  after the reopen.
- `PreviewSessionTest` (instrumented, 11 tests incl. the capture-equals-producer check) on
  `emulator-5554`, API 35: 11 of 11 pass (`solo/s18_capturefix/PreviewSessionTest_connected.log`).
- JVM `preview.*` unit tests (`RecordingMuteRaceTest`, 3): pass
  (`solo/s18_capturefix/preview_unit.log`).
- Since then: the fix landed as ae6cda2. On code E, s18 passes inside the full batch on API 35 and
  on API 29. The 2 GB failure is a different, Dart-side race (FIX M-22): the capture correctly
  returns frame 0, because the opening seek has not been sent yet.

### AND-14: the notification-permission request always returns

**What.** The owner's rule of 2026-10-16: the request must never hang an export. The Dart side's
10 s timeout (e0fa7e8) is only a safety net. `platform/Permissions.kt` now answers on every path,
exactly once:

- **true at once:**
  - below API 33;
  - when the permission is already granted, even with no activity.
- **false at once:**
  - no activity, or the activity is finishing or destroyed;
  - the activity is paused or stopped (a LifecycleOwner activity reports its own state; any other
    activity is tracked by a process-wide `ActivityLifecycleCallbacks`);
  - one of our requests is already pending;
  - the permission is permanently denied. A flag in AND-14's own prefs (`danaview_editor_permissions`)
    is set when a denial turns `shouldShowRequestPermissionRationale` from true to false, and is
    cleared when the permission is granted or the rationale returns. A first dialog dismissed
    without an answer does not set it.
- **The system dialog** is shown otherwise, and its answer is returned. If the activity is
  destroyed or recreated while the dialog is up, the request returns false at that moment, and the
  late platform callback is ignored. An empty (cancelled) result, a request that cannot start, or
  a request that throws all return false.
- **Exactly once:** a guard flag makes each path call the completion exactly once. The destroy
  watch is removed when the request finishes.

The recorder's RECORD_AUDIO flow (`recording/VoiceRecorder`) is separate and unchanged.

**Tests.**

- JVM: `test/.../platform/NotificationPermissionFlowTest.kt`, 15 cases, all pass. They cover:
  below API 33, already granted, no usable activity, pending, permanently denied and how the flag
  follows the rationale, answering once, destroy while asking, the late callback ignored, the
  destroy watch unregistered, cancelled/not-started/throwing requests, and Settings changes.
- Instrumented: `androidTest/.../platform/PermissionsTest.kt` on emulator-5554, API 35. The
  platform package: 24 tests, 0 failures, 3 skipped by design. Of the 10 PermissionsTest cases, 8
  pass:
  - already granted;
  - no activity;
  - backgrounded activity;
  - pending request;
  - destroyed while asking;
  - recreated while asking;
  - cannot start;
  - permanently denied.

  Two are skipped. `belowApi33AnswersTrueWithoutPrompt` needs API < 33; the JVM tests cover that
  rule. `realDialogDestroyedThenDenyThenAllow` runs only when a flag is set.
- The real system dialog: `realDialogDestroyedThenDenyThenAllow` was run alone with
  `am instrument`, after `pm revoke` and `clear-permission-flags` of POST_NOTIFICATIONS. The result
  was OK (1 test), with the logcat line "AND-14 real notification dialog on API 35: destroyed ->
  false, deny -> false, allow -> true". The test's step 2 had hung before, because UiAutomator
  clicked the closing dialog of step 1. Two helpers fix that: `dismissDialogs` and
  `clickUntilDone` (20 s). No assertion was loosened.
- Lint: `lintDebug` passes.
- `testDebugUnitTest` overall: 384 tests, 1 failure, in the frozen INT-07 glue test (Windows path
  separators; FIX M-11). It is unrelated to AND-14.

**Proof in the E2E suite.** In every export of the API 35 and API 34 reruns, the app asked the
host for `grantNotifications` and the export started. None waited at "Preparing…".

**Landed.** The code and tests landed in the WIP backups e6a9340 (`Permissions.kt`), 938a42f and
1ff018c (tests). The landing record is 0f15c97.

### `scripts/ci/editor/e2e_android.sh` (QA-02)

- **`kill_stray_serve`** (3e4caaf): on Windows it stops leftover `e2e_host.sh serve` loops of its
  own serial, before and after each extra phase. Proof: in the API 35 reruns it killed 4 strays,
  and every host request was then handled once (`host.log`: one `request #1`, at most one
  `request #2` per phase). The same commit replaced a stray non-UTF-8 byte in the header; the file
  is valid UTF-8 and passes `bash -n`.
- **Death-phase race** (0ad2477): after the host's `am kill`, `flutter test` can exit on the lost
  connection before `serve` (which reports a minute after the action) has said that the app was
  ended. The runner used to stop `serve` and report a FAIL. For a "dies" phase it now waits up to
  90 s for `serve`'s own status. Proof: "phase death: the host ended the app (flutter test had
  already exited)", then PASS death and PASS death-check, on both API 34 and API 35.
- **Emulator restart without `adb kill-server`** while another device is attached (f298ee7). This
  stops a restart from cutting off the other emulator. `bash -n` and a dry run pass. The restart
  path ran twice on API 35 this round (after the two s07 crashes); both restarts booted the
  emulator again and the run went on.
- Note: the first API 35 rerun ended early with `e2e_android.sh: line 577: syntax error`, after its
  death phase and before the summary, so it wrote no `summary.txt`. That happened because the death
  fix was saved into the script while bash was still reading it. Run 2 covers the death phases. The
  current file passes `bash -n`.
- 2026-10-21 (before the code E pass): an emulator restart no longer runs `adb kill-server`, even
  when no other device is listed. A second emulator that is still booting is not yet a listed
  device, and a server restart would cut it off. Saved before the run started; `bash -n` passes.

### Other Android-lane changes in this window (for completeness)

- `core/Capabilities.kt`: the one-line capabilities log (1dede14). It is proven by the on-device
  output on API 28, 29, 29 2 GB, 34 and 35 shown above.
- AND-15 (696fe0b): copied file names are capped at 200 UTF-8 bytes (`DropTarget.MAX_NAME_BYTES`),
  not only in characters. AND-16 (9ef20b8): no crash when a recording mutes a preview that is still
  opening (`setMuted` before `open` only stores the mute), and the mute fan-out in
  `PreviewSessionManager` is guarded, so one failing session cannot stop the others. They have
  their own landing records. In this suite, s13 (recording with the preview open) did not crash on
  code B.

## FIX requests for the Mac (still open)

**Closed by the clean pass on code E (88469c0):**

| Request | Proof |
|---|---|
| M-1, s06 close | s06 passes in the API 35 batch |
| M-2, s07 threshold | s07 passes, both exports alone |
| M-3, s12 marquee | the phone and the tablet both pass |
| M-4, tablet rail | the tablet's s12 reaches Format |
| M-5, s13 recording length | the length passes inside the window |
| M-6, destroyActivity | fgs-check returns `finished` with `detached=true` on API 35 and API 34 |
| M-7, notification Cancel | API 34 and API 35 |
| M-8, s10 relink | s10 passes |
| M-9, s02 on API 29 | API 29 and the 2 GB AVD |
| M-10, API 28 test runs | no longer skips |
| M-15, s09 recover close | s09 passes |
| M-21, swipe by task id | swipe-check passes on API 34 and API 35 |
| M-11, M-12 (Android lane) and M-13 (README) | done before this pass |

**M-14 (s08 close past "export interrupted")** is fixed in `E2eEditor.close` (FIX-QA00-R7). The
clean pass did not exercise it, because every batch starts from cleared data.

**M-22. s18 on the 2 GB AVD reads frame 0 after the reopen** (new; QA-00 harness with the UX-08
open sequence).

- **Where:** `s18_close_reopen_test.dart:55`, `expect((await ed.barcode()).index, 77)`, right after
  `E2eEditor.openFromProjects`.
- **Seen on:** Pixel_API_29_2GB (tier MINIMAL), code 88469c0.
  - The batch failed with "Expected: <77> Actual: <0>".
  - Alone, the first rerun failed the same way and the second passed.
  - It passes on API 29 (3 GB) and on API 35.
  - Timeline JSON, playhead and zoom are equal after the reopen. Only the captured frame is wrong.
- **Cause:**
  1. `EditorController.open` sets `PreviewPhase.ready` when `PreviewFirstFrame` arrives
     (`editor_controller.dart`, `_onPreviewEvent`, around line 660). That first frame is frame 0
     of the first applied plan.
  2. It can arrive before `open` has called `preview.seek(t)` (around line 372, followed by
     `markOpenedAt` at line 380).
  3. `E2eEditor.waitReady` (`integration_test/editor/support/e2e_editor.dart`, lines 156–165)
     returns on that phase, so the capture can run before the opening seek exists.
  4. The native `debugCaptureFrame` waits only for a seek already in flight (ae6cda2), so it
     correctly returns the frame on screen, frame 0.
- **Fix:** choose one.
  - (a) The test side: `waitReady` (with `waitPreview`) also waits until the open's exact seek has
    finished. For example, `EditorSession` exposes a flag or future that `markOpenedAt`
    completes; the initial seek can legitimately be null. Then `pumpUntil` that and
    `!playhead.isSeeking`.
  - (b) The product side: do not move the preview to `ready` until the opening seek's frame is up.
    This applies if UX-08 wants the first visible frame to be the restored playhead; today slow
    devices flash frame 0.
- Do not loosen s18.
- **Evidence:**
  - `build/e2e/android/emulator-5556_Pixel_API_29_2GB/` (`batch_s01-s04_s18/`,
    `s18_alone_rerun1_FAIL/`, `s18_alone_rerun2_PASS/`, and the diagnostic
    `s18_diag_instrumented_NOT_A_RESULT/`).
  - `CODE_VERSION.txt`.

**Observation, no request yet (s13 stop, API 35):** one solo s13 run (`emulator-5554/solo/s13/`)
showed Stop not taking effect within 30 s, with two `activeJobs` Pigeon timeouts. There was no ANR
and no error line. It did not repeat in two later runs that took thread dumps. If it shows up again,
the Android lane will take a thread dump at that moment and decide whether it is
`VoiceRecorder.finish` or the Dart side.

The code-review findings on the native glue (D2–D6 in the Android lane's Mac list) are review
items, not QA-02 reproductions. They are tracked there.

## Manual checklist (owner, Pixel_Tablet_API_35)

This covers the four manual items in `docs/v1.1/editor/qa/README.md` ("Manual checklist"):
hardware keyboard (s12 by hand), real mouse, drag from Files, and drag from Photos (ARCH D-18,
AND-15). Do it when no automated run is going, so the emulators do not fight over the CPU.

Use **Git Bash**. Start each new window with:

```bash
source ~/danaview_env.sh
cd <repo root>
mkdir -p build/e2e/android/manual
```

Screenshots go to `build/e2e/android/manual/` (`build/` is not committed). Name them as given below.

### 0. Setup

1. **Keyboard.** Done 2026-10-16: the tablet's `config.ini` has `hw.keyboard=yes`, so the laptop
   keyboard reaches the tablet as a hardware keyboard. If it ever reverts, fix it while the tablet
   emulator is **off**: Android Studio > Device Manager > Pixel_Tablet_API_35 > Edit (pencil) >
   Additional settings > tick **Enable keyboard input** > Finish. Or edit
   `%USERPROFILE%\.android\avd\Pixel_Tablet_API_35.avd\config.ini` in Notepad: `hw.keyboard=yes`.
2. **Start the tablet** with a window and with audio (no `-no-window`, no `-no-audio`):

   ```bash
   "$ANDROID_HOME/emulator/emulator.exe" -avd Pixel_Tablet_API_35 -gpu host -no-snapshot-save
   ```

   `-gpu host` is the recommended tablet GPU mode (see "GPU modes (tablet)" under Emulator
   realities); without it the tablet dies more often when the preview starts.

   Leave that window open and wait for the home screen. In a second Git Bash window, run
   `adb devices -l`. The tablet is `emulator-5554` when it is the only emulator, and usually
   `emulator-5556` otherwise. That serial is written `SERIAL` below. Rotate to landscape if
   needed (side toolbar, rotate button).
3. **Shortcuts to the tablet, not to the emulator.** Click **⋯** (Extended controls) > **Settings**
   > **General** > **Send keyboard shortcuts to** > **Virtual device**. Close Extended controls.
   Otherwise, for example, Ctrl+S takes an emulator screenshot.
4. **Mouse.** Move the mouse over the tablet. A pointer arrow should show inside it (VirtioMouse).
   If you only get touches (no arrow, right-click does nothing), note it and carry on.
5. **Test media:**

   ```bash
   adb -s SERIAL push packages/danaview_editor_engine/test_fixtures/media/frame_counter_1080p30.mp4 /sdcard/Download/
   adb -s SERIAL push packages/danaview_editor_engine/test_fixtures/media/tone_440hz.wav /sdcard/Download/
   adb -s SERIAL push packages/danaview_editor_engine/test_fixtures/media/clap_flash_av.mp4 /sdcard/Movies/
   adb -s SERIAL push packages/danaview_editor_engine/test_fixtures/media/still_4k.jpg /sdcard/Pictures/
   adb -s SERIAL shell content call --method scan_volume --uri content://media --arg external_primary
   ```

   The last line asks Android to index the new files. **Files** shows the first two in Downloads.
   **Photos** shows the last two. If Photos asks you to sign in, use it without an account. If
   Photos does not show them, restart the tablet once.
6. **Install and start the app with the editor on:**

   ```bash
   flutter run -d SERIAL --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true
   ```

   These are the editor defines the E2E host uses. The first build takes several minutes (one
   Gradle worker). If it stops with "Connection timed out" while downloading the media_kit jars,
   ask Claude for the curl workaround. Keep this window open; `q` stops the app.
7. **Open the editor with a clip.** Home > **Open video editor** (the edit button left of the
   Settings gear) > **New project** > **Files** > `frame_counter_1080p30.mp4` in Downloads >
   name it `Manual QA-02` > **Create**. Wait until the preview shows the frame counter.

**Screenshots.** Use either the emulator's **camera** button (set Extended controls > Settings >
General > Screenshot save location to the repo's `build\e2e\android\manual` folder once, then rename
each file), or:

```bash
adb -s SERIAL exec-out screencap -p > build/e2e/android/manual/m1_keyboard_space.png
```

Take sheets and menus while they are open.

### M1. Physical keyboard (scenario 12 by hand)

Click the timeline once first (not a text field). A row passes when the "Expected" happens.

| # | Do | Expected | Screenshot | Result |
|---|---|---|---|---|
| 1 | Space, then K | Space starts playback (counter runs); K pauses | `m1_keyboard_space.png` (playing) | not run |
| 2 | Paused: → once, then ← once | counter +1 frame, then back | `m1_keyboard_frame_step.png` (after →) | not run |
| 3 | Shift+→, then Shift+← | playhead jumps 1 s (30 frames) forward, then back | `m1_keyboard_shift_step.png` | not run |
| 4 | Tap the clip to select it, press S | splits in two at the playhead | `m1_keyboard_split.png` | not run |
| 5 | Select the right half, Delete | that part is removed | `m1_keyboard_delete.png` | not run |
| 6 | Ctrl+Z | the deleted part comes back | `m1_keyboard_undo.png` | not run |
| 7 | Ctrl+Shift+Z (then Ctrl+Z again) | deleted again (redo), then back | `m1_keyboard_redo.png` | not run |
| 8 | Right half, Backspace, then Ctrl+Z | Backspace deletes like Delete; Ctrl+Z restores | `m1_keyboard_backspace.png` | not run |
| 9 | Left clip, Ctrl+C, playhead to the end, Ctrl+V | a copy is pasted at the end | `m1_keyboard_paste.png` | not run |
| 10 | Last clip, Ctrl+D | the clip is duplicated | `m1_keyboard_duplicate.png` | not run |
| 11 | Add a text (Text tool), click into its field, note the text, Ctrl+S | the project saves; **no "s" is typed**; Esc twice to leave | `m1_keyboard_ctrl_s.png` | not run |
| 12 | Tap a tool tile (for example Format; scroll the rail if needed), Esc, Space twice | Space starts and stops playback; the tile is not pressed again | `m1_keyboard_space_after_tile.png` (playing) | not run |
| 13 | Ctrl+/ (or ?) | the Keyboard shortcuts sheet opens; every row has its key, with Ctrl glyphs (not ⌘); scroll through it all | `m1_shortcuts_sheet_1.png`, `_2.png`, … | not run |

If a key does nothing, write down which one. If the emulator reacts instead of the app, recheck
setup step 3.

### M2. Real mouse

| # | Do | Expected | Screenshot | Result |
|---|---|---|---|---|
| 1 | Move the mouse over a clip, do not click | a hover pill shows the clip's name and length; it goes away when the mouse leaves | `m2_mouse_hover_pill.png` | not run |
| 2 | Right-click a clip | the clip's context menu opens (Split, Delete, …); Esc closes it | `m2_mouse_context_menu.png` | not run |
| 3 | Press on an **empty** part of a lane (after the last clip) and drag back over two clips | a marquee shows; on release both clips are selected | `m2_mouse_marquee.png` | not run |
| 4 | Wheel over the lanes | the lanes scroll up/down; zoom unchanged | — | not run |
| 5 | Shift+wheel over the lanes | the timeline scrolls in time (left/right) | `m2_mouse_shift_wheel.png` | not run |
| 6 | Ctrl+wheel over a clip | the timeline zooms, anchored at the mouse | `m2_mouse_ctrl_wheel_before.png`, `_after.png` | not run |

Row 3 checks by hand what s12's automated marquee step checks (it passes on code E on the phone
and the tablet). If the emulator window zooms on Ctrl+wheel, or right-click never
reaches the app, record it as an emulator reality.

### M3. Drag from Files

**Side by side (Android 15 tablet split screen):** open **Files** > Downloads. Open **Overview**
(the square button on the emulator's side toolbar, or swipe up from the bottom edge and hold). Click
the **Files icon** at the top of its card > **Split screen**. Click the **Danaview** card on the
other side (the editor with the project open; if not, open it as in setup step 7). Drag the
middle divider if the timeline is too narrow.

**The drag:** press and **hold** `frame_counter_1080p30.mp4` until it lifts, drag it without
letting go onto an empty spot of a lane a few seconds in, and let go. Repeat with `tone_440hz.wav`
on an audio lane.

**Pass when** the clip lands on the lane under the pointer, starting where you let go (a
"Starts …" label may show while hovering), and the import progress shows before the clip appears.

| Screenshots | Result |
|---|---|
| `m3_files_split_screen.png`, `m3_files_dragging.png` (if you can), `m3_files_dropped.png`, `m3_files_audio_dropped.png` | not run |

### M4. Drag from Photos

Same split screen with **Photos** (Overview > Photos icon > Split screen > Danaview). Long-press
`clap_flash_av.mp4` (or `still_4k.jpg`) and drag it onto a lane.

**Pass when** the same as M3, **and** the dropped copy exists under `work/drops/`. Check right after
the drop; the app clears `work/` at its next launch:

```bash
adb -s SERIAL shell run-as com.vecvel.danaview ls -R cache/danaview/editor/work/drops > build/e2e/android/manual/m4_drops_listing.txt
```

You should see a folder with a random id and the file inside it. (`run-as` works because
`flutter run` installs a debug build.)

| Screenshots / file | Result |
|---|---|
| `m4_photos_split_screen.png`, `m4_photos_dropped.png`, `m4_drops_listing.txt` (paste the listing here) | not run |

**When done:** press `q` in the `flutter run` window, close the emulator, and tell Claude which
rows passed or failed (one line each is enough). This report then links the screenshots.

## Evidence

Paths are relative to `build/e2e/android/`. They are local to the Windows laptop and not
committed.

**Before the code E pass,** the code D evidence that was in `emulator-5554/` was moved to
`_before_88469c0/emulator-5554/`. No older `emulator-5556` evidence was in the main checkout, so
nothing was moved for that serial. The `dv2` copies of the gate runs remain in
`C:/dev/dv2/build/e2e/android/` (`*_88469c0_*`).

**Code E (88469c0), 2026-10-21: the certifying evidence**

| Folder | Device | Content |
|---|---|---|
| `emulator-5554/full/` (`logs/`, `screens/`, `files/`, `summary.txt`, `runner.log`, `s09_close_trace.txt`, `s07_batch_note.txt`) | API 35 | The full pass, 18:31–21:37. `logs/` lacks the batch's own s07 logs; see the note. |
| `emulator-5554/solo/s07/` | API 35 | s07 alone (pass) |
| `emulator-5554/solo/{s13,s13_diag,s13_tone}/` | API 35 | s13 alone three times (fail). `s13_threads/` holds the app thread dumps of the last two runs. |
| `emulator-5556_Pixel_API_34/` (`runner_full_88469c0.log`, `runner_fgs_rerun_88469c0.log`, `logs/`, `screens/`, `CODE_VERSION.txt`) | API 34 | The extra batch and the fgs pair alone. In `logs/`, the fgs files are from the solo rerun and the rest are from the batch. |
| `emulator-5556_Pixel_API_29/` | API 29 | s01–s04, s18 |
| `emulator-5556_Pixel_API_29_2GB/` (`batch_s01-s04_s18/`, `s18_alone_rerun1_FAIL/`, `s18_alone_rerun2_PASS/`, `s18_diag_instrumented_NOT_A_RESULT/`) | API 29 2 GB | s01–s04, s18, and the M-22 diagnosis |
| `emulator-5556_Pixel_API_28/` | API 28 | `x_android_api28` |
| `emulator-5556_Pixel_Tablet_API_35/clean_88469c0/` (`tablet_editor_2560x1600.png`) | tablet | s12 and the tablet-size screenshot |

**Before code E: history only**

| Folder | Code |
|---|---|
| `_before_88469c0/emulator-5554/{full,solo/s13,solo/x_swipe}/` | D (API 35, 2026-10-17) |
| `_before_3d38ef2/emulator-5554/` (`full/`, `solo/…`, `solo/s18_capturefix/`) | C, C+ |
| `_before_c93ad22/emulator-5554/` | B |
| `_prev/emulator-5554-20261016-1926/` | A |
| `_before_3d38ef2/emulator-5556/avd-Pixel_API_{28,29,29_2GB}/` | A |
| `_before_3d38ef2/emulator-5556_Pixel_API_34/` | B |
| `_before_3d38ef2/emulator-5556_Pixel_Tablet_API_35/` (`run4_rerun_alone/`, `gpu_*`, `gpu_trials_README.txt`) | B |

Superseded and not used: `_run3_cert/`, `_rerun4_cert/`, `_stale_before_1145/` and
`_api35_slowemu_1252/`.

**Owner's manual evidence** goes to `manual/` (M1–M4, not yet taken).

## What remains for certification

BUILD_PLAN acceptance, and PRODUCTION_READINESS §4.3, require all of the following on one code
version:

- every scenario and every extra phase passes on API 35;
- the detached export (AND-12) on API 34 and API 35;
- API 34 notification Cancel;
- s01–s04 and s18 on API 29 and on API 29 2 GB;
- the API 28 automated check;
- tablet s12, plus the owner's M1–M4.

**Verdict on code E (88469c0): QA-02 is NOT certified.**

**Done on 88469c0:**

- **API 35:** 16 of 18 scenarios and 7 of 7 extra phases pass in the batch.
- **AND-12** is proven on API 35 (fgs and swipe) and on API 34 (swipe in the batch, fgs alone).
- **API 34:** Cancel passes.
- **API 29:** s01–s04 and s18 pass.
- **API 29 2 GB:** s01–s04 pass.
- **API 28:** the automated check passes.
- **Tablet:** s12 passes.
- **s09 close trace:** the trace is clean.
- **Android lane:** no defect found and no fix needed.

**Still open, by owner:**

1. **Mac (Dart / QA-00): FIX M-22.** s18 fails on the 2 GB AVD from the open-sequence race. After
   the fix, rerun s01–s04 and s18 on Pixel_API_29_2GB (fresh install, `-feature
   GLESDynamicVersion`). For the gate, rerun s18 on API 29 and API 35 too.
2. **Owner decision or environment (API 35 s13):** the laptop microphone feeds the emulator
   near-silence, so the export level stays below -60 dBFS. There are two ways to close it:
   - the owner accepts s13's level check as an emulator reality on this laptop (every other s13
     check passes); or
   - s13 is rerun in the batch with a voice or tone the laptop microphone actually picks up (an
     external mic or a headset).
3. **Environment (host power), API 35 s07 and the API 34 fgs pair:** both passed alone on 88469c0,
   but the clean batch was cut by the laptop hibernating on critical battery (19:08–20:10).
   - Either the owner accepts the solo passes,
   - or the API 35 command and the API 34 extra are rerun **on mains power**, together with item 1's
     reruns on the code that carries M-22.
4. **Owner (manual): M1–M4 on the tablet** (keyboard, mouse, drag from Files, drag from Photos),
   using the checklist below. This report then records each row with its screenshot.

If M-22 changes Dart code, the final certifying run is one more full pass on that code version:

- API 35 full command;
- API 34 extra;
- API 29 and API 29 2 GB: s01–s04 and s18;
- API 28;
- tablet s12.

**Android-lane items open:** none. The `debugCaptureFrame` fix (ae6cda2) passed s18 inside the
batch on API 35 and API 29.
