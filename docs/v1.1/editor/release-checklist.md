# Danaview release checklist (editor milestone 1.1)

> **INT-05 is closed in 1.1 (owner, 2026-10-22): moved into the single 1.0.0 release ticket at the end of 1.3**, the widened AIS-41 in `docs/v1.2/BUILD_PLAN.md` (branch `v1.2-wip`). Only the release-pipeline checks of §3.2 are applied now (`f8cd585`); the editor and Auto captions `--dart-define`s, the version, `app_info.dart`, `legal_texts.dart`, the store metadata and every upload wait for that ticket. This file stays its plan for the 1.1 part.
> **Owner:** INT-05 (BUILD_PLAN INT-05; ARCH §23 is the source of every item), now carried by the 1.0.0 release ticket (widened AIS-41).
> **State: prepared, nothing switched on (INT-05-PREP, 2026-10-16; status columns refreshed 2026-10-22 against BUILD_STATE, PRODUCTION_READINESS §0 and the QA reports).** This file holds the filled ARCH §23 checklist, the release changes written out as diffs, the store and privacy texts, and the steps only the owner can do. Only the release-pipeline part of §3.2 is applied (`f8cd585`, 2026-10-22: whisper xcframework build, `check_ios_min_os.sh` and the `nm -um` NEWLAPACK check in the iOS lane; `check_native_libs.sh` in the Android lane and the Android release workflow). Everything else is still a prepared diff: `pubspec.yaml` is `1.0.0+1`, both flags still default to false and no release build passes them, and the fastlane metadata is unchanged.
> **Version (owner decision 2026-10-22):** nothing has been released to production yet, and 1.1, 1.2 and 1.3 are dev milestones only. The first store release is **version 1.0.0, build 1**, tagged `v1.0.0`; nothing has ever been uploaded to App Store Connect or Play (owner, 2026-10-22). "1.1" in this file names the editor milestone (its docs and tickets), not a store version.
> **Go-live:** the app ships once, after the internal 1.3 dev milestone completes (owner, 2026-10-22). INT-05 is applied at that point, with all of 1.1–1.3 in it. Until then this file is the plan for that release build, written for the 1.1 milestone. The store texts in §4 describe what the 1.1 milestone really has. When the public release moves to the 1.3 milestone, rewrite them for that feature set (photos on Home and photo editing arrive in 1.2; the desktop editor and the camera arrive in 1.3).
> **Related:** [user guide](user-guide.md) · [QA index](qa/README.md) · [ARCHITECTURE §23](ARCHITECTURE.md) · [BUILD_PLAN INT-05](BUILD_PLAN.md)

## Remaining before go (2026-10-22)

Tickets: 163 of 166 done; open are QA-01, QA-02 and QA-05. INT-05 is closed in 1.1 and moved to the 1.0.0 release ticket after 1.3 (widened AIS-41, `docs/v1.2/BUILD_PLAN.md`) ([BUILD_STATE](handoff/BUILD_STATE.md), [PRODUCTION_READINESS §0](handoff/PRODUCTION_READINESS.md)).

**Windows (Android lane):**
1. Merge `editor-wip` (it carries FIX M-23 `8fb43c2`, D8 Dart `2c09282`, W1–W7 `5912db4`, FIX-QA05-D8-2 `911110f`).
2. ~~Fix QA-05 D9, D10 and the D8 engine half~~ done on the Android lane (`c90819a` D8 engine half, `92623ff` D9, `74392c9` D10; merged at `b7c4a8c`).
3. QA-02 certification re-run on mains power: s01–s04 + s18 in one batch on Pixel_API_29_2GB, and s02 on API 29.
4. QA-05 Android half with the unmodified `soak_host.py`: seeded soak (seed 5150, 15 min) and the death chain, then the 1 h emulator run.
5. Android runs the reports still list as Windows-lane: QA-07 on the emulator (default phase and job-kill/job-resume), QA-03, QA-04 Android rows, QA-10 and its `bmgr`/URI-grant checks, QA-11.

**Owner:**
1. QA-01 manual iPad-simulator steps with screenshots (Files/Photos drop, physical keyboard, hover pill).
2. QA-02 manual tablet checklist M1–M4.
3. Device-lab items (§6 O4), including one iOS and one Android QA-07 device row, which the Auto captions flag needs (§3.3).
4. The "go" for the 1.0.0 release ticket (widened AIS-41) once the internal 1.3 milestone is complete; it then applies the rest of INT-05 with all of 1.1–1.3 in it, followed by the §6 steps. Until then the 1.1 milestone only has to reach release-ready.

**Mac:** nothing blocking. After the Windows re-runs: close QA-01, QA-02 and QA-05 in BUILD_STATE; re-run the QA-09 full nightly matrix and the CI items of §1.1 on the release commit. Optional: FIX-QA-00-4 (harness attach watchdog).

---

## 1. ARCH §23 checklist

