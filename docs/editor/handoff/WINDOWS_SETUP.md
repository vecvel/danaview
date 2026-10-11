# Windows laptop: setup and pitfalls (Android lane)

Read this with [README.md](README.md) (who builds what, how the branches sync) and [ANDROID_LANE.md](ANDROID_LANE.md) (the tickets).

**For the owner (plain version).** The laptop builds and tests Android only. Do Part A in order:

1. Install the tools (A2, A3).
2. Switch on three Windows settings (A4).
3. Set up the environment variables (A5).
4. Tell Git to leave line endings alone, and only then clone (A6).
5. Copy the two signing files by USB (A7).
6. Install Claude's notes (A8).

Then start Claude with the first message in README.md. Claude runs the checks in Part B and tells you if something is missing.

**For Claude on the Windows laptop.**
- Your shell is Git Bash (MSYS). Run every `.sh` as `bash <script>` from Git Bash.
- Windows cannot build or test iOS, run the whisper host tests, or regenerate the engine media fixtures. Those stay on the Mac (C2).
- Several test failures happen only on Windows and are expected (C3). Read Part C before you treat a red test as a regression.
- Nothing in this document has been run on Windows yet. It comes from reading the repo on the Mac. P5, P10, P13 and P15 are predictions: confirm them in Part B.

---

## Part A: Owner setup

### A1. Check the laptop

- **Processor type.** Open Settings > System > About. It should say "x64-based processor". If it says ARM-based, stop and tell the Mac session: the emulator image and the NDK host tools in this guide assume x64.
- **Virtualization.** Open Task Manager > Performance > CPU. It should say "Virtualization: Enabled". If it says Disabled, turn on Intel VT-x or AMD SVM in the UEFI/BIOS.
- **Folder locations.** Put everything on drive C: under `C:\dev\`. Don't use Desktop or Documents (OneDrive often syncs them) or Program Files, and avoid paths with spaces.
- **User name.** If your Windows user folder `C:\Users\<name>` contains a space or a non-English letter, also do the extra step at the end of A5.

### A2. Install

| Tool | Version | Notes |
|---|---|---|
| Git for Windows | current 2.x (`winget install Git.Git`) | Includes Git Bash and Git Credential Manager. On the installer's line-ending page pick **"Checkout as-is, commit as-is"**. Keep the default PATH option. |
| Flutter | **3.44.2** stable (Dart 3.12) | The Windows zip from the Flutter SDK archive, extracted to `C:\dev\flutter`. Same version as the Mac and CI (`FLUTTER_VERSION: '3.44.2'` in `.github/workflows/editor-ci.yml`). |
| JDK | **21**, for example Eclipse Temurin 21 (`winget install EclipseAdoptium.Temurin.21.JDK`) | The Mac also runs Java 21. CI uses 17. Every module targets Java 17 (`JavaVersion.VERSION_17`, `JvmTarget.JVM_17`), so both work. |
| Android Studio | current stable (`winget install Google.AndroidStudio`) | Then install the SDK items in A3. |
| ffmpeg | 7.x full build with libx264 and libx265 (`winget install Gyan.FFmpeg`) | Dev-only tool for test media and media tests. The Mac has 7.1.1. |
| Claude desktop app | current | Sign in with the same account as on the Mac. |

You don't need Visual Studio, Xcode, CocoaPods, WSL or Python. Only the Mac-owned AND-01 spike media script uses Python (P16).

### A3. Android SDK items and the emulator

In Android Studio, open Settings > Languages & Frameworks > Android SDK. Tick **Show Package Details** on both tabs.

| Tab | Item | Why |
|---|---|---|
| SDK Platforms | Android 16 ("Baklava") > Android SDK Platform 36 | `compileSdk = 36` in every Android module |
| SDK Platforms | Android 15 ("VanillaIceCream") > **Google APIs Intel x86_64 Atom System Image** | The emulator image. CI uses API 35, x86_64, `google_apis` (`editor-ci.yml`) |
| SDK Platforms | Android 10 (API 29) and Android 14 (API 34) > Google APIs Intel x86_64 Atom System Image | Needed later: AND-02 checks the editor gate on API 29, and AND-12 runs on 29, 34 and 35 ([ANDROID_LANE.md](ANDROID_LANE.md)). It also asks for a tablet AVD for AND-15 |
| SDK Tools | Android SDK Build-Tools 36.0.0 | AGP 9.0.1. The Mac also has 35.0.0 |
| SDK Tools | NDK (Side by side) **28.2.13676358** | `flutter.ndkVersion` in Flutter 3.44.2 (`FlutterExtension.kt`) and `ndkVersion` in `spikes/android_engine/app/build.gradle.kts`. The whisper Android build (AI-04) uses it too |
| SDK Tools | NDK (Side by side) **27.0.12077973** | Installed on the Mac. Nothing in the repo pins it today, so it's harmless |
| SDK Tools | CMake **3.22.1** | Pinned by `externalNativeBuild { cmake { version = "3.22.1" } }` (spike, AI-04 plan). Ships `ninja.exe` |
| SDK Tools | Android SDK Command-line Tools (latest), Android Emulator, Android SDK Platform-Tools | Provide `sdkmanager`, `avdmanager`, `emulator` and `adb`, and handle licence acceptance |

The command-line equivalent is below. It downloads packages and accepts licences, so the owner runs it or approves it.

```bash
sdkmanager.bat --install "platforms;android-36" "build-tools;36.0.0" "platform-tools" "emulator" \
  "cmdline-tools;latest" "ndk;28.2.13676358" "ndk;27.0.12077973" "cmake;3.22.1" \
  "system-images;android-35;google_apis;x86_64" \
  "system-images;android-29;google_apis;x86_64" "system-images;android-34;google_apis;x86_64"
