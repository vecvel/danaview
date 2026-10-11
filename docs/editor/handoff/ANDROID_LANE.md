# Android lane (Windows laptop): ticket plan

> Status 2026-10-11. Sources: `docs/editor/BUILD_PLAN.md` §1, §2, §5, §6, §7; `docs/editor/spikes/AND-01.md`; `docs/editor/ARCHITECTURE.md` §3.2, §4.4, §13.3–13.5, §14.3, §15, §20.4, §24.2.
> When sources disagree: ARCHITECTURE as updated by ENG-06 wins, then the rules in AND-01.md §6 and §7, then BUILD_PLAN §6, then this file. ENG-06 records the AND-01 rules in ARCH §13.3 before any AND ticket starts. Until then, AND-01 beats older ARCH and BUILD_PLAN text, for example AND-08's gaps (transparent images, not `addGap`), AND-16's ImageReader decks (not a SurfaceTexture) and AND-17's reference frame.
> Repo: github.com/vecvel/vwish. Windows branch: `editor-android`, created from `origin/editor-wip`.

## 1. Summary

The laptop builds the Android half of the editor's native engine inside the `vwish_editor_engine` plugin (`packages/vwish_editor_engine/android/`), plus the Android build of the on-device speech library (`packages/vwish_whisper`). That covers the plugin glue that connects Dart to Kotlin (ENG-08), the whisper `.so` build (AI-04), and the media services: probe, thumbnails, waveforms, speech audio, proxies, freeze frames and reverse (AND-02..07). It also covers the live preview: plan reader, GL effects, paused-frame renderer, preview session, and the contingency preview engine AND-16, which is active because AND-01 was a NO-GO for Media3's `CompositionPlayer`. Last come export, the export foreground service, the voice recorder, pickers and drag-and-drop (AND-11 to AND-15), then the render-preview renderer (AND-18) and the multi-pass export precompose (AND-19), both added by the owner's D-43(e) decision of 2026-10-11 (ARCH D-45). Everything is checked with Gradle builds, JVM unit tests and instrumented tests on the Android emulator. Anything that needs a real phone is written down as "deferred: no device available". The Mac builds everything else, including ENG-06, which freezes the plugin's Gradle file and glue after ENG-08. The Mac merges the laptop's branch.

## 2. Owner checklist (plain language)

1. **Install** the agreed tools: Git for Windows, Flutter 3.44.2, Java 21, Android Studio with SDK 36, NDK 27.0.12077973 and 28.2.13676358, CMake 3.22.1, the `Pixel_9_Pro_XL_API_35` emulator, ffmpeg and the Claude desktop app. The lane also needs:
   - **API 29 and API 34 AVDs** (`Pixel_API_29`, `Pixel_API_34`). AND-02 checks GLES 3 on API 29, and AND-12 tests the export service on API 29, 34 and 35.
   - **A tablet AVD** (`Pixel_Tablet_API_35`), for AND-15's manual drag test from the Files app.
   - **An ffmpeg build with libx264 and libx265**, for test media.
   - **The clone at `C:\dev\vwish_player`** (WINDOWS_SETUP A6). Claude's notes folder name comes from that path, and a short path avoids Windows path-length limits.
2. **Carry the gates between machines.**
   - Tell the Windows session when each of these lands on `editor-wip`: ENG-06, ENG-02, ENG-03, ENG-04. (ENG-09 and API-04 are already done.)
   - Tell the Mac session each time Windows reports a ticket pushed, so it can merge `editor-android`.
3. **AND-16 sign-off (D-43e): done, owner decision 2026-10-11** (ARCH D-43(e), D-45). Preview adapts to the device; export is always full quality and never refused, only slower on weak devices. Proxies are on by default on the minimal and low tiers; preview quality adapts full → 1/2 → 1/4 unless pinned; layers over the live decode budget show paused-exact stills during playback only; exact seek may be +30% on AND-16 (nearest frame first, then exact); frames are dropped rather than shown late or wrong; `maxVisualSequences` limits live preview only, and export above the device's decoder limit runs a multi-pass precompose (AND-19). Heavy ranges can be pre-rendered into a render-preview cache (AND-18). AND-16 no longer waits for a sign-off.
4. **ENG-08 belongs to Windows** (owner decision, 2026-10-11). The Mac's builders no longer include it.
5. **Optional.** The root app's Android build makes `media_kit_libs_android_video` download its libmpv jars from github.com (its own `build.gradle`; this is not pub or Maven). Windows will not build the root app unless you allow it. Only one AI-04 check needs that build ("no libc++_shared clash with media_kit"). Without your OK, the Mac covers it when INT-02 wires whisper into the app.

**For the Mac to settle in ENG-06** (Windows does not decide these):
- **AND-16 needs a ~60-line JNI shim** (HardwareBuffer → OES texture) built with CMake (AND-01 §6.3). No ticket owns `packages/vwish_editor_engine/android/src/main/cpp/`, and ENG-06 freezes `build.gradle.kts`. ENG-06 must add the `externalNativeBuild` block and assign the cpp directory before AND-16 starts.
- **`minSdk` conflict.** ENG-08's spec and ARCH §3.2 keep the plugin at minSdk 24: the app is minSdk 24 and gates the editor at runtime. AND-01 §6.3 says 29. ENG-08 ships 24, and ENG-06 decides.
- **Ignore `.cxx/`.** The root `.gitignore` covers `**/build/` but not `.cxx/`, where AGP stages CMake builds inside plugin modules. Add `**/.cxx/` before AND-16's shim build. AI-04 keeps its own staging folder under `build/`.
- **AND-01.md still has `{{…}}` measurement placeholders** from the Mac's final reruns. The NO-GO verdict and the rules in its §6 do not depend on them.

## 3. Working rules (Windows Claude session)

