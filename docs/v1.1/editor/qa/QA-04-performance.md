<!-- OWNER: QA-04 -->

# QA-04 · Performance and memory budgets

This report covers BUILD_PLAN QA-04. It measures every budget row of ARCH §18.2, §13.4 and §14.4 (with the D-36 renegotiated Android structural rows), V-D7 (sprite pre-pass) and the D-40 minimal-tier promise.

Status on 2026-10-16:

- Every row has a test that measures it and prints a `QA04|<row>|…` line.
- Every test passes on flutter-tester and on the iOS 26.5 "iPhone 16" simulator.
- Device-lab numbers are **deferred: no device available**.
- Android rows are **deferred: Windows lane**.

Simulator and host numbers are recorded here but never count as passes or misses. ARCH §21 says simulator performance is meaningless: the simulator has software H.264, no hardware HEVC and no background GPU.

## Suites

| File | Measures | Engine |
|---|---|---|
| `packages/danaview_editor_engine/example/integration_test/perf_engine_test.dart` | the native half of the rows: export speed and working set; preview first frame (200 items), exact seek, scrub, param patch, transient, paused structural patch and memory; thumbnail miss; 2-layer playback (D-40); structural edit during playback at 2/4/6 sequences | real plugin (`MobileEditorEngine` → Pigeon → IOS-11/12/17 or AND-11/16) |
| `packages/danaview_editor/integration_test/perf/editor_open_perf_test.dart` | Dart half of editor open → first frame (200 items); Dart heap with 1,000 items; autosave block; commit → patch (property, structural) | API-01 `FakeEditorEngine` (UI only) |
| `…/perf/timeline_perf_test.dart` | timeline fling and pinch UI/raster per frame (1,000 items); playback with centre-follow: UI per frame and rebuild counts; centre-locked drag → scrub issued | fake engine |
| `…/perf/projects_perf_test.dart` | Projects first paint, 40 projects | fake repository |
| `…/perf/sprite_prepass_perf_test.dart` | V-D7: sprite pre-pass with 3,000 cues (cold and cached) | API-04 `SpritePrepass` + UX-30 fonts |
| `…/perf/core_rows_perf_test.dart` | CORE-35's core rows (apply/dryRun 1,000; incremental compile + diff, full compile + encode, open 2,000; autosave encode) on the phone. CORE-35 asks for them "recorded for one mid-tier Android and one iPhone through QA-04". | CORE-35 benchmark code, imported by path |
| `…/perf/perf_support.dart` | budgets per tier, report lines, percentiles, the FrameTiming recorder, the VM-service heap reader and the project builders | — |
| `…/perf/perf_driver.dart` | `flutter drive` driver. It writes `build/qa04/<stamp>.qa04.txt` and, for each `traceAction` timeline, `<key>.timeline_summary.json` (TimelineSummary) plus the raw timeline | — |

Rows that have both a native half and a UI half (editor open, commit → preview, scrub) are measured in two parts. The editor package may not depend on the engine plugin (ARCH §4.2 rule 7), so the report adds the halves. The full end-to-end figure on a device is the sum of the `ui.*` and `preview.*` lines of the same run.

### Budgets and enforcement

- **Where budgets fail a test.** Only on a real device, in a profile build, with `--dart-define=QA04_ENFORCE=true`. Everywhere else rows print `enforced=false`.
- **Tier.** The engine suite reads the tier from `EditorCapabilities.tier`; `--dart-define=QA04_TIER=minimal|low|mid|high` overrides it. The editor suite defaults to `mid`.
- **High tier.** It uses the mid column, because §18.2 has only low and mid columns. §13.4 and §14.4 give high-tier memory caps of their own.
- **Minimal tier.** It has only the D-40 promise: no crash or OOM, and ≥ 24 fps preview at ≤ 2 layers. Every latency row prints `budget=none` there.
- **Android exact seek.** The limit is +30 % (390 / 260 ms) on the AND-16 engine (D-43(e) point 5).
- **Contract checks that always run.** Some checks fail on every run, whatever the build:
  - exact seeks are exact;
  - every patch and transient shows up in the texture;
  - fling scrolls and pinch zooms;
  - playback rebuilds nothing but `TimecodeText`;
  - the cached pre-pass reuses every sprite.

## How to run

**Host (flutter-tester).** These are functional checks; the numbers are not device numbers. Run from `packages/danaview_editor`:

```
for f in integration_test/perf/*_test.dart; do flutter test "$f" -d flutter-tester; done
```

Run the files one at a time. Several integration files in one `flutter test` call on flutter-tester fail to launch ("The log reader failed unexpectedly"); this is a tool limitation, not a test failure.

**iOS simulator.** Run from `packages/danaview_editor_engine/example`:

