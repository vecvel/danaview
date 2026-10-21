# Danaview 1.2.0 Release Roadmap: Files & Media Home, AI Studio and the Unified Editor

> **Release:** Danaview 1.2.0 (app version `1.2.0+N`). **Date:** 2026-10-15 (release contents set by the owner on this date). **Status:** Master roadmap and overview.
> **Baseline releases:**
> - Danaview 1.0: cross-platform media player (libmpv, equalizer, subtitles, hardware decode).
> - Danaview 1.1: multi-track video editor on iOS and Android with on-device AI subtitles (`docs/v1.1/editor/ARCHITECTURE.md`, `BUILD_PLAN.md`).
> **Next:** Danaview 1.3.0 brings the desktop editor and the in-house native camera (`docs/v1.3/V1_3_ROADMAP.md`).
> **Core theme:** **Photos and documents join videos.** The Home screen becomes the Files & Media Home (photos, videos, documents, Danaview folders, PDF tools), the editor edits photos and videos, subtitles get rich styling and on-device speaker detection, and optional bring-your-own-key AI adds AI search.
> **Widened on 2026-10-16 (owner):** Pillar 1 now covers documents and PDF tools; AI Studio adds multi-speaker diarization, AI search and a shared AI layer, with a Genkit spike as its first provider ticket.
> **Build entry point (2026-10-21):** start with [`ARCHITECTURE.md`](ARCHITECTURE.md) (the single source of truth for 1.2.0: scope, package graph, data models, native work, privacy and network rules, budgets, the V2 decision log with the mapping from every plan's decision ids, and the open [OWNER] questions) and [`BUILD_PLAN.md`](BUILD_PLAN.md) (builder rules, milestones N0–N6, the dependency-ordered index of all 166 tickets, ticket specs, the shared-file register and feature coverage). Both win over the four plans below where they differ.

---

## 1. The three pillars of Danaview 1.2.0

```
                      +---------------------------------------------------------------+
                      |                        DANAVIEW 1.2.0                         |
                      |      Files & Media Home, AI Studio and the Unified Editor     |
                      +---------------------------------------------------------------+
                                                      |
                         +----------------------------+----------------------------+
                         |                            |                            |
                         v                            v                            v
              +--------------------+       +--------------------+       +--------------------+
              |      PILLAR 1      |       |      PILLAR 2      |       |      PILLAR 3      |
              | Files & Media Home |       |     AI Studio      |       | Unified Editor     |
              | Photos, Videos,    |       | & Rich Subtitles   |       | Photo & Video Edit |
              | Documents, PDF     |       |                    |       |                    |
              +--------------------+       +--------------------+       +--------------------+
              | • All/Videos/Photos|       | • Rich-text cues   |       | • Still Photo Mode |
              |   /Documents       |       | • Karaoke captions |       | • 16-bit float tone|
              | • Danaview folders |       | • Transcript view  |       | • HSL & RGB curves |
              | • Import, share,   |       | • Speaker lanes    |       | • Masks & keystone |
              |   Save to Files    |       |   (on-device       |       | • 8-Category Beauty|
              | • Native viewers   |       |   diarization)     |       | • One-Euro tracking|
              | • PDF tools        |       | • On-device search |       | • Batch export     |
              | • Montage maker    |       | • BYO-key AI, AI   |       |                    |
              | • Player preserved |       |   search, off by   |       |                    |
              |                    |       |   default          |       |                    |
              +--------------------+       +--------------------+       +--------------------+
```

### Pillar 1: Files & Media Home (photos, videos, documents, PDF tools)
- **Document:** [`docs/v1.2/files-media-home/FILES_MEDIA_HOME_PLAN.md`](files-media-home/FILES_MEDIA_HOME_PLAN.md) (HOM-01 to HOM-32, decisions D-86 to D-98 and D-98a to D-98k).
- **Summary:** The Home screen becomes one place for photos, videos and documents. Filters All, Videos, Photos and Documents (PDF, Word, Excel, PowerPoint, text/CSV, other); app-private **Danaview folders** (nested, mixed types, included in app backups); favourites, recents, search and sort; import from Photos/Gallery, Files and "Open with Danaview" (originals never modified); file actions and a multi-select bar; Save to Files (iOS), Save to Downloads (Android) and share. Files open in **native viewers**: photos natively, videos in the existing player, PDF with PDFKit / `PdfRenderer`, Office and text files with Quick Look on iOS and macOS; on Android text and CSV get an in-app viewer and Office files a card with "Open in another app". **PDF tools:** merge, split, reorder, rotate and delete pages, annotate and highlight, sign, compress, on native PDF engines only. No Office editing. Every player, playlist, queue, Continue Watching and folder feature stays exactly as it is. Editor actions show where the editor runs (iOS and Android in 1.2.0).

### Pillar 2: AI Studio and advanced subtitles
- **Document:** [`docs/v1.2/ai-studio/AI_STUDIO_PLAN.md`](ai-studio/AI_STUDIO_PLAN.md) (AIS-01 to AIS-54, decisions D-45 to D-70 and D-70a to D-70i; D-45…D-70 clash with v1.1's ARCH D-45 and are renumbered by AIS-01).
- **Summary:** On-device rich subtitles (styled spans, per-line placement, karaoke from whisper word timings, transcript view, timing tools, font import, style presets) plus an optional, off-by-default AI Studio where the user brings their own key for Gemini, OpenAI, Claude, OpenRouter or Grok to clean up transcripts, detect emotion, add emojis, label speakers and translate tracks. Nothing is sent without an explicit Send, and every AI result is a reviewable, undoable suggestion. iOS and Android only.
- **Added 2026-10-16:**
  - **Multi-speaker transcription:** on-device speaker diarization after whisper (sherpa-onnx, pyannote segmentation 3.0, a speaker-embedding model, downloaded once with consent); overlapping speech becomes separate cues on per-speaker subtitle lanes with exact timestamps; per-speaker styles and renamable speakers; optional cloud diarization behind Send.
  - **AI search over the Files & Media Home:** an on-device index (image labels and text in photos, document text, captions, transcripts, metadata) by default; with AI Studio on, "query to filters" (only the typed question is sent) and per-folder deep indexing (behind Send with a token estimate).
  - **Shared `danaview_ai` layer** for the editor, search and later the camera and documents, behind one AI Studio switch.
  - **Genkit Dart spike** as the first provider ticket: Genkit is used behind our own interface only if our guarded transport stays in control; otherwise the custom adapters stay.

### Pillar 3: Unified Photo & Video Editor
- **Document:** [`docs/v1.2/video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md`](video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md) (VED-01 to VED-32, decisions D-116 to D-145).
- **Summary:** The editor opens photos in a still-photo workspace (16-bit half-float pipeline, pro tone controls, 8-channel HSL mixer, spline RGB curves, gradient and brush masks, perspective keystone, batch export, "Add to Video Project") and keeps the multi-track timeline for video. The 8-category Beauty & Retouching Suite works on both, with temporal One-Euro landmark tracking on moving video. This plan owns the face landmark tracker and beauty shaders that the 1.3.0 camera reuses. iOS and Android only.

---

### Also in 1.2.0: speed test provider fallback
- **Document:** [`docs/v1.2/speed-test/SPEED_TEST_FALLBACK_PLAN.md`](speed-test/SPEED_TEST_FALLBACK_PLAN.md) (ST-01 to ST-05).
- **Summary:** keeps Cloudflare's public endpoint as the default ($0), adds M-Lab as a fallback only after a consent prompt (M-Lab publishes results publicly), shows no provider names in the speed-test UI, and names the providers in the privacy policy.

---

## 2. Order and dependencies inside 1.2.0

1. **Starts after v1.1 ships** (BUILD_PLAN INT-05).
2. **Home (HOM)** has no dependency on the other two. The media part (HOM-01…15) is mostly Flutter work; the documents part (HOM-16…32) adds the `danaview_pdf` plugin, where the Android PDF write path (HOM-27 spike) is the main unknown.
3. **AI Studio (AIS)** is the most complete plan (full ticket specs); its core lane (AIS-01…07) and provider lane (AIS-42 Genkit spike, then AIS-08…10) run in parallel. The shared AI layer (AIS-43) lands before the Studio core. Diarization (AIS-44…49) follows the word-timing work (AIS-15); AI search (AIS-50…53) needs the Home's file model and folders (HOM-16, HOM-17, HOM-19).
4. **Unified Editor (VED)**: photo mode (VED-01…14) can run alongside AIS. The beauty phase (VED-15…28) needs the face tracker (VED-16) first. `.dnproj` schema: AIS-04 moves projects to schema 2; VED-15's schema 3 builds on it (or both are merged into one migration before release).
5. **Cross-pillar links:** HOM-11 and HOM-12 open photos and montages in the VED editor; HOM search uses the AI Studio index (AIS-50); AIS and VED both extend the v1.1 editor's inspector and action registry, so their UI tickets coordinate on shared files through [INTEGRATION] tickets. The 1.3.0 camera reuses `danaview_pdf` (HOM) and `danaview_media_analysis` (AIS) for document scanning.

---

## 3. Core principles in 1.2.0

1. **Graceful degradation:** a capability the device lacks is hidden, not disabled.
2. **Non-destructive:** originals are never modified; edits live in `.dnphoto` (photos) and `.dnproj` (timelines) recipes.
3. **Privacy:** Home, documents, PDF tools, search indexing, speaker detection, photo editing, beauty and subtitles run fully on device (speaker detection after a one-time, consented model download). The only optional network use is AI Studio (including AI search), off by default, with a per-request disclosure.
4. **Owner UI rules:** custom `danaview_ui_kit` components, Figtree, dark UI, computed contrast (≥ 4.5:1), touch targets ≥ 44 px, no overflow at 280–1280 px.
5. **Player preserved:** Now Playing, Continue Watching, playlists, folders, queue and stream opening stay fully intact.

---

## 4. Plan index

| Component | Location | Document |
|---|---|---|
| **Files & Media Home (1.2)** | `docs/v1.2/files-media-home/` | [FILES_MEDIA_HOME_PLAN.md](files-media-home/FILES_MEDIA_HOME_PLAN.md) |
| **AI Studio, advanced subtitles, speaker lanes & AI search (1.2)** | `docs/v1.2/ai-studio/` | [AI_STUDIO_PLAN.md](ai-studio/AI_STUDIO_PLAN.md) |
| **Unified Photo & Video Editor (1.2)** | `docs/v1.2/video-editor-update/` | [VIDEO_EDITOR_UPDATE_PLAN.md](video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md) |
| **Speed test provider fallback (1.2)** | `docs/v1.2/speed-test/` | [SPEED_TEST_FALLBACK_PLAN.md](speed-test/SPEED_TEST_FALLBACK_PLAN.md) |
| **1.2 architecture (source of truth)** | `docs/v1.2/` | [ARCHITECTURE.md](ARCHITECTURE.md) |
| **1.2 build plan (tickets)** | `docs/v1.2/` | [BUILD_PLAN.md](BUILD_PLAN.md) |
| **1.2 roadmap** | `docs/v1.2/` | this file |
| **1.3 roadmap (desktop editor, native camera with document and code scanning)** | `docs/v1.3/` | [V1_3_ROADMAP.md](../v1.3/V1_3_ROADMAP.md) |