Status values: **open** (work or evidence still missing), **ready** (evidence exists, re-check on the release commit), **owner** (only the owner can do it, see §6), **deferred** (needs a device the build run doesn't have).

### 1.1 Tickets, CI and builds (§23 item 1)

| Check | Status | Evidence / next step |
|---|---|---|
| All tickets merged (BUILD_PLAN §5) | open | 2026-10-22: 163 of 166 done. Open: QA-01 (manual iPad steps), QA-02 (Windows re-runs), QA-05 (Android half). INT-05 closed in 1.1, moved to the 1.0.0 release ticket (widened AIS-41). [handoff/BUILD_STATE.md](handoff/BUILD_STATE.md) (Totals, M6). |
| `editor-ci.yml` green on `main` | open | Run on the release commit. Link the run here. |
| Existing player tests green (`flutter test` at the root) | open | Run on the release commit. Known: `settings_account_test` "app version matches pubspec.yaml" needs `app_info.dart` and `pubspec.yaml` to agree; both stay at 1.0.0 / 1 (§3.1). |
| App builds for iOS, Android, macOS, Windows, Linux (desktop with the editor hidden) | open | Release workflows and lanes dry-run (§3.4). Desktop builds get **no** editor dart-defines. |

### 1.2 QA reports (§23 item 2)

| Report | Ticket | Status | Evidence (date) | Link |
|---|---|---|---|---|
| iOS Simulator E2E, 18 scenarios | QA-01 | owner | Automated suite certified (2026-10-21, re-run 4): s01–s18 and the iOS extras pass in one batch on iPhone 16 / iOS 26.5, iPad s12 passes, iOS 18.2 lane 3/3. Left: the manual iPad-simulator steps (Files/Photos drop, physical keyboard, hover pill) with screenshots; iPhone 7/8 smoke deferred (no devices) | [QA-01 re-run 4](qa/QA-01-ios-simulator.md#run-of-2026-10-21-re-run-4-after-fix-ios-12-1-d7-and-the-round-7-dart-fixes) |
| Android Emulator E2E | QA-02 | open | Not certified (2026-10-22, re-run on `d680bd3`): s02 failed once in the API 29 2 GB batch (FIX M-23, fixed on the Mac in `8fb43c2`), and the QA-05 Android half is not green (D8 Dart and W1–W7 fixed; D9, D10 and the D8 engine half on the Windows lane). Everything else passes on `d680bd3` / `88469c0`. Left: Windows re-run (s01–s04 + s18 on API 29 2 GB, s02 on API 29), the QA-05 Android half, owner's tablet M1–M4 | [QA-02 verdict](qa/QA-02-android-emulator.md#what-remains-for-certification) |
| Parity, accuracy, A/V sync | QA-03 | ready | iOS Simulator (2026-10-16): accuracy 12/12, A/V 7/7, parity 4/4, grid cuts 100 %. Android emulator run is Windows lane; device lab and preview A/V offset deferred | [QA-03 results](qa/QA-03-parity.md#results-ios-simulator) |
| Performance budgets | QA-04 | ready | Every row measured and passing on the iOS Simulator and flutter-tester (2026-10-16); simulator numbers don't count as passes. Device lab deferred (no devices); Android rows Windows lane | [QA-04 results](qa/QA-04-performance.md#results-ios-simulator) |
| Conditional tile cache | UX-43 | ready | Closed as not needed (BUILD_STATE done; QA-04 2026-10-16: no number triggers the remedy). Reopens only if the low-tier device run misses the timeline budgets | [QA-04 remedy](qa/QA-04-performance.md#remedy-decision-and-ux-43) |
| Soak and crash recovery | QA-05 | open | iOS green (2026-10-17, after FIX-IOS-D7): seed 5150, 965 ops, 0 failed, death chain passes. Android (2026-10-22, `d680bd3`): death chain 7/7, seeded soak fails on D8, D9, D10. Mac fixes since: D8 Dart (`2c09282`), W1–W7 (`5912db4`), FIX-QA05-D8-2 export sweep (`911110f`). Left: D9, D10, D8 engine half, then the Windows re-run; 1 h runs and device steps deferred | [QA-05 Android half](qa/QA-05-soak.md#a-android-half-windows-lane-2026-10-22-code-d680bd3), [iOS](qa/QA-05-soak.md#2-third-re-run-after-fix-ios-d7-qa-05-rerun) |
| AI accuracy eval | QA-06 | ready | Done (2026-10-15): harness, nightly job and decisions recorded. Real-model accuracy numbers come from the first CI nightly; device benchmarks deferred | [ai-eval.md §7](ai-eval.md#7-results) |
| AI device matrix | QA-07 | open | Ticket done (BUILD_STATE). Report (2026-10-16): D1–D4 fixed, iOS Simulator green (q01–q09, job-kill/resume, s08). The flag is **not yet cleared**: the Android Emulator run and one iOS and one Android device row are missing (§3.3) | [QA-07 §6](qa/QA-07-ai.md#6-release-flag) |
| Accessibility | QA-08 | ready | Automated 234/234 green (2026-10-15); the FIX tickets of §4 were fixed by FIX-A11Y and FIX-UX-22-2 (2026-10-16), and the registers in `a11y_support.dart` are empty. VoiceOver/TalkBack checklist deferred (devices, §6 O4) | [QA-08 §3](qa/QA-08-a11y.md#3-results) |
| Overflow matrix | QA-09 | open | Ticket done; PR subset green (2026-10-15); FIX-UX-22-2 fixed 2026-10-16 and `knownDefects` is empty. The last recorded full-matrix run (2026-10-15) still lists FIX-UX-12-3, FIX-UX-14-3 and FIX-UX-18-1 findings; re-run `overflow_full.sh` on the release commit and record it | [QA-09 results](qa/QA-09-overflow.md#results) |
| Persistence, bookmarks, grants | QA-10 | ready | iOS Simulator 6/6 (2026-10-16). Android emulator (incl. `bmgr`, URI grants) Windows lane; physical devices deferred | [QA-10 results](qa/QA-10-persistence.md#results-ios-simulator-2026-10-16) |
| Export conformance, presets, audio | QA-11 | ready | iOS Simulator green (2026-10-15). Android emulator and Android preview PCM Windows lane; device lab deferred. Finding: CI does not run the QA-11 suites yet | [QA-11 results](qa/QA-11-export-audio.md#results-ios-simulator) |

### 1.3 iOS (§23 item 3)

| Check | Status | Evidence / next step |
|---|---|---|
| Deployment target 15.0 everywhere | ready | Done in INT-01 (ARCH §3.1). Re-check: `grep -n IPHONEOS_DEPLOYMENT_TARGET ios/Runner.xcodeproj/project.pbxproj` shows only 15.0, and `ios/Podfile` has `platform :ios, '15.0'`. |
| Launch, player and editor smoke on iPhone 7 (iOS 15.8) and iPhone 8 (iOS 16.7) | deferred | No iOS 15/16 lab devices (owner default in ARCH D-43). Covered by `-Werror=unguarded-availability-new` and `check_ios_min_os.sh`. If a device turns up: `DV_E2E_LAB_UDIDS=<udid> scripts/ci/editor/e2e_ios.sh lab`. |
| Smoke on iOS 26 | ready | QA-01 re-run 4 (2026-10-21): the full suite passes in one batch on the iPhone 16 / iOS 26.5 simulator ([QA-01](qa/QA-01-ios-simulator.md#run-of-2026-10-21-re-run-4-after-fix-ios-12-1-d7-and-the-round-7-dart-fixes)). Re-check on the release build. |
| `check_ios_min_os.sh` clean on the release app | open (pipeline applied) | **Applied `f8cd585`:** `flutter_ipa` (lanes `build`, `beta`, `release`) runs `check_ios_min_os.sh --min 15.0` on `build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app` after `flutter build ipa`. Dry run 2026-10-22 on an existing local release archive (the v1.2-wip build, flags off, whisper linked): `check_ios_min_os: OK`, 28 binaries, 1414 strongly bound symbols probed. Paste the output of the 1.0.0 release build here. |
| `nm -um` shows no `NEWLAPACK` | open (pipeline applied) | `build_ios_xcframework.sh` checks it after every build. **Applied `f8cd585`:** the iOS lane also runs `nm -um` on the release `Runner.app` binary and every `Frameworks/*.framework` / `*.dylib` and fails on any `NEWLAPACK` reference (`check_ios_min_os.sh` doesn't probe `$NEWLAPACK` names). Dry run 2026-10-22 on the same local archive: no NEWLAPACK in 28 binaries; a fixture referencing `_dgemm$NEWLAPACK` fails the check. Paste the lane output of the release build here. |
| Privacy manifests valid | open | ARCH §20.4. The Xcode privacy report from the release archive (Organizer › Generate Privacy Report) lists the engine pod (C617.1, E174.1, 35F9.1) and the whisper pod (E174.1); Runner has `NSPrivacyTracking = false` and no collected data types. |
| Info.plist strings present | ready | INT-03: `NSMicrophoneUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `BGTaskSchedulerPermittedIdentifiers`, and no `NSPhotoLibraryUsageDescription`. |
| App Store Connect validation clean | owner | Upload through `fastlane ios beta` (TestFlight), then read the processing email. |
| IPA growth ≤ 6 MB for whisper plus the engine | open | Compare the App Store Connect "App Store file sizes" report (or the thinned IPA sizes) of the release build against a player-only build of the same commit (no editor defines). Nothing has been released, so there is no released build to compare with. The editor fonts (≈ 5.6 MB, ARCH §17.8) and the 12 filter looks are content and are listed separately. |
| GPU continued-processing entitlement status | owner | Record whether Apple granted `com.apple.developer.background-tasks.continued-processing.gpu` (ARCH §20.4). Without it, exports pause in the background and resume on return. |

### 1.4 Android (§23 item 4)

| Check | Status | Evidence / next step |
|---|---|---|
| AAB holds `libdanaview_whisper*.so` for arm64-v8a and x86_64 only, 16 KB aligned, only `dv_*` exported, ≤ 3 MB each | open (pipeline applied) | **Applied `f8cd585`:** `check_native_libs.sh` runs in the Android lane on every AAB `flutter_aab` returns (built, `ENV["AAB"]` or an existing `build/` one) and in `android-release.yml` on the AAB and the universal and split APKs. The whisper libraries are linked whatever the flags say, so flags-off builds must pass too. Dry run 2026-10-22 on the Mac: the script runs (NDK 28.2 `llvm-readelf`); the only local AAB (4 Oct, before the whisper plugin) fails "missing whisper libraries", as it should. Paste the output of the release build here. |
| FGS declaration submitted | owner | Text in §5.4. |
| Play pre-launch report clean | owner | Internal testing track, then Play Console › Pre-launch report. |
| `POST_NOTIFICATIONS` / `RECORD_AUDIO` flows verified | deferred | Emulator side done: AND-14's real notification dialog passes on API 35, and every QA-02 export asks for `grantNotifications` and starts; s13 records a voiceover (low level accepted as an emulator limitation, 2026-10-22) ([QA-02](qa/QA-02-android-emulator.md#and-14-the-notification-permission-request-always-returns)). One device check left. |
| Backup rules verified | open | QA-10 Android is still Windows lane (2026-10-16): run `integration_test/editor_store/tool/android_backup_check.sh -d emulator-5554` and confirm the editor and speech trees are not in the backup ([QA-10 deferred](qa/QA-10-persistence.md#deferred)). Statically both rule files exclude them. |

### 1.5 Privacy, store listing, sign-offs (§23 item 5)

| Check | Status | Evidence / next step |
|---|---|---|
| Privacy policy and terms updated in the app | ready | UX-42 (`packages/danaview_features/lib/src/more/legal_texts.dart`); `test/privacy_policy_host_test.dart` (INT-04). `legalEffectiveDate` still has to move to the release date (§3.1). Owner decision 2026-10-16 (§8, defect 1): the "Open-source licences" page returns under Settings › About and the "Auto captions" terms link to it. **FIX-LICENSES landed** (2026-10-16): the page, its `/settings/licenses` route and the terms paragraph are in the app; the hosted copy must carry the same paragraph (§5.1). |
| Published at every store privacy URL with a diff or screenshot | owner | §5.1. iOS/macOS: `https://vecvel.com/ios/danaview/privacy`. Play: the listing's privacy URL in Play Console. |
| Owner sign-offs of D-43 recorded | ready | ARCH D-43: owner defaults 2026-10-08 for (a)–(d) and (f), owner decision 2026-10-11 for (e). The owner may still revise them before go-live. |
| Store descriptions, release notes, screenshots | owner | Texts drafted in §4 (not yet in `ios/fastlane/metadata/` or `android/fastlane/metadata/`). Owner decision 2026-10-16: the current fastlane store descriptions (never released) are replaced with the new casual texts at launch time, not now (§8, defect 3). Screenshots are an owner step after v1.3 (§6). |
| Privacy labels unchanged | ready | App Privacy: "Data Not Collected". Data safety: no data collected, no data shared. Reasons in §5.2 and §5.3. |

### 1.6 Flags, version, rollback (§23 items 6–8)

| Check | Status | Evidence / next step |
|---|---|---|
| Release builds pass `--dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true` on iOS and Android | open | Diff in §3.2. Not applied (it belongs to the 1.0.0 release ticket, widened AIS-41). `DANAVIEW_AUTO_CAPTIONS` waits for the QA-07 conditions still open on 2026-10-22: Android Emulator run and one iOS and one Android device row (§3.3). |
| Desktop builds keep the editor hidden | ready | Desktop builds get no defines, and `EditorAvailability.platform` hides the editor on macOS/Windows/Linux regardless of the flags (ARCH §3.3, D-17). Desktop absence tests: INT-02, INT-04. |
| Version `1.0.0+1` | ready | Owner decision 2026-10-22: the first store release stays 1.0.0, build 1, so `pubspec.yaml` (`1.0.0+1`) and `app_info.dart` (`1.0.0` / `1`) need no change (§3.1). Nothing has been uploaded to either store, so build 1 is free (owner, 2026-10-22). |
| Project schema 1, `minReader` 1, RenderPlan `v` 1, migration fixtures committed | ready | CORE-25 (schema and migration fixtures), CORE-29 (plan `v` 1). Re-check on the release commit: `cd packages/danaview_editor_core && dart test test/store test/plan`. |
| Rollback plan | ready | §7. |

### 1.7 [VERIFY] closures owned by INT-05 (ARCH §24.2)

| Item | Answer to record in ARCH §24.2 at release |
|---|---|
| V-A14 App Review stance on post-install model downloads | The model is data (weights), not code: no executable code is downloaded, the app's behaviour doesn't change, and the download is optional and asked for each time (Guideline 2.5.2). The App Review note in §5.5 says so. Close it with the date of the first approved submission that included the download. |

---

## 2. Release order (when the owner says go)

The app ships once, after the internal 1.3 dev milestone completes (owner, 2026-10-22). Step 1 is what the 1.1 milestone still needs to be release-ready; steps 2–5 run at go time for the combined 1.1–1.3 build, as version 1.0.0 (1).

1. Finish the open QA items (§1.2, status 2026-10-22; FIX-LICENSES, §8 defect 1, has landed):
   - QA-02 (Windows): after merging `editor-wip`, s01–s04 + s18 in one batch on Pixel_API_29_2GB and s02 on API 29; then QA-02 is certified except the owner's tablet M1–M4.
   - QA-05 Android half (Windows): D9, D10 and the D8 engine half are fixed (`b7c4a8c`); run the seeded soak (seed 5150, 15 min) and the death chain with the unmodified `soak_host.py`, then the 1 h run.
   - QA-01 (owner): the manual iPad-simulator steps with screenshots.
   - QA-07: the Android Emulator run (default phase, job-kill/job-resume) and one iOS and one Android device row, before the Auto captions flag ships (§3.3).
   - QA-09 (Mac): a green full nightly matrix on the release commit.
   - Device-lab items (§6 O4) as devices allow.
2. Apply §3.1 (the legal effective date; the version stays `1.0.0+1`) and the flag part of §3.2 (its pipeline checks are already applied, `f8cd585`) in one release commit. Apply §3.3 (the Auto captions flag) only once QA-07 says yes. If it doesn't, ship with Auto captions off and leave the captions text out of the store copy (§4.6).
3. Copy the §4 texts into the fastlane metadata files listed in §4.5, replacing the current, never released store descriptions (owner decision 2026-10-16: at launch time, not before).
4. Dry-run every release workflow and lane (§3.4). Upload to TestFlight and to the Play internal track.
5. Owner steps in §6, then tag `v1.0.0` on `main`.

---

## 3. Prepared changes (not applied, except the §3.2 pipeline checks)

### 3.1 Version 1.0.0+1 (no change)

Owner decision 2026-10-22: nothing has been released to production yet, and 1.1, 1.2 and 1.3 are dev milestones. The first store release keeps **version 1.0.0, build 1**. So there is no version diff:

- `pubspec.yaml` stays `version: 1.0.0+1`.
- `packages/danaview_features/lib/src/more/app_info.dart` stays `danaviewAppVersion = '1.0.0'` and `danaviewBuildNumber = 1`. The About screen and the root test `settings_account_test` read it, and the two files agree today.

The legal pages' effective date still becomes the release date (its comment already names INT-05):

```diff
--- a/packages/danaview_features/lib/src/more/legal_texts.dart
+++ b/packages/danaview_features/lib/src/more/legal_texts.dart
-const String legalEffectiveDate = '11 October 2026';
+const String legalEffectiveDate = '<release day> <month> <year>';
```

Notes:
- **Build number.** Owner confirmed 2026-10-22: nothing has ever been uploaded to App Store Connect or Play (no TestFlight build, no test track). The first release is exactly **1.0.0 (1)** on both stores, with no fallback number. So run the iOS `release`/`build` lanes with `BUILD_NUMBER=1` (their default), and check that the Android lane uses version code 1: the upload lanes (`internal`, `beta`, `production`) take the highest Play version code plus one, which is 1 on an empty Play app, while `android build` without `BUILD_NUMBER` uses a `yymmddHH` stamp, so pass `BUILD_NUMBER=1` there. The Android release workflow uses `pubspec.yaml`'s `+1`. The iOS `beta` lane takes the next TestFlight number, which is 1 on an empty record. The macOS `mac_release` lane defaults to build 2, so pass `BUILD_NUMBER=1` if a Mac build ships.
- Projects are forward-compatible through `minReader`, so the release needs no data migration.

### 3.2 Release builds: flags, whisper framework and native checks

Both editor flags are compile-time `--dart-define`s that default to false (ARCH D-31). The code never flips them. Only the iOS and Android release builds pass them.

**Applied 2026-10-22 (`f8cd585`), pipeline part only:** the whisper xcframework build, `check_ios_min_os.sh` and an `nm -um` NEWLAPACK check in the iOS lane (`flutter_ipa`), and `check_native_libs.sh` in the Android lane (`flutter_aab`, also on pre-built AABs) and in `android-release.yml` (the step below). The `--dart-define` lines (`EDITOR_DEFINES`, the workflow `env:` block and the `$EDITOR_DEFINES` arguments) are **not** applied; they belong to the 1.0.0 release ticket (widened AIS-41). The checks don't depend on the flags: `danaview_whisper` is a plain dependency in `pubspec.yaml`, so its pod (iOS, which needs the xcframework) and its CMake libraries (Android, arm64-v8a and x86_64) are linked into every build, and the defines only gate Dart code. The applied iOS lane runs the min-OS check with `bash` and adds the NEWLAPACK scan, which the diff below doesn't show.

**iOS lane** (`ios/fastlane/Fastfile`): build the whisper xcframework first, pass both flags, and check the 15.0 floor on the built app. The macOS build (`macos_pkg`) gets nothing.

```diff
--- a/ios/fastlane/Fastfile
+++ b/ios/fastlane/Fastfile
 ROOT = File.expand_path("../..", __dir__)
 IPA_DIR = File.join(ROOT, "build/ios/ipa")
+# Release builds turn the video editor and Auto captions on (ARCH D-31, §23 item 6).
+# Desktop builds never pass these; the editor stays hidden there (D-17).
+EDITOR_DEFINES = [
+  "--dart-define=DANAVIEW_EDITOR=true",
+  "--dart-define=DANAVIEW_AUTO_CAPTIONS=true",
+].freeze
@@
   def flutter_ipa(build_number)
     Dir.chdir(ROOT) do
+      # WhisperCore.xcframework is git-ignored; --if-missing is a no-op when its stamp matches (AI-05).
+      sh("packages/danaview_whisper/tool/build_ios_xcframework.sh", "--if-missing")
       sh("flutter", "build", "ipa", "--release",
          "--export-options-plist=ios/ExportOptions.plist",
-         "--build-number=#{build_number}")
+         "--build-number=#{build_number}",
+         *EDITOR_DEFINES)
+      # D-41: nothing in the app may need more than iOS 15.0 at load time.
+      sh("scripts/ci/editor/check_ios_min_os.sh", "--min", "15.0",
+         "build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app")
     end
```

`brew install cmake` (≥ 3.28) is needed on the release Mac for the xcframework build (ARCH §22).

**Android lane** (`android/fastlane/Fastfile`): pass both flags and check the native libraries in the AAB.

```diff
--- a/android/fastlane/Fastfile
+++ b/android/fastlane/Fastfile
     Dir.chdir(ROOT) do
-      sh("flutter", "build", "appbundle", "--release", "--build-number=#{version_code}")
+      sh("flutter", "build", "appbundle", "--release", "--build-number=#{version_code}",
+         "--dart-define=DANAVIEW_EDITOR=true", "--dart-define=DANAVIEW_AUTO_CAPTIONS=true")
+      sh("bash", "scripts/ci/editor/check_native_libs.sh", AAB)
     end
     AAB
```

A pre-built AAB passed through `ENV["AAB"]`, or one already in `build/`, skips this build. Check it by hand with `check_native_libs.sh` before uploading.

**Android release workflow** (`.github/workflows/android-release.yml`): the same flags on all three builds, then the native-library check on every archive. The workflow needs an NDK for `llvm-readelf`. The Flutter Android toolchain installs NDK 28.2.13676358, which the script finds by itself.

```diff
--- a/.github/workflows/android-release.yml
+++ b/.github/workflows/android-release.yml
+    env:
+      # Release builds turn the video editor and Auto captions on (ARCH D-31). Desktop workflows don't.
+      EDITOR_DEFINES: --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true
@@
       - name: Build Signed App Bundle (AAB)
         if: github.event_name == 'push' || inputs.build_type == 'both' || inputs.build_type == 'bundle'
-        run: flutter build appbundle --release
+        run: flutter build appbundle --release $EDITOR_DEFINES
 
       - name: Build Signed Universal APK
         if: github.event_name == 'push' || inputs.build_type == 'both' || inputs.build_type == 'apk'
-        run: flutter build apk --release
+        run: flutter build apk --release $EDITOR_DEFINES
 
       - name: Build Signed Split-ABI APKs
         if: github.event_name == 'push' || inputs.build_type == 'both' || inputs.build_type == 'apk'
-        run: flutter build apk --release --split-per-abi
+        run: flutter build apk --release --split-per-abi $EDITOR_DEFINES
+
+      - name: Check native libraries (ABIs, 16 KB pages, exports, size)
+        run: |
+          check() { if [ -f "$2" ]; then bash scripts/ci/editor/check_native_libs.sh $1 "$2"; fi; }
+          OUT=build/app/outputs
+          check "" $OUT/bundle/release/app-release.aab
+          check "" $OUT/flutter-apk/app-release.apk
+          check "--abis arm64-v8a" $OUT/flutter-apk/app-arm64-v8a-release.apk
+          check "--abis x86_64" $OUT/flutter-apk/app-x86_64-release.apk
+          # armeabi-v7a carries no whisper library at all (D-43(b)); the check fails if one appears.
+          check "--abis=" $OUT/flutter-apk/app-armeabi-v7a-release.apk
```

The `env:` block goes on the build job (the job named "Build Signed Android Release"). The empty `--abis=` form for the armeabi-v7a APK was tried against AI-04's script on 2026-10-16 with a test archive (it passes when no whisper library is present). The step's `check` helper skips archives the chosen `build_type` didn't build.

**Desktop workflows** (`linux-release.yml`, `windows-release.yml`) and the macOS lanes (`mac_release`, `macos_pkg`): **no change.** They pass no editor defines, and the editor is hidden on desktop anyway.

### 3.3 The Auto captions flag waits for QA-07

QA-07 is done as a ticket (BUILD_STATE), but its report still has conditions (2026-10-16, [qa/QA-07-ai.md §6](qa/QA-07-ai.md#6-release-flag)): D1 and D2 are fixed and the iOS Simulator is green, so `DANAVIEW_AUTO_CAPTIONS` may ship on only after:

1. the default phase is green on the Android Emulator (Windows lane);
2. the job-kill/job-resume phases pass on the Android Emulator (the §16.4 #4 Android kill case);
3. at least one iOS and one Android device row of the device matrix is green, including Balanced within budget and one real download with resume.

PRODUCTION_READINESS §1 says the flag can ship; the QA-07 report does not say so yet, and the report decides. If the release has to go out before that, drop `--dart-define=DANAVIEW_AUTO_CAPTIONS=true` from the three places in §3.2 and use the "without Auto captions" store texts (§4.6). The editor flag doesn't depend on it.

### 3.4 Dry runs (BUILD_PLAN INT-05 acceptance)

| What | How | Result |
|---|---|---|
| iOS lane | `cd ios && BUILD_NUMBER=1 fastlane ios build` (or the next free build number, §3.1): builds the xcframework (`--if-missing`) and the IPA with the flags, runs the min-OS and NEWLAPACK checks, uploads nothing | open. Static checks 2026-10-22 (`f8cd585`): `ruby -c` OK, `fastlane lanes` lists all 9 iOS lanes, both checks pass on an existing local release archive; no build run (8 GB Mac shared with other builders). The release Mac needs `cmake` ≥ 3.28 on PATH (not installed on the dev Mac). |
| Android lane | `cd android && BUILD_NUMBER=1 fastlane android build` (without `BUILD_NUMBER` the lane stamps `yymmddHH`); runs `check_native_libs.sh` on the AAB | open. Static checks 2026-10-22: `ruby -c` OK, `fastlane lanes` lists all 8 Android lanes. A stale `build/app/outputs/bundle/release/app-release.aab` now fails the check instead of being reused silently: delete it or pass a fresh `AAB`. |
| Android workflow | `workflow_dispatch` with `build_type: both` on a branch; don't publish the GitHub release | open. Static checks 2026-10-22: the YAML parses, the new step sits after the three builds and before "Prepare Release Artifacts", shellcheck on its script is clean apart from the intentional unquoted `$1`. |
| Linux and Windows workflows | `workflow_dispatch` on a branch; confirm no editor entry points (Home has no editor button) | open |
| macOS | `fastlane ios mac_release` without upload, or `flutter build macos --release`; the editor stays hidden | open |
| Flags reach the app | On a TestFlight or internal-track build: Home shows the editor button left of the gear, and Auto captions shows in the Captions tool | open |

---

## 4. Store texts (drafts)

Tone: grounded and casual, plain words, no spec terms. Every line has to be true for the release build (version 1.0.0, editor milestone 1.1). What it has: the player (videos, streams and links, subtitles, audio tracks, equalizer, playlists, folders, gestures, network tools), and on iPhone, iPad and Android the new video editor with Auto captions. Photos come in only as pictures you add to a video project. Photo browsing and photo editing arrive in 1.2, and there is no document viewer, so the copy doesn't promise either.

Limits checked: App Store subtitle ≤ 30, promotional text ≤ 170, keywords ≤ 100, description and release notes ≤ 4,000; Play title ≤ 30, short description ≤ 80, full description ≤ 4,000, release notes ≤ 500 characters.

### 4.1 App Store (iPhone and iPad)

**Subtitle** (`subtitle.txt`)

```text
Watch, edit and caption videos
```

**Promotional text** (`promotional_text.txt`)

```text
New: a video editor built right in. Trim, add music, text and captions, then share. Everything stays on your iPhone.
```

**Keywords** (`keywords.txt`)

```text
video editor,video player,captions,subtitles,trim,cut,music,voiceover,mkv,mp4,offline,private
```

**Description** (`description.txt`)

```text
Danaview plays your videos, and now it edits them too. Everything happens on your iPhone or iPad.

WATCH
• Play almost any video file, with subtitles and multiple audio tracks.
• Open videos from the Files app, your own folders, or a link.
• Pick up where you left off, build playlists, and shape the sound with the equalizer.
• Swipe for brightness, volume and seeking. Lock the screen so nothing gets in the way.

EDIT
• Tap Edit while you watch and the editor opens at that exact moment.
• Trim, split and move clips on a timeline with layers for video, text, captions and sound. Undo anything.
• Add music, record a voiceover, drop in photos, or put a video on top of another.
• Add text with fonts, colors and simple animations.
• Speed clips up or slow them down, play them backwards, freeze a frame, add transitions, filters and color touches.
• Export in sizes made for YouTube, Instagram and TikTok, then save to Photos, save to Files, or share.

CAPTIONS
• Type captions yourself, or let Danaview write them from what's said in your video.
• Auto captions are made on your iPhone, even offline. The first time, they need a one-time download.
• Bring in caption files you already have, or save yours to use elsewhere.

YOURS, AND PRIVATE
• No account, no ads, no tracking.
• Your videos are never uploaded. The only download is the optional one for Auto captions, and only when you say yes.
• Editing never changes your original videos, photos or music.
```

**Release notes** (`release_notes.txt`)

```text
New: a video editor, built right in.
• Open it from the new button on Home, or tap Edit while you watch.
• Trim and arrange clips, add music, voiceovers, text and transitions, then save or share.
• Auto captions: Danaview listens to your video and writes the captions on your iPhone. The first time needs a one-time download. Nothing is uploaded.
• Your originals are never changed.
Danaview needs iOS 15 or later.
```

### 4.2 Google Play

**Title** (`title.txt`): unchanged, `Danaview`.

**Short description** (`short_description.txt`)

```text
Watch, edit and caption your videos. Private, on your phone.
```

**Full description** (`full_description.txt`)

```text
Danaview plays your videos, and now it edits them too. Everything happens on your phone or tablet.

WATCH
• Play almost any video file, with subtitles and multiple audio tracks.
• Open videos from your folders, your file manager, or a link.
• Pick up where you left off, build playlists, and shape the sound with the equalizer.
• Swipe for brightness, volume and seeking. Lock the screen so nothing gets in the way.

EDIT
• Tap Edit while you watch and the editor opens at that exact moment.
• Trim, split and move clips on a timeline with layers for video, text, captions and sound. Undo anything.
• Add music, record a voiceover, drop in photos, or put a video on top of another.
• Add text with fonts, colors and simple animations.
• Speed clips up or slow them down, play them backwards, freeze a frame, add transitions, filters and color touches.
• Export in sizes made for YouTube, Instagram and TikTok, then save to your gallery, save to a folder, or share.
• Exports keep going in the background, with a notification you can cancel from.

CAPTIONS
• Type captions yourself, or let Danaview write them from what's said in your video.
• Auto captions are made on your phone, even offline. The first time, they need a one-time download.
• Bring in caption files you already have, or save yours to use elsewhere.

YOURS, AND PRIVATE
• No account, no ads, no tracking.
• Your videos are never uploaded. The only download is the optional one for Auto captions, and only when you say yes.
• Editing never changes your original videos, photos or music.

The video editor needs Android 10 or later. On older phones, Danaview still plays everything as before.
```

**Release notes** (`changelogs/1.txt`, named after the version code, or the code actually used per §3.1; also replace `changelogs/default.txt`)

```text
New: a video editor, built right in.
• Open it from the new button on Home, or tap Edit while you watch.
• Trim and arrange clips, add music, voiceovers, text and transitions, then save or share.
• Auto captions are written on your phone. The first time needs a one-time download. Nothing is uploaded.
• Your originals are never changed.
```

### 4.3 Mac App Store (if a Mac build ships with this release)

The Mac build has no editor in the 1.1 milestone (it comes in 1.3), so its description stays as it is. Release notes (`metadata_mac/en-US/release_notes.txt`):

```text
Small fixes and an updated privacy policy. The new video editor is on iPhone, iPad and Android for now.
```

### 4.4 Words to keep out

Owner rule for store copy: no spec terms. Don't write 4K, HDR, hardware, codec names (HEVC, H.264, AV1), bitrate, AI, machine learning, model, neural, whisper, GPU or FFmpeg. "One-time download" stands in for "speech model download". The privacy policy (§5.1) is the exception: it keeps its exact wording ("speech recognition model", host names and sizes), because there accuracy matters more than tone.

The current store copy in the repo, never released (`description.txt`, `full_description.txt`, `promotional_text.txt`, `subtitle.txt`, `short_description.txt`) leans on those terms ("ultra-high performance HDR", "hardware-accelerated", codec lists, "zero battery drain"). The §4.1–§4.2 texts replace it completely. Don't merge the two.

### 4.5 Where the texts go (INT-05, at release)

| Text | File |
|---|---|
| App Store subtitle, promo, keywords, description, release notes | `ios/fastlane/metadata/en-US/{subtitle,promotional_text,keywords,description,release_notes}.txt` |
| App Review notes | `ios/fastlane/metadata/review_information/notes.txt` (§5.5) |
| Mac release notes | `ios/fastlane/metadata_mac/en-US/release_notes.txt` |
| Play short and full description | `android/fastlane/metadata/android/en-US/{short_description,full_description}.txt` |
| Play release notes | `android/fastlane/metadata/android/en-US/changelogs/1.txt` (or the version code used, §3.1; + `default.txt`) |

Upload with the existing lanes: `fastlane ios metadata` and `fastlane android metadata`, or with the binary. Both metadata lanes also upload screenshots, and `fastlane ios metadata` refuses to run with an empty screenshot folder, so they run only after the owner's screenshots (§6).

### 4.6 If Auto captions stay off

If the release ships without `DANAVIEW_AUTO_CAPTIONS` (§3.3):
- App Store and Play descriptions: drop the second bullet of CAPTIONS, and change the first to "Type captions yourself, or bring in caption files you already have." Delete the third bullet. In YOURS, AND PRIVATE, use "Your videos are never uploaded." alone.
- Promotional text: "New: a video editor built right in. Trim, add music, text and captions, then share. Everything stays on your iPhone." still holds.
- Release notes: drop the Auto captions bullet.
- Keep the privacy policy as it is. It already says "only if you choose to create captions automatically".

---

## 5. Privacy and review texts

### 5.1 Hosted privacy policy and terms

The in-app texts are the source (`packages/danaview_features/lib/src/more/legal_texts.dart`, UX-42). The hosted pages must say the same, word for word, with the release date as the effective date. Compared to the pages hosted today, the changes are (ARCH §20.3):

| Section | Change |
|---|---|
| Summary | Replaced: "Danaview keeps everything on your device. There are no accounts, no analytics, no ads and no tracking, and nothing you watch, edit or type is sent to us. The only extra download is the optional speech model for Auto captions, and only after you agree." |
| What Danaview stores on your device | Three new bullets: video editing projects; picked and dropped media copied into Danaview's storage; the Auto captions speech model and transcribed text. |
| When Danaview uses the internet | New "Speech model for Auto captions" entry (Hugging Face, huggingface.co and hf.co, 31 to 181 MB, only the file name is sent). New closing paragraph about on-device processing. |
| Files and permissions | Paragraph replaced. New bullets: Photo library, Microphone, Notifications (Android). |
| Your choices | Two new bullets: deleting projects, deleting the speech model and clearing editor caches. |
| Terms: Your content | Adds the rights to footage, music, images and fonts. |
| Terms: new sections | "Editing and exports", "Auto captions". |
| Terms: Trademarks, No warranty | YouTube, Instagram, TikTok added; export size estimates and captions are approximate. |

| Terms: Auto captions, licences | New closing paragraph: Danaview uses open-source software and fonts and, on iPhone, iPad and Android, open-source speech recognition models for Auto captions, each under its own licence, which can be read in **Settings › About › Open-source licences** (FIX-LICENSES). |

Licences in the hosted terms: the hosted copy keeps that paragraph word for word and points to the same place, **Settings › About › Open-source licences** in the app (`openSourceLicencesLocation` in `legal_texts.dart`). The page itself is not hosted; it lists the notices bundled with the build (libmpv/FFmpeg, whisper.cpp/ggml, Figtree and the content fonts under OFL-1.1, AndroidX Media3 and the Flutter packages).

Steps (owner, §6): build the HTML from `privacyPolicyText` and `termsOfUseText`, publish it at `https://vecvel.com/ios/danaview/privacy` (iOS and macOS, `privacy_url.txt`) and at the Play listing's privacy URL, then attach a diff of the old and new page, or before and after screenshots, here.

### 5.2 App Store App Privacy label

Unchanged: **Data Not Collected.** Why it still holds:
- Projects, recordings, transcripts, the speech model and the profile stay on the device. Nothing is sent to vecvel.
- The speech-model download goes straight to Hugging Face and sends only the file name. No identifiers, no user content, and nothing for vecvel or a partner to keep.
- No analytics, crash reporting or ad SDKs were added. The new pods' privacy manifests declare required-reason APIs only (§1.3).

Tracking: **No.**

### 5.3 Google Play Data safety

Unchanged: **No data collected. No data shared.** Same reasons as §5.2. Keep the answers "Is all of the user data collected by your app encrypted in transit?" not applicable (nothing collected) and "Do you provide a way for users to request that their data is deleted?" not applicable. In the optional explanation field, if used:

```text
Danaview doesn't collect or share user data. Videos, edits, recordings and captions stay on the device. The optional Auto captions download fetches a file from Hugging Face and sends only the file name.
```

### 5.4 Play foreground service declaration

Play Console › App content › Foreground service permissions. Permissions: `FOREGROUND_SERVICE_DATA_SYNC` (Android 10–14) and `FOREGROUND_SERVICE_MEDIA_PROCESSING` (Android 15+). Attach a short screen recording: start an export, leave the app, show the notification with progress and Cancel, return to the finished video.

```text
Danaview's video editor uses a foreground service to finish work the user started and is watching: exporting an edited video and creating captions from a video's audio. The service runs only while that job runs, shows a notification with progress and a Cancel button, and stops when the job ends. On Android 15 and later it uses the mediaProcessing type. On Android 10 to 14, where mediaProcessing doesn't exist, it uses dataSync, because the export writes the finished video into the user's gallery or chosen folder. Without the service, an export of several minutes would stop as soon as the user switches apps.
```

If Play rejects `dataSync` for 10–14, the fallback is already built: no background service on those versions (`backgroundKind = none`), and the export pauses when the user leaves (ARCH R10).

### 5.5 App Review notes (iOS)

Replace `ios/fastlane/metadata/review_information/notes.txt` with:

```text
Danaview is a local and network media player with a video editor. No account or login is needed.

Player: tap "Open link" on Home and enter a sample video stream, or pick any local video.

Video editor: tap the editor button to the left of the settings gear on Home, then New project and pick a video. You can also open a video in the player and tap Edit.

Auto captions: in the editor, open Captions and choose Auto captions. The first time, the app asks before downloading a speech recognition model (about 60 MB for the default quality) from huggingface.co. The model is data (the weights of an open-source speech recognizer, MIT licensed), not code: it contains no executable code and doesn't change the app's features or behavior. The download is optional, asked for each time, and checked against a fixed size and SHA-256 before use. Transcription runs entirely on the device; no audio, video or text leaves it.

Microphone: used only while recording a voiceover in the editor. Photos: the app only adds exported videos (add-only access) and receives only the items the user picks.
```

---

## 6. Owner-only steps

These need the owner's accounts, devices or decisions. Builders don't do them. Timing: the owner plans to go live only after v1.3, so the store steps (records, screenshots, submission) happen then; signing and device checks can happen earlier on internal builds.

| # | Step | Notes |
|---|---|---|
| O1 | Store records for `com.vecvel.danaview` | App Store Connect app record (iOS and macOS) and Play Console app exist and match the bundle id / applicationId `com.vecvel.danaview`. Confirm the Play listing's privacy policy URL. |
| O2 | Signing | iOS distribution certificate and App Store profile for `com.vecvel.danaview` (and the BGTask identifiers); `android/key.properties` and the upload keystore on the release machine and in the workflow secrets. `ios/fastlane/.env` and `android/fastlane/.env` filled (see the `.env.example` files). |
| O3 | GPU background entitlement | Request `com.apple.developer.background-tasks.continued-processing.gpu` from Apple; record granted or not in §1.3. |
| O4 | Device-lab checks | VoiceOver and TalkBack checklist (QA-08 §5); QA-07 device matrix; QA-10 physical iPhone and Android items; QA-11 device rows; performance (QA-04) on the lab phones; iPhone 7 / iPhone 8 smoke if such devices become available (otherwise the D-43 owner default stands). |
| O5 | Publish the privacy policy and terms | §5.1, with diff or screenshots attached in §1.5. |
| O6 | App Privacy and Data safety | Re-confirm §5.2 and §5.3 in the consoles (they should already read "no data"). |
| O7 | Play FGS declaration | §5.4 text plus the demo video. |
| O8 | Screenshots | After v1.3 (the UI changes in 1.2 and 1.3 would date them). Regenerate with the existing lanes (`fastlane ios screenshots`, `fastlane ios mac_screenshots`, and `fastlane android images` for the Play images), then run the metadata lanes. Show Home with the editor button, the editor timeline, the export sheet and captions. |
| O9 | Review the store texts | §4. Owner tone and accuracy. Rewrite for 1.3 at go-live. |
| O10 | D-43 sign-offs | The 2026-10-08 owner defaults stand unless revised; write any revision into ARCH D-43 before release. |
| O11 | Submit | TestFlight build to App Review with the §5.5 notes; Play internal → closed → production. Tag `v1.0.0` on `main` after both are approved. |

---

## 7. Rollback

- **Turn the editor off:** a hotfix build without the two `--dart-define`s (remove `EDITOR_DEFINES` from §3.2's three places) hides the Home button, the player's Edit and the editor routes. The player is unaffected. Projects stay on the device untouched and come back when the editor returns.
- **Turn only Auto captions off:** drop `--dart-define=DANAVIEW_AUTO_CAPTIONS=true`. Captions made earlier stay in projects as normal caption tracks. The speech model stays until the user deletes it in Settings.
- **Projects are forward-compatible:** schema 1 with `minReader` 1. A later version that writes a newer schema raises `minReader` only when older apps can't read it; older apps then open such projects read-only (QA-10 "D-12 newer schema read-only").
- **Store side:** App Store phased release can be paused; Play staged rollout can be halted. Don't remove 1.0.0 from the stores without a replacement build. This is the first store release (owner decision 2026-10-22), so there is no older store version to fall back to.

---

## 8. Defects and follow-ups found while preparing

1. **Third-party licences in the "Auto captions" terms** (`legal_texts.dart`, UX-42). Owner decision 2026-10-16: the owner reverses the earlier removal of the licences route (option (b) of the earlier list). A simple, plain **"Open-source licences"** page returns under **Settings › About**, as ARCH §20.3 / §20.4 and UX-42 describe. It lists the notices for libmpv/FFmpeg (LGPL), whisper.cpp/ggml (MIT), the OFL fonts (Figtree and the content fonts, OFL-1.1), AndroidX Media3 (Apache-2.0) and the other bundled packages. The "Auto captions" terms link to it, in the app and in the hosted copy (§5.1).

   **Landed: ticket FIX-LICENSES** (2026-10-16; FIX-TESTS-R6 exported `registerContentFontLicenses` from the editor barrel). Scope: the licences page and its `/settings/licenses` route under Settings › About; the notice list above, plain text in the owner UI rules; the link from the "Auto captions" terms in `legal_texts.dart`; `test/editor_wiring_test.dart` changed so `/settings/licenses` opens the licences page instead of landing on Home; a test that every bundled package with a licence notice appears on the page. The in-app terms now point to the page; the hosted copy gets the same paragraph when it is published (§5.1).
2. **Version sync**: `app_info.dart` (`danaview_features`) and `pubspec.yaml` must agree, or the root version test fails. With the owner decision of 2026-10-22 (first release 1.0.0 (1), §3.1) both already say 1.0.0 / 1, so nothing changes.
3. **Store copy**: the current (never released) texts in `ios/fastlane/metadata/` and `android/fastlane/metadata/` use the spec terms the owner doesn't want (§4.4). Owner decision 2026-10-16: they are replaced with the new casual texts (§4) at launch time, not now, so that nothing uploads early. Leave the fastlane metadata files unchanged until release step 3 (§2).
4. **QA reports**: every report is now in `qa/` (QA-01 to QA-05, QA-07 to QA-11) plus `ai-eval.md` for QA-06; their state is in §1.2 (2026-10-22).
