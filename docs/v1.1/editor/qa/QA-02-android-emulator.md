<!-- OWNER: QA-02 -->

# QA-02: E2E suite on the Android Emulator

This report covers QA-00's app-level suite (`integration_test/editor`, ARCH §21.2) run on Android
Emulators on the Windows laptop (BUILD_PLAN QA-02). It also holds the API 28 below-gate checks, the
Android export extra on API 34 and API 35, the tablet run of scenario 12, and the manual tablet
steps for the owner (hardware keyboard, mouse, drag from Files and Photos).

**Status (2026-10-16, 23:50): not certified.**

- **API 35 phone, full pass on code C (0cfc691, 22:07–23:06, one emulator, fresh install,
  audio):** 11 of 18 scenarios pass in the batch (s01, s03, s04, s05, s08, s11, s14–s17; s08 and
  s16 for the first time on recent code). Rerun alone: s02 and s06 pass (flaky in the batch); s18
  passes after an Android-lane fix to `debugCaptureFrame` (see "Android-lane fixes"). Still failing
  alone: s07, s09, s10, s12, s13, all with Mac-owned causes. s10 is decided: the engine draws the
  plan's offline placeholder after the relink (FIX M-8, now a Dart request). s09's recover phase is
  a new failure on C (FIX M-15).
- **Export extra:** 4 of 7 phases pass on API 34 (code B) and on API 35 (code C). The 3 that fail
  do so because the host actions do not do what they claim on these images (the activity is not
  destroyed, the task is not swiped away, Cancel cannot be found).
- **Gate devices:** API 29 and API 29 2 GB pass s01, s03 and s04 (and s18 on API 29). s02 fails
  there (Mac, UX-41). The API 28 manual checks pass; the API 28 automated test skips itself (Mac).
- **Tablet:** s12 fails. The manual checklist has not been run yet.

"What remains for certification" at the end lists every open item.

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
  command carries `-s <serial>`. `e2e_android.sh` runs `adb kill-server` on an emulator restart
  only when no other device is attached.
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

All AVDs: x86_64, `google_apis` (no Play Store), GPU `auto` (SwiftShader, GLES 3.0), audio input
on, 16 GB data. The RAM column is the effective `hw.ramSize` from `hardware-qemu.ini`. On the
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

All runs took place on 2026-10-16 on the `editor-android` branch. The Mac's triage fix **e0fa7e8**
(the `grantNotifications` host action, seek after the plan ack, the 10 s Dart timeout on the
notification request, and the s06/s08/s10/s12/s13 test fixes) reached this branch with merge
**d723c10** at 16:38.

