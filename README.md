<div align="center">

# 🎬 Danaview

**The all-in-one media player, in-house native camera, and unified photo & on-device video editor.**
*Powered by Flutter, libmpv, native GPU capture & render engines, and on-device AI.*

[![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Engine](https://img.shields.io/badge/Engine-libmpv%20%2B%20FFmpeg-5C2D91)](https://mpv.io)
[![AI Engine](https://img.shields.io/badge/AI-whisper.cpp%20(On--Device)-FF6F00)](https://github.com/ggml-org/whisper.cpp)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Android%20%7C%20iOS-22c55e)](#-supported-platforms)
[![License: Proprietary](https://img.shields.io/badge/License-Proprietary-red.svg)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](#-sponsor--support)

</div>

---

## 🌟 Overview

**Danaview** is an all-in-one visual media ecosystem bringing playback, creation, capture, and editing into a unified, privacy-first application across mobile and desktop.

- 🎥 **The Player** (available now, v1.0): plays almost any video file or network stream on Android, iOS, macOS, Windows and Linux, with a 10-band equalizer, volume boost up to 300%, subtitles, playlists, a queue, diagnostics and built-in network and media tools.
- ✂️ **The Unified Photo & Video Editor** (in development, v1.1.0 mobile · v1.2.0 desktop · v1.3.0 photo & beauty updates): a single, high-performance editor serving both photo editing and multi-track video editing dynamically based on user intent. Includes still photo post-processing (16-bit float pipeline, pro tone adjustments, 8-channel HSL color mixer, RGB curves, selective masks, perspective keystone, batch export), multi-track video timeline editing (frame-accurate cuts, transitions, keyframes, hardware export, and **on-device AI subtitles**), and the **complete 8-category Beauty & Retouching Suite** (face slimming, feature reshaping, blemish healing, virtual makeup, body slimming) with temporal One-Euro landmark tracking for moving video.
- 🤖 **AI Studio** (v1.2.0): optional bring-your-own-key intelligence for transcripts, translation, emotion detection, and advanced word-by-word karaoke styling.
- 📷 **The In-House Native Camera** (v1.3.0): high-performance capture built directly on native OS APIs (`AVFoundation`, `Camera2/CameraX`), featuring the **8-category real-time beauty & face reshaping suite**, cinematic portrait bokeh, pro manual controls (ISO, shutter, focus peaking), live overlays & masks, dual front+back simultaneous capture, and background device audio recording with external mic opt-out.
- 🗂️ **Unified Media Home** (v1.3.0): a unified visual media hub for browsing both photos and videos, system albums, and device folders—while **strictly preserving 100% of existing player, playlist, queue, and streaming features**.

**Legend:** ✅ available now · 🚧 in development · 🗓️ planned 

---

## 💖 Sponsor & Support

If you enjoy using **Danaview** or find our engineering helpful, consider sponsoring the project to support active development and upcoming features:

- 💖 **GitHub Sponsors**: [github.com/sponsors/vecvel](https://github.com/sponsors/vecvel)
- ☕ **Buy Me a Coffee**: [buymeacoffee.com/vecvel](https://buymeacoffee.com/vecvel)
- 🌐 **GitHub Profile**: [github.com/vecvel](https://github.com/vecvel)
- ✉️ **Support**: support@vecvel.com

---

## 🎬 Player Features ✅

### Playback & controls
- Plays local files and network streams through libmpv, with hardware decoding (Auto-safe, Auto or Software).
- Opens mkv, mp4, m4v, mov, avi, webm, ts, m2ts, mts, flv, wmv, ogv, 3gp, mpg and mpeg files.
- Controls fade out after 3 seconds and come back on tap or mouse hover. There's a big Play/Replay button and a loading spinner.
- **Touch gestures:**
  - Tap to show or hide the controls.
  - Double-tap the left or right side to seek back or forward. The step is 5, 10, 15 or 30 seconds (your choice), and repeated taps keep adding to the seek.
  - Double-tap the middle to play or pause.
- **Mouse:** click to play or pause, double-click for fullscreen.
- **Control lock:** hides every control and blocks touches and shortcuts. The unlock button fades away and reappears when you tap.
- **Seek bar:** tap or drag to seek, with a time tooltip, the buffered range and the A-B loop range shown on it.
- **Time display:** tap to switch between elapsed/total and remaining time.
- **Speed:** 0.25× to 3×, with the audio pitch kept natural. The speed is remembered between launches.
- **A-B loop:** set A, set B, clear.
- **Picture:** aspect ratio (Auto, 16:9, 4:3, 2.35:1), zoom from 50% to 300%, and color adjustments (brightness, contrast, saturation, gamma, hue), which are saved per video.
- **Orientation:** a "Rotate screen" button on phones. On iPhone the player follows how the phone is held, and phones keep the library in portrait.
- **Resume where you left off:** the position is saved automatically for every video.
- **Previous / Next:** Previous restarts the current video if it has played for more than 5 seconds.
- The screen stays awake while a video plays.
- **Clear error messages:** missing file, unsupported format, network, permission or audio device. Press Play to retry.
- **Adaptive toolbar:** buttons that don't fit move into a "More options" sheet.

### Audio
- Volume from 0% to 300%, with a highlighted boost zone above 100%, plus mute.
- **10-band graphic equalizer** (31 Hz – 16 kHz, ±12 dB per band).
- **Equalizer presets:** Flat, Rock, Pop, Bass Boost, Vocal / Dialogue, Classical, Cinema. "Custom" appears when you change bands yourself.
- **Night mode** (quiets loud parts and lifts quiet ones), and **loudness normalization** to -16 LUFS.
- **Audio delay:** ±2000 ms, saved per video.
- **Audio track switching.** Matching external audio files load automatically.

### Subtitles
- Subtitle files next to the video, or in a `Subs` / `Subtitles` folder, load automatically.
- Pick a subtitle track or turn subtitles off.
- **Subtitle delay:** ±5000 ms, saved per video.
- Font size (24–96 pt) and outline (0–8 px).
- Subtitles use the app's Figtree font.

### Library, playlists & queue
- **Home:**
  - "Now Playing" card.
  - Quick actions: Open file, Open folder, Open link.
  - **Continue watching:** progress bars, remove from history, clear all.
  - Playlists and folders.
- **Folders:** breadcrumbs, video counts, natural sorting (Episode 2 comes before Episode 10), season/episode badges (S01E02), Play all, Shuffle, Play next, Add to queue.
- **Playlists:** create, rename, delete, play, shuffle, add videos or links, drag to reorder, play from here.
- **Queue:** jump to any item, remove, drag to reorder, shuffle (restores the original order when turned off), repeat Off / All / One, and auto-play of the next video.
- **Open link:** plays http, https, rtsp, rtmp, srt, udp, rtp, mms and file URLs, with a paste button and address checking.
- **Open with Danaview:**
  - Android: open videos from other apps and links.
  - iOS: open from Files and from other apps.
  - macOS: open from Finder.
  - All platforms: `danaview://` links.
- **Drag and drop** of files and folders onto the player (desktop).

### Diagnostics
- **Stats for Nerds:** resolution, FPS, codecs, hardware decoding, dropped and delayed frames, A/V sync, bitrate, audio channels and color space. Copy the report with one tap.

### Settings, tools & account
- **Player settings panel:** Video, Color, Audio & Equalizer, Subtitles, Playback and a Keyboard Shortcuts list.
- **App Settings:**
  - Profile.
  - Tools.
  - Double-tap seek step.
  - About, Privacy Policy, Terms of Use.
- **Tools (built in, no third-party services):**
  - 📶 **Speed test:** ping, download, upload and jitter, with a live dial. Tells you what your connection can handle (4K/1080p/720p streaming, video calls, going live).
  - 🔎 **Stream check:** tells you whether a link will play. Detects HLS/DASH, quality levels, live vs on-demand, seeking support and DRM.
  - 🎞️ **Media info:** container, duration, size, bitrate and every track (codec, profile, language, HDR, rotation).
  - 📊 **Data usage calculator:** data needed for a watch time, or watch time for a data allowance, by quality.
  - 🗄️ **Storage & history:** app video and cache size, clear watch history, resume points or cache. Your videos are never deleted.
- **Profile:** name, email, phone and date of birth, stored on the device only.
- **About:** version and contact support.

### Desktop
- Custom title bar showing the video title, always-on-top pin and fullscreen. Windows and Linux get window buttons.
- On macOS the window reopens from the Dock, and there's a Main Window menu item.
- Keyboard shortcuts (see below).

---

## ✂️ Video Editor Features 🚧 (v1.1.0)

Built natively for **iPhone, iPad and Android** (iOS 15+, Android 10+):
- iOS engine: AVFoundation, Core Image and Metal.
- Android engine: Media3.
- Desktop editing will come later. On desktop, the editor entry points stay hidden for now.

**Opening the editor**
- Edit button on the Home screen, next to Settings.
- **Edit** while a video is playing, starting at the current position.

**Projects & timeline**
- Create, save, rename, duplicate, reopen and delete projects. Autosave, crash recovery and project format upgrades.
- **Non-destructive:** your original media is never modified, moved, renamed or deleted.
- **Multi-track timeline:** multiple video, audio, text, subtitle and image/overlay tracks.
- **Timeline view:** zoom and scroll, playhead and time ruler, snapping to clips, markers and the playhead.
- Single and multi-select, track lock, visibility, mute and solo.
- Clip thumbnails, audio waveforms, clip duration and details.
- Full undo/redo history.
- Detects missing media and lets you relink it. Media management.

**Basic editing**
- Import video, audio and images.
- Cut, trim, split, delete, duplicate, copy/paste and move.
- Ripple delete, ripple insert and replace media.
- Freeze frame, reverse video, frame-accurate seeking and markers.

**Transform**
- Position, scale, rotation, horizontal and vertical flip, crop, opacity and aspect ratio.
- Drag directly in the preview to adjust, and reset the transform in one tap.

**Speed**
- 0.25×, 0.5×, 0.75×, 1×, 1.25×, 1.5×, 2×, 3× and 4×, or a custom speed.
- Speed ramping.
- The audio pitch stays natural and audio stays in sync.

**Text**
- Text overlays with font, size, bold/italic, alignment, color, opacity, letter and line spacing, background, outline and shadow.
- Position, rotation, scale and duration.
- Animations: Fade, Slide, Scale and Typewriter.

**Subtitles**
- Create, edit, retime, move, split, merge and delete subtitles.
- Style them and position them on a subtitle track.
- Import and export SRT and VTT.
- Burn subtitles into the exported video.

**AI subtitles (on-device)**
- Generate subtitles straight from a video or audio clip in the language you choose.
- Processing:
  - Extracts the audio.
  - Turns speech into text with timestamps.
  - Splits the text into subtitles automatically.
- The generated subtitles are added to the timeline and are fully editable.
- Regenerate them, export them as SRT/VTT, or burn them into the exported video.
- **Private:**
  - Runs entirely on your device with whisper.cpp.
  - The speech model downloads once, only after you agree.
  - After that it works offline.
- Captions are the only AI feature in v1.

**Audio**
- Multiple audio tracks.
- Import audio, or extract it from video.
- Trim, split, move, duplicate and delete.
- Volume, fade in/out, mute and waveforms.
- Background music, voice recording where supported, and audio sync.

**Effects & color**
- Brightness, contrast, saturation, exposure, highlights, shadows, temperature and tint.
- Sharpness, blur, vignette and opacity.
- Color presets.
- `.cube` LUT import with an intensity control.

**Transitions**
- Fade, cross dissolve, dip to black, dip to white, slide, wipe and zoom.
- Adjustable duration and direction, with a preview.

**Picture-in-picture & compositing**
- Video over video and image over video, with multiple overlays.
- Resize, move, rotate, crop, opacity and independent timing.
- **Chroma key:**
  - Green screen or a custom key color.
  - Similarity, smoothness and spill reduction.
  - Live preview.
- **Masks:** rectangle and circle, with position, size, feather and opacity.

**Keyframes**
- Animate position, scale, rotation, opacity, volume and basic effects.
- Add, remove, move and edit keyframes, with linear interpolation.

**Preview**
- Real-time timeline preview with play/pause and frame/time seeking.
- Fullscreen preview.
- Preview quality options.
- Current time and duration display.

**Export**
- Real video rendering, hardware-accelerated where supported.
- **Formats:**
  - MP4, and MOV where supported.
  - H.264, and H.265 where supported.
- Choose the resolution, FPS, video bitrate and audio bitrate.
- **Presets:** quality presets, YouTube, YouTube Shorts, Instagram and TikTok, or custom settings.
- Export progress and cancel.
- Background rendering where supported.

**Performance**
- Thumbnail and waveform caches and proxy media.
- Lazy timeline drawing and background workers.
- Large-project support.

**Touch & keyboard**
- **Touch:**
  - Drag clips, trim handles and split controls.
  - Pinch to zoom the timeline, long-press menus and touch preview controls.
  - A bottom editing toolbar with tool tabs and bottom sheets.
- **Keyboard (iPad and Android tablets):**
  - Editor shortcuts (see below).
  - Mouse and trackpad timeline control.
  - Drag and drop of media.

---

## 🤖 AI Studio & Advanced Subtitles 🚧 (v1.2.0)

Private, bring-your-own-key intelligence and rich karaoke captioning:
- **Advanced Subtitles (100% on-device):**
  - Word-by-word karaoke highlight animations using whisper word timings.
  - Per-cue style overrides and per-line custom positioning.
  - Rich text styling spans across grapheme ranges.
  - Multi-script typography fallbacks (Indic, Arabic, Hebrew, Thai) and user font import (`.ttf`/`.otf`).
- **AI Studio (Optional & Off by Default):**
  - Bring your own API key for Google Gemini, OpenAI, Anthropic Claude, OpenRouter, or xAI Grok.
  - One-tap transcript cleanup, grammar repair, and smart punctuation.
  - Speaker diarization labeling and voice tone/emotion detection.
  - Subtitle translation into secondary tracks with automatic duration retiming.
  - Strict privacy: keys stored in hardware Keystore/Keychain; zero telemetry; explicit **Send** disclosure before every network call.

---

## 🖥️ Desktop Video Editor 🚧 (v1.2.0)

Expanding the non-destructive multi-track editor to **macOS, Windows, and Linux**:
- **Native Render Engines:**
  - **macOS:** Metal + AVFoundation (sharing ~90% of the tested Darwin code with iOS).
  - **Windows:** Media Foundation + Direct3D 11 with hardware MFT encoders (NVENC, Intel QuickSync, AMD AMF).
  - **Linux:** GStreamer 1.x + VA-API / Vulkan with graceful software fallback.
- **Desktop Ergonomics:**
  - Responsive 3-pane workstation with resizable media bin, inspector, canvas, and timeline.
  - Dedicated desktop cursor tools: Selection (`V`), Razor cut (`C`), Slip (`Y`), and Ripple edit (`B`).
  - Professional transport shortcuts: J-K-L multi-speed shuttling and space toggle.
  - Multi-monitor support with detached floating preview canvas.
  - Native file drag-and-drop from Finder, Windows Explorer, and Linux file managers.

---

## 📷 In-House Native Camera & Beauty Suite 🚧 (v1.3.0)

A high-performance capture engine built directly on native OS APIs (`AVFoundation`, `Camera2/CameraX`, `DirectShow`, `V4L2`):
- **Photo & Video Capture:** zero-shutter-lag photos, 4K 60fps video, 10-bit HDR, and RAW capture (Apple ProRAW / DNG).
- **Comprehensive 8-Category Beauty Suite (60 fps GPU realtime):**
  1. **Face Shape & Slimming:** face narrowing, V-line jaw tapering, jawline sharpening, chin slimming/length, forehead adjustment, cheekbone enhancement, symmetry correction, overall face reshape.
  2. **Eyes & Eyebrows:** eye enlargement, canthus angle tilt, interpupillary spacing, eye brightening, dark-circle & eye-bag removal, eyebrow thickness/arch, procedural eyelashes.
  3. **Nose & Lips:** nose bridge slimming, bridge elevation, tip reshaping, lip plumping, cupid's bow sculpting, speech smile adjustment.
  4. **Skin Retouching:** multi-scale bilateral smoothing, neural acne & blemish removal, dark-spot removal, skin tone shifting, anti-shine oiliness reduction, wrinkle softening, natural glow, teeth whitening.
  5. **Virtual Makeup:** foundation/concealer, lipstick (matte/gloss/velvet/ombré), blush & 3D contour, eyeliner & eyeshadow, colored contact lenses, hair color tinting, freckles & beauty marks.
  6. **Body Slimming & Proportions:** skeletal silhouette reshaping, waist slimming with background anchor protection, arm/leg slimming, hip/shoulder tuning, leg elongation, posture correction.
  7. **Camera Filters & Effects:** real-time beauty filters, background portrait blur & optical bokeh ($f/1.4$ to $f/16$), AR face masks, split-screen Before/After comparison.
  8. **Advanced Features:** 468-point 3D landmark tracking, automatic one-tap beautification, manual pro sliders, custom beauty presets.
- **Cinematic Capture:** 24 fps cinematic cadence, 2.39:1 anamorphic matte, real-time 3D LUT grading.
- **Pro Manual Controls:** manual ISO, shutter speed (1/8000s to 1s), focus peaking, live zebra stripes, RGB histogram.
- **Dual Multicam Capture (Front + Back):** simultaneous concurrent recording with customizable PIP placement, aspect ratio (1:1, 4:3, 16:9), and PIP shape (circle, pill, heart, teardrop, rounded rect) or 50/50 split.
- **Background Device Audio Recording:** record internal device audio while playing music or games, with opt-out toggle to mute external mic or record multi-track synchronized audio.

---

## ✂️🎨 Unified Photo & Video Editor 🚧 (v1.3.0 Updates)

The Danaview Editor seamlessly serves both photo editing and multi-track video editing dynamically based on user intent:

### 1. Still Photo Editing Mode
- **Strict Non-Destructive Pipeline:** edits saved as lightweight `.dnphoto` recipes; original image files are never altered or compressed.
- **High-Bitness Color Engine:** 16-bit half-float (`RGBA16F`) internal processing in Display P3 / Rec.709 color space.
- **Pro Tonal Controls:** Exposure ($\pm 5.0$ EV), Contrast, Highlights, Shadows, Whites, Blacks, Clarity, Dehaze, Vignette, Grain.
- **Color Mastery:** 8-channel HSL color mixer with Target Adjustment Tool (TAT) and interactive spline RGB curves.
- **Portrait Retouching:** full 8-category beauty suite (face slimming, feature reshaping, blemish removal, teeth whitening) evaluated at full sensor resolution.
- **Crop, Transform & Keystone:** free crop, standard aspect ratios, auto-horizon leveler, horizontal/vertical perspective keystone correction.
- **Selective Masking:** linear gradient, radial spotlight, brush masks, and luminance range masks with localized adjustments.
- **Typography & Overlays:** multi-layer text with Danaview font catalog, stickers, and vintage borders.
- **Batch Productivity:** copy/paste adjustment recipes across multiple photos and batch export (JPEG, PNG, WebP, HEIC).
- **One-Tap Bridge to Video:** "Add to Video Project" instantly turns any edited photo into a timeline still clip with optional Ken Burns pan-and-zoom motion.

### 2. Video Timeline Mode & Moving Beauty Suite
- **Timeline Beauty Integration:** complete 8-category beauty & retouching suite applied directly to moving video clips on the timeline.
- **Temporal One-Euro Landmark Stabilization:** velocity-adaptive landmark smoothing eliminates inter-frame mesh jitter.
- **Multi-Subject Video Tracking:** detects, isolates, and independently beautifies up to 4 distinct faces per clip.
- **Timeline Keyframe Automation:** animate any beauty parameter over time with linear and bezier easing curves.
- **Hardware 4K 60fps Video Export:** real-time GPU evaluation during scrubbing and hardware-accelerated master export.

---

## 🗂️ Unified Media Home Screen 🚧 (v1.3.0)

A unified visual media hub for all photos and videos on your device:
- **100% Preservation of Player Features:** Now Playing card, Continue Watching tray (resume progress, episode badges), Playlists (create, rename, delete, shuffle, play all), Folders (device storage, external directories, breadcrumbs), Playback Queue, and streaming URL opening (HTTP, RTSP, RTMP, SRT, UDP) remain fully functional.
- **Unified Navigation Tabs:** `Home / Overview`, `Videos`, `Photos`, `All Media`, `Playlists`, `Folders`, and `Projects`.
- **Fast Media Browsing:** high-speed Masonry photo grid and adaptive video cards backed by 64 MB LRU memory + disk cache for 50,000+ items.
- **Multi-Selection "Make Video Montage":** select mixed photos and videos to automatically assemble a timeline story in the Video Editor.

---

## ⌨️ Keyboard Shortcuts

**Player** ✅

| Shortcut | Action |
|---|---|
| <kbd>Space</kbd> / <kbd>K</kbd> | Play / Pause |
| <kbd>←</kbd> / <kbd>→</kbd> | Seek -5 s / +5 s |
| <kbd>J</kbd> / <kbd>L</kbd> | Seek -10 s / +10 s |
| <kbd>↑</kbd> / <kbd>↓</kbd> | Volume +5% / -5% (up to 300%) |
| <kbd>M</kbd> | Mute |
| <kbd>F</kbd> | Fullscreen |
| <kbd>Esc</kbd> | Close open panels, or leave fullscreen |
| <kbd>T</kbd> | Always on top |
| <kbd>[</kbd> / <kbd>]</kbd> | Speed -0.1× / +0.1× |
| <kbd>I</kbd> | Stats for Nerds |
| <kbd>P</kbd> | Queue |
| <kbd>O</kbd> | Open files |
| <kbd>C</kbd> | Next subtitle track |
| <kbd>#</kbd> | Next audio track |
| <kbd>⌘</kbd>/<kbd>Ctrl</kbd> + <kbd>,</kbd> | Player settings |

**Editor & Creative Tools** 🚧

| Shortcut | Action |
|---|---|
| <kbd>Space</kbd> / <kbd>K</kbd> | Play / Pause |
| <kbd>J</kbd> / <kbd>L</kbd> | Shuttle reverse / forward (1×, 2×, 4×, 8×) |
| <kbd>←</kbd> / <kbd>→</kbd> | Previous / next frame |
| <kbd>V</kbd> | Selection tool |
| <kbd>C</kbd> | Razor cut tool |
| <kbd>Y</kbd> | Slip tool |
| <kbd>B</kbd> | Ripple edit tool |
| <kbd>S</kbd> / <kbd>⌘</kbd>+<kbd>B</kbd> | Split clip at playhead |
| <kbd>Delete</kbd> / <kbd>Backspace</kbd> | Delete selected |
| <kbd>⌘</kbd>/<kbd>Ctrl</kbd> + <kbd>Z</kbd> | Undo |
| <kbd>⌘</kbd>/<kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>Z</kbd> | Redo |
| <kbd>⌘</kbd>/<kbd>Ctrl</kbd> + <kbd>S</kbd> | Save project |
| <kbd>⌘</kbd>/<kbd>Ctrl</kbd> + <kbd>C</kbd> / <kbd>V</kbd> | Copy / Paste attributes |
| <kbd>⌘</kbd>/<kbd>Ctrl</kbd> + <kbd>D</kbd> | Duplicate |

---

## 📱 Supported Platforms

| Platform | Media Player | Unified Photo & Video Editor | Native Camera | AI Studio |
|---|---|---|---|---|
| **iOS / iPadOS** | ✅ | 🚧 (v1.1 video · v1.3 photo & beauty) | 🚧 (v1.3) | 🚧 (v1.2) |
| **Android** | ✅ | 🚧 (v1.1 video · v1.3 photo & beauty) | 🚧 (v1.3) | 🚧 (v1.2) |
| **macOS** | ✅ | 🚧 (v1.2 desktop · v1.3 photo & beauty) | 🚧 (v1.3 Webcams) | 🚧 (v1.2) |
| **Windows** | ✅ | 🚧 (v1.2 desktop · v1.3 photo & beauty) | 🚧 (v1.3 Webcams) | 🚧 (v1.2) |
| **Linux** | ✅ | 🚧 (v1.2 desktop · v1.3 photo & beauty) | 🚧 (v1.3 Webcams) | 🚧 (v1.2) |

*Note: Features not supported on a specific hardware device (e.g. concurrent multicam, LiDAR depth, manual shutter on basic webcams) degrade gracefully and are cleanly hidden from the UI.*

---

## 🏗️ Monorepo Architecture

Danaview is a Flutter & Dart monorepo with strict package boundaries:

```
danaview/
├── lib/
│   ├── app.dart                    # App root, theme & incoming media
│   ├── main.dart                   # Composition root & MediaKit bootstrap
│   └── router/app_router.dart      # GoRouter declaration
├── packages/
│   │   # Player & Library
│   ├── danaview_domain/               # Pure Dart player & media models
│   ├── danaview_engine/               # libmpv / media_kit playback engine
│   ├── danaview_data/                 # Storage, natural sort, sessions, tools
│   ├── danaview_ui_kit/               # Design system: Figtree font, custom controls
│   ├── danaview_platform/             # Window, orientation, wakelock bridges
│   ├── danaview_features/             # Player, library, queue, settings screens
│   │
│   │   # Editor & Creative Suite
│   ├── danaview_editor/               # Editor UI, timeline, and inspector panels
│   ├── danaview_editor_core/          # Pure Dart timeline model, RenderPlan, beauty specs
│   ├── danaview_editor_engine_api/    # Engine contracts, reference renderer, shaders
│   ├── danaview_editor_engine/        # Mobile native engines (Metal iOS, Media3 Android)
│   ├── danaview_editor_engine_desktop/# Desktop native engines (macOS, Windows, Linux)
│   ├── danaview_editor_fonts/         # Bundled typography catalog & font resolver
│   ├── danaview_transcription/        # Speech model catalog, download manager
│   └── danaview_whisper/              # whisper.cpp (vendored) FFI plugin
├── docs/
│   ├── v1.1/                          # Video Editor baseline architecture & build plan
│   ├── v1.2/                          # AI Studio & Desktop Editor (macOS, Windows, Linux)
│   └── v1.3/                          # Unified Home, Native Camera & Unified Editor Updates
└── test/                              # Unit, widget, and render parity tests
```

---

## 🚀 Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) 3.44 (stable)
- Xcode 26 (for macOS / iOS builds)
- Android Studio with the Android SDK, NDK and CMake 3.22.1 (for Android and the AI subtitle engine)
- Visual Studio C++ Build Tools (for Windows builds)

### Installation & Run

1. **Clone the repository**:
   ```bash
   git clone https://github.com/vecvel/danaview.git
   cd danaview
   ```

2. **Install dependencies**:
   ```bash
   flutter pub get
   ```

3. **Run tests**:
   ```bash
   # App tests
   flutter test

   # Editor core tests
   ./scripts/ci/editor/core.sh
   ```

4. **Launch the app**:
   ```bash
   # macOS
   flutter run -d macos

   # iOS / Android with the editor enabled (in development)
   flutter run -d ios --dart-define=DANAVIEW_EDITOR=true
   flutter run -d android --dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true

   # Windows / Linux
   flutter run -d windows
   flutter run -d linux
   ```

---

## 📄 License & Conduct

- **License**: Proprietary — Copyright © 2026 vecvel. All rights reserved. See [`LICENSE`](LICENSE) for terms.
- **Code of Conduct**: See [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
