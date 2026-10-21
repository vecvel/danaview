# Danaview 1.2.0: Architecture (single source of truth)

> **Release:** Danaview 1.2.0 (app version `1.2.0+N`), "Files & Media Home, AI Studio and the Unified Editor". **Date:** 2026-10-21. **Baseline:** `editor-wip` @ `c2ee137` (Danaview 1.1.0 editor, 162 of 166 v1.1 tickets done), Flutter 3.44.2, Dart 3.12.2, Xcode 26.6, AGP 9.0.1, Kotlin 2.3.20.
> **Inputs:** [`V1_2_ROADMAP.md`](V1_2_ROADMAP.md), [`files-media-home/FILES_MEDIA_HOME_PLAN.md`](files-media-home/FILES_MEDIA_HOME_PLAN.md) ("HOM plan"), [`ai-studio/AI_STUDIO_PLAN.md`](ai-studio/AI_STUDIO_PLAN.md) ("AIS plan"), [`video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md`](video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md) ("VED plan"), [`speed-test/SPEED_TEST_FALLBACK_PLAN.md`](speed-test/SPEED_TEST_FALLBACK_PLAN.md) ("ST plan"), and the v1.1 references [`../v1.1/editor/ARCHITECTURE.md`](../v1.1/editor/ARCHITECTURE.md) ("v1.1 ARCH") and [`../v1.1/editor/BUILD_PLAN.md`](../v1.1/editor/BUILD_PLAN.md) ("v1.1 BP").
> **Implementation:** follows [`BUILD_PLAN.md`](BUILD_PLAN.md) in this folder ("BP").
> **Authority:** this document wins over `BUILD_PLAN.md`, and both win over the four plans. The plans stay the detailed reference for anything this document doesn't restate; §14 lists every point where they disagreed with each other, with v1.1 or with the code, and how each was settled. v1.1 ARCH stays the source of truth for v1.1 behaviour that 1.2.0 doesn't change. Later changes to this file are made only by tickets marked **[INTEGRATION]** (BP §0.2).
> **Decision ids:** 1.2.0 decisions use the prefix **V2-** so they never clash with v1.1 ARCH's D-01…D-45 (§2.1 has the mapping from every plan id). Inside the plans the old ids stay valid as aliases.
> **Binding owner input:** the owner decisions of 2026-10-15 (release contents) and 2026-10-16 ("go with the recommendation" in the HOM, AIS and ST plans) are applied below and marked *owner 2026-10-16*. **[OWNER]** marks a point the owner still has to confirm (§16; until then the recommendation is the working default, as in v1.1 ARCH D-43). **[VERIFY]** marks a claim a named ticket must prove (§15).

---

## 1. Release scope, goals, non-goals and product rules

### 1.1 Scope

1.2.0 ships four parts together. Milestones (BP §1) order the work; nothing ships separately.

| Part | What ships | Platforms in 1.2.0 | Plan |
|---|---|---|---|
| **Files & Media Home** | Home becomes one place for photos, videos and documents: filters `All`/`Videos`/`Photos`/`Documents`; app-private **Danaview folders** with **Recently deleted** (30 days); favourites, recents, name search, sort; import (Photos/Gallery, Files, "Open with Danaview", **iOS Share Extension**); file actions, multi-select bar, Save to Files / Save to Downloads, share, open in another app; native viewers (photos, the existing player, PDFKit / `PdfRenderer`, Quick Look, an in-app text/CSV viewer, a file card); **PDF tools** (merge, split, reorder, rotate, delete pages, annotate, sign, compress); photo viewer, masonry grid, badges, "Make video montage". The whole v1.0/v1.1 player hub is preserved (HOM plan §1.2, P-1…P-8). | iOS, Android, macOS (full); Windows, Linux (library, folders, import, file actions, text/CSV viewer, "Open in another app"; no PDF viewer or tools, V2-124) | HOM plan |
| **AI Studio and rich subtitles** | On-device rich subtitles (spans, per-line placement, karaoke, transcript view, timing tools, emoji tools, fonts, presets); **on-device speaker diarization** with per-speaker lanes; **on-device search index** over the Home; optional, off-by-default **AI Studio** (bring your own key for Gemini, OpenAI, Claude, OpenRouter, Grok) for clean-up, emotion, emoji, speakers, translation, Ask AI, cloud diarization and AI search, all behind Send; one shared AI layer. | iOS, Android (editor and AI); the on-device search index also on macOS; Windows/Linux name search only | AIS plan |
| **Unified Photo & Video Editor** | The editor opens photos in a **Still Photo Mode** (16-bit half-float pipeline, pro tone, 8-band HSL, spline curves, gradient/brush/luminance masks, crop/straighten/keystone, text and stickers, presets, batch export, EXIF policy, "Add to Video Project") and keeps the v1.1 timeline for video. The **8-category Beauty & Retouching Suite** works in both modes, with One-Euro temporal landmark smoothing, up to 4 subjects and keyframable parameters. | iOS, Android | VED plan |
| **Speed-test fallback** | Cloudflare public endpoint stays the default; **M-Lab NDT7** as a fallback only after a consent prompt; no provider names in the UI; both providers named in the privacy policy. | every platform with the speed test | ST plan |

### 1.2 Goals

| # | Goal | Where it is guaranteed |
|---|---|---|
| G-R1 | Every owner feature of the four plans ships in **one release** | BP §6 feature coverage |
| G-R2 | **Player preserved.** Now Playing, Continue Watching, quick actions, playlists, linked folders, queue, streams, drag-and-drop and `danaview://` links behave exactly as in 1.1 (HOM P-1…P-8) | V2-32; HOM-06…HOM-08, HOM-15, QA-107 |
| G-R3 | **Originals are never modified.** Imports copy; viewers, PDF tools, photo edits and beauty never write to a source; Quick Look editing is off; linked-folder files are read-only | v1.1 G2, V2-09, V2-10, §9.3; HOM-20, HOM-32, QA-106 |
| G-R4 | **On device by default.** With AI Studio off, the only network uses are the ones in the §9.1 inventory, each started by the user (and each download after consent) | V2-22, §9; QA-103 |
| G-R5 | **Nothing leaves the device without an explicit Send** on a disclosure that equals the payload (AIS G-S2), for every AI feature in the app | V2-201, V2-227, §7.2; AIS-08, AIS-43, QA-103 |
| G-R6 | **Non-destructive editing in both modes**: `.dnphoto` recipes for stills, `.dnproj` schema 2 for timelines; projects from 1.1 upgrade losslessly and 1.1.x opens 1.2.0 projects read-only | V2-03, V2-10; AIS-04, VED-02, VED-15, QA-106 |
| G-R7 | **Preview equals export** on a platform for rich subtitles, photo adjustments and beauty; iOS and Android match within the v1.1 parity tolerance except the segmentation-based passes of V2-17 | v1.1 ARCH §11.6, V2-11, V2-17; AIS-39, VED-32 |
| G-R8 | Smooth at scale: 50,000 library items, 10,000 documents, 48 MP stills, 1080p beauty preview on the mid tier, at the §10 budgets | §10; HOM-14, VED-31, QA-104 |
| G-R9 | v1.1's standing UI rules on every new surface (custom components, Figtree chrome, dark UI, computed contrast, touch targets ≥ 44 px, no overflow at 280–1280 px and text scale 0.85–1.35, accessibility) | §1.4; QA-105 |
| G-R10 | **Install size.** Diarization adds no install size (owner 2026-10-16); every other addition is measured and recorded against the budgets of §10.3 | V2-229, V2-14; AIS-44, VED-33, AIS-41 |

### 1.3 Non-goals for 1.2.0

- **Desktop editor and AI.** The editor, AI Studio, AI search and beauty stay iOS and Android only (v1.1 D-17); the macOS, Windows and Linux columns of the VED plan §7 are the 1.3.0 desktop editor's target.
- **The native camera** (1.3.0). Its Home kind (`savedCode`) and capture sources are reserved (§5.1) but not built.
- **Office editing** (V2-122), PDF forms, OCR as a document tool (OCR exists only inside the search index), certificate signatures, PDF/A, PDF passwords (HOM plan §8.6).
- Cloud drive sync, server-side conversion of any kind, a vecvel-run backend, accounts, billing, telemetry, remote config.
- On-device LLMs or translation, AI over video pictures, video keyframes in deep indexing (owner 2026-10-16), custom AI endpoints (AIS plan §1.3).
- Rich text on `TextItem` overlays, karaoke "current word only", font sync (AIS plan §1.3).
- Showing Danaview folders in the iOS Files app (owner 2026-10-16, V2-115).
- "Search by place" reverse geocoding (recommendation, V2-22, **[OWNER]** §16 Q-N4).
- A paid PDF or Office SDK on any platform (V2-121, V2-123).

### 1.4 Standing UI rules (binding on every ticket)

v1.1 ARCH §1.3 applies unchanged: custom `danaview_ui_kit` components only (no Material chrome, matched as whole identifiers), solid surfaces and soft shadows, rounded-rectangle text buttons and round single-icon buttons, computed foreground contrast ≥ 4.5:1, **no overflow at 280–1280 px and text scale 0.85–1.35**, Figtree as the only UI font (content fonts are content), dark UI. HOM D-98, AIS §4.1 and VED D-145 restate it (V2-113, V2-330).

**Extension in 1.2.0:** the forbidden-Material architecture test (v1.1 INT-01, UX-01) also scans `packages/danaview_documents/lib`, `packages/danaview_ai_ui/lib`, the new `danaview_features/lib/src/library/**` and `lib/src/more/settings_sections/**` files, the touched speed-test files, and `packages/danaview_editor/lib/src/editor/photo/**` and `panels/beauty/**` (INT-101). Platform views (PDFKit, Quick Look) are native content, not chrome; their surrounding toolbars are kit components.

### 1.5 Preservation register

