# Danaview 1.3.0 Release Roadmap: The Visual Creation & Capture Suite

> **Release:** Danaview 1.3.0 (app version `1.3.0+N`). **Date:** 2026-10-12. **Status:** Master Roadmap & Architectural Overview.
> **Baseline Releases:**
> - Danaview 1.0: Cross-platform media player (libmpv, equalizers, subtitles, hardware decode).
> - Danaview 1.1: Multi-track video editor on iOS and Android (`docs/v1.1/editor/ARCHITECTURE.md`, `BUILD_PLAN.md`).
> - Danaview 1.2: AI Studio & Advanced Subtitles (`docs/v1.2/ai-studio/AI_STUDIO_PLAN.md`) + Desktop Video Editors for macOS, Windows, and Linux (`docs/v1.2/editor-desktop/DESKTOP_EDITOR_PLAN.md`).
> **Core Theme:** **Complete Media Symmetry**. Unifying Photos and Videos into a single cohesive ecosystem: a unified home library, an in-house native capture camera with real-time beauty & dual capture, and a unified photo and video editor serving both still post-processing and timeline video editing based on user intent.

---

## 1. The Three Pillars of Danaview 1.3.0

```
                      +---------------------------------------------------------------+
                      |                        DANAVIEW 1.3.0                         |
                      |                 The Visual Creation Suite                     |
                      +---------------------------------------------------------------+
                                                      |
                         +----------------------------+----------------------------+
                         |                            |                            |
                         v                            v                            v
              +--------------------+       +--------------------+       +--------------------+
              |      PILLAR 1      |       |      PILLAR 2      |       |      PILLAR 3      |
              | Unified Home Media |       |   Native Camera    |       | Unified Editor     |
              |  Photos & Videos   |       |  Capture & Beauty  |       | Photo & Video Edit |
              +--------------------+       +--------------------+       +--------------------+
              | • All Media view   |       | • Photo & Video    |       | • Still Photo Mode |
              | • Folder browser   |       | • Face slimming    |       | • Timeline Video   |
              | • Album explorer   |       | • Face reshaping   |       | • 16-bit float tone|
              | • Fast thumbnails  |       | • Pro manual mode  |       | • HSL & RGB curves |
              | • Montage maker    |       | • Dual front+back  |       | • 8-Category Beauty|
              | • Direct editor    |       | • Device BG audio  |       | • One-Euro filter  |
              | • Player preserved |       | • Dynamic overlays |       | • Batch & 4K export|
              +--------------------+       +--------------------+       +--------------------+
```

