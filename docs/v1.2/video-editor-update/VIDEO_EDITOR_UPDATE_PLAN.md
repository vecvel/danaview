# Danaview 1.2.0: Unified Photo & Video Editor (Still Photo Post-Processing, Multi-Track Video Timeline, 8-Category Beauty Suite & Tracking)

> **Release:** Danaview 1.2.0 (app version `1.2.0+N`), moved from 1.3.0 by the owner on 2026-10-15. **Date:** 2026-10-12. **Status:** Proposal & Architectural Draft.
> **Baseline:** `docs/v1.1/editor/ARCHITECTURE.md` (decisions D-01 to D-44), `docs/v1.2/ai-studio/AI_STUDIO_PLAN.md` (decisions D-45 to D-70), `docs/v1.2/home-photo-video-view/HOME_PHOTO_VIDEO_PLAN.md` (decisions D-86 to D-98, same release). Later plans that build on this one: `docs/v1.3/editor-desktop/DESKTOP_EDITOR_PLAN.md` (D-71 to D-85) and `docs/v1.3/camera-photo-video/NATIVE_CAMERA_PLAN.md` (D-99 to D-115).
> **Scope:** Upgrades the Danaview Editor into a single, unified visual post-processing engine. Rather than maintaining a separate photo app or disjoint editor binaries, our main editor dynamically serves both **Still Photo Editing** and **Multi-Track Video Timeline Editing** based on user intent and media type. Incorporates a 16-bit float still pipeline, pro tone controls, 8-channel HSL mixer, RGB curves, selective masking, perspective keystone, batch export, multi-track video timeline editing, and the complete 8-category Beauty, Face Reshaping, Virtual Makeup, Body Slimming, and AI Retouching Suite with temporal One-Euro landmark tracking for moving video.
> **Release placement (2026-10-15):** this plan now ships in 1.2.0, **before** the native camera and the desktop editor (both 1.3.0). Consequences, applied below: (1) this plan owns the face landmark tracker and the beauty shaders (VED-16, VED-20…VED-23 no longer depend on CAM-04…CAM-06); the 1.3.0 camera reuses them for real-time capture. (2) Platforms are iOS and Android only; the macOS, Windows and Linux columns of §7 arrive with the 1.3.0 desktop editor. (3) The 4K export check (VED-30) runs on the v1.1 mobile exporters (IOS-12, AND-11) instead of DSK-06. (4) AI Studio (same release) moves `.dnproj` to schema 2 (AIS-04); VED-15's schema 3 lands after it, or both bumps are merged into one release migration.
> **Decisions:** Proposes decisions **D-116 to D-145**. Decisions marked **[OWNER]** require confirmation from the product owner.

---

## 0. Contents

1. Executive Summary & Intent-Based Architecture
2. Decisions Log (D-116 to D-145)
3. Unified Engine & Dual-Mode Pipeline Architecture
   - 3.1 Intent-Based Mode Routing (Still Photo Mode vs. Video Timeline Mode)
   - 3.2 Non-Destructive Storage Model (`.dnphoto` & `.dnproj` Schemas)
   - 3.3 GPU Shader Graph Lowering & Effect Order (D-08 & D-131)
   - 3.4 16-Bit Half-Float High-Resolution Render Pipeline
   - 3.5 Temporal Face Landmark Stabilization (One-Euro Filter)
   - 3.6 Multi-Subject Tracking & Keyframe Automation
4. Still Photo Editing Capabilities (Mode 1)
   - 4.1 Pro Tone & Light Adjustments (Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Clarity, Dehaze)
   - 4.2 Color Mastery & 8-Channel HSL Mixer
   - 4.3 Curves & Tonal Range (Spline RGB & Individual Color Channels)
   - 4.4 Crop, Straighten & Perspective Keystone Matrix
   - 4.5 Selective Masks & Local Adjustments (Linear, Radial, Brush, Luminance)
   - 4.6 Typography, Vector Stickers, Borders & Overlays
   - 4.7 Batch Editing, Presets & Multi-Photo Export
   - 4.8 Instant Timeline Bridge ("Add to Video Project" / Ken Burns Animation)
5. Comprehensive 8-Category Beauty & Retouching Suite (Shared Photo & Video)
   - 5.1 Face Shape & Slimming
   - 5.2 Eyes & Eyebrows
   - 5.3 Nose & Lips
   - 5.4 Skin Retouching
   - 5.5 Virtual Makeup & Appearance
   - 5.6 Body Slimming & Proportions
   - 5.7 Filters, Cinematic Portrait Bokeh & Effects
   - 5.8 Advanced Tracking, Multi-Subject Support & Automation
6. Unified Editor UI & Inspector Layouts
   - 6.1 Still Photo Mode Viewport & Tool Trays
   - 6.2 Video Timeline Mode & Clip Inspector Integration
   - 6.3 Interactive Split-Screen Before/After Comparator
7. Platform Capability Matrix & Graceful Degradation
8. Implementation Ticket Breakdown (VED-01 to VED-32)

---

## 1. Executive Summary & Intent-Based Architecture

### 1.1 Executive Summary
In Danaview 1.1.0, the Danaview Editor established multi-track timeline editing, color grading, 3D LUTs (`.vlut`), typography, and on-device AI subtitles on iOS and Android; AI Studio and rich subtitles ship alongside this plan in 1.2.0. 