HOM plan §1.2 (P-1…P-8) is binding. With `DANAVIEW_FILES_HOME=false` (V2-04) the Home screen is byte-for-byte the 1.1 Home (asserted by the 1.1 `test/home_screen_test.dart` and HOM-06…HOM-08 goldens). With it on, the 1.1 sections render unchanged inside the `Home` (Overview) tab, and every existing callback (`_play`, `_playRecent`, `_playPlaylist`, `_playFolder`, `danaviewPlayItems(ref, items)`) still receives `MediaRef` (V2-101's `VideoMediaItem` wraps it, HOM-01).

---

## 2. Decision log

### 2.1 Id scheme and mapping

v1.1 ARCH already uses D-45 (render-preview cache, 2026-10-11), and the AIS plan used D-45…D-70 for its own decisions, so the plan ids can't be recorded as they are. Every 1.2.0 decision gets a **V2-** id in one of five blocks. The plan ids stay valid as aliases inside the plans; new text cites the V2 id.

| Block | Source | Rule | Count |
|---|---|---|---|
| **V2-01 … V2-34** | cross-plan decisions made by this document (§2.2) | — | 34 |
| **V2-101 … V2-124** | HOM plan D-86…D-98, D-98a…D-98k | D-*n* → V2-(*n* + 15) for 86 ≤ *n* ≤ 98; D-98a…D-98k → V2-114…V2-124 in letter order | 24 |
| **V2-201 … V2-235** | AIS plan D-45…D-70, D-70a…D-70i | D-*n* → V2-(*n* + 156) for 45 ≤ *n* ≤ 70; D-70a…D-70i → V2-227…V2-235 in letter order | 35 |
| **V2-301 … V2-330** | VED plan D-116…D-145 | D-*n* → V2-(*n* + 185) | 30 |
| **V2-401 … V2-406** | ST plan D-ST1…D-ST6 | D-ST*n* → V2-(400 + *n*) | 6 |

AIS-01's job of "recording D-45…D-70 in v1.1 ARCH" is replaced: they are recorded here (§2.3), and AIS-01 and AIS-41 update this file's status cells instead of v1.1 ARCH (V2-33).

### 2.2 Cross-plan decisions (made by this document)

Each row is final unless it carries **[OWNER]**. "Resolves" names the contradiction of §14 it settles.

| ID | Decision | Resolves | Rationale |
|---|---|---|---|
| **V2-01** | **Authority and records.** This file is the 1.2.0 source of truth; `BUILD_PLAN.md` (this folder) orders the work; the four plans are the detailed reference. v1.1 ARCH stays authoritative for unchanged v1.1 behaviour. | C-1, C-3 | One place to look; v1.1 ARCH is a shipped record and isn't rewritten. |
| **V2-02** | **Process.** 1.2.0 starts after v1.1 INT-05. Milestones N0–N6 (BP §1). Ticket ids: HOM-, AIS-, VED-, ST- from the plans; **INT-1xx** for cross-plan integration, **QA-1xx** for cross-plan QA; an **`A` suffix** (for example `VED-20A`) marks the Android-lane half of a native ticket whose Dart and Apple half is the base id. New tickets VED-33/33A (spike) and VED-34/34A (filters, bokeh, stickers) close coverage gaps (BP §8). | C-28 | Keeps the plans' ids, makes the two-machine split visible in the index. |
| **V2-03** | **One project schema for 1.2.0: `.dnproj` schema 2, `minReader` 1.** AIS-04 defines it (V2-209) and writes the only production migration `s1 → s2`. VED-15 *extends* schema 2 with additive, optional fields (`ph` photo recipe on image clips, `bt` `BeautyEffectSpec` on visual clips, easing on keyframes); AIS-47's speaker lanes are in schema 2 too. There is **no schema 3 and no s2→s3 step**. The VED plan's `"schema": 3, "minReader": 3` sample is rejected. | C-2 | `minReader 3` would block 1.1.x users from even viewing their projects, against v1.1 D-12 and V2-209's reasoning. 1.2.0 hasn't shipped, so unreleased additive fields need no migration. A 1.1.x app shows a 1.2.0 project read-only without beauty, spans or lanes; nothing is lost because it can't save. |
| **V2-04** | **Flags** (compile-time `--dart-define`, default false, never flipped in code; AIS-41 passes them in release builds): `DANAVIEW_FILES_HOME` (all Pillar 1 UI; off = the 1.1 Home), `DANAVIEW_PHOTO_EDITOR` (Still Photo Mode and its Home entry points), `DANAVIEW_BEAUTY` (beauty panel and passes), `DANAVIEW_AI_STUDIO` (V2-221). Rich subtitles, fonts, presets and diarization ship under v1.1's `DANAVIEW_EDITOR` (V2-221). The speed-test fallback has no flag (it is behind its own consent). Flags are read in one file per package (`flags.dart`, INT-101) and asserted by architecture tests. | — | `editor-wip` stays releasable while ~170 tickets land, the v1.1 D-31 pattern. |
| **V2-05** | **Package graph** of §4: five new non-AI packages (`danaview_library`, `danaview_library_native`, `danaview_pdf`, `danaview_documents`, `danaview_face_tracking`), nine AI packages from the AIS plan (`danaview_ai_providers`, `danaview_ai`, `danaview_ai_ui`, `danaview_ai_studio`, conditional `danaview_ai_genkit`, `danaview_secure_keys`, `danaview_diarization`, `danaview_media_analysis`, `danaview_search`), and photo/beauty additions inside the four editor packages. | — | Names the packages the plans leave open; keeps plugins free of `danaview_*` dependencies so the 1.3.0 camera and desktop can reuse them. |
| **V2-06** | **Library storage.** One SQLite database `library.db` (package `sqlite3`, FTS not needed here) under the library root (§5.2), written only through `danaview_library`'s writer. Files live at `files/<entryId>/<displayName>`; **folder membership is a database column**, so move and nest are database-only and atomic; rename renames one file inside its own directory. Atomic copy-in through `imports/<jobId>.part` then rename. | — | A 50,000-item tree with nesting, favourites, recents and Recently deleted needs indexed queries; id-keyed directories make moves crash-safe and keep paths short. |
| **V2-07** | **The search index is a separate database** `search.db` (SQLite FTS5 **[VERIFY: AIS-50, V-S21]**), backup-excluded, opened by `danaview_search` and joined to `library.db` by entry id. AIS-50's "index tables in the library database" becomes "in `search.db` next to it". | C-5 | The library is included in backups (V2-115) and the index must be excluded (V2-230). One file can't be both. |
| **V2-08** | **Recently deleted** (owner 2026-10-16): delete sets `trashed_at` and `expires_at = trashed_at + 30 days` on the entry or folder subtree; files stay where they are until purge. Trashed rows are excluded from every filter, search, recents and index query; they still count toward storage. The expiry sweep runs on launch and daily while foreground (`expires_at ≤ now`, wall clock; a clock moved backwards never resurrects or deletes early because `expires_at` is fixed at delete time). **Restore** goes back to the original folder, or `Imported` if it no longer exists. **Empty now** purges everything. A file still referenced by an editor project or `.dnphoto` warns before delete ("Used in 2 projects") and, after purge, the editor's v1.1 relink flow takes over. | C-24 | Matches the owner's rule; no file moves means a crash mid-delete can't lose data. |
| **V2-09** | **Item identity.** Ids are namespaced: `fe_…` (Danaview folder entry), `fd_…` (Danaview folder), `lk:<linkedRootId>/<relativePath>` (a file in a linked folder, read-only), `ph:<localIdentifier>` (PhotoKit asset), `ms:<id>` (MediaStore item). Only `fe_`/`fd_` rows live in `library.db`; linked and system items are listed live and cached in memory. The editor references Danaview folder files through `danaview-library://fe_…` URIs resolved by an app-root adapter, so moves and renames never break a project; system and linked items enter the editor through v1.1 D-13 import rules. | C-8, C-24 | Stable references across moves; v1.1 import policy unchanged. |
| **V2-10** | **`.dnphoto` lives in the editor's app-private store**, `<support>/danaview/editor/photos/<photoId>/recipe.dnphoto` (two-line header + body like `.dnproj`, v1.1 ARCH §8.2), never next to the original and never in a linked folder. Its `source` is a typed reference (§5.7), never a raw `DCIM` path. Backup rules follow the editor's project bundles (v1.1 ARCH §8.1). | C-8 | The VED plan's "saved alongside the original" would write into user folders, against G-R3; iOS apps can't address `DCIM` paths. |
| **V2-11** | **Still Photo Mode renders through the engine.** A still is a one-frame **RenderPlan v2** (§6.3) compiled by core from the recipe and rendered by the native engine for preview tiles and export, so photo and video share every pass (VED G-U1). **Global per-pixel colour operations** (whites, blacks, temperature/tint beyond v1.1's range, vibrance, the 8-band HSL mixer, the RGB and channel curves) are **baked in Dart into one generated `.vlut` per recipe** (33³, or 65³ when a curve's slope exceeds 8 **[VERIFY: VED-08]**) and applied in a new `recipeLut` slot; engines add only the spatial passes. The normative effect order is §6.2. | C-16 | Parity by construction for every global op (one implementation in Dart, golden-tested), and much less native shader code. |
| **V2-12** | **RenderPlan v2** is an additive contract change (new optional layer fields, new asset kinds, `v: 2`) plus engine interface additions (still preview/export, landmark assets). It is a lead-approved amendment of the frozen v1.1 Pigeon surface, done once by **INT-102** (Dart, Pigeon, iOS glue) and **INT-102A** (Android glue), exactly like v1.1 INT-06. Native passes then register through placeholders INT-102 creates, so no later ticket edits v1.1-owned render files. | C-18 | v1.1 BP §2 freezes the surface after ENG-06; beauty and stills can't be expressed in RenderPlan v1. |
| **V2-13** | **One landmark topology on both platforms.** Apple Vision returns about 76 2D face points, not the 468 the VED plan assumes, so the canonical face mesh is the **MediaPipe Face Landmarker topology (478 points incl. irises)**, produced on iOS and Android by the same model through the runtime VED-33 picks (MediaPipe Tasks, LiteRT, Core ML conversion or the ONNX Runtime that sherpa-onnx brings **[VERIFY: VED-33]**). Apple Vision is used only for fast face rectangles where it helps. Pose (33 points) and segmentation (person, hair) models come from the same family. | C-7 | One topology means one set of warp shaders, one `.dnface` format and goldens that match across platforms. |
| **V2-14** | **Beauty models download on demand, with consent, like whisper** (recommendation, **[OWNER]** §16 Q-N1): a "Beauty pack" (face landmarker, pose, segmentation models) from a pinned Hugging Face revision (no new host), through v1.1's downloader (AI-09) and consent view, stored with the speech models and backup-excluded. Native runtime code is bundled (iOS can't download code) and its size is measured by VED-33. Without the pack, beauty and portrait tools are hidden (graceful degradation). | C-19 | Same rule the owner set for diarization (V2-229); keeps the privacy host list unchanged; D-143's "zero external calls" holds after the one consented download. |
| **V2-15** | **Temporal smoothing is pure Dart.** Trackers return raw landmarks; `.dnface` stores raw per-frame landmarks (§5.9). The One-Euro filter (`beauty/one_euro.dart`, core) produces a smoothed track per clip and setting, written as a content-addressed plan asset, so preview and export (and iOS and Android) see identical smoothed points. Occlusion fade-out over 3 frames is part of the same function. | — | Determinism and parity; the 1.3.0 camera mirrors the same function natively against committed vectors. |
| **V2-16** | **Keyframe easing.** v1.1 keyframes are linear only (v1.1 ARCH §1.2). VED D-134 adds `linear` and cubic-bezier easing per key in the **model** (schema 2, `e`), lowered by the compiler to piecewise-linear keys on the frame grid (one key per frame across eased spans, merged when collinear within 1e-4). RenderPlan keys stay linear; engines don't change. Easing applies to beauty parameters and to every existing keyframable property. | C-17 | No engine change; frame-exact on both platforms. |
| **V2-17** | **Segmentation-based passes** (portrait bokeh, hair colour, background protection beyond pose pinning) run the segmentation model at render time on each platform. They are exempt from cross-platform parity (documented tolerance per pass in VED-32) but preview equals export on a platform, and the same model and thresholds run on both. Everything landmark-driven (face, eyes, nose, lips, skin, makeup, body warps) is deterministic and inside the v1.1 parity tolerance. | — | Per-frame segmentation masks for video can't be cached at reasonable size; honest tolerance beats a false promise. |
| **V2-18** | **Still export size per tier** (recommendation, **[OWNER]** §16 Q-N3): full sensor resolution on mid and high tiers (48 MP and 100 MP); low tier up to 48 MP; `minimal` tier up to 24 MP, with the export sheet saying "Exported at 24 MP on this device". All export is **tiled** (tiles ≤ 4096 px with an apron of the largest spatial radius) and encoded from tiles, so peak memory is bounded (§10). | — | 100 MP in RGBA16F is 800 MB; only tiling and tier caps keep "no OOM" (v1.1 D-40) true. |
| **V2-19** | **Colour spaces.** Still Photo Mode works in linear-light half float (`RGBA16F`, or `RGB10A2` fallback **[VERIFY: VED-04A]**) in the source's gamut; exports are tagged Display P3 when the source is P3 (or wide-gamut HEIC/DNG), else sRGB. Video export stays SDR BT.709 8-bit (v1.1 D-23). | C-31 | VED D-118 for stills without changing v1.1's video promise. |
| **V2-20** | **Shared AI layer paths are authoritative here** (AIS-43, V2-227): the send view is `packages/danaview_ai_ui/lib/src/ai_send_view.dart`, provider settings are under `packages/danaview_ai_ui/lib/src/settings/`, the master switch, feature registry, `AiClient`, usage ledger and the `AiKeyStore` port are in `danaview_ai`. The settings route is **`/settings/ai`** ("Settings › AI Studio"; Settings › Video editor keeps a row that opens it). The pref is `ai.enabled` from the start; the AIS plan's migration from `editor.ai.enabled` is dropped (that key never shipped). AIS-31 and AIS-32 own the moved paths (BP §8). | C-4 | The AIS plan's §3.2 file list predates AIS-43. |
| **V2-21** | **AI platforms.** AI Studio, AI search (levels a and b) and cloud diarization run on iOS and Android only (the key store is mobile only, V2-202). The on-device search index runs on iOS, Android and macOS; Windows and Linux get name search. Diarization is iOS and Android (with the editor). | C-20 | AIS §1.3 and §7.1 combined. |
| **V2-22** | **The network inventory (§9.1) is closed.** Any new socket-opening path needs an [INTEGRATION] change to §9.1, the privacy text (INT-106) and QA-103's guard. "Search by place" (reverse geocoding, AIS §7.6) is **deferred** (recommendation, **[OWNER]** §16 Q-N4): EXIF place names already in a file are indexed, nothing is looked up. | C-6 | The roadmap's principle 3 says AI Studio is the only *optional* network use, which ignored the speed test, the model downloads and geocoding. |
| **V2-23** | **Consent call sites.** v1.1 `UserConsent.accepted(` stays only in `danaview_editor/.../flows/captions/model_consent_view.dart` and covers every model download (whisper, diarization V2-229, Beauty pack V2-14). `AiSendConsent.accepted(` and `ProviderProbeConsent.accepted(` per rule 17 (§4.2). `OpenNetworkConsent.accepted(` (M-Lab, V2-402) only in `packages/danaview_features/lib/src/tools/speed_consent_sheet.dart`. Architecture tests enforce each (AIS-01, AIS-43, INT-101, ST-04). | — | One auditable call site per consent kind. |
| **V2-24** | **Plugin adapters live at the app root** (`lib/adapters/`), never in `danaview_editor`. This corrects AIS-37's `danaview_editor/lib/src/app/adapters/secure_key_store_adapter.dart`, which would break AIS rule 12 (the editor never imports `danaview_secure_keys`). `danaview_features` may import `danaview_library_native` and `danaview_documents` directly (rule 23). | C-32 | Keeps AIS rule 12 and v1.1 rule 7 true. |
| **V2-25** | **Native surfaces freeze after their first ticket.** Each new plugin's Pigeon surface is defined in full by one ticket (`danaview_library_native`: HOM-02; `danaview_pdf`: HOM-24; `danaview_face_tracking`: VED-16) with generated code and native stubs returning `notSupportedOnDevice`; later tickets implement native classes behind it. A surface change after that is an [INTEGRATION] amendment. | — | Exclusive file ownership with parallel native work (v1.1 D-42 pattern). |
| **V2-26** | **Shared files are edited only in the order of BP §5** (the shared and integration file register). | C-12…C-15 | v1.1 BP §7 rule. |
| **V2-27** | **Two-machine split.** The Mac builds Dart, iOS, macOS and every integration and doc ticket, and runs one iOS Simulator at a time; it never runs the Android emulator. The Windows laptop builds the Android lane (`A` tickets, `HOM-25`, `HOM-27`, the Android halves of AIS-11/24/44/45/50 and Android QA) on `editor-android`, merged into `editor-wip` by the Mac. Windows and Linux desktop builds are checked in CI, not on the laptop (**[OWNER]** §16 Q-N9). | — | The v1.1 split that worked (handoff `ANDROID_LANE.md`). |
| **V2-28** | **Thumbnails.** PhotoKit (`PHCachingImageManager`) and MediaStore (`loadThumbnail`) for system assets; `QLThumbnailGenerator` for files on iOS/macOS; `PdfRenderer` first page and `ThumbnailUtils`/`MediaMetadataRetriever` on Android; type icons elsewhere. The disk cache stores **WebP on Android and JPEG (HEIC on iOS 17+) on Apple**, because ImageIO has no WebP encoder **[VERIFY: HOM-04]**. One cache for library, documents and the Home grid: `<cache>/danaview/library/thumbs/`, 64 MB memory LRU (V2-104). | C-21 | HOM D-89 named one thumbnailer for everything and a WebP cache Apple can't write. |
| **V2-29** | **Saved signatures stay on the device**: app-private, **backup-excluded** (iOS `isExcludedFromBackup`, Android `noBackupFilesDir/signatures/`), deletable in Settings and in the Sign tool. | — | "Stay on the device" (HOM §8.5) is only true if backups don't carry them. |
| **V2-30** | **Desktop in 1.2.0** follows the §3 matrix: macOS gets the full Files & Media Home (PDFKit, Quick Look, the Share sheet as a target is later) and the on-device search index; Windows and Linux get library, folders, import, file actions, the text/CSV viewer, "Open in another app" and name search. No editor, AI or beauty on desktop. | C-20 | Consolidates four plans' desktop notes. |
| **V2-31** | **Face test data.** Beauty goldens, eval sets and E2E use synthetic faces (generated or rendered heads) or images with a recorded licence that allows modification and redistribution in a repo; no photo of a real person without their written consent on file. The set is listed in `docs/v1.2/video-editor-update/qa/face_fixtures.md` (VED-33) (**[OWNER]** §16 Q-N6 for owner-recorded clips). | — | Beauty retouching of real faces in a public repo is a consent and licence problem. |
| **V2-32** | **Home preservation gate.** HOM-15's regression suite is a merge gate for every Pillar 1 ticket that touches `danaview_features/lib/src/library/`; with the Home flag off the 1.1 Home must be unchanged. | — | G-R2. |
| **V2-33** | **AIS-01 and AIS-41 record status in this file** (decision status cells, [VERIFY] closures, release status) instead of v1.1 ARCH; AIS-41 adds one pointer line to v1.1 ARCH's header at release. | C-3 | V2-01. |
| **V2-34** | **Opening photos in the editor** uses the v1.1 import policy (D-13): a PhotoKit photo becomes a managed copy, a Files photo a security-scoped reference, an Android photo a persisted grant with managed-copy fallback, a Danaview folder photo a `danaview-library://` reference (V2-09). The `.dnphoto` keeps the resulting media reference and its `quickHash` fingerprint; a missing source uses the v1.1 relink flow. | C-8 | Reuses tested code; no new import rules. |

