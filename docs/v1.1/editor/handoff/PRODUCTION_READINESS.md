# Danaview 1.1.0 editor: path to production (handoff for any agent)

> **Written:** 2026-10-17 00:15 IST by the Mac lead session. **Branch:** `editor-wip` (Mac) and `editor-android` (Windows), both pushed to `github.com/vecvel/danaview`. **Ground truth:** the code on `editor-wip` plus the QA reports in `docs/v1.1/editor/qa/`.
> **Purpose:** if the current session stops (usage limit, app restart), any agent or person can finish v1.1 from this file alone. Read it top to bottom once, then work through §4 in order.
> **Owner plan:** the app goes live only after v1.3 is built. So v1.1 must reach "release-ready" (code complete, QA certified, release changes prepared), but the release switch-on (INT-05 apply) waits for the owner.

---

## 0. Live status (kept current; last update 2026-10-17 00:50 IST; Android fixes merged 00:47)

| Ticket | State | What's left |
|---|---|---|
| **QA-01** iOS simulator E2E | **Nearly certified.** Full run 16/18; s07 and s13 pass when re-run alone. iPad s12 passes (V-U5 certified on the simulator). iOS 18.2 lane 3/3 | Fix **FIX-IOS-12-1**: the second back-to-back export stalls in "rendering" in the s07 full run (IOS-12 `ExportCoordinator.swift` and its writer; probably the same family as D7). The manual iPad Files/Photos drop and the physical-keyboard step need a person (screenshots in `build/e2e/ios/2C9213E9-.../manual/`). The iPhone 7/8 smoke needs devices |
| **QA-05** soak and crash recovery | **Partial.** The process-death phases pass after FIX-QA05-D5. The seeded soak (5150) fails on **D7** | Fix **D7**: iOS export audio read hang, or SIGSEGV in `MixAudioSource.nextAudio()` `copyNextSampleBuffer` (§4.1), then re-run the soak |
| **QA-02** Android emulator E2E | **Windows lane.** The Kotlin INT-07/ENG-06 fixes are **done and merged** into `editor-wip` (00:47): M-11 `e5ba18d`, M-12 `583c693`, M-16 `e42522a`, M-18 with the native M-17 free-space preflight `7467769`, M-19 `19338db`, M-20 `ee908e4` | After the Mac merges round 7: one clean full QA-02 pass (§4.3) |
| **INT-05** release | **Prepared, not applied** (release-checklist) | Owner "go" |
| Round 7 (Mac Dart fixes M-1, M-2..M-7, M-9, M-10, M-13..M-15, M-17 Dart) | **All 6 tickets done**, review running in worktree `parallel-r7` | Commit the worktree, merge into `editor-wip`, re-run the iOS scenarios it touches (s02, s06, s09, s12, s13) |

Other follow-ups found by QA-01 (not blocking):
- The player library screens (`danaview_home_screen.dart`, `danaview_folder_screen.dart`, `library_storage.dart`) have a follow-up noted in `QA-01-ios-simulator.md`.
- An empty new project shows a preview spinner that keeps spinning with no media; check whether that is intended (UX-18).

**Next actions, in order:**
1. Merge `parallel-r7` once both reviews finish.
2. iOS round: fix D7 and FIX-IOS-12-1, re-run QA-05 and the affected QA-01 scenarios.
3. Windows: merge `editor-wip`, then the full QA-02 pass.
4. Close QA-01, QA-02 and QA-05.
5. INT-05 on the owner's go.

---

## 1. Where things stand

- **Tickets:** 162 of 166 BUILD_PLAN tickets done (see §0 for live detail). Left: **QA-01**, **QA-02**, **QA-05**, **INT-05**.
- **Platforms:** iOS and Android editor features are all built, and the Android lane (ENG-08, AI-04, AND-02 to AND-19) is complete. What remains is the QA certification and the fixes it finds.
- **What's done, in short:** all of M0 to M5; QA-00 (E2E suite), QA-03 (parity), QA-04 (performance; UX-43 closed as not needed), QA-06 (AI eval host side), QA-07 (auto captions, re-run passes; the DANAVIEW_AUTO_CAPTIONS flag can ship), QA-08 (a11y), QA-09 (overflow), QA-10 (persistence), QA-11 (export conformance), and the idle benchmark (CORE-35 gate passes).
- **Release prep:** INT-05 is drafted in `docs/v1.1/editor/release-checklist.md`, with nothing applied. It holds the version 1.1.0+3 diff, the release flag diff, casual store texts, privacy/App Privacy/Data safety texts, owner steps and the rollback plan.
- **Branding:** done and merged. The 6B "page-fold Dv" logo is on every platform, with an outlined wordmark, a new Play feature graphic and the in-app logo. The old Vwish store screenshots are removed; new screenshots are made at launch (after v1.3).
- **Open-source licences page:** restored under Settings › About (FIX-LICENSES, owner decision 2026-10-16).

