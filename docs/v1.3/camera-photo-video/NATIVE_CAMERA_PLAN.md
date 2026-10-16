# Danaview 1.3.0: In-House Native Camera (Photo & Video Capture)

> **Release:** Danaview 1.3.0 (app version `1.3.0+N`). **Date:** 2026-10-12, rewritten 2026-10-15 with the owner's decisions (§2). **Status:** plan, ready for the planning review that turns §10 into a BUILD_PLAN-style ticket file.
> **Baseline:** `docs/v1.1/editor/ARCHITECTURE.md` ("ARCH"), `docs/v1.1/editor/BUILD_PLAN.md` ("BP"), the 1.2.0 plans `docs/v1.2/video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md` ("VED": face tracker VED-16, beauty shaders VED-20…25), `docs/v1.2/files-media-home/FILES_MEDIA_HOME_PLAN.md` ("HOM"), `docs/v1.2/ai-studio/AI_STUDIO_PLAN.md` ("AIS"), and the 1.3.0 desktop plan `docs/v1.3/editor-desktop/DESKTOP_EDITOR_PLAN.md` ("DSK": shared Darwin engine, Rust engine for Windows/Linux).
> **Scope:** a first-party camera on every platform Danaview runs on: full camera on iOS and Android, webcam and iPhone-as-webcam on macOS, webcam capture on Windows and Linux. Every control within one thumb's reach, fast to open and to shoot, built on each platform's native camera API.
> **Decisions:** D-99 to D-115 (this plan's range; the earlier draft's decisions are replaced), plus D-115a to D-115n added on 2026-10-16. **[OWNER]** marks the few still open. **[VERIFY]** marks a claim a spike or ticket must prove.
> **Widened on 2026-10-16 (owner):** the camera also scans **documents** (edge detection, auto-capture, perspective correction, filters, on-device OCR, searchable PDFs, image to PDF) and **QR codes and barcodes** (smart result cards that preview before acting, payment hand-off to the user's own UPI or payment app, saved codes with reminders, scan history). Decisions **D-115a to D-115n** (lettered, because D-116 onwards belongs to the 1.2.0 editor plan) and tickets **CAM-46 to CAM-60**; details in §12 and §13. Saved codes extend the 1.2.0 Files & Media Home model (`docs/v1.2/files-media-home/FILES_MEDIA_HOME_PLAN.md` §8.1, HOM-16).
> **Priorities set by the owner (2026-10-15):** most customisable camera, all controls in the hand, fast, native, cross-platform, production-ready.

---

## 0. Contents

1. Summary, goals, non-goals, what already exists
2. Decisions D-99 to D-115 (plus D-115a to D-115n, 2026-10-16)
3. Architecture
4. Controls in the hand: layout, dial, hardware buttons, launch points, gestures
5. Capture features (photo, video, pro, cinematic, dual camera, overlays, audio, beauty)
6. Speed and thermal budgets
7. Capabilities per platform and graceful degradation
8. Privacy, permissions and security
9. Testing and the device lab
10. Tickets (milestones, lanes, index, ticket specs)
11. Risks, [VERIFY] register, open questions, effort
12. Document scan & PDF (added 2026-10-16; D-115a to D-115f)
13. QR and barcode scanning, payment hand-off, saved codes (added 2026-10-16; D-115g to D-115n)
Appendix A. Beauty catalogue (owner's list) with live tiers

---

## 1. Summary, goals, non-goals, what already exists

### 1.1 Summary

The camera is **not a separate engine**. It is a capture module inside each editor engine Danaview already has, so it reuses their GPU pipelines, the 1.2.0 face tracker and beauty shaders, LUTs, text sprites and hardware encoders:

| Platform | Engine (from v1.1 / 1.2 / DSK) | Capture API |
|---|---|---|
| iOS, iPadOS | Shared Darwin Swift engine | AVFoundation: `AVCaptureSession`, `AVCaptureMultiCamSession`, `AVCapturePhotoOutput` |
| macOS | Shared Darwin Swift engine (DSK-06) | AVFoundation (webcams, Continuity Camera, Desk View) |
| Android | Kotlin engine | **CameraX** (lifecycle, device quirks, extensions, concurrent cameras) + **Camera2Interop** for full manual control |
| Windows | Rust engine (DSK) | Windows Media Capture (`MediaCapture`, `MediaFrameReader`) through the `windows` crate |
| Linux | Rust engine (DSK) | PipeWire camera portal (`xdg-desktop-portal` Camera), V4L2 fallback, through GStreamer |

Live beauty in the camera, beauty in the editor and beauty in exports run the **same shaders**, so they always look the same.

### 1.2 Goals

| # | Goal | Where it is guaranteed |
|---|---|---|
| G-C1 | **Every control in one hand:** a thumb dial and a customisable control layout reach zoom, EV, ISO, shutter, focus, white balance and beauty strength without a second hand | §4; CAM-20…CAM-24 |
| G-C2 | **Fast:** viewfinder in ≤ 0.5 s warm and ≤ 1 s cold; zero shutter lag where the platform supports it; ≤ 2 frames viewfinder latency with beauty on | §6; CAM-40 |
| G-C3 | **Native:** platform camera APIs only (no cross-platform camera wrapper), platform encoders, platform pro features (ProRAW, Apple Log, ProRes, HLG, RAW DNG, OEM night/bokeh/HDR) where the device has them | D-99, D-100; §5 |
| G-C4 | **Same look everywhere:** live beauty, filters and LUTs equal the editor's output for the same settings | D-104; CAM-41 |
| G-C5 | **Hidden, not disabled:** a control the device can't support never appears | D-110; CAM-08 |
| G-C6 | **Never lose a shot:** captures are written atomically and survive a crash, a phone call or the app being killed mid-recording (the file is finalised on next launch) | D-108; CAM-14, CAM-15 |
| G-C7 | **Private:** no network use; location only when the user turns on the location overlay or geotagging | §8 |
| G-C8 | **Owner UI rules:** custom components, Figtree, dark viewfinder chrome, computed contrast, touch targets ≥ 44 px, no overflow at 280–1280 px and text scale 0.85–1.35 | ARCH §1.3; CAM-24 |
| G-C9 | **Scan to a searchable PDF on device:** edge detection, perspective correction, filters and OCR without any network; the text feeds AI search's on-device index | D-115a…D-115f; CAM-46…CAM-52 |
| G-C10 | **Codes never act on their own:** every QR or barcode opens a result card that shows what it will do; payment codes only hand off to the user's own payment app after a confirm card; scanning is fully on device | D-115g…D-115n; CAM-53…CAM-60 |

### 1.3 Non-goals for 1.3.0

- Recording other apps' sound on iOS (not available to camera apps, D-107), and iOS night mode (not available to third-party apps; Apple's quality prioritisation is used instead).
- Live streaming, video calls, AR scene effects beyond face-anchored stickers. (QR and document scanning moved into scope on 2026-10-16, §12 and §13.)
- Processing, storing or confirming payments; handling money, bank details or payment credentials (D-115j). Danaview only hands a payment code to the user's own payment app.
- Online link reputation checks (they would send every scanned URL to a third party); the URL checks of D-115h are local.
- Apple Watch or Wear OS remotes (Bluetooth remotes that send volume-key events work, §4.4).
- Spatial video, 360°, external-monitor clean output.

### 1.4 What already exists and is reused

- **Face tracker** (VED-16: Apple Vision / MediaPipe Face Mesh, One-Euro filter) and **beauty shaders** (VED-20…25).
- **Render kernels:** LUTs (`.vlut`), grade, blur, masks, text sprites (`.vsprite`) and the `FontCatalog` / `TextLayoutEngine` for overlays (iOS/macOS Core Image + Metal, Android GLES, Rust `wgpu`).
- **Encoders:** AVAssetWriter/VideoToolbox, MediaCodec, Media Foundation, GStreamer (DSK-19).
- **Library:** captures appear in the 1.2.0 Home library (HOM) and open in the editor in photo or timeline mode (VED-01).

---

## 2. Decisions D-99 to D-115 (plus D-115a to D-115n, added 2026-10-16)

| ID | Decision | Status |
|---|---|---|
| **D-99** | **Capture module inside each engine**, not a separate camera engine: `packages/danaview_editor_engine` gains `capture/` in the Darwin, Android and Rust engines, and a Dart `CaptureSession` API in `danaview_editor_engine_api`. A thin `danaview_camera` Flutter package holds the camera UI and controller | owner 2026-10-15 |
| **D-100** | **Android: CameraX + Camera2Interop.** CameraX owns the session lifecycle, device quirks, concurrent cameras, OEM extensions, zero-shutter-lag capture and effects; Camera2Interop / `Camera2CameraControl` set manual sensor values (ISO, exposure time, focus distance, white balance gains). Raw Camera2 only where CameraX blocks a feature **[VERIFY: CAM-03]** | owner 2026-10-15 |
| **D-101** | **Zero-copy frame path.** iOS/macOS: `CVPixelBuffer` → `CVMetalTextureCache` → Metal/Core Image → IOSurface-backed buffer to `FlutterTexture` and AVAssetWriter. Android: camera → `SurfaceTexture` (OES) → GLES effect chain → Flutter `SurfaceProducer` and MediaCodec input surface. Windows/Linux: as DSK D-75 | – |
| **D-102** | **Two render resolutions.** Effects run at viewfinder size for preview; the recording path renders at the encode size; photos are processed at full sensor resolution after capture | – |
| **D-103** | **Beauty live tiers** (Appendix A): the *core set* (face shape, eyes and brows, nose and lips, skin, teeth, basic makeup) runs live on every tier that supports beauty; the *heavy set* (body reshaping, hair colour, AR masks, neural blemish inpainting) runs live on the high tier only and is otherwise applied after capture, in the camera's review screen or in the editor | owner 2026-10-15 |
| **D-104** | **Same shaders as the editor.** The camera calls VED's tracker and shaders; it never forks them | – |
| **D-105** | **Capture output:** default **burn in** (what users share). Option **"Keep editable"**: also saves the clean original plus a recipe (`.dnphoto` for photos, a one-clip `.dnproj` for video) so the editor can change beauty, filter and overlays later | owner 2026-10-15 |
| **D-106** | **Dual capture:** `AVCaptureMultiCamSession` (iOS) and CameraX concurrent cameras (Android 11+, `FEATURE_CAMERA_CONCURRENT`); two USB webcams on desktop. Picture-in-picture shapes and split layouts as §5.6. Recording writes one composed video plus, with "Keep editable", both raw streams as a two-track `.dnproj` | – |
| **D-107** | **Audio routing per platform.** Android 10+: internal audio through `AudioPlaybackCapture` (needs the user's screen-capture consent each session; only apps that allow capture are recorded). Windows: WASAPI loopback. macOS 13+: ScreenCaptureKit audio (needs Screen Recording permission). Linux: PipeWire monitor source. iOS: no internal audio; offers "Keep music playing while recording" (audio session mixes with others; the microphone hears the music). Modes: mic, internal, mixed, and two tracks (mic and internal as separate tracks) where internal audio exists | owner 2026-10-15 |
| **D-108** | **Crash-safe recording:** fragmented MP4 / movie fragments every 2 s, so a crash, call or kill leaves a playable file that is finalised on next launch | – |
| **D-109** | **Where captures go:** iOS Photos (add-only permission) into a "Danaview" album; Android `MediaStore` `DCIM/Danaview`; desktop `Pictures/Danaview` and `Videos/Danaview`. All appear in the Home library | – |
| **D-110** | **Capability probe → hidden controls:** each control appears only when the probe proves it works on this device and lens | – |
| **D-111** | **Hardware buttons and launch points:** volume buttons as shutter (iOS 17.2+ `AVCaptureEventInteraction`, Android key events, which also covers most Bluetooth remotes); iPhone Camera Control button (iOS 18 `AVCaptureControl`: slider and picker bound to the dial); iOS 18 Locked Camera Capture extension (launch from the lock screen, Control Center and Camera Control); Android Quick Settings tile, launcher shortcut, and registering as a camera app (`STILL_IMAGE_CAMERA`, `VIDEO_CAMERA`, `IMAGE_CAPTURE`, `VIDEO_CAPTURE` intents) | owner 2026-10-15 |
| **D-112** | **Platform pro features first:** iOS ProRAW, ProRes and Apple Log on supporting iPhones, Apple's photo quality prioritisation (Deep Fusion, Smart HDR) and native Cinematic Video capture on iOS 26 where supported **[VERIFY: CAM-02]**; Android RAW (DNG), 10-bit HLG, CameraX extensions (Night, HDR, Bokeh, Face Retouch, Auto) where the phone has them. Danaview's own depth blur only where no native mode exists | owner 2026-10-15 |
| **D-113** | **Thermal manager:** steps down live heavy beauty, then live core beauty to preview-only, then frame rate, then resolution, before the OS throttles; restores after sustained recovery | – |
| **D-114** | **Rollout order:** iOS and Android are the 1.3.0 camera. macOS follows in the same release. Windows/Linux webcam capture is the last milestone and may ship in a 1.3.x update without holding 1.3.0 | owner 2026-10-15 |
| **D-115** | **Owner UI rules** on every camera surface (ARCH §1.3), dark viewfinder chrome, left-handed mirror layout | – |
| **D-115a** | **Scan mode for documents:** VisionKit `VNDocumentCameraViewController` on iOS; Google ML Kit Document Scanner on Android, with a Danaview fallback (own capture, edge detection, manual corners) where Google Play services or the scanner module is missing. Edge detection, auto-capture, perspective correction, filters colour / greyscale / black-and-white (§12.1) | owner 2026-10-16; ML Kit availability and terms **[VERIFY: CAM-46]** |
| **D-115b** | **On-device OCR** with Apple Vision and ML Kit text recognition through the 1.2.0 `danaview_media_analysis` plugin (AI Studio plan D-70d); scans become searchable, selectable PDFs (invisible text layer), and the text feeds the AI search index (§12.2) | owner 2026-10-16 |
| **D-115c** | **Image to PDF:** one or many images; page size, margins, quality, order, compression (§12.3) | owner 2026-10-16 |
| **D-115d** | **"Export as PDF" in the Files & Media Home:** select photos, then Export as PDF with the D-115c options (§12.3) | owner 2026-10-16 |
| **D-115e** | **Reuse the 1.2.0 PDF tools:** merge, page tools and compression come from the `danaview_pdf` plugin (HOM D-98j, HOM-24, HOM-28, HOM-31); the camera adds only the image-to-page writer and the OCR text layer to that plugin (§12.4) | owner 2026-10-16 |
| **D-115f** | **Export and save:** PDF, JPEG or PNG; share sheet; save to Danaview folders, Files (iOS) or Downloads (Android); merge scans or PDFs (§12.4) | owner 2026-10-16 |
| **D-115g** | **Code scanner:** live detection in the camera plus a dedicated Scan mode; AVFoundation metadata output and VisionKit `DataScannerViewController` (iOS 16+, metadata output below) on iOS; ML Kit Barcode Scanning (bundled, on device) on Android; scan from a photo or file in the library. Formats: QR, Data Matrix, Aztec, PDF417, EAN/UPC, Code 128 (§13.1) | owner 2026-10-16 |
| **D-115h** | **Smart result card, preview before acting:** a scanned code never opens anything by itself. URLs show the full domain and local warnings (lookalike or IDN domains, shorteners, non-HTTPS, IP-address links); no automatic link preview (§13.2) | owner 2026-10-16; "Load preview" button **[OWNER]** |
| **D-115i** | **Actions per payload type:** Wi-Fi join, contact, calendar event, email, SMS, phone, geo, plain text, app links, product barcodes (§13.3) | owner 2026-10-16; iOS Wi-Fi entitlement **[VERIFY: CAM-55]** |
| **D-115j** | **Payments are a redirect only:** UPI and EMVCo / Bharat QR codes are parsed into a confirm card, then handed to the user's payment app (Android chooser; iOS detected UPI apps). Danaview never processes, stores or confirms payments and never handles money or credentials (§13.4) | owner 2026-10-16; iOS scheme list **[VERIFY: CAM-57]** |
| **D-115k** | **Saved codes:** a new item type in the Files & Media Home, fileable in any Danaview folder, with raw payload, regenerated code image, decoded fields, title, note, tags, dates, optional reminder and optional location (§13.5) | owner 2026-10-16 |
| **D-115l** | **Scan history:** local and private, can be turned off or cleared, with auto-expiry (§13.6) | owner 2026-10-16 |
| **D-115m** | **Create QR:** link, text, Wi-Fi, contact, and a personal UPI receive QR (§13.7) | **[OWNER]** |
| **D-115n** | **Privacy and safety:** scanning and decoding fully on device; no network unless the user taps an action that needs it; "quishing" warnings; payment codes never auto-redirect (§13.8) | owner 2026-10-16 |

---

## 3. Architecture

### 3.1 Layers

```
danaview_camera (Flutter)            camera screen, controls, dial, layouts, My Modes, review screen
        │  CaptureController (state, intents, persistence)
        ▼
danaview_editor_engine_api           CaptureSession, CaptureCapabilities, CaptureSettings, CaptureEvent (new, CAM-05)
        ▼
danaview_editor_engine               capture/ module per engine
  darwin/Classes/Capture/            AVFoundation session, photo/video outputs, controls, Metal effect chain
  android/.../capture/               CameraX use cases, Camera2Interop controls, GLES effect chain
  rust/dv_engine/src/capture/        MediaCapture (Windows) / PipeWire+V4L2 (Linux), wgpu effect chain
        ▼ reuses
  VED tracker + beauty shaders, LUT/grade/blur kernels, sprites, encoders
```

### 3.2 Frame pipeline (all platforms)

```
camera frames ──► effect chain (beauty → grade/LUT/filter → overlays) ──► viewfinder texture (preview size)
                                   │
                                   └──► recording branch (encode size) ──► hardware encoder ──► fragmented MP4/MOV
photo capture (full res, ZSL) ─────► same effect chain at full res (async) ──► HEIF/JPEG/DNG writer ──► library
```

- **Threads:** session control queue; camera frame queue; render queue owning the GPU context; encoder queue; audio queue. No blocking calls on the frame queue; a late frame is dropped, never shown late.
- **Face tracking** runs on a reduced copy of the frame (e.g. 256 px) at up to the frame rate, smoothed by the One-Euro filter, and feeds the mesh to the beauty pass of the same frame or the next.
- **Recording** starts from the already-running pipeline (no session reconfiguration) so the first frame is ready in ≤ 1 frame interval after the tap.

### 3.3 iOS and macOS

- `AVCaptureSession` (or `AVCaptureMultiCamSession`) with `AVCaptureVideoDataOutput` (BGRA or 420f/x420 for 10-bit), `AVCaptureAudioDataOutput`, `AVCapturePhotoOutput` (responsive capture, fast-capture prioritisation, zero shutter lag on iOS 17+; HEIF, JPEG, ProRAW, Apple ProRAW Max).
- Recording through AVAssetWriter with VideoToolbox (H.264, HEVC, ProRes; Apple Log colour space on supporting devices) and movie fragments (D-108).
- Lens selection: virtual devices (`builtInTripleCamera`, etc.) with switching over zoom factors for smooth zoom; manual lens lock in Pro mode.
- macOS: the same code with external webcams, Continuity Camera (iPhone as webcam, macOS 13+) and Desk View; manual controls only where the device exposes them.

### 3.4 Android

- CameraX `Preview`, `ImageCapture` (`CAPTURE_MODE_ZERO_SHUTTER_LAG` where supported), `VideoCapture` with `Recorder`, `ImageAnalysis` for the face tracker; `CameraEffect` / `SurfaceProcessor` runs our GLES chain for preview and video. Camera2Interop for manual values and physical lens selection on logical multi-cameras.
- Dynamic range: `DynamicRange.HLG_10_BIT` where supported; RAW (DNG) via CameraX or a Camera2 path **[VERIFY: CAM-03]**.
- Extensions: `ExtensionsManager` for Night, HDR, Bokeh, Face Retouch, Auto, shown only when available (they cannot combine with our live effects; choosing one turns our live effects off for that mode, applied after capture instead).

### 3.5 Windows and Linux (webcams)

- Windows: `MediaCapture` + `MediaFrameReader` (NV12), camera controls through `VideoDeviceController` (exposure, focus, white balance, zoom where present), WASAPI microphone and loopback.
- Linux: PipeWire camera portal (sandbox-friendly), V4L2 via GStreamer otherwise; controls through V4L2 controls; PipeWire monitor for internal audio.
- Effects, encoders and texture hand-off reuse the DSK Rust engine.

---

## 4. Controls in the hand

### 4.1 Layout (phone, portrait)

```
+---------------------------------------------+
| [flash] [HDR] [timer] [ratio]   [⚙] [mode] |   top bar: status and rarely changed settings
|                                             |
|                 VIEWFINDER                  |   tap = focus+expose, drag sun = EV, long-press = AE/AF lock
|          (zebra, peaking, histogram)        |   pinch = zoom, double-tap = switch camera
|                                             |
|  0.5×   1×   2×   5×        [quick bar ▲]   |   lens chips, user's quick bar (up to 5 controls)
|  ╭───────── THUMB DIAL ──────────╮          |   dial: zoom / EV / ISO / shutter / focus / WB / beauty
|  ╰───────────────────────────────╯          |
| [gallery]   PHOTO  VIDEO  PRO  CINEMA  SCAN ... [flip] |
|                ( SHUTTER )                  |
+---------------------------------------------+
```

- The bottom 40% of the screen holds every frequent control; the top bar holds status and rarely changed settings.
- **Left-handed layout** mirrors the screen; **one-hand mode** pulls the top bar down on a swipe.
- Landscape and tablets: controls move to the side of the gripping hand (detected from the last touch side, switchable).

### 4.2 Thumb dial

- A horizontal ring with haptic detents (iOS `UISelectionFeedbackGenerator`-equivalent through the platform channel; Android `HapticFeedbackConstants.CLOCK_TICK`). Tap its label to choose what it controls: zoom, EV, ISO, shutter, focus, white balance (Kelvin), tint, beauty strength, filter strength, or any beauty slider pinned to it.
- "Auto" detent on each manual control returns it to automatic.
- On iPhone with the Camera Control button the same dial is mirrored on the button (D-111).

### 4.3 Customisation

- **Quick bar:** the user picks up to 5 controls (from about 30) and their order.
- **My Modes:** save the whole camera state (mode, lens, resolution, frame rate, codec, manual values, beauty, filter, LUT, overlays, audio route, dual-camera layout) under a name and icon; they appear in the mode carousel and as launcher/Quick Settings shortcuts.
- **Defaults per mode:** each mode remembers its last settings.
- **Import/export** My Modes as a small JSON file (no network).

### 4.4 Hardware buttons and remotes

- Volume up/down: shutter (photo) or start/stop (video); long-press = burst or quick video; configurable (shutter, zoom, EV, off).
- iPhone Camera Control: press = shutter, light-press = dial picker, slide = dial value.
- Bluetooth selfie remotes and keyboards that send volume or media keys work through the same path. Desktop: `Space`/`Enter` shutter, arrow keys for the dial.

### 4.5 Launch points

- iOS: app icon, Locked Camera Capture extension (lock screen, Control Center, Camera Control press), Home Screen quick action, Siri/App Shortcuts intent "Open Danaview Camera in *My Mode*".
- Android: app icon, launcher shortcuts per My Mode, Quick Settings tile, double-press power if the user picks Danaview as the default camera app (system setting), camera intents from other apps.
- Desktop: Home screen "Camera" button and the menu bar item.

### 4.6 Gestures

Tap to focus and expose; drag the sun icon for EV; drag focus and exposure points apart; long-press for AE/AF lock; pinch to zoom; swipe left/right to change mode; swipe up/down to switch cameras; double-tap to switch front/back; press-and-hold the shutter for quick video (photo mode).

---

## 5. Capture features

### 5.1 Photo
Modes: Photo, Portrait (native depth where present), Night (native extension on Android), Pro, Burst, Timer, Interval. Formats: HEIF/JPEG; ProRAW / RAW DNG where supported; 48 MP and higher sensor modes where supported. Aspect ratios 4:3, 3:2, 16:9, 1:1, full. Live Photo-style motion clip is a non-goal.

### 5.2 Video
Resolutions and rates from the probe (720p…4K, 24/25/30/48/50/60, 120/240 slow motion where supported); H.264, HEVC, ProRes (iOS Pro); SDR, HLG (Android), Apple Log (iOS Pro); stabilisation modes (off, standard, cinematic/extended); pause/resume recording; photos while recording.

### 5.3 Pro controls
ISO, shutter (1/8000 s to the device maximum), manual focus with focus peaking, white balance (Kelvin + tint), EV, lens lock; zebra stripes (80–100%), live RGB/luma histogram; split focus/exposure points; all values shown and settable from the dial.

### 5.4 Cinematic
24/25 fps with 180° shutter where manual exposure is allowed, aspect guides (2.39:1, 2:1, 4:3, 1:1), live LUTs; depth blur from the platform (iOS Cinematic Video, Android Bokeh extension) or Danaview's segmentation blur as fallback.

### 5.5 Filters, LUTs and overlays
Live filters and LUTs from the editor's look library; dynamic text (time, date, location, speed/altitude, custom title, watermark) with content fonts; aesthetic masks (VHS date, film perforations, frames, crosshairs). All are sprites/kernels the editor already renders.

### 5.6 Dual camera
Picture-in-picture (shapes: rounded rectangle, circle, pill, teardrop, heart, diamond; ratios 1:1, 4:3, 16:9, 9:16; draggable with edge snapping; tap to swap) and split (top/bottom, left/right). Only on devices that support concurrent capture.

### 5.7 Audio
Mic, internal, mixed, two-track (D-107); input gain with a live meter; wind-noise reduction where the platform offers it; external mics (USB-C, Lightning, Bluetooth) selectable.

### 5.8 Beauty
The owner's full catalogue is in Appendix A, with the live tier of each feature (D-103). Master intensity, per-feature sliders, presets, Auto Enhance, before/after (split or press-and-hold), reset per section, saved custom presets shared with the editor.

---

## 6. Speed and thermal budgets

| Measure | Target | Ticket |
|---|---|---|
| App icon → live viewfinder (warm / cold) | ≤ 0.5 s / ≤ 1 s | CAM-40 |
| Mode switch photo ↔ video | ≤ 300 ms, no black frame | CAM-40 |
| Shutter → photo captured (ZSL) | ≤ 50 ms where ZSL exists, else ≤ 300 ms | CAM-40 |
| Record tap → first frame written | ≤ 1 frame interval | CAM-40 |
| Viewfinder latency (beauty on) | ≤ 2 frames over beauty off | CAM-40 |
| Live beauty, core set | 30 fps on low tier, 60 fps on mid/high at 1080p preview | CAM-41 |
| 4K60 recording, 10 min | no dropped frames on high tier before the thermal manager acts | CAM-42 |

Thermal steps (D-113) are logged and shown as a small status chip, never as an error dialog.

---

## 7. Capabilities per platform and graceful degradation

| Feature | iOS | Android | macOS | Windows / Linux | If unsupported |
|---|---|---|---|---|---|
| Manual ISO / shutter / focus | All | Camera2 MANUAL_SENSOR | Device-dependent | UVC controls where present | Pro controls hidden |
| RAW | ProRAW models | RAW capability | – | – | RAW hidden |
| Log / HLG | Apple Log (Pro) | HLG10 | – | – | Option hidden |
| ProRes recording | Pro models | – | – | – | Option hidden |
| Zero shutter lag | iOS 17+ | CameraX ZSL support | – | – | Normal capture |
| Native night / bokeh / HDR | Quality prioritisation; Cinematic Video on iOS 26 **[VERIFY]** | CameraX extensions | – | – | Mode hidden or Danaview fallback |
| Dual camera | MultiCam devices (XS/XR+) | Concurrent cameras (Android 11+) | Two webcams | Two webcams | Dual hidden |
| Internal audio | Not available ("keep music playing" instead) | Android 10+, consent, apps that allow it | macOS 13+, Screen Recording permission | WASAPI loopback / PipeWire monitor | Option hidden |
| Live core beauty | All supported tiers | GLES 3.x tiers | Yes | Yes (DSK GPU) | Beauty applied after capture |
| Live heavy beauty | High tier | High tier | High tier | High tier | After capture |
| Camera Control button | iPhone 16+ | – | – | – | – |
| Lock-screen launch | iOS 18+ | Default camera app setting | – | – | – |

---

## 8. Privacy, permissions and security

- Permissions asked at first use with Danaview's own explainer before the system prompt: camera, microphone, photo library add-only (iOS), location only when the location overlay or geotagging is turned on, screen-capture consent only for internal audio (Android, macOS).
- No network. Face data never leaves the device and is not stored except inside a "Keep editable" recipe (landmark cache), deleted with the recipe.
- Location metadata off by default; "Remove location on share" option.
- Recording indicator rules respected (the OS indicators cannot be hidden and are never covered by our UI).
- Privacy policy and App Store / Play data-safety updates in CAM-45.
- Document scanning, codes, payments and saved codes: §12.5 and §13.8.

---

## 9. Testing and the device lab

- **Simulators/emulators can't test a camera:** the iOS Simulator has no camera and the Android emulator has a virtual scene only. Unit and widget tests use a `FakeCaptureSession` (CAM-05); pipeline tests feed recorded frames through the effect chain.
- **Device lab (owner-provided):** iPhone 16 or newer (Camera Control, ProRAW/Log on Pro), an older iPhone (XR or 11, MultiCam baseline), a Google Pixel (reference Camera2 behaviour), a Samsung Galaxy (OEM quirks and extensions), a budget Android phone (LIMITED hardware level), plus one USB webcam per desktop OS.
- **Automated device runs:** XCUITest and Android instrumented tests drive the real camera on connected phones (shutter, mode switch, recording length, file validity, timings of §6); results are written to `docs/v1.3/camera-photo-video/qa/`.
- **Parity:** live beauty frames vs the editor's output for the same frame and settings (SSIM ≥ 0.98, CAM-41).

---
## 10. Tickets

Same process as v1 (BP §0–§2): exclusive file ownership, tests shipped with every ticket, "done" only when its acceptance tests pass; device-only checks run in the device lab (§9). Lanes: **IOS** (Mac + iPhones), **AND** (Windows laptop + Android phones), **DART** (either), **DESK** (macOS on the Mac; Windows/Linux on the laptop and a Linux machine).

### 10.1 Milestones

| Milestone | Scope | Exit |
|---|---|---|
| **C0** Spikes and foundations | CAM-01…CAM-05 | Spikes report; capture API frozen with a fake and contract kit |
| **C1** Core capture (iOS and Android in parallel) | CAM-06…CAM-19 | Photo, video, pro, audio, dual and cinematic work on the device lab phones |
| **C2** Controls and UI | CAM-20…CAM-25 | Every control reachable with one thumb; My Modes; review screen |
| **C3** Platform integrations | CAM-26…CAM-31 | Hardware buttons, lock-screen/Quick Settings launch, Keep editable, thermal, permissions |
| **C4** macOS | CAM-32…CAM-33 | Webcams and Continuity Camera with beauty and overlays |
| **C5** Windows and Linux webcams (may ship in 1.3.x, D-114) | CAM-34…CAM-37 | Webcam capture with beauty, overlays, dual webcam, internal audio |
| **C6** QA and release | CAM-38…CAM-45 | §6 budgets met on the lab phones; parity; release |
| **C7** Document scan & PDF (2026-10-16) | CAM-46…CAM-52 | Scan to a searchable PDF on iOS and Android, with and without Google Play services |
| **C8** QR, barcodes, payments, saved codes (2026-10-16) | CAM-53…CAM-60 | Every payload type opens the right card; payment hand-off works with the lab's UPI apps; saved codes live in the Home |

### 10.2 Index and specs

| # | Ticket | Lane | Title and key acceptance | Depends on |
|---|---|---|---|---|
| 1 | **CAM-01** | DART | [INTEGRATION] Foundations: `danaview_camera` package, `DANAVIEW_CAMERA` flag, placeholders for every file of this plan, dependency rules, CI jobs. *Player, editor and Home suites stay green with the flag on and off.* | 1.2.0 release, DSK-06 |
| 2 | **CAM-02** | IOS | iOS spike: zero-copy viewfinder with VED beauty at 60 fps, ZSL timings, MultiCam + beauty load, Apple Log/ProRes, Cinematic Video API on iOS 26, `AVCaptureControl`, Locked Camera Capture extension. *Report with numbers and go/no-go per feature.* | CAM-01 |
| 3 | **CAM-03** | AND | Android spike: CameraX + Camera2Interop manual values on Pixel/Samsung/budget phone, `CameraEffect` GLES chain cost, ZSL, concurrent cameras, extensions vs our effects, RAW path, `AudioPlaybackCapture`. *Report with a device matrix.* | CAM-01 |
| 4 | **CAM-04** | DART | [INTEGRATION] Spike outcomes: tier values, feature gates per device class, recorded in this plan and ARCH. | CAM-02, CAM-03 |
| 5 | **CAM-05** | DART | [INTEGRATION] Capture API in `danaview_editor_engine_api` (`CaptureSession`, `CaptureCapabilities`, `CaptureSettings`, `CaptureEvent`, photo/video results), Pigeon additions, `FakeCaptureSession`, contract kit. *Phone builds green; contract kit runs against the fake.* | CAM-04 |
| 6 | **CAM-06** | IOS | iOS session: device discovery, virtual/physical lenses, smooth zoom, focus/exposure points, AE/AF lock, capability probe. *Probe output matches recorded device profiles; lens switches without a black frame.* | CAM-05 |
| 7 | **CAM-07** | IOS | iOS effect chain and viewfinder: `CVMetalTextureCache`, VED tracker + core beauty, grade/LUT/filters, overlays, IOSurface to `FlutterTexture`, preview/encode branches. *60 fps core beauty on iPhone 16, ≤ 2 frames added latency.* | CAM-06 |
| 8 | **CAM-08** | DART | Capability model and hidden-control rules shared by all platforms. *Table tests: every control hidden when its capability is absent.* | CAM-05 |
| 9 | **CAM-09** | IOS | iOS photo: responsive capture, ZSL, HEIF/JPEG/ProRAW, full-res effects after capture, Photos add-only save to "Danaview" album, burst, timer, interval. *Shutter-to-capture ≤ 50 ms with ZSL; files valid with EXIF.* | CAM-07 |
| 10 | **CAM-10** | IOS | iOS video: AVAssetWriter, movie fragments (D-108), H.264/HEVC/ProRes, Apple Log, stabilisation, pause/resume, photo while recording, slow motion. *Kill during recording → playable file finalised on relaunch.* | CAM-07 |
| 11 | **CAM-11** | AND | Android session: CameraX lifecycle, Camera2Interop, physical lenses on logical cameras, zoom, focus/exposure, probe. *Probe matrix for the three lab phones.* | CAM-05 |
| 12 | **CAM-12** | AND | Android effect chain and viewfinder: `CameraEffect` GLES chain with VED shaders, `SurfaceProducer`, encoder surface branch. *30 fps core beauty on the budget phone, 60 fps on Pixel.* | CAM-11 |
| 13 | **CAM-13** | AND | Android photo: ZSL, HEIF/JPEG/DNG, extensions (Night, HDR, Bokeh, Face Retouch, Auto), MediaStore `DCIM/Danaview`, burst, timer, interval. *Extension modes appear only where available.* | CAM-12 |
| 14 | **CAM-14** | AND | Android video: `Recorder`, HLG10, fragmented MP4 (D-108), stabilisation, pause/resume, photo while recording, slow motion. *Kill during recording → playable file.* | CAM-12 |
| 15 | **CAM-15** | DART | Crash-safe finalisation and recovery on launch (both platforms), pending-capture store. *Recovery tests with truncated fixtures; nothing lost.* | CAM-10, CAM-14 |
| 16 | **CAM-16** | IOS+AND | Pro controls native: ISO, shutter, manual focus, WB Kelvin/tint, EV, lens lock; GPU focus peaking, zebra, histogram. *Values applied within one frame; peaking/zebra goldens.* | CAM-07, CAM-12 |
| 17 | **CAM-17** | IOS+AND | Audio routing (D-107): mic/internal/mixed/two-track, gain meter, external mics, iOS "keep music playing". *Two-track files open in the editor with separate tracks.* | CAM-10, CAM-14 |
| 18 | **CAM-18** | IOS+AND | Dual camera: MultiCam / concurrent cameras, PiP shapes and ratios, split layouts, swap, Keep editable two-stream recipe. *Only on supported devices; 30 fps composed recording.* | CAM-07, CAM-12 |
| 19 | **CAM-19** | IOS+AND | Cinematic: native Cinematic Video (iOS 26) / Bokeh extension, segmentation-blur fallback, 180° shutter, aspect guides, live LUTs. *Native path preferred; fallback only where none.* | CAM-16 |
| 20 | **CAM-20** | DART | Camera screen shell and layout planner: portrait, landscape, tablet, left-handed, one-hand mode, viewfinder widget. *No overflow 280–1280 px, text 0.85–1.35.* | CAM-08 |
| 21 | **CAM-21** | DART | Thumb dial (haptic detents, Auto detent) and quick bar (user-chosen, up to 5). *Every manual value settable from the dial; widget tests with drags and taps.* | CAM-20 |
| 22 | **CAM-22** | DART | My Modes, per-mode defaults, import/export JSON, launcher/Quick Settings hooks. *Save → relaunch → identical state.* | CAM-21 |
| 23 | **CAM-23** | DART | Gestures: tap focus/expose, EV drag, split points, AE/AF lock, pinch, swipes, double-tap flip. *Gesture arbitration tests.* | CAM-20 |
| 24 | **CAM-24** | DART | Panels: settings, pro panel, beauty panel (reusing VED-26 components), filters/LUTs, overlays editor, audio and dual-camera sheets. *Owner UI rules scan; a11y labels.* | CAM-21 |
| 25 | **CAM-25** | DART | Review screen: last captures, apply heavy-set beauty after capture, share, open in editor (photo/timeline), move to trash. *Opens the right editor mode.* | CAM-24, CAM-29 |
| 26 | **CAM-26** | IOS | Volume-button shutter (`AVCaptureEventInteraction`), Camera Control (`AVCaptureControl` slider/picker bound to the dial). *Device test on iPhone 16.* | CAM-21 |
| 27 | **CAM-27** | IOS | Locked Camera Capture extension, Control Center control, Home Screen quick actions, App Shortcuts for My Modes. *Launch from the lock screen to viewfinder ≤ 1 s.* | CAM-26 |
| 28 | **CAM-28** | AND | Volume/Bluetooth keys, Quick Settings tile, launcher shortcuts, camera intents (`STILL_IMAGE_CAMERA`, `VIDEO_CAMERA`, `IMAGE_CAPTURE`, `VIDEO_CAPTURE` with results). *Another app's IMAGE_CAPTURE gets a valid result.* | CAM-21 |
| 29 | **CAM-29** | DART | Keep editable (D-105): clean original + `.dnphoto` / one-clip `.dnproj` recipe with beauty, filter, overlays (and landmark cache); Home library entries. *Editor reopens and changes the beauty.* | CAM-09, CAM-13 |
| 30 | **CAM-30** | IOS+AND | Thermal and battery manager (D-113), status chip. *Injected thermal states step down in order and recover.* | CAM-07, CAM-12 |
| 31 | **CAM-31** | DART | Permissions and explainers, location/geotag toggles, "remove location on share". *Denied permission states are explained, never dead ends.* | CAM-20 |
| 32 | **CAM-32** | DESK | macOS capture on the shared Darwin code: webcams, Continuity Camera, Desk View, controls where present, beauty and overlays. *Contract kit on macOS; Continuity Camera test.* | CAM-07, DSK-06 |
| 33 | **CAM-33** | DESK | macOS internal audio (ScreenCaptureKit), two webcams. *Option hidden without permission.* | CAM-32 |
| 34 | **CAM-34** | DESK | Windows/Linux webcam spike: MediaCapture frame reader, PipeWire portal, V4L2, controls, loopback/monitor audio. *Report.* | CAM-05, DSK-18 |
| 35 | **CAM-35** | DESK | Windows capture in the Rust engine: MediaCapture, controls, WASAPI mic and loopback, effects via DSK. *Contract kit on Windows.* | CAM-34 |
| 36 | **CAM-36** | DESK | Linux capture in the Rust engine: PipeWire portal, V4L2 fallback, controls, PipeWire monitor audio. *Contract kit on the CI runner with a virtual camera (v4l2loopback).* | CAM-34 |
| 37 | **CAM-37** | DART | Desktop camera UI: window layouts, keyboard/mouse controls, device picker. *Overflow at desktop sizes.* | CAM-35, CAM-36, CAM-32 |
| 38 | **CAM-38** | IOS+AND | Device test harness: XCUITest and instrumented runners on connected phones, timing capture, report writer. | CAM-10, CAM-14 |
| 39 | **CAM-39** | IOS+AND | Functional device suite: every mode, format, lens, dual, audio route, crash recovery, intents. | CAM-38, CAM-17…CAM-19, CAM-26…CAM-28 |
| 40 | **CAM-40** | IOS+AND | Speed budgets of §6 on the lab phones. | CAM-38 |
| 41 | **CAM-41** | IOS+AND | Beauty parity (camera vs editor, SSIM ≥ 0.98) and live-beauty frame rates per tier. | CAM-38 |
| 42 | **CAM-42** | IOS+AND | Thermal and soak: 4K60 10 min, 30 min 1080p recording, 500-photo burst session. | CAM-30, CAM-38 |
| 43 | **CAM-43** | DART | Overflow, accessibility (VoiceOver/TalkBack labels, shutter and recording announcements), left-handed layout. | CAM-20…CAM-25 |
| 44 | **CAM-44** | DART | Capability matrix tests across recorded device profiles (hidden-not-disabled for every control). | CAM-08, CAM-04 |
| 45 | **CAM-45** | DART | [INTEGRATION] Release: flag on, Info.plist usage texts, extension target, Android manifest (intents, tile, foreground service type `camera`/`microphone` if needed), privacy policy and store data-safety updates, user guide. **Since 2026-10-16 also:** `LSApplicationQueriesSchemes` for UPI apps, the Hotspot Configuration capability if CAM-55 keeps it, Android `<queries>` for `upi://`, notification permission texts, privacy text for scanning, payments hand-off and saved codes (§12.5, §13.8). | CAM-39…CAM-44, CAM-52, CAM-60 |
| 46 | **CAM-46** | IOS+AND | Scan spike: VisionKit document camera (quality, filters, page limits, how results come back), ML Kit Document Scanner (Play services module download, minimum device, offline use, terms and licence, UI customisation), the fallback path's edge detection quality, OCR scripts and sizes. *Report with a go/no-go per path.* | CAM-01 |
| 47 | **CAM-47** | IOS | iOS Scan mode: `VNDocumentCameraViewController` from the mode carousel and from Home; results into the scan review screen. *Multi-page scan of 10 pages returns 10 corrected images.* | CAM-46 |
| 48 | **CAM-48** | AND | Android Scan mode: ML Kit Document Scanner (`GmsDocumentScanning`, JPEG pages; its PDF output isn't used, so our own writer adds the OCR layer) and the fallback scanner on our CameraX session (quad detection on a downscaled frame, auto-capture when stable, manual corners, perspective warp in GLES). *Same 10-page test with and without Play services.* | CAM-46, CAM-12 |
| 49 | **CAM-49** | DART | Scan review screen: reorder, rotate, re-crop corners, filters (colour, greyscale, black-and-white), retake, delete page, add page. *Edits are non-destructive until Save; golden tests per filter.* | CAM-47, CAM-48 |
| 50 | **CAM-50** | IOS+AND | OCR and searchable PDFs: Vision / ML Kit text recognition through `danaview_media_analysis` (AIS-50), invisible text layer per page in `danaview_pdf` (extends HOM-24), text sent to the on-device search index. *Text in the PDF can be selected and searched in PDFKit and in another PDF app; Home search finds it.* | CAM-49, AIS-50, HOM-24 |
| 51 | **CAM-51** | DART | Image to PDF (D-115c) in `danaview_pdf` (extends HOM-28's page writer) and Home "Export as PDF" for selected photos (D-115d). *Page size, margins, quality, order and compression options produce the expected PDFs (fixture tests).* | CAM-50, HOM-22, HOM-28 |
| 52 | **CAM-52** | DART | Export and save (D-115f): PDF/JPEG/PNG, share, save to Danaview folders / Files / Downloads, merge scans or PDFs through HOM-28, compression through HOM-31. *Saved scans appear in the Home under Documents.* | CAM-51, HOM-31 |
| 53 | **CAM-53** | IOS+AND | Code scanner core (D-115g): AVCaptureMetadataOutput on our session for live detection in every camera mode (opt-in chip), `DataScannerViewController` in Scan mode on iOS 16+ with the metadata-output fallback; ML Kit Barcode Scanning (bundled) on a CameraX `ImageAnalysis` stream; scanning from a photo or file (Vision `VNDetectBarcodesRequest`, ML Kit `InputImage`). *All listed formats decode from the fixture set on both platforms.* | CAM-07, CAM-12 |
| 54 | **CAM-54** | DART | Payload parser (pure Dart): URL, Wi-Fi (`WIFI:`), vCard, MeCard, iCalendar `VEVENT`, `mailto:`/`MATMSG`, `SMSTO:`/`sms:`, `tel:`, `geo:`, app and deep links, EAN/UPC (check digit), UPI `upi://pay`, EMVCo merchant-presented QR (TLV, CRC-16 check). *Corpus and fuzz tests; malformed input never throws.* | CAM-01 |
| 55 | **CAM-55** | DART | Result cards and actions (D-115h, D-115i): URL safety checks, Wi-Fi join (Android `WifiNetworkSuggestion` / Add-networks intent; iOS `NEHotspotConfiguration` if the entitlement holds, else copy password), contacts, calendar, compose, call, Maps, copy/share, app links with "Opens in <app>", product search on tap; "Load preview" per the owner. *Nothing opens without a tap (test); quishing test set flags every lookalike.* | CAM-53, CAM-54 |
| 56 | **CAM-56** | DART | Saved codes (D-115k): new item kind in the Files & Media Home (extends HOM-16, HOM-17, HOM-19), fields and editor, regenerated code image, full-screen show, share as image, Pay now, reminders (local notifications), optional location, search, sort by due date, "Due soon" filter. *A saved code survives backup and restore with the Danaview folders.* | CAM-54, CAM-55, HOM-16, HOM-17, HOM-19, HOM-22 |
| 57 | **CAM-57** | IOS+AND | Payment hand-off (D-115j): confirm card, Android `upi://` chooser, iOS UPI app detection with `canOpenURL` and the declared schemes, "No payment app found" with Copy VPA, "Returned from payment app". *On the lab phones, GPay, PhonePe, Paytm and BHIM (where installed) open with the payee and amount filled in; Danaview stores nothing about the payment.* | CAM-55 |
| 58 | **CAM-58** | DART | Scan history (D-115l): local list, off switch, clear, auto-expiry (off / 7 / 30 / 90 days), save to Saved codes from history. *Turning history off deletes it and records nothing new.* | CAM-55 |
| 59 | **CAM-59** | DART | Create QR (D-115m, only if the owner says yes): link, text, Wi-Fi, contact, personal UPI receive QR; save as a saved code or share as image. *Generated codes scan back to the same payload.* | CAM-56 |
| 60 | **CAM-60** | IOS+AND | Scan QA: device suite (lighting, angles, damaged and small codes, multi-page documents), parser and quishing corpora, payment hand-off checklist per UPI app, network spy (zero requests while scanning and decoding), a11y (VoiceOver/TalkBack read the card before any action). | CAM-52, CAM-56…CAM-58 (+ CAM-59 if scheduled) |

Lane split: IOS 8, AND 7, IOS+AND 15, DART 25, DESK 5 (60 tickets; CAM-59 conditional).

---

## 11. Risks, [VERIFY] register, open questions, effort

### 11.1 Risks

| Risk | Mitigation |
|---|---|
| Android device fragmentation (manual controls, ZSL, concurrent cameras vary by phone) | CameraX first; probe-driven hidden controls; three-phone lab incl. Samsung and a budget phone |
| Live beauty too slow on low tiers | Core/heavy split (D-103), preview-size processing, thermal manager |
| CameraX extensions can't run with our live effects | Extension modes turn live effects off and apply them after capture; documented in the UI |
| Lock-screen/Camera Control APIs are new (iOS 18) | Feature-gated; spike CAM-02 proves them first |
| Device testing needs the owner's phones | Automated device suites the owner can run with one command; fakes for everything else |

### 11.2 [VERIFY] register

| Claim | Closed by |
|---|---|
| iOS 26 Cinematic Video capture API available to third-party apps and combinable with our pipeline | CAM-02 |
| CameraX RAW (DNG) capture on target phones, else Camera2 path | CAM-03 |
| `CameraEffect` GLES chain sustains core beauty at 60 fps on Pixel and 30 fps on the budget phone | CAM-03 |
| MultiCam + beauty on both streams fits the iPhone XR thermal budget | CAM-02 |
| `AudioPlaybackCapture` works with common music apps the owner cares about | CAM-03 |
| ML Kit Document Scanner: availability through Google Play services, minimum device, offline use after the module download, terms and licence, and how well the fallback scanner does without it | CAM-46 |
| ML Kit text recognition and barcode scanning run fully offline with bundled models and make no network requests of their own | CAM-46, CAM-60 |
| `NEHotspotConfiguration` needs the Hotspot Configuration capability; whether App Review accepts it for a camera app's Wi-Fi QR join | CAM-55 |
| iOS URL schemes of common UPI apps (for example GPay, PhonePe, Paytm, BHIM) and whether each accepts the `upi://pay` parameters; whether UPI apps limit payments started from another app (for example to personal payees) | CAM-57 |
| `DataScannerViewController` device support (it needs newer hardware) and its behaviour next to our own capture session | CAM-53 |

### 11.3 Open questions for the owner

1. Device lab: which phones can you provide (see §9)?
2. Default save target on iOS: Photos "Danaview" album only, or also a copy inside Danaview's library?
3. Should Danaview offer to become the default camera app on Android at first launch, or only from Settings?
4. **D-115h:** Offer an explicit "Load preview" button for scanned links? It contacts the site (the site sees the user's IP) only after the tap. Recommendation: no in 1.3.0; the full domain and warnings are enough.
5. **D-115m:** Ship Create QR (link, text, Wi-Fi, contact, personal UPI receive QR) in 1.3.0?
6. **D-115l:** Scan history on by default with 30-day expiry (proposed), or off by default?
7. **D-115k:** Should a dismissed due-date reminder come back once the next day (proposed), or remind once only?

### 11.4 Effort

45 tickets. iOS and Android in parallel about **4–5 weeks** (device testing sets the pace), macOS about **1 week**, Windows/Linux webcams about **1–1.5 weeks** (may move to 1.3.x, D-114).

**Added 2026-10-16:** 15 more tickets (60 in total, CAM-59 conditional). Document scan & PDF (C7) about **1.5–2 weeks**, mostly reuse of the 1.2.0 PDF and analysis plugins; QR, barcodes, payments and saved codes (C8) about **2 weeks**, of which the payment hand-off checks on real phones with UPI apps set the pace. Both run in parallel with C2–C3.

---

## 12. Document scan & PDF (added 2026-10-16; D-115a to D-115f)

The scanner turns paper into clean, searchable PDFs on the device. It reuses two 1.2.0 pieces instead of building its own: the `danaview_pdf` plugin from the Files & Media Home plan (PDF tools, HOM-24…HOM-31) and the `danaview_media_analysis` plugin from the AI Studio plan (Vision / ML Kit, AIS-50).

### 12.1 Scan mode (D-115a)

| Step | iOS / iPadOS | Android (Google Play services) | Android fallback (no Play services or scanner module) |
|---|---|---|---|
| Capture UI | VisionKit `VNDocumentCameraViewController` (system UI, iOS 13+) | ML Kit Document Scanner (`GmsDocumentScanning`; Google's scanner UI, delivered as a Play services module) **[VERIFY: CAM-46]** | Danaview's own Scan mode on the CameraX session (CAM-48) |
| Edge detection | built in | built in | quad detection on a downscaled frame (pure on-device code; no new library unless the spike shows it's needed) |
| Auto-capture | built in | built in | when the detected edges hold still for about 0.6 s |
| Perspective correction | built in | built in | GLES perspective warp at full resolution |
| Filters | colour, greyscale, black-and-white in Danaview's review screen (CAM-49), applied to the corrected images | same | same |

- Entry points: SCAN in the camera's mode carousel (scanning documents and codes; a toggle picks Document or Code), and "Scan document" in the Files & Media Home's add menu.
- **Review screen (CAM-49):** reorder, rotate, re-crop corners, filter per page or all pages, retake, add or delete pages. Nothing is written until Save.
- **Google's terms:** ML Kit is free but closed-source and covered by Google's terms, not an open-source licence; the scanner module is downloaded by Google Play services, not by Danaview **[VERIFY: CAM-46]**. Where it's missing (for example phones without Google services) the fallback runs, so scanning always works.

### 12.2 OCR and searchable PDFs (D-115b)

- **Engines:** Apple Vision `VNRecognizeTextRequest` (accurate mode, the user's languages) on iOS and macOS; ML Kit text recognition v2 with bundled models on Android (Latin by default; Devanagari, Chinese, Japanese and Korean models as bundled extras if the size budget allows **[VERIFY: CAM-46]**). Both run fully on device.
- **Searchable, selectable PDF:** each page is the corrected image plus an invisible text layer placed over the recognised words, so the text can be selected, copied and searched in Danaview's PDF viewer and in any other PDF app. The text layer writer is added to `danaview_pdf` (CAM-50 extends HOM-24).
- **AI search:** the recognised text goes into the on-device search index (AI Studio plan D-70d), so "find the electricity bill from March" can match the scan's text. It stays on the device; AI search's cloud levels follow that plan's rules.
- OCR can be turned off per scan (faster, smaller file).

### 12.3 Image to PDF and "Export as PDF" (D-115c, D-115d)

| Option | Values |
|---|---|
| Pages | one image per page, in the chosen order (drag to reorder) |
| Page size | Fit to image, A4, US Letter, Legal, A5 |
| Orientation | Auto (per image), portrait, landscape |
| Margins | None, small (6 mm), normal (12 mm) |
| Image quality | High (JPEG 90), Medium (JPEG 75), Small (JPEG 60, max 2000 px) |
| Compression | the 1.2.0 compress presets (HOM-31) on the finished file |
| OCR | on / off |

- **From the Home:** select photos (and scans), then **Export as PDF** in the multi-select bar (HOM-22), with the options above. The originals are untouched; the PDF is a new file in the chosen Danaview folder.

### 12.4 Merge, export and save (D-115e, D-115f)

- **Merge** scans with each other or with existing PDFs through the 1.2.0 page tools (HOM-28); split, reorder, rotate, delete pages, annotate, sign and compress are the same tools (HOM-28…HOM-31). The camera adds no second PDF implementation.
- **Export as** PDF (default), JPEG or PNG (one file per page, zipped only if the user asks).
- **Save to** a Danaview folder (default `Scans`), Files (iOS, "Save to Files") or Downloads (Android, "Save to Downloads"), or share through the system share sheet (HOM §8.3).

### 12.5 Privacy

- No network: capture, correction, filters, OCR and PDF writing are all on device. (Google Play services may update its own scanner module in the background; that is Google's system update, not a request from Danaview, and the privacy text says so.)
- Scans are stored like any other Danaview file: app-private, included in app backups (HOM D-98b).
- Camera permission only; no photo library permission is needed to save scans into Danaview folders.

---

## 13. QR and barcode scanning, payment hand-off, saved codes (added 2026-10-16; D-115g to D-115n)

### 13.1 Scanner (D-115g)

**Where it works:**
- **Live in the camera:** an opt-in "Detect codes" chip in Photo and Video modes; a found code shows a small floating chip ("QR · link · example.com"); tapping it opens the result card. Capture is never interrupted.
- **SCAN mode (Code):** a dedicated full-screen scanner with a target frame, torch, zoom, and multiple-code picking when several codes are visible.
- **From the library:** "Scan code in image" on any photo, screenshot or PDF page in the Home, and from the share sheet ("Open with Danaview").

**Capabilities:**

| Capability | iOS / iPadOS | Android | macOS |
|---|---|---|---|
| Live detection on our capture session | `AVCaptureMetadataOutput` on the camera's `AVCaptureSession` (iOS 7+; Data Matrix iOS 8+; micro QR and others iOS 15.4+) | ML Kit Barcode Scanning, **bundled** model (`com.google.mlkit:barcode-scanning`), on a CameraX `ImageAnalysis` stream | `AVCaptureMetadataOutput` is iOS-only; Vision `VNDetectBarcodesRequest` on frames |
| Dedicated scanner UI | VisionKit `DataScannerViewController` (iOS 16+, supported devices only, `isSupported` **[VERIFY: CAM-53]**); below that, our own view on `AVCaptureMetadataOutput` | our own view on CameraX + ML Kit | our own view (webcam) |
| Scan from an image or file | Vision `VNDetectBarcodesRequest` | ML Kit on an `InputImage` | Vision `VNDetectBarcodesRequest` |
| Formats | QR, Data Matrix, Aztec, PDF417, EAN-13, EAN-8, UPC-E (UPC-A as EAN-13), Code 128, plus Code 39/93, ITF, Codabar where the API has them | QR, Data Matrix, Aztec, PDF417, EAN-13, EAN-8, UPC-A, UPC-E, Code 128, Code 39/93, ITF, Codabar | as iOS |
| Network | none | none with the bundled model **[VERIFY: CAM-60]** | none |

Windows and Linux: scanning from an image or file only, with a pure on-device decoder chosen in CAM-34's webcam spike (no live scanning in 1.3.0).

### 13.2 Smart result card: preview before acting (D-115h)

A scanned code **never opens anything by itself.** It always opens a card that shows what the code contains and what each button will do. Buttons are plain verbs ("Open in browser", "Join network", "Pay with…").

**Links (URL):**
- The **full domain** is shown large and on its own line (`login.example.com`), with the rest of the URL below in smaller text; long URLs wrap, never truncate the domain.
- **Local warnings** (no network, CAM-55):
  - lookalike or internationalised domains: punycode (`xn--`), mixed scripts, and confusable characters (Unicode TR39 skeleton compared with a short list of well-known brands and banks);
  - link shorteners (a bundled list, for example `bit.ly`, `t.co`, `tinyurl.com`): "This short link hides where it goes";
  - non-HTTPS links: "Not a secure link";
  - IP-address links and unusual ports;
  - user-info tricks (`https://bank.com@other.site`) and brand names buried in subdomains.
- Buttons: **Open in browser**, Copy, Share, Save (as a saved code, §13.5).
- **No automatic link preview:** fetching a title or image would contact the site (and tell it the user's IP) before the user decides. An explicit "Load preview" button is possible **[OWNER]**; the recommendation is no for 1.3.0.
- **Quishing (QR phishing):** the card carries one plain line when any warning fires: "QR codes can lead to fake sites. Check the address before you sign in or pay."

### 13.3 Actions per payload type (D-115i)

| Payload | Shown on the card | Actions (each needs a tap) |
|---|---|---|
| Wi-Fi (`WIFI:T:…;S:…;P:…;;`) | network name, security type, password (hidden, tap to show) | **Join network**: Android 10+ `WifiNetworkSuggestion` (or the Android 11+ "add networks" system dialog); iOS `NEHotspotConfiguration`, which needs the Hotspot Configuration capability **[VERIFY: CAM-55]**; if unavailable, **Copy password** and "Open Wi-Fi settings" |
| Contact (vCard, MeCard) | name, phone, email, organisation | **Add to contacts** (iOS `CNContactViewController` for a new contact; Android `ACTION_INSERT`; no contacts permission needed **[VERIFY: CAM-55]**), Copy, Share |
| Calendar event (iCalendar `VEVENT`) | title, date and time, place | **Add to calendar** (iOS `EKEventEditViewController`; Android `ACTION_INSERT` on `CalendarContract.Events`) |
| Email (`mailto:`, `MATMSG`) | address, subject | **Write email** (opens the mail app with the fields filled in) |
| SMS (`SMSTO:`, `sms:`) | number, message | **Write message** |
| Phone (`tel:`) | number | **Call** (the system asks before dialling) |
| Geo (`geo:`) | coordinates, label | **Open in Maps** |
| Plain text | the text | Copy, Share, Save |
| App links and deep links (custom schemes, universal / app links) | the link and a clear line **"Opens in <app>"** (from the scheme or domain; "Opens in an app on your phone" when unknown) | **Open in <app>**, Copy |
| Product barcode (EAN/UPC) | the number, with the check digit verified | Copy, **Search the web** (opens the browser with the number, only on tap) |
| Payment (UPI, EMVCo) | §13.4 | §13.4 |
| Unknown | raw text | Copy, Share |

### 13.4 Payments: redirect only (D-115j)

**Parsing (pure Dart, CAM-54):**
- **UPI** `upi://pay?…`: `pa` (payee VPA), `pn` (payee name), `am` (amount), `cu` (currency), `tn` (note), `tr` (reference), `mc` (merchant code); other parameters are kept and passed through unchanged.
- **Bharat QR and other EMVCo merchant-presented QR codes** (TLV format with a CRC-16 check): payee or merchant name, merchant city, amount, currency, and any UPI fields inside, where decodable. A failed CRC shows "This code may be damaged or altered" and no Pay button.
- Other payment schemes found in EMVCo codes (for example PIX, PayNow, PromptPay) are shown as decoded text with Copy; they get a Pay button only if a matching installed app can be handed the code.

**Confirm card:**
```
Pay with UPI
  To          ANITA STORES            ← payee name, large
  UPI ID      anitastores@okbank
  Amount      ₹ 450.00                ← or "Amount entered in your payment app"
  Note        Order 1182
  Check the payee name before paying.
[ Copy UPI ID ]   [ Save for later ]   [ Pay with… ]
```

**Hand-off:**
- **Android:** `Intent(ACTION_VIEW, upi://pay?…)` through the system chooser of installed UPI apps (`Intent.createChooser`), with a `<queries>` entry for the `upi` scheme for package visibility on Android 11+.
- **iOS:** there's no generic chooser. Danaview declares `LSApplicationQueriesSchemes` for common UPI apps (for example GPay, PhonePe, Paytm, BHIM; exact schemes **[VERIFY: CAM-57]**), detects the installed ones with `canOpenURL`, lists them, and opens the chosen app with the same parameters. If none is installed: **"No payment app found"** plus Copy UPI ID.
- Some UPI apps limit payments started from another app (for example to personal payees or above an amount) **[VERIFY: CAM-57]**; when an app refuses, the card stays open with Copy UPI ID.

**Rules:**
- Payment codes **never auto-redirect**, even from history or a saved code: Pay always goes through the confirm card.
- Danaview **never processes, stores or confirms payments**, and never handles money, bank details or payment credentials. It only hands off to the user's payment app.
- Payment result callbacks, if a payment app sends one, are ignored except to show **"Returned from payment app"**. Danaview never says "Paid".

### 13.5 Saved codes (D-115k)

A new **Saved code** item type in the Files & Media Home (HOM §8.1's open kind list; extended by CAM-56 on top of HOM-16, HOM-17 and HOM-19). Saved codes can be filed into any Danaview folder and appear under a `Saved codes` filter.

| Field | Notes |
|---|---|
| Raw payload | exactly the decoded bytes / text, and the symbology (QR, EAN-13, …) |
| Code image | a crisp image **regenerated** from the payload (pure-Dart encoder, licence checked in CAM-56), not the blurry photo |
| Decoded type and fields | from the CAM-54 parser (URL, Wi-Fi, UPI payee and amount, …) |
| Title | "Whose QR is this", for example "Electricity bill" or "Ravi's UPI" |
| Note, tags | free text, user tags |
| Date saved | automatic |
| Due date / reminder | optional; a **local notification** on the device (no server, no push), for example "Pay electricity bill" |
| Scan location | optional, **off by default**; one location fix at save time with when-in-use permission |

What users can do: edit the info; **show full screen** (maximum brightness, so someone else can scan it); share as an image (the regenerated code plus its title); **Pay now** (the same confirm card and hand-off as §13.4); search saved codes by title, note, tags, payee or domain; sort by due date; a **"Due soon"** filter (due in the next 7 days or overdue).

Storage follows the Danaview folders (app-private, in app backups, HOM D-98b). Reminders are rescheduled after a restore.

### 13.6 Scan history (D-115l)

- A local list of recent scans (payload, type, time; never the camera frame). Private, never synced, never sent.
- Settings: **History on/off** (proposed on **[OWNER]**), **Clear history**, **Auto-delete after** 7 / 30 (default) / 90 days or never.
- Turning history off deletes it and records nothing new. From history, any item can be saved as a saved code.

### 13.7 Create QR (D-115m, **[OWNER]**)

If the owner says yes: create a QR for a link, text, Wi-Fi network or contact, and a **personal UPI receive QR** (`pa`, `pn`, optional `am`) so someone can pay the user. Created codes can be saved as saved codes, shown full screen or shared as an image. Nothing is sent anywhere.

### 13.8 Privacy and safety (D-115n)

- **Fully on device:** detection, decoding, parsing, URL checks and history make **no network requests**. The network is used only when the user taps an action that needs it (Open in browser, Search the web, Load preview if offered), and then by the browser or the target app.
- **No automatic actions:** nothing opens, joins, dials, adds or pays without a tap on the card; payment codes always show the confirm card first.
- **Quishing warnings** on suspicious links (§13.2), and "check the payee name" on every payment card.
- **Permissions:** camera; notifications only when the user sets the first reminder; location only when the user turns on scan location; no contacts or calendar permission for adding entries through the system sheets **[VERIFY: CAM-55]**.
- **Privacy policy (CAM-45):** add plain bullets: codes are read on the device; scan history and saved codes stay on the device (in app backups with the Danaview folders); payment codes are handed to the payment app the user picks, and Danaview sees no payment details beyond what the code contains.

---

## Appendix A. Beauty catalogue (owner's list) with live tiers

**Live tiers (D-103):** **Core** = live on every tier that supports beauty. **Heavy** = live on the high tier only; applied after capture elsewhere. Core: everything in sections 1–4 except neural blemish inpainting, plus lipstick, blush and contour, eyeliner and eyeshadow, foundation and concealer from section 5, and filters, before/after and intensity from section 7. Heavy: neural acne and blemish inpainting, virtual contact lenses, hair colour and hairstyle effects, freckles, all of section 6 (body), background portrait blur without native depth, and AR face masks and stickers.

### A.1 Full catalogue

The native camera beauty engine runs real-time on-device facial landmark tracking (468+ points) and skeletal/body contour estimation via GPU compute shaders (Metal on iOS/macOS, OpenGL ES 3.2 / Vulkan on Android, Direct3D 11 / DirectML on Windows), operating at 60 fps during live preview, photo capture, and video recording.

#### 1. Face Shape & Slimming
- **Face Slimming / Narrow Face**: Bilateral radial deformation targeting the cheek and outer facial boundary to smoothly slim the overall facial width.
- **V-Shaped Face**: Dynamic interpolation tapering the lower jaw inward toward the chin apex for a natural V-line aesthetic.
- **Jawline Sharpening**: High-contrast contour adjustment and localized mesh lifting defining the mandibular border.
- **Chin Slimming & Shortening**: Independent two-axis chin control—narrowing breadth and adjusting vertical chin length (shorten / elongate / sharpen).
- **Forehead Width & Height Adjustment**: Smooth hairline translation and temporal boundary scaling to balance facial thirds.
- **Lower-Face Slimming**: Targeted contouring between the mouth corners and mandibular angle without affecting upper cheek structure.
- **Cheekbone Enhancement**: Inward cheekbone softening (reduce prominent zygomatic arches) or lifting/contouring for sculpted cheek definition.
- **Face Symmetry Correction**: Dual-hemisphere landmark alignment mirroring and subtly balancing asymmetric eye, jaw, or lip planes.
- **Overall Face Reshape**: Master proportion scaling harmonizing the Golden Ratio across upper, middle, and lower facial thirds.

#### 2. Eyes & Eyebrows
- **Eye Enlargement**: Spherical iris-anchored magnification preserving eye shape fidelity without distortion.
- **Eye Shape & Angle Adjustment**: Outer canthus lifting / lowering (cat-eye, puppy-eye, doe-eye tilt) and vertical aperture rounding.
- **Eye Spacing & Positioning**: Interpupillary distance adjustment (widen / narrow spacing) and vertical eye level positioning.
- **Eye Brightening**: Sclera brightening and specular reflection enhancement delivering vibrant catchlights.
- **Dark-Circle & Eye-Bag Removal**: Selective luminance lifting and bilateral chroma de-shadowing under the lower eyelid.
- **Eyebrow Thickness, Shape & Positioning**: Eyebrow arch lift, tail extension, thickness control, and brow-to-eye distance balancing.
- **Eyelash Enhancement**: Procedural upper and lower eyelash volume thickening, elongation, and curl rendering.

#### 3. Nose & Lips
- **Nose Slimming & Narrowing**: Lateral nasal bone and alar wing compression for a refined nasal silhouette.
- **Nose Length & Bridge Adjustment**: Nasal bridge elevation/straightening and vertical nose length adjustment.
- **Nose-Tip Reshaping**: Precision spherical scaling of the nasal tip (sharpen, lift, or reduce bulbous tips).
- **Lip Enlargement & Resizing**: Volumetric upper and lower lip plumping with independent vermilion border scaling.
- **Lip Shape & Thickness Adjustment**: Cupid's bow contouring, lip corner lifting, and upper-to-lower lip ratio tuning.
- **Smile Adjustment**: Bilateral oral commissure lifting creating a natural, joyful smile expression even in neutral pose.

#### 4. Skin Retouching
- **Skin Smoothing**: Multi-scale bilateral / domain-transform filter eliminating pores and uneven texture while preserving eye, hair, and clothing sharpness.
- **Acne & Blemish Removal**: Automated patch-based neural inpainting and high-frequency spot elimination.
- **Dark-Spot Removal**: Melanin-selective chrominance balancing attenuating sunspots and hyperpigmentation.
- **Skin Tone & Brightness Adjustment**: Parametric skin illumination (porcelain fair, sun-kissed warm, bronzed, neutral pink, rich deep).
- **Oiliness Reduction (Anti-Shine)**: Specular highlight attenuation on the T-zone, forehead, and chin to create a velvety matte finish.
- **Wrinkle Softening**: Non-destructive micro-contrast smoothing fading forehead lines, nasolabial folds, and crow's feet.
- **Natural Glow**: Diffuse subsurface-scattering simulation adding translucent vitality and luminous skin radiance.
- **Teeth Whitening**: Blue-balanced dental chroma desaturation and luminance elevation targeting the oral aperture.

#### 5. Makeup & Appearance
- **Foundation & Concealer**: Seamless digital foundation layer blending skin coloration with customizable coverage opacity.
- **Lipstick**: Matte, satin, glossy, and velvet finishes across curated color palettes with edge feathering and gradient ombré modes.
- **Blush & Contour**: Anatomical cheekbone blush application (coral, peach, rosy, plum) and 3D jaw/nose contour shading.
- **Eyeliner & Eyeshadow**: Winged, tightline, and smokey eyeliner styles paired with multi-tone blending eyeshadow gradients.
- **Virtual Colored Contact Lenses**: Procedural iris texture overlays (hazel, crystal gray, emerald green, deep sapphire) with natural pupil dilation.
- **Hair Color & Hairstyle Effects**: Real-time hair strand segmentation with chromatic tinting (ash blonde, chestnut, neon, highlights) and hairline fullness.
- **Freckles & Beauty Marks**: Customizable sun freckle patterns and aesthetic facial beauty marks with variable density and alpha.

#### 6. Body Slimming & Proportions
- **Body Reshaping**: Real-time skeletal pose detection adjusting full-body silhouette contours.
- **Waist Slimming**: Bilateral torso narrowing creating a natural hourglass waistline while preserving surrounding backgrounds via smart mesh anchors.
- **Arm & Leg Slimming**: Targeted cylindrical deformation slimming upper arms, thighs, and calves.
- **Hip & Shoulder Adjustments**: Shoulder width refinement (broaden / soften) and pelvic curve enhancement.
- **Leg-Length Adjustment**: Lower-extremity vertical stretching with ground-plane anchoring for statuesque proportions.
- **Height & Body-Proportion Correction**: Head-to-body ratio adjustment and postural straightening (spine and neck alignment).

#### 7. Camera, Filters & Effects
- **Real-Time Beauty Filters**: Ultra-low latency GPU shaders applying combined beauty grades at full capture frame rates.
- **Filter Styles**: "Natural Pure", "Soft Glow", "Cinematic Glam", "Vintage Film 35mm", "Retro VHS", "Pastel Dream".
- **Background Blur & Portrait Effects**: Depth-map segmentation creating adjustable optical bokeh ($f/1.4$ to $f/16$), studio lighting, and stage spotlight.
- **AR Face Masks & Interactive Stickers**: 3D face-anchored tracking for dynamic aesthetic stickers, glasses, headwear, and seasonal masks.
- **Photo & Video Retouching Cohesion**: Identical shader pipeline powers live camera capture, photo editing, and timeline video clips.
- **Before-and-After Comparison**: Split-screen swipe or press-and-hold instant toggle comparing original unretouched and beautified streams.
- **Adjustable Effect Intensity**: Universal master slider (0–100%) plus granular per-feature micro-sliders.
- **Undo, Redo & Reset**: Full history stack for manual adjustments with one-tap section resets.

#### 8. Advanced Intelligence & Management
- **AI Face Detection & Facial Landmarks**: 468 3D landmark points tracking under extreme head pose angles ($\pm 60^\circ$ yaw/pitch).
- **Automatic Face Enhancement**: One-tap smart enhancement automatically analyzing facial structure and applying ideal harmonious values.
- **Manual Adjustment Sliders**: Precision floating point numeric control for pro creators.
- **HD Photo Export & 4K Video Retouching**: Full-bitness rendering preserving native sensor resolution without downsampling artifacts.
- **Preset Beauty Styles**: Factory curated profiles: "Everyday Clean", "Editorial Model", "K-Beauty Dewy", "Bronze Glow", "Studio Portrait".
- **Save Custom Beauty Settings**: Export and save user-tailored beauty parameter presets stored in local secure JSON preferences.

```
+---------------------------------------------------------------------------------------------------+
|  DANAVIEW CAMERA BEAUTY SUITE                                                    [ Before / After ]|
+---------------------------------------------------------------------------------------------------+
|  [ Face Shape ]  [ Eyes/Brows ]  [ Nose/Lips ]  [ Skin ]  [ Makeup ]  [ Body ]  [ Filters ]  [ Presets ]
+---------------------------------------------------------------------------------------------------+
|  Master Beauty: [ ON ]                                               Intensity: [====o===] 75%    |
|                                                                                                   |
|  Face Slimming:    [ - ]======o===========[ + ] 55%    Skin Smoothing:    [ - ]=======o========[ + ] 65%  |
|  V-Shape Face:     [ - ]====o=============[ + ] 40%    Acne / Blemishes:  [ - ]=========o======[ + ] 85%  |
|  Jawline Sharpen:  [ - ]=====o============[ + ] 50%    Dark Circles:      [ - ]=======o========[ + ] 60%  |
|  Chin Slim/Length: [ - ]====o=============[ + ] 35%    Teeth Whitening:   [ - ]========o=======[ + ] 75%  |
|  Eye Enlarge:      [ - ]===o==============[ + ] 30%    Lipstick (Matte):  [ - ]=====o==========[ + ] 45%  |
|  Nose Slimming:    [ - ]====o=============[ + ] 42%    Waist Slimming:    [ - ]====o===========[ + ] 38%  |
|  Nose Bridge/Tip:  [ - ]=====o============[ + ] 48%    Leg Elongation:    [ - ]===o============[ + ] 25%  |
+---------------------------------------------------------------------------------------------------+
|  [ 🔄 Reset Section ]                         [ 💾 Save Preset ]                     [ ✨ Auto Enhance ]|
+---------------------------------------------------------------------------------------------------+
```