```

**Emulator.** In Device Manager, create a **Pixel 9 Pro XL, API 35, Google APIs x86_64** device and name it `Pixel_9_Pro_XL_API_35`. That's the same name as on the Mac, but not the same image: the Mac's AVD is `arm64-v8a` (`google_apis_playstore`), and an arm64 image can't run on this PC. Give it at least 2 GB of RAM. The command line:

```bash
avdmanager.bat create avd -n Pixel_9_Pro_XL_API_35 -k "system-images;android-35;google_apis;x86_64" -d pixel_9_pro_xl
# if the id is missing: avdmanager.bat list device
```

The editor gate is ≥ 2 GB RAM (ARCHITECTURE.md §3.2, D-43), and Android reports a little less than the AVD's configured RAM. If the engine reports `insufficient_memory` on this AVD, raise its RAM to 3 GB.

### A4. Windows settings (once, as administrator)

1. **Developer Mode** (P1). Run `start ms-settings:developers` and switch Developer Mode **On**.
2. **Windows Hypervisor Platform** (P3). Run this in an admin PowerShell, then reboot:
   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
   ```
   You can also tick it under "Turn Windows features on or off".
3. **Long paths** (P5). Run this in an admin PowerShell:
   ```powershell
   New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force
   ```
4. **Optional, your decision:** Microsoft Defender exclusions for `C:\dev`, `%USERPROFILE%\.gradle`, `%LOCALAPPDATA%\Android\Sdk` and `%LOCALAPPDATA%\Pub\Cache`. Android Studio offers to add these itself. Builds get faster, but those folders are less protected.

### A5. Environment variables and PATH

Run this in PowerShell as a normal user. Edit the `$jdk` line to the folder the JDK installer created.

```powershell
$jdk     = 'C:\Program Files\Eclipse Adoptium\<your jdk-21 folder>'
$sdk     = "$env:LOCALAPPDATA\Android\Sdk"
$ffmpeg  = (Get-Command ffmpeg).Source      # or the full path to ffmpeg.exe
$ffprobe = (Get-Command ffprobe).Source
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $sdk, 'User')
[Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk, 'User')
[Environment]::SetEnvironmentVariable('FFMPEG', $ffmpeg, 'User')
[Environment]::SetEnvironmentVariable('FFPROBE', $ffprobe, 'User')
$add = 'C:\dev\flutter\bin', "$jdk\bin", "$sdk\platform-tools", "$sdk\emulator",
       "$sdk\cmdline-tools\latest\bin", "$sdk\cmake\3.22.1\bin"
$old = [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('Path', (($add + $old) -join ';'), 'User')
```

Close every terminal and the Claude app, then open a new PowerShell:

```powershell
flutter config --jdk-dir "$env:JAVA_HOME"   # Flutter's Gradle runs and ./gradlew use the same JDK
flutter doctor --android-licenses           # read and accept the licences (owner)
```

`FFMPEG` and `FFPROBE` must be full `.exe` paths. The engine tests can't find ffmpeg through PATH on Windows (P12).

