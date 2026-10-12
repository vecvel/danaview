---
name: windows-machine-state
description: "What is actually installed on the Windows laptop (2026-10-11): repo C:\dev\danaview, env script ~/danaview_env.sh, SDK/AVDs/ffmpeg, media_kit jar download workaround"
metadata:
  node_type: memory
  type: project
  originSessionId: 0ad1acc4-d6e3-4e88-b536-11b1440e0f4d
  modified: 2026-10-11T02:42:27.546Z
---

Checked 2026-10-11 against WINDOWS_SETUP.md Part B ([[windows-android-lane]]):

- **Repo path:** `C:\dev\danaview` since 2026-10-11 (moved out of OneDrive; old path was the OneDrive Desktop `vwish` folder).
- **Shell env:** the Bash tool sources neither `~/.bashrc` nor `~/.bash_profile`. Start every Bash command with `source ~/danaview_env.sh` (renamed from vwish_env.sh 2026-10-11; its VWISH_* vars are now DANAVIEW_*; `VWISH_BASHRC_TEST` removed from `~/.bashrc`) (sets ANDROID_HOME, JAVA_HOME = Android Studio JBR 21.0.10, FFMPEG/FFPROBE, PATH for adb/emulator/cmake/ninja/ffmpeg/sdkmanager). The A5 user env vars WERE set on 2026-10-11 but only reach new processes after the Claude app restarts.
- **Flutter 3.44.8** at `C:\Users\Masud\develop\flutter` (docs say 3.44.2; Dart 3.12.2; flutter.ndkVersion 28.2.13676358). `pubspec.lock` stayed clean after pub get.
- **SDK (gaps installed 2026-10-11 with the owner's OK):** platforms 35/36/36.1/37.0, build-tools 36.0.0, NDK 28.2.13676358 only (NDK 27 skipped: nothing pins it), CMake 3.22.1 + ninja, cmdline-tools latest (sdkmanager 22.0), system images android-35/29/34 google_apis x86_64 plus android-37.0 playstore.
- **AVDs:** Pixel_9_Pro_XL_API_35, Pixel_API_29, Pixel_API_34, Pixel_Tablet_API_35 (x86_64, 3 GB RAM, 16 GB data; created 2026-10-11, first boot not yet tested) and Medium_Phone (API 37, playstore). WHPX works.
- **Installed 2026-10-11:** ffmpeg 7.1.1 full (winget Gyan.FFmpeg, under %LOCALAPPDATA%\Microsoft\WinGet\Packages), Developer Mode ON, `flutter config --jdk-dir` = JBR. JDK is still only the JBR (21.0.10), which is fine.
- **Baselines:** core suite 3691 tests, 113 fail, all under `test/store/**` (P10). `danaview_editor_engine`: only the Pigeon regeneration test fails (P11). Benchmarks can fail under load (P14), rerun once.
- **media_kit jar download (Java can't reach one GitHub IP):** `media_kit_libs_android_video` downloads 4 libmpv jars from GitHub releases at Gradle configure time into `build/media_kit_libs_android_video/v1.1.7/`. From this network 185.199.109.133 (one of the four `release-assets.githubusercontent.com` IPs) times out; curl falls back to another IP, Java doesn't, so the build fails with "Connection timed out: connect" at the plugin's build.gradle line 83. Fix (2026-10-11): fetch `default-{arm64-v8a,armeabi-v7a,x86_64,x86}.jar` from `https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/` with `curl -L` into that folder; the plugin skips files whose MD5 matches (MD5s are in its build.gradle). Needed again after `flutter clean` or a fresh build dir. Don't edit the hosts file (system setting).
- **Gradle:** `./gradlew --stop` in one project kills the daemon of a concurrent build in another project. Never run it while another Gradle build is running.
- **Git identity here:** danavsi <317363190+danavsi@users.noreply.github.com> (global, 2026-10-11). The owner first asked for their work email, but GitHub's "block command line pushes that expose my email" setting rejected the push, so the owner chose the noreply address. The Mac uses besaoct.

**Why:** the hand-off assumed a fresh C:\dev setup; this machine differs in several ways that cost time to rediscover.
**How to apply:** source the env script in every command, use Medium_Phone for emulator checks that don't name an API level, and ask the owner before installing anything from the missing list.
