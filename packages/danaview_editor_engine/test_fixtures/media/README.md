<!-- OWNER: ENG-05 -->
# Editor test media fixtures

Small, committed, locally generated media for the editor engine tests (total about 12 MB, budget 30 MB).
Used by the Dart tests in this package, the native tests (RunnerTests, androidTest, the spike hosts),
QA-00, QA-03 and QA-11. `manifest.json` is machine readable and is the contract the tests check.

Everything here was generated on the dev Mac; **nothing was downloaded**. All files are original
test content released under CC0 / public domain except where noted under "Provenance and licences".

## Regenerating

```sh
cd packages/danaview_editor_engine
swiftc -O -swift-version 5 tool/make_fixtures.swift -o /tmp/make_fixtures
/tmp/make_fixtures                         # all files + manifest.json into test_fixtures/media
/tmp/make_fixtures --only vfr_720p.mp4     # one file (manifest entries of the others are kept)
/tmp/make_fixtures --skip-containers       # skip the two ffmpeg-made containers
/tmp/make_fixtures --out /tmp/media        # elsewhere
```

Needs macOS (AVAssetWriter, Core Graphics, Core Text, `say`). The MKV and WebM files also need the
dev-only `ffmpeg` (`FFMPEG=/path/to/ffmpeg` overrides the lookup). ffmpeg is a development tool only; it is
never shipped and never used by the app.

**Regeneration is semantically equivalent, not byte identical** (V-U6): hardware encoders and the speech
synthesizer change across OS updates. What must stay equal: barcode per frame, durations within one
frame (0.1 s for AAC audio-only files), stream layout, tone frequency within 1 Hz, tone level and channel
content. `test/fixtures/fixtures_semantic_test.dart` verifies the committed files against `manifest.json`
and, with `DANAVIEW_FIXTURE_REGEN=1` (macOS), compiles and runs the tool into a temp dir and verifies that
fresh output against the same committed manifest:

```sh
flutter test test/fixtures test/testing                              # committed files (needs ffmpeg/ffprobe)
DANAVIEW_FIXTURE_REGEN=1 flutter test test/fixtures/fixtures_semantic_test.dart   # plus a fresh regeneration
```

## The frame barcode

Every video fixture draws the same machine readable band over a hue-shifting backdrop with big digits
(human readable), `t=` and fps text, and a sweeping yellow bar. The bottom 22 % of the frame is calm
(subtitle safe area, QA-00 scenario 7). The **barcode** is the normative, resolution independent layout:

| Cells (of 28 equal columns, full width) | Content |
| --- | --- |
| band | top 10 % of the frame height (at least 8 px) |
| 0, 1 | white, black (calibration: fixes the threshold) |
| 2 .. 17 | frame index, 16 bits, MSB first, white = 1 |
| 18 .. 25 | CRC-8 (poly 0x07, init 0, no reflection) of the two index bytes, MSB first |
| 26, 27 | white, black (end guard) |

Readers sample the central 50 % x 50 % of each cell, threshold at the midpoint of cells 0 and 1, and
require every cell to be at least 25 % of the contrast away from the midpoint. Results are `ok(index)`,
`noSignal` (flat, black or white frame), `blended` (a cell is gray: a dissolve of two different frames or a
fade, never a wrong index), `badGuard` (inverted, cropped, rotated, letterboxed) or `badChecksum`.

Golden vectors (index, cells 0..27), identical in all three readers and tests:

```
0      1000000000000000000000000010
1      1000000000000000010000011110
160    1000000000101000000110100110
239    1000000000111011111000001110
4660   1000010010001101001111000110   (0x1234)
65535  1011111111111111110010010010
```

Readers (all pure, decode a pixel buffer; `region` crops a letterboxed capture; stride and BGRA aware):

* Dart: `package:danaview_editor_engine/testing.dart` (`FrameBarcode.read` / `decode`), for
  `PreviewSession.debugCaptureFrame` RGBA bytes and extracted export frames.
* Swift: `example/ios/RunnerTests/Support/FrameBarcode.swift` (`FrameBarcode.read(pixelBuffer:)`, `read(cgImage:)`,
  `read(pixels:)`; 32BGRA and 8/10-bit bi-planar 4:2:0 from the luma plane).