**Extra step if your user folder has a space or a non-English letter:** also set the user variables `GRADLE_USER_HOME=C:\dev\.gradle` and `PUB_CACHE=C:\dev\.pub-cache` before the first build. If the SDK path itself contains a space, move the SDK to `C:\dev\Android\Sdk` (Android Studio > SDK Manager > Edit) and update `ANDROID_HOME` and PATH to match.

### A6. Git settings, then clone

Do this in Git Bash. The order matters: change the settings first, then clone.

```bash
git config --global core.autocrlf false
git config --global core.longpaths true
git config --global user.name  "<same as on the Mac>"
git config --global user.email "<same as on the Mac>"
mkdir -p /c/dev && cd /c/dev
git clone --branch editor-wip https://github.com/vecvel/vwish.git vwish_player
cd vwish_player
test -f .gitattributes && git status --short   # prints nothing
git switch -c editor-android                   # if origin/editor-android exists already: git switch editor-android
git push -u origin editor-android              # the first push opens a GitHub sign-in window; the owner signs in
```

- Clone only after the Mac has pushed the hand-off commit. That commit adds `.gitattributes`, `docs/editor/handoff/` and `tool/handoff/`. If `test -f .gitattributes` fails, the clone is too early.
- Keep the folder `C:\dev\vwish_player`. Claude's notes folder name comes from this path (A8).
- If `git status` shows modified files right after cloning, Git converted the line endings. Delete the folder, check the settings, and clone again (P2).

### A7. Signing files (USB)

Copy two files from the Mac:

- `android/key.properties` to `C:\dev\vwish_player\android\key.properties`
- `android/app/release.jks` to `C:\dev\vwish_player\android\app\release.jks`

Then check that Git ignores them. `git check-ignore -v android/key.properties android/app/release.jks` must print two rules from `android/.gitignore`, and `git status --short` must stay empty.

Erase them from the USB stick afterwards. Never commit, email or paste them, and Claude never opens or prints them.

Lane work doesn't need them: without them, release builds of the app use the debug key instead (`android/app/build.gradle.kts`).

### A8. Claude's notes

