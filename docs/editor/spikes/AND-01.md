# AND-01 · Android engine spike: Media3 1.11.1 CompositionPlayer + Transformer

**Verdict (R1): NO-GO for `CompositionPlayer` as the preview engine. GO for Transformer export.**
ENG-06 activates **AND-16** (contingency preview engine). The owner signs off its degradations
before M1 ends (D-43e, "Owner sign-off" below).

| | |
|---|---|
| Ticket | AND-01 (BUILD_PLAN §6). Risk R1, decisions D-14, D-35, D-36, D-42, D-43e |
| Spike host | `spikes/android_engine/` (throwaway Gradle app, 51 instrumented tests + 2 JVM tests; see its README) |
| Media3 | 1.11.1 (`common`, `exoplayer`, `effect`, `transformer`, `muxer`, `inspector`, `inspector-frame`) |
| Target | Emulator `Pixel_9_Pro_XL_API_35` (`sdk_gphone64_arm64`, API 35, 3 GB RAM, GLES 3.0 through the host Metal translator, goldfish `c2.goldfish.h264.decoder` with `maxSupportedInstances` 32, no HEVC Main10 decoder, no `GL_EXT_YUV_target`) |
| Host | 8 GB Mac shared with other engineers' builds and an iOS simulator. Load average 5–48 during the runs; each timing below names its run's load |
| Media | Generated locally by `tool/gen_media.sh` (ffmpeg): 1280×720 barcode clips at 24/30/60 fps (14-bit frame number per frame), B-frame variant, clock clips, rotated clip, HLG clips, 440/880 Hz tones. Nothing downloaded |
| Date | Spike 2026-10-08 to 2026-10-10. Final runs 2026-10-11 (section 8) |

**Not measured (deferred: no device available).** The Pixel 7a and the 4 GB device that the ticket
names were not available, so the device runs are deferred to QA-04: 30 fps 720p playback numbers,
`setComposition` latency on the 4 GB device, GPU memory (the emulator reports 0 for graphics and
GL memory), and HLG tone mapping (the emulator has no Main10 decoder and no `GL_EXT_YUV_target`).
The verdict does not depend on them. The blocking failures below sit in Media3's shared Java code
(`MultipleInputVideoGraph` / `DefaultVideoCompositor` state handling), not in emulator codecs or
GL. Each one has a minimal reproduction test that turns red, with the message "rerun AND-01", if a
Media3 upgrade fixes it.

---

## 1. Why CompositionPlayer is a no-go

ARCH §13.3 needs `CompositionPlayer` with `MultipleInputVideoGraph` (the only video graph that
composites several sequences). On Media3 1.11.1 that configuration fails at three of the preview's
core jobs:

1. **Playback stalls at every secondary-sequence boundary.** Video in a *secondary* sequence stops
   at the first item→item, item→gap or gap→item transition. The clock keeps running and the player
   never reaches `STATE_ENDED`, even after a 45 s wait with Media3's default late-drop policy. The
   same transitions in the *primary* sequence play. Every packed lane is a secondary sequence with
   gaps (ARCH §13.3 "Sequence stack"), so every real timeline stalls.
   - Tests: `PlayerTopologyTest`, nine variants (`R1_*.json`). Every variant stalls at its
     boundary: k = 28–32 for a boundary at 31 (the default drop policy drops the last frames before
     it), k = 60 for 61, gap→item at 32 for 34. The variants cover per-item effects on and off,
     image and video clock bands, per-stream progression, a late boundary, and the default drop
     policy with a 45 s wait. `primaryItemTransition_plays` ends normally.
     `GridTimingTest.playbackBarcode{24,30,60}`: the grid-cut composition stalls at its first
     secondary boundary (k = 24, 30, 63), and every frame composited before the stall is exact.
   - Side finding: with the ARCH's *image* clock band (2×2 transparent image), even a
     one-sequence composition composites all 60 frames but never reaches `STATE_ENDED`
     (`imageClockBand_neverReachesEnded`); a video clock band ends. The player tests therefore use
     a video clock band. Transformer is not affected (image clock bands export, V-N24).