Danaview 1.2.0 establishes complete visual media symmetry by expanding the main editor into a **Unified Photo & Video Editor**. Rather than forcing creators to juggle two separate applications or isolated codebases, our single editor intelligently adapts its workspace based on user intent:
1. **Still Photo Mode**: When a user selects a photo (or multiple photos) from the Home screen, camera roll, or file picker, the editor opens directly in an optimized still-image canvas featuring tiled GPU rendering, 16-bit half-float processing, pro exposure/light controls, 8-channel HSL color mixer, spline RGB curves, selective masking, perspective keystone correction, batch export, and full-resolution portrait beauty retouching.
2. **Video Timeline Mode**: When a user selects a video clip, a project, or chooses to assemble a story, the editor presents the full multi-track timeline with frame-accurate trimming, transitions, audio mixing, and temporal One-Euro landmark tracking for moving video retouching.
3. **Seamless Transition**: With a single tap ("Add to Timeline / Make Video"), any edited still photo can instantly become an animated clip on a video track, complete with Ken Burns pan-and-zoom motion presets.

Both modes share 100% of the underlying GPU shader infrastructure (`danaview_editor_engine_api`), the `.vlut` 3D LUT evaluator, the `TextLayoutEngine`, and the **complete 8-category Beauty, Face Reshaping, Virtual Makeup, Body Slimming, and AI Retouching Suite**.

### 1.2 Goals

| # | Goal | Where Guaranteed |
|---|---|---|
| **G-U1** | **Single Unified Editor**: One cohesive editor codebase (`danaview_editor`) serving both photos and videos with zero duplicated shader math or UI styling. | D-117, D-130; VED-01 |
| **G-U2** | **Strict Non-Destructive Invariance**: Original media files are never altered or overwritten. Edits exist as lightweight recipes (`.dnphoto` for stills, `.dnproj` for video timelines). | ARCH G2, D-116, D-136; VED-02 |
| **G-U3** | **High-Bitness Color Accuracy**: 10-bit HDR and 16-bit half-float processing prevent color banding during extreme shadow recovery and tone curve manipulation. | D-118; VED-04 |
| **G-U4** | **Temporal Consistency on Video**: Zero flickering or mesh jitter on moving video subjects via adaptive One-Euro landmark filtering. | D-132; VED-16 |
| **G-U5** | **Multi-Subject Tracking**: Detect, isolate, and independently beautify up to 4 individual faces within the same video clip or still photo. | D-133; VED-18 |
| **G-U6** | **Batch Productivity**: Copy adjustment recipes from one photo and paste across dozens of images with background batch export. | D-125; VED-12 |
| **G-U7** | **Owner Standing UI Compliance**: Figtree typography, custom Danaview controls, computed contrast $\ge 4.5:1$, touch targets $\ge 44\text{ px}$. | ARCH §1.3, D-145; VED-30 |

---

## 2. Decisions Log (D-116 to D-145)

| ID | Decision (Summary) | Owner? |
|---|---|---|
| **D-116** | Non-destructive `.dnphoto` project format (single JSON recipe alongside thumbnail cache) for still photo edits. | – |
| **D-117** | Engine reuse: Still Photo Mode executes `danaview_editor_core` visual layer shaders directly on still textures. | – |
| **D-118** | Color pipeline: Rec.709 / Display P3 color space with 16-bit float internal precision for still photo post-processing. | – |
| **D-119** | Viewport rendering: preview operates on screen-resolution GPU mipmaps; export re-evaluates full sensor resolution. | – |
| **D-120** | Pro Tone adjustments: Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Clarity, Dehaze, Vignette, Grain. | – |
| **D-121** | HSL Color Mixer: 8 independent color bands (Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta) with Target Adjustment Tool. | – |
| **D-122** | Tone Curves: Spline-interpolated master RGB, Red, Green, and Blue curves with interactive draggable anchor points. | – |
| **D-123** | Portrait retouching parity: Still Photo Mode embeds identical 8-category beauty algorithms as camera and video timeline. | **[OWNER]** |
| **D-124** | Crop & Transform: free crop, fixed aspect ratios, horizon leveler, 90° rotation, horizontal/vertical perspective keystone. | – |
| **D-125** | Batch processing: copy/paste adjustment recipe, background batch export to JPEG, PNG, WebP, HEIC with quality sliders. | **[OWNER]** |
| **D-126** | Selective masks: Linear gradient, Radial gradient, and Brush masks with independent localized tonal adjustments. | – |
| **D-127** | Typography & overlays: multi-layer text utilizing `FontCatalog` and `TextLayoutEngine`, vector stickers, borders. | – |
| **D-128** | Video Timeline bridge: "Add to Video Project" turns photo into timeline still with optional Ken Burns pan/zoom animation. | – |
| **D-129** | EXIF & Metadata: preservation of camera metadata (EXIF/IPTC) with optional "Strip Metadata on Export" privacy toggle. | **[OWNER]** |
| **D-130** | Intent-based routing: single photo launch opens Still Photo UI; multi-clip or timeline opens Multi-Track UI; dynamic UI gating hides unsupported tools. | – |
| **D-131** | Beauty effect placement in D-08 effect order: crop → chroma key → **beauty/mesh deformation** → grade → LUT → blur → place. | – |
| **D-132** | Temporal landmark stabilization: One-Euro filter smoothing 468 3D facial landmarks to eliminate inter-frame mesh jitter on moving video. | – |
| **D-133** | Multi-face track management: persistent Face IDs assigned per clip; independent beauty parameter sets per subject. | **[OWNER]** |
| **D-134** | Keyframable beauty channels: all numeric beauty sliders support timeline keyframes with linear and bezier easing. | – |
| **D-135** | Background landmark pre-caching: background isolate pre-tracks video landmarks, storing compact vector caches (`.dnface`). | – |
| **D-136** | Project schema update: `.dnproj` schema 3 introduces `BeautyEffectSpec` within visual clip effect lists. | – |
| **D-137** | Full 8-category beauty parity across Still Photo Mode, Video Timeline Mode, and Native Camera. | – |
| **D-138** | Body slimming mesh segmentation: pose estimation with background-preservation constraint preventing background warping. | **[OWNER]** |
| **D-139** | Inspector UI integration: dedicated "Beauty & Retouching" tab in clip inspector alongside Transform, Color, and Audio. | – |
| **D-140** | Split-screen Before/After preview on video canvas and photo viewport with draggable comparison divider. | – |
| **D-141** | Presets & copy/paste attributes: copy beauty recipe from one clip/photo and paste onto multiple timeline clips/photos. | – |
| **D-142** | Real-time proxy playback: low-tier devices execute beauty shaders on half-resolution proxies during interactive playback. | – |
| **D-143** | Offline & privacy guarantee: 100% on-device neural landmark models; zero external API or cloud calls. | AIS G-S1 |
| **D-144** | Selective bypass toggle: per-category and master beauty bypass switches for instant A/B performance testing. | – |
| **D-145** | Standing UI compliance: custom Danaview controls, Figtree typography, dark UI, computed contrast $\ge 4.5:1$. | ARCH §1.3 |