1. In the Claude app, open the Code tab, open `C:\dev\vwish_player` once, then close that session.
2. In PowerShell, in `C:\dev\vwish_player`, run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File tool\handoff\install_claude_memory.ps1
   ```
   The script copies `docs/editor/handoff/claude-memory/*.md` into `%USERPROFILE%\.claude\projects\C--dev-vwish-player\memory\`. The folder name is the repo path with every character that isn't a letter or digit replaced by `-`. Notes already in that folder are backed up first.
3. Start a new Code session in the same folder and paste the first message from README.md.

If Claude reports that it can't find Git Bash, set the user variable `CLAUDE_CODE_GIT_BASH_PATH=C:\Program Files\Git\bin\bash.exe` and restart the app.

---

## Part B: Smoke checks (Claude runs them in Git Bash from `/c/dev/vwish_player`)

Run them in order and stop at the first failure. Ask the owner before installing anything.

**B1. Tools**
```bash
flutter --version            # Flutter 3.44.2, Dart 3.12.x
java -version                # version "21..."
cmake --version              # cmake version 3.22.1
adb version
ffmpeg -version | head -1    # ffmpeg version 7.x
ls "$FFMPEG" "$FFPROBE"      # both exist (full .exe paths)
```

**B2. Doctor and acceleration**
```bash
flutter doctor -v            # Flutter, Android toolchain (licences accepted), Android Studio ticked. Ignore Visual Studio and Chrome.
emulator -accel-check        # reports WHPX as installed and usable
```

**B3. Git and line endings**
```bash
git config --get core.autocrlf      # false
git config --get core.longpaths     # true
git branch --show-current           # editor-android
git status --short                  # nothing
git ls-files --eol | grep -E 'w/(crlf|mixed)'
```
The last command passes if it lists only `tool/handoff/install_claude_memory.ps1` and files under `packages/*/test/fixtures/`. Some subtitle and LUT fixtures contain CR or CRLF on purpose. If it lists any `.sh`, `gradlew`, `.dart`, `.kt`, `.kts`, golden or JSON outside fixtures, the clone is broken (P2).

**B4. Flutter at the repo root (proves symlinks work)**
```bash
flutter pub get        # no "requires symlink support" error (P1)
git status --short     # still nothing (see C4 "Generated files" if registrants changed)
```

**B5. Pure Dart core**
```bash
cd packages/vwish_editor_core
dart pub get
dart run tool/gen_frame_vectors.dart --check     # exit 0: the LF fixture is byte-exact
dart test -r failures-only test/time test/formats test/model test/eval test/plan test/ops test/validate test/session
```
This passes when it prints `All tests passed!`. That's about 2,800 tests today, taking about 40 s on the Mac.

If a `*_benchmark_test.dart` fails, rerun once (P14). If the only failures are golden or vector mismatches in the last digits of a decimal, that's P15: record it and tell the owner.

Then record the Windows baseline of the whole suite, outside the repo:
```bash
dart test -r failures-only > ~/vwish_core_windows_baseline.txt 2>&1; tail -n 3 ~/vwish_core_windows_baseline.txt
cd ../..
```
Failures in `test/store/**` and in the two `container_paths_test.dart` files are expected (P10). Report anything else. From now on, judge core runs against this baseline, not against "all green".

**B6. Flutter packages**
```bash
bash scripts/ci/editor/flutter_packages.sh vwish_editor_engine_api architecture   # summary: failed: none
bash scripts/ci/editor/flutter_packages.sh vwish_editor_engine
```
In the first run, a last-digit mismatch in `test/reference/regen_check_test.dart` would be P15, not a toolchain problem.
In the second run, the only expected failure is `committed Pigeon output equals a fresh regeneration` (P11). Its ffmpeg tests (`test/testing/frame_barcode_test.dart`, `test/fixtures/fixtures_semantic_test.dart`) must run, not skip. A skip means `FFMPEG` or `FFPROBE` isn't set (P12).

**B7. Gradle, NDK and CMake (no emulator needed)**
```bash
cd spikes/android_engine
./gradlew --console=plain :app:assembleDebug :app:testDebugUnitTest   # BUILD SUCCESSFUL
./gradlew --stop
cd ../..
```
This compiles the spike's C++ with NDK 28.2.13676358 and CMake 3.22.1. The first run downloads Gradle 9.1.0 and Maven packages, which is normal dependency resolution.

The spike has no `gradlew.bat` and no `local.properties` (it's git-ignored), so it needs Git Bash and `ANDROID_HOME` (P16).

**B8. Example host and JVM tests** (the `android-unit` CI job; needs ENG-09's `packages/vwish_editor_engine/example/`)
```bash
VWISH_ANDROID_APK_MODE=debug bash scripts/ci/editor/android_unit.sh   # android-unit: OK
```

**B9. Emulator and instrumented tests** (Claude: start the emulator in the background)
```bash
emulator -avd Pixel_9_Pro_XL_API_35 -gpu host -no-snapshot-load &
adb wait-for-device
adb shell getprop sys.boot_completed               # 1 once booted (repeat until it is)
adb shell getprop ro.product.cpu.abi               # x86_64
adb shell dumpsys SurfaceFlinger | grep -m1 GLES   # mentions OpenGL ES 3.x (editor gate, ARCHITECTURE.md §3.2)
bash scripts/ci/editor/android_emulator.sh         # android-emulator: OK
```

---

## Part C: Known Windows pitfalls

Each pitfall has a tag: **Blocker** (fix during setup), **Mac-only**, **Expected** (not a regression) or **Risk** (likely, not yet confirmed).

### C1. Blockers

**P1. Symlinks need Developer Mode.** Blocker.
- **Symptom:** `flutter pub get` at the root stops with "Building with plugins requires symlink support. Please enable Developer Mode…". Core tests that create links fail with `ERROR_PRIVILEGE_NOT_HELD` (1314).
- **Cause:** the root app has `windows/` and `linux/` folders and desktop plugins in `pubspec.yaml` (`window_manager`, `desktop_drop`, `file_selector`). Every `pub get` links these plugins into `windows/flutter/ephemeral/.plugin_symlinks` (flutter_tools `createPluginSymlinks`). Tests under `packages/vwish_editor_core/test/store/**` also call `Link.createSync`. Without admin rights, Windows only allows symlinks in Developer Mode.
- **Fix:** A4.1. Keep the Flutter SDK, the pub cache and the repo on the same NTFS drive. Otherwise Flutter fails with `ERROR_INVALID_FUNCTION`.

**P2. CRLF line endings.** Blocker.
- **Symptom:**
  - Scripts fail with `$'\r': command not found` or `set: pipefail\r: invalid option name`.
  - `./gradlew` fails with `/bin/sh^M: bad interpreter`.
  - `gen_frame_vectors.dart --check`, the golden tests, the Pigeon check or the `kitchen_sink.vwproj` checksum fail.
  - `git status` shows hundreds of modified files.
- **Cause:** Git for Windows can be set to `core.autocrlf=true`, which rewrites text files to CRLF. The repo needs exact LF bytes in:
  - every `.sh` (`scripts/ci/editor/*.sh`, `spikes/android_engine/tool/*.sh`, `packages/vwish_whisper/tool/vendor_whisper.sh`) and `spikes/android_engine/gradlew`;
  - `packages/vwish_editor_core/test/fixtures/vectors/` (string-compared by `tool/gen_frame_vectors.dart --check`);
  - `packages/vwish_editor_core/test/plan/compile_lowering/goldens/`, `.../compile_visual/goldens/` and `test/ops/*/goldens/*.golden`;
  - `packages/vwish_editor_core/test/codec/fixtures/kitchen_sink.vwproj` (its header carries `bodyBytes` and `bodySha256`);
  - `packages/vwish_transcription/test/segmentation/goldens/`;
  - the committed Pigeon output in `packages/vwish_editor_engine` (compared with a fresh run);
  - `packages/vwish_whisper/third_party/whisper.cpp` (tree digest in `vendor_whisper.sh`);
  - `test/architecture/fixtures/`.

  Some fixtures contain CR or CRLF on purpose and must never be converted: `packages/vwish_editor_core/test/fixtures/subtitles/` (`basic.srt`, `bom_utf8.srt`, `cp1252.srt`, `cr_only.srt`, `vtt_bom_crlf.vtt`, the UTF-16 files) and `test/fixtures/luts/adobe_identity_4.cube`.
- **Fix:** apply the A6 settings before cloning. `.gitattributes` adds `* text=auto eol=lf` and `-text` for `**/test/fixtures/**`, `**/test_fixtures/**`, `test/architecture/fixtures/**`, `*.golden`, `*.srt`, `*.vtt` and `*.cube`, plus binary rules. `*.ps1`, `*.bat` and `*.cmd` stay CRLF. With both in place, Windows checks out LF and can't commit CRLF.

  Goldens outside `test/fixtures/` stay text with `eol=lf`. They contain no CR, so normalisation leaves them byte-identical.

  If a clone is damaged, delete it and clone again. Don't fix files by hand.

**P3. The emulator won't start or crawls.** Blocker.
- **Symptom:** "x86_64 emulation currently requires hardware acceleration", the AVD never boots, or an arm64 image won't run.
- **Cause:** WHPX is off or virtualization is disabled, or the Mac's arm64 AVD was copied over.
- **Fix:** A1, A4.2 and an x86_64 image (A3). Check with `emulator -accel-check`.

**P4. Paths with spaces, non-ASCII letters, OneDrive or a second drive.** Blocker.
- **Symptom:** Gradle, CMake or NDK path errors, native link errors, random "file in use" errors, or Flutter's `ERROR_INVALID_FUNCTION` when linking plugins.
- **Cause:** NDK and CMake command lines break on unquoted spaces. AI-04's linker version script `packages/vwish_whisper/src/vw_exports.map` is one example. OneDrive syncs and locks `build/` folders. Flutter's plugin links need the same drive.
- **Fix:** use `C:\dev\flutter` and `C:\dev\vwish_player`, keep the SDK path free of spaces, and do the A5 extra step if your user folder has a space or a non-English letter.

**P5. Long paths.** Risk.
- **Symptom:** git reports "Filename too long". CMake warns or fails about object paths. aapt2 or `flutter clean` can't create or delete files.
- **Cause:** Gradle intermediates get very deep. On the Mac, one file under `packages/vwish_editor_engine/example/build/vwish_editor_engine/.transforms/…/bundleLibRuntimeToDirDebug_global-synthetics/…` sits 360 characters below the repo root, and Windows' classic limit is 260 for the whole path. Java (Gradle, D8, Kotlin) handles long paths itself; native tools may not. The longest tracked path is 138 characters, so checkout itself is fine.
- **Fix:** `core.longpaths true` (A6), LongPathsEnabled (A4.3) and the short root `C:\dev\vwish_player`. If a tool still fails, report the path. Don't move the repo deeper.

### C2. Mac-only (hand these to the Mac)

**P6. whisper host tests.**
- `scripts/ci/editor/whisper_host.sh` (AI-03) needs a host C/C++ compiler and targets macOS and Linux:
  - `packages/vwish_whisper/src/CMakeLists.txt` says "Host build (macOS / Linux, CPU only)" and uses `-fsanitize=…` and `Threads`;
  - the macOS leg runs Apple `leaks`.
- Windows has no host compiler (the NDK's clang only targets Android), so the configure step fails even though `cmake` is on PATH.
- For AI-04: keep changes inside AI-04's own files (`packages/vwish_whisper/android/build.gradle.kts`, `android/src/main/AndroidManifest.xml`, `src/cmake/android.cmake`, `src/vw_exports.map`, `scripts/ci/editor/check_native_libs.sh`). If a shim source `packages/vwish_whisper/src/vw_*` must change, ask the Mac to run `whisper_host.sh` before the merge.

**P7. Engine media fixtures.** `packages/vwish_editor_engine/tool/make_fixtures.swift` (ENG-05) needs macOS: AVFoundation, Core Text and `say` (see `test_fixtures/media/README.md`). Use the committed files and never regenerate them on Windows. If a lane ticket needs new media, generate it locally with ffmpeg in Git Bash. No downloads.

**P8. iOS.** Leave all of it to the Mac: `ios/`, `packages/*/ios/`, `scripts/ci/editor/ios.sh`, `check_ios_min_os.sh`, XCTest and CocoaPods.

**P9. Re-vendoring whisper.cpp.** `packages/vwish_whisper/tool/vendor_whisper.sh` (AI-01) downloads the upstream tarball, even with `--check`. It would run in Git Bash, but the download rule keeps it on the Mac.

### C3. Expected on Windows (not regressions)

**P10. `vwish_editor_core` store tests fail.**
- **Symptom:** failures under `packages/vwish_editor_core/test/store/**`, `test/store/repository/container_paths_test.dart` and `test/codec/container_paths_test.dart`. This also makes `scripts/ci/editor/core.sh` fail on Windows, so don't use it as a gate here.
- **Cause:** the persistence layer ships only on iOS and Android and assumes POSIX:
  - `lib/src/store/store_fs.dart` maps POSIX errno values (`_eexist = 17`, 13, 28). Windows reports 80, 5 and 112, so `copyExclusive` throws instead of returning false.
  - `lib/src/store/store_roots.dart` joins paths with the platform separator (`\`). The in-memory fake in `lib/testing.dart` uses `p.posix`, and tests assert POSIX strings such as `'/journal/'` and `'/vwish/editor/media/'` under roots like `/mem/…` and `/var/mobile/…`.
  - The symlink tests need Developer Mode, and Windows treats file and directory links differently.
- **Fix:** none on Windows. The CORE tickets belong to the Mac, so never edit core to make these pass. Compare against the B5 baseline. Any `packages/vwish_editor` widget test that uses the in-memory fake repository may fail the same way.

**P11. The Pigeon regeneration test fails.**
- **Cause:** `packages/vwish_editor_engine/test/glue/pigeon_regeneration_test.dart` runs `<flutter>/bin/dart`. On Windows that file is a bash script, so `Process.run` throws.
- **Windows check instead:** run this in `packages/vwish_editor_engine`. No output means the committed Pigeon files are in sync:
  ```bash
  dart run pigeon --input pigeons/engine_api.dart && git diff --exit-code -- lib/src/pigeon ios/Classes/Pigeon android/src/main/kotlin/com/vecvel/vwish/editor/engine/pigeon
  ```
  The generated files belong to ENG-01/ENG-06. If anything differs, restore it with `git restore` and tell the Mac.
- **Mac follow-up:** the test's owner (ENG-01) could use `bin\dart.bat` with `runInShell: true`, or `bin/cache/dart-sdk/bin/dart.exe`, on Windows.

**P12. Skipped tests.**
- **ffmpeg tests:** `packages/vwish_editor_engine/test/fixtures/support/media_tools.dart` searches `/opt/homebrew/bin`, `/usr/local/bin` and `/usr/bin`, and splits PATH on `:` without adding `.exe`. Without `FFMPEG` and `FFPROBE` (A5), every ffmpeg test skips.
- **ffigen:** `packages/vwish_whisper/test/abi/ffigen_regen_test.dart` skips because it runs `dart` (a `.bat` on Windows) and needs libclang. The Mac and Linux CI run it.
- **Fallback fonts:** `packages/vwish_editor_engine_api/test/render_prep/support.dart` only knows macOS and Linux font paths, so those cases skip.
- **macOS-only:** `packages/vwish_whisper/test/device/ios_profiler_host_test.dart` and the fixture regeneration group skip.

**P13. This emulator isn't the Mac's, CI's or a phone.**
- **ABI:** x86_64 here, arm64 on the Mac. AI-04's two arm64 libraries (`armv8-a` and `armv8.2-a+fp16+dotprod`) never load here; the x86_64 library does. Record arm64 runtime-selection checks as "deferred: no device available", unless the Mac runs them on its arm64 AVD.
- **GPU:** the Windows host GPU here, a Metal translator on the Mac, and SwiftShader in CI (`-gpu swiftshader_indirect` in `editor-ci.yml`). GL extensions and decoders can differ from the target row in `docs/editor/spikes/AND-01.md`. Probe them again instead of copying the Mac's results. If a GL test disagrees with CI, rerun the emulator with `-gpu swiftshader_indirect`.
- **Timings:** numbers aren't comparable between machines.
- **Spike APK:** the spike is arm64-only (`abiFilters += listOf("arm64-v8a")`), so its native code only works here through ARM translation, if at all.

**P14. Timing tests are flaky under load.**
- `*_benchmark_test.dart` files assert millisecond budgets. One example is `packages/vwish_editor_core/test/plan/diff/incremental_benchmark_test.dart`.
- During this audit, the B5 subset failed 3 tests on the Mac once and passed on the rerun.
- Defender scanning adds load. Rerun once before you treat a failure as real.

**P15. Last-digit golden differences.** Risk.
- **Cause:** plan goldens hold full-precision doubles and are compared as exact strings. Some of these values go through `dart:math` `sin`, `cos`, `exp` and `log` (`lib/src/plan/lowering_audio.dart`, `lowering_transitions.dart`, `lib/src/eval/speed_math.dart`), and the math library can round the last bit differently on Windows. The API-03 tool already allows for this in PNGs (`packages/vwish_editor_engine_api/tool/regen_goldens.dart`), but compares JSON and binaries byte for byte.
- **Fix:** if a golden fails only in trailing digits, record it in the baseline and tell the Mac. Never run `VWISH_UPDATE_GOLDENS=1` or `regen_goldens.dart` on Windows.

**P16. The AND-01 spike tools assume the Mac.**
- `spikes/android_engine/tool/gen_media.sh` defaults ffmpeg to `/opt/homebrew/bin/ffmpeg`. It ends with a `python3` check, and on Windows `python3` may be the Microsoft Store stub.
- `spikes/android_engine/tool/run_spike.sh` defaults the SDK to `$HOME/Library/Android/sdk`. It also pulls `/sdcard/Android/data/…/results/.`, which Git Bash rewrites to `C:/Program Files/Git/sdcard/…`. The error is hidden (`>/dev/null 2>&1 || true`), so `results/` stays stale.
- The spike belongs to the Mac (AND-01); on Windows, use it only for B7. If you ever run it, pull the results by hand from `spikes/android_engine`:
  ```bash
  MSYS_NO_PATHCONV=1 adb pull /sdcard/Android/data/com.vecvel.vwish.spike.engine/files/results/. results/
  ```

### C4. Working rules on Windows (for Claude)

- **Shell.**
  - Use Git Bash. Run scripts as `bash scripts/...`. In PowerShell, `bash` may start WSL (`C:\Windows\System32\bash.exe`), so don't use it.
  - In Git Bash, `.bat` tools need the extension: `sdkmanager.bat`, `avdmanager.bat`. `flutter`, `dart`, `adb`, `emulator`, `cmake` and `./gradlew` work as on the Mac.
  - Run the emulator and other long commands in the background.
- **adb and device paths.** Git Bash rewrites any argument that starts with `/`, such as `/sdcard/…` or `/data/local/tmp/…`, including inside `adb shell ls /sdcard`. Prefix those commands with `MSYS_NO_PATHCONV=1` and use relative host paths in them.
- **CI scripts already work.** `scripts/ci/editor/android_unit.sh`, `android_emulator.sh`, `flutter_packages.sh` and `nightly.sh` use portable bash and tools that Git Bash has (`find -print -quit`, `awk`, `seq`, `tr`, `sed -n`). `android_emulator.sh` finds `adb` through PATH; its fallbacks are macOS and Linux SDK paths only.
- **Keep scripts portable.**
  - New or changed scripts must keep the `scripts/ci/editor/README.md` contract: macOS bash 3.2 and Ubuntu CI. That means no `sed -i`, `stat`, `readlink -f`, `mapfile` or associative arrays. Use `wc -c` for sizes.
  - Never commit machine paths (`C:\…`, `/c/…`, `local.properties`).
- **AI-04 `check_native_libs.sh`.**
  - Choose the NDK host folder by `uname -s`: `darwin-x86_64` (also on Apple silicon; confirmed in the Mac's NDK 28.2), `linux-x86_64`, or `windows-x86_64` (`MINGW*`/`MSYS*`, add `.exe`: `llvm-readelf.exe`, build-tools `zipalign.exe`).
  - Git Bash has no `zip` and may lack `unzip`. Check with `command -v unzip`; the JDK's `jar tf`/`jar xf` works everywhere.
- **Executable bit.** Windows can't set it. Add new scripts with `git add --chmod=+x <file>`. `core.sh`, `flutter_packages.sh`, `nightly.sh`, the spike tools, `vendor_whisper.sh` and `spikes/android_engine/gradlew` are `100755` in git today.
- **Generated files.** `flutter pub get` at the root rewrites tracked registrants (`windows/flutter/generated_plugin*`, `linux/flutter/generated_plugin*`, `macos/Flutter/GeneratedPluginRegistrant.swift`). Any `pub get` can touch the tracked `pubspec.lock` files. If these show up in `git status` and the ticket doesn't own them, `git restore` them before committing.
- **File locks.** If deleting `build/` or running `flutter clean` fails with "being used by another process", run `./gradlew --stop` in that Android project, close Android Studio, and retry.
- **Line separator.**
  - Set Android Studio > Settings > Editor > Code Style > Line separator to "Unix and macOS (\n)".
  - `.gitattributes` normalises commits, but some tests read the files in the working tree, such as `test/architecture/dependency_rules_test.dart` and `packages/vwish_editor_core/test/purity_test.dart`.
- **Prefer the example host for Android checks.** The root app's Android build downloads libmpv jars from GitHub through the Gradle script of `media_kit_libs_android_video` 1.3.8 (MD5-checked; the Mac does the same). The example (`packages/vwish_editor_engine/example/pubspec.yaml`) has no media_kit.
- **Java.** `android_unit.sh` says "install JDK 17" in its error text, but it only checks that `java` exists. JDK 21 is fine (see A2).

---

## Part D: What the audit checked

| Area | Checked | Result |
|---|---|---|
| Symlinks in git | `git ls-tree -r origin/editor-wip` | none |
| Names that clash on Windows | the whole tree, for case-only duplicates, `CON`/`NUL`/`AUX`/`COMn`/`LPTn`, and `<>:"\|?*` | none |
| Longest tracked path | the whole tree | 138 characters (`test/architecture/fixtures/m_features_material_in_interpolation/…`) |
| Files containing CR | tracked and new files | only `packages/vwish_editor_core/test/fixtures/{subtitles,luts}/…`, covered by `-text` |
| `.bat`/`.cmd`/`.ps1` | the whole tree | only `tool/handoff/install_claude_memory.ps1` (ASCII, CRLF by rule) |
| Gradle setup | `android/`, `packages/vwish_editor_engine{,/example}/android`, `packages/vwish_whisper/android`, `spikes/android_engine` | AGP 9.0.1, Kotlin 2.3.20, Gradle wrapper 9.1.0, `compileSdk` 36. NDK is `flutter.ndkVersion` (28.2.13676358) or pinned 28.2 in the spike; CMake is pinned 3.22.1. `sdk.dir` comes from untracked `local.properties`: Flutter writes it for the app and the example, and the spike needs `ANDROID_HOME` |
| Host tests that handle `\` correctly | `test/architecture/dependency_rules_test.dart`, `packages/vwish_editor_core/test/purity_test.dart`, `packages/vwish_whisper/test/abi/abi_contract_test.dart`, `packages/vwish_editor/test/architecture/arch_scan.dart`, `packages/vwish_transcription/lib/src/models_store/model_manifest.dart` | they normalise or reject `\` |
| Host tests that don't | see P10, P11, P12 | expected on Windows |
| Test HTTP servers | `packages/vwish_transcription/test/models_store/support/fake_model_server.dart` | bind loopback only, so no firewall prompt |
| What ran | B5's core subset, on the Mac | green on rerun (P14). Nothing in this document has been run on Windows |
