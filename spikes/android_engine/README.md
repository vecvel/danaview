# AND-01 Android engine spike host

Throwaway Gradle app (not shipped, not part of any package; ARCH D-42) whose instrumented tests answer
the Media3 1.11.1 questions of AND-01 (V-N1…V-N6, V-N15…V-N19, V-N23…V-N25 and the R1 go/no-go).
The report with the measurements and the verdict is `docs/editor/spikes/AND-01.md`.

## Layout

- `app/src/main/kotlin/…/engine/`: spike versions of the engine pieces
  - `SpikeCompositionMapper` (AND-08 shape: clock band, packed video sequences, background, audio
    sequences, P(k)-anchored boundaries, ε mechanisms, gap fills), `LayerGatingCompositorSettings`,
    `PlaceEffect` (canvas-size straight-alpha output with early exit), `ProbeEffect` (barcode reader)
  - `PausedFrameRendererProto` (AND-17 prototype: FrameExtractor EXACT frames + the same shader)
  - `ContingencyEngineProto` (AND-16 prototype: two decks per packing slot, frame clock, lead, hold)
  - `OffsetAudioSink` (V-N23 compensation probe), `GridTime` (ARCH §5 rules), `HwbImport` + `src/main/cpp`
    (HardwareBuffer → EGLImage → OES texture)
- `app/src/androidTest/kotlin/…/engine/`: one test class per question group (see the report's V-N table)
- `tool/gen_media.sh`: generates every test clip locally with ffmpeg (barcode, clock, rotated, HLG,
  tones); `media/` is git-ignored
- `tool/run_spike.sh [Class[#method]]`: builds, installs, runs on the connected emulator/device without
  uninstalling, and pulls `results/*.json` (git-ignored; summarized in the report)

## Running

```sh
cd spikes/android_engine
./tool/gen_media.sh                 # once (needs ffmpeg; dev-only)
./tool/run_spike.sh                 # every class, or e.g. ./tool/run_spike.sh PlayerTopologyTest
./gradlew :app:testDebugUnitTest    # JVM tests (GridTime)
```

Measured on the `Pixel_9_Pro_XL_API_35` emulator. Timing numbers depend on host load; correctness
assertions do not.