```
flutter test integration_test/perf_engine_test.dart -d <udid>
```

The editor package has no runner of its own, so the app is the host. Run from the repo root:

```
flutter drive -d <udid> \
  --driver=packages/danaview_editor/integration_test/perf/perf_driver.dart \
  --target=packages/danaview_editor/integration_test/perf/<name>_perf_test.dart
```

**Device lab (profile).** Engine suite:

```
flutter run --profile -d <device> -t integration_test/perf_engine_test.dart --dart-define=QA04_ENFORCE=true
```

Editor suite: add these flags to the `flutter drive` command above:

```
--profile --dart-define=QA04_ENFORCE=true --dart-define=QA04_TIER=<tier>
```

`flutter test` has no profile mode. That is why the device-lab runs use `flutter run --profile` and `flutter drive --profile`. `flutter_driver` resolves as a transitive dependency of `integration_test`, so neither pubspec needs a change.

**Android (Windows lane, branch `editor-android`).** The same files run unchanged:

```
cd packages\danaview_editor_engine\example
flutter test integration_test/perf_engine_test.dart -d emulator-5554
```

From the repo root:

```
flutter drive -d emulator-5554 --driver=packages/danaview_editor/integration_test/perf/perf_driver.dart --target=packages/danaview_editor/integration_test/perf/<name>_perf_test.dart
```

Device-lab Android runs add `--profile --dart-define=QA04_ENFORCE=true`.

Collect the report lines with `grep QA04` on the console output, or from `build/qa04/` after a drive run.

## Method

- **UI and raster per frame.** These come from the engine's `FrameTiming` (build and raster durations), the same data TimelineSummary uses. The timeline test also records a `traceAction` timeline on phones, and `perf_driver.dart` writes its TimelineSummary. The timeline and playback tests run with `framePolicy = fullyLive`, so frames are real vsync frames. Hosts without engine timings fall back to the pump wall time; the line then says `source=pumpWall`.
- **Projects.** 40 seeded projects, five cold mounts, p90 of UX-05's `editor.projects.firstPaint` span.
- **Editor open.** 200-item project from `perfProject`: 60 % main-lane clips, 15 % PiP, 15 % animated text, 10 % audio. Five runs, p90 of UX-08's `editor.open.firstFrame` span. The span runs from repository open to the session, the first compile, PlanSync and the first-frame event.
- **Heap.** The VM service (`getAllocationProfile(gc: true)`, then `getMemoryUsage`): used + external, with the editor open on 1,000 items. On hosts and simulators the figure includes the test framework, so `deltaMb` (the change since before the open) is printed as well.
- **Autosave block.** CORE-27's main-isolate work after a one-clip edit: the incremental `ProjectJsonCodec.encodeBytes` with a warmed codec, at 1,000 items in the editor. `core.autosave_block_2000` is the 2,000-item core row.
- **Commit → patch (UI half).** Time from `EditorController.apply` (SetVisual opacity, or SplitItems) until the preview session receives `applyPatch`/`setPlan`.
- **Playback.** Centre-follow on, 90 frames at 30 fps with 10 Hz clock samples, run through `EditorRebuildCounters.record`. Only `TimecodeText` may rebuild; `TextOverlayPaint` counts paints, not rebuilds.
- **Native preview.** The canvas is 1280×720 over a generated 1080p30 H.264 original. That original is the 6 s export of the first test: a moving noise picture, a PiP copy of it, a text sprite and a 1 kHz tone.
  - The 200-item plan has 160 half-second media items (each one seeks a different source GOP), 40 solids, a white box and a frame marker. The marker is a yellow bar keyframed with one held step per frame, so every captured texture names its frame.
  - The latency of patches, transients and structural patches is measured until `debugCaptureFrame` shows the change. The median capture round trip is subtracted and printed as `captureMs`.
  - The scrub test issues one scrub seek every 16 ms, which is the rate the timeline sends while dragging.
- **Playback at 2 layers.** Marker sampling while playing at half quality, which is the preview size of the minimal tier. When captures run at ≥ 2× the frame rate, or no two samples are more than one frame apart, the distinct-frame count is exact and gives the drop share. Otherwise it is a lower bound, recorded as such, and the drop share comes from native signposts on devices.
- **Structural edit during playback.** N = 2, 4 and 6 overlapping media layers, each on its own sequence. While playing, the top layer is re-cut (new source in-point). The time runs from the patch until two consecutive playing clock samples advance. The clock runs at 10 Hz, so the resolution is about 100 ms.
- **Memory.**
  - The process RSS is sampled every 50 ms. The export working set is the peak minus the baseline during the export.
  - Native preview memory is the RSS delta while the preview is open. It includes decoder buffers, so it over-states the §13.4 figure.
  - Native compose times come from signposts and GL timer queries in Instruments or Perfetto on the device lab. They are not visible from Dart.