---

## 3. Unified Engine & Dual-Mode Pipeline Architecture

```mermaid
graph TD
    UserEntry[User Enters Danaview Editor] --> ModeCheck{User Intent / Media Input}
    
    ModeCheck -->|Single Still Photo / Image Batch| PhotoMode[Still Photo Editing Mode]
    ModeCheck -->|Video Clip / Multi-Clip / Timeline Project| VideoMode[Video Timeline Editing Mode]
    
    subgraph Shared Core Engine (danaview_editor_core & engine_api)
        Tone[Pro Tone & Exposure Shaders]
        Curves[Spline RGB Curves Evaluator]
        HSL[8-Channel HSL Color Mixer]
        LUT[3D LUT Evaluator .vlut]
        Beauty[8-Category Beauty & Mesh Deformation Suite]
        Text[TextLayoutEngine & FontCatalog]
        Masks[Selective Gradient & Brush Masks]
    end
    
    PhotoMode --> Tone & Curves & HSL & LUT & Beauty & Text & Masks
    VideoMode --> Tone & Curves & HSL & LUT & Beauty & Text & Masks
    
    PhotoMode --> SingleViewport[Tiled High-Res Viewport 60fps]
    SingleViewport --> ExportStill[Full-Bitness GPU Photo Export JPEG/PNG/WebP/HEIC]
    PhotoMode -.->|"Add to Timeline / Make Video"| VideoMode
    
    VideoMode --> MultiTrack[Multi-Track Timeline with Keyframes]
    MultiTrack --> TemporalFilter[One-Euro Temporal Landmark Filter]
    TemporalFilter --> PreviewCanvas[Timeline Preview Canvas 60fps]
    PreviewCanvas --> ExportVideo[Hardware Accelerated 4K 60fps Video Export MP4/MOV]
```

### 3.1 Intent-Based Mode Routing
When launching the Danaview Editor from the Home Screen, Native Camera, or OS file picker, the router evaluates the media selection:
- **Still Photo Intent**:
  - Direct tap on a photo in the gallery or camera thumbnail.
  - Launches `DanaviewEditorScreen` in **Still Mode**: displays full-canvas image viewport, zoom/pan navigation, bottom photo tools tray (Crop, Tone, HSL, Curves, Beauty, Masks, Text), and top action bar with "Export Photo", "Save Preset", and **"Add to Timeline"**.
- **Video Timeline Intent**:
  - Direct tap on a video clip, "New Video Project", or selecting multiple media items with "Make Video Montage".
  - Launches `DanaviewEditorScreen` in **Timeline Mode**: displays playback preview canvas, multi-track timeline, playhead, clip inspector, transport controls, and export modal.
- **Dynamic Transition**:
  - A user editing a still photo can tap **"Add to Timeline"** at any moment. The photo, along with its full adjustment recipe and beauty spec, is wrapped into a 3-second animated still clip and dropped onto Track V1 of an active or new video project, with optional Ken Burns pan-and-zoom motion presets.

### 3.2 Non-Destructive Storage Model (`.dnphoto` & `.dnproj`)