* Kotlin: `android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/support/FrameBarcode.kt` (pure JVM
  file: `read(ByteArray, ...)`, `readArgb(IntArray, ...)`) plus `BitmapFrameBarcode.kt` for `Bitmap`.
  The JVM unit test `android/src/test/kotlin/.../support/FrameBarcodeTest.kt` compiles that file too, so the Android
  library's Gradle file must add the directory to the `test` source set (ENG-08/ENG-09 own the Gradle file):
  `getByName("test") { java.srcDirs("src/test/kotlin", "src/androidTest/kotlin/com/vecvel/danaview/editor/engine/support") }`.

`frames/frame_counter_1080p30_<n>.png` are ten committed 960x540 frames (n = 0, 1, 2, 29, 30, 119, 120, 159,
160, 239) extracted from the video, so the JVM and Swift readers have real compressed frames without ffmpeg:

```sh
ffmpeg -i frame_counter_1080p30.mp4 -vf scale=960:540 -fps_mode passthrough -start_number 0 /tmp/f_%d.png
```

## Files

Frame `i` shows barcode `i` and is presented at `i / fps` s unless stated otherwise. "No audio" means no audio
stream at all (the export no-audio cases of QA-11 and IOS-12/AND-11).

| File | Layout |
| --- | --- |
| `frame_counter_1080p30.mp4` | H.264 High 1920x1080, 30 fps CFR, 8.000 s, 240 frames, barcodes 0..239, no audio, BT.709, keyframe every second, B-frames on. Scenario 2: 0:05:10 is barcode 160. |
| `frame_counter_720p25.mp4` | 1280x720, 25 fps, 8 s, 200 frames, barcodes 0..199, no audio. Also the source of the MKV/WebM files. |
| `frame_counter_720p24.mp4` | 1280x720, 24 fps, 8 s, 192 frames, barcodes 0..191, no audio. Grid-cut cases (D-35). |
| `frame_counter_720p48.mp4` | 1280x720, 48 fps, 8 s, 384 frames, barcodes 0..383, no audio. Grid-cut cases. Track and movie timescale 2400, so frame k is stored exactly at k/48 s (50·k ticks); the generator writes every CFR counter at 2400 (a multiple of 24/25/30/48/60), never AVAssetWriter's default 600, which cannot hold 48 fps (QA-03 finding 4, FIX-48FPS-TIMESCALE). The other committed counters predate this and still carry 600, which holds 24/25/30/60 exactly. |
| `frame_counter_720p60.mp4` | 1280x720, 60 fps, 8 s, 480 frames, barcodes 0..479, no audio. Grid-cut cases. |
| `clap_flash_av.mp4` | H.264 1280x720 30 fps, 6 s, 180 frames + AAC-LC mono 48 kHz. **Flash frames** (all white, black digits, barcode still readable) at frames 30, 75, 120 (1.0 s, 2.5 s, 4.0 s). **Clicks** (20 ms Hann-windowed 2 kHz burst, -6 dBFS peak, digital silence between) start exactly at those times. The AAC track has the encoder priming (2112 samples) carried in the `elst` edit list, so the first audio sample is not at media time zero. |
| `vfr_720p.mp4` | H.264 1280x720 variable frame rate, 143 frames, 6.000 s. Timescale 600; frame durations cycle 20, 20, 40, 25, 10, 30, 20, 20 ticks and frame 60 is held for 0.5 s (300 ticks). The exact presentation ticks are in `manifest.json` (`video.ptsTicks`). `r_frame_rate` differs from `avg_frame_rate`. No audio. |
| `hlg_10bit_720p.mov` | HEVC Main10 1280x720 30 fps, 3 s, 90 frames, 10-bit 4:2:0, BT.2020 primaries/matrix, ARIB STD-B67 (HLG) transfer, MOV container. Barcodes 0..89. No audio. |
| `rotated_90.mov` | H.264, encoded 1280x720, **preferred transform rotates 90 degrees** (ffprobe `rotation=-90`), displayed 720x1280, 30 fps, 3 s, 90 frames. The barcode is upright in the top band only after the rotation is applied (AVAssetReader / MediaCodec give the raw landscape buffer). No audio. |
| `speech_10s.m4a` | AAC-LC mono 44.1 kHz, 10 s (0.1 s tolerance), synthesized English speech (macOS `say`, voice Samantha when installed, 165 wpm), padded or truncated (50 ms fade) to exactly 10 s of PCM before encoding. The spoken text is in `manifest.json`. |
| `surround_5_1.m4a` | AAC-LC 5.1 (6 channels) 48 kHz, 5 s. **Only the centre channel carries a 500 Hz tone at -12 dBFS**; L, R, Ls, Rs and LFE are digital silence. AAC channel order C L R Ls Rs LFE; ffprobe/ffmpeg report the `5.1` layout and name the centre `FC`. |
| `tone_440hz.wav` | PCM 16-bit mono 48 kHz, 10 s, 440 Hz sine at -12 dBFS peak, no fades. |
| `tone_1khz.wav` | PCM 16-bit mono 48 kHz, 10 s, 1000 Hz sine at -12 dBFS peak, no fades. QA-11 pitch and mix checks. |
| `stereo_440l_880r.wav` | PCM 16-bit stereo 48 kHz, 5 s, 440 Hz left and 880 Hz right at -12 dBFS peak. |
| `tone_under_video.mp4` | H.264 1280x720 30 fps, 8 s, 240 frames, barcodes 0..239 (the frame_counter video) + AAC-LC mono 48 kHz 1000 Hz sine at -12 dBFS. |
| `still_4k.jpg` | JPEG 3840x2160 (quality 0.72), gradient + shapes + text, barcode 0 in the top band. No alpha, no EXIF orientation. |
| `alpha.png` | PNG RGBA 512x512: transparent margin, opaque red square (64,64) 160x160, 50 % green rectangle (64,300) 160x120, radial blue disc centred (340,340) fading to alpha 0 over 150 px. |
| `sample_h264_aac.mkv` | Matroska, H.264 640x360 25 fps (the first 3 s = 75 frames of `frame_counter_720p25`, barcodes 0..74) + AAC mono 48 kHz 440 Hz at -12 dBFS, 3 s. iOS refuses MKV editing (R7 message); Android: editable when decoders exist. |
| `sample_vp9_opus.webm` | WebM, VP9 640x360 25 fps (same 75 frames) + Opus mono 48 kHz 440 Hz at -12 dBFS, 3 s. Same use. |