- **Sprite pre-pass.** `exportSpriteRequests` for a 1080p export of a project with 3,000 burned-in cues, run through `SpritePrepass` with UX-30's `FontCatalog` (the export flow's wiring). The first run is cold. The second must reuse every sprite.

## Results: iOS simulator

Setup: iPhone 16, iOS 26.5 (23F77), Xcode 26.6, Flutter 3.44, debug build, run 2026-10-16. Engine capabilities: tier `high`, 6 layers, 16 sequences, software H.264 only (`hardwareEncoder` false).

| Row | Budget (low / mid; high) | Simulator | Notes |
|---|---|---|---|
| export.1080p30 (2 layers + text) | ≥ 0.7× / ≥ 1.5× RT | 1.18–1.44× RT (6 s in 4.2–5.1 s) | software VideoToolbox H.264, 180/180 frames |
| export.workingSet | ≤ 220 / 300 / 400 MB | 291–306 MB (RSS 282 → 587 MB) | the RSS includes the Flutter debug VM |
| preview.firstFrame200 (native) | ≤ 1.8 / 1.0 s | 132–496 ms (applyMs 118–452) | the first run after the build was the slow one |
| preview.exactSeek | ≤ 300 / 200 ms p90 | p90 168–178 ms, p50 90–101 ms, 60/60 exact | |
| preview.scrubDrag | ≤ 200 / 120 ms p90 | p90 179–226 ms | 45 scrubs at 60 Hz, each ack awaited |
| preview.scrubRelease | ≤ 300 / 200 ms | 4–5 ms | the exact frame was already decoded |
| preview.paramPatch → texture | ≤ 50 / 30 ms p90 | 20–31 ms (capture 83–86 ms subtracted) | |
| preview.commitProperty (engine half) | ≤ 150 / 80 ms | 103–115 ms incl. one capture | |
| preview.transient | ≤ 3 / 2 frames | 2.6–2.9 frames | |
| preview.structural (paused) | ≤ 400 / 250 ms | 259–481 ms (applyMs 257–479) | |
| preview.nativeMemory | ≤ 160 / 250 / 350 MB | +6–7 MB RSS | the export before it had already raised the RSS |
| thumb.miss | ≤ 400 / 250 ms p90 | p90 1,139–1,224 ms, p50 ~600 ms | **watch**: well over budget on the simulator, see Findings |
| playback.twoLayers | minimal ≥ 24 fps; drop ≤ 2 / 1 % | 29.2–29.6 fps presented, max gap 1–2 frames, drop ≤ 1.2–2.7 % (upper bound) | capture 41–42 Hz |
| playback.structural.2 / 4 / 6 | Android ≤ 600 / 400 ms (D-36); iOS informational | 282–300 / 420–427 / 646–722 ms | ack 181–199 / 314–333 / 443–653 ms |
| ui.editorOpen200 (Dart half) | ≤ 2.5 / 1.5 s with the native half | p90 170 ms, p50 18 ms | the first open in the isolate is the p90 |
| ui.projectsFirstPaint40 | ≤ 400 / 250 ms | p90 355 ms, p50 65 ms | the first, cold mount is the p90 |
| ui.timeline.uiP90 / uiP99 | ≤ 8 (14) / 5 (10) ms | 2.9–3.0 / 5.6–11.9 ms | 378–445 FrameTimings. TimelineSummary: build p90 4.9, p99 6.6 ms, 0 missed frames |
| ui.timeline.rasterP90 | ≤ 10 / 7 ms | ≈ 0 ms | the simulator reports no meaningful raster time |
| ui.playback.uiP90 | ≤ 3 ms | 4.3–6.4 ms (debug build) | rebuilds: `TimecodeText` only (96 for 90 frames), others 0 |
| ui.scrub.issue (UI half) | with the engine half ≤ 200 / 120 ms | p90 23 ms | 18 of 30 moves issued a seek (≤ 1 in flight) |
| ui.heap1000 | ≤ 180 / 150 MB | 187 MB isolate total (incl. the test framework) | `deltaMb` is not meaningful in one isolate run (−28) |
| ui.autosaveBlock1000 | ≤ 2 / 1 ms p90 | 0.56 ms p90 | |
| ui.commit.property / structural (UI half) | with the engine half | p90 58 / 36 ms | includes PlanSync's coalescing frame |
| ui.spritePrepass3000 (V-D7) | mid ≤ 15 s | 4.7 s cold (3,002 sprites, UI slice p90 1.2 ms, max 11.3 ms); 0.69 s cached | |
| core.apply_1000 / dry_run_1000 | ≤ 2 / ≤ 1 ms | 1.22 / 1.14 ms (JIT debug) | CORE-35 gates these on the CI host in AOT |
| core.incremental_compile_2000 | ≤ 3 ms | 3.47 ms (JIT debug) | |
| core.full_compile_2000 + plan_encode_2000 | ≤ 60 + 25 ms | 21.4 + 15.6 ms | |
| core.open_2000 | ≤ 150 ms | 30.8 ms | |
| core.autosave_block_2000 | ≤ 2 ms | 4.7 ms (JIT debug, 2,000 items) | the 1,000-item editor row is 0.56 ms |