#### Still Photo Recipe (`.dnphoto`)
Lightweight JSON file saved alongside the original image or in the internal project cache:
```json
{
  "schema": 1,
  "minReader": 1,
  "source": {
    "uri": "file:///var/mobile/Media/DCIM/100APPLE/IMG_4210.HEIC",
    "fingerprint": "a3f5b9...",
    "width": 4032,
    "height": 3024
  },
  "adjustments": {
    "exposure": 0.35,
    "contrast": 1.1,
    "highlights": -0.2,
    "shadows": 0.15,
    "whites": 0.05,
    "blacks": -0.05,
    "temperature": 5600,
    "tint": 4.0,
    "vibrance": 1.15,
    "saturation": 1.02,
    "clarity": 0.1,
    "dehaze": 0.05,
    "vignette": -0.15,
    "grain": 0.08
  },
  "hsl": {
    "orange": { "hue": -2, "saturation": 5, "luminance": 8 }
  },
  "crop": {
    "rect": [0.05, 0.05, 0.9, 0.9],
    "rotationDegrees": 0.0,
    "keystoneH": 0.0,
    "keystoneV": 0.0
  },
  "lutId": "teal_and_orange_cinematic",
  "beauty": {
    "masterIntensity": 0.7,
    "faceSlimming": 0.5,
    "vLineJaw": 0.4,
    "skinSmoothing": 0.6,
    "eyeEnlarge": 0.35,
    "lipPlumping": 0.45
  }
}
```

#### Video Project Spec (`.dnproj` Schema 3)
In `.dnproj` schema 3, video clips contain `BeautyEffectSpec` alongside color grading, transforms, and transitions:
```json
{
  "schema": 3,
  "minReader": 3,
  "timeline": {
    "tracks": [
      {
        "id": "track-v1",
        "type": "video",
        "clips": [
          {
            "id": "clip-1",
            "sourceUri": "file:///movies/interview.mp4",
            "timelineIn": "00:00:00.000",
            "timelineOut": "00:00:15.000",
            "effects": [
              {
                "type": "beauty",
                "spec": {
                  "masterIntensity": 0.75,
                  "temporalSmoothing": 0.85,
                  "subjects": [
                    {
                      "subjectId": 0,
                      "faceSlimming": 0.55,
                      "skinSmoothing": 0.65,
                      "darkCircles": 0.60
                    }
                  ],
                  "keyframes": []
                }
              }
            ]
          }
        ]
      }
    ]
  }
}
```

### 3.3 GPU Shader Graph Lowering & Effect Order
In Danaview's lowered RenderPlan architecture (D-01, D-08, D-131), the evaluation order for both still images and video frames is strictly deterministic:
$$\text{Input Texture} \longrightarrow \text{Crop \& Keystone} \longrightarrow \text{Chroma Key} \longrightarrow \mathbf{Beauty\ \&\ Mesh\ Deformation} \longrightarrow \text{Tone \& Grade} \longrightarrow \text{HSL Mixer} \longrightarrow \text{3D LUT} \longrightarrow \text{Blur} \longrightarrow \text{Transform}$$

By placing facial/body mesh deformation and skin smoothing before tonal grading and LUT evaluation, virtual makeup and skin smoothing integrate organically into the creative color grade without clipping or color shifts.

### 3.4 16-Bit Half-Float High-Resolution Render Pipeline
- **Still Viewport**: Tiled texture mipmapping renders screen-resolution proxies at 60 fps during slider manipulation.
- **Internal Processing**: Textures evaluate in 16-bit half-float (`RGBA16F`) or 10-bit HDR (`RGB10A2`) within Display P3 or Rec.709 color space, eliminating banding in deep shadows and bright skies.
- **Export Processing**: Re-evaluates the mathematical shader tree on full-resolution uncompressed image buffers (48 MP / 100 MP) using hardware image encoders.

### 3.5 Temporal Face Landmark Stabilization (One-Euro Filter)
While still photos evaluate 468 3D landmarks on a static frame, moving video requires temporal stabilization:
- **One-Euro Velocity-Adaptive Filter**: Automatically adapts cutoff frequency based on movement speed. Eliminates jitter during static or conversational scenes while tracking rapid head movements without lag.
- **Occlusion Handling**: When a subject turns away or is occluded by hands/objects, the mesh smoothly fades out over 3 frames to prevent abrupt visual pops.

### 3.6 Multi-Subject Tracking & Keyframe Automation
- **Multi-Subject Detection**: Tracks up to 4 distinct faces per clip. Each subject can have independent retouching settings (e.g., subtle grooming on one actor, glam retouching on another).
- **Timeline Keyframing**: Every numeric beauty parameter supports linear and cubic bezier keyframing over time, enabling smooth transitions (e.g., from unretouched to enhanced during a makeover sequence).

---

## 4. Still Photo Editing Capabilities (Mode 1)

### 4.1 Pro Tone & Light Adjustments
- **Exposure**: $\pm 5.0$ EV stops in 0.01 EV increments.
- **Contrast**: Symmetric S-curve contrast slider (0.50 to 2.00).
- **Highlights & Shadows**: Targeted smart recovery algorithms preventing highlight clipping and lifting shadow detail without midtone washout.
- **Whites & Blacks**: Precise clipping-point anchors with visual clipping warnings (blue for crushed blacks, red for blown highlights).
- **Clarity & Texture**: Midtone local contrast enhancement without halos.
- **Dehaze**: Atmospheric scattering subtraction algorithm.
- **Vignette & Grain**: Aesthetic radial edge falloff and simulated film grain.