2. **No exact seek ever renders.** With `MultipleInputVideoGraph`, a paused `seekTo` renders
   nothing, even for a plain one-sequence composition with no effects and no compositor settings,
   and playback does not resume after it. With late-drop disabled, the next seek fails with
   `IllegalStateException` at `DefaultVideoCompositor.queueInputTexture` line 193, which is
   `checkState(!inputSource.isInputEnded)`: an input's end-of-stream state is not reset on flush.
   With CompositionPlayer's default single-input graph, the same compositions seek exactly 6/6.
   - Tests: `SeekDiagnosticsTest.compositionPlayerSeekIsolation` (minimal reproduction, 0/6 vs 6/6),
     `compositionPlayerSeekByTopology` (the spike's compositions: 0 seeks answered),
     `scrubThenExactSeek` (0 scrub frames, the 3 post-scrub seeks unanswered),
     `PlayerTopologyTest.clockBandKinds_exactSeeks` (0/5 image, 0/5 video) and
     `secondaryItemTransition_seekPastBoundary_fails`.
3. **No rebuild ever renders.** A paused `setComposition(c, positionMs)` never renders the frame at
   the playhead (10 s timeout). A rebuild during playback renders nothing either. The first or
   second rebuild then fails with `ExoTimeoutException: Player release timed out` (at 4 and 6
   sequences on 2026-10-10, at 2, 4 and 6 sequences in the final run).
   - Test: `PausedEditTest.setCompositionLatency_vn19` (`VN19_set_composition_latency.json`).

`experimentalRedrawLastFrame` is no fallback either (V-N3). Without the replayable cache it throws
`IllegalStateException`. With the cache, `MultipleInputVideoGraph.redraw()` throws
`UnsupportedOperationException` on Media3's playback thread, which kills the process unless an
uncaught-exception handler catches it.

Seek, rebuild and play-through are the editor's core preview operations, and no wrapper can avoid
them. The stall happens inside Media3's frame release, so no compositor settings or effects can
work around it. Hence the no-go. **Transformer is not affected:** the same compositions export
frame-exactly (section 3; one open observation in section 4).

---

## 2. The contingency engine (AND-16) prototype

`ContingencyEngineProto` (906 lines including probe and diagnostics) implements ARCH §13.3
"Contingency" and adds four mechanisms that the measurements showed are needed:

- **Two decks per packing slot.** A deck is an `ExoPlayer` with `SeekParameters.EXACT` and
  `pauseAtEndOfMediaItems`, playing the slot's layers as one clipped playlist. It renders into its
  own PRIVATE `ImageReader` (8 images, `USAGE_GPU_SAMPLED_IMAGE`), whose HardwareBuffers become OES
  textures through a 34-line JNI shim (`eglCreateImageKHR` + `glEGLImageTargetTexture2DOES`). One
  deck plays layer i. The other pre-rolls layer i + 1, paused at its first frame, once that layer
  is less than 1 s away. A cut therefore never waits for a seek. Without the standby deck, the
  frames after a cut showed the previous clip (errors down to −146 source frames, table below).
- **Lead.** The players run 2 output frames ahead of the compositor's frame clock, and each deck's
  queue holds the frames until their output frame is composited. This needs `ImageReader`. A
  `SurfaceTexture` can only latch its newest frame, which put wrong slot frames into every 30 fps
  run (100–159 per run in runs A and B, `surface_texture` row).
- **Hold / miss.** The compositor draws output frame k only when every active slot has latched its
  **rule frame** (ARCH §11.5, by pts). Otherwise it retries on the next vsync, or drops k as soon
  as a deck has already passed k. A late slot frame becomes a dropped output frame and is never a
  wrong one. While a playing deck rebuffers, the frame clock stops (at most 2 s at a time).
- **Stuck-deck watchdog** (found in the final runs). On cold starts with 4 and 6 slots, a deck
  sometimes sat in `STATE_BUFFERING` and never produced its first frame: before a working
  watchdog, 4 of 6 cold starts with 4–6 slots had no frame after 90 s. Re-issuing the same exact seek does nothing, because
  ExoPlayer ignores a seek to the millisecond it already reports while BUFFERING or READY (29 and
  58 ignored re-seeks in one run). The watchdog re-seeks a deck that has been stuck for 3 s,
  alternating between ms − 1 and ms. Both land on the rule frame (first frame with pts ≥ position,
  V-N18, and frames are more than 1 ms apart). With it, all 9 cold starts since then rendered, and
  one 6-slot start needed one re-seek.

The frame clock is Choreographer-driven on one preview thread, which also owns EGL, GL and the
players' application looper. Gating follows the plan, and the place shader and straight-alpha
blend are the same as in the Media3 effects. Drift beyond one frame is corrected by seeking the
late deck (1 s cooldown). Audio slots were not prototyped: V-N23 shows the audio-sink offset
mechanism they need.

Grid-cut composition: 3 slots, gaps and cuts at k ≡ 1, 2 (mod 3), 720p, 4 s. All
`ContingencyEngineTest` tests passed in runs A and B.

| Measurement | Run A (load 5–10) | Run B (load 10–20) |
|---|---|---|
| Playback 24 / 30 / 60 fps (AND-16 configuration): wrong slot frames on composited frames | **0 of 647** | **0 of 495** |
| Same: output frames composited (the rest dropped) | 71/96, **118/120**, 194/240 | 80/96, 86/120, 135/240 |
| Slow clock (frame clock and decks at 0.25×) 24 / 30 / 60 fps: composited; cuts seen on both sides; wrong | 96/96, 120/120, 208/240; 19/21 cuts; 0 of 720 | 96/96, 120/120, 238/240; 21/21 cuts; 0 of 788 |
| Composite + probe readback per frame, 30 fps, p50 / p90 | 3.0 / 16.1 ms | 5.8 / 28.3 ms |
| Same engine, frame clock not stopped while a deck rebuffers, 30 fps | 59/120 composited, 0 wrong | 106/120, 0 wrong |
| Same engine without hold, 30 fps | 119/120 composited, **3 of 205 slot frames wrong** (−3…−1) | 89/120, **41 of 156 wrong** (−8…−1, one empty) |
| One deck per slot, no lead, no hold (ARCH's original contingency), 30 fps | 117/120, **65 of 204 wrong** (−146…−1) | 106/120, **57 of 180 wrong** (−146…−1) |
| One SurfaceTexture per slot, 30 fps | 120/120, **159 of 207 wrong** (−143…+252) | 78/120, **100 of 133 wrong** (−145…+252) |
| Exact seek, 200 random k (`exactSeek_contingency`) | **200/200**, p50 143, p90 220, max 542 ms | **200/200**, p50 318, p90 609, max 1 762 ms |
| Scrub: 83 off-grid positions (47 ms steps), then 3 exact seeks | 86 frames, 0 wrong, 0 off-grid; p50 185, p90 293 ms | 86 frames, 0 wrong, 0 off-grid; p50 180, p90 367 ms |
| Cold engine → exact frame at the playhead, 2 / 4 / 6 slots (V-N19 upper bound) | 2.39 s / 1.64 s / no frame in 90 s (before the watchdog) | 2.42 / 0.64 / 1.39 s (watchdog, 0 re-seeks) |
| Warm exact seek p50, 2 / 4 / 6 slots | 179 / 522 / 1 234 ms | 168 / 348 / 1 076 ms |

Other runs:

- **Run C** was the full suite at load 14–48. Exact seek was 200/200 (p50 297, p90 532 ms). Scrub
  had 0 wrong frames (p50 447 ms). Cold starts took 1.40 / 0.71 / 1.24 s and warm seeks
  344 / 668 / 1 022 ms.
- **The watchdog runs between A and B.** With the same-ms re-seek: 3.30 s, then no frame at 4 or
  6 slots. With the alternating re-seek: 2.02 / 2.12 / 4.24 s (one re-seek).
- **Runs C and D (load ≈ 22) under heavy load.** Playback still showed **0 wrong frames** (0 of
  173 and 0 of 685 composited slot frames). But it composited too few frames for the test's
  non-vacuity check: 72/456 frames, then 4/21 cuts seen on both sides. So
  `gridCutPlayback_contingency` reports "not enough evidence" on an overloaded host. That is a
  property of the check, not a wrong frame.

All playback, seek and scrub frames carry pts = P(k) exactly (the frame clock is ours).

---

## 3. Every V-N item, answered by a test

Results are JSON files under `spikes/android_engine/results/` (pulled by `tool/run_spike.sh`,
git-ignored). Numbers are from the final full run (run C) unless a range of runs is given.

| Item | Question | Test(s) | Answer |
|---|---|---|---|
| **V-N1** | `getOverlaySettings` input id = sequence index, pts = composition time | `CompositorContractTest.canonicalComposition_{player,export}_vn1*` | **Yes.** Input ids 0…4 = sequence index (clock band 0, sequences 1–3, background 4) in player and Transformer. pts are composition times: within −1 … +500 µs of P(k) (secondary items' frame times come from the clip start, SHIFT_START_500), with `frameIndexNearest(pts) = k` on every call. Export barcode 120/120, player 30/30 before the stall. |
| **V-N2** | Effect pts sequence-cumulative in CompositionPlayer and Transformer | `canonicalComposition_export_vn1_vn2`, `primarySequence_player_vn2` | **Yes.** Export: sequence 1 effect pts run 500 µs → 3 967 167 µs across its items and gaps. Player: the primary sequence's second item continues at the cumulative time (29 calls at or after item B). |
| **V-N3** | Does `experimentalRedrawLastFrame` re-run a secondary sequence's effects? | `PausedEditTest.redrawLastFrame_secondarySequence_vn3` | **No, it is unusable** with `MultipleInputVideoGraph`. Without the replayable cache: `IllegalStateException` (`checkState(enableReplayableCache)`). With it: `UnsupportedOperationException` from `MultipleInputVideoGraph.redraw()` on the playback thread, a process crash. 0 effect calls, pixels unchanged. D-36 confirmed: paused edits go through PausedFrameRenderer. |
| **V-N4** | Straight alpha preserved | `CompositorContractTest.straightAlpha_{export,player}_vn4` | **Yes.** Red 0.5 over green 0.5 over the background matches straight-alpha "over" within 0.002 in export and in the player (frame read from the surface). Blend: `glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)`. |
| **V-N5** | `hdrMode` tone-maps HLG | `SourceRulesTest.hlgToneMapped_export_vn5` | **Not verifiable on the emulator (deferred: device).** `HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL` selects Media3's OpenGL tone-map shader, which needs `GL_EXT_YUV_target`; the emulator lacks it, so export fails with `ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED` (shader compile error). The emulator also has no HEVC Main10 decoder. Consequence for AND-02: probe `GL_EXT_YUV_target` with the 10-bit decoder, and use `HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC` (API 31+) or the automatic SDR proxy where it is missing. |
| **V-N6** | Upright frames for rotated sources | `rotatedSourceUpright_{export,player}_vn6` | **Yes.** A 90°-rotated source: export 60/60 frames upright (orientation markers and barcode), player 59/59. |
| **V-N15** | Clock band gives export fps above the source rate | `exportFpsAboveSourceRate_vn15` | **Yes.** 30→60: 120/120 frames at a constant 16 667 µs step. 24→48: 96/96. 30→50: 100/100. Which source frame repeats follows Media3's nearest-frame choice, not the floor rule: 20/120, 16/96 and 24/100 frames show the next source frame. Acceptable for up-conversion (always an adjacent frame); `fpsUpconversion = true`. |
| **V-N16** | A mechanism meeting the ε source-frame rule at clip starts | `epsilonRule_export_vn16`, `epsilonRule_player_vn16` | **`SNAP_TO_RULE_FRAME`**: clip start = PTS of the rule frame (greatest sample PTS ≤ s0 + 500 µs, read with `MediaExtractorCompat`, edit lists applied). 0 mismatches over 7 start offsets (−400 µs … +32 ms) on plain and B-frame sources in export, and 0 of 9 clip-start frames in the player (B-frame source). Per source, plain clipping at s0 gave 15 mismatches and s0 − 500 µs gave 14. |
| **V-N17** | `setFrameRate` caps fast items | `fastItemFrameRateCap_{export,player}_vn17` | **Yes.** A 4× item: `EditedMediaItem.setFrameRate(gridFps)` cuts effect calls 240 → 60 in export and 234–236 → 56 in the player. Barcode exact. `FrameDropEffect` gives the same count. Wall times (1.5–9.4 s) are host-load noise. Use `setFrameRate` as ARCH says: it is the documented item-level cap and keeps the player's rendered frame count (56 rendered vs 15 with `FrameDropEffect`). |
| **V-N18** | Seek semantics → `androidSeekMsRounding`; clock-band pts after seeks and scrubs; secondary-frame selection; grid-cut 100% in playback, exact seek, export | `SeekDiagnosticsTest.*`, `GridTimingTest.*`, `ContingencyEngineTest.*` | **Seek semantics: first frame with pts ≥ position**, so **`androidSeekMsRounding = "floor"`**. ExoPlayer EXACT: 16/16 floor hits, 0/16 ceil. CompositionPlayer with the single-input graph: 6/6. CompositionPlayer with MIG cannot seek (section 1). **Secondary-frame selection:** Media3 takes the secondary frame nearest to the primary pts. With `addGap`, a gap has fewer frames than the output grid, so at 60 fps one item start shows one output frame early (k = 154). With gaps filled by transparent image items at the output fps (`GapFill.TRANSPARENT_IMAGE`), every grid time has a secondary frame. **Grid-cut export: 100%** at 24/30/60 fps with transparent-image gaps and rule-frame clip starts (96/96, 120/120, 240/240), both on composited frames and on the decoded output file. **Playback 100% and exact seek 200/200:** on the contingency path (section 2), every composited frame exact and at pts = P(k); scrubs 0 wrong. |
| **V-N19** | `setComposition` → first frame at 2/4/6 sequences; PausedFrameRenderer showing a secondary-sequence effect change; transient round trip | `PausedEditTest.*`, `ContingencyEngineTest.structuralRebuild_contingency_vn19` | `setComposition` **never renders** (section 1). The 4 GB device measurement is moot (deferred). Contingency cold rebuild → exact frame: 0.64–4.24 s over 2/4/6 slots (9 cold starts in the 3 runs with the stuck-deck watchdog, all rendered; section 2). **PausedFrameRendererProto works:** with the player surface detached, 3 EXACT `FrameExtractor` frames + the same place shader + the compositor blend reproduce the player's paused frame (0 barcode mismatches, grey difference 0). A tint change on secondary sequence 2 shows on the surface, 20/20 correct. **Transient round trip p50 5.0–6.8 ms, p90 15.9–16.4 ms** (GL p50 0.9–1.3 ms). Paused structural edit (one new EXACT extraction) → frame: 1 389–1 487 ms on the loaded emulator. Reattach + resume: 555–1 399 ms. |
| **V-N23** | Preview A/V latency; can the audio sink delay audio? | `AudioTest.previewAvLatency_and_audioDelay_vn23` | Video release vs audible audio: −6.6 to −9.5 ms (video slightly early, rate 1.0000). The ImageReader (SurfaceProducer stand-in) receives each frame **43–45 ms before its release time** (p50; the consumer sees queued buffers right away). Flutter's raster delay comes on top; QA-03 measures the end-to-end number. **The sink can shift audio:** a `ForwardingAudioSink` reporting position + 40 ms moved video 34–36 ms relative to audio (`OffsetAudioSink`). AND-16 uses the same signed offset on its audio slots, or as an offset of its frame clock. |
| **V-N24** | Clock band trackTypes {VIDEO, AUDIO} → silent AAC in Transformer output | `AudioTest.clockBandTrackTypesGiveSilentAac_vn24` | **Yes.** Image and video clock bands both give `audio/mp4a-latm` 44.1 kHz stereo, 1.997 s for a 2.0 s video, decoded peak 0. Control without AUDIO: no audio track. (ARCH asks for 48 kHz composition audio: AND-11 keeps `SonicAudioProcessor(48 kHz)` in the composition effects.) |
| **V-N25** | Six-lane sparse PiP: decoders, memory, drops, unpacked vs packed | `PackingTest.sixLanePip_{export,playerFootprint}_vn25`, `packedExport_repeated_vn25` | See section 4. |
| Export vs player | Transformer exports the same composition with matching frames (SSIM ≥ 0.98) | `CompositorContractTest.exportMatchesPlayer_ssim` | **Yes.** SSIM between the player's composited frame and the decoded export at k = 10, 45, 80, 110: worst **0.9997**. |

---

## 4. Packing and `maxVisualSequences` (V-N25, D-14)

Twelve 12-frame PiP clips on six lanes, never overlapping, at 30 fps. "unpacked_12" puts one
sequence per clip, "unpacked_6" one per lane, "packed_2" and "packed_1" use CORE-36 style slots.
The player column has the final run (run C) with the 2026-10-10 run in brackets. The export
wall time is shown at the lighter 2026-10-10 load and as the range over the final runs (load
20–48).

| Config | CompositionPlayer: prepare / video decoders created (peak alive) / peak PSS | Transformer export: decoders peak alive / wall 10-10 (realtime factor) / wall final runs / frames exact |
|---|---|---|
| unpacked_12 (12 sequences) | 15.1 s (37.2 s) / 13 (13) / 113 MB | 9–12 / 23.7 s (0.20×) / 17.7–33.9 s / 144/144 |
| unpacked_6 (6 sequences) | 3.9 s (20.1 s) / 8 (8) / 91 MB | 7 / 12.4 s (0.39×) / 20.1–24.0 s / 144/144 |
| packed_2 (2 slots) | 2.1 s (5.1 s) / 4 (4) / 76 MB | 4–5 / 4.6 s (1.05×) / 6.0–30.7 s / 144/144 in 10 of 11 exports (below) |
| packed_1 (1 slot) | 1.6 s (2.2 s) / 3 (3) / 71 MB | 3–5 / 4.4 s (1.10×) / 11.3–21.8 s / 144/144 |
| packed_2 with `addGap` (control) | — | 4–6 / 6.8 s / 10.2–11.1 s / **225–285 bad region readings** (black frames at item→gap edges) |

Findings:

- Decoders and prepare time grow with the number of sequences, not with how many clips are on
  screen at once. In the player, 12 sequences keep 13 video decoders alive (one per sequence plus
  the video clock band) for 1 visible clip. Packing into 1–2 slots brings that down to 3–4 and cuts
  prepare time 7–10×. In export, peak decoders drop from 9–12 to 3–5, and at the lighter load
  export runs about 5× faster (0.20× → 1.05–1.10× real time). This confirms CORE-36 packing and
  the D-14 sequence cap. The emulator reports no GPU memory (graphics and GL counters are 0), so
  the GPU column is deferred to QA-04.
- Transformer export of packed sequences with gaps is exact only with transparent-image gap fill.
  With `addGap`, every packed or unpacked secondary sequence produced fully black output frames at
  its item→gap edges. **AND-08 must fill gaps with transparent image items at the output fps**
  (also needed for V-N18).
- **Open observation (export): one one-frame error, not reproduced.** In the final full run at host
  load 35–48, one packed_2 export composited the previous source frame at one output frame. It was
  k = 68, lane 5, in the middle of a clip: source frame 142 instead of 143. It did not happen in the
  10 other packed_2 exports (the 2026-10-10 run, a rerun and 8 repeats at load 20–35), or in any
  other export of the same run (grid-cut 24/30/60 on composited and decoded frames,
  V-N1/2/4/6/15/16/17, SSIM).
  `packedExport_repeated_vn25` repeats the export 8 times with sequence-level probes. It tells a
  frame lost before the compositor (the nearest-frame tie then picks the earlier frame) from a
  wrong choice inside it. 8/8 runs were exact, and every source frame reached the compositor. The
  cause is unknown. It does not change the GO for export, because one error in about 40
  exports in the final runs, under extreme emulator load, cannot be told apart from emulator
  decoder behaviour. AND-11 and QA-04 keep frame-checked export fixtures that run repeatedly on devices,
  under thermal load too, with `packedExport_repeated_vn25`'s diagnostics.
- On AND-16, every slot costs **two decoders** (playing + standby) and two ImageReaders of 8 images
  each at preview size.

**Tier values for `maxVisualSequences` (Android, AND-16):**

- The values are minimal **2**, low **3**, mid **4**, high **6**. Each is further capped at
  `(codec maxSupportedInstances − 2) / 2`: two decoders per slot, and two kept free for
  FrameExtractor and thumbnails.
- ARCH's provisional 3 / 4 / 6 / 8 assumed one decoder per sequence.
- The six-lane sparse case packs into 2 slots, so even the minimal tier previews it.
- `maxConcurrentVideoLayers` stays 2 / 3 / 4 / 6.
- QA-04 re-measures on the lab devices. It may raise the values. It lowers high to 4 if a 6-slot
  warm exact seek misses the seek budget on the high-tier device: on the emulator, 6 slots took
  p50 0.6–1.2 s, against 168–344 ms for 2 slots.

---

## 5. Android preview budgets (ARCH §13.4), confirmed or renegotiated

| Budget (low / mid) | Status | Evidence |
|---|---|---|
| Param patch / transient → texture while paused ≤ 50 / 30 ms | **Confirmed** | PausedFrameRenderer transient round trip p50 5.0–6.8 ms, p90 15.9–16.4 ms on the loaded emulator |
| Paused structural edit → updated frame ≤ 400 / 250 ms (≤ 600 / 400 ms when GOP > 2 s) | **Kept, unconfirmed** | 1 389–1 487 ms on the emulator under host load 20–60 (one EXACT extraction plus GL setup in a fresh renderer). AND-17 keeps one long-lived renderer, so setup is paid once. QA-04 measures on the low and mid devices |
| Playback-ready after a structural edit (`setComposition` → first frame) ≤ 1 000 / 600 ms with ≤ 4 sequences | **Renegotiated** | No `setComposition` under AND-16. New budget: **affected-slot re-plan → exact frame at the playhead ≤ 600 / 400 ms**. A re-plan calls `setMediaItems` on the changed slots' decks and seeks exactly. Warm exact seek with 2 slots: p50 168–344 ms on the emulator. A cold rebuild of every slot (EGL and decoders created, 0.64–4.24 s) is the upper bound that a re-plan does not repeat |
| Exact seek ≤ 300 / 200 ms (original 1080p, GOP ≤ 2 s) | **Kept, +30% allowed on AND-16** (D-43e bullet) | Contingency exact seek with 3 slots at 720p: p50 143–318 ms, p90 220–609 ms over three runs at load 5–48, always 200/200 exact. 6 slots: see the tier note in section 4 |
| Playback at preview size 30 fps with ≤ 2% / ≤ 1% dropped | **Kept for QA-04 on devices** | At load 5–10 the emulator composited 118/120 (1.7% dropped). At load 10–20, 86/120. Frames are never wrong, only dropped |
| Preview A/V offset ≤ 1 frame and ≤ 40 ms after compensation | **Kept** | Mechanism shown (audio-sink offset, V-N23). The end-to-end number is QA-03's |

---

## 6. What ENG-06 must apply

1. **Ticket status.** Activate AND-16 (no-go). AND-10 ships the `PreviewSession` shell and the
   `PreviewBackend` interface, and meets its playback ACs through AND-16 (BUILD_PLAN AND-10 spec).
   Block M1 exit until the owner signs off section 7.
2. **`frame_grid.json`:** `"androidSeekMsRounding": "floor"` (V-N18). On AND-16 this rounding
   applies to the slot players' item positions: `floor((ruleFramePts − clipStart) / 1000)` ms with
   `SeekParameters.EXACT`.
3. **`packages/vwish_editor_engine/android/build.gradle.kts`.** The dependencies the engine needs,
   all at one version:
   ```kotlin
   val media3Version = "1.11.1" // pinned (R1); upgrading means rerunning AND-01's tests
   implementation("androidx.media3:media3-common:$media3Version")
   implementation("androidx.media3:media3-exoplayer:$media3Version")   // AND-16 slot players
   implementation("androidx.media3:media3-effect:$media3Version")
   implementation("androidx.media3:media3-transformer:$media3Version") // export (AND-11)
   implementation("androidx.media3:media3-muxer:$media3Version")
   implementation("androidx.media3:media3-inspector:$media3Version")       // MediaExtractorCompat: rule-frame PTS (V-N16), probe
   implementation("androidx.media3:media3-inspector-frame:$media3Version") // FrameExtractor EXACT (AND-17)
   ```
   - The engine's `minSdk` stays at the editor gate (29).
   - The JNI shim needs
     `externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }`
     and `ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }` (match the app's
     ABIs). It links `EGL`, `GLESv2`, `android`, `nativewindow` and `log` (see the spike's
     `src/main/cpp`).
   - This is the only native code AND-16 needs. At the API 29 floor the SDK has no
     `HardwareBuffer` → `EGLClientBuffer` call, so the shim stays.
   - `kotlin { compilerOptions { optIn.add("kotlin.RequiresOptIn") } }`
4. **`lint.xml`** (unchanged from ARCH §3.2, proven in the spike with `abortOnError = true`, 0 errors):
   ```xml
   <issue id="UnsafeOptInUsageError" severity="error">
       <option name="opt-in" value="androidx.media3.common.util.UnstableApi,androidx.media3.common.util.ExperimentalApi" />
   </issue>
   ```
   Every Media3 file starts with `@file:OptIn(UnstableApi::class, ExperimentalApi::class)`.
5. **Pigeon surface.** No message changes are needed: AND-16 consumes the same plan, patch,
   transient, seek, clock and texture messages through `PreviewBackend`. One capability field
   carries an AND-01 value: `fpsUpconversion = true` (V-N15).
6. **ARCHITECTURE records** (§13.3, §13.4, §24.2, D-14):
   - Replace the Android "Session" bullet's CompositionPlayer path with AND-16.
   - Record the decks / lead / hold / watchdog mechanism and the rules below.
   - Set the `maxVisualSequences` tiers 2 / 3 / 4 / 6 with the `(instances − 2) / 2` cap.
   - Apply the budget table of section 5.
   - Close V-N1…V-N4, V-N6, V-N15…V-N19 and V-N23…V-N25 as answered here. V-N5 is deferred to a
     device.
7. **Rules carried into the AND tickets:**
   - **AND-08:**
     - Gaps in video sequences are transparent image items at the output fps, not `addGap`.
     - Clip starts use the rule-frame PTS (`SNAP_TO_RULE_FRAME`).
     - Items faster than 1× use `EditedMediaItem.setFrameRate(gridFps)`.
     - Keep `setDurationUs` = the full source duration for every media item: CompositionPlayer
       needed it, and Transformer does not mind.
   - **AND-11:**
     - Silent AAC via clock-band trackTypes works (V-N24).
     - Keep the export frame-check fixtures repeatable, for the open observation in section 4.
   - **AND-02:** HDR editability depends on `GL_EXT_YUV_target` and a 10-bit decoder (V-N5).
   - **AND-10/AND-17:** with any `CompositionPlayer`, detach with `clearVideoSurface(surface)`.
     The no-arg overload throws `IllegalArgumentException` in 1.11.1.
   - **AND-16:**
     - The stuck-deck watchdog (section 2) covers every exact seek and pre-roll. A re-seek to the
       same ms is a no-op in ExoPlayer, so alternate between ms − 1 and ms.
     - Under load, frames are dropped, never shown wrong (hold / miss).

---

## 7. AND-16 sizing and the owner's sign-off (D-43e)

**Scope:** `MultiPlayerBackend : PreviewBackend` (AND-10). It contains:

- The deck pool: 2 decks per packing slot, each an ExoPlayer with a PRIVATE ImageReader, the
  HardwareBuffer→OES JNI import and epoch-tagged frames.
- The stuck-deck watchdog.
- The frame clock: Choreographer on the preview thread, a lead of 2 frames, the hold/miss policy
  and drift correction.
- Audio slots: one ExoPlayer per audio interval colour, with AND-08's speed and `GainProcessor`
  chain and a signed sink offset for V-N23. The frame clock follows the audio master.

It handles:

- exact seek and scrub through the decks;
- structural re-plan by slot diff (`setMediaItems` on affected decks only);
- surface lifecycle (SurfaceProducer cleanup/available);
- quality steps (ImageReader size) and thermal SEVERE.

Compositing is shared with AND-17's `LayerCompositorGl` and shaders. Export stays on Transformer
(AND-11).

**Size:** ≈ 1,700–2,100 lines of Kotlin, ≈ 60 lines of C++ (JNI + CMake), ≈ 850 lines of
instrumented tests (ported from `ContingencyEngineTest`). **About 3.5 weeks** of the Android lane,
against ARCH's 3 weeks: the standby decks, hold/miss, the watchdog and the JNI import were not in
the original estimate. ENG-06 records the schedule impact.

**Owner bullets AND-16 degrades (sign-off before M1 ends):**

1. **More than 2 simultaneous video layers on the minimal and low tiers** play from paused-exact
   still frames during playback (ARCH's bullet, unchanged). On mid and high, all layers play.
2. **Exact seek latency up to +30%** against the §13.4 budget (unchanged bullet).
3. **New:** under heavy load, playback **drops frames instead of showing a late one.** Visually this
   is a stutter, never a wrong clip at a cut.
4. **New:** **fewer visual sequences per project** (`maxVisualSequences` 2 / 3 / 4 / 6 instead of
   3 / 4 / 6 / 8). Projects above the cap still open (D-14 banner + proxies), and export refuses
   until reduced.

Not degraded: every owner bullet stays previewable (multi-layer video, transitions, PiP,
keyframes, text overlays, captions, speed, audio mixing). Export quality and frame accuracy are
unchanged.

---

## 8. Test record and reproducing

Final runs, 2026-10-11, on `Pixel_9_Pro_XL_API_35`, with the host shared with other engineers'
builds:

| Run | What | Load | Result |
|---|---|---|---|
| A | `ContingencyEngineTest` (4 tests) | 5–10 | OK (4 tests) |
| — | `structuralRebuild_contingency_vn19`, watchdog variants | 10–12 | OK (cold starts recorded, section 2) |
| B | `ContingencyEngineTest` (4 tests, final watchdog) | 10–20 | OK (4 tests) |
| C | Full suite (50 tests) | 14–48 | 47 passed. 3 failed on host load, rerun below |
| — | `PausedEditTest#redrawLastFrame_secondarySequence_vn3` (C: "frame 45 never rendered" in its setup) | 31 | OK |
| — | `PackingTest#sixLanePip_export_vn25` (C: the k = 68 observation, section 4) | 20–30 | OK |
| — | `PackingTest#packedExport_repeated_vn25` (new, 8 exports) | 20–35 | OK, 8/8 exact |
| D | `ContingencyEngineTest#gridCutPlayback_contingency` (C: non-vacuity check) | 22 | 0 wrong frames, but too few frames for the non-vacuity check (passes in A and B) |
| — | `./gradlew :app:testDebugUnitTest :app:lintDebug` | — | GridTimeTest 2/2. Lint 0 errors (9 warnings: dependency and AGP versions, app icon, target API, backup rules, ChromeOS ABIs) |

The R1 tests assert the *observed* Media3 1.11.1 behaviour (`…_stalls`, `…_fails`, seek/rebuild
"unanswered"). Each fails with "R1 may be a go, rerun AND-01" once a Media3 version fixes the
behaviour.

```sh
cd spikes/android_engine
./tool/gen_media.sh                    # local media (ffmpeg, dev-only)
./tool/run_spike.sh                    # all classes on the running emulator/device; results/ is refreshed
./tool/run_spike.sh SeekDiagnosticsTest#compositionPlayerSeekIsolation   # the minimal R1 reproduction
./gradlew :app:testDebugUnitTest :app:lintDebug   # GridTime JVM tests, Media3 opt-in lint
```

Timing assertions are avoided. Correctness assertions (barcodes, pts, alpha, SSIM) do not depend
on load. The contingency playback check also needs enough composited frames to be meaningful
(non-vacuity), so it needs a host load under about 20.