The flutter-tester host numbers are close to the simulator's. Examples: timeline UI p90 2.7–3.3 ms, playback rebuilds 0 outside `TimecodeText`, sprite pre-pass 3.35 s cold.

## Deferred

- **Device lab: deferred, no device available.** These rows need profile builds with `QA04_ENFORCE=true` on:
  - iPhone 7 (iOS 15.8) and iPhone 8 (iOS 16.7): minimal tier, D-40;
  - iPhone SE 2 (low), iPhone 12 (mid), iPhone 15 Pro (high);
  - a 2–3 GB Android Go device (minimal), a 4 GB Android device (low), Pixel 7a (mid), Pixel 9 or Galaxy S24 (high).

  Both suites run unchanged; the commands are under "How to run". Each run fills one column of the table above, which then gets a device section per tier.
- **Android (emulator and devices): deferred, Windows lane.** Commands are under "How to run". These rows are Android-only budgets:
  - `playback.structural.2/4/6` (≤ 600 / 400 ms, the renegotiated §13.4 row; the §18.2 D-36 row is ≤ 1,000 / 600 ms);
  - `preview.exactSeek` with +30 %.

  The emulator also records the 2,000-item core rows on x86_64. The Windows-lane watch items from AND-09, AND-16 and AND-18 are listed under Findings.
- **Native compose times** (1080p frame with 2 video layers + LUT ≤ 14 / 8 ms; signposts and GL timer queries): **deferred, no device available**. They come from Instruments (iOS `DVCompositor` signposts) and Perfetto (Android `danaview-gl` timer queries) during the playback row.
- **Drop share during playback (≤ 2 % / 1 %) and the minimal ≥ 24 fps promise on devices: deferred, no device available.** The simulator's marker sampling ran at 41 Hz, which is below 2× the frame rate, so its drop share is an upper bound.
- **D-40 "no crash / OOM" on the minimal tier: deferred, no device available.** The whole engine suite plus `timeline_perf_test.dart` on the iPhone 7 / iPhone 8 / Android Go is the check.

## Remedy decision and UX-43

No measured number triggers the ARCH §18.2 remedy order:

- The timeline UI p90 is 2.9–3.3 ms and p99 5.6–12 ms on the simulator and host, against the low-tier budgets of ≤ 8 ms and p99 ≤ 14 ms.
- Playback rebuilds are 0 outside `TimecodeText`.

The verdict depends on the low-tier device run (iPhone SE 2 and a 4 GB Android device). If `ui.timeline.uiP90/uiP99` or `rasterP90` misses there, UX-43 (tile cache) is the first remedy. Until then **UX-43 is not needed on the evidence so far.** It stays open, conditional on the low-tier device numbers.

## Findings and watch items

1. **Thumbnail miss latency on the iOS simulator is 1.1–1.2 s p90** against ≤ 250 ms (mid). The simulator decodes in software, and each request extracts 8 frames (one strip) from a 1080p H.264 file. If the iPhone 12 run also misses, file a FIX against IOS-06 (thumbnail service): decode once per strip from the nearest sync sample, with tolerance.
2. **Paused structural patch on the simulator is 259–481 ms** against ≤ 400 / 250 ms. `applyMs` makes up almost all of it, which is the composition rebuild. Confirm on devices before any FIX against IOS-11.
3. **Scrub drag lag on the simulator is 179–226 ms p90.** The test awaits every ack of a 60 Hz scrub stream. The app's PlayheadController keeps ≤ 1 seek in flight, so in the app the lag is the newest-target latency (the `ui.scrub.issue` half plus one ack). Confirm on devices.
4. **Windows-lane watch items to record with the Android runs:**
   - AND-09 `LayerLookEffect` footprint (up to about 150 MB at 8× zoom) on the low and minimal tiers. Check it against `preview.nativeMemory` (≤ 160 MB low) during a look + 8× scale-keyframe preview.
   - The intermittent off-by-one frame from AND-18 (rendered-range swap), against the marker frames of `playback.twoLayers`.
   - BT.709 vs BT.601 on emulators (colour only; no effect on timing).
5. **iOS one-frame live-layer lag after an item swap into a rendered plan (IOS-19).** No rendered range is used in this suite, so it does not affect these rows. QA-03 or QA-05 track it.
