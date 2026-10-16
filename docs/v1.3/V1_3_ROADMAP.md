# Danaview 1.3.0 Release Roadmap: Desktop Editor and Native Camera

> **Release:** Danaview 1.3.0 (app version `1.3.0+N`). **Date:** 2026-10-12, contents changed by the owner on 2026-10-15. **Status:** Master roadmap and overview.
> **Baseline releases:**
> - Danaview 1.0: cross-platform media player (libmpv, equalizer, subtitles, hardware decode).
> - Danaview 1.1: multi-track video editor on iOS and Android (`docs/v1.1/editor/ARCHITECTURE.md`, `BUILD_PLAN.md`).
> - Danaview 1.2: Files & Media Home (photos, videos, documents, PDF tools), AI Studio & advanced subtitles (speaker lanes, AI search), and the Unified Photo & Video Editor with the beauty suite, on iOS and Android (`docs/v1.2/V1_2_ROADMAP.md`).
> **Change on 2026-10-15:** the Home screen and the Unified Photo & Video Editor moved to 1.2.0; the desktop editor moved here from 1.2.0. 1.3.0 is now the desktop editor plus the in-house camera.
> **Core theme:** **Everywhere and at capture.** The 1.2.0 photo and video editor reaches macOS, Windows and Linux, and Danaview gets its own camera with real-time beauty built on the 1.2.0 beauty engine.
> **Widened on 2026-10-16 (owner):** the camera also scans documents (OCR, searchable PDFs, image to PDF) and QR codes and barcodes (result cards that preview before acting, payment hand-off to the user's own UPI app, saved codes with reminders).

---

## 1. The two pillars of Danaview 1.3.0

```
                      +---------------------------------------------------------------+
                      |                        DANAVIEW 1.3.0                         |
                      |              Desktop Editor and Native Camera                 |
                      +---------------------------------------------------------------+
                                                      |
                                   +------------------+------------------+
                                   |                                     |
                                   v                                     v
                        +----------------------+              +----------------------+
                        |       PILLAR 1       |              |       PILLAR 2       |
                        |    Desktop Editor    |              |    Native Camera     |
                        | macOS · Windows ·    |              |  Capture & Beauty    |
                        |        Linux         |              |                      |
                        +----------------------+              +----------------------+
                        | • Swift (macOS) +    |              | • Native, zero-copy  |
                        |   Rust (Win/Linux)   |              | • Thumb dial, My Mode|
                        | • Photo mode, beauty |              | • Live beauty, pro   |
                        | • 3-pane workspace   |              | • Cinematic & bokeh  |
                        | • Razor/slip/ripple  |              | • Dual front+back    |
                        | • J-K-L, scopes      |              | • Live overlays      |
                        | • HW export, parity  |              | • Audio routing      |
                        | • PDF viewer & tools |              | • Document scan, OCR |
                        |   on Windows/Linux   |              |   & PDF export       |
                        |                      |              | • QR & barcodes, pay |
                        |                      |              |   hand-off, saved    |
                        |                      |              |   codes              |
                        +----------------------+              +----------------------+
```

### Pillar 1: Desktop Photo & Video Editor (macOS, Windows, Linux)
- **Document:** [`docs/v1.3/editor-desktop/DESKTOP_EDITOR_PLAN.md`](editor-desktop/DESKTOP_EDITOR_PLAN.md) (DSK-01 to DSK-40, decisions D-71 to D-85; rewritten 2026-10-15).
- **Summary:** Two native engines behind the same editor API: macOS reuses the iOS Swift/Metal/AVFoundation engine; Windows and Linux share one Rust engine (`wgpu` rendering on Direct3D 12 / Vulkan, Media Foundation and GStreamer for hardware decode and encode). Unusual formats open through an isolated FFmpeg helper process that converts them on import, so a bad file cannot crash the app. Desktop extras: 4K preview without proxies, GPU speech recognition, batch export, ProRes export on macOS, colour scopes. Because 1.2.0 already added photo mode and the beauty suite, the desktop engines run those too, and the parity suite checks them against mobile. The desktop UX adds a 3-pane workspace, cursor tools, J-K-L shuttle, multi-monitor preview, native drag and drop and menus. DSK-20 also turns on the Home screen's editor actions on desktop. The Files & Media Home's native PDF viewing and PDF tools reach Windows and Linux with this desktop work (HOM D-98k; macOS has them from 1.2.0).

### Pillar 2: In-House Native Camera (photo and video capture)
- **Document:** [`docs/v1.3/camera-photo-video/NATIVE_CAMERA_PLAN.md`](camera-photo-video/NATIVE_CAMERA_PLAN.md) (CAM-01 to CAM-60, decisions D-99 to D-115 and D-115a to D-115n; rewritten 2026-10-15, widened 2026-10-16).
- **Summary:** A capture module inside each existing engine (Swift on iOS/macOS, CameraX + Camera2Interop on Android, Rust on Windows/Linux), so the camera reuses the 1.2.0 face tracker, beauty shaders, LUTs, overlays and hardware encoders, and live beauty looks exactly like the editor's. Every control in one hand: a haptic thumb dial (zoom, EV, ISO, shutter, focus, white balance, beauty), a user-chosen quick bar, saved "My Modes", left-handed layout, volume-button and iPhone Camera Control shutter, lock-screen / Control Center / Quick Settings launch. Fast: viewfinder in ≤ 0.5 s warm, zero shutter lag, zero-copy frames. Native pro features first (ProRAW, Apple Log, ProRes, HLG, RAW DNG, Android Night/HDR/Bokeh extensions, iOS Cinematic Video). Core beauty live on all phones, heavy effects live on high-end phones and after capture elsewhere. "Keep editable" saves the clean original plus a recipe the editor can reopen. Rollout: iOS and Android first, macOS (webcams, Continuity Camera) next, Windows/Linux webcams last (may ship in 1.3.x).
- **Added 2026-10-16:**
  - **Document scan & PDF:** a Scan mode with edge detection, auto-capture, perspective correction and colour / greyscale / black-and-white filters (VisionKit on iOS; ML Kit Document Scanner on Android, with a Danaview fallback when Google Play services is missing); on-device OCR for searchable, selectable PDFs whose text also feeds AI search; image to PDF and "Export as PDF" for photos in the Home; merge, export as PDF/JPEG/PNG, share or save to Danaview folders, Files or Downloads. It reuses the 1.2.0 PDF tools.
  - **QR and barcode scanning:** live in the camera, in a dedicated Scan mode and from photos or files; QR, Data Matrix, Aztec, PDF417, EAN/UPC and Code 128. Every code opens a smart result card first (full domain and phishing warnings for links; Wi-Fi join, contacts, calendar, email, SMS, phone, maps, app links, product search), never acting on its own.
  - **Payment hand-off, redirect only:** UPI and EMVCo / Bharat QR codes show a confirm card (payee, UPI ID, amount, note), then open the user's own payment app. Danaview never processes, stores or confirms payments.
  - **Saved codes** in the Files & Media Home (title, note, tags, due-date reminders, show full screen, Pay now), plus a private scan history and an optional Create QR.

---

## 2. Order and dependencies inside 1.3.0

1. **Starts after 1.2.0 ships.** Both pillars depend on 1.2.0 work: the desktop engines must render VED's photo and beauty passes, and the camera reuses VED's tracker and shaders, the Home's `danaview_pdf` plugin and file model (HOM-16…HOM-31) and AI Studio's `danaview_media_analysis` plugin (AIS-50).
2. **The two pillars are independent** and can run in parallel: desktop work splits by platform (macOS on the Mac, Windows on the Windows laptop, Linux needs a Linux machine or VM). The camera needs a real-device lab (an iPhone 16 or newer, an older iPhone, a Pixel, a Samsung and a budget Android phone), because the iOS Simulator has no camera and the Android emulator only has a virtual one. The camera's Windows/Linux webcam milestone builds on the desktop Rust engine and comes last.
3. **Settled feasibility points:** iOS does not let camera apps record other apps' sound (iOS gets "keep music playing while recording"; true internal audio on Android 10+, Windows, macOS 13+ and Linux) and has no third-party night mode (Apple's quality prioritisation is used); FFmpeg on desktop runs only in a separate LGPL decode-only helper process (owner, 2026-10-15).

