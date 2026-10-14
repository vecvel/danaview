# Danaview 1.3.0 Release Roadmap: Desktop Editor and Native Camera

> **Release:** Danaview 1.3.0 (app version `1.3.0+N`). **Date:** 2026-10-12, contents changed by the owner on 2026-10-15. **Status:** Master roadmap and overview.
> **Baseline releases:**
> - Danaview 1.0: cross-platform media player (libmpv, equalizer, subtitles, hardware decode).
> - Danaview 1.1: multi-track video editor on iOS and Android (`docs/v1.1/editor/ARCHITECTURE.md`, `BUILD_PLAN.md`).
> - Danaview 1.2: Unified Media Home, AI Studio & advanced subtitles, and the Unified Photo & Video Editor with the beauty suite, on iOS and Android (`docs/v1.2/V1_2_ROADMAP.md`).
> **Change on 2026-10-15:** the Home screen and the Unified Photo & Video Editor moved to 1.2.0; the desktop editor moved here from 1.2.0. 1.3.0 is now the desktop editor plus the in-house camera.
> **Core theme:** **Everywhere and at capture.** The 1.2.0 photo and video editor reaches macOS, Windows and Linux, and Danaview gets its own camera with real-time beauty built on the 1.2.0 beauty engine.

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
                        | • Swift (macOS) +    |              | • Photo & video      |
                        |   Rust (Win/Linux)   |              | • Live beauty (60fps)|
                        | • Photo mode, beauty |              | • Pro manual mode    |
                        | • 3-pane workspace   |              | • Cinematic & bokeh  |
                        | • Razor/slip/ripple  |              | • Dual front+back    |
                        | • J-K-L, multi-screen|              | • Live overlays      |
                        | • HW export, parity  |              | • Audio routing      |
                        +----------------------+              +----------------------+
```

### Pillar 1: Desktop Photo & Video Editor (macOS, Windows, Linux)
- **Document:** [`docs/v1.3/editor-desktop/DESKTOP_EDITOR_PLAN.md`](editor-desktop/DESKTOP_EDITOR_PLAN.md) (DSK-01 to DSK-40, decisions D-71 to D-85; rewritten 2026-10-15).
- **Summary:** Two native engines behind the same editor API: macOS reuses the iOS Swift/Metal/AVFoundation engine; Windows and Linux share one Rust engine (`wgpu` rendering on Direct3D 12 / Vulkan, Media Foundation and GStreamer for hardware decode and encode). Unusual formats open through an isolated FFmpeg helper process that converts them on import, so a bad file cannot crash the app. Desktop extras: 4K preview without proxies, GPU speech recognition, batch export, ProRes export on macOS, colour scopes. Because 1.2.0 already added photo mode and the beauty suite, the desktop engines run those too, and the parity suite checks them against mobile. The desktop UX adds a 3-pane workspace, cursor tools, J-K-L shuttle, multi-monitor preview, native drag and drop and menus. DSK-20 also turns on the Home screen's editor actions on desktop.

### Pillar 2: In-House Native Camera (photo and video capture)
- **Document:** [`docs/v1.3/camera-photo-video/NATIVE_CAMERA_PLAN.md`](camera-photo-video/NATIVE_CAMERA_PLAN.md) (CAM-01 to CAM-20, decisions D-99 to D-115).
- **Summary:** A first-party camera on AVFoundation and Camera2/CameraX (plus desktop webcams): photo and video modes, real-time beauty using the 1.2.0 landmark tracker and shaders (VED-16, VED-20…23) on the live stream, cinematic 24 fps with depth bokeh, pro manual controls, live text and mask overlays, dual front+back capture with custom picture-in-picture, and audio routing. Captures open directly in the editor and appear in the Home library.

---

## 2. Order and dependencies inside 1.3.0

1. **Starts after 1.2.0 ships.** Both pillars depend on 1.2.0 work: the desktop engines must render VED's photo and beauty passes, and the camera reuses VED's tracker and shaders.
2. **The two pillars are independent** and can run in parallel: desktop work splits by platform (macOS on the Mac, Windows on the Windows laptop, Linux needs a Linux machine or VM); camera work needs real phones, because the iOS Simulator has no camera and the Android emulator only has a virtual one.
3. **Feasibility notes to settle while planning:** iOS does not let a third-party camera app record other apps' audio (camera D-107 internal audio is Android 10+ only, with the user's capture consent); FFmpeg on desktop is settled (owner, 2026-10-15): only in a separate helper process, LGPL and decode-only, never GPL encoders.

---

## 3. Core principles in 1.3.0

1. **Graceful degradation:** if a device or OS lacks a capability (dual camera, depth, manual shutter, internal audio, hardware encoder), the control is hidden, not disabled.
2. **Non-destructive:** originals stay read-only; edits stay `.dnphoto` / `.dnproj` recipes.
3. **Privacy and offline:** capture, face tracking and rendering run fully on device with no network use.
4. **Owner UI rules:** custom `danaview_ui_kit` components, Figtree, dark UI, computed contrast (≥ 4.5:1), touch targets ≥ 44 px.
5. **Player preserved:** no player, playlist, queue or streaming feature is removed or changed.

---

## 4. Plan index

| Component | Location | Document |
|---|---|---|
| **Desktop Photo & Video Editor (1.3)** | `docs/v1.3/editor-desktop/` | [DESKTOP_EDITOR_PLAN.md](editor-desktop/DESKTOP_EDITOR_PLAN.md) |
| **In-House Native Camera (1.3)** | `docs/v1.3/camera-photo-video/` | [NATIVE_CAMERA_PLAN.md](camera-photo-video/NATIVE_CAMERA_PLAN.md) |
| **1.3 roadmap** | `docs/v1.3/` | this file |
| **1.2 roadmap (Home, AI Studio, Unified Editor)** | `docs/v1.2/` | [V1_2_ROADMAP.md](../v1.2/V1_2_ROADMAP.md) |