### 4.2 Color Mastery & 8-Channel HSL Mixer
- **White Balance**: Kelvin temperature slider ($2,000\text{ K} - 12,000\text{ K}$) and tint slider (green to magenta).
- **Vibrance**: Non-linear saturation protecting skin tones from over-saturation.
- **8-Channel HSL Mixer**:
  - Independent **Hue** ($\pm 100^\circ$), **Saturation** ($-100$ to $+100$), and **Luminance** ($-100$ to $+100$) for:
    - Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta.
  - Interactive Target Adjustment Tool (TAT): tap and drag directly on any pixel in the photo to adjust the hue/saturation of that specific color family.

```
+-------------------------------------------------------------------------------+
|  COLOR MIXER (HSL)                                                [ Done ]    |
+-------------------------------------------------------------------------------+
|  Selected: [🟠 Orange]  (Targeting Skin Tones)                                |
|  Colors:   [🔴] [🟠] [🟡] [🟢] [🔵] [🟣] [🟤] [⚪]                            |
|                                                                               |
|  Hue:         [ - ]=======o===========[ + ]  -4°                              |
|  Saturation:  [ - ]=========o=========[ + ]  +8%                              |
|  Luminance:   [ - ]===========o=======[ + ]  +15%                             |
+-------------------------------------------------------------------------------+
```

### 4.3 Curves & Tonal Range
- Interactive curve graph with live histogram underlay.
- Spline interpolation through up to 8 user-placed anchor points.
- Modes: **Combined RGB**, **Red Channel**, **Green Channel**, **Blue Channel**.

### 4.4 Crop, Straighten & Perspective Keystone Matrix
- **Aspect Ratios**: Original, Freeform, 1:1, 4:5 (Instagram), 9:16 (Stories), 16:9, 3:2, 4:3, 2.39:1 Cinema.
- **Auto-Straighten**: Detects horizon tilt using embedded gyro sensor metadata or line detection.
- **Perspective Keystone**: Horizontal and vertical keystone correction for architecture and flat-lay photography.

### 4.5 Selective Masks & Local Adjustments
- **Mask Types**:
  - **Linear Gradient**: Graduated density filter for skies and landscapes.
  - **Radial Gradient**: Vignettes, spotlights, and subject highlighting.
  - **Brush Mask**: Freehand painting with soft edge feathering.
  - **Luminance Mask**: Isolates specific brightness ranges.
- **Local Overrides**: Masks allow localized adjustments to Exposure, Contrast, Warmth, Saturation, and Sharpness.

### 4.6 Typography, Vector Stickers, Borders & Overlays
- Powered by `TextLayoutEngine` and `FontCatalog`:
  - Full access to bundled fonts (Figtree, Outfit, Roboto) plus user-imported `.ttf`/`.otf` fonts.
  - Multi-line text with letter spacing, line height, drop shadows, outlines, and color fills.
  - Vector stickers, location tags, date stamps, and decorative film frames.

### 4.7 Batch Editing, Presets & Multi-Photo Export
- **Presets**: Save any combination of adjustments, curves, HSL, and LUT into reusable presets stored in local JSON storage (`D-62`).
- **Copy & Paste Edits**: Copy adjustments from one image and paste across dozens of selected photos in the Home Screen grid.
- **Batch Export**: Configurable dimensions, format (JPEG, PNG, WebP, HEIC), quality compression slider, and optional EXIF privacy stripping.

### 4.8 Instant Timeline Bridge ("Add to Video Project")
- Tapping **"Add to Video Project"** exports the edited photo directly onto a video track in an active or new `.dnproj`.
- Automatically assigns a 3.0-second clip duration with optional Ken Burns pan-and-zoom animation preset.

---

## 5. Comprehensive 8-Category Beauty & Retouching Suite (Shared Photo & Video)

The unified editor embeds the complete 8-category beauty suite developed for Danaview. In Still Photo Mode, it evaluates on high-resolution still textures with sub-pixel deformation precision; in Video Timeline Mode, it evaluates at 60 fps on moving video frames with temporal landmark filtering:

### 5.1 Face Shape & Slimming
- **Face Slimming / Narrow Face**: Symmetrical radial contraction narrowing full facial width while keeping ear and neck contours natural.
- **V-Shaped Face**: Contours the lower jaw angle progressively toward the chin apex.
- **Jawline Sharpening**: Localized edge-contrast enhancement and contour lifting along the mandible.
- **Chin Slimming & Shortening**: Independent dual-axis chin adjustments—narrow width, shorten/lengthen height, and sharpen apex.
- **Forehead Width & Height Adjustment**: Hairline repositioning and temporal curve narrowing to balance classical facial proportions.
- **Lower-Face Slimming**: Targeted volume reduction around the lower cheeks, jowls, and corners of the mouth.
- **Cheekbone Enhancement**: Softens overly angular zygomatic arches or adds chiseled high-cheekbone definition.
- **Face Symmetry Correction**: Real-time landmark mirror balancing correcting natural tilt or asymmetric expression planes.
- **Overall Face Reshape**: Master proportional scaling aligning upper, middle, and lower facial thirds to Golden Ratio aesthetics.

