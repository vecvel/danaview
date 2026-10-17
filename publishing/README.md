# Danaview — App Store Publishing Assets

This directory contains the official App Store and Google Play marketing screenshots for **Danaview**, rendered in accordance with Apple's App Store Review Guidelines and the high-fidelity `midnight-glow-pro` visual design system.

---

## 📱 Screenshots Overview

### Display Specifications
- **iPhone 6.9" Display (iPhone 16 Pro Max / iPhone 17 Pro Max):** `1320 × 2868 px`
- **iPhone 6.5" Display (iPhone 11 Pro Max / XS Max / 14 Plus):** `1284 × 2778 px`
- **iPad Pro 12.9" / 13" Display (iPad Pro 3rd-6th Gen, M4):** `2048 × 2732 px`

All images follow a unified dark studio aesthetic:
- **Canvas Base:** Pitch near-black (`#07080B`) with an engineering radial dot grid.
- **Lighting:** Focused top indigo-violet light beam (`#8F8CFF` → `#A77BFF`) with soft horizon bloom and floor reflection.
- **Device Frame:** Titanium iPhone or iPad bezel with subtle rim-lighting and ambient drop shadows.
- **Typography:** Google Fonts **Figtree** used exclusively across all headlines, sublines, eyebrows, and telemetry cards.
- **Eyebrows:** Clean uppercase technical tracking without `//` slash tokens.
- **Telemetry Overlays:** Compact glassmorphic cards (`backdrop-filter: blur(28px)`) anchored cleanly at `top: 20%` or `bottom: 20%` to preserve UI visibility.
- **Design Rule:** Strictly **no pill badges**, emphasizing professional craftsmanship.

---

## 📂 Directory Layout

```
publishing/
├── screenshots/
│   ├── iphone_6_9/                   # 1320 × 2868 px (App Store Connect 6.9" slot)
│   │   ├── 01_hero_4k.png            # Slide 1: Ultra-HD Playback Engine
│   │   ├── 02_equalizer_bass.png     # Slide 2: 10-Band Parametric Equalizer
│   │   ├── 03_speed_diagnostics.png  # Slide 3: Real-Time Stream Diagnostics
│   │   ├── 04_color_mastering.png    # Slide 4: Frame Color Grading Controls
│   │   └── 05_privacy_storage.png    # Slide 5: On-Device Storage & Bandwidth
│   │
│   ├── iphone_6_5/                   # 1284 × 2778 px (App Store Connect 6.5" slot)
│   │   ├── 01_hero_4k.png
│   │   ├── 02_equalizer_bass.png
│   │   ├── 03_speed_diagnostics.png
│   │   ├── 04_color_mastering.png
│   │   └── 05_privacy_storage.png
│   │
│   └── ipad_12_9/                    # 2048 × 2732 px (App Store Connect 12.9" iPad Pro slot)
│       ├── 01_hero_4k.png
│       ├── 02_equalizer_bass.png
│       ├── 03_speed_diagnostics.png
│       ├── 04_color_mastering.png
│       └── 05_privacy_storage.png
│
├── source_assets/                    # Native simulator captures and frames
│   ├── 01_home.png                   # iPhone: Home library screen
│   ├── 02_equalizer.png              # iPhone: 10-band EQ curve
│   ├── 03_speed_test.png             # iPhone: Network speed test
│   ├── 04_color_grade.png            # iPhone: Color adjustments
│   ├── 05_data_usage.png             # iPhone: Data usage calculator
│   ├── ipad_01_home.png              # iPad: Home screen with Now Playing
│   ├── ipad_02_settings.png          # iPad: Settings & Seek Controls
│   ├── ipad_03_speed_test.png        # iPad: 4K Network Benchmark
│   ├── ipad_04_color_grade.png       # iPad: Real-time Color Adjustments
│   ├── ipad_05_storage.png           # iPad: Local Sandbox & Storage
│   ├── mockup.png                    # High-res iPhone frame overlay
│   └── mockup-ipad.png               # High-res iPad frame overlay
│
├── generate_screenshots.py           # Automated iPhone rendering pipeline
├── generate_ipad_screenshots.py      # Automated iPad rendering pipeline
└── README.md                         # Publishing documentation (this file)
```

---

## 🎨 Slide Deck Narrative Arc

| # | Slide ID | Headline | Key Benefit | Telemetry Card |
|---|---|---|---|---|
| **01** | `01_hero_4k` | **Play everything.**<br>In pure **HDR clarity.** | Universal hardware decoding (HEVC, AV1, HLS, DASH, local files) | `Ultra-HD HEVC` · Hardware accelerated |
| **02** | `02_equalizer_bass` | **Smart playback.**<br>Tuned to **your rhythm.** | Custom seek gestures, stream inspection, and media tools | `Custom Seek Controls` · 5s–30s Seek |
| **03** | `03_speed_diagnostics` | **Zero buffer.**<br>Tested in **real time.** | Integrated speed test, ping diagnostics, and link validator | `Stream Speed Test` · Stream Ready |
| **04** | `04_color_mastering` | **Every frame,**<br>color **graded live.** | Real-time brightness, contrast, saturation, gamma, and hue | `Hardware Color Grade` · Live gamma & contrast |
| **05** | `05_privacy_storage` | **Your media.**<br>Zero **tracking.** | 100% on-device sandbox, no telemetry, direct Files integration | `Zero Data Collected` · Private sandbox |

---

## 🚀 How to Re-generate or Customize

If you capture new screenshots in the iOS simulator:
1. Save the new 1320×2868 captures into `publishing/source_assets/`.
2. To re-generate iPhone screenshots:
   ```bash
   python3 generate_screenshots.py
   ```
   Outputs will update in `publishing/screenshots/iphone_6_9/` and `publishing/screenshots/iphone_6_5/`.
3. To re-generate iPad screenshots:
   ```bash
   python3 generate_ipad_screenshots.py
   ```
   Outputs will update in `publishing/screenshots/ipad_12_9/`, `ios/fastlane/screenshots/en-US/`, and `android/fastlane/metadata/android/en-US/images/tenInchScreenshots/`.