### 2.3 Plan decisions, mapped

Status: **final** (no owner input needed), **owner 2026-10-15/16** (decided), **[OWNER]** (recommendation is the working default; §16). "Here" points to where this document refines the decision.

#### Files & Media Home (HOM plan §3)

| V2 | Plan | Decision (short) | Status | Here |
|---|---|---|---|---|
| V2-101 | D-86 | Navigation: `Home` (Overview, classic layout) plus filters `All`, `Videos`, `Photos`, `Documents`; `Playlists`, `Folders`, `Projects` tabs (updated by D-98a) | final | §5.1 |
| V2-102 | D-87 | Presentation: classic rows on Home, masonry on Photos, cards on Videos | final | — |
| V2-103 | D-88 | Privacy and permissions: no telemetry; limited photo library (iOS) and partial access (Android 13+); full library access only for the Photos tab's system-library view | **[OWNER]** Q-H1 | §9.4 |
| V2-104 | D-89 | Thumbnails: 64 MB memory LRU + disk cache + OS thumbnailers | final, refined | V2-28 |
| V2-105 | D-90 | Formats: JPEG, PNG, WebP, HEIC/HEIF, AVIF, RAW (DNG, CR2, NEF, ARW) and every video format the player plays; decode support per platform **[VERIFY: HOM-02]** | final | §3 |
| V2-106 | D-91 | Tap actions: video → player with resume; photo → viewer with Edit | final | — |
| V2-107 | D-92 | Multi-select bar: Make video montage, Batch edit photos, Add to playlist, Play all | **[OWNER]** Q-H2 | §5.1 |
| V2-108 | D-93 | System albums and device folders coexist | final | — |
| V2-109 | D-94 | Desktop browser: sidebar shortcuts, external drives, drag and drop | final | V2-30 |
| V2-110 | D-95 | Badges: duration, RAW/HDR/Live, resolution, frame rate | final | — |
| V2-111 | D-96 | Incremental scanning via PhotoKit change observers and Android `ContentObserver` | final | §8.4 |
| V2-112 | D-97 | Sort and group: date groups, folder; location grouping only from existing EXIF place names (V2-22) | final, narrowed | — |
| V2-113 | D-98 | Owner UI rules | final (= §1.4) | §1.4 |
| V2-114 | D-98a | Filters `All`/`Videos`/`Photos`/`Documents`; document sub-filters `PDF`, `Word`, `Excel`, `PowerPoint`, `Text/CSV`, `Other`; UTType / MIME / extension classifier table | owner 2026-10-16 | §5.1 |
| V2-115 | D-98b | Danaview folders app-private, nested, mixed types, included in backups; Recently deleted 30 days; not shown in the iOS Files app in 1.2.0 | owner 2026-10-16; Android backup limit **[VERIFY: HOM-17]** | V2-06, V2-08, §5.2 |
| V2-116 | D-98c | Import is a copy; sources never changed; Photos/Gallery, Files, "Open with Danaview", iOS Share Extension | owner 2026-10-16 | §5.6, §8.3 |
| V2-117 | D-98d | Getting files out: Save to Files, Save to Downloads, share sheet, Open in another app | owner 2026-10-16 | §8.4 |
| V2-118 | D-98e | File actions and multi-select bar | owner 2026-10-16 | — |
| V2-119 | D-98f | Favourites, recents (50), name search, sort per folder; AI Studio index when it lands | owner 2026-10-16 | §7.6 |
| V2-120 | D-98g | Viewers native first (PDFKit, `PdfRenderer`, Quick Look) | owner 2026-10-16 | §8.1, §8.2 |
| V2-121 | D-98h | Android Office files: file card + Open in another app; text/CSV in-app; no paid SDK | owner 2026-10-16 | — |
| V2-122 | D-98i | No Office editing | owner 2026-10-16 | §1.3 |
| V2-123 | D-98j | PDF tools via one `danaview_pdf` plugin; results as new files; Android platform/Jetpack APIs first, PdfBox-Android or PDFium only if HOM-27 shows text turning into pictures | owner 2026-10-16; **[VERIFY: HOM-27]** | §8.1 |
| V2-124 | D-98k | Desktop documents: macOS = iOS paths; Windows/Linux viewers and tools wait for 1.3.0 | owner 2026-10-16 | V2-30 |