### Pillar 1: Unified Media Home Screen
- **Document:** [`docs/v1.3/home-photo-video-view/HOME_PHOTO_VIDEO_PLAN.md`](file:///Users/besaoct/Desktop/danaview/docs/v1.3/home-photo-video-view/HOME_PHOTO_VIDEO_PLAN.md)
- **Summary:** Expands the Danaview Home Screen into a unified media browser. Users can explore all photos and videos on their device, browse physical folders or system albums, view high-res previews, and launch playback or open the editor with a single tap. Multi-selection allows instant creation of video montages from chosen photos and clips. Crucially, 100% of player, playlist, queue, continue watching, and folder features remain intact and active.

### Pillar 2: In-House Native Camera Engine (Photo & Video Capture)
- **Document:** [`docs/v1.3/camera-photo-video/NATIVE_CAMERA_PLAN.md`](file:///Users/besaoct/Desktop/danaview/docs/v1.3/camera-photo-video/NATIVE_CAMERA_PLAN.md)
- **Summary:** A custom camera built directly on native OS frameworks (`AVFoundation`, `Camera2/CameraX`, `DirectShow/MediaCapture`, `V4L2`). Highlights include the **8-category Beauty & Retouching Suite** (real-time face slimming, V-line jaw, chin/forehead contouring, eye enlargement & brightening, nose & lip reshaping, skin smoothing, acne/dark-spot removal, virtual makeup, body & leg slimming), cinematic 24 fps recording with synthetic bokeh, pro manual exposure/focus controls, dynamic live text/mask overlays, concurrent dual front+back camera recording with customizable PIP shapes and ratios, and internal background device audio recording with mic opt-out.

### Pillar 3: Unified Photo & Video Editor (Still Photo Mode & Multi-Track Timeline)
- **Document:** [`docs/v1.3/video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md`](file:///Users/besaoct/Desktop/danaview/docs/v1.3/video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md)
- **Summary:** Upgrades the Danaview Editor to dynamically handle both photo editing and video editing based on user intent. When opening photos, it provides a 16-bit half-float still-image workspace with pro exposure/light controls, 8-channel HSL color mixer, spline RGB curves, selective gradient/brush masks, perspective keystone correction, batch export, and instant "Add to Timeline" conversion. For video clips and projects, it provides multi-track timeline editing, frame-accurate trimming, transitions, keyframing, and the **complete 8-category Beauty & Retouching Suite** stabilized across moving frames with temporal One-Euro landmark filtering.

---

## 2. Core Architectural Principles in v1.3.0

1. **Hardware-Aware Progressive Enhancement & Graceful Degradation**:
   - If a device or operating system does not support a capability (e.g., dual concurrent multicam, LiDAR depth, manual shutter speed on basic webcams, or internal audio capture on older Android versions), **the feature is completely hidden from the UI**.
   - No disabled buttons, no greyed-out sliders, no confusing error modals. The UI dynamically adapts to the exact capabilities of the running hardware.
2. **Absolute Non-Destructive Invariance**:
   - Original photos and video files are treated as read-only and immutable. Edits exist as lightweight command recipes (`.dnphoto` for photos, `.dnproj` for video timelines).
3. **Privacy & Offline Guarantee**:
   - Every feature in v1.3.0 runs 100% on-device. Face tracking, mesh deformation, image processing, and audio routing require zero network permissions and communicate with zero external servers.
4. **Owner Standing UI Adherence**:
   - Every new screen and control uses custom `danaview_ui_kit` components, Figtree typography, dark UI surfaces, computed contrast ratios ($\ge 4.5:1$), and touch targets $\ge 44\text{ px}$.
5. **100% Preservation of Media Player, Playlist & Queue Features**:
   - Absolutely zero existing player functionality is removed or compromised. The Now Playing card, Continue Watching tray (resume progress, episode badges, clear history), Playlists (create, rename, delete, shuffle, play all), Folders (device storage, external directories, breadcrumbs), Playback Queue, and streaming URL opening (HTTP, RTSP, RTMP, SRT, UDP) remain 100% active, prominent, and untouched.

---

## 3. Directory Navigation & Plan Index

| Component | Target Location | Specification Document |
|---|---|---|
| **Desktop Video Editor (v1.2)** | `docs/v1.2/editor-desktop/` | [DESKTOP_EDITOR_PLAN.md](file:///Users/besaoct/Desktop/danaview/docs/v1.2/editor-desktop/DESKTOP_EDITOR_PLAN.md) |
| **AI Studio (v1.2)** | `docs/v1.2/ai-studio/` | [AI_STUDIO_PLAN.md](file:///Users/besaoct/Desktop/danaview/docs/v1.2/ai-studio/AI_STUDIO_PLAN.md) |
| **Unified Home Media (v1.3)** | `docs/v1.3/home-photo-video-view/` | [HOME_PHOTO_VIDEO_PLAN.md](file:///Users/besaoct/Desktop/danaview/docs/v1.3/home-photo-video-view/HOME_PHOTO_VIDEO_PLAN.md) |
| **In-House Native Camera (v1.3)**| `docs/v1.3/camera-photo-video/` | [NATIVE_CAMERA_PLAN.md](file:///Users/besaoct/Desktop/danaview/docs/v1.3/camera-photo-video/NATIVE_CAMERA_PLAN.md) |
| **Unified Photo & Video Editor (v1.3)** | `docs/v1.3/video-editor-update/` | [VIDEO_EDITOR_UPDATE_PLAN.md](file:///Users/besaoct/Desktop/danaview/docs/v1.3/video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md) |
| **v1.3 Master Roadmap** | `docs/v1.3/` | [V1_3_ROADMAP.md](file:///Users/besaoct/Desktop/danaview/docs/v1.3/V1_3_ROADMAP.md) |