## Provenance and licences

* All files except the speech were generated by `tool/make_fixtures.swift` from code (frames drawn with Core Graphics,
  tones synthesized from sine formulas). Content is original and dedicated to the public domain (CC0 1.0).
* `speech_10s.m4a` is synthesized with the macOS speech synthesizer (`/usr/bin/say`, voice recorded in
  `manifest.json`). The audio contains no third-party recording. Apple's voice terms govern redistribution of
  synthesized output; if that is ever questioned, replace it with a CC0 recording of the same text and keep
  the 10 s / audible-speech semantics (the verifier checks duration and audibility, not the words).
* `sample_h264_aac.mkv` and `sample_vp9_opus.webm` deviate from the BUILD_PLAN text ("small CC0 files committed
  with their source URL"): under the no-download rule they are **derived locally** with the dev-only ffmpeg
  (`libx264`/`aac` and `libvpx-vp9`/`libopus`) from our own `frame_counter_720p25.mp4` (first 3 s, scaled to
  640x360) and an ffmpeg `sine` source. There is no third-party source URL; CC0 as above. The exact ffmpeg
  command lines are in `tool/make_fixtures.swift` (`sample_h264_aac.mkv` and `sample_vp9_opus.webm` fixtures).

## Checks that exist today

| Check | Where |
| --- | --- |
| Dart reader on all 240 frames of `frame_counter_1080p30` (ffmpeg raw RGBA), every other counter file, rotated, HLG, VFR, MKV/WebM, flash frames | `test/testing/frame_barcode_test.dart` |
| Dart reader unit tests (golden vectors, 65 536 indices, noise, blend, inversion, crop, region, stride, BGRA) | same |
| Kotlin reader: golden vectors, statuses, committed PNG frames, all 240 PNG frames when ffmpeg exists (JVM) | `android/src/test/kotlin/.../support/FrameBarcodeTest.kt` |
| Swift reader: golden vectors, 250 PNG frames, AVAssetReader pixel buffers (BGRA, 420v, x420) | verified with a command line harness; XCTest wiring arrives with ENG-09 |
| Manifest equals the files (durations +-1 frame, layout, rotation, HDR flags, VFR pts, tone Hz +-1, levels, 5.1 centre-only, click onsets, flash frames, MKV/WebM streams) | `test/fixtures/fixtures_semantic_test.dart` |
| Fresh regeneration is equivalent (opt-in, macOS) | same, `DANAVIEW_FIXTURE_REGEN=1` |
| Size budget <= 30 MB | same |

Loading the files through the example host (RunnerTests folder reference, androidTest assets) is verified by ENG-09.