| Label | Code | Used for |
|---|---|---|
| **A** (before the fixes) | 542dcc6 + Android-lane backups up to 75b6a53, before e0fa7e8 | API 35 full pass 1 (13:12–14:38) and pass 2 (failed batches, 14:43–16:37); API 28 / 29 / 29 2 GB (14:23–16:06, from the `dv2` copy) |
| **B** | d723c10 + merge 2be8a84 + the final AND-14 `Permissions.kt` (e6a9340) and its tests, up to 0ad2477 | API 35 reruns (19:27–21:44, main checkout); API 34 and tablet runs (19:33–21:10, `dv2` refreshed from the main checkout's tracked files) |
| **C** (current) | 0cfc691: editor-wip c93ad22 merged (incl. the Mac's ebc2fb2: job resume after the first media resolve, preview restart, captions resume fraction) + AND-18's range-touch vectors | API 35 full pass (22:07–23:06) and the solo reruns of the failed batches (23:09–23:43), main checkout, `emulator-5554` only |
| **C+** | C + the `PreviewSession.debugCaptureFrame` fix (WIP 550b8ac) | the s09 recover phase run alone (23:14–23:16) and the solo reruns from s02 on (23:17–23:43: s02, s06, s07, s12, s13, the extra phases), the s18 rerun at 23:44–23:46 and the PreviewSessionTest run. The fix only changes `debugCaptureFrame` |

Runs on A and on B differ only in the e0fa7e8 fixes, AND-14 and the runner changes. Every API 35
scenario that failed on A was rerun on B, except s16 and s18 (see the matrix). C has no QA-00 test
or harness change since B (`git diff 0ad2477 0cfc691 -- integration_test/` is empty): none of FIX
M-1 to M-14 has landed yet. The API 28, API 29, API 29 2 GB results are from code A; the API 34 and
tablet results are from code B. None of them was rerun on C.

On C the JVM tests asked for with the merge ran on Windows (one Gradle worker,
`testDebugUnitTest --tests '*Int07GlueTest*' --tests '*RangeTouchVectorTest*' --tests '*RangeTouchTest*'`):
`Int07GlueTest` compiles with the Mac's `RecordingSignals.installOnce` keyed per `EngineContext`
and passes 8 of 9, including `theBridgeEmitsOnceperChangeAndMutes`; the one failure is the known
Windows-only path test (FIX M-11). `RangeTouchVectorTest` (new, FIX-AND-18-1) passes 1 of 1 and
`RangeTouchTest` 3 of 3 (0cfc691's commit message).

## Results matrix

Latest result per scenario and device. The cell gives the result, the time (all 2026-10-16) and
the code label. "—" means the scenario is not in that device's QA-02 scope. "not run" means it is
in scope but has not run yet.

| # | API 35 phone | API 29 | API 29 2 GB | Tablet | Note |
|---|---|---|---|---|---|
| s01 | **pass** 22:09 C | **pass** A | **pass** A | — | |
| s02 | **pass** 23:18 C+ (alone); **fail** 22:11 C (batch) | **fail** 2 of 2 runs, A | **fail** in the full run, **pass** alone, A | — | API 35 batch: the player never reached 0:05:10 within 30 s (`s02_player_to_editor_test.dart:33`, screen 00:00 / 00:08), before the editor opens; seen once on API 29 too. Flaky (player seek, media_kit), not the editor. API 29: FIX M-9 (UX-41) |
| s03 | **pass** 22:13 C | **pass** A | **pass** A | — | |
| s04 | **pass** 22:15 C | **pass** A | **pass** A | — | the e0fa7e8 seek fix works on API 35 |
| s05 | **pass** 22:17 C | — | — | — | |
| s06 | **pass** 23:21 C+ (alone, fresh install); **fail** 22:20 C (batch) | — | — | — | batch: close blocked by "Couldn't save your latest changes" (FIX M-1), as in 3 of 3 runs on B. Passed alone for the first time: timing-dependent |
| s07 | **fail** 22:24 C (batch) and 23:26 C+ (alone) | — | — | — | both exports complete; burned caption t1b 293 px (> 300 needed), the same count as on B (FIX M-2). No emulator death this time |
| s08 | **pass** 22:26 C (in the batch, after a reset) | — | — | — | first batched pass: 3 cues, SRT round trip and undo. The earlier batched failures (B) came right after emulator reboots; there were none in this pass |
| s09 | **fail** 22:30 C (batch) and 23:16 C/C+ (alone: edit phase on C, recover phase on C+) | — | — | — | edit phase ends with the host kill as designed; the recover phase restores the project and the text, then the editor does not close in 30 s, with no dialog on screen (FIX M-15). Passed on A |
| s10 | **fail** 23:09 C (2 of 2 runs) | — | — | — | relink works; after it the preview shows the plan's offline placeholder (solid 0x303030), so no barcode: decided, a Dart (INT-02 / PlanSync) cause, not AND-16/ENG-08 (FIX M-8) |
| s11 | **pass** 22:34 C | — | — | — | |
| s12 | **fail** 22:37 C (batch) and 23:29 C+ (alone) | — | — | **fail** 20:31 B (2 of 2 runs) | phone: marquee (FIX M-3); tablet: `tile.tool.format` off the tool rail (FIX M-4), then the same marquee failure |
| s13 | **fail** 22:39 C (batch) and 23:31 C+ (alone) | — | — | — | recording works (host mic on); the clip is 10.63 s (batch) / 10.10 s (alone), 2.5–4 s expected (FIX M-5) |
| s14 | **pass** 22:42 C | — | — | — | the export works with the `grantNotifications` host action |
| s15 | **pass** 22:44 C | — | — | — | |
| s16 | **pass** 22:46 C | — | — | — | first run on recent code; no close dialog |
| s17 | **pass** 22:48 C | — | — | — | |
| s18 | **pass** 23:46 C+ (alone, fresh install); **fail** 22:50 and 23:12 C | **pass** A | not run | — | on C the reopen step failed with `EngineFailure(internal: nothing composed)` from `debugCaptureFrame` (2 of 2): an Android-lane defect, fixed (see "Android-lane fixes"). Not yet rerun inside a full batch |

The per-device times for API 29 / 29 2 GB are in their `summary.txt` files (s01 552 s / 479 s,
s03 283 s / 507 s, s04 280 s / 242 s, s18 255 s on API 29).

### Android export extra (`x_android_export_background`)

| Phase | API 35 (batch 22:51–23:06 on C, alone 23:32–23:43 on C+) | API 34 (B, 19:33–20:21) | Note |
|---|---|---|---|
| fgs | **pass** (2 of 2) | **pass** (2 of 2) | the export keeps running as a foreground service after `destroyActivity`; the host ends the app |
| fgs-check | **fail** (2 of 2): `ExportReattach.none`, expected `finished` | **fail** (2 of 2): same | harness: the activity is never destroyed, so the export finishes attached (FIX M-6) |
| cancel | **fail** (2 of 2): "no Cancel button in the shade" | **fail** (2 of 2): "no Cancel button in the shade" | harness: `uiautomator dump` fails while the notification updates (FIX M-7) |
| swipe | **pass** (2 of 2) | **pass** (2 of 2) | the host reports the app ended |
| swipe-check | **fail** (2 of 2): `none`, expected `finished` | **fail** (2 of 2): same | harness: the task is still there after the swipe under load (FIX M-6) |
| death | **pass** (batch; not rerun, it passed) | **pass** (rerun) | `am kill` mid-export; needed the runner race fix (see "Android-lane fixes") |
| death-check | **pass** (batch) | **pass** (rerun) | exactly one interrupted record; reattach `interrupted` |

**What the extra proves and what it does not.** The export runs as a foreground service of the
right type on both images. A process death mid-export leaves exactly one interrupted record. The
detached path, where the export finishes while no activity is attached and the relaunch reattaches
as `finished` (AND-12), has **not been exercised**. The harness never really destroyed the
activity or removed the task, so every fgs/swipe export ended with `detached=false`. These results
neither prove nor disprove AND-12's detach handling.

### API 28 below-gate checks (code A)

| Check | Result | Evidence (`build/e2e/android/emulator-5556/avd-Pixel_API_28/`) |
|---|---|---|
| `x_android_api28` automated | **skip**. The runner says PASS but the log says "All tests skipped". The skip condition is platform-only (FIX M-10). The test file is unchanged on B, so it still skips. | `logs/x_android_api28_test.log` |
| Home edit button shows | **pass** (manual, debug app with the editor flag, fresh install) | `manual/01_home.png` |
| Projects shows the `android_too_old` copy | **pass** (manual): "Video editing needs Android 10 or later…" | `manual/02_projects.png` |
| Player Edit explains | **pass** (manual): a dialog with the same copy; no editor opens | `manual/03_player.png`, `manual/05_player_edit.png` |
| Existing player tests stay green | **not applicable**: there are no player device tests. `integration_test/` holds only `editor/`, `editor_ai/` and `editor_store/`. | — |

The engine log confirms the gate: `supported=false reason=android_too_old`.

### Tablet (Pixel_Tablet_API_35, code B)

| Item | Result |
|---|---|
| s12 automated | **fail** in `run3_fresh` and `run4_rerun_alone`: "Timed out after 30 s waiting for tile.tool.format" (`s12_keyboard_pointer_test.dart:103`). At 2560×1600 the left tool rail is cut off at the timeline split: Media to Effects show, Filters is half visible, Format is off-screen and never built. `tapTile` scrolls only the phone's `ToolStrip`, not the tablet's `ToolRail`. |
| s12 with a local, uncommitted QA-00 patch | With `tapTile` also scrolling the `ToolRail` (`gpu_host_patched/qa00_tapTile_rail.diff`, reverted afterwards): the Format tile, Space, wheel and context-menu steps **pass**, then the run fails at the marquee (line 144), as on the phone. Diagnostic only; it does not count as a result. |
| Editor screenshot at tablet size | **taken**: `run4_rerun_alone/screens/tablet_editor_2560x1600.png`. It shows the two-pane editor (tool rail, media panel, preview, timeline) with the rail ending at Effects. |
| Manual M1–M4 | **not run** (owner; see the checklist) |

Earlier tablet runs (`run1`, `run2`, the earlier agent's, FAIL*) are not counted: the emulator
died in them. The GPU-mode trials (`gpu_*`, see `gpu_trials_README.txt`) changed nothing in the
s12 result.

## Measured values

All on emulators with software codecs and SwiftShader GL. They are **not** performance numbers;
QA-04 measures on devices. All values below are from code C on API 35 (`emulator-5554/full/` for the batch,
`emulator-5554/solo/<batch>/` for the reruns alone), except where API 34 is named.

| What | Value | Where |
|---|---|---|
| Encoders | every export: video `c2.android.avc.encoder` (`hardware=false`), audio `c2.android.aac.encoder` (software codecs, as before) | `DanaviewEngine: export … done, encoder …` lines in `full/logs/batch-*.logcat.txt` |
| s07 exports | 4 305 971 B and 4 259 887 B, 8.0 s each (identical in the batch and alone) | `full/logs/s07_export_verified_test.log`, `solo/s07/` |
| s07 burned caption t1b | 293 changed pixels in the subtitle area (threshold > 300), in both runs; t1a passed | same |
| s14 export | "E2E pip", 4 771 418 B, 8.0 s | `full/logs/s14_pip_overlay_test.log` |
| s15 export and levels | "E2E audio", 4 511 851 B, 10.0 s; head −15.1 dBFS, body −9.0 dBFS | `full/logs/s15_extract_audio_music_test.log` |
| s08 captions | 3 cues from whisper-tiny ("Welcome to the video editor test, \| the quick brown fox jumps over the …"); SRT round trip and undo pass; batch 103 s | `full/logs/s08_auto_captions_test.log` |
| s12 wheel (phone) | Ctrl+wheel zoom 45.45 → 75.76 px/s; scroll −1.53 → 1.10 s (batch), −1.50 → 1.13 s (alone) | `full/logs/s12_keyboard_pointer_test.log`, `solo/s12/` |
| s13 microphone | `DANAVIEW_E2E_AUDIO=1`: the AVD booted with audio, `adb emu avd hostmicon` on; the host input is the laptop's Built-in Microphone Array (Intel Smart Sound Technology for Digital Microphones). The app's `VoiceRecorder` held audio focus 22:39:12.495–22:39:23.403 | `full/runner.log` ("host microphone: on"), `full/logs/batch-s13.logcat.txt` |
| s13 recording length | 10.63 s (batch), 10.10 s (alone), for a 3 s recording | `full/logs/s13_voiceover_test.log`, `solo/s13/` |
| Extra export (API 35) | 7 789 785 B, `detached=false` | `full/logs/batch-x_android_export_background-fgs.logcat.txt` |
| Extra export (API 34, B) | gallery insert done, 7 785 197 B, `detached=false` | `emulator-5556_Pixel_API_34/rerun_alone/` |
| FGS on API 35 | `isForeground=true types=0x00002000` (mediaProcessing), channel `danaview_editor_export`, category progress, 1 action | `DV_E2E_FGS` lines in `full/logs/batch-x_android_export_background-{fgs,cancel,swipe}.log` |
| FGS on API 34 (B) | `types=00000001` (dataSync); logcat `export service: foreground (type 1, API 34)` | `emulator-5556_Pixel_API_34/run1/`, `rerun_alone/` |
| Batch times on API 35 (C) | s01 79 s, s03 102 s, s04 106 s, s05 96 s, s08 103 s, s11 103 s, s14 136 s, s15 127 s, s16 97 s, s17 94 s; extra fgs 250 s, cancel 108 s, swipe 249 s, death 235 s; emulator restarts: 0 | `full/summary.txt` |

`DV_E2E_*` values of this pass. Build defines: `DANAVIEW_EDITOR=true`, `DANAVIEW_AUTO_CAPTIONS=true`,
`DV_E2E_HOST=true`, `DV_E2E_PHASE=<phase>` (extra and s09); runner `DV_E2E_PHASE_TIMEOUT=1200`.
Reported lines: `DV_E2E_EXPORT` (the s07, s14 and s15 exports above), `DV_E2E_REPORT` (s08 cues,
s12 wheel, s15 levels), `DV_E2E_FGS` (fgs, cancel, swipe), `DV_E2E_HANDSHAKE` (`grantNotifications`
before every export, `grantMic` in s13, screenshots, `kill` in s09, the extra's host actions).

### GLES 3 and tier

The engine logs one capabilities line per process (`core/Capabilities.kt`).

| Device | Line (abridged) | Tier | Verdict |
|---|---|---|---|
| API 35 phone | `supported=true tier=LOW api=35 ram=4110262272 lowRam=false gles3=true gl=OpenGL ES 3.0 SwiftShader 4.0.0.1 maxTexture=8192` | LOW | ok |
| API 35 tablet | `supported=true tier=LOW api=35 ram=4110274560 … gles3=true … maxTexture=8192` | LOW | ok |
| API 34 | `supported=true tier=LOW api=34 ram=3123421184 lowRam=false gles3=true … maxTexture=8192` | LOW | ok |
| API 29 | `supported=true tier=LOW api=29 ram=3143041024 gles3=true gl=OpenGL ES 3.0 SwiftShader 4.0.0.1 maxTexture=8192` | LOW | ok; GLES 3 confirmed |
| API 29 2 GB | `supported=true tier=MINIMAL api=29 ram=2089222144 lowRam=false gles3=true …` | MINIMAL | ok, as D-40 expects |
| API 28 | `supported=false reason=android_too_old` | — | ok |

- API 29 offers GLES 3 only with `-feature GLESDynamicVersion`. `e2e_android.sh` adds it for API 29
  AVDs.
- `lowRam=false` on the 2 GB AVD: the emulator does not set the low-RAM flag. The tier comes from
  the RAM size alone, which is what D-40 needs here.

## Emulator realities (reported, not failed)

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
  and the whole pass had 0 emulator restarts.
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
  s08, so this should not hit that run; the helper still cannot close past the sheet (FIX M-14).
- **`always_finish_activities` has no effect** on the API 34 and API 35 images. After
  `settings put global always_finish_activities 1` and HOME, `dumpsys activity` still shows
  MainActivity STOPPED and in history, even with the setting held for 8–10 s. This is why fgs-check
  never sees a detached export (FIX M-6).
- **`uiautomator dump` fails while a progress notification updates** ("could not get idle
  state"). Notification-shade automation must not depend on it (FIX M-7).
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
  `emulator-5556_Pixel_Tablet_API_35/gpu_*` and `gpu_trials_README.txt`.

## Android-lane fixes this round

Android-lane commits of this round, all on `editor-android` and all in code C or C+:

| Commit | What |
|---|---|
| 0f15c97 | AND-14: the notification-permission request always returns (landing record) |
| 9ef20b8 | AND-16: no crash when a recording mutes a preview that is still opening |
| 696fe0b | AND-15: copied file names capped in UTF-8 bytes, not only characters |
| 0cfc691 | AND-18: `RangeTouchVectorTest` replays the shared range-touch vectors (FIX-AND-18-1) |
| 550b8ac (WIP) | `PreviewSession.debugCaptureFrame` waits for a seek in flight (s18, this pass); landing record still to come |

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
- Not yet: s18 inside a full batch, and `lintDebug` (the change adds no API).

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

Each request below either reproduced on code B (d723c10 or later), or is about a file that is
unchanged on B and has a deterministic cause (M-10). M-1, M-2, M-3, M-5, M-6, M-7 and M-8 were
checked again on code C (0cfc691) on 2026-10-16 22:07–23:43: each still reproduces (M-1 only in the
batch); M-11 still fails on C. M-15 is new on C. M-4, M-9, M-10, M-12, M-13 and M-14 were not
rerun on C; their files are unchanged since B. The fixes from e0fa7e8 are confirmed on
API 35 and are closed: s04 seek, s06 transition handles, the s07/s14 notification dialog, the s08
track row, the s10 extra step, the s12 phone `tapTile`, and the s13 `MediaKind`.

**M-1. s06: closing hits "Couldn't save your latest changes"**
(QA-00 test, or UX-39 / EditorLifecycle).
- **Where:** `s06_speed_effects_test.dart:130` `ed.close()`.
- **Symptom:** `E2eEditor.close` times out after 30 s with "Couldn't save your latest changes /
  Leave anyway? Your last autosave is kept." on screen. This happened in 3 of 3 runs on B,
  including alone on a fresh install.
- **Cause:** `EditorLifecycle.flushTimeout` is 3 s (`editor_lifecycle.dart:290`). Saving this
  effects-heavy project takes longer on the loaded software-GPU emulator.
- **Also seen:** s16:37 and s18:49 failed the same way on code A. On code C, s16 and s18 do not
  show the dialog (s16 passes; s18's failure was the Android capture defect, now fixed).
- **On C:** s06 failed the same way in the batch (22:20) and **passed alone** on a fresh install
  (23:21): the save races the 3 s timeout, so the result depends on the load.
- **Fix:** either `E2eEditor.close` waits for the save to be idle before it closes, or it answers
  the dialog with Stay and retries. Also consider a longer flush timeout on the LOW/MINIMAL tier.
  A slow phone that shows this dialog on a normal close is a product issue, not only a test one.

**M-2. s07: the burned caption threshold is just missed** (QA-00 test).
- **Where:** `s07_export_verified_test.dart:172`, "burned cue t1b must show in the subtitle area".
- **Symptom:** 293 changed pixels; more than 300 are needed. Run alone, both exports completed.
  t1a passed. The between/t2 checks run only after this one.
- **Fix:** derive the threshold from the cue's glyph area at the export size, or lower it with a
  margin, for example > 200. It is a fixed glyph-pixel count, and the 720p H.264 software encode
  blurs thin glyphs.

**M-3. s12: the marquee selection never starts** (QA-00 test).
- **Where:** `s12_keyboard_pointer_test.dart:144`, "Timed out after 30 s waiting for the marquee
  selection (got {})".
- **Symptom:** on the phone (2 of 2 runs on B), and on the tablet once its Format step was patched
  locally.
- **Cause (about 60% confident):** the drag starts at `laneAt(main, project.duration + 0.5 s)`
  after `zoomFit`. On the phone that point is past the visible canvas. Because the tablet fails
  the same way, the start point may also land on a non-lane widget, or the drag may not reach the
  marquee's mouse handler.
- **Fix:** start the drag from a point that is checked to be inside the lane's hit area (assert
  the hit test). If the selection stays empty, log what was hit.

**M-4. s12 on the tablet: `tapTile('tool.format')` cannot reach Format** (QA-00 helper; UX).
- **Where:** `support/e2e_editor.dart` `tapTile`.
- **Cause:** it scrolls only the `ToolStrip`, not the tablet's `ToolRail`. At 2560×1600 the rail
  is cut off at the timeline split, so Format is never built.
- **Fix:** scroll the `ToolRail`'s Scrollable too. Diff:
  `build/e2e/android/emulator-5556_Pixel_Tablet_API_35/gpu_host_patched/qa00_tapTile_rail.diff`.
  It was verified locally and not committed.
- **UX note:** on a landscape tablet, Format and Filters cannot be reached without scrolling the
  rail.

**M-5. s13: a host screenshot during the recording makes the clip 10–13 s long** (QA-00 test).
- **Where:** `s13_voiceover_test.dart:59`, which expects 2.5–4 s.
- **Cause:** the test asks the host for a screenshot before tapping Stop. On the loaded emulator
  the request, `adb screencap` and ack round trip took 4–8 s (`host.log` 21:10:48 request, 21:10:52
  screenshot). The microphone, `MediaKind.recording` and the voice lane all pass.
- **On C:** 10.63 s (batch) and 10.10 s (alone). Batch timeline (device clock, from
  `full/logs/batch-s13.logcat.txt` and `host.log`): the recorder takes audio focus at 22:39:12.5;
  the screenshot request arrives at 22:39:19 (the test's 3 s count starts when the `recording` key
  shows, so the UI showed it about 3 s after the recorder started); the screenshot is written at
  22:39:21; focus is released at 22:39:23.4. So about 4–5 s come from the screenshot and about 3 s
  from the time between the recorder start and the `recording` key on this loaded emulator. Taking
  the screenshot after Stop alone may not bring the clip under 4 s here; comparing with the
  device-side Record→Stop time is the robust fix.
- **Fix:** take the screenshot after Stop. Or compare the clip length with the time between the
  Record tap and the Stop tap (both on the device clock) instead of a fixed range.

**M-6. Export extra: `destroyActivity` and `swipeFromRecents` do not do what they claim**
(QA-00, `integration_test/editor/tool/e2e_host.sh`).
- **destroyActivity** (`e2e_host.sh:149-152`):
  - **Symptom:** `always_finish_activities 1` + HOME leaves MainActivity STOPPED and in history on
    API 34 and API 35. fgs-check gets `none`, expected `finished`, in 2 of 2 runs on each.
  - **Fix:** destroy the activity for real, for example by having the test app finish its activity
    on a handshake request (test-only path). Then have the host confirm with
    `dumpsys activity activities` (no ActivityRecord for `com.vecvel.danaview`) before it acks.
- **swipeFromRecents** (`e2e_host.sh:142`):
  - **Symptom:** during an export the task stays after the swipe, on API 34 and API 35. On an idle
    app the same swipe removes it. The 1.5 s wait for recents is too short under load.
  - **Fix:** wait until recents is shown, retry the swipe, and confirm with
    `dumpsys activity recents` that the task is gone before the ack.
- Until both are fixed, the detached export path (AND-12) is untested on Android.

**M-7. `tapNotificationCancel` cannot find Cancel** (QA-00, `e2e_host.sh:127-135, 187-191`).
- **Symptom:** `uiautomator dump` fails ("could not get idle state") while the export's progress
  notification updates. This failed in 2 of 2 runs on API 34 and on API 35.
- **Fix:** send the notification's cancel action directly (a broadcast or service intent with
  `-p com.vecvel.danaview`; the deterministic option). Or retry the dump with the shade expanded.

**M-8. s10: after the relink the preview draws the offline placeholder** (Dart: INT-02
`SessionAssetResolver` / PlanSync after a relink, or CORE-28 availability; decided on C, not an
Android-lane defect).
- **Where:** `s10_missing_media_relink_test.dart:80`, `Expected 10, Actual null`. 3 of 3 runs on B,
  2 of 2 on C.
- **Evidence (C, `solo/s10/`):** a host screenshot every 1–2 s during the run (`hostcaps/`). Before
  the relink the preview shows the Media missing card. After "Relink 3 files" ("Everything is
  back", 23:09:14) the preview is a flat grey under the sheet's scrim (19, 19, 19). Once the sheet
  is closed, at the seek to 00:00:00:10 (23:09:16, `hostcaps/230916.png`), the whole preview area
  is a flat **(48, 48, 48)**, which is exactly `offlinePlaceholderColor` 0xFF303030
  (`danaview_editor_core/lib/src/plan/lowering_visual.dart:46`), and the timeline clips still have
  no thumbnails. The Android engine has no grey of its own: it clears to black, and 0x303030 can
  only come from a `solid` layer in the plan. So the engine holds a plan in which the clip is still
  the offline placeholder; it draws that plan faithfully, acks the seek with frame 10, and the
  capture has no barcode. The relinked file never reached the engine's plan.
- **Likely place:** `default_plan_compiler.dart` resolves each asset once per (media id, locator,
  status, fingerprint) and retries a failed resolve only when the availability report changes. After
  the relink either the report is not refreshed before the next compile, or the compiler still
  sees the asset as `missing`, or PlanSync does not resend after the relink.
- **Request:** after a relink, recompile with fresh availability and push the plan; add a unit test
  "relink → compiled plan has a `media` layer with the new uri, no offline solid". Keep the s10
  check as it is.

**M-9. s02 on API 29: the player-to-editor handoff loses the playhead** (UX-41).
- **Symptom:** `Expected 160, Actual 0` with "player position at Edit 5333000 us; project
  view.playhead 0 us". This happened in 2 of 2 runs on API 29 and in the full run on the 2 GB AVD;
  s02 passed alone on the 2 GB AVD. Once, the player also never reached 0:05:10 within 30 s.
- **Code:** this ran on code A. `editor_launcher.dart` is unchanged on B, but the E2E support files
  changed, so it must be rerun on B before the Mac acts on it.
- **Suspect:** `editor_launcher.dart` (the `createProjectImportJob` route, or
  `findUntouchedProjectFor` after a data clear).
- **Request:** a debug log of `at` and the initial `view.playhead`.

**M-10. `x_android_api28_test.dart` skips itself on every Android device** (QA-00).
- **Cause:** `below = EditorAvailability.platform is! EditorSupported` (line 24) checks only the
  platform, so the `skip:` at line 52 is always taken. This ran on code A. The file is unchanged
  on B, so it still skips.
- **Fix:** base `below` on the device verdict (`editorDeviceSupportProvider` with reason
  `android_too_old`), or on SDK < 29.

**M-11. INT-07 frozen glue test fails on Windows only** (INT-07, test only).
- **Test:** `Int07GlueTest.materializePickRunsOnIoWithTheNormalizedDirectory`.
- **Symptom:** expected `/data/user/0/app/cache/danaview/editor/work/picks/u1/clip.mp4` but got
  backslashes. The fake records `File.path`. It passes on macOS and on the device.
- **On C:** the same single failure (8 of 9 pass; the Mac's per-`EngineContext` `installOnce`
  change compiles and its test passes). `Int07GlueTest.kt:38-39` is unchanged.
- **Fix:** use `intoDir.invariantSeparatorsPath` in the test's fake (`Int07GlueTest.kt:39`).

**M-12. `lintDebug` and `connectedDebugAndroidTest` in one Gradle invocation fail validation**
(`build.gradle.kts` owner).
- **Cause:** `lintAnalyzeDebugAndroidTest` and `generateDebugAndroidTestLintModel` read the
  generated `danaviewTestFixtures` without depending on `syncDanaviewTestFixtures`. Run separately,
  both pass.
- **Fix:** add the dependency (or declare the input).

**M-13. Docs** (QA-00): `docs/v1.1/editor/qa/README.md` still says "Emulator run: deferred:
Windows lane (QA-02)". Point it to this report.

**M-14. s08: `E2eEditor.close` cannot get past the "export interrupted" sheet** (QA-00 helper or
test).
- **Where:** `s08_auto_captions_test.dart:118` `ed.close()`, `support/e2e_editor.dart:165`.
- **Symptom:** in `solo/s08_nofresh` (no fresh install, no reset, right after the death phases)
  the captions passed, then the close timed out with "The export was interrupted" on screen (keys
  `export-interrupted-close`, `export-start-again`).
- **Fix:** have `E2eEditor.close` dismiss that sheet (Close), or have s08 start from clean state.

**M-15. s09 recover: the editor does not close after a restore** (new on C; UX-35 tasks /
EditorLifecycle; suspect ebc2fb2).
- **Where:** `s09_recovery_after_kill_test.dart:60` `ed.close()` in the recover phase.
- **Symptom:** the restore works (the project and the `RECOVER …` text come back), then Close
  times out after 30 s with the editor still on screen ("Saved", no dialog). 2 of 2 on C (batch
  22:30, alone 23:16). The same phase passed on A (13:45); it was not rerun on B.
- **What the logs show:** after Close, the preview's deck players are never released (in a normal
  close, e.g. s18, the four deck `ExoPlayerImpl` instances are released when
  the editor closes); there is no engine error. So the close flow stops before the preview session is
  released, or the release never returns. The only editor change between A/B and C in this area
  is ebc2fb2 (FIX-QA05-D5: tasks wait for the first media resolve before resuming jobs; preview
  restart after resume), and a restored session is exactly the case that resumes jobs.
- **Request:** a debug log of each close step (`flushBeforeClose` result, `_release` start/end,
  `EditorSession.close`, the tasks controller's pending resume) and a unit test "close right after
  a recovery restore completes". The Android lane will then check the native release if the Dart
  side reaches it.

**Flaky, no request (s02 on API 35).** In the C batch the player never reached 0:05:10 within 30 s
(`s02_player_to_editor_test.dart:33`, the screen shows 00:00 / 00:08), before the editor is
involved; alone it passed. The same symptom was seen once on API 29 (M-9). If it recurs, the test
could retry the player seek once.

The code-review findings on the native glue (D2–D6 in the Android lane's Mac list: the copy on the
io lane, the free-space check, error codes, notification-text validation, `file://` decoding) are
review items, not QA-02 reproductions. They are tracked there, not here.

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
   "$ANDROID_HOME/emulator/emulator.exe" -avd Pixel_Tablet_API_35 -no-snapshot-save
   ```

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

Row 3 matters: the automated marquee step fails (FIX M-3), so a pass by hand tells whether the
problem is the test or the app. If the emulator window zooms on Ctrl+wheel, or right-click never
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

Paths are relative to `build/e2e/android/` (local to the Windows laptop; not committed). Before
the code C pass, everything that was in `emulator-5554/` was moved to
`_before_c93ad22/emulator-5554/`. Paths of code B runs cited elsewhere in this report as
`emulator-5554/…` or `solo/…` (with "B") are now under that folder.

| Folder | Device | Code | Content |
|---|---|---|---|
| `emulator-5554/full/` (`logs/`, `screens/`, `files/`, `summary.txt`, `runner.log`) | API 35 | C | the full pass, 22:07–23:06, fresh install, audio, models, one emulator |
| `emulator-5554/solo/{s10,s18,s09,s02,s06,s07,s12,s13,x_fgs,x_cancel,x_swipe}/` | API 35 | C (s02 on: C+) | each failed batch rerun alone on a fresh install (23:07–23:43); `s10/hostcaps/` holds the host screenshots of the relink |
| `emulator-5554/solo/s18_capturefix/` | API 35 | C+ | s18 alone after the capture fix (pass), `PreviewSessionTest_connected.log`, `preview_unit.log` |
| `_before_c93ad22/emulator-5554/` (`logs/`, `screens/`, `screens_run2/`, `files/`, `summary_run2.txt`) | API 35 | B | rerun run 1 (19:27–20:30) and run 2 (20:40–21:27). `logs/` holds only the latest log of each batch, so later runs overwrote run 1's logs of s06–s13. Run 1 wrote no `summary.txt`; its runner log was not kept under `build/`. `summary.txt` now holds only the solo s07 row. |
| `_before_c93ad22/emulator-5554/solo/{s06,s07,s08,s10}/` | API 35 | B | single-batch reruns on a fresh install (21:33–21:44) |
| `_before_c93ad22/emulator-5554/solo/s08_nofresh/` | API 35 | B | s08 alone at 21:30–21:32, no fresh install and no reset, right after the death phases |
| `_prev/emulator-5554-20261016-1926/pass1/` | API 35 | A | full pass 1 (13:12–14:38): s01, s02, s03, s05, s09, s11 pass |
| `_prev/emulator-5554-20261016-1926/logs/` | API 35 | A | pass 2, failed batches (14:43–16:37), incl. s16 and s18 |
| `emulator-5556/avd-Pixel_API_28/` | API 28 | A | automated log and manual screenshots |
| `emulator-5556/avd-Pixel_API_29/{run1,rerun_s02}/` | API 29 | A | s01–s04, s18 |
| `emulator-5556/avd-Pixel_API_29_2GB/{run1,rerun_s02}/` | API 29 2 GB | A | s01–s04 |
| `emulator-5556_Pixel_API_34/{run1,rerun_alone}/` | API 34 | B | all extra phases; `rerun_alone/logs/probe-activity.log` (activity probe every 2 s) |
| `emulator-5556_Pixel_Tablet_API_35/{run3_fresh,run4_rerun_alone}/` | tablet | B | s12 and the tablet screenshot |
| `emulator-5556_Pixel_Tablet_API_35/gpu_*` | tablet | B | GPU-mode trials and the patched `tapTile` diagnostic |

Superseded and not used: `_run3_cert/`, `_rerun4_cert/`, `_stale_before_1145/`,
`_api35_slowemu_1252/`, `emulator-5556/avd-Pixel_API_34/run1/` (a grant-order problem, before the
`grantNotifications` host action), `emulator-5556_Pixel_Tablet_API_35/run1`, `run2` (emulator died).

## What remains for certification

BUILD_PLAN acceptance: every scenario passes on API 35, the gate/minimal/FGS checks pass on API 29
and 34, the API 28 checks pass, and the tablet keyboard/mouse and drop evidence is recorded, with
artifacts attached.

1. **Mac fixes** (QA-00 unless noted): M-1 (s06 close), M-2 (s07 threshold), M-3 and M-4 (s12
   marquee and tablet rail), M-5 (s13 recording length), M-6 (destroyActivity and
   swipeFromRecents), M-7 (notification Cancel), M-8 (INT-02/PlanSync: the relinked media never
   reaches the plan), M-9 (UX-41, s02 on API 29), M-10 (API 28 skip), M-14 (s08 close past the
   "export interrupted" sheet), M-15 (s09 recover close), and the test/build items M-11 (INT-07
   test path on Windows) and M-12 (`build.gradle.kts` lint input).
2. **API 35 full pass on one code version** after those fixes, with only one emulator running:
   `DANAVIEW_E2E_FRESH=1 DANAVIEW_E2E_AUDIO=1 DANAVIEW_E2E_MODELS=<models dir> scripts/ci/editor/e2e_android.sh`.
   All 18 scenarios and all 7 extra phases must pass in the batch. On code C, 11 scenarios and 4
   phases already pass in the batch; s18 must also pass inside a batch with the capture fix, and
   s02 and s06 must pass in the batch, not only alone.
3. **The detached export (AND-12)** must be shown on API 34 and API 35: fgs-check and swipe-check
   return `finished`, after M-6 makes the host really destroy the activity or remove the task. If
   they still fail after that, it is an Android-lane defect (AND-12).
4. **API 34 cancel** after M-7.
5. **API 29 and API 29 2 GB** rerun of s01–s04 and s18 on the final code (s18 has never run on the
   2 GB AVD), with s02 passing after M-9.
6. **API 28**: rerun `x_android_api28` after M-10, so the automated check really runs. The manual
   checks already pass.
7. **Tablet**: s12 automated passes after M-3 and M-4; the owner runs M1–M4, and this report
   records each row with its screenshot.
8. **README**: QA-00's README status line points here (M-13).
9. **Artifacts**: list the final evidence folders here, and remove or mark the superseded ones.

Android-lane items still open from this round:

- s18 inside a full batch with the `debugCaptureFrame` fix, `lintDebug` on that change, and its
  landing record (it is only in WIP 550b8ac so far);
- the native side of M-15, if the Dart close reaches the preview release and it does not return;
- AND-12, if item 3 still fails after M-6.

M-8 is answered: not an Android-lane defect.
