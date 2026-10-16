# Danaview 1.1.0 release checklist

> **Owner:** INT-05 (BUILD_PLAN INT-05; ARCH §23 is the source of every item).
> **State: prepared, nothing switched on (INT-05-PREP, 2026-10-16).** This file holds the filled ARCH §23 checklist, the release changes written out as diffs, the store and privacy texts, and the steps only the owner can do. None of the diffs below are applied. `pubspec.yaml` is still `1.0.0+1`, both flags still default to false, and the release workflows, Fastfiles and fastlane metadata are unchanged.
> **Go-live:** the owner plans to go live only after v1.3. Until then this file is the plan for the 1.1.0 build. The store texts in §4 describe what 1.1.0 really has. When the public release moves to 1.3, rewrite them for the 1.3 feature set (photos on Home and photo editing arrive in 1.2; the desktop editor and the camera arrive in 1.3).
> **Related:** [user guide](user-guide.md) · [QA index](qa/README.md) · [ARCHITECTURE §23](ARCHITECTURE.md) · [BUILD_PLAN INT-05](BUILD_PLAN.md)

---

## 1. ARCH §23 checklist

Status values: **open** (work or evidence still missing), **ready** (evidence exists, re-check on the release commit), **owner** (only the owner can do it, see §6), **deferred** (needs a device the build run doesn't have).

### 1.1 Tickets, CI and builds (§23 item 1)

| Check | Status | Evidence / next step |
|---|---|---|
| All tickets merged (BUILD_PLAN §5) | open | [handoff/BUILD_STATE.md](handoff/BUILD_STATE.md): QA-00/01/03/04/05/07/08/09/10/11 and UX-43 in progress; QA-02 (Android lane) not started. |
| `editor-ci.yml` green on `main` | open | Run on the release commit. Link the run here. |
| Existing player tests green (`flutter test` at the root) | open | Run on the release commit. Known: `settings_account_test` "app version matches pubspec.yaml" needs `app_info.dart` and `pubspec.yaml` bumped together (§3.1). |
| App builds for iOS, Android, macOS, Windows, Linux (desktop with the editor hidden) | open | Release workflows and lanes dry-run (§3.4). Desktop builds get **no** editor dart-defines. |

### 1.2 QA reports (§23 item 2)

| Report | Ticket | Status | Link |
|---|---|---|---|
| iOS Simulator E2E, 18 scenarios | QA-01 | open: 11 of 18 pass (2026-10-16); open FIX tickets (FIX-UX-41-1, FIX-INT-02-2, FIX-QA-00-1, FIX-UX-07-1, FIX-UX-07-2 and the others in the report); s13 deferred to a device | [qa/QA-01-ios-simulator.md](qa/QA-01-ios-simulator.md) |
| Android Emulator E2E | QA-02 | open: not started (Windows laptop, branch `editor-android`) | `qa/QA-02-android-emulator.md` (not written yet) |
| Parity, accuracy, A/V sync | QA-03 | ready on iOS Simulator (accuracy 12/12, A/V 7/7, parity 4/4, grid cuts 100 %); Android and device lab open | [qa/QA-03-parity.md](qa/QA-03-parity.md) |
| Performance budgets | QA-04 | open: no report yet | `qa/QA-04-*.md` |
| Conditional tile cache | UX-43 | open: waits on QA-04 (closes as "not needed" if QA-04 passes) | QA-04 report |
| 1 h soak | QA-05 | open: no report yet | `qa/QA-05-*.md` |
| AI accuracy eval | QA-06 | ready (done) | [ai-eval.md](ai-eval.md) |
| AI device matrix | QA-07 | open: **verdict "not yet"**. D1 (iOS background pause) and D2 (interrupted-job notice) block turning `DANAVIEW_AUTO_CAPTIONS` on (§3.3) | [qa/QA-07-ai.md](qa/QA-07-ai.md) |
| Accessibility | QA-08 | automated 234/234 green; VoiceOver and TalkBack checklist deferred (needs devices) | [qa/QA-08-a11y.md](qa/QA-08-a11y.md) |
| Overflow matrix | QA-09 | open: PR subset green; full matrix fails `--strict` until FIX-UX-22-2, FIX-UX-12/14/18 land | [qa/QA-09-overflow.md](qa/QA-09-overflow.md) |
| Persistence, bookmarks, grants | QA-10 | iOS Simulator 6/6 pass; physical iPhone and Android deferred | [qa/QA-10-persistence.md](qa/QA-10-persistence.md) |
| Export conformance, presets, audio | QA-11 | iOS Simulator green; preview PCM, device lab and Android open | [qa/QA-11-export-audio.md](qa/QA-11-export-audio.md) |

### 1.3 iOS (§23 item 3)

| Check | Status | Evidence / next step |
|---|---|---|
| Deployment target 15.0 everywhere | ready | Done in INT-01 (ARCH §3.1). Re-check: `grep -n IPHONEOS_DEPLOYMENT_TARGET ios/Runner.xcodeproj/project.pbxproj` shows only 15.0, and `ios/Podfile` has `platform :ios, '15.0'`. |
| Launch, player and editor smoke on iPhone 7 (iOS 15.8) and iPhone 8 (iOS 16.7) | deferred | No iOS 15/16 lab devices (owner default in ARCH D-43). Covered by `-Werror=unguarded-availability-new` and `check_ios_min_os.sh`. If a device turns up: `DV_E2E_LAB_UDIDS=<udid> scripts/ci/editor/e2e_ios.sh lab`. |
| Smoke on iOS 26 | open | QA-01 (iPhone 16, iOS 26.5). |
| `check_ios_min_os.sh` clean on the release app | open | Added to the iOS release lane by the §3.2 diff. Paste the output here. |
| `nm -um` shows no `NEWLAPACK` | open | `build_ios_xcframework.sh` checks it after every build. Also run `nm -um` on the release `Runner.app/Frameworks/*` and paste the empty result here. |
| Privacy manifests valid | open | ARCH §20.4. The Xcode privacy report from the release archive (Organizer › Generate Privacy Report) lists the engine pod (C617.1, E174.1, 35F9.1) and the whisper pod (E174.1); Runner has `NSPrivacyTracking = false` and no collected data types. |
| Info.plist strings present | ready | INT-03: `NSMicrophoneUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `BGTaskSchedulerPermittedIdentifiers`, and no `NSPhotoLibraryUsageDescription`. |
| App Store Connect validation clean | owner | Upload through `fastlane ios beta` (TestFlight), then read the processing email. |
| IPA growth ≤ 6 MB for whisper plus the engine | open | Compare the App Store Connect "App Store file sizes" report of 1.0.0 and 1.1.0. The editor fonts (≈ 5.6 MB, ARCH §17.8) and the 12 filter looks are content and are listed separately. |
| GPU continued-processing entitlement status | owner | Record whether Apple granted `com.apple.developer.background-tasks.continued-processing.gpu` (ARCH §20.4). Without it, exports pause in the background and resume on return. |

### 1.4 Android (§23 item 4)

| Check | Status | Evidence / next step |
|---|---|---|
| AAB holds `libdanaview_whisper*.so` for arm64-v8a and x86_64 only, 16 KB aligned, only `dv_*` exported, ≤ 3 MB each | open | Added to the release workflow and the Android lane by the §3.2 diff (`check_native_libs.sh`). Paste the output here. |
| FGS declaration submitted | owner | Text in §5.4. |
| Play pre-launch report clean | owner | Internal testing track, then Play Console › Pre-launch report. |
| `POST_NOTIFICATIONS` / `RECORD_AUDIO` flows verified | open | QA-02 (emulator) plus one device. |
| Backup rules verified | open | QA-02 / QA-10 Android: `adb shell bmgr backupnow com.vecvel.danaview` and confirm the editor and speech trees are not in the backup. |

### 1.5 Privacy, store listing, sign-offs (§23 item 5)

| Check | Status | Evidence / next step |
|---|---|---|
| Privacy policy and terms updated in the app | ready | UX-42 (`packages/danaview_features/lib/src/more/legal_texts.dart`); `test/privacy_policy_host_test.dart` (INT-04). `legalEffectiveDate` still has to move to the release date (§3.1). Owner decision 2026-10-16 (§8, defect 1): the "Open-source licences" page returns under Settings › About and the "Auto captions" terms link to it; ticket **FIX-LICENSES** builds it and must land before the hosted copy is published. |
| Published at every store privacy URL with a diff or screenshot | owner | §5.1. iOS/macOS: `https://vecvel.com/ios/danaview/privacy`. Play: the listing's privacy URL in Play Console. |
| Owner sign-offs of D-43 recorded | ready | ARCH D-43: owner defaults 2026-10-08 for (a)–(d) and (f), owner decision 2026-10-11 for (e). The owner may still revise them before go-live. |
| Store descriptions, release notes, screenshots | open / owner | Texts drafted in §4 (not yet in `ios/fastlane/metadata/` or `android/fastlane/metadata/`). Owner decision 2026-10-16: the 1.0 fastlane store descriptions are replaced with the new casual texts at launch time, not now (§8, defect 3). Screenshots are an owner step after v1.3 (§6). |
| Privacy labels unchanged | ready | App Privacy: "Data Not Collected". Data safety: no data collected, no data shared. Reasons in §5.2 and §5.3. |

### 1.6 Flags, version, rollback (§23 items 6–8)

| Check | Status | Evidence / next step |
|---|---|---|
| Release builds pass `--dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true` on iOS and Android | open | Diff in §3.2. Not applied. `DANAVIEW_AUTO_CAPTIONS` waits for QA-07 (§3.3). |
| Desktop builds keep the editor hidden | ready | Desktop builds get no defines, and `EditorAvailability.platform` hides the editor on macOS/Windows/Linux regardless of the flags (ARCH §3.3, D-17). Desktop absence tests: INT-02, INT-04. |
| Version `1.1.0+3` | open | Diff in §3.1. Not applied. |
| Project schema 1, `minReader` 1, RenderPlan `v` 1, migration fixtures committed | ready | CORE-25 (schema and migration fixtures), CORE-29 (plan `v` 1). Re-check on the release commit: `cd packages/danaview_editor_core && dart test test/store test/plan`. |
| Rollback plan | ready | §7. |

### 1.7 [VERIFY] closures owned by INT-05 (ARCH §24.2)

| Item | Answer to record in ARCH §24.2 at release |
|---|---|
| V-A14 App Review stance on post-install model downloads | The model is data (weights), not code: no executable code is downloaded, the app's behaviour doesn't change, and the download is optional and asked for each time (Guideline 2.5.2). The App Review note in §5.5 says so. Close it with the date of the first approved submission that included the download. |

---

## 2. Release order (when the owner says go)

1. Land every open FIX ticket (including FIX-LICENSES, §8 defect 1), then re-run QA-01, QA-02, QA-07, QA-09 to green (§1.2).
2. Apply §3.1 (version) and §3.2 (release builds) in one INT-05 commit. Apply §3.3 (the Auto captions flag) only once QA-07 says yes. If it doesn't, ship with Auto captions off and leave the captions text out of the store copy (§4.6).
3. Copy the §4 texts into the fastlane metadata files listed in §4.5, replacing the 1.0 store descriptions (owner decision 2026-10-16: at launch time, not before).
4. Dry-run every release workflow and lane (§3.4). Upload to TestFlight and to the Play internal track.
5. Owner steps in §6, then tag `v1.1.0` on `main`.

---

## 3. Prepared changes (not applied)

### 3.1 Version 1.1.0+3

```diff
--- a/pubspec.yaml
+++ b/pubspec.yaml
-version: 1.0.0+1
+version: 1.1.0+3
```

The About screen and a root test read the version from `app_info.dart`, which has to move with it (the file belongs to the player features, so the change goes through INT-05 as an integration change or a FIX ticket):

```diff
--- a/packages/danaview_features/lib/src/more/app_info.dart
+++ b/packages/danaview_features/lib/src/more/app_info.dart
-const String danaviewAppVersion = '1.0.0';
-const int danaviewBuildNumber = 1;
+const String danaviewAppVersion = '1.1.0';
+const int danaviewBuildNumber = 3;
```

The legal pages' effective date becomes the release date (its comment already names INT-05):

```diff
--- a/packages/danaview_features/lib/src/more/legal_texts.dart
+++ b/packages/danaview_features/lib/src/more/legal_texts.dart
-const String legalEffectiveDate = '11 October 2026';
+const String legalEffectiveDate = '<release day> <month> <year>';
```

Notes:
- Build 3 is higher than every build uploaded so far (1.0.0 was build 1). The iOS `beta` lane takes the next TestFlight number by itself. `release` takes `BUILD_NUMBER` (default 1), so run it with `BUILD_NUMBER=3`. The Android lanes take the version code from `pubspec.yaml`. If Play or App Store Connect already holds a build ≥ 3, use the next free number on both and say so here.
- Projects are forward-compatible through `minReader`, so 1.1.0 needs no data migration.

### 3.2 Release builds: flags, whisper framework and native checks

Both editor flags are compile-time `--dart-define`s that default to false (ARCH D-31). The code never flips them. Only the iOS and Android release builds pass them.

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

QA-07's verdict on 2026-10-16 is **not yet**: keep `DANAVIEW_AUTO_CAPTIONS` off until D1 and D2 are fixed, the suite is green on the simulator and on one device per platform, and the device matrix is filled ([qa/QA-07-ai.md](qa/QA-07-ai.md)). If the release has to go out before that, drop `--dart-define=DANAVIEW_AUTO_CAPTIONS=true` from the three places in §3.2 and use the "without Auto captions" store texts (§4.6). The editor flag doesn't depend on it.

### 3.4 Dry runs (BUILD_PLAN INT-05 acceptance)

| What | How | Result |
|---|---|---|
| iOS lane | `cd ios && BUILD_NUMBER=3 fastlane ios build`: builds the IPA with the flags, runs the min-OS check, uploads nothing | open |
| Android lane | `cd android && fastlane android build` | open |
| Android workflow | `workflow_dispatch` with `build_type: both` on a branch; don't publish the GitHub release | open |
| Linux and Windows workflows | `workflow_dispatch` on a branch; confirm no editor entry points (Home has no editor button) | open |
| macOS | `fastlane ios mac_release` without upload, or `flutter build macos --release`; the editor stays hidden | open |
| Flags reach the app | On a TestFlight or internal-track build: Home shows the editor button left of the gear, and Auto captions shows in the Captions tool | open |

---

## 4. Store texts (drafts)

Tone: grounded and casual, plain words, no spec terms. Every line has to be true for 1.1.0. What 1.1.0 has: the player (videos, streams and links, subtitles, audio tracks, equalizer, playlists, folders, gestures, network tools), and on iPhone, iPad and Android the new video editor with Auto captions. Photos come in only as pictures you add to a video project. Photo browsing and photo editing arrive in 1.2, and there is no document viewer, so the copy doesn't promise either.

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
New in 1.1: a video editor.
• Open it from the new button on Home, or tap Edit while you watch.
• Trim and arrange clips, add music, voiceovers, text and transitions, then save or share.
• Auto captions: Danaview listens to your video and writes the captions on your iPhone. The first time needs a one-time download. Nothing is uploaded.
• Your originals are never changed.
Danaview now needs iOS 15 or later.
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

**Release notes** (`changelogs/3.txt`; also replace `changelogs/default.txt`)

```text
New in 1.1: a video editor.
• Open it from the new button on Home, or tap Edit while you watch.
• Trim and arrange clips, add music, voiceovers, text and transitions, then save or share.
• Auto captions are written on your phone. The first time needs a one-time download. Nothing is uploaded.
• Your originals are never changed.
```

### 4.3 Mac App Store (if a 1.1.0 Mac build ships)

The Mac build has no editor in 1.1 (it comes in 1.3), so its description stays as it is. Release notes (`metadata_mac/en-US/release_notes.txt`):

```text
Small fixes and an updated privacy policy. The new video editor is on iPhone, iPad and Android for now.
```

### 4.4 Words to keep out

Owner rule for store copy: no spec terms. Don't write 4K, HDR, hardware, codec names (HEVC, H.264, AV1), bitrate, AI, machine learning, model, neural, whisper, GPU or FFmpeg. "One-time download" stands in for "speech model download". The privacy policy (§5.1) is the exception: it keeps its exact wording ("speech recognition model", host names and sizes), because there accuracy matters more than tone.

The current 1.0 store copy (`description.txt`, `full_description.txt`, `promotional_text.txt`, `subtitle.txt`, `short_description.txt`) leans on those terms ("ultra-high performance HDR", "hardware-accelerated", codec lists, "zero battery drain"). The §4.1–§4.2 texts replace it completely. Don't merge the two.

### 4.5 Where the texts go (INT-05, at release)

| Text | File |
|---|---|
| App Store subtitle, promo, keywords, description, release notes | `ios/fastlane/metadata/en-US/{subtitle,promotional_text,keywords,description,release_notes}.txt` |
| App Review notes | `ios/fastlane/metadata/review_information/notes.txt` (§5.5) |
| Mac release notes | `ios/fastlane/metadata_mac/en-US/release_notes.txt` |
| Play short and full description | `android/fastlane/metadata/android/en-US/{short_description,full_description}.txt` |
| Play release notes | `android/fastlane/metadata/android/en-US/changelogs/3.txt` (+ `default.txt`) |

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

The in-app texts are the source (`packages/danaview_features/lib/src/more/legal_texts.dart`, UX-42). The hosted pages must say the same, word for word, with the release date as the effective date. Compared to the 1.0 pages, the changes are (ARCH §20.3):

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
| O11 | Submit | TestFlight build to App Review with the §5.5 notes; Play internal → closed → production. Tag `v1.1.0` on `main` after both are approved. |

---

## 7. Rollback

- **Turn the editor off:** a hotfix build without the two `--dart-define`s (remove `EDITOR_DEFINES` from §3.2's three places) hides the Home button, the player's Edit and the editor routes. The player is unaffected. Projects stay on the device untouched and come back when the editor returns.
- **Turn only Auto captions off:** drop `--dart-define=DANAVIEW_AUTO_CAPTIONS=true`. Captions made earlier stay in projects as normal caption tracks. The speech model stays until the user deletes it in Settings.
- **Projects are forward-compatible:** schema 1 with `minReader` 1. A later version that writes a newer schema raises `minReader` only when older apps can't read it; older apps then open such projects read-only (QA-10 "D-12 newer schema read-only").
- **Store side:** App Store phased release can be paused; Play staged rollout can be halted. Don't remove 1.1.0 from the stores without a replacement build: 1.0.0 needs iOS 13, so iOS 13/14 users keep 1.0.0 through "last compatible version" either way.

---

## 8. Defects and follow-ups found while preparing

1. **Third-party licences in the "Auto captions" terms** (`legal_texts.dart`, UX-42). Owner decision 2026-10-16: the owner reverses the earlier removal of the licences route (option (b) of the earlier list). A simple, plain **"Open-source licences"** page returns under **Settings › About**, as ARCH §20.3 / §20.4 and UX-42 describe. It lists the notices for libmpv/FFmpeg (LGPL), whisper.cpp/ggml (MIT), the OFL fonts (Figtree and the content fonts, OFL-1.1), AndroidX Media3 (Apache-2.0) and the other bundled packages. The "Auto captions" terms link to it, in the app and in the hosted copy (§5.1).

   **Still to be built before release: ticket FIX-LICENSES** (app change, not done yet). Scope: the licences page and its `/settings/licenses` route under Settings › About; the notice list above, plain text in the owner UI rules; the link from the "Auto captions" terms in `legal_texts.dart`; `test/editor_wiring_test.dart` changed so `/settings/licenses` opens the licences page instead of landing on Home; a test that every bundled package with a licence notice appears on the page. Until FIX-LICENSES lands, the in-app terms and the hosted policy keep their current text and don't point to the page.
2. **Version sync**: `app_info.dart` (`danaview_features`) has to change with `pubspec.yaml` (§3.1), or the root version test fails. INT-05 does it as an integration change, or a FIX ticket owns it.
3. **Store copy**: the current 1.0 texts in `ios/fastlane/metadata/` and `android/fastlane/metadata/` use the spec terms the owner doesn't want (§4.4). Owner decision 2026-10-16: they are replaced with the new casual texts (§4) at launch time, not now, so that nothing uploads early. Leave the fastlane metadata files unchanged until release step 3 (§2).
4. **QA reports still missing**: QA-02, QA-04 and QA-05 have no report in `qa/` yet.