### 5.2 Eyes & Eyebrows
- **Eye Enlargement**: Iris-centered radial magnification preserving natural eyelid curvature without fisheye distortion.
- **Eye Shape & Angle Adjustment**: Inner/outer canthus angle control (fox-eye lift, rounded doe-eye, subtle almond contouring).
- **Eye Spacing & Positioning**: Inter-ocular distance expansion/contraction and vertical orbital elevation.
- **Eye Brightening**: Sclera luminance lifting with specular highlight boost creating vivid, glistening catchlights.
- **Dark-Circle & Eye-Bag Removal**: Non-destructive micro-contrast smoothing and blue/purple chroma neutralization under the lower lid.
- **Eyebrow Thickness, Shape & Positioning**: Arch height, tail angle, brow thickness, and vertical brow-to-eye spacing.
- **Eyelash Enhancement**: Procedural lash volume thickening, length extension, and curl rendering along upper and lower lashlines.

### 5.3 Nose & Lips
- **Nose Slimming & Narrowing**: Lateral nasal bridge compression and alar flare reduction.
- **Nose Length & Bridge Adjustment**: Nasal bridge height sculpting, dorsal hump smoothing, and vertical nose length tuning.
- **Nose-Tip Reshaping**: Precision spherical scaling (refine bulbous tips, lift drooping tips, sharpen columella).
- **Lip Enlargement & Resizing**: Volumetric upper/lower lip plumping with independent vermilion border definition.
- **Lip Shape & Thickness Adjustment**: Cupid's bow contouring, lip corner elevation, and upper-to-lower fullness ratio tuning.
- **Smile Adjustment**: Bilateral oral commissure lift creating a natural, pleasant smile with subtle cheek lift.

### 5.4 Skin Retouching
- **Skin Smoothing**: Multi-frequency domain-transform filtering eliminating pores, roughness, and blemishes while preserving authentic skin texture, eyebrows, and hair.
- **Acne & Blemish Removal**: Precision patch inpainting brush and automated neural spot removal.
- **Dark-Spot Removal**: Melanin-selective desaturation fading freckles, sunspots, and hyperpigmentation.
- **Skin Tone & Brightness Adjustment**: Tone shifting across porcelain, warm honey, bronze, olive, and deep rich palettes.
- **Oiliness Reduction (Anti-Shine)**: Specular highlight attenuation on the T-zone, forehead, and nose tip yielding a velvety matte complexion.
- **Wrinkle Softening**: Micro-contrast attenuation fading forehead furrows, laugh lines, and periorbital crow's feet.
- **Natural Glow**: Diffuse subsurface-scattering simulation introducing soft, youthful vitality and dewy skin luster.
- **Teeth Whitening**: Selective dental enamel brightening with blue-tinted chroma desaturation targeting the mouth opening.

### 5.5 Virtual Makeup & Appearance
- **Foundation & Concealer**: Flawless skin tint matching with customizable coverage opacity and satin/matte finish.
- **Lipstick**: Matte, gloss, velvet, and ombré finishes across hundreds of curated shades with feathering controls.
- **Blush & Contour**: Anatomical blush placement on cheek apples paired with 3D shadow contouring along the jaw and nose bridge.
- **Eyeliner & Eyeshadow**: Winged, tightline, and smokey liner styles paired with multi-gradient eyeshadow blends.
- **Virtual Colored Contact Lenses**: Procedural iris overlays with realistic pupil apertures and light reflections.
- **Hair Color & Hairstyle Effects**: Intelligent hair strand segmentation with vibrant or natural color tinting.
- **Freckles & Beauty Marks**: Authentic aesthetic freckle scattering and placement of customizable beauty marks.

### 5.6 Body Slimming & Proportions
- **Body Reshaping**: Full-body silhouette mesh deformation with smart background-preservation pinning.
- **Waist Slimming**: Bilateral torso contraction accentuating a balanced, natural waistline.
- **Arm & Leg Slimming**: Targeted cylindrical deformation reducing upper arm girth, thigh fullness, and calf width.
- **Hip & Shoulder Adjustments**: Shoulder broadening/softening and hip curve contouring.
- **Leg-Length Adjustment**: Lower-body elongation anchored to floor plane for statuesque proportions.
- **Height & Body-Proportion Correction**: Head-to-body proportion tuning and posture realignment.

### 5.7 Filters, Cinematic Portrait Bokeh & Effects
- **Real-Time Beauty Filters**: Natural, Soft, Glam, Vintage 35mm, Pastel, and Cinematic portrait color profiles.
- **Background Blur & Portrait Bokeh**: Realistic synthetic depth-of-field bokeh ($f/1.4$ to $f/16$) with customizable aperture blades.
- **AR Masks & Stickers**: 3D face-anchored vector stickers, glasses, headbands, and decorative frames.
- **Before-and-After Comparison**: Split-screen slider and instant press-to-hold unretouched toggle across both modes.
- **Adjustable Intensity**: Universal master intensity (0–100%) and independent parameter sliders.
- **Undo, Redo & Reset**: Full history stack for all facial and body modifications (`Cmd/Ctrl+Z`).

### 5.8 Advanced Tracking, Multi-Subject Support & Automation
- **AI Face Detection & Facial Landmarks**: High-precision 468-point 3D mesh detection with multi-face detection (select and beautify individual subjects).
- **Automatic Face Enhancement**: One-tap smart beautification analyzing skin tone and facial balance for instant, natural results.
- **Timeline Keyframing**: Animate any beauty parameter over time with linear and bezier easing curves in Video Timeline Mode.
- **Full Sensor HD Export**: Full-resolution export preserving native 48 MP / 100 MP detail for stills, and hardware 4K 60fps export for video.
- **Preset Styles & User Recipes**: Curated style presets ("Natural Glow", "Editorial Chic", "Sunset Warmth", "Clean Beauty") and custom recipe saving.