#### AI Studio and rich subtitles (AIS plan §2, §7)

| V2 | Plan | Decision (short) | Status | Here |
|---|---|---|---|---|
| V2-201 | D-45 | Privacy model: master switch off, per-provider opt-in, disclosure + Send per action, nothing automatic | **[OWNER]** Q-A1 (recommended a) | §7.2 |
| V2-202 | D-46 | Keys in first-party `danaview_secure_keys` (Keychain ThisDeviceOnly / Keystore-wrapped in `noBackupFilesDir`) | final | §8.9 |
| V2-203 | D-47 | Pure `dart:io` HTTP, no vendor SDKs, host allow-list, keys in headers only | final (unless AIS-42 adopts Genkit behind the transport, V2-228) | §7.2 |
| V2-204 | D-48 | One `LlmProvider` interface, capability flags (+ `imageInput`, `embeddings`, V2-227), timeouts, retries, rate limits | final | — |
| V2-205 | D-49 | Token estimate before, recorded usage after, no prices | **[OWNER]** Q-A2 | — |
| V2-206 | D-50 | Voice-tone audio clips (16 kHz mono WAV, caps), audio-capable providers only | **[OWNER]** Q-A3 | §7.2 |
| V2-207 | D-51 | Strict JSON contracts, local validation and repair only, review always | final | §7.3 |
| V2-208 | D-52 | Rich text: span runs over grapheme ranges + cue overrides + placement | final | — |
| V2-209 | D-53 | Project schema 2, `minReader` 1, migration s1→s2 | final, widened by V2-03 | §5.8 |
| V2-210 | D-54 | SRT/WebVTT mapping of styles, speakers, karaoke, RTL | final | — |
| V2-211 | D-55 | Emoji: graphemes, system emoji font, Emoji ≤ 12.0 allow-list for AI emoji | **[OWNER]** Q-A4 | — |
| V2-212 | D-56 | RTL and complex scripts: auto direction, bundled Noto fallbacks, script rules | final | — |
| V2-213 | D-57 | Translation: new track, sentence groups, proportional re-timing, AI-11 re-segmentation | final | — |
| V2-214 | D-58 | Emotion taxonomy: 10 labels, fixed emoji and style table | **[OWNER]** Q-A5 | — |
| V2-215 | D-59 | Speakers: manual; on-device diarization (V2-229); AI suggestions or cloud diarization when AI Studio is on | owner 2026-10-16; text-only labelling on Claude/Grok **[OWNER]** Q-A6 | — |
| V2-216 | D-60 | Bundled fonts ≤ 8 MB of non-CJK Noto; system CJK; packs (AIS-27) only if asked | **[OWNER]** Q-A7 | §10.3 |
| V2-217 | D-61 | Font import .ttf/.otf, validation, app-level library, rights reminder | **[OWNER]** Q-A8 (wording; warn, don't block) | — |
| V2-218 | D-62 | Subtitle presets: built-ins in code, user presets in one JSON file, tracks copy values | final | §5.5 |
| V2-219 | D-63 | Store disclosures, privacy labels, Data safety, review access, AI-content reporting | **[OWNER]** Q-A9 | §9.5 |
| V2-220 | D-64 | Suggestions outside history, project sidecar, stale detection, accept = command | final | — |
| V2-221 | D-65 | Gating: `DANAVIEW_AI_STUDIO` + runtime switch; rich subtitles unflagged | final, extended by V2-04 | — |
| V2-222 | D-66 | Exactly five provider hosts; loopback override for debug/tests only | **[OWNER]** Q-A10 | §9.1 |
| V2-223 | D-67 | Ask AI free text edits only the selected text | final | — |
| V2-224 | D-68 | Karaoke via the sprite `reveal` channel; no plan or engine change | final (independent of RenderPlan v2) | — |
| V2-225 | D-69 | Word timings stored on cues | final | — |
| V2-226 | D-70 | 1.2.0 process: "extends" ownership, skeleton placeholders, register | final, generalised by V2-02, V2-26 | BP §0 |
| V2-227 | D-70a | Shared `danaview_ai` layer, one AI Studio switch | owner 2026-10-16 | V2-20, §7.1 |
| V2-228 | D-70b | Genkit spike first; adopt behind `LlmProvider` only if our transport stays in control; all or nothing | owner 2026-10-16 | §7.1 |
| V2-229 | D-70c | On-device diarization (sherpa-onnx, pyannote segmentation 3.0, embedding model), downloaded on demand with consent; install size doesn't grow | owner 2026-10-16; models **[VERIFY: AIS-44]** | §7.5 |
| V2-230 | D-70d | On-device search index over the Home | owner 2026-10-16 | V2-07, §5.10 |
| V2-231 | D-70e | Word-to-speaker assignment; overlaps never merged; missed voice = empty cue marked "needs text" | owner 2026-10-16 | §7.5 |
| V2-232 | D-70f | Per-speaker subtitle lanes (one track per speaker in a group) | owner 2026-10-16 | §5.8 |
| V2-233 | D-70g | Optional cloud diarization behind Send | owner 2026-10-16 | §7.3 |
| V2-234 | D-70h | AI search (a): only the typed question is sent; Send on every question | owner 2026-10-16 | §7.6 |
| V2-235 | D-70i | AI search (b): deep indexing per folder; photos and documents only, never video keyframes | owner 2026-10-16 | §7.6 |

#### Unified Photo & Video Editor (VED plan §2)

| V2 | Plan | Decision (short) | Status | Here |
|---|---|---|---|---|
| V2-301 | D-116 | Non-destructive `.dnphoto` recipe | final, refined | V2-10, §5.7 |
| V2-302 | D-117 | Still Photo Mode reuses the editor's visual pipeline | final, refined | V2-11 |
| V2-303 | D-118 | P3/Rec.709 with 16-bit float internal precision for stills | final, refined | V2-19 |
| V2-304 | D-119 | Preview at screen resolution (tiles, mip levels); export re-evaluates at full resolution | final | §6.2 |
| V2-305 | D-120 | Pro tone: exposure, contrast, highlights, shadows, whites, blacks, clarity, dehaze, vignette, grain | final | §6.2 |
| V2-306 | D-121 | 8-band HSL mixer with Target Adjustment Tool | final (baked, V2-11) | — |
| V2-307 | D-122 | Spline RGB and channel curves, ≤ 8 points | final (baked, V2-11) | — |
| V2-308 | D-123 | Still Photo Mode has the same 8-category beauty as video (and later camera) | **[OWNER]** Q-V1 | — |
| V2-309 | D-124 | Crop, aspect ratios, horizon leveler, 90° rotation, H/V keystone | final | §6.2 |
| V2-310 | D-125 | Batch: copy/paste recipe, background batch export JPEG/PNG/WebP/HEIC with quality | **[OWNER]** Q-V2 | §8.7 |
| V2-311 | D-126 | Masks: linear, radial, brush (+ luminance) with local adjustments | final | §6.2 |
| V2-312 | D-127 | Text, stickers, borders via `FontCatalog`/`TextLayoutEngine` | final | — |
| V2-313 | D-128 | "Add to Video Project": photo becomes a 3 s still clip, optional Ken Burns | final, refined | §6.1 |
| V2-314 | D-129 | Keep EXIF/IPTC by default; "Strip metadata on export" toggle | **[OWNER]** Q-V3 (default keep vs strip; GPS) | §9.4 |
| V2-315 | D-130 | Intent routing: photo → Still UI; video/multi → timeline; unsupported tools hidden | final | §6.1 |
| V2-316 | D-131 | Beauty placed after chroma key, before grade | final, merged into §6.2 order | §6.2 |
| V2-317 | D-132 | One-Euro smoothing of landmarks on video | final, refined | V2-13, V2-15 |
| V2-318 | D-133 | Up to 4 subjects with persistent Face IDs per clip | **[OWNER]** Q-V4 | §6.4 |
| V2-319 | D-134 | Keyframable beauty channels, linear and bezier easing | final, refined | V2-16 |
| V2-320 | D-135 | Background pre-tracking into `.dnface` caches | final | §5.9 |
| V2-321 | D-136 | Project schema: `BeautyEffectSpec` on visual clips | final, **re-homed into schema 2** | V2-03 |
| V2-322 | D-137 | Beauty parity across photo, video (and the 1.3.0 camera) | final | VED-32 |
| V2-323 | D-138 | Body slimming with pose and background-preservation pinning | **[OWNER]** Q-V5 | §6.4 |
| V2-324 | D-139 | "Beauty & Retouching" inspector tab | final | — |
| V2-325 | D-140 | Split before/after comparator, press-and-hold original | final | §6.4 |
| V2-326 | D-141 | Beauty presets and copy/paste attributes | final | — |
| V2-327 | D-142 | Low tiers run beauty on half-resolution proxies in interactive playback | final; beauty counts as "heavy" for the v1.1 render-preview cache | §6.4 |
| V2-328 | D-143 | On-device models only; no cloud calls | final, with V2-14's one consented download | §9.1 |
| V2-329 | D-144 | Per-category and master bypass | final | — |
| V2-330 | D-145 | Standing UI rules | final (= §1.4) | §1.4 |

#### Speed-test fallback (ST plan §3)

| V2 | Plan | Decision (short) | Status | Here |
|---|---|---|---|---|
| V2-401 | D-ST1 | Provider chain: Cloudflare public, then M-Lab NDT7 after consent; `SpeedTestProvider` keeps the order configurable | owner 2026-10-16 | §8.10 |
| V2-402 | D-ST2 | One-time M-Lab consent prompt, remembered, changeable in Settings › Privacy | owner 2026-10-16 | V2-23 |
| V2-403 | D-ST3 | Health check folded into latency; per-phase failover; failed provider skipped 10 minutes | owner 2026-10-16 | — |
| V2-404 | D-ST4 | Per-phase provider attribution, never shown by brand; "measured on two servers", "open network" notes | owner 2026-10-16 | — |
| V2-405 | D-ST5 | No provider names in the speed-test UI | owner 2026-10-16 | — |
| V2-406 | D-ST6 | Privacy policy names both providers; store answers updated if needed | owner 2026-10-16 (owner reviews wording) | §9.5 |

---

## 3. Platform matrix and gating

| Capability | iOS / iPadOS (15.0+) | Android (API 29+ editor gate; Home from API 24) | macOS | Windows | Linux |
|---|---|---|---|---|---|
| Player hub, playlists, queue, linked folders, streams (P-1…P-8) | unchanged | unchanged | unchanged | unchanged | unchanged |
| Danaview folders, Recently deleted, favourites, recents, name search, sort | yes | yes (API 24+) | yes | yes | yes |
| System photo library view (Photos tab) | PhotoKit, limited access honoured | MediaStore, partial access (13+) honoured | PhotoKit | Pictures folder scan (HOM-03) | XDG Pictures scan (HOM-03) |
| Import | `PHPicker`, `UIDocumentPicker`, Open with, **Share Extension** | Photo Picker, SAF, `VIEW`/`SEND`/`SEND_MULTIPLE` | `PHPicker`, `NSOpenPanel`, Open With, drop | `file_selector`, association, drop | `file_selector`/portal, drop |
| Getting files out | Save to Files, share, Open in | Save to Downloads, share, Open with | save panel, share, open | save dialog, default app | save dialog, `xdg-open` |
| PDF viewer | PDFKit | `PdfRenderer` (search/selection per **[VERIFY: HOM-25]**) | PDFKit | file card + Open in another app | file card + Open in another app |
| PDF tools | PDFKit | per HOM-27 route | PDFKit | 1.3.0 | 1.3.0 |
| Office / other files | Quick Look (editing off) | file card + Open in another app | Quick Look | file card | file card |
| Text / CSV | Quick Look | in-app viewer | Quick Look | in-app viewer | in-app viewer |
| Photo viewer, masonry, badges | yes | yes | yes | yes | yes |
| Edit in Editor, Make video montage, Batch edit | yes (flags) | yes (flags; API 29+) | hidden (v1.1 D-17) | hidden | hidden |
| Still Photo Mode, beauty | yes; beauty needs the Beauty pack (V2-14) | yes (API 29 + GLES 3; RGBA16F per **[VERIFY: VED-04A]**) | – | – | – |
| Rich subtitles, fonts, presets, karaoke | yes | yes | – | – | – |
| Diarization (on device) | yes, tiers meeting 0.3× RT (V2-229) | yes, same rule | – | – | – |
| On-device search index | Vision labels + OCR, PDFKit text | ML Kit (bundled) + `PdfRenderer` text where available | Vision + PDFKit | names, text/CSV content | names, text/CSV content |
| AI Studio, AI search, cloud diarization | yes (switch off by default) | yes (switch off by default) | – | – | – |
| Speed test with M-Lab fallback | yes | yes | yes | yes | yes |

**Runtime gates.** Every capability a device lacks is hidden, not disabled (roadmap principle 1): no Beauty pack → no Beauty tab; tier below the diarization speed target → no "Detect speakers"; no `RGBA16F` render target → `RGB10A2` (or `RGBA8` with dithering on the minimal tier) with no UI difference; `PdfRenderer` can't open a password PDF → file card. Editor gates are v1.1's (`EditorCapabilities`), extended with `stillMaxPixels`, `halfFloatTargets`, `beautyTier` (INT-102).

**Flags** (V2-04): `DANAVIEW_FILES_HOME`, `DANAVIEW_PHOTO_EDITOR`, `DANAVIEW_BEAUTY`, `DANAVIEW_AI_STUDIO`, with v1.1's `DANAVIEW_EDITOR` and `DANAVIEW_AUTO_CAPTIONS`. During development run with all of them `=true`.

---

## 4. Package graph, dependency rules and file layout

### 4.1 Graph (1.2.0 additions in **bold**; arrows are allowed imports)

```
app root (lib/: main.dart, app.dart, router/, **adapters/**)
 ├─ danaview_features (+ library tabs, viewers, search UI, settings sections)
 │    ├─ danaview_ui_kit, danaview_domain, danaview_data, danaview_engine, danaview_platform   (v1.1 deps)
 │    ├─ **danaview_library** (pure Dart: item model, classifier, library.db, folders, trash, import, organise) ──► danaview_domain, sqlite3
 │    ├─ **danaview_library_native** (plugin iOS/macOS/Android, Pigeon: photo library, pickers, out, share, open-in, Quick Look, thumbnails, App Group inbox, incoming intents) ──► no danaview_*
 │    ├─ **danaview_documents** (Flutter UI: viewer router, text/CSV viewer, file card, PDF viewer and tools UI, signatures) ──► danaview_library, danaview_pdf, danaview_library_native, danaview_ui_kit
 │    │    └─ **danaview_pdf** (plugin iOS/macOS/Android, Pigeon: PDFKit / PdfRenderer + HOM-27 write path, text extraction) ──► no danaview_*
 │    ├─ **danaview_search** (query types and the search UI's controller only)
 │    └─ **danaview_ai_ui** (the AI search chip uses the one send view)
 ├─ danaview_editor (UX; + photo/ workspace, panels/beauty/, speaker lanes UI)
 │    ├─ danaview_editor_core (+ photo/, color/, beauty/, schema 2, rich cues, lanes, easing)
 │    ├─ danaview_editor_engine_api (+ still preview/export service, landmark assets, reference passes, render prep v2)
 │    ├─ danaview_transcription (+ words on drafts, speakers/)
 │    ├─ **danaview_ai_studio** ──► **danaview_ai**, danaview_editor_core, danaview_transcription
 │    ├─ **danaview_ai_ui** ──► **danaview_ai**, danaview_ui_kit
 │    ├─ danaview_editor_fonts (+ Noto)
 │    └─ danaview_ui_kit, danaview_data, danaview_platform, danaview_domain, danaview_features (chrome/orientation/storage only)
 ├─ danaview_editor_engine (+ Pigeon v2 amendment, Still/, Photo/, Beauty/ native passes) ──► engine_api, core
 ├─ danaview_whisper
 ├─ **danaview_ai** (pure Dart: switch, feature registry, AiClient, usage ledger, AiKeyStore port) ──► **danaview_ai_providers**
 ├─ **danaview_ai_providers** (pure Dart + dart:io: contracts, transport, consent tickets, adapters) ──► meta, collection, crypto
 ├─ **danaview_ai_genkit** (only if AIS-42 adopts Genkit) ──► danaview_ai_providers, genkit
 ├─ **danaview_secure_keys** (plugin iOS/Android) ──► no danaview_*
 ├─ **danaview_diarization** (FFI plugin iOS/Android: sherpa-onnx) ──► no danaview_*
 ├─ **danaview_media_analysis** (plugin iOS/macOS/Android: Vision / ML Kit labels + OCR) ──► no danaview_*
 ├─ **danaview_search** (pure Dart: index store, extractors, query engine, AI levels) ──► danaview_library, danaview_ai, sqlite3
 └─ **danaview_face_tracking** (plugin iOS/Android: face mesh, pose, segmentation runtime; video frame sampling) ──► no danaview_*
```

Only the app root constructs plugin-backed implementations and adapts them to ports (V2-24): `lib/adapters/{secure_key_store_adapter, face_tracking_adapter, media_analysis_adapter, document_text_adapter, library_media_access_adapter, speaker_model_adapter}.dart`.

### 4.2 Dependency rules (enforced by `test/architecture/dependency_rules_test.dart` and per-package architecture tests)

Rules 1–8 are v1.1 ARCH §4.2 and stay as they are. Rules 9–19 are the AIS plan's §3.1, with rule 13 replaced by rule 17 and adapters moved by V2-24. Rules 20–31 are new (INT-101 adds them).

9. `danaview_ai_providers` → only `meta`, `collection`, `crypto` and the SDK. No Flutter, no `danaview_*`.
10. `danaview_ai_studio` → `danaview_ai`, `danaview_ai_providers` (types), `danaview_editor_core`, `danaview_transcription`, `characters`, `collection`, `meta`, `path`. Never engine packages, `danaview_editor`, `danaview_features`, `danaview_secure_keys`. No widgets.
11. `danaview_secure_keys` → no `danaview_*`; only the app root imports it.
12. `danaview_editor` may import `danaview_ai_studio`, `danaview_ai`, `danaview_ai_ui` and `danaview_ai_providers` (types). Never `danaview_secure_keys`, `danaview_face_tracking`, `danaview_diarization`, `danaview_media_analysis`, `danaview_pdf` or `danaview_library_native`.
13. *(replaced by 17)*
14. `HttpClient(` is constructed in AI packages only in `packages/danaview_ai_providers/lib/src/transport/http_transport.dart`.
15. No AI package contains `?key=`; no `print`/`debugPrint`/`log` in AI packages takes a body, response, key or caption (grep test with an allow-list).
16. `danaview_ai` → only `danaview_ai_providers`, `meta`, `collection` and the SDK. Every feature that sends anything goes through `danaview_ai`; no other package builds a provider or transport.
17. `AiSendConsent.accepted(` only in `packages/danaview_ai_ui/lib/src/ai_send_view.dart`; `ProviderProbeConsent.accepted(` only in `packages/danaview_ai_ui/lib/src/settings/provider_sheet.dart`.
18. `danaview_diarization`, `danaview_media_analysis`, `danaview_search` open no sockets (`HttpClient(`, `Socket.connect`, `WebSocket.connect`, `HttpURLConnection`, `URLSession` banned by grep in Dart, Swift and Kotlin); model files arrive only through v1.1's consented downloader.
19. Only `danaview_ai_genkit` imports `package:genkit*`, and every Genkit call goes through the injected `HttpTransport`.
20. `danaview_library` is pure Dart: no `package:flutter`, no `danaview_*` except `danaview_domain`; deps `sqlite3`, `meta`, `collection`, `crypto`, `path`. `dart:io` only under `lib/src/store/`, `lib/src/import/` and `lib/src/db/`.
21. `danaview_library_native`, `danaview_pdf`, `danaview_face_tracking`, `danaview_media_analysis`, `danaview_diarization` and `danaview_secure_keys` depend on no `danaview_*` package, and open no sockets (rule 18's grep extended to them). `danaview_face_tracking` loads models only from paths it is given.
22. `danaview_documents` → `danaview_ui_kit`, `danaview_library`, `danaview_pdf`, `danaview_library_native`, `flutter_riverpod`, `characters`. Never `danaview_features`, editor packages, AI packages or `danaview_search`.
23. `danaview_features` may add `danaview_library`, `danaview_library_native`, `danaview_documents`, `danaview_search` and `danaview_ai_ui`. It never imports `danaview_ai_providers`, `danaview_ai_studio`, `danaview_secure_keys`, `danaview_pdf` (only through `danaview_documents`) or any editor package (rule 1 stands). Editor and AI entry points stay callbacks.
24. `danaview_search` is pure Dart: `danaview_library`, `danaview_ai`, `sqlite3`, `meta`, `collection`, `characters`. It reaches Vision/ML Kit and PDF text only through its own ports (`MediaAnalysisPort`, `DocumentTextPort`), implemented at the app root.
25. The photo and beauty code in `danaview_editor_core` keeps the core purity test (no Flutter; `dart:io` only under `lib/src/store/`).
26. **Library writes.** Only `danaview_library/lib/src/store/` and `lib/src/import/` write under the library root; only `danaview_library_native`'s `Inbox` class reads or deletes in the App Group container; no package writes to a URI it didn't create (architecture test on the native wrapper APIs: Save-out calls are create-new only).
27. **Source files are opened read-only.** Import, thumbnail, viewer, PDF tool, still render and tracking code open external sources with read-only modes (`O_RDONLY`, `openFileDescriptor(uri, "r")`, `PDFDocument(url:)` without writing back); PDF tools write only new files in the library or a temporary directory (grep tests in each plugin, INT-101 fixtures).
28. `OpenNetworkConsent.accepted(` only in `packages/danaview_features/lib/src/tools/speed_consent_sheet.dart`; the M-Lab provider refuses to run without a ticket from it.
29. `danaview_editor` reaches the face tracker only through `FaceTrackingPort` (engine API package) and library files only through `MediaAccessPort` (v1.1), both adapted at the app root.
30. No package logs file names, paths, document text, OCR text, labels, landmarks, captions or search queries (v1.1 BP §1 rule 4 extended; grep test with an allow-list).
31. Material chrome ban extended to the new UI files (§1.4).

### 4.3 New packages

| Package | Kind | Owner of skeleton | Layout (top level) |
|---|---|---|---|
| `danaview_library` | pure Dart | INT-101 | `lib/danaview_library.dart`, `lib/testing.dart`, `lib/src/{model,classify,db,store,import,organise,refs}/` |
| `danaview_library_native` | Flutter plugin (iOS, macOS via `darwin/`, Android) | INT-101 (pubspec, barrel); surface HOM-02 | `pigeons/library_api.dart`, `lib/src/pigeon/`, `lib/src/native_*.dart`, `darwin/Classes/{Glue,PhotoLibrary,Pickers,Thumbnails,ExportOut,Share,OpenIn,QuickLook,Inbox}/`, `android/src/main/kotlin/com/vecvel/danaview/library/{glue,photolibrary,pickers,thumbnails,exportout,share,openin,incoming}/`, `android/src/main/AndroidManifest.xml` (FileProvider) |
| `danaview_pdf` | Flutter plugin (iOS, macOS via `darwin/`, Android) | INT-101; surface HOM-24 | `pigeons/pdf_api.dart`, `lib/src/{pdf_document,pdf_view,pdf_tools,pdf_text}.dart`, `darwin/Classes/{Glue,Viewer,Text,Tools,Annotate,Sign,Compress}/`, `android/src/main/kotlin/com/vecvel/danaview/pdf/{glue,viewer,text,tools,annotate,sign,compress}/` |
| `danaview_documents` | Flutter UI | INT-101 | `lib/src/{router,text,card,pdf/{viewer,organiser,annotate,sign,compress},quicklook,signatures}/` |
| `danaview_face_tracking` | Flutter plugin (iOS, Android) | INT-101; surface VED-16 | `pigeons/face_api.dart`, `lib/src/{face_tracker,video_sampler,models}.dart`, `ios/Classes/{Glue,Face,Pose,Segmentation,VideoSampler}/`, `android/src/main/kotlin/com/vecvel/danaview/face/{glue,face,pose,segmentation,videosampler}/` |
| AI packages | per AIS plan §3.1 | AIS-01, AIS-11, AIS-43, AIS-45, AIS-50 | per AIS plan §3.2 as amended by V2-20, V2-24 |

### 4.4 Changed existing packages (who extends what)

| Package | 1.2.0 changes | Tickets |
|---|---|---|
| `danaview_domain` | none (MediaRef stays; `VideoMediaItem` wraps it in `danaview_library`) | — |
| `danaview_data` | `network/speed/` providers, coordinator, health store; `speed_test.dart` becomes a facade | ST-01…ST-03 |
| `danaview_platform` | `incoming_media_bridge.dart` routes documents and photos to the library import; videos still play at once | HOM-21 |
| `danaview_features` | Home shell and tabs, thumbnails, photo viewer, selection bar, file actions, import sheet, search field and screen, settings sections, speed-test consent and UI copy, legal texts, player "Save to Danaview folder" | HOM-05…HOM-22, AIS-51, ST-04, ST-05, AIS-36, INT-106 |
| `danaview_editor_core` | rich cues, schema 2, lanes (AIS); `photo/`, `color/`, `beauty/`, `formats/dnface.dart`, easing, still lowering, beauty lowering, render-range cost (VED) | AIS-02…AIS-47, VED-02…VED-19 |
| `danaview_editor_engine_api` | render prep v2 (AIS-13), font pick kind (AIS-24), still service, landmark and face-track assets, `FaceTrackingPort`, reference passes (VED) | AIS-13, AIS-24, INT-102, VED-03…VED-34 |
| `danaview_editor_engine` | Pigeon v2 amendment and glue (INT-102/102A); `ios/Classes/{Still,Photo,Beauty,StillExport}/`; `android/.../engine/{still,photo,beauty,stillexport}/` | INT-102, INT-102A, VED-03…VED-34A |
| `danaview_editor` | rich subtitle UI, AI flows, speaker lanes (AIS); `editor/photo/` workspace, `panels/beauty/`, compare overlay, launcher intents (VED) | AIS-16…AIS-48, VED-01…VED-28 |
| `danaview_transcription` | words on drafts (AIS-15), `speakers/` (AIS-46) | AIS-15, AIS-46 |
| `danaview_editor_fonts` | Noto families (AIS-22) | AIS-22 |

---

## 5. Data models

### 5.1 Library item model (`danaview_library/lib/src/model/`, HOM-01, HOM-16)

```dart
sealed class MediaItem { String id /*V2-09 namespace*/; String uri; String name; int sizeBytes;
  DateTime modifiedAt; String mimeType; FileKind kind; }
final class VideoMediaItem extends MediaItem { Duration duration; double frameRate; String? codec; bool hasAudio;
  Duration? resumePosition; MediaRef toMediaRef(); }           // the player keeps receiving MediaRef (§1.5)
final class PhotoMediaItem extends MediaItem { int width, height; bool isRaw, isHdr, isLivePhoto;
  int? iso; double? aperture; String? cameraModel; DateTime? takenAt; }
final class DocumentItem extends MediaItem { DocumentKind docKind /*pdf|word|excel|powerpoint|text|other*/;
  int? pageCount; String? textEncoding; }
final class FileEntry {                                         // one row per Danaview folder file (library.db)
  EntryId id /*fe_*/; FolderId folderId /*fd_*/; String displayName; FileKind kind; String? subKind;
  int sizeBytes; DateTime addedAt, modifiedAt; DateTime? lastOpenedAt; bool isFavourite;
  SourceHint sourceHint /*photos|files|openWith|shareExtension|linkedFolder|editorExport|player*/;
  String? quickHash; DateTime? trashedAt, expiresAt; }
enum FileKind { video, photo, document, audio, other /* 1.3.0: savedCode */ }
```

- **Open kind list.** `FileKind` is extended by appending; decoders map unknown kinds to `other` so a 1.2.0 app reading a 1.3.0 library shows them as files (the camera's `savedCode`, NATIVE_CAMERA_PLAN CAM-56).
- **Classifier** (`classify/type_table.dart`): one table of rows `{uti?, mime?, extensions[], kind, docKind}` exactly as HOM plan §8.1, consulted UTType first (Apple), then MIME (Android), then extension; an obviously wrong UTType/MIME (`application/octet-stream`, `public.data`) defers to the extension. One test per row (HOM-16).
- **Saved items** in 1.2.0: favourites (`isFavourite` on entries and folders), saved signatures (V2-29, `danaview_documents/lib/src/signatures/`), subtitle presets (V2-218), photo presets and beauty presets (§5.5). `savedCode` is reserved for 1.3.0.

### 5.2 Storage roots and backup classes

| Data | iOS / macOS | Android | Windows / Linux | Backup | Owner |
|---|---|---|---|---|---|
| Library database + files | `Library/Application Support/DanaviewLibrary/{library.db, files/, imports/}` | `filesDir/library/{…}` | `<appSupport>/DanaviewLibrary/` | **included** (except `imports/*.part`, excluded); Android cloud Auto Backup caps at 25 MB per app, so Settings says device-to-device transfer carries a large library **[VERIFY: HOM-17]** | HOM-17 |
| Search index | `Library/Application Support/DanaviewSearch/search.db` (`isExcludedFromBackup`) | `noBackupFilesDir/search/search.db` | `<appSupport>/DanaviewSearch/` | excluded (rebuildable) | AIS-50 (V2-07) |
| Thumbnails | `Library/Caches/danaview/library/thumbs/` | `cacheDir/library/thumbs/` | `<cache>/danaview/library/thumbs/` | excluded | HOM-04 |
| Share Extension inbox | App Group `group.com.vecvel.danaview/Inbox/` (`manifest.json` + files) | – | – | excluded; emptied on import | HOM-21 |
| Saved signatures | `Application Support/DanaviewLibrary-private/signatures/` (`isExcludedFromBackup`) | `noBackupFilesDir/signatures/` | – | excluded (V2-29) | HOM-30 |
| `.dnphoto` recipes | `<support>/danaview/editor/photos/<photoId>/` | same under the editor root | – | as editor projects (v1.1 ARCH §8.1; Android excluded, D-43(f)) | VED-02 |
| `.dnface` landmark caches | `<cache>/danaview/editor/faces/` | same | – | excluded (regenerable) | VED-17 |
| Beauty pack, speaker models | with the speech models (`<support>/danaview/speech/models/`) | same | – | excluded (v1.1 D-20) | VED-16, AIS-45 |
| Photo and beauty presets | `<support>/danaview/editor/presets/{photo,beauty}_presets.json` | same | – | as editor presets (AIS D-62 file) | VED-12, VED-28 |
| Speed-test prefs | SharedPreferences `speed.mlabConsent`, `speed.skip.<provider>` | same | same | prefs default | ST-03, ST-04 |

On iOS the library is deliberately **not** under `Documents/` (that folder is visible in the Files app because the app sets `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`, P-5; owner 2026-10-16).

### 5.3 `library.db` schema (HOM-17)

```
meta(key TEXT PRIMARY KEY, value TEXT)                                    -- schema_version = 1
folders(id TEXT PRIMARY KEY /*fd_*/, parent_id TEXT NULL REFERENCES folders, name TEXT, created_at INT, modified_at INT,
        is_favourite INT, sort_mode TEXT, sort_desc INT, system_role TEXT NULL /*imported|null*/,
        trashed_at INT NULL, expires_at INT NULL)
entries(id TEXT PRIMARY KEY /*fe_*/, folder_id TEXT REFERENCES folders, display_name TEXT, kind TEXT, sub_kind TEXT,
        mime TEXT, uti TEXT, ext TEXT, size_bytes INT, quick_hash TEXT, content_sha256 TEXT NULL,
        added_at INT, modified_at INT, last_opened_at INT NULL, is_favourite INT, source_hint TEXT,
        trashed_at INT NULL, expires_at INT NULL, trashed_from_folder TEXT NULL)
entry_meta(entry_id TEXT PRIMARY KEY, width INT, height INT, duration_us INT, fps REAL, codec TEXT,
           page_count INT, taken_at INT, camera TEXT, flags INT /*raw|hdr|live*/)
recents(entry_id TEXT PRIMARY KEY, opened_at INT)                         -- capped at 50 by trigger
import_jobs(id TEXT PRIMARY KEY, source_desc TEXT, target_folder TEXT, bytes_total INT, bytes_done INT,
            state TEXT, part_path TEXT, created_at INT)
refs(entry_id TEXT, holder TEXT /*project:<id> | photo:<id>*/, PRIMARY KEY(entry_id, holder))
indexes: entries(folder_id, trashed_at), entries(kind, sub_kind), entries(added_at), entries(display_name COLLATE NOCASE),
         folders(parent_id)
```

- **Writer.** One writer (`store/library_writer.dart`) on a background isolate; WAL mode; every multi-row change (move subtree, delete subtree, restore) is one transaction. Readers use a read-only connection on the UI isolate for paged queries (≤ 2 ms per 200-row page on the mid tier, §10).
- **Migrations.** `db/migrations.dart`, pure, forward-only, tested from every committed fixture; a newer `schema_version` than supported opens read-only with a banner (the v1.1 D-12 rule applied to the library).
- **Invariants** (checked on open and by a property test): no cycles in `folders`; every entry's folder exists (or the entry is trashed with `trashed_from_folder`); `files/<id>/` exists for every live entry (missing → entry marked unavailable, never silently dropped); the `Imported` system folder always exists.
- **Duplicates** (HOM §8.2): same name in one folder → `Name (2).ext` (the `LibraryStorage._uniqueTarget` scheme v1.1 already uses); same `size + sha256` anywhere → ask "keep both or skip".

### 5.4 Folders and Recently deleted

See V2-08. State per row: `live → trashed(expires_at) → purged` or `trashed → live (restore)`. Deleting a folder trashes the subtree in one transaction with the same `expires_at`. Restoring a child of a trashed folder restores it into the nearest live ancestor or `Imported`. Recently deleted is a virtual view (`trashed_at IS NOT NULL`), shown under the Folders tab with "N days left" per row and **Restore** / **Empty now**.

### 5.5 Presets and saved recipes

- Subtitle presets: AIS D-62 (`subtitle_presets.json`).
- **Photo presets** (`photo_presets.json`, VED-12) and **beauty presets** (`beauty_presets.json`, VED-28): `{"format":"danaview.editor.photoPresets"|"…beautyPresets","schema":1,"presets":[…]}`, atomic writes through core `StoreFs`, ≤ 200 each. Applying a preset **copies values** into the recipe or clip and records `presetRef {id, builtIn, revision}` (AIS D-62's rule), so projects never depend on the presets file. Built-in beauty styles ("Natural Glow", "Editorial Chic", "Sunset Warmth", "Clean Beauty") live in code.

### 5.6 Import pipeline and inbox (HOM-20, HOM-21)

```
source (picker result | Open with URI | Share Extension inbox item | linked-folder file | player "Save to Danaview folder")
  └► ImportService.enqueue(source, targetFolder = Imported)        danaview_library (writer isolate)
        ├ open source read-only (rule 27); stat size; quickHash
        ├ duplicate check (name, then size + sha256 streamed during copy)
        ├ copy → imports/<jobId>.part  (progress row; resumable after kill from bytes_done when the source is still readable)
        ├ fsync → rename into files/<entryId>/<displayName> → INSERT entry + entry_meta in one transaction
        └ thumbnail request (HOM-04) ; index request (AIS-50, when enabled)
```

- **Never** move, rename, delete or write the source (rule 27, QA-106 byte-and-timestamp test).
- **iOS Share Extension** (owner 2026-10-16): the extension writes streamed copies plus `manifest.json` (`{items:[{file, uti, name, targetFolderId}], createdAt}`) into the App Group `Inbox/<batchId>/`, never touches `library.db`, and stays under the extension memory limit by streaming. On launch and on every foreground, `InboxImporter` imports each complete batch through the normal path (`sourceHint = shareExtension`) and deletes the batch; an incomplete batch (no manifest) older than 24 h is deleted.
- **Incoming videos** still play at once (P-7, P-8); the player menu gains "Save to Danaview folder" (an import).

### 5.7 `.dnphoto` format (VED-02)

Two-line file like `.dnproj` (v1.1 ARCH §8.2): line 1 header `{"format":"danaview.photo","schema":1,"minReader":1}`, line 2 body. Default values are omitted; unknown keys are kept on round trip; decode clamps and repairs, never refuses (v1.1 ARCH §6.9).

```json
{"id":"ph_7Gq2…","source":{"ref":{"kind":"library","id":"fe_A1b2…"},"quickHash":"a3f5b9…","w":4032,"h":3024,"orient":1,"gamut":"p3"},
 "tone":{"exp":0.35,"con":1.1,"hi":-0.2,"sh":0.15,"wh":0.05,"bl":-0.05,"clar":0.1,"tex":0.0,"dehaze":0.05},
 "color":{"temp":5600,"tint":4.0,"vib":1.15,"sat":1.02},
 "hsl":{"orange":{"h":-2,"s":5,"l":8}},
 "curves":{"rgb":[[0,0],[0.25,0.22],[1,1]],"r":[],"g":[],"b":[]},
 "geom":{"crop":[0.05,0.05,0.9,0.9],"aspect":"4:5","rot90":0,"straighten":-1.2,"keyH":0.0,"keyV":0.08,"flipH":false},
 "masks":[{"id":"mk_…","t":"radial","g":{"cx":0.5,"cy":0.4,"rx":0.3,"ry":0.2,"a":0},"feather":0.4,"inv":false,
           "adj":{"exp":0.3,"temp":-200,"sat":0.1}}],
 "lut":{"id":"teal_and_orange_cinematic","amt":0.8},"fx":{"vig":-0.15,"grain":{"amt":0.08,"size":0.5}},
 "overlays":[/* TextItem / sticker specs, the v1.1 text model */],
 "beauty":{/* BeautyEffectSpec, identical to the clip type (§6.4) */},
 "export":{"fmt":"heic","q":0.9,"maxLong":null,"meta":"keep"}, "presetRef":null}
```

- **`source.ref` kinds:** `library` (Danaview folder entry, V2-09), `media` (a v1.1 managed copy or reference with its `MediaId`, V2-34), never a raw path.
- **Brush masks** store vector strokes (`points`, `radius`, `hardness`, `erase`) and are rasterized deterministically in Dart (Flutter `Picture` → single-channel `.vsprite`, v1.1 D-06) at plan compile time, keyed by content hash.
- **Migrations:** its own `Migrations` chain (empty in 1.2.0), same framework as CORE-23.

### 5.8 `.dnproj` schema 2 (AIS-04 + VED-15 + AIS-47)

One schema for 1.2.0 (V2-03). The s1→s2 step is AIS D-53's (cue markup → spans); everything else is additive and optional:

| Addition | Key (illustrative; AIS-04 and VED-15 pin names in `schema/project.v2.schema.json`) | Owner |
|---|---|---|
| Rich cue fields (spans, emoji marks, override, placement, words, emotion, speaker) | `sp`, `em`, `ov`, `pl`, `w`, `emo`, `spk` | AIS-02, AIS-04 |
| Track additions (speakers, karaoke, direction, speaker display, emotion styles, preset ref) | per AIS D-52 | AIS-02, AIS-04 |
| Speaker lanes | `speakerLane {groupId, speakerId, laneIndex}` on `SubtitleTrackData` | AIS-47 (keys pinned by AIS-04) |
| Photo recipe on image clips | `ph` = the `.dnphoto` body without `id`, `source` and `export` | VED-15 |
| Beauty on visual clips | `bt` = `BeautyEffectSpec` | VED-15 |
| Keyframe easing | `e` on keys: absent = linear, `[x1,y1,x2,y2]` = cubic bezier | VED-19 (key pinned by VED-15) |

`BeautyEffectSpec` (core `model/beauty.dart`, VED-15):

```dart
final class BeautyEffectSpec { double masterIntensity /*0..1*/; Smoothing temporalSmoothing /*low|medium|high*/;
  BeautyBypass bypass /*master + per category*/; List<BeautySubject> subjects /*≤ 4*/; BodySpec? body; PortraitFx? fx; }
final class BeautySubject { int subjectId /*0..3, stable per clip*/; FaceSignature? signature /*for re-identification*/;
  Map<BeautyParamId, double> params; MakeupSpec? makeup; }
enum BeautyCategory { faceShape, eyesBrows, noseLips, skin, makeup, body, filters, tracking }
// BeautyParamId: one enum value per slider of VED plan §5.1–§5.7 (≈ 70), each with range, default 0 and its category.
// Keyframes: property keys 'beauty.<subjectId>.<paramId>' and 'beauty.master' in the clip's KeyframeSet.
```

Opening a 1.1 project: v1.1 CORE-23 framework, one toast (AIS D-53). Opening a 1.2.0 project in 1.1.x: `readOnlyNewer` (D-12); the 1.1.x decoder keeps unknown keys **[VERIFY: AIS-04 tests 1.1.x decode of `ph`, `bt`, `e` fixtures]**.

### 5.9 `.dnface` landmark cache (VED-17)

Binary, little-endian, zlib-compressed body (the `.vsprite` container style): header `'DNFC'`, u16 version 1, u16 topology (1 = face 478, 2 = pose 33), media `quickHash`, source range (µs), sample stride (µs), u8 subject count; per sample: source PTS (µs, i64), per subject `{present u8, confidence u8, bbox 4×f16, points N×3×f16 normalized}`. Raw landmarks only (V2-15). Key: `sha1(quickHash, range, stride, topology, modelRevision)`. Smoothed tracks for plans are separate content-addressed assets (`<cache>/danaview/editor/faces/smoothed/<hash>.dnface`) produced by core from raw + `temporalSmoothing`.

### 5.10 Search index (`search.db`, AIS-50)

```
meta(key, value)                                   -- schema_version, model revisions, last full rebuild
docs(item_id TEXT PRIMARY KEY /*fe_|lk:|ph:|ms:*/, kind TEXT, folder_id TEXT, added_at INT, taken_at INT,
     size_bytes INT, width INT, height INT, duration_us INT, state TEXT /*pending|done|failed*/, extractor_rev INT)
fts USING fts5(item_id UNINDEXED, name, folder_names, labels, ocr_text, doc_text, captions, transcript,
               tokenize = 'unicode61 remove_diacritics 2')        -- trigram for CJK per [VERIFY: AIS-50]
labels(item_id, label, confidence)                                -- for the AI filters' local label match (V2-234)
deep(item_id TEXT PRIMARY KEY, folder_id, provider, model, description TEXT, embedding BLOB /*f16*/, dims INT, at INT)
```

- Rebuildable from `library.db` + sources at any time; excluded from backups (V2-07); "Rebuild index" and "Delete index" in Settings (INT-103).
- Deleting or trashing a library item removes its `docs`, `fts`, `labels` and `deep` rows in the same index batch; "Remove deep index" deletes a folder's `deep` rows.
- Vector search is brute-force cosine over `deep.embedding` (fast enough below 100,000 items, AIS §7.8).

---

## 6. Editor architecture changes

### 6.1 Intent routing (VED-01) and the timeline bridge (VED-14)

`EditorLauncher` (v1.1 UX-41) gains typed intents: `openPhoto(PhotoSource)`, `openPhotoBatch(List<PhotoSource>)`, `newMontage(List<LibraryMediaRef>)`, `openProject(ProjectId)`, `editAtPosition(...)` (v1.1). `openPhoto` opens `DanaviewEditorScreen` in **Still mode** (`editor/photo/photo_editor_screen.dart`); everything else opens the v1.1 timeline. Still mode hides timeline-only tools; timeline mode hides photo-only tools (D-130).

**"Add to Video Project"** (D-128) creates (or appends to the chosen) project an **image clip carrying the recipe** (`ph`) and beauty (`bt`) on V1, duration 3.0 s on the grid, with an optional Ken Burns preset as two keyframed transform keys (eased, V2-16). The recipe stays editable in the clip inspector; nothing is baked (VED G-U2). Montages (HOM-12) lay out photos as 3 s stills and videos in chronological order on V1 through the same command (`AddMediaSequence`, VED-14).

### 6.2 Photo pipeline and normative effect order

**Order** (merges v1.1 D-08, VED D-131 and VED §3.3; applies to stills and to every visual clip):

1. **Source sampling:** crop rect → 90° rotation → straighten → **keystone homography** (source space).
2. **Chroma key + spill** (v1.1).
3. **Beauty geometry:** face mesh warp (face shape, eyes, nose, lips) → body warp (pose-pinned).
4. **Beauty surface:** skin (smoothing, blemish, dark spots, tone, anti-shine, wrinkles, glow, teeth) → makeup (foundation, concealer, blush, contour, lips, eye makeup, lenses, freckles) → hair colour (segmentation).
5. **Grade (v1.1):** exposure → brightness/contrast → highlights/shadows (v1.1 global form, video clips only) → saturation → temperature/tint.
6. **Tone v2 (spatial, stills and clips with a recipe):** local highlights/shadows recovery, clarity, texture, dehaze, all from one low-pass base (separable blur at ¼ resolution, radius per tier).
7. **Recipe LUT** (baked in Dart, V2-11): whites, blacks, extended temperature/tint, vibrance, HSL mixer, curves.
8. **User LUT** (`.vlut`, v1.1) with amount.
9. **Local adjustments** (masks): per mask, its own exposure, contrast, warmth, saturation, sharpness, blended by the mask (linear, radial, luminance, brush sprite).
10. **Blur → sharpen → vignette (v1.1) → grain** (seeded, deterministic per pixel coordinate and frame).
11. **Portrait bokeh** (segmentation, V2-17).
12. **Layer mask → place** (transform, flip, opacity) → canvas masks → premultiplied source-over (v1.1).

Face-anchored stickers and text are sprite layers placed above (v1.1 text path; stickers anchored by lowering from the smoothed landmark track).

**Still preview.** `StillPreviewSession` (engine API, INT-102): the viewport requests tiles at the current zoom's mip level; sliders send param patches (v1.1 patch path) that re-render only visible tiles. 60 fps interaction target (§10). The Dart reference renderer implements every new pass at low resolution for goldens (API-03 method).

**Still export.** `StillExportService.export(plan, StillEncodeSettings{format jpeg|png|webp|heic, quality, maxLongSide, colorTag, metadata keep|strip|stripGps})`: tiled render (V2-18), encode from tiles, write to a temporary file, then save to the library (new entry, `sourceHint = editorExport`), to Photos/MediaStore (add-only), or both. Batch export runs as a background job queue with progress and cancel (VED-12).

### 6.3 RenderPlan v2 (INT-102)

Additive to v1.1 ARCH §11.2; `v = 2`; a v2 plan without the new fields is byte-identical to its v1 form except `v` (contract fixture). Validators (Dart, Swift, Kotlin) accept both.

| Addition | Shape | Used by |
|---|---|---|
| `canvas.still` | `{w, h, tile?}` one-frame plans for stills | VED-03 |
| `layer.src.homography` | 3×3 row-major, source-normalized | VED-09 |
| `layer.look.recipeLut` | asset id (`lut` kind, generated) | VED-07, VED-08 |
| `layer.look.tone2` | `{hi, sh, clar, tex, dehaze, baseRadius}` | VED-06 |
| `layer.local[]` | `{mask: {linear|radial|luma|sprite}, feather, invert, adj{exp, con, temp, sat, sharp}}` | VED-10 |
| `layer.fx.grain` | `{amt, size, seed}` | VED-06 |
| `layer.beauty` | `{faces: assetId (smoothed .dnface), pose?: assetId, subjects: [{id, params: {paramId: value | channelRef}}], passes: bitmask, quality: full|half}` | VED-15, VED-20…VED-25 |
| `layer.portrait` | `{bokeh?: {aperture, blades}, hair?: {color, amount}}` (segmentation at render time) | VED-24, VED-34 |
| assets | new kinds `faces` (`.dnface`), `mask` (`.vsprite` alpha) | VED-10, VED-17 |
| channels | beauty params animate through v1.1 `channels` (linear keys, eased in lowering, V2-16) | VED-19 |

**Engine interface additions** (Pigeon amendment, INT-102/102A): `StillHostApi` (`openStill`, `renderTiles`, `applyPatch`, `close`), `JobKindMsg.exportStill`, `EditorCapabilities.{stillMaxPixels, halfFloatTargets, beautyTier, segmentationAvailable}`, `FaceTrackingPort` (Dart interface in engine API, implemented at the app root over `danaview_face_tracking`). Native pass registries (`PhotoPassRegistry`, `BeautyPassRegistry`) are created by INT-102 in `ios/Classes/{Photo,Beauty}/Registry.swift` and `android/.../engine/{photo,beauty}/Registry.kt` and called from the v1.1 `LayerRenderer.swift` / `LayerEffectChainFactory.kt` hook points INT-102 adds; VED tickets register their passes in their own files.

### 6.4 Beauty pipeline

```
media + range ─► FaceTrackingPort.trackVideo(stride = 1 frame of the source, analysis ≤ 720p) ─► raw .dnface (VED-17, background isolate + native)
             └─► (stills) trackImage(full res, ≤ 4 faces)
raw .dnface + Smoothing ─► OneEuro (core, V2-15) + occlusion fade (3 frames) ─► smoothed track asset
subjects: FaceSignature (embedding of landmark geometry ratios) matches faces across frames ─► subjectId 0..3 (VED-18)
BeautyEffectSpec (+ keyframes, eased) ─► lowering_beauty (core) ─► layer.beauty in RenderPlan v2
engine: per frame, interpolate smoothed landmarks at the source PTS ─► build warp mesh ─► passes (registry order of §6.2 steps 3–4)
```

- **One-Euro parameters** per `temporalSmoothing`: low `{minCutoff 2.0, beta 0.02}`, medium `{1.0, 0.007}`, high `{0.5, 0.003}`, `dCutoff 1.0` **[VERIFY: VED-16 jitter metric]**; committed vectors in `test/fixtures/vectors/one_euro.json` for the 1.3.0 camera.
- **Warps** are mesh deformations of the canonical topology with per-parameter displacement fields (normalized to inter-ocular distance), clamped so no triangle flips; the background outside the face hull and the body silhouette is pinned (D-138).
- **Tiers and proxies** (D-142): `beautyTier` full on mid/high; low tier renders beauty passes at half resolution during playback and full on pause and export; minimal tier: stills only, video beauty hidden. Ranges with beauty count as **heavy** in the v1.1 render-preview cache (D-45), so playback uses pre-rendered ranges on weak devices.
- **Bypass** (D-144): master and per-category bypass are plan-level (passes bitmask), so A/B costs no re-track.
- **Compare** (D-140): a preview transient (v1.1 CORE-32 transients) duplicates the layer without beauty and photo passes under a canvas mask at the divider; press-and-hold sets the bypass bitmask to all.

### 6.5 Rich subtitles and speaker lanes

As the AIS plan §3.4 and §7.4: rich text and karaoke render through Flutter's `TextLayoutEngine` for preview and sprites, with no plan or engine change (V2-224). Lanes are one subtitle track per speaker in a group; concurrent lanes stack by line height (or fixed slots, AIS-47 decides). They are independent of RenderPlan v2.