## 2. What is running or unmerged right now

| Item | Where | What to do |
|---|---|---|
| **Round 6** Mac build (QA-01 re-certification on the iOS simulator) | main checkout `/Users/besaoct/Desktop/danaview` | Let it finish. Its results go into `docs/v1.1/editor/qa/QA-01-ios-simulator.md` |
| **Round 7 parallel** Dart fixes for the Windows QA-02 requests | git worktree `.claude/worktrees/parallel-r7`, branch `parallel-r7` | When finished, `git add -A && git commit` in the worktree, then from the main checkout `git merge --no-edit parallel-r7 && git push origin editor-wip`, then `git worktree remove .claude/worktrees/parallel-r7`. **Merge only after QA-01 has finished**, because QA-01 rebuilds the app from the main checkout's files |
| Windows lane | `C:\dev\danaview`, branch `editor-android` | Kotlin INT-07 fixes (§4.3), then a full QA-02 pass |

If a session ended mid-run, the uncommitted work is safe on disk. The Mac's backup loop committed `editor-wip` every 10 minutes while it ran. Check `git status` in the main checkout and in `.claude/worktrees/*`.

## 3. Rules every agent must follow

1. **Two machines.** The Mac builds iOS and everything else. The Windows laptop builds and tests the Android lane. Never start the Android emulator on the Mac (8 GB RAM). Windows merges `editor-wip` to receive Mac work, and the Mac merges `editor-android`. Android-lane files are `packages/danaview_editor_engine/android/**` and `packages/danaview_whisper/android/**`.
2. **Ownership.** Edit only the files the ticket owns (BUILD_PLAN §0–§2). Fix tickets name the files they may touch.
3. **Commits** carry **no Claude co-author trailer** (owner request).
4. **One iOS simulator job at a time** on the Mac. Use the iOS 26.5 "iPhone 16" (or iPhone 17) simulator; shut down what you boot. Pass `-parallel-testing-enabled NO` for RunnerTests on 8 GB.
5. **Speech models** for scenario 8 and QA-07 are approved and already downloaded on the Mac at `/Users/besaoct/danaview-models` (`ggml-tiny-q5_1.bin`, 32,152,673 B, SHA-256 `818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7`; `ggml-silero-v6.2.0.bin`, 885,098 B, SHA-256 `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`). Stage them with `integration_test/editor/tool/e2e_host.sh stage-models <dir>`. Never commit them. Windows downloads the same files to `C:\dev\models\` (approved).
6. **Owner UI rules** apply to every surface: custom components (no Material chrome), Figtree, dark UI, computed contrast ≥ 4.5:1, touch targets ≥ 44 px, no overflow at 280–1280 px and text scale 0.85–1.35.
7. **Do not apply INT-05** (version, flags, store texts) until the owner says go.

## 4. Remaining work, in order

### 4.1 Mac, iOS lane (after round 6 finishes)

1. **D7 (new, from the QA-05 re-check), iOS export audio read.** Files: `packages/danaview_editor_engine/ios/Classes/Export/ReaderWriterPipeline.swift`, `MixAudioSource.nextAudio()` (IOS-12 / FIX-IOS-EXPORT-STALL follow-up).
   - Symptom: in the seeded soak (seed 5150), the same export op either fails with "audio read hung" (exportFailed.unknown) or crashes with SIGSEGV in `AVAssetReaderAudioMixOutput.copyNextSampleBuffer`.
   - Likely cause: the reader is used or cancelled from another thread while `copyNextSampleBuffer` runs (watchdog or cancel racing the pump). Make reader access single-threaded and serialized, never cancel a reader mid-call, and let the watchdog signal instead of touching the reader.
   - Add a seeded RunnerTest, then re-run the QA-05 soak (seed 5150) and the process-death phases. Update `docs/v1.1/editor/qa/QA-05-soak.md`.
2. **Review the QA-01 result** in `QA-01-ios-simulator.md`. Previously 14/18 (iPhone) plus the extras, iOS 18.2 3/3, iPad s12 nearly there. Round 6 fixed s10 (relink preview, FIX-UX-40-1), s18 (playhead on reopen, FIX-UX-14-1), the s12 marquee and the s13 timing (FIX-TESTS-R6), and play-during-record (FIX-IOS-AUDIOSESSION). Fix any new failures, then re-certify with `scripts/ci/editor/e2e_ios.sh` (iPhone lane full, iPad lane s12, iOS 18.2 lane), and record the manual iPad Files/Photos drop steps that the simulator allows.
3. **Test-infra note from QA-05:** never run two host drivers (`e2e_host.sh` and `soak_host.py`) against the same simulator at once; they answer each other's handshakes.

### 4.2 Mac, Dart lane (round 7, in progress in `parallel-r7`)

These come from the Windows QA-02 requests (full text: `docs/v1.1/editor/qa/QA-02-android-emulator.md`, "FIX requests for the Mac"):

| ID | Fix |
|---|---|
| **M-15** | The editor never closes after a recovery restore (s09 recover). Likely the close waits on the job-resume / first-media-resolve logic from ebc2fb2. Close must never wait on resume |
| **M-1** | "Couldn't save your latest changes" on close under load (flushTimeout 3 s in `editor_lifecycle.dart`). Make it tier-aware and longer, show "Saving…", never lose data; the harness waits for the save |
| **M-9** | Player → editor handoff loses the playhead after a fresh install / data clear (UX-41 `editor_launcher.dart`) |
| M-2, M-14, M-10, M-4, M-13, M-3, M-5 | QA-00 suite fixes (caption threshold, export-interrupted sheet, API 28 self-skip, tablet ToolRail scroll, README line, marquee hit-test, voiceover length vs tap times) |
| M-6, M-7 | Host harness: real activity finish and swipe-from-recents, both verified with `dumpsys`; send the notification Cancel action directly |
| M-17 (Dart) | Check free space before materializing a pick (`media_pool_service.dart:558`) |

M-8 (relinked media never reaching the plan) was fixed in round 6 by FIX-UX-40-1; Windows confirms it on the next pass.

After merging `parallel-r7`, re-run on the iOS simulator any iOS scenario its changes touch (s02, s06, s09, s12, s13 at least).

### 4.3 Windows, Android lane

Lead-approved edits to INT-07/ENG-06 Android files:
- **M-11:** Int07GlueTest uses `intoDir.invariantSeparatorsPath`.
- **M-16:** materializePick on its own thread, with a stall timeout and cancel.
- **M-18:** correct error codes (permissionDenied, storage full, unreadable source), not mediaOffline for everything.
- **M-19:** per-string English fallback for notification texts; never reset the texts process-wide.
- **M-20:** decode %20 in file:// URIs.
- **M-17 (native half):** check free space against the source size before materializing a pick. The Dart half is in round 7 on the Mac.
- **M-12:** in `build.gradle.kts`, the lint tasks depend on `syncDanaviewTestFixtures`.

Status 2026-10-17 00:35: these fixes are in progress on Windows (WIP backups up to 7ca3413, review running).

Also: compile and run Int07GlueTest for the Mac's `RecordingSignals.kt` change (`installOnce` keyed per EngineContext).

Then pull `editor-wip` (with round 7 merged) and run **one clean QA-02 pass on one code version**, as in `QA-02-android-emulator.md` "What remains for certification":
- API 35 full suite: all 18 scenarios plus all 7 export-extra phases, with s08 passing inside the batch.
- The detached export proof on API 34 and 35 (AND-12).
- API 34 notification cancel.
- API 29 and API 29 2 GB: s01–s04 and s18.
- API 28 automated check.
- Tablet s12 plus the owner's manual tablet checklist M1–M4.

Command:
```bash
DANAVIEW_E2E_FRESH=1 DANAVIEW_E2E_AUDIO=1 DANAVIEW_E2E_MODELS=C:/dev/models scripts/ci/editor/e2e_android.sh
```

### 4.4 Certify and close the QA tickets

- **QA-01** is certified when every iOS scenario passes on the final code (§4.1).
- **QA-02** is certified when §4.3 passes; Windows owns `QA-02-android-emulator.md`.
- **QA-05** is certified when the seeded soak and every process-death phase pass after D7 is fixed.
- Update `docs/v1.1/editor/handoff/BUILD_STATE.md` (mark done) and `docs/v1.1/editor/qa/README.md`.

### 4.5 INT-05: release (owner go only)

Follow `docs/v1.1/editor/release-checklist.md`:
- §2 release order;
- §3 prepared diffs: version 1.1.0+3 and `app_info.dart`; flags `DANAVIEW_EDITOR=true` and `DANAVIEW_AUTO_CAPTIONS=true` (QA-07 passed); the whisper xcframework built before `flutter build ipa`; `check_ios_min_os.sh` and `check_native_libs.sh`;
- §4 store texts (casual tone; swap in at launch);
- §5 privacy texts;
- §7 rollback.

## 5. Owner-only steps (cannot be done by agents)

1. **Store records** for `com.vecvel.danaview`: Google Play app and App Store Connect app.
2. **Signing:** the iOS distribution certificate and profiles, the Android upload keystore (the Play service account key is at `/Library/Secrets/danaview-prod-3623cbc6bab3.json`, referenced from `android/fastlane/.env`; never print it), and macOS notarization if a Mac build ships.
3. **Continued-processing GPU entitlement** request to Apple (optional; see release-checklist).
4. **Hosted privacy policy and terms** at vecvel.com (texts in release-checklist §5.1), including the Open-source licences mention.
5. **Real-device checks** (device lab; everything marked "deferred: no device available" in the QA reports):
   - iPhone: HEVC hardware export, thumbnail speed, structural patch time, live mic latency < 100 ms, background export on iPhone 7 (iOS 15.8) and iPhone 8 (iOS 16.7), the one-frame live-layer lag after a rendered-range swap.
   - Android: a real phone for the AND-18 frame check (the emulator glitch was traced to the emulator's software decoder), the BT.709 colour check, hardware encoders, the AND-09 GPU memory on a low-tier phone, TalkBack.
   - VoiceOver.
6. **Store screenshots:** new captures of the real app with the 6B brand (after v1.3, at launch). The fastlane upload lanes refuse to run while the screenshot folders are empty.
7. **The final "go"** for INT-05.

## 6. After v1.1: what is planned next

- **v1.2** (`docs/v1.2/V1_2_ROADMAP.md`): Files & Media Home (photos, videos, documents, PDF tools; `docs/v1.2/files-media-home/FILES_MEDIA_HOME_PLAN.md`), AI Studio (BYO keys, rich subtitles, multi-speaker diarization with overlaps, AI search, shared `danaview_ai`, Genkit spike first), the Unified Photo & Video Editor with the beauty suite, and the speed-test provider fallback.
- **v1.3** (`docs/v1.3/V1_3_ROADMAP.md`): the desktop editor (Swift on macOS, Rust/wgpu on Windows and Linux, FFmpeg only in an isolated helper) and the native camera (one-hand controls, live beauty, document scan and PDF, QR/barcode with payment hand-off and saved codes).
- Owner decisions for all of these are recorded inside each plan ("Owner decision 2026-10-16").

## 7. Useful commands

```bash
# Mac: iOS E2E suite (certification)
scripts/ci/editor/e2e_ios.sh
# Mac: one scenario
integration_test/editor/tool/e2e_host.sh -p ios -d <udid> run s10
# Editor package tests
cd packages/danaview_editor && flutter test
# Core benchmark gate (idle machine)
cd packages/danaview_editor_core && dart run benchmark/run.dart --check
# iOS RunnerTests (8 GB Mac)
cd packages/danaview_editor_engine/example/ios && xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16,OS=26.5' -parallel-testing-enabled NO -only-testing:RunnerTests/<Suite>
# Windows: Android E2E (Git Bash, after `source ~/danaview_env.sh`)
scripts/ci/editor/e2e_android.sh
```

## 8. Key documents

- `docs/v1.1/editor/ARCHITECTURE.md`: the source of truth (it wins over the build plan).
- `docs/v1.1/editor/BUILD_PLAN.md`: tickets, owns lists, acceptance criteria.
- `docs/v1.1/editor/handoff/BUILD_STATE.md`: ticket status table (refresh after each round).
- `docs/v1.1/editor/handoff/ANDROID_LANE.md`, `WINDOWS_SETUP.md`: the Windows lane.
- `docs/v1.1/editor/qa/*.md`: every QA report, including what's still deferred.
- `docs/v1.1/editor/release-checklist.md`, `docs/v1.1/editor/user-guide.md`: release.