---

## 3. Core principles in 1.3.0

1. **Graceful degradation:** if a device or OS lacks a capability (dual camera, depth, manual shutter, internal audio, hardware encoder), the control is hidden, not disabled.
2. **Non-destructive:** originals stay read-only; edits stay `.dnphoto` / `.dnproj` recipes.
3. **Privacy and offline:** capture, face tracking, rendering, document scanning, OCR and code decoding run fully on device with no network use. A scanned code never acts without a tap, and payment codes only hand off to the user's payment app.
4. **Owner UI rules:** custom `danaview_ui_kit` components, Figtree, dark UI, computed contrast (≥ 4.5:1), touch targets ≥ 44 px.
5. **Player preserved:** no player, playlist, queue or streaming feature is removed or changed.

---

## 4. Plan index

| Component | Location | Document |
|---|---|---|
| **Desktop Photo & Video Editor (1.3)** | `docs/v1.3/editor-desktop/` | [DESKTOP_EDITOR_PLAN.md](editor-desktop/DESKTOP_EDITOR_PLAN.md) |
| **In-House Native Camera (1.3)** | `docs/v1.3/camera-photo-video/` | [NATIVE_CAMERA_PLAN.md](camera-photo-video/NATIVE_CAMERA_PLAN.md) |
| **1.3 roadmap** | `docs/v1.3/` | this file |
| **1.2 roadmap (Files & Media Home, AI Studio, Unified Editor)** | `docs/v1.2/` | [V1_2_ROADMAP.md](../v1.2/V1_2_ROADMAP.md) |