---

## 6. Unified Editor UI & Inspector Layouts

### 6.1 Still Photo Mode Viewport & Tool Trays

```
+---------------------------------------------------------------------------------------------------+
|  [ < Back ]  IMG_4210.HEIC (4032 x 3024)                 [ Compare ]  [ ➕ To Video ]  [ 💾 Export ]|
+---------------------------------------------------------------------------------------------------+
|                                                                                                   |
|                                                                                                   |
|                                    [ HIGH-RES PHOTO CANVAS ]                                      |
|                                  (Pan & Pinch-to-Zoom 60fps)                                      |
|                                                                                                   |
|                                                                                                   |
+---------------------------------------------------------------------------------------------------+
|  [ ✂️ Crop ]  [ ☀️ Tone ]  [ 🎨 HSL ]  [ 📈 Curves ]  [ 💄 Beauty ]  [ 🎭 Masks ]  [ 🔤 Text ]  [ 📦 Presets ]|
+---------------------------------------------------------------------------------------------------+
|  Exposure:   [ - ]=======o===========[ + ] +0.35 EV    Highlights: [ - ]====o=============[ + ] -20%  |
|  Contrast:   [ - ]=========o=========[ + ] 1.10        Shadows:    [ - ]=======o==========[ + ] +15%  |
+---------------------------------------------------------------------------------------------------+
```

### 6.2 Video Timeline Mode & Clip Inspector Integration

```
+---------------------------------------------------------------------------------------------------+
|  CLIP INSPECTOR: Video Clip 1 (00:02:14 - 00:08:30)                              [ Compare Split ]|
+---------------------------------------------------------------------------------------------------+
|  [ Transform ]   [ Color & LUT ]   [ 💄 Beauty & Retouch ]   [ Audio ]   [ Speed ]   [ Keyframes ]    |
+---------------------------------------------------------------------------------------------------+
|  Master Beauty: [ ON ]                                               Intensity: [====o===] 75%    |
|  Active Subject: Face 1 (Main Actor) [ + Track Face 2 ]              Temporal Smoothing: [ High v]|
|                                                                                                   |
|  [ Face Shape ]  [ Eyes/Brows ]  [ Nose/Lips ]  [ Skin ]  [ Makeup ]  [ Body ]  [ Filters ]  [ Presets ]
|                                                                                                   |
|  Face Slimming:    [ - ]======o===========[ + ] 55%  [◇]  Skin Smoothing:   [ - ]=======o========[ + ] 65% [◇]
|  V-Shape Jaw:      [ - ]====o=============[ + ] 40%  [◇]  Blemish Healing:  [ - ]=========o======[ + ] 85% [◇]
|  Chin Slim/Length: [ - ]====o=============[ + ] 35%  [◇]  Dark Circles:     [ - ]=======o========[ + ] 60% [◇]
|  Eye Enlarge:      [ - ]===o==============[ + ] 30%  [◇]  Teeth Whitening:  [ - ]========o=======[ + ] 75% [◇]
|  Nose Slimming:    [ - ]====o=============[ + ] 42%  [◇]  Lipstick (Matte): [ - ]=====o==========[ + ] 45% [◇]
|  Waist Slimming:   [ - ]====o=============[ + ] 38%  [◇]  Leg Length:       [ - ]===o============[ + ] 25% [◇]
+---------------------------------------------------------------------------------------------------+
|  [ 🔄 Reset Beauty ]             [ 📋 Copy Attributes ]             [ 💾 Save Beauty Preset ]     |
+---------------------------------------------------------------------------------------------------+
```

### 6.3 Interactive Split-Screen Before/After Comparator
In both Still Photo Mode and Video Timeline Mode, activating **Compare Split** renders a draggable divider across the viewport. The left half displays the original unretouched pixels, while the right half displays the real-time processed output. Press-and-hold anywhere on the canvas instantly flips the entire viewport to the unretouched original.

---

## 7. Platform Capability Matrix & Graceful Degradation

> 1.2.0 ships the iOS and Android columns. The macOS, Windows and Linux columns are the target for the 1.3.0 desktop editor (`docs/v1.3/editor-desktop/DESKTOP_EDITOR_PLAN.md`).

| Feature | iOS / iPadOS | Android | macOS | Windows | Linux |
|---|---|---|---|---|---|
| **Tone & Color Engine** | Metal (Instant) | OpenGL ES / Vulkan | Metal (Instant) | Direct3D 11 HLSL | OpenGL / Vulkan |
| **Still Photo Mode** | 16-bit Float Metal | 16-bit Float GL/Vulkan | 16-bit Float Metal | Direct3D 11 / WIC | OpenGL / LibRaw |
| **Landmark Tracking** | Apple Vision | MediaPipe FaceMesh | Apple Vision | DirectML / ONNX | ONNX Runtime |
| **Temporal Smoothing** | One-Euro Filter | One-Euro Filter | One-Euro Filter | One-Euro Filter | One-Euro Filter |
| **Multi-Face Tracking**| Up to 4 faces | Up to 4 faces | Up to 4 faces | Up to 4 faces | Up to 4 faces |
| **Still Batch Export** | ImageIO Hardware | MediaCodec / Bitmap | ImageIO Hardware | WIC HW encode | libjpeg-turbo / PNG |
| **Video 4K Export** | VideoToolbox HW | MediaCodec HW | VideoToolbox HW | MFT (NVENC/QSV/AMF)| VA-API / NVENC |

