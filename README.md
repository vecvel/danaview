<div align="center">

# 🎬 Danaview

**High-performance media player and on-device video editor.**
*Powered by Flutter, libmpv, native video engines and on-device AI.*

[![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Engine](https://img.shields.io/badge/Engine-libmpv%20%2B%20FFmpeg-5C2D91)](https://mpv.io)
[![AI Engine](https://img.shields.io/badge/AI-whisper.cpp%20(On--Device)-FF6F00)](https://github.com/ggml-org/whisper.cpp)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Android%20%7C%20iOS-22c55e)](#-supported-platforms)
[![License: Proprietary](https://img.shields.io/badge/License-Proprietary-red.svg)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](#-sponsor--support)

</div>

---

## 🌟 Overview

**Danaview** is a media player and a non-destructive video editor in one app.

- 🎥 **The Player** (available now): plays almost any video file or network stream on Android, iOS, macOS, Windows and Linux, with a 10-band equalizer, volume boost up to 300%, subtitles, playlists, a queue, diagnostics and built-in network and media tools.
- ✂️ **The Editor** (in development, v1.1.0): a multi-track editor for iPhone, iPad and Android, with frame-accurate cuts, text, subtitles, effects, color and LUTs, transitions, picture-in-picture, chroma key, masks, keyframes, real video export, and **on-device AI subtitles** that never send audio to the cloud.

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

**Editor** 🚧

| Shortcut | Action |
|---|---|
| <kbd>Space</kbd> / <kbd>K</kbd> | Play / Pause |
| <kbd>←</kbd> / <kbd>→</kbd> | Previous / next frame |
| <kbd>S</kbd> | Split at playhead |
| <kbd>Delete</kbd> / <kbd>Backspace</kbd> | Delete selected |
| <kbd>⌘</kbd>/<kbd>Ctrl</kbd> + <kbd>Z</kbd> | Undo |
| <kbd>⌘</kbd>/<kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>Z</kbd> | Redo |
| <kbd>⌘</kbd>/<kbd>Ctrl</kbd> + <kbd>S</kbd> | Save project |
| <kbd>⌘</kbd>/<kbd>Ctrl</kbd> + <kbd>C</kbd> / <kbd>V</kbd> | Copy / Paste |
| <kbd>⌘</kbd>/<kbd>Ctrl</kbd> + <kbd>D</kbd> | Duplicate |

---

## 📱 Supported Platforms

| Platform | Player | Editor |
|---|---|---|
| iOS / iPadOS | ✅ | 🚧 (iOS 15+) |
| Android | ✅ | 🚧 (Android 10+) |
| macOS | ✅ | 🗓️ later |
| Windows | ✅ | 🗓️ later |
| Linux | ✅ | 🗓️ later |

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
│   │   # Player
│   ├── danaview_domain/               # Pure Dart player models & state
│   ├── danaview_engine/               # libmpv / media_kit playback engine
│   ├── danaview_data/                 # Storage, natural sort, sessions, network & media tools
│   ├── danaview_ui_kit/               # Design system: theme, Figtree font, components
│   ├── danaview_platform/             # Window, orientation, wakelock, open-with bridges
│   ├── danaview_features/             # Player, library, queue, settings, tools screens
│   │
│   │   # Editor (v1.1.0, in development)
│   ├── danaview_editor/               # Editor screens and state
│   ├── danaview_editor_core/          # Pure Dart timeline model, frame grid, commands, render plan
│   ├── danaview_editor_engine_api/    # Engine contracts, fake engine, reference renderer
│   ├── danaview_editor_engine/        # Native engines (AVFoundation/Metal on iOS, Media3 on Android)
│   ├── danaview_transcription/        # Speech model catalog, downloads, caption pipeline
│   └── danaview_whisper/              # whisper.cpp (vendored) FFI plugin
├── spikes/                         # Native engine experiments (iOS, Android)
├── docs/
│   └── editor/                     # Editor architecture & 158-ticket build plan
└── test/                           # App and architecture tests
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