- **Repo scripts run in Git Bash:** `bash scripts/ci/editor/<script>.sh`.
- **Line endings.** `.gitattributes` keeps LF everywhere and marks fixtures `-text`. Check with `git ls-files --eol scripts/ci/editor/android_unit.sh`, which should print `i/lf w/lf`.
- **Edit only your ticket's `owns` paths** (§5 below, copied from BUILD_PLAN §6), plus files whose header says `// OWNER: <your ticket>`. Need a change in someone else's file? Report it as a defect against that ticket (BUILD_PLAN §1 rule 3) and tell the owner. Never edit:
  - `docs/editor/**`, `spikes/**`
  - `packages/vwish_editor_engine/{pigeons,lib,example,test_fixtures}/**`, except AND-10's one integration test file
  - the root `pubspec.yaml` and `android/app/**`
- **Never run `pigeon` or `tool/make_fixtures.swift`.** The generated code and fixtures belong to Mac tickets.
- **No downloads except pub, Gradle and Maven resolution.** Never download speech models or media. Generate test media locally (ffmpeg, or in code) inside your owned test directories. If a build tries to fetch an NDK, CMake, a system image or a GitHub file, stop and ask the owner.
- **Criteria that need a real device** are recorded as `deferred: no device available` with the emulator result, if there is one. Never fake them. Owner defaults (D-43):
  - the Android editor gate is API 29 + GLES 3 + 2 GB RAM;
  - no Auto captions on `armeabi-v7a`;
  - Android editor and speech data are excluded from backup.