---

## 8. Implementation Ticket Breakdown (VED-01 to VED-32)

### Phase 1: Core Engine Unification & Still Photo Mode (VED-01 to VED-14)

| Ticket | Scope & Summary | Depends On |
|---|---|---|
| **VED-01** | Refactor `danaview_editor` router and entry point for intent-based routing (Still Photo vs. Video Timeline). | v1.1 Editor |
| **VED-02** | Create non-destructive `.dnphoto` project domain model, JSON codec, and migration handler. | VED-01 |
| **VED-03** | Adapt `danaview_editor_engine_api` GPU shader graph to execute visual layer shaders on still textures. | v1.1 Engine |
| **VED-04** | Implement 16-bit half-float (`RGBA16F`) render pipeline with Display P3 color space support. | VED-03 |
| **VED-05** | Build interactive still-photo viewport with 60 fps tiled pan and pinch-to-zoom scaling. | VED-03 |
| **VED-06** | Implement Pro Tone adjustments (Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Clarity, Dehaze). | VED-03 |
| **VED-07** | Build 8-channel HSL Color Mixer with on-image Target Adjustment Tool (TAT). | VED-06 |
| **VED-08** | Implement Spline RGB and individual color channel curves widget and GPU evaluator. | VED-06 |
| **VED-09** | Build Crop, Straighten, Horizon Leveler, and 3D Perspective Keystone matrix engine. | VED-05 |
| **VED-10** | Develop Selective Masking engine (Linear Gradient, Radial Gradient, Brush Mask, Luminance). | VED-06 |
| **VED-11** | Integrate typography and vector stickers via `TextLayoutEngine` and `FontCatalog`. | VED-05 |
| **VED-12** | Implement Presets and Copy/Paste adjustments for still photos and batch export. | VED-06 |
| **VED-13** | Implement EXIF metadata preservation and "Strip Metadata on Export" privacy toggle. | VED-02 |
| **VED-14** | Build "Add to Video Project" bridge: turns edited photo into 3.0s animated clip with Ken Burns motion. | VED-02, v1.1 Editor |

### Phase 2: Timeline Beauty, Temporal Tracking & Video Integration (VED-15 to VED-28)

| Ticket | Scope & Summary | Depends On |
|---|---|---|
| **VED-15** | Update `.dnproj` schema to version 3 with `BeautyEffectSpec` within visual clip effect lists. | CORE-03, VED-02, AIS-04 |
| **VED-16** | Build the on-device face landmark tracker (Apple Vision on iOS, MediaPipe Face Mesh on Android; 468 points) and the temporal One-Euro stabilization filter that removes inter-frame mesh jitter on moving video. Shared later with the 1.3.0 camera (CAM-04). | VED-03 |
| **VED-17** | Build background video landmark pre-tracker isolate and `.dnface` caching service. | VED-16 |
| **VED-18** | Implement multi-subject face detection and independent Face ID parameter management. | VED-16 |
| **VED-19** | Wire timeline keyframe animation system for all numeric beauty parameters. | VED-15, CORE-19 |
| **VED-20** | Implement real-time facial slimming, V-line jaw, and chin deformation shaders for still and video clips. | VED-03, VED-16 |
| **VED-21** | Implement eye enlargement, canthus angle tilt, and eye brightening shaders. | VED-03, VED-16 |
| **VED-22** | Implement nose slimming, bridge elevation, and lip plumping shaders. | VED-03, VED-16 |
| **VED-23** | Implement skin smoothing, blemish healing brush, and teeth whitening shaders. | VED-03, VED-16 |
| **VED-24** | Build virtual makeup shader passes (foundation, lipstick, blush, contour, eyeliner). | VED-03 |
| **VED-25** | Implement body reshaping, waist slimming, and leg length adjustment shaders. | VED-03 |
| **VED-26** | Design and build "Beauty & Retouching" inspector panel in `danaview_editor` UI kit. | ARCH §1.3, VED-15 |
| **VED-27** | Implement split-screen Before/After preview divider on photo canvas and video timeline. | VED-26 |
| **VED-28** | Build beauty preset management and copy/paste attributes for timeline video clips. | VED-15 |

### Phase 3: Hardware Export, Benchmarks & Parity Validation (VED-29 to VED-32)

| Ticket | Scope & Summary | Depends On |
|---|---|---|
| **VED-29** | High-resolution still photo export engine (JPEG, PNG, WebP, HEIC with quality sliders). | VED-04 |
| **VED-30** | Hardware video export verification on iOS and Android: validate 4K 60fps export with full beauty passes (desktop export is verified by the 1.3.0 desktop plan). | VED-15, IOS-12, AND-11 |
| **VED-31** | Memory stress test on 48 MP and 100 MP camera images across low-RAM devices. | VED-05, VED-29 |
| **VED-32** | Golden image parity test suite comparing photo mode vs video timeline beauty rendering. | VED-29, VED-30 |