- **Media3 files.** Every file that uses Media3 starts with `@file:OptIn(UnstableApi::class, ExperimentalApi::class)`; lint enforces it. Media3 is pinned at 1.11.1.
- **No logs of media paths, transcript text or user content** (BUILD_PLAN §1 rule 4).
- **Read before coding:** ARCHITECTURE §1–§4, the sections your ticket cites, and `docs/editor/spikes/AND-01.md` §6 ("What ENG-06 must apply"). The spike code in `spikes/android_engine/` is a working reference for AND-08/09/10/16/17. Read it and port from it; do not edit it.
- **One builder group at a time** (the workflow's default `maxParallel: 1`). Groups share one emulator and one working tree.
- **Git:**
  - one commit per ticket on `editor-android`, then push;
  - no `Co-Authored-By` trailer;
  - never push to `editor-wip`;
  - receive Mac gates with `git merge origin/editor-wip`.

## 4. Ticket order and gates

Statuses: **DONE** means finished and on `origin/editor-wip`. **MAC (pending)** means the Mac still has to land it on `editor-wip`. **WINDOWS** means this lane.

Verification keys:
- **GRADLE**: the example host builds the plugin (`flutter build apk` inside `android_unit.sh`).
- **JVM**: `:vwish_editor_engine:testDebugUnitTest`.
- **EMU**: `:vwish_editor_engine:connectedDebugAndroidTest` on the API 35 emulator. Run the ticket's test package first, then the full `android_emulator.sh`.
- **IT**: an example `integration_test/` run on the emulator.
- **LINT**: `:vwish_editor_engine:lintDebug`.
- **NDK**: the whisper native build plus `check_native_libs.sh` on an AAB.

Commands are in §9.

| # | Ticket | Title | M | Depends on | Can start when | Group | Verification |
|---|---|---|---|---|---|---|---|
| 1 | AI-04 | whisper Android native build | M2 | AI-03 DONE | Now (AI-03's `packages/vwish_whisper/src/` is on `origin/editor-wip`) | ai-android | NDK, whisper JVM tests via a scratch host, `flutter_packages.sh vwish_whisper` |
| 2 | ENG-08 | Android plugin glue, engine core, Gradle, manifest and native service placeholders | M0 | ENG-09 DONE | Now (ENG-09's `example/android/` is on `origin/editor-wip`) | eng08 | GRADLE, JVM, LINT (plus a negative fixture), EMU + `engine_smoke_test.dart` |
| 3 | AND-02 | Android probe, compatibility, device profile, capabilities | M2 | ENG-06 MAC (pending), ENG-05 DONE | ENG-06 merged into `editor-android` | and-m2a | JVM, EMU on API 35 and API 29 |
| 4 | AND-03 | Android thumbnails and disk cache | M2 | AND-02 WINDOWS | AND-02 committed | and-m2a | JVM, EMU |
| 5 | AND-04 | Android PCM decoder, waveforms, speech audio extraction | M2 | AND-02 WINDOWS | AND-02 committed | and-m2a | JVM, EMU |
| 6 | AND-05 | Android job registry, proxy job and registry | M2 | AND-02 WINDOWS | AND-02 committed | and-m2a | JVM, EMU |
| 7 | AND-06 | Android freeze frame and source-frame cache | M2 | AND-05 WINDOWS | AND-05 committed | and-m2b | JVM, EMU |
| 8 | AND-07 | Android reverse rendition job | M2 | AND-05 WINDOWS | AND-05 committed | and-m2b | JVM, EMU |
| 9 | AND-08 | Android plan reader, ParamSnapshot, composition mapper, gating, speed and gain providers | M3 | ENG-06 MAC (pending); CORE-29, CORE-32, API-03 DONE | ENG-06 merged | and-m3-render | JVM, EMU |
| 10 | AND-09 | Android GL effects, shaders, LUT and sprite textures | M3 | ENG-06 MAC (pending); API-03, API-04, CORE-21 DONE | ENG-06 merged | and-m3-text | JVM, EMU (GL, parity goldens) |
| 11 | AND-17 | Android paused-frame renderer, layer GL compositor and structural debounce | M3 | AND-08, AND-09, AND-06 WINDOWS | All three committed | and-m3-paused | EMU |
| 12 | AND-10 | Android preview session: SurfaceProducer, clock, seek/scrub, transients, redraw, quality, lifecycle | M3 | AND-08, AND-09, AND-06, AND-17 WINDOWS; ENG-02 MAC (pending) | AND-17 committed **and** ENG-02 merged | and-m3-preview | EMU, IT `android_preview_test.dart` |
| 13 | AND-16 | Android contingency preview engine (active: AND-01 NO-GO) | M3 | AND-10, AND-17 WINDOWS; activation by ENG-06 MAC (pending); owner sign-off D-43e DONE (2026-10-11) | AND-10 committed **and** ENG-06 has activated AND-16 **and** ENG-06 has settled the JNI shim's Gradle and cpp ownership (§2). The lead then adds `AND16-SHIM` to the workflow's `landed` | and-m3-fallback | EMU, IT (AND-10's playback list through this backend) |
| 14 | AND-13 | Android voice recorder | M4 | ENG-03 MAC (pending) | ENG-03 merged | and-m4-services | EMU |
| 15 | AND-14 | Android pickers, URI grants (media access), permissions | M4 | ENG-03 MAC (pending) | ENG-03 merged | and-m4-services | EMU (API 35, so API 33+ permission flows run) |
| 16 | AND-15 | Android external drop target | M4 | ENG-03 MAC (pending) | ENG-03 merged | and-m4-services | EMU, plus a manual check on the tablet AVD |
| 17 | AND-11 | Android export: coordinator, Transformer, encoder settings, hardware selector, active store | M4 | AND-09, AND-08, AND-10 WINDOWS; ENG-04 MAC (pending) | AND-10 committed **and** ENG-04 merged | and-m4-export | JVM, EMU |
| 18 | AND-12 | Android export foreground service, notification, background guard, MediaStore, file handoff | M5 | AND-11 WINDOWS | AND-11 committed | and-m5 | EMU on API 29, 34 and 35 (UiAutomator) |
| 19 | AND-18 | Android render-preview renderer and playback swap-in | M4 | AND-16, AND-10 WINDOWS; INT-06 MAC (pending) | AND-16 committed **and** INT-06 merged. INT-06 is the Mac [INTEGRATION] ticket that adds the Pigeon/glue calls AND-18 is reached through (`renderPreview` job kind, `setRenderedRanges`, power signal; ARCH D-45, §12.6) and leaves `// OWNER: AND-18` placeholders in `preview/render/` | and-m4-rpreview | JVM, EMU |
| 20 | AND-19 | Android multi-pass export precompose | M4 | AND-11 WINDOWS | AND-11 committed | and-m4-precomp | JVM, EMU |

How groups map to builder agents:
- The Group column is the group id in `android_lane_workflow.js` (pass it in the workflow's `only` argument to run one group). Each group is one builder agent and runs its tickets in the order listed.
- and-m4-rpreview (AND-18) also waits for INT-06 (Mac): the engine interface additions for render preview.
- and-m4-services needs only ENG-06 and ENG-03. Run it whenever ENG-03 arrives, even before the M3 groups.
- Everything from AND-02 on waits for ENG-06. ENG-06 in turn waits for ENG-08 (Windows), ENG-07, IOS-01 and AND-01 (all Mac). ENG-08 is therefore the lane's most urgent ticket.

## 5. Tickets: owned files, shared files, acceptance criteria

Every `AND-xx` main-source file below starts as a `// OWNER: AND-xx` placeholder that ENG-08 creates (D-33). The ticket replaces that placeholder; test directories start empty. §7 shared files come up only where listed.

### AI-04 · whisper Android native build (ai-android)

```
packages/vwish_whisper/android/build.gradle.kts
packages/vwish_whisper/android/src/main/AndroidManifest.xml
packages/vwish_whisper/src/cmake/android.cmake
packages/vwish_whisper/src/vw_exports.map
scripts/ci/editor/check_native_libs.sh
```

**§7 files:** none. Two files need care even so:
- AI-06 (Mac, done) already added lines to the two files above: `testImplementation("junit:junit:4.13.2")` and `ACCESS_NETWORK_STATE`. Keep both.
- `packages/vwish_whisper/src/CMakeLists.txt` belongs to AI-03. It already `include()`s `cmake/android.cmake` when `ANDROID OR VW_ANDROID`. Do not edit it.

**Build (ai.md §4.3):**
- `externalNativeBuild` points at `../src/CMakeLists.txt` with CMake `3.22.1`.
- ABIs: `arm64-v8a` and `x86_64` only, never `armeabi-v7a`.
- Arguments: `-DANDROID_STL=c++_static -DVW_ANDROID=ON`.
- Libraries: `libvwish_whisper.so` (armv8-a, plus x86_64) and `libvwish_whisper_v82.so` (armv8.2-a+fp16+dotprod, arm64 only).
- Link flags: 16 KB pages, `--version-script=vw_exports.map`, `--gc-sections`.
- Compiler: `-O3`, no OpenMP, `GGML_NATIVE=OFF`.
- `GGML_CPU_KLEIDIAI=OFF`: KleidiAI fetches sources at build time, which is a forbidden download.
- Pin `ndkVersion` to an installed NDK. Flutter 3.44.2's default is 28.2.13676358, which the spike also uses.
- Set `buildStagingDirectory` under the module's `build/` folder. The root `.gitignore` doesn't cover `.cxx/`, so the default staging folder would show up in `git status`.

**`check_native_libs.sh`** must run under bash 3.2 (macOS), Ubuntu CI and Git Bash. It finds `llvm-readelf` under the NDK's `toolchains/llvm/prebuilt/{darwin-x86_64,linux-x86_64,windows-x86_64}/bin` (`.exe` on Windows). It follows the script contract in `scripts/ci/editor/README.md`.

**Acceptance criteria:**
- The AAB contains exactly the expected `.so` files.
- The 16 KB LOAD alignment and "only `vw_*` exported" checks pass.
- Each `.so` is ≤ 3 MB.
- The build works with SDK CMake 3.22.1, or the pinned version is documented (V-A8, answered in the commit body).
- No `libc++_shared` conflict with media_kit. This needs a root-app build; see owner item 5. Otherwise record it as "checked by the Mac in INT-02".

**How to verify:**
- Build a throwaway Flutter app **outside the repo** that has a path dependency on `packages/vwish_whisper`.
- Run `flutter build appbundle` on it, then `check_native_libs.sh` on the AAB.
- Run `./gradlew :vwish_whisper:testDebugUnitTest` from its `android/`. This keeps AI-06's JVM tests green.

On-device loading is AI-07's (Mac), not AI-04's.

### ENG-08 · Android plugin glue, engine core, Gradle, manifest and native service placeholders (eng08)

```
packages/vwish_editor_engine/android/build.gradle.kts
packages/vwish_editor_engine/android/lint.xml
packages/vwish_editor_engine/android/src/main/AndroidManifest.xml
packages/vwish_editor_engine/android/src/main/res/xml/vwish_editor_file_paths.xml
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/VwishEditorEnginePlugin.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/glue/
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/core/EngineContext.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/core/ErrorCodes.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/core/EventHub.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/core/EngineThreads.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/core/Paths.kt
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/glue/
```

**§7 files:**
- `build.gradle.kts`, `AndroidManifest.xml`, `VwishEditorEnginePlugin.kt`, `glue/` and `lint.xml` all follow the order ENG-01 (placeholder) → **ENG-08** → ENG-06 (Mac), then freeze.
- `pigeon/EngineApi.g.kt` is ENG-01/ENG-06's: use it, never regenerate it.
- Also creates the placeholders for every Android service file of ARCH §4.4, AND-02..AND-17. That includes `preview/{PausedFrameRenderer,LayerCompositorGl,StructuralDebouncer}` and an AND-16 placeholder in `preview/fallback/`. Each placeholder returns `notSupportedOnDevice` and carries a `// OWNER: AND-xx` header.

**Spec points:**
- Glue for the 6 host APIs plus `EngineEventsStreamHandler` (ARCH §12.6). Handlers validate, hop to the engine threads, reply asynchronously and never block.
- `EngineThreads`: `vwish-preview`, `vwish-gl`, `vwish-export`, `vwish-jobs`, `vwish-io`.
- Gradle: minSdk 24; Media3 1.11.1 (`common`, `exoplayer`, `effect`, `transformer`, `muxer`, `inspector`, `inspector-frame`); `concurrent-futures`; `activity`.
- `lint.xml`: make `UnstableApi` and `ExperimentalApi` opt-in-required errors. The AND-01 spike's `app/lint.xml` is proven.
- Manifest per ARCH §20.4.
- **Declare every dependency the lane needs now** (BUILD_PLAN §2), because the file freezes at ENG-06. That includes the test dependencies the example harness doesn't add:
  - `androidx.test:rules` (permission rules, AND-13 and AND-14);
  - `androidx.test.uiautomator` (required by AND-12's criteria).

  List any other dependency you expect in the commit body.
- Leave the JNI and `externalNativeBuild` block to ENG-06 (§2).

**Acceptance criteria:**
- `capabilities()` round-trips on the emulator through the example host (`android_emulator.sh` runs `engine_smoke_test.dart`).
- The glue JVM tests are green.
- Lint fails on a negative fixture that lacks the opt-in. Keep that fixture inside the owned paths.
- V-N14 (activity and concurrent-futures versions vs AGP 9.0.1 and Kotlin 2.3.20) is recorded in the commit body.
- The example app's manifest merge is clean.
- No device-only criteria.

### AND-02 · Android probe, compatibility, device profile, capabilities (and-m2a)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/media/Probe.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/media/Compatibility.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/core/DeviceProfile.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/core/Capabilities.kt
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/probe/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/probe/
```

**§7 files:** none.

**Acceptance criteria:**
- Probe fields are correct on the ENG-05 fixtures, including MKV and WebM (EMU).
- Gate unit tests cover `android_too_old`, `gles3_missing` and `insufficient_memory`.
- Tier-table tests use injected profiles, including `minimal`.
- The GLES 3 check passes on an **API 29 emulator**.
- `maxTextureSize` is read on the emulator.

**Rules from AND-01:**
- HDR is editable only with `GL_EXT_YUV_target` plus a 10-bit decoder. Otherwise use MediaCodec tone mapping (API 31+) or the automatic SDR proxy (V-N5).
- `maxVisualSequences` tiers are 2/3/4/6, capped at `(codec instances − 2) / 2`. Take the values ENG-06 writes into ARCH.
- `fpsUpconversion = true` (V-N15).

**Deferred: no device available:**
- V-N7, a GLES 3 context on a real low-tier API 29 device.
- The HDR tone-map path. The emulator has no HEVC Main10 decoder and no `GL_EXT_YUV_target`; re-check what the Windows emulator reports.

### AND-03 · Android thumbnails and disk cache (and-m2a)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/media/ThumbnailService.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/media/DiskCache.kt
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/thumbs/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/thumbs/
```

**§7 files:** none.

**Acceptance criteria:**
- Tile frames on `frame_counter` are correct, checked by barcode, with the sync-frame tolerance documented.
- A cache hit takes ≤ 20 ms.
- Cancel works.
- The LRU cap holds.
- The `work/` wipe exemptions match IOS-03.

**Deferred: no device available:** a miss takes ≤ 400 ms on the low tier (QA-04).

### AND-04 · Android PCM decoder, waveforms, speech audio extraction (and-m2a)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/media/PcmDecoder.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/media/WaveformService.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/media/SpeechAudioExtractor.kt
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/audio/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/audio/
```

**§7 files:** none.

**Acceptance criteria** (the same as IOS-04):
- Peaks match the reference.
- The `.vwpk` and 16 kHz s16 mono WAV formats are correct.
- Duration is within ±1 ms.
- The clap lands within ±20 ms, including the edit list and AAC priming (V-A6, answered in the commit body).
- The 5.1 centre channel is kept.
- Unsupported codecs return `unsupportedMedia`.

**Deferred: no device available:** ≥ 60× real time on a mid-tier device. Record the emulator figure as indicative only.

### AND-05 · Android job registry, proxy job and registry (and-m2a)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/core/JobRegistry.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/media/ProxyJob.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/media/ProxyRegistry.kt
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/proxy/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/proxy/
```

**§7 files:** none.

**Acceptance criteria:**
- Proxy PTS equal the source PTS on the VFR fixture.
- The job is paused during export (tested with a fake coordinator).
- Cancel cleans up: `.part` files are removed.

**Deferred: no device available:** HDR → SDR. `hlg_10bit_720p.mov` is HEVC Main10, which the emulator can't decode.

### AND-06 · Android freeze frame and source-frame cache (and-m2b)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/media/FreezeFrameJob.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/preview/SourceFrameCache.kt
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/freeze/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/freeze/
```

**§7 files:** none.

**Acceptance criteria:**
- The still's barcode equals the requested frame (FrameExtractor EXACT).
- `sampleColor` is within ±2/255.
- Memory stays bounded.
- Look stills stay unprocessed until AND-09 lands.

All of this is emulator-verifiable.

### AND-07 · Android reverse rendition job (and-m2b)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/media/ReverseJob.kt
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/reverse/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/reverse/
```

**§7 files:** none.

**Acceptance criteria:**
- The barcode is strictly decreasing.
- Duration is within ±1 frame.
- Clicks are mirrored within ±20 ms.
- Peak `work/` size is ≤ one chunk plus the output.
- The memory bound matches IOS-07.
- Preflight refuses ranges over 10 min and low free space.
- Cancel cleans `work/`.

All of this is emulator-verifiable.

### AND-08 · Android plan reader, ParamSnapshot, composition mapper, gating, speed and gain providers (and-m3-render)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/plan/
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/composition/
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/composition/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/composition/
```

**§7 files:** none.
- Reads `packages/vwish_editor_core/test/fixtures/vectors/frame_grid.json`, read-only. Its `androidSeekMsRounding` field is written by ENG-06 (`"floor"` per AND-01).
- Reads the core contract fixtures.

**Acceptance criteria:**
- Every contract fixture maps.
- Sequence durations equal `durUs`, and every item and gap boundary equals P(k) exactly (frame_grid vectors at 24/25/30/48/50/60).
- `grid_cuts_30fps.json` gating matches `expected_active.json` on every frame.
- Sequence count equals slot count.
- A no-audio plan still yields an audio track.
- The z-order unit tests pass.
- `SegmentSpeedProvider` is within ±1 µs.
- The gain envelope is sample-exact.
- The classification vectors pass.

**Rules from AND-01 §6.7:**
- Gaps are transparent image items at the output fps, not `addGap`.
- Clip starts use `SNAP_TO_RULE_FRAME`.
- Items faster than 1× get `setFrameRate(gridFps)`.
- `setDurationUs` is the full source duration.

**Test note:** `android.util.JsonReader` doesn't work in JVM unit tests (android.jar stubs). Test plan decoding in androidTest, or keep the pure-Kotlin logic separately testable.

**Deferred: no device available:** 2,000-item mapping ≤ 150 ms on a mid-tier device.

### AND-09 · Android GL effects, shaders, LUT and sprite textures (and-m3-text)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/effects/
packages/vwish_editor_engine/android/src/main/assets/vwish_shaders/
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/effects/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/effects/
```

**§7 files:** none. Reads API-03's vectors and goldens and API-04's `.vsprite` format.

**Acceptance criteria:**
- The render-math vectors and the API-03 parity goldens pass on the API 35 emulator within tolerance, including the 8× scale-keyframed case.
- A gated frame costs one clear (GL timer query).
- The GL leak test passes.
- Expose a `ShaderPrograms` API for AND-17.

**Deferred: no device available:** 1080p compose ≤ 8 ms on a mid-tier device (QA-04).

### AND-17 · Android paused-frame renderer, layer GL compositor and structural debounce (and-m3-paused)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/preview/PausedFrameRenderer.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/preview/LayerCompositorGl.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/preview/StructuralDebouncer.kt
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/paused/
```

**§7 files:** none.

**Acceptance criteria:**
- The paused frame matches the composed frame within the ARCH §11.6 tolerance. Because of the NO-GO, the reference frame cannot come from `CompositionPlayer`. Suggested reference: the Transformer export of the same plan, stated in the commit body.
- A secondary-sequence effect change while paused updates the frame.
- The debounce turns 10 structural patches in 1 s into ≤ 3 rebuilds.
- GL resources are released on dispose.

**Port from** `spikes/android_engine/.../PausedFrameRendererProto.kt`. With any player, detach with `clearVideoSurface(surface)`: the no-argument overload throws in 1.11.1.

**Deferred: no device available:** transient ≤ 2 frames on mid; paused structural edit ≤ 250 ms on mid and ≤ 400 ms on low. Record the emulator numbers.

### AND-10 · Android preview session (and-m3-preview)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/preview/PreviewSession.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/preview/PreviewSessionManager.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/preview/SurfaceBridge.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/preview/SeekController.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/preview/QualityGovernor.kt
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/preview/
packages/vwish_editor_engine/example/integration_test/android_preview_test.dart
```

**§7 files:** none. The integration test sits inside ENG-09's (Mac) `example/`; touch nothing else there.

**Scope on NO-GO:** this ticket ships the `PreviewSession` shell, the `PreviewBackend` interface, `SurfaceBridge` (resetInBackground, ≤ 500 ms latch), seek, quality and the session manager. Its **playback** criteria are met through AND-16 (BUILD_PLAN AND-10 spec).

**Acceptance criteria:**
- **Hand back now:**
  - `seq` semantics;
  - surface loss recovers;
  - the latch never takes > 500 ms;
  - a rebuild keeps the last frame;
  - paused edits go through AND-17.
- **Re-run when AND-16 lands:**
  - exact seek ack 200/200, including every frame around the grid cuts at 24/30/60 fps;
  - scrub coalescing;
  - transient ≤ 2 frames while paused;
  - A/V offset ≤ 1 frame and ≤ 40 ms (V-N23).

**Deferred: no device available:** the mid and low latency budgets of ARCH §13.4.

### AND-16 · Android contingency preview engine (and-m3-fallback, active)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/preview/fallback/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/fallback/
```

**§7 files:**
- The JNI shim and its Gradle `externalNativeBuild` are outside these owns. Wait for ENG-06 (§2).
- Uses AND-17's `LayerCompositorGl` and AND-10's `PreviewBackend` without editing them.

**Design:** follow AND-01 §2 and §7.
- Two decks per packing slot, each an ExoPlayer with a PRIVATE ImageReader → OES texture.
- A Choreographer frame clock with a 2-frame lead and the hold/miss rule.
- Audio slots with a signed sink offset.
- Structural re-plan by slot diff.

**Size:** about 1,700–2,100 lines of Kotlin plus about 800 lines of tests. Split it inside the owned directories (BUILD_PLAN §1 rule 2). Port from `ContingencyEngineProto.kt` and `ContingencyEngineTest.kt`.

**Acceptance criteria:**
- AND-10's playback list passes through this backend.
- The frame-grid and grid-cut barcode cases pass.
- The A/V offset stays ≤ 1 frame over 10 min.

**Deferred: no device available:** transitions and video-over-video PiP at 30 fps with ≤ 2% dropped on the mid device.

**Owner decision 2026-10-11 (D-43(e); BUILD_PLAN AND-16 amended criteria):**
- Layers beyond the tier's live decode budget play as paused-exact stills during playback only; paused, scrub and exact seek are exact for every layer (barcode test).
- An exact seek while playing may show the nearest decoded frame first, then refines; it acks only the exact frame, within +30% of ARCH §13.4.
- Under injected load frames are dropped, never late or wrong.
- Adaptive quality steps full → 1/2 → 1/4 under load and recovers (degraded/recovered events); a pinned quality never changes.
- Provide a `RenderedRangeHook` (no-op by default) inside `preview/fallback/` for AND-18, called at range boundaries (test double).

### AND-13 · Android voice recorder (and-m4-services)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/recording/VoiceRecorder.kt
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/recording/
```

**§7 files:** none. `RECORD_AUDIO` is already in ENG-08's manifest.

**Acceptance criteria:**
- The WAV format is verified (s16, 48 kHz, mono).
- An interruption (audio-focus loss) keeps a valid file.
- The denied and permanently-denied permission states work.
- Start latency is reported.

**Deferred: no device available:** removing a real input device (headset or Bluetooth).

### AND-14 · Android pickers, URI grants (media access), permissions (and-m4-services)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/platform/MediaPicker.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/platform/MediaAccess.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/platform/Permissions.kt
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/platform/
```

**§7 files:** none.

**Acceptance criteria:**
- V-D2: Photo Picker URIs persist across relaunch, or the managed-copy fallback is selected.
- The grant budget is computed (512 on API 30+, 128 before).
- `quickHash` equals the core fixtures.
- The permission flows work on API 33+.

All of this is emulator-verifiable.

### AND-15 · Android external drop target (and-m4-services)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/platform/DropTarget.kt
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/drop/
```

**§7 files:** none.

**Acceptance criteria:**
- Synthesized DragEvents carry ClipData from a test ContentProvider: video, audio, image, `.cube` and unsupported URIs. Check the items, the copies into `work/drops/` and the positions.
- Permissions are released after the copy.
- Disabling works.
- **Manual:** a cross-app drag from Files on the **tablet AVD**, with recorded evidence (repeated in QA-02).

### AND-11 · Android export (and-m4-export)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/export/ExportCoordinator.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/export/TransformerExport.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/export/EncoderSettings.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/export/HardwareEncoderSelector.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/export/ActiveExportStore.kt
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/export/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/export/
```

**§7 files:** none.

**Acceptance criteria:**
- MP4 H.264 and HEVC pass conformance on the emulator, including the `hvc1` tag (V-N13).
- No-audio, all-muted and images/text-only fixtures produce a silent **AAC 48 kHz stereo** track (V-N24). AND-01 found the clock band gives 44.1 kHz, so keep `SonicAudioProcessor(48 kHz)` in the composition effects.
- An export with gridFps 30 and fps 24 passes.
- A/V offset is ≤ 1 frame and ≤ 20 ms.
- The portrait retry path works with an injected refusal.
- The error-mapping tests pass.
- A software or fallback encoder raises the preflight/progress warning (tested with an injected codec list).
- The export reports `interrupted` after a process kill.

**Deferred: no device available:** hardware-encoder preference against real hardware codecs. Test the selector logic with injected codec lists.

**Owner decision 2026-10-11 (D-45; BUILD_PLAN AND-11 amended):** preflight never refuses for sequence or layer counts. When the packed export plan needs more decoders than the device allows, `ExportCoordinator` hands the job to a `MultiPassExport` hook (interface in AND-11's coordinator, implemented by AND-19) instead of failing; test the routing with a test double.

### AND-12 · Android export foreground service, notification, background guard, MediaStore, file handoff (and-m5)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/export/ExportService.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/export/ExportNotification.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/platform/BackgroundGuard.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/platform/MediaStoreSaver.kt
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/platform/FileHandoff.kt
packages/vwish_editor_engine/android/src/main/res/drawable/vwish_export_notification.xml
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/service/
```

**§7 files:** none. The `ExportService` and `FileProvider` entries live in ENG-08's frozen manifest. If they are wrong, report a defect; do not edit the manifest.

**Acceptance criteria:**
- Export continues with the activity destroyed.
- Swiping the app from recents mid-export ends with the video in the Gallery and a `completedWhileDetached` record, offered once on relaunch (UiAutomator).
- The notification's Cancel button cancels.
- The FGS types are correct on the **API 29, 34 and 35** emulators.
- The lease lifecycle works.
- The gallery insert is visible in Photos.
- The share intent grants read access only to the chosen target.

### AND-18 · Android render-preview renderer and playback swap-in (and-m4-rpreview)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/preview/render/
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/render/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/render/
```

**§7 files:** none. It is called through `JobKindMsg.renderPreview`, `PreviewHostApi.setRenderedRanges` and the power signal (`powerState`), which the Mac's INT-06 ([INTEGRATION]) adds to the frozen Pigeon surface and glue (ARCH D-45, §12.6); AND-18 depends on INT-06 and starts only after it is merged. INT-06 leaves `notSupportedOnDevice` placeholders headed `// OWNER: AND-18` in `preview/render/` (the render-preview job service, the rendered-range handler and the power signal); replace them, keeping their names and signatures. Never edit Pigeon or glue files; a signature mismatch is a defect report against INT-06. Never edit AND-16's, AND-10's or AND-11's files: plug into AND-16's `RenderedRangeHook`.

**Design:** ARCH D-45 and §13.3 'Over-budget layers and the render-preview cache'.
- `RenderPreviewJob` (AND-05's job registry): a `Transformer` export of the range plan through AND-08's mapper at the preview canvas size and project fps into `<cache>/vwish/editor/renders/`, H.264 all-intra or ≤ 0.5 s GOP, video only; cancel deletes the partial file; thermal `SEVERE` pauses; never runs during an export.
- `RenderedRangeSwap`: during playback one deck plays the cached file in place of every slot of the range, pre-rolled like a standby deck, switched at the range's exact frame boundaries under the hold/miss rule. Paused, scrub and exact seek keep the normal decks. A patch touching a range drops it until the next `setRenderedRanges`.

**Acceptance criteria:**
- A rendered range matches live composition at preview size (barcode exact, SSIM ≥ 0.99).
- 0 wrong frames across range boundaries at 24/30/60 fps.
- A param patch inside a range falls back to live on the next frame.
- Cancel and process death leave no partial file in the index.
- Export plans never reference render files.

**Deferred: no device available:** the minimal/low-tier smoothness numbers on real devices (QA-04). Record emulator numbers for a 6-layer chroma-key range.

### AND-19 · Android multi-pass export precompose (and-m4-precomp)

```
packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/export/precompose/
packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/precompose/
packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/precompose/
```

**§7 files:** none. Plug into AND-11's `MultiPassExport` hook; never edit AND-11's files (a missing hook is a FIX-AND-11 request).

**Design:** ARCH D-45(B) and §14.3 'Multi-pass precompose'. Replaces "export refuses until reduced".
- `PrecomposePlanner`: from the packed export plan and `maxVisualSequences` / codec `maxSupportedInstances` − 2, decide how many bottom slots each pass renders.
- `PrecomposePass`: a video-only `Transformer` export of the background plus those slots (AND-08 mapper, `target = export`, same frame processor, HDR mode and working colour space) at the export size to `work/export-<jobId>/pre-<n>.mp4`, all-intra or ≥ 4× the export bitrate. Repeat until the rest fits; the final pass uses the intermediate as an ordinary bottom layer on the export frame grid and mixes audio once.
- One progress fraction over all passes; cancel, failure and process death delete intermediates; disk preflight counts them; AND-12's service covers every pass.

**Acceptance criteria:**
- A precomposed export equals a single-pass export of the same plan: SSIM ≥ 0.995 per frame, grid-cut barcodes 100% at 24/30/60 fps, identical frame count, audio within the QA-11 tolerances.
- With `maxVisualSequences` forced to 2, a 6-slot project exports instead of being refused.
- HDR/tone-mapped and rotated sources match single pass.
- Cancel during each pass leaves no intermediates.
- JVM tests for the planner (slot split, disk estimate).

## 6. Start now

These can run before any Mac gate:

1. **Owner setup** (§2, item 1).
2. **Branch**, once the Mac's hand-off push is on `origin/editor-wip`:
   `git fetch origin && git switch -c editor-android origin/editor-wip && git push -u origin editor-android`.
3. **Toolchain check.** Run WINDOWS_SETUP.md Part B (B1–B9). The AND-01 spike is used only for B7; don't run its media or emulator scripts on Windows (P16).
4. **AI-04 (ai-android).** Its only dependency, AI-03, is done.
5. **ENG-08 (eng08).** ENG-09's `example/android/` is already on `origin/editor-wip`. Merge `origin/editor-wip` in first, then run `bash scripts/ci/editor/android_unit.sh` and `android_emulator.sh` once on the untouched tree to confirm the example host works on Windows. This is the first Android run of `engine_smoke_test.dart`: if the instrumented tests pass and only the smoke step fails, report it to the Mac as an ENG-09 defect with the error, and continue.

Nothing else can start until ENG-06. Do not start AND tickets against the unfrozen Gradle file and glue.

## 7. Conflict hot-spots

| Path | Who edits, in order | Rule for Windows |
|---|---|---|
| `packages/vwish_editor_engine/android/build.gradle.kts`, `android/lint.xml` | ENG-01 → **ENG-08 (Windows)** → ENG-06 (Mac), then frozen | Edit only in ENG-08. After that, every dependency, NDK, CMake or test-dependency need goes to the owner as a request for the Mac. |
| `android/src/main/AndroidManifest.xml`, `.../engine/VwishEditorEnginePlugin.kt`, `.../engine/glue/` | ENG-01 → **ENG-08** → ENG-06 (glue amendments), then frozen → INT-06 (Mac, [INTEGRATION]: `renderPreview` job kind, `setRenderedRanges`, `powerState`) | Edit only in ENG-08. Service tickets implement the classes the glue already calls. A signature mismatch is a defect report, not an edit. |
| `pigeons/`, `lib/src/pigeon/`, `lib/src/mobile_editor_engine.dart`, `android/.../engine/pigeon/` | ENG-01 → ENG-06 (Mac only) | Read-only. Never regenerate. |
| `ENG-08` placeholders (`// OWNER: AND-xx`) | ENG-08 creates them → ENG-06 may update them with Pigeon amendments → the AND ticket replaces them | Merge `origin/editor-wip` after ENG-06 before starting any AND ticket. |
| `packages/vwish_editor_core/test/fixtures/vectors/frame_grid.json` | CORE-02 → ENG-06 (`androidSeekMsRounding` only) | Read-only (AND-08 and AND-10 read it). |
| `docs/editor/ARCHITECTURE.md` | INT-01 → ENG-06 → INT-05 (Mac) | Read-only. Put V-item answers in the commit body; the Mac records them. |
| `packages/vwish_whisper/android/build.gradle.kts`, `.../src/main/AndroidManifest.xml` | AI-02 skeleton → AI-06 lines (Mac, done) → **AI-04** | Keep AI-06's `junit` and `ACCESS_NETWORK_STATE` lines (both are on `origin/editor-wip`). |
| `packages/vwish_whisper/src/CMakeLists.txt` | AI-03 (Mac) | Read-only. AI-04 works through `src/cmake/android.cmake`. |
| `packages/vwish_editor_engine/example/**`, `scripts/ci/editor/{android_unit,android_emulator}.sh` | ENG-09 (Mac) | Read-only. The one exception is AND-10's `example/integration_test/android_preview_test.dart`. |
| `packages/vwish_editor_engine/test_fixtures/media/` | ENG-05 (Mac; generated with Swift and AVFoundation) | Read-only. Windows can't regenerate it. Ask the Mac for new shared fixtures, or generate ticket-local ones inside owned test directories. |
| `android/src/main/cpp/` (AND-16's JNI shim) | unowned; ENG-06 decides | Don't create it until ENG-06 assigns it. |
| `spikes/android_engine/`, `docs/editor/spikes/AND-01.md` | AND-01 (Mac, final reruns) | Read-only reference. |
| Root `pubspec.yaml`, `lib/`, `android/app/**` | INT-02, INT-04, INT-05, CORE-28 (Mac) | Never commit. A local verification edit (owner item 5) must be reverted with `git restore`. |
| `docs/editor/BUILD_PLAN.md`, `docs/editor/handoff/` | Mac | Read-only. Send corrections through the owner. |

## 8. Hand-back checklist (every ticket)

1. **Gates.** `git fetch origin && git merge --no-edit origin/editor-wip` ran before starting, and every dependency in §4 is satisfied.
2. **Tests green.** Use the ticket's verification column in §4 (commands in §9):
   - the ticket's JVM tests;
   - the ticket's androidTest package on the API 35 emulator (plus API 29 or 34 where listed);
   - then the full `scripts/ci/editor/android_unit.sh` and `scripts/ci/editor/android_emulator.sh` (no regressions);
   - `lintDebug` clean;
   - `bash scripts/ci/editor/flutter_packages.sh vwish_editor_engine` (or `vwish_whisper` for AI-04).
3. **Ownership.** Stage owned paths explicitly; never `git add -A`. After committing, `git show --name-only --format= HEAD` lists only paths from the ticket's owns in §5, or files whose header names the ticket. `git status --porcelain` shows no leftover edits to files you don't own.
4. **Content.**
   - Media3 opt-in on every Media3 file.
   - No path or user content in logs.
   - Public Kotlin APIs are documented.
   - The `// OWNER:` placeholder header is gone from files you replaced.
5. **Commit message:**
   - Subject: `feat(editor): <TICKET> <title>`, using the title from §4, e.g. `feat(editor): AND-03 Android thumbnails and disk cache`.
   - Body: the tests run with their results, the emulator (AVD and API), measured numbers, V-items answered, and each `deferred: no device available` item.
   - **No `Co-Authored-By` trailer.** `git log -1 --format=%B | grep -i co-authored-by` must print nothing; amend before pushing if it does.
6. **Push.** `git push origin editor-android`. Never push to `editor-wip`. If you need a fix after pushing, add `fix(editor): <TICKET> <what>` instead of rewriting history.
7. **Tell the owner:** "`<TICKET>` landed on editor-android at `<short sha>`. Deferred: … Needs from Mac: …" The Mac session then merges `editor-android` into `editor-wip`.

## 9. Commands (Git Bash)

```bash
# Once, in ~/.bashrc: SDK path in Git Bash form
export ANDROID_HOME="$(cygpath -u "${ANDROID_HOME:-$LOCALAPPDATA/Android/Sdk}")"
export PATH="$ANDROID_HOME/platform-tools:$PATH"

# Gate checks (read-only)
git fetch origin
git cat-file -e origin/editor-wip:packages/vwish_whisper/src/vw_whisper.cpp && echo "AI-03 present (AI-04 can start)"
git cat-file -e origin/editor-wip:packages/vwish_editor_engine/example/android/vwish_test_harness.gradle && echo "ENG-09 present (ENG-08 can start)"
git show origin/editor-wip:packages/vwish_editor_core/test/fixtures/vectors/frame_grid.json | grep androidSeekMsRounding
#   null before ENG-06, "floor" after. Also wait for the owner's word.
#   ENG-02, ENG-03, ENG-04, INT-06: the owner's word.

# Receive gates
git switch editor-android && git merge --no-edit origin/editor-wip

# Plugin tests (from the repo root)
VWISH_ANDROID_APK_MODE=debug bash scripts/ci/editor/android_unit.sh   # APK build + all JVM tests
bash scripts/ci/editor/android_emulator.sh                            # all instrumented tests + engine smoke test
cd packages/vwish_editor_engine/example/android
./gradlew :vwish_editor_engine:testDebugUnitTest --tests 'com.vecvel.vwish.editor.engine.thumbs.*'
./gradlew :vwish_editor_engine:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.package=com.vecvel.vwish.editor.engine.thumbs
./gradlew :vwish_editor_engine:lintDebug
cd -

# AND-10 integration test (serial from `adb devices`)
cd packages/vwish_editor_engine/example && flutter test integration_test/android_preview_test.dart -d emulator-5554

# API 29 / API 34 / tablet runs (AND-02, AND-12, AND-15): one emulator at a time, under the workflow's lock
emulator -list-avds              # Pixel_9_Pro_XL_API_35, Pixel_API_29, Pixel_API_34, Pixel_Tablet_API_35
adb emu kill                     # stop the API 35 emulator first
emulator -avd Pixel_API_29 -no-snapshot-save &
adb wait-for-device
ANDROID_SERIAL=emulator-5554 bash scripts/ci/editor/android_emulator.sh   # serial from `adb devices`
adb emu kill
```

Test packages per ticket:

| Ticket | Package |
|---|---|
| ENG-08 | `glue` |
| AND-02 | `probe` |
| AND-03 | `thumbs` |
| AND-04 | `audio` |
| AND-05 | `proxy` |
| AND-06 | `freeze` |
| AND-07 | `reverse` |
| AND-08 | `composition` |
| AND-09 | `effects` |
| AND-17 | `paused` |
| AND-10 | `preview` |
| AND-16 | `fallback` |
| AND-13 | `recording` |
| AND-14 | `platform` |
| AND-15 | `drop` |
| AND-11 | `export` |
| AND-12 | `service` |
| AND-18 | `render` |
| AND-19 | `precompose` |

Each package is under `com.vecvel.vwish.editor.engine`.
