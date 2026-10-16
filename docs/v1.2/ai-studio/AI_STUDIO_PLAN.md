# Danaview 1.2.0: AI Studio and advanced subtitles

> **Release:** Danaview 1.2.0 (app version `1.2.0+N`; 1.1.x stays for editor bug fixes). **Date:** 2026-10-11. **Status:** proposal, written while the v1 editor (Danaview 1.1.0) is being built on `editor-wip`.
> **Baseline:** `docs/v1.1/editor/ARCHITECTURE.md` (decisions D-01 to D-44, "ARCH") and `docs/v1.1/editor/BUILD_PLAN.md` (158 tickets M0–M6, "BP"), plus the area designs in `docs/v1.1/editor/design/` (`domain.md`, `native.md`, `ux.md`, `ai.md`) and the code on `editor-wip`. ARCH stays the source of truth for v1 behaviour. This plan proposes decisions **D-45 to D-70**, plus **D-70a to D-70i** (added 2026-10-16, §7). AIS-01 records them in ARCH (an [INTEGRATION] change) once the owner has confirmed the ones marked **[OWNER]**.
> **Release placement (2026-10-15):** 1.2.0 also ships the Files & Media Home (`docs/v1.2/files-media-home/FILES_MEDIA_HOME_PLAN.md`) and the Unified Photo & Video Editor (`docs/v1.2/video-editor-update/VIDEO_EDITOR_UPDATE_PLAN.md`); the desktop editor and the native camera moved to 1.3.0. AIS-04's schema 2 comes first; the photo/video editor's schema 3 (VED-15) builds on it. **Decision-number clash:** v1.1 ARCHITECTURE now has its own D-45 (render-preview cache, added 2026-10-11), so this plan's D-45…D-70 (and D-70a…D-70i) must be renumbered when AIS-01 records them in ARCH.
> **Widened on 2026-10-16 (owner):** four additions, written up in §7 and folded into the tables of §1–§6: (1) **multi-speaker transcription with overlapping speech**, using on-device speaker diarization after whisper and per-speaker subtitle lanes (this replaces D-59's "no on-device diarization"); (2) **AI search over the Files & Media Home**, on-device by default with two opt-in AI Studio levels; (3) a **shared `danaview_ai` layer** used by the editor, search and later the camera and documents, behind the one AI Studio switch; (4) the first provider ticket is a **Genkit Dart spike** (AIS-42) that decides whether the provider adapters are built on Genkit or stay custom. New decisions are lettered **D-70a to D-70i** so the numbers of the other 1.2.0 plans are untouched; new tickets are **AIS-42 to AIS-54**. The privacy model (D-45: Send consent, a disclosure that equals the payload, the network guard, keys only to their own provider) applies to every addition unchanged.
> **Scope:** 1.2.0 work starts after the v1 release ticket INT-05 lands. Every v1 ticket listed under "Depends on" is therefore already merged when its 1.2.0 dependant starts.
> **Notation:** "ARCH §11.2" points into ARCHITECTURE.md and "BP §6" into BUILD_PLAN.md. **[OWNER]** marks a decision the owner must confirm. **[VERIFY]** marks a claim to check during implementation; the ticket that closes each one is listed in §6.3. "Extends CORE-15" means the ticket edits a file that v1 ticket CORE-15 created (§5.1 rule 2).

---

## 0. Contents

1. Summary, goals, non-goals, and what v1 already provides
2. Product decisions D-45 to D-70 (plus D-70a to D-70i, added 2026-10-16)
3. Architecture
4. UX
5. Tickets (process, milestones, index, tickets, file register, feature coverage)
6. Risks, open questions, [VERIFY] register, privacy policy and terms changes, effort, owner confirmations
7. Additions of 2026-10-16: multi-speaker transcription, AI search, shared AI layer, Genkit spike (tickets AIS-42 to AIS-54)

---

## 1. Summary, goals and non-goals

### 1.1 Summary

Danaview 1.2.0 adds two things to the v1 editor:

1. **Advanced subtitles, entirely on device.** Users can style any range of a caption (even one word) as rich text. Each line can have its own placement and its own style overrides. Captions can highlight word by word (karaoke) using the word timings whisper already produces. There is a transcript view for editing captions in place, plus timing tools, emoji tools, more bundled fonts (Indic, Arabic, Hebrew, Thai), imported fonts, and subtitle style presets. None of this uses the network.
2. **AI Studio, which is optional and off by default.** The user brings their own API key for Google Gemini, OpenAI, Anthropic Claude, OpenRouter or xAI Grok. AI Studio can clean up transcripts, detect emotion and tone (from the text, or from the voice with audio-capable models), add emojis, label speakers, translate a subtitle track into a new track, and run "Ask AI" on a selection. Every result comes back as a suggestion. The user reviews it and accepts or rejects it, and undo always works. Nothing is sent unless the user starts an action and taps **Send** after seeing what will be sent.

When AI Studio is off (the default), the editor works exactly as in v1: on device and offline.

**Added 2026-10-16** (details in §7):

3. **Multi-speaker transcription, on device.** After whisper, an optional on-device diarization pass (sherpa-onnx with pyannote segmentation 3.0 and a speaker-embedding model, downloaded once after consent) finds who speaks when, including overlapping speech. Words are assigned to speakers from whisper's word timestamps, and overlapping speech becomes separate cues on **per-speaker subtitle lanes** with exact timestamps, each lane with its own style and a renamable speaker. With AI Studio on, cloud diarization (for example Gemini listening to the audio) is an optional alternative behind Send.
4. **AI search over the Files & Media Home.** An on-device index (image labels and text in photos through Apple Vision / ML Kit, document text, captions, transcripts, metadata) makes the whole library searchable with no network. With AI Studio on, two opt-in levels: **query to filters** (only the typed question is sent; the model returns structured filters that run over the local index) and **deep indexing**, chosen per folder, which sends content for descriptions or embeddings behind Send with a token estimate.
5. **One shared AI layer** (`danaview_ai`) for the editor, search and, later, the camera and documents, all behind the single AI Studio switch.

### 1.2 Goals

| # | Goal | Where it is guaranteed |
|---|---|---|
| G-S1 | With AI Studio off, 1.2.0 makes **no network requests** beyond v1's (the speech model download after consent) | D-45, D-65; `ai_network_guard_test.dart` (AIS-37) |
| G-S2 | **Nothing leaves the device without an explicit Send** on a disclosure that lists exactly what is sent (provider, host, model, counts, bytes, estimated tokens, audio length) | D-45, D-51; `AiSendConsent` call-site test (AIS-01), payload hash check (AIS-08) |
| G-S3 | **Model output never changes the project directly.** Every result is a suggestion, accepted or rejected in review, and accepting creates normal undoable commands | D-51, D-64; AIS-28, AIS-33 |
| G-S4 | Keys are kept in the iOS Keychain or behind an Android Keystore key, are never in backups, logs, URLs or project files, and are sent only to their own provider | D-46, D-47; AIS-11, AIS-08 |
| G-S5 | Rich-text captions, karaoke, per-line placement, RTL and complex scripts look the same in the preview and in the burned-in export on a given device | D-52, D-56, D-68; AIS-12 … AIS-16, AIS-39 |
| G-S6 | Opening a v1 project upgrades it losslessly. A 1.1.x app opens 1.2.0 projects read-only instead of misreading them | D-53; AIS-04 |
| G-S7 | v1's standing UI rules hold on every new surface: custom components, Figtree chrome, no overflow at 280–1280 px and text scale 0.85–1.35, touch targets ≥ 44 px, computed contrast, accessibility | ARCH §1.3, §17.9; AIS-38 |
| G-S8 | No engine or RenderPlan schema change is needed for rich text or karaoke. Native code changes only for the font picker | D-68; AIS-14, AIS-24 |
| G-S9 | **Diarization is on device.** With AI Studio off, speaker detection makes no network request beyond the one-time model download after consent; overlapping speech is never merged into one cue | D-70c, D-70e, D-70f; AIS-44…AIS-48, AIS-54 |
| G-S10 | **Search is on device by default.** The search index never leaves the device. AI search sends only the typed question (level a) unless the user turns on deep indexing for a folder and taps Send (level b) | D-70d, D-70h, D-70i; AIS-50…AIS-53, AIS-54 |
| G-S11 | **One switch, one consent model** for every AI feature in the app (editor, search, later camera and documents) | D-70a; AIS-43 |

### 1.3 Non-goals for 1.2.0

- On-device language models and on-device translation. (On-device speaker diarization was a non-goal until 2026-10-16; it is now in scope, D-70c.)
- Any AI over video pictures in the editor (scene detection, auto-edit, summaries), dubbing or text-to-speech. Search's deep indexing (D-70i) may send photo thumbnails and video keyframes from a folder the user chose; that is the only exception.
- A vecvel-run backend, proxy, account, key sharing or billing. Keys belong to the user's own provider accounts (D-49).
- Custom or self-hosted endpoints (Ollama, Azure OpenAI, Vertex, Bedrock). OpenRouter covers other models (D-66).
- Streaming responses in the UI (the capability flag exists but is unused, D-48).
- Rich-text styling of **text overlays** (`TextItem`). 1.2.0 covers subtitle cues only. Text items keep their whole-item `TextStyleSpec`.
- Karaoke that highlights only the current word (it needs non-cumulative reveal, D-68). 1.2.0 ships "progressive" and "fill".
- Live sync of translated tracks with later edits to the source track. Re-translating is a new action.
- WOFF/WOFF2/TTC font import, variable-font axis controls, and font sync across devices.
- Desktop. AI Studio, like the editor, is iOS and Android only (ARCH D-17). The on-device search index (D-70d) also runs on macOS; Windows and Linux get name search only in 1.2.0.
- Tools, agents, sessions and MCP from Genkit (D-70b): not used in 1.2.0 even if Genkit is adopted.

### 1.4 What v1 already provides (verified in docs and code)

| v1 area | What exists (file, ticket, section) | What 1.2.0 needs on top |
|---|---|---|
| Subtitle model | `SubtitleCue {text, origin, editedAfterGeneration}` with `\n` breaks and inline `<i>`/`<b>` only (`packages/danaview_editor_core/lib/src/model/items.dart`, CORE-03, ARCH §6.3). `SubtitleTrackData {language, style, position, burnIn, provenance}`, `SubtitleStyle` (font, size, bold/italic, colour, box, outline, shadow, maxLines 1..3, maxWidth, align), `SubtitlePosition` sealed `bottom \| top \| custom(yFraction)`, `CaptionProvenance` (whisper fields, schema 1), `SubtitleCueDraft(range, text)` (`model/subtitle.dart`, CORE-03, ARCH §6.6) | Style spans over grapheme ranges, cue-level overrides and placement, word timings, emotion, speakers, translation provenance (D-52, D-53) |
| Subtitle commands | `AddCue, SetCueText, SetCueRange, SplitCue, MergeCues, DeleteCues, ShiftCues, ImportSubtitles, SetSubtitleStyle/Position/BurnIn/Language, AddGeneratedCaptionTrack, ReplaceGeneratedCaptions` (`ops/commands/{subtitle,caption}_commands.dart`, CORE-15, ARCH §7.2) | Span-aware versions plus new style, placement, batch-AI, derived-track and emoji commands (AIS-05, AIS-06) |
| Text layout spec | `TextLayoutSpec` with `TextRun(text, bold, italic)` runs; `parseCueMarkup` turns `<b>/<i>` into runs; `cueLayoutSpecOf(cue, track, canvas)`; `resolveTextDirection` (first strong character); `textGraphemeCount` via `package:characters` (`eval/text_layout_spec.dart`, CORE-07) | Runs carrying full style overrides, placement, karaoke variants (AIS-12) |
| Text rendering path | **Preview and export are both rendered by Flutter** (checked): D-05 draws preview text with a Flutter overlay (`TextOverlayLayer`, UX-19, `previewTextEngineProvider`), and D-06 rasterizes export sprites with the same `TextLayoutEngine` (`packages/danaview_editor_engine_api/lib/src/render_prep/text_layout_engine.dart`, API-04: "preview overlay, manipulation handles and export sprites all lay out a core `TextLayoutSpec` here with `ui.Paragraph`"). ai.md §10.4 still says export uses CoreText or a native overlay; ARCH D-05/D-06 supersede that. V-A11 was measured in API-04: Figtree has no Greek, Cyrillic, Hebrew, Arabic, Devanagari, Thai, CJK or emoji, so those use Flutter's per-character system fallback in both paths, and `TextLayoutEngine.fallbackFamilies` already exists | Per-run styles, decorations, highlight, per-run outline and shadow, karaoke highlight sprite, bundled script fallbacks (AIS-13) |
| RenderPlan and sprites | Cues lower to export-only sprite layers `<cueId>#c` placed by `cueCenter` from the track position (`plan/lowering_text.dart`, CORE-31). `.vsprite` v1 holds premultiplied RGBA plus an optional u16 glyph-order map, and the `reveal` channel draws glyph `< floor(reveal(t))` (ARCH §10.3, §11.6). Sprite key = `sha1(TextLayoutSpec JSON, scale, canvas, fontsVersion)` with `contentFontsVersion = 1` (`plan/sprite_requests.dart`). `ZOrder.of` allows `sub` −5…5 (`plan/z_order.dart`). Preview plans have no text layers (D-05) | Karaoke as a second sprite layer with a `reveal` channel at `sub` +1, so the plan schema and engines stay unchanged (D-68, AIS-14) |
| AI pipeline | Whisper words in **source µs** (`TranscriptWord`, AI-10) are cached under `<support>/danaview/speech/transcripts/` with a 64 MiB LRU, backup-excluded (D-20). `WordMapper` maps words to the timeline through `ClipTimeMap` (AI-12). `DpCaptionSegmenter` turns `TimedWord`s into `SubtitleCueDraft(range, text)`, **dropping word timings** (AI-11). `AddGeneratedCaptionTrack` carries `CaptionProvenance` (AI-13, CORE-15). Speech audio comes from `MediaJobs.extractSpeechAudio(SpeechAudioJobRequest(media, range, outputPath, audioStream))` as a 16 kHz s16 mono WAV (ARCH §12.3, D-28) | Persist word timings on cues (D-69, AIS-15). Reuse extraction for voice-tone clips (D-50) |
| Consent model | `ConsentDisclosure.of(spec)` is exactly what the view shows; `UserConsent.accepted(` is allowed only in `model_consent_view.dart` (ARCH §4.2 rule 8, §16.3, §20.2). Consent is never remembered, and the downloader re-checks the disclosure | The same pattern for sends (`AiSendConsent`) and for key checks (`ProviderProbeConsent`) (D-45) |
| Privacy | "Danaview keeps everything on your device…"; every editor bullet in `legal_texts.dart` starts "On iPhone, iPad and Android"; the speech model is the only extra download; INT-04's `HttpOverrides` spy proves zero network before consent (ARCH §20.3) | New disclosures, an "AI Studio with your own key" entry, and a network guard for AI (§6.4, AIS-36, AIS-37) |
| Project codec and migrations | Two-line `.dnproj` with `schema` and `minReader` in the header; header-only classification (D-12); `Migrations.chain` of pure, idempotent raw-JSON steps with an **empty production chain** and a test-only s0→s1 step; pre-migration backup on first save; `currentProjectSchema = 1`, `currentProjectMinReader = 1` (`codec/schema_version.dart`, `codec/migrations/migrations.dart`, CORE-22, CORE-23, ARCH §8.5) | The first production step, s1→s2 (D-53, AIS-04) |
| Font catalog | 10 OFL families bundled in `packages/danaview_editor_fonts` for user content only. `FontCatalog` maps ids to families and supplies the `FontResolver`. Unknown ids fall back to Figtree (ARCH §17.8, D-30, UX-30) | More bundled scripts, imported fonts, search, favourites and live preview (D-60, D-61, AIS-22 … AIS-25) |
| Undo and history | Snapshot history of the `Timeline` root, 200 entries or about 48 MB, not persisted; transactions add one entry; coalescing keys (ARCH §7.3, CORE-19); every mutation goes through `EditorController.apply` (ARCH §17.3, UX-08) | Accepting a suggestion is a command, so undo comes for free. Pending suggestions live outside history (D-64) |
| Action registry, inspector, tools | `EditorActionId` enum (complete v1 list, ARCH §17.6) in `contracts/action_ids.dart` (UX-01). Handlers live in per-feature `actions/bindings/<feature>_bindings.dart`, merged by `wiring/action_bindings.dart`. Inspector routes are in `contracts/inspector_routes.dart`, with `SubtitlesInspector(track, cue, section)` and `SubtitlesPanelSection {cues, style, position}`. Tool strip, inspector host and dock are UX-16; the subtitles panel is UX-31; SRT/VTT UI is UX-32; export sheet is UX-39 | New action ids, panel sections and binding files (AIS-01), plus panels and flows (S2–S4) |

**State of v1 at the time of writing (2026-10-11, `editor-wip`).** Several v1 UX files are still D-33 placeholders: `editor/text/font_catalog.dart`, `editor/panels/{font_picker,text_panel,subtitles_panel}.dart`, `editor/flows/captions/model_consent_view.dart`, and the `danaview_editor_fonts` package. Core, engine API, render prep and transcription code exist. 1.2.0 starts after INT-05, so the dependencies above will be real by then. Where this plan describes a v1 type, it follows the code on `editor-wip`, which matches ARCH.

---

## 2. Product decisions (D-45 to D-70)

Each decision lists options, a recommendation and its consequences. **[OWNER]** = the owner must confirm. Until then the recommendation is the working default, the same convention as ARCH D-43.

| ID | Decision (short) | Owner? |
|---|---|---|
| D-45 | Privacy model: master switch off by default, per-provider opt-in, a disclosure and Send for every action, nothing automatic | **[OWNER]** |
| D-46 | Keys in a small first-party plugin `danaview_secure_keys` (Keychain / Keystore-wrapped, no backups) | – |
| D-47 | HTTP: pure `dart:io` `HttpClient` adapters, no vendor SDKs, host allow-list, keys in headers only | – |
| D-48 | One `LlmProvider` interface with capability flags, curated and live model lists, timeouts, retries, rate limits | – |
| D-49 | Usage: token estimate before sending, recorded usage after; no prices and no billing in the app | **[OWNER]** |
| D-50 | Voice-tone audio: reuse v1 speech extraction, 16 kHz mono WAV clips, size caps, audio providers only | **[OWNER]** |
| D-51 | Strict JSON contract per action, local validation, local repair only, reject otherwise, review always | – |
| D-52 | Rich text: span runs over grapheme ranges plus cue-level overrides and placement | – |
| D-53 | Project schema 2 (`minReader` stays 1), first production migration s1→s2 | – |
| D-54 | SRT/VTT mapping of styles, speakers, karaoke timings and RTL marks | – |
| D-55 | Emoji: grapheme-based handling, system emoji font, Emoji ≤ 12.0 allow-list for AI-inserted emoji | **[OWNER]** |
| D-56 | RTL and complex scripts: auto direction plus per-track override, bundled Noto fallbacks, script rules | – |
| D-57 | Translation: new track, sentence-group translation, proportional re-timing, AI-11 re-segmentation | – |
| D-58 | Emotion taxonomy: 10 labels, intensity, confidence, source; fixed emoji and style mapping | **[OWNER]** |
| D-59 | Speaker labels: manual, on-device diarization (D-70c), or AI-suggested (audio-capable models preferred). **Updated 2026-10-16** | owner 2026-10-16 |
| D-60 | Bundled fonts: about 8 MB of non-CJK Noto; CJK uses system fonts; downloadable font packs only if the owner asks | **[OWNER]** |
| D-61 | Font import: .ttf/.otf, validated, app-level library, project references, rights reminder | **[OWNER]** (reminder text) |
| D-62 | Presets: built-ins in code, user presets in one app-level JSON file, tracks copy the values | – |
| D-63 | App Store and Play: disclosures, privacy labels / Data safety, review access, AI-content reporting | **[OWNER]** |
| D-64 | Suggestions: outside history, stored in a project sidecar, stale detection, accept = command | – |
| D-65 | Gating: compile-time `DANAVIEW_AI_STUDIO` plus a runtime master switch. Rich subtitles ship without a flag | – |
| D-66 | Endpoints: exactly five provider hosts, no custom base URL; a loopback override for debug and tests only | **[OWNER]** |
| D-67 | Ask AI free-text: edits only the selected text of the selected cues; output shown as a diff | – |
| D-68 | Karaoke rendered with the existing sprite `reveal` channel; no plan or engine change | – |
| D-69 | Word timings stored on cues (generated, imported VTT, estimated) | – |
| D-70 | 1.2.0 process: "extends" ownership of v1 files, skeleton placeholders, integration register | – |
| D-70a | Shared `danaview_ai` layer for the editor, search and later the camera and documents; one app-level AI Studio switch (§7.1) | owner 2026-10-16 |
| D-70b | Genkit Dart spike first (AIS-42); Genkit behind our `LlmProvider` interface only if our transport stays in control, else the custom adapters of AIS-08…AIS-10 (§7.2) | owner 2026-10-16 |
| D-70c | On-device speaker diarization after whisper: sherpa-onnx, pyannote segmentation 3.0, a speaker-embedding model, downloaded once after consent (§7.3) | owner 2026-10-16; models and app size **[VERIFY]** / **[OWNER]** |
| D-70d | On-device search index over the Files & Media Home: image labels, text in images, document text, captions, transcripts, metadata (§7.6) | owner 2026-10-16 |
| D-70e | Word-to-speaker assignment from whisper word timestamps; overlapping speech produces one cue per speaker, never a merged cue (§7.3) | owner 2026-10-16; overlap text **[OWNER]** |
| D-70f | Per-speaker subtitle lanes: one subtitle track per speaker in a speaker group, per-speaker style, renamable speakers, export rules (§7.4) | owner 2026-10-16 |
| D-70g | Optional cloud diarization when AI Studio is on (for example Gemini audio), behind Send (§7.5) | owner 2026-10-16 |
| D-70h | AI search level (a), query to filters: only the typed question is sent; the model returns structured filters run over the local index (§7.7) | owner 2026-10-16; Send per question **[OWNER]** |
| D-70i | AI search level (b), deep indexing: explicit per folder, content sent for descriptions or embeddings, behind Send with a token estimate (§7.8) | owner 2026-10-16; video keyframes **[OWNER]** |

### D-45 · Privacy model **[OWNER]**

**Options.** (a) A master switch, per-provider opt-in, and a disclosure plus Send for every action. (b) One consent when AI Studio is turned on, after which actions send freely. (c) One consent per editing session.

**Recommendation: (a).**
- **Master switch.** Settings › Video editor › AI Studio, **off by default**. While off, no AI entry point is shown, no provider object is built, and no AI code path can open a socket. `aiStudioProvider` returns `AiStudioOff`, and AIS-37's test asserts zero requests.
- **Per-provider opt-in.** A provider is usable only after the user enters its key in that provider's sheet. The sheet says who the provider is, which host Danaview contacts, that the provider's terms and data policy apply (and that some free tiers may use requests to improve models), and that the key stays on this device.
- **Per-action disclosure.** Every action that sends project content shows a "What will be sent" block inside its sheet, built from the exact prepared request bodies (§3.8):
  - the provider, host and model;
  - the number of caption lines and characters, and the estimated input tokens plus an output cap;
  - for voice actions, the number of audio clips, their total length and bytes;
  - what is never sent: video pictures, file names and paths, project name, profile, device identifiers.

  Only the **Send** button sends. **Test key** and **Load models** send no project content and carry a one-line disclosure of their own.
- **Nothing automatic.** Auto captions, import, open and resume never start an AI action. A job interrupted by an app kill is never resumed without a new disclosure and Send. Failed batches are retried automatically only inside the running job, with identical bytes (D-51).
- **Enforcement** mirrors ARCH §4.2 rule 8. `AiSendConsent.accepted(` may appear only in `packages/danaview_editor/lib/src/editor/flows/ai/ai_send_view.dart`, and `ProviderProbeConsent.accepted(` only in `packages/danaview_editor/lib/src/settings/ai/provider_sheet.dart` (architecture tests, AIS-01). The transport refuses any body whose SHA-256 is not in the consent's list (AIS-08).
- **Logging.** Keys, caption text, prompts, responses and audio are never logged (grep test, AIS-08).
- **Policy text.** See §6.4: summary, storage, "When Danaview uses the internet", terms.

**Consequence.** The UI has one more step per action. That is the price of "exactly what is sent", and it is also what App Store guideline 5.1.2(i) appears to ask for (D-63).

### D-46 · Key storage

**Options.**
- (a) `flutter_secure_storage` from pub.dev. Mature, but on Android it stores ciphertext in a SharedPreferences file that Auto Backup copies. After a restore, that file can no longer be decrypted unless the backup rules are edited. Its Android cipher implementation has also changed across major versions [VERIFY current version behaviour].
- (b) A first-party Pigeon plugin, `packages/danaview_secure_keys`.
- (c) SharedPreferences encrypted in Dart. Rejected: there is no hardware-backed key.

**Recommendation: (b), a platform channel.**
- **iOS.** `kSecClassGenericPassword`, service `com.vecvel.danaview.ai`, account = provider id, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`. The key never syncs to iCloud and is never restored to another device.
- **Android.** An AES-256-GCM key in `AndroidKeyStore` (non-exportable, no user-auth requirement) wraps each API key. Ciphertext is stored in `context.noBackupFilesDir/danaview_ai_keys.bin`, which Auto Backup never copies, so neither the app's backup rules nor CORE-28's files change. A missing or invalidated Keystore key reports `keysLost`, and the UI asks the user to re-enter the key.
- **API.** `get/set/delete/listProviders`. It returns key presence and the last four characters; the full key is read only by the transport at send time.
- **Why not (a).** Restore and backup behaviour is under our control, there are no transitive dependencies, the surface is tiny (five entries), and the repo already uses Pigeon for its own plugins (ENG-01, ARCH §12.6).
- **Port.** `danaview_editor` never imports the plugin. `danaview_ai_studio` defines the `AiKeyStore` port, and the app root adapts the plugin to it (AIS-37), the same pattern as D-28.

### D-47 · HTTP

**Options.** (a) Pure `dart:io` `HttpClient` adapters. (b) Vendor SDKs (Google's Dart SDKs, community OpenAI and Anthropic packages). (c) `package:http`.

**Recommendation: (a)**, the same stack as v1's model downloader (AI-09). Rules:
- HTTPS only, OS trust store, no certificate pinning (provider certificates rotate).
- `followRedirects = false`: a redirect is an error.
- No cookies. `User-Agent: Danaview/<version>`, and no other identifying headers. No OpenRouter attribution headers (`HTTP-Referer`, `X-Title`).
- Keys go in headers only (`Authorization: Bearer`, `x-api-key`, `x-goog-api-key`), **never in URLs**. Gemini's `?key=` form is banned by test.
- Hosts are checked against the D-66 allow-list before connecting. One `HttpClient` per job, closed afterwards.

**Why.** SDKs add dependency churn, telemetry risk and uneven timeout and retry behaviour, and none of them covers all five providers. Each adapter needs only two to four endpoints.

### D-48 · Provider abstraction

```dart
enum AiProviderId { gemini, openai, anthropic, openrouter, xai }
final class ProviderCapabilities { final bool text, audioInput, jsonSchema, jsonObject, streaming;
  final int maxRequestBytes, contextTokens, maxOutputTokens; }
final class AiModelInfo { final String id, displayName; final ProviderCapabilities caps; final bool curated; }
abstract interface class LlmProvider {
  AiProviderId get id; String get host;                       // allow-listed host (D-66)
  List<AiModelInfo> get curatedModels;                        // shipped list, refreshed per release (AIS-40)
  ProviderCapabilities capabilitiesOf(String modelId);        // curated → live list → conservative default (text only)
  PreparedRequest prepare(String modelId, LlmRequest r);      // pure: body bytes + sha256, no key
  Future<KeyCheck> testKey(ApiKey key, ProviderProbeConsent c);          // list-models call, no content
  Future<List<AiModelInfo>> listModels(ApiKey key, ProviderProbeConsent c);
  Future<LlmResponse> send(ApiKey key, PreparedRequest p, AiSendTicket t, {CancelToken? cancel}); }
final class LlmRequest { final String contractId, system; final List<LlmPart> parts /*text | wavAudio*/;
  final JsonSchemaSpec schema; final double temperature /*0.2*/; final int maxOutputTokens; }
final class LlmResponse { final String json; final LlmUsage? usage; final FinishReason finish; }
```

- **Capability flags.** `text` (all), `audioInput` (D-50), `jsonSchema` (native structured output), `jsonObject` (JSON mode without a schema), `streaming` (declared, unused in 1.2.0).
- **JSON mode per provider** [VERIFY each at implementation]:
  - OpenAI and xAI: `response_format: {type: json_schema, strict: true}`.
  - Gemini: `generationConfig.responseMimeType: application/json` plus `responseSchema`.
  - Anthropic: a single forced tool (`tool_choice: {type: tool}`) whose `input_schema` is the contract schema.
  - OpenRouter: `response_format` json_schema when the model lists structured outputs, else `json_object`.
  - Our own validator always runs regardless (D-51).
- **Model lists.** Each adapter ships a short **curated** list (ids recorded by AIS-09/AIS-10 and refreshed by AIS-40 each release, [VERIFY]). **Load models** calls the provider's list endpoint with a probe consent. OpenRouter's list includes input modalities and supported parameters, so capabilities come from there. Users can also type a model id; unknown ids get conservative capabilities (text, no schema).
- **Timeouts.** Connect 15 s, first byte 90 s, total 180 s per request. Key test: 15 s total.
- **Retries.** At most 2 per request, identical bytes, on connection errors, timeouts, 408, 429, 500, 502, 503, 504. Backoff 2 s and 4 s with ±25% jitter. `Retry-After` is honoured up to 60 s; longer, and the batch fails as `rateLimited`. No retry on other 4xx.
- **Rate limits.** Per provider: concurrency 2 (1 after any 429 in the job), plus a soft cap of 20 requests per minute. Each adapter maps "quota or credit exhausted" separately from "rate limited" [VERIFY error shapes]: OpenAI `insufficient_quota`, Gemini `RESOURCE_EXHAUSTED` with quota detail, Anthropic credit-balance errors, OpenRouter 402, xAI 429 bodies.

### D-49 · Cost and usage display **[OWNER]**

**Options.** (a) A local token estimate before sending plus the provider-reported usage afterwards, with no prices. (b) Also show estimated prices from a bundled price table. (c) Show nothing.

**Recommendation: (a).**
- **Before sending.** The disclosure shows "about N input tokens, up to M output tokens". N comes from a local heuristic (AIS-08): about 4 characters per token for Latin text, 1 per CJK, kana or Hangul character, about 2.5 per character for other scripts, plus prompt overhead, plus audio at a per-provider rate per second [VERIFY: Gemini documents 32 tokens/s; OpenAI audio rates differ]. It is shown as a range (±25%). Provider count-token endpoints are **not** used, because they would send content before consent.
- **After the job.** The provider-reported `usage` (input and output tokens per request) is recorded in a local ledger (SharedPreferences `editor.ai.usage.<provider>.<yyyymm>`). Settings shows "This month on this device" per provider, with Reset.
- **No billing.** No prices, currencies or in-app purchases. OpenRouter's returned cost field is not shown.
- **Large requests.** Above 200k estimated input tokens, the Send button needs a second tap ("This is a large request").

**Why not (b).** Prices change often and differ by tier and region. A wrong price is worse than none.

### D-50 · Audio clips for voice tone **[OWNER]**

**Recommendation.**
- **Which audio.** For each cue, AIS-28's `ClipPlanner` picks the audible clip under it, using AI-12's priority (voice > main video > other video > other audio > music; muted, soloed-out and reversed clips excluded). It maps the cue's timeline range to source time through `ClipTimeMap`. Neighbouring cues of one media item are merged into units (5 s gap rule, as AI-12).
- **Extraction.** Each unit is extracted once with v1's `MediaJobs.extractSpeechAudio` (16 kHz s16 mono WAV, sample-accurate, ARCH §12.3/§15) into `<cache>/danaview/editor/work/ai/<jobId>/`. Then `WavSlicer` (Dart, isolate) cuts one clip per cue (cue range ±150 ms, at most 15 s).
- **Cleanup.** Clips are deleted through `OwnedFileDeleter` when the job ends, and the launch-time `work/` wipe (ARCH §15) catches leftovers. No new engine API is needed: the adapter mirrors D-28 (`EngineAiAudioClipExtractor`, AIS-37).
- **Size.** 16 kHz s16 mono is 32 kB per second, so a 7 s cue is about 224 kB (about 300 kB as base64).
- **Limits.** At most 4 MB of raw audio per request (about 2 min). At most 20 min of audio per action; above that the sheet asks for a smaller scope. These stay below the providers' inline-request limits (Gemini documents a 20 MB inline request limit) [VERIFY each].
- **Providers that accept audio** (capability `audioInput`):
  - Gemini models (inline `audio/wav`).
  - OpenAI audio-capable chat models (`input_audio` content part).
  - OpenRouter models whose input modalities include audio.
  - Claude and Grok are text-only for this feature [VERIFY at implementation]. On those, the "From the voice" option is disabled with the reason "This model can't listen to audio. Choose a Gemini or OpenAI audio model."
- **Why per-cue clips** rather than one long clip with timestamps: answers attach to cue ids exactly, and a failed batch costs only its own cues.

**Owner must confirm** that sending voice audio, after disclosure, is acceptable. Otherwise emotion and speaker detection run from text only.

### D-51 · Prompt and response contracts

**Contracts.** Every action has a versioned contract (`dv.cleanup.v1`, `dv.emotion.v1`, `dv.emoji.v1`, `dv.speakers.v1`, `dv.ask.v1`, `dv.translate.v1`). A contract has:
- a fixed system prompt (in code, reviewed like code);
- an input JSON builder in which caption text is **data** in fields, with short ids `c1…cN` mapped locally;
- an output **JSON Schema**, the strict subset all five providers accept;
- a validator;
- a mapper to suggestions.

**Validation and repair, in order.**
1. Parse locally, with local repair only: strip code fences or text before the first `{`, and tolerate one trailing comma.
2. Validate against the schema.
3. Validate each item: the id must exist in the batch and appear once. Text is limited to the input length × 3 + 40 graphemes. Control characters are removed. Markup is allowed only where the contract allows it. Emoji must be on the D-55 allow-list. Labels must be in the D-58 set. Confidences must lie in [0, 1].

Invalid items are dropped and counted ("2 suggestions were unusable and were skipped"). An unparseable batch is retried **once with identical bytes**; if that fails it is reported as failed with a "Retry batch" action (identical bytes again).

**No repair round trips.** Asking the model to fix its own output would send a new payload that the user never saw, so it is not done. A reply cut off by the length limit (`finish = length`) fails the batch with "Retry with smaller batches". That builds a new plan and shows a new disclosure.

**Prompt injection.** Cue text cannot widen what the model can do: the output can only name given ids and given fields, and everything goes through review. User-typed free text (Ask AI) is the user's own instruction (D-67).

**Never applied directly.** Validated output becomes `AiSuggestion`s (D-64). The only path into the project is the user accepting a suggestion, which runs normal commands.

### D-52 · Rich-text data model

**Options.**
- (a) Inline markup in `SubtitleCue.text` (extend v1's `<b>/<i>`). Rejected: escaping, fragile edits, emoji and grapheme confusion, and the AI would see tags.
- (b) A rich-text tree. Rejected: more than captions need.
- (c) **Plain text plus span runs over grapheme ranges.** Recommended.

**Model** (core, `model/cue_rich.dart`, AIS-02):

```dart
final class GraphemeRange { final int start, end; }            // extended grapheme clusters (package:characters), end exclusive
final class CueStyleOverride {                                  // every field optional; absent = inherit
  final String? fontFamily; final double? sizeScale /*0.5..3, × track size*/; final bool? bold, italic, underline, strike;
  final int? color /*ARGB*/; final Opt<int> highlight /*inherit|off|ARGB glyph background*/;
  final Opt<StrokeStyle> outline; final Opt<ShadowStyle> shadow; }
final class CueSpan { final GraphemeRange range; final CueStyleOverride style; } // sorted, non-overlapping, normalized
final class CuePlacement { final SubtitlePosition? vertical /*top|bottom|custom(y); "Middle" = custom(0.5)*/;
  final double? x /*0.05..0.95 block centre*/; final TextAlignH? align; }
final class CueWord { final GraphemeRange range; final TimeUs start, end /*relative to cue start*/; final bool estimated; }
final class CueEmotion { final EmotionLabel label; final int intensity /*1..3*/; final double confidence; final EmotionSource source /*text|voice|manual*/; }
final class Speaker { final SpeakerId id /*'sp_'*/; final String name; final int colorIndex; }
// SubtitleCue (extended): text (plain, '\n' breaks) + spans + emojiMarks (List<GraphemeRange>, AI-added emoji)
//   + override (CueStyleOverride?) + placement (CuePlacement?) + words (List<CueWord>) + emotion + speaker (SpeakerId?)
// SubtitleTrackData (extended): speakers, karaoke (KaraokeSettings{mode off|progressive|fill, highlight CueStyleOverride}),
//   direction (auto|ltr|rtl), speakerDisplay (none|prefix|color|prefixAndColor), emotionStyles (bool), presetRef
// SubtitleStyle (extended): underline (bool), letterSpacing (em/100), lineHeight
// CaptionProvenance (extended, additive): translation (TranslationProvenance?), aiEdits (List<AiEditRecord>, ≤ 50)
// CueOrigin gains `translated`. SubtitleCueDraft gains optional words and spans.
```

**Effective style resolution** (one function, `effectiveCueStyle`, AIS-12; later layers win per field):

| # | Layer | Source |
|---|---|---|
| 1 | Track style | `SubtitleStyle` (preset values are copied here, D-62) |
| 2 | Emotion style | `emotionStyles` on, and `confidence ≥ 0.6`: the D-58 table |
| 3 | Speaker colour | `speakerDisplay` includes colour |
| 4 | Cue override | `CueStyleOverride` |
| 5 | Span override | per range |
| 6 | Karaoke highlight | highlight sprite or overlay only (D-68) |

**Interactions** (pure functions in `eval/cue_text_ops.dart`, AIS-03):

| Operation | Spans | Emoji marks | Words |
|---|---|---|---|
| Text edit (`SetCueText`, AI clean-up, Ask AI) | Remapped by a grapheme diff (common prefix and suffix, then Myers on the middle). Unchanged graphemes keep their style. Inserted graphemes inherit the style of the grapheme before them (or after, at the start) | Kept when the emoji grapheme survives | Kept on unchanged words; words in changed regions get interpolated times and `estimated = true` |
| Split at grapheme k | Partitioned at k and re-based | Partitioned | Partitioned; split time = start of the first word at or after k, else proportional to graphemes, snapped to the grid |
| Merge a + sep + b | b's spans offset by `len(a) + len(sep)` | Same | b's word times offset by `b.start − a.start` |
| Translate (new track) | **Cue-level override kept**; partial spans dropped (the review says "Word styling isn't carried into translations") | Emoji are text, so they are translated or kept (the contract says "keep emoji") | Replaced by estimated timings (D-57) |
| SRT/VTT export | D-54 mapping | n/a | VTT karaoke timestamps (D-54) |
| Burn-in and preview | All layers rendered by `TextLayoutEngine` (AIS-13) | n/a | Karaoke (D-68) |

**Why grapheme ranges.** They are independent of UTF-16 or UTF-8 storage, match what users select, and match what the typewriter and karaoke reveal (v1 already counts clusters with `package:characters`). Decode clamps ranges to the grapheme count (repair), so a future change in segmentation rules can only shorten a span, never corrupt text.

### D-53 · Project schema 2 and migration

**Recommendation.** Body `schema = 2` and `minReader = 1` (`codec/schema_version.dart`).
- **Production step `s1 → s2`** (`codec/migrations/s1_to_s2.dart`, the first production entry in `Migrations.chain`, AIS-04): for each cue whose JSON has no `"sp"` key, `parseCueMarkup` (v1's own parser) turns `<b>/<i>` into spans and strips the tags. Unknown keys are kept. The step is idempotent: an s2 encoder always writes `"sp":[]` for a cue whose plain text contains a literal `<b>`, `<i>` or `<u>` pattern, so the step never re-reads literal angle brackets in an s2 body.
- **No other migration.** Every other 1.2.0 field is additive and optional, and default values are omitted (ARCH §8.2).
- **Opening a v1 project in 1.2.0** follows the CORE-23 framework: header classified `needsMigration`, chain runs in the decode isolate, `LoadedProject.migratedFrom = 1`, UX-40's one-time toast ("This project was updated for the new subtitle features. The previous version is kept as a backup."), and the first save writes `backups/pre-migration-s1.dnproj` (CORE-25).
- **Opening a 1.2.0 project in 1.1.x**: header `schema 2, minReader 1` → `readOnlyNewer` (D-12). The project opens read-only with the newer-version banner and shows plain cue text without spans, overrides, placement or karaoke. Imported fonts fall back to Figtree. Nothing is lost, because a 1.1.x app cannot save it.
- **Why not `minReader 2`.** That would block 1.1.x users from viewing and exporting their own projects. Read-only with simpler rendering is the D-12 promise.
- **JSON shape** (illustrative; AIS-04 pins the names in `schema/project.v2.schema.json`):

```json
{"t":"cue","id":"it_…","start":1000000,"dur":2000000,"text":"I love this 😍",
 "sp":[{"s":2,"e":6,"b":true,"c":"#FFD400FF"}],"em":[[12,13]],"ov":{"sz":1.2},
 "pl":{"v":"custom","y":0.5,"al":"center"},"w":[[0,1,0,180000],[2,6,200000,600000,1]],
 "emo":{"l":"joy","i":2,"c":0.82,"src":"voice"},"spk":"sp_A1b2C3d4E5f6"}
```

### D-54 · SRT and WebVTT mapping

Default export options: "Keep basic styling" on, "Speaker names" on when the track shows names, "RTL marks" on when the track is RTL.

| Feature | SRT export | VTT export | Import (both, AIS-07) |
|---|---|---|---|
| Bold, italic, underline | `<b>`, `<i>`, `<u>` | `<b>`, `<i>`, `<u>` | Mapped to spans (v1 kept only `<b>/<i>`) |
| Colour | `<font color="#RRGGBB">` (non-standard but common) | `<c.dvN>` classes plus a `STYLE` block (`::cue(.dvN){color:…;background-color:…}`) | SRT `<font color>`; VTT `<c.x>` resolved from `STYLE` (colour and background only) |
| Highlight | dropped | `background-color` in the class | from VTT class |
| Strike, outline, shadow, font, size, per-cue placement | dropped | dropped (VTT position settings are not written; v1 ignores cue settings) | ignored |
| Speaker | `NAME: ` prefix | `<v NAME>` voice span | VTT `<v>` → speakers; SRT `NAME:` prefix → speaker when ≥ 80% of cues match |
| Karaoke words | dropped | `<hh:mm:ss.ttt>` timestamp tags (VTT native) when "Karaoke timings" is on | VTT timestamp tags → words |
| RTL | U+200F at the start of each RTL line | same | U+200F/U+200E stripped |
| Emoji | as text | as text | as text |

"Keep basic styling" off gives v1's output exactly (`<i>/<b>` only). The suggested name stays `<project>.<bcp47>.srt|vtt` (ARCH §10.1), so a translated Spanish track exports as `<project>.es.srt`.

### D-55 · Emoji handling **[OWNER]**

- **Text model.** Emoji are ordinary grapheme clusters (ZWJ sequences, flags, keycaps and skin tones count once, as in v1's typewriter). `formats/emoji.dart` (AIS-03) recognizes them with `Extended_Pictographic` plus RGI sequence rules.
- **Font.** (a) System emoji: Apple Color Emoji on iOS, the system Noto Color Emoji on Android. This is what v1 does, through Flutter fallback. (b) Bundle Noto Color Emoji (about 10 MB in COLRv1, about 24 MB in bitmap form [VERIFY]) for an identical look across platforms; Impeller COLRv1 support needs checking [VERIFY].
- **Recommendation: (a).** Export matches the preview on the same device by construction (D-05: one engine). Only the emoji artwork differs between an iPhone and an Android phone, as in every other app.
- **AI-inserted emoji** must be on an allow-list of about 400 RGI emoji from **Emoji ≤ 12.0**. Android 10 (API 29, the editor's floor) supports Emoji 12.0, so AI emoji never render as missing-glyph boxes on supported devices. User-typed emoji are not restricted.
- **Removal.** "Remove all emojis" removes either only AI-added emoji (tracked by `emojiMarks`) or every emoji. It collapses the spacing left behind. A cue that becomes empty is deleted, with a notice, because invariant I8 requires non-empty cues.

**Owner confirms (a)**, or chooses (b) with its size cost.

### D-56 · RTL and complex scripts

- **Direction.** Auto from the first strong character (v1's `resolveTextDirection`) unless the track overrides it (`direction: ltr|rtl`). Bidi reordering, Arabic joining and Indic shaping are done by Flutter's paragraph engine (ICU plus HarfBuzz), identically for preview and export because both are the same engine (D-05).
- **Consistent glyphs.** The bundled Noto families (D-60) are injected as explicit `fallbackFamilies` ahead of the system fallback. Arabic, Hebrew, Indic and Thai captions therefore look the same on every device, not only within one device.
- **Rules.**
  - Letter spacing is forced to 0 for runs in cursive or joining scripts (Arabic, Syriac, N'Ko, Mongolian), because spacing breaks joining [VERIFY in AIS-13 goldens].
  - Underline and strike thickness scale with the run's font size.
  - Alignment stays absolute (`left/center/right`, as in v1). Translated RTL tracks default to centre.
  - Spans and words use logical grapheme order. The karaoke and typewriter reveal follows logical order, which progresses right to left on screen for RTL. v1's reveal strips are built from glyph boxes; AIS-13 adds RTL and mixed-direction goldens.
- **Segmentation of translated text** reuses AI-11's script profiles (CJK 16, Korean 18, no-space SE Asian 35, RTL) and kinsoku.
- **IME.** The rich editor keeps the composing region unstyled until it is committed, so CJK, Indic and Arabic input methods work (AIS-17).

### D-57 · Translation

- **Result.** Translation **always creates a new subtitle track**. The original is kept. The new track is placed directly above the source in display order, with `language` = target, `origin = translated` cues, and burn-in **off** by default (the source keeps its setting). Provenance: a new `CaptionProvenance` whose `translation = {sourceTrack, sourceLanguage, targetLanguage, provider, model, contract}`. Whisper fields are copied from the source when present, else filled with neutral values (`generator: 'translation'`). Regenerate is disabled for translated tracks.
- **Alignment strategy.**
  1. Group consecutive source cues into **sentence groups**: break at a sentence end (`TimedWord.endsSentence` rules) or a gap ≥ 1.2 s, with at most 6 cues per group. The model sees whole sentences, so word order can change across lines (needed for SOV languages, for example).
  2. The contract returns one translation per group.
  3. The group's time span is the union of its cues. Each translated word gets a pseudo-time by spreading the group's text across the span in proportion to the source cues' durations. Breaks fall at word boundaries, or at grapheme boundaries for no-space scripts.
  4. AI-11's `DpCaptionSegmenter` re-segments these pseudo-timed words with the target language's profile, constrained to the group span, with edges on the frame grid and the min/max duration and CPS rules applied. Re-split lines therefore fit the target script.
  5. Option "Keep line timing" (off by default) translates cue by cue instead (1:1 timing, line re-wrap only).
- **Carried over.** Cue-level overrides, placement, emotion and speaker are carried from the dominant source cue of each output cue. Partial spans are dropped (D-52). Words are estimated, so karaoke works and shows "estimated".
- **Review.** Translation is reviewed as a whole new track (§4.3 U10) before it is created. One accept equals one history entry (`AddDerivedSubtitleTrack`).
- **Languages.** A searchable list of about 180 BCP-47 tags with English and native names (`translation/languages.dart`, AIS-30), reusing whisper's 99 language names where they overlap, plus "Other…" with BCP-47 syntax validation.

### D-58 · Emotion taxonomy **[OWNER]**

**Labels:** `neutral, joy, excitement, affection, sadness, anger, fear, surprise, disgust, sarcasm`. Each has an `intensity` of 1–3, a `confidence` in [0, 1], and a `source` of `text | voice | manual`. Below confidence 0.5, the label is treated as neutral for emoji and style. The table is fixed in code (`actions/common/emotion_tables.dart`, AIS-29):

| Label | Emoji pool (light = 1 per eligible cue, heavy = up to 2) | Emotion style (only when "Emotion styles" is on for the track) |
|---|---|---|
| joy | 😀 😄 😊 🙂 | colour #FFD54F |
| excitement | 🤩 🎉 🔥 ⚡ | bold, colour #FFB300 |
| affection | ❤️ 🥰 😍 🤗 | colour #F48FB1 |
| sadness | 😢 😔 💔 | italic, colour #90CAF9 |
| anger | 😠 😡 💢 | bold, colour #EF5350 |
| fear | 😨 😱 😰 | italic, colour #B39DDB |
| surprise | 😮 😲 🤯 | bold, sizeScale 1.1 |
| disgust | 🤢 😖 | colour #AED581 |
| sarcasm | 🙃 😏 | italic |
| neutral | – | – |

**Emoji density.**
- none: no emoji.
- light: at most 1 emoji per cue, only cues with a non-neutral label and confidence ≥ 0.6, and at most one in three consecutive cues.
- heavy: at most 2 per cue, every non-neutral cue.

The limits are enforced locally even when the model suggests more. Emotion-driven emoji need **no extra request** (local mapping from labels). "AI picks emojis" (contextual, for example 🍕) is the `dv.emoji.v1` contract.

Owner confirms the label set, colours and emoji pools.

### D-59 · Speaker labels (updated 2026-10-16)

**Options.**
- (a) Text-only inference by any model. Weak: it guesses changes of speaker from the wording.
- (b) An audio-capable model listening to windows of about 2 min, with the speaker list carried across windows.
- (c) On-device diarization. That needs a second model, a second consent and download, and native inference. ~~Out of scope for 1.2.0.~~ In scope since 2026-10-16 (D-70c).

**Updated 2026-10-16 (owner).** Option (c) is now in scope as the default way to find speakers: on-device diarization after whisper (D-70c), with words assigned to speakers from whisper's word timestamps and overlapping speech kept as separate cues on per-speaker lanes (D-70e, D-70f). The order is: manual always; on-device diarization when its model pack is downloaded; cloud diarization (D-70g) or the AI suggestions below when AI Studio is on and the user picks them. The rest of this section still describes the AI suggestions.

**Recommendation.** Manual speaker assignment always (speaker table per track: names, colours, merge). AI suggestions use (b) when the model has `audioInput`, else (a) labelled "guessed from the text". The model may suggest a name only when the name is spoken in the captions; otherwise speakers are "Speaker 1…n". At most 8 speakers per action. Display: `speakerDisplay` none, prefix ("ANNA: "), colour, or both. VTT `<v>` import and export (D-54).

### D-60 · Bundled fonts and font packs **[OWNER]**

**Budget.** At most **8 MB** added to the compressed iOS and Android download (measured by AIS-22 on IPA and AAB, [VERIFY]). v1 already bundles about 3–4 MB (ARCH §17.8).

**Add** (OFL-1.1, Regular and Bold static TTF, from the Noto project at a pinned upstream commit with SHA-256 recorded in `danaview_editor_fonts/FONTS.md`): Noto Sans Arabic, Noto Naskh Arabic, Noto Sans Hebrew, Noto Sans Devanagari, Noto Sans Bengali, Noto Sans Gurmukhi, Noto Sans Gujarati, Noto Sans Tamil, Noto Sans Telugu, Noto Sans Kannada, Noto Sans Malayalam, Noto Sans Sinhala, Noto Sans Thai. If the measurement exceeds the budget, drop Naskh and Sinhala first. Greek, Cyrillic and Vietnamese are covered by Inter (already bundled), which is added to the fallback chain.

**CJK options.**
- (a) System CJK fonts. This is the v1 behaviour, and it renders correctly in preview and export on the device.
- (b) Optional downloadable "font packs" (Noto Sans/Serif CJK SC/TC/JP/KR, about 8–16 MB each [VERIFY]) from a pinned host with a disclosure and consent like §16.3. This adds a network host and privacy text: conditional ticket AIS-27.
- (c) Bundle CJK: 40 MB or more.

**Recommendation: (a)**, with AIS-27 scheduled only if the owner wants a choice of CJK fonts.

**Emoji** per D-55.

### D-61 · Font import **[OWNER]** (reminder wording)

- **Formats.** `.ttf` and `.otf` only. Single face, at most 30 MB, at most 200 imported fonts.
- **Validation** (`formats/sfnt_inspector.dart`, pure Dart, AIS-23):
  - sfnt magic `0x00010000`, `OTTO` or `true` (reject `ttcf`, `wOFF`, `wOF2`);
  - table directory bounds and checksums;
  - required `cmap`, `head`, `name`, `hhea`, `hmtx` (`glyf`/`loca` or `CFF `);
  - family and style names from `name`; supported scripts from `cmap` ranges;
  - `OS/2.fsType` embedding bits;
  - a successful load with `ui.loadFontFromList` before it is accepted.
- **Storage.** An **app-level library** `<support>/danaview/editor/fonts/<sha256>.<ext>` plus `fonts/index.json` (atomic writes through `StoreFs`), deduplicated by hash. Projects reference `usr_<sha256[0:16]>` ids. `refs.json` lists the font ids a project uses, so the library can say "Used in 3 projects". Fonts are never garbage-collected; only the user deletes them.
- **Portability.** Duplicating a project shares the fonts. A project opened where a font is missing (for example, after a restore) shows "1 font used in this project is missing" with **Import font…**, which re-links by family name plus hash. Until then those runs fall back to Figtree. The sprite key includes the font id, so a re-imported different file never reuses stale sprites.
- **Rights reminder**, shown on every import, with **Import** and **Cancel**: "Only import fonts you have the right to use in videos you make and share. Some font licences don't allow this." When `fsType` marks the font restricted, a stronger line is added: "This font's licence restricts embedding. Check its licence before you publish videos that use it."

### D-62 · Subtitle style presets

- **Built-ins** live in code (`model/subtitle_presets.dart`, AIS-23) and are versioned:

  | Preset | Font and colour | Treatment | Placement |
  |---|---|---|---|
  | YouTube classic | Figtree 42 pt white | black box at 75% | bottom |
  | TikTok bold | Montserrat Bold 56 pt white | 6 pt black outline, no box, 1 line, maxWidth 0.8 | custom 0.62 |
  | Karaoke | Figtree Bold 48 pt white | progressive mode, yellow highlight, outline | bottom |
  | Cinema | Lora 40 pt off-white | soft shadow, no box | bottom |
  | Minimal | Inter 38 pt white | 30% shadow, no box | bottom |

- **User presets.** One app-level file `<support>/danaview/editor/presets/subtitle_presets.json` (`{"format":"danaview.editor.subtitlePresets","schema":1,"presets":[…]}`, atomic writes, at most 100). Each holds style, karaoke, position, speaker display and emotion-styles values.
- **Applying a preset copies the values** into the track and records `presetRef {id, builtIn, revision}`. Projects therefore never depend on the presets file, and a changed or deleted preset never alters an existing project. The track shows "Modified" when its values differ from the referenced preset.
- **Why not SharedPreferences.** The data is structured, versioned and may grow.

### D-63 · App Store and Google Play **[OWNER]**

- **Apple.**
  - Guideline 5.1.2(i), as updated in late 2025, asks apps to disclose clearly where personal data is shared with third parties, including third-party AI, and to get explicit permission first [VERIFY the current wording]. D-45's per-provider sheet and per-action disclosure meet this.
  - Privacy nutrition label: content goes from the device straight to a provider the user chose, under the user's own account, and the provider may keep it under its terms. The conservative choice is to declare "User Content: Audio Data, Other User Content: not linked to the user, not used for tracking, App Functionality" — **owner and legal to decide** whether the label changes.
  - No in-app purchase is involved (guideline 3.1.1): nothing is sold, and keys come from the user's own accounts.
  - Provider names are used only nominatively, with no logos.
  - App Review needs a way to test AI Studio. **Owner decides** between providing a spend-capped demo key in the review notes or describing the feature as optional with screenshots.
  - The age-rating questionnaire may ask about AI-generated content [VERIFY].
  - Export compliance is unchanged (OS TLS only).
- **Google Play.**
  - Data safety: declare "Audio" and "Other user-generated content" as collected only when the user starts an action, optional, for App functionality. Transfers the user starts to a service they chose are typically not counted as "sharing" [VERIFY current Play definitions].
  - The AI-Generated Content policy asks apps that generate content with AI to let users report or flag offensive output [VERIFY scope for text rewriting]. Recommendation: a "Report a problem" item on suggestion rows that opens an email draft to vecvel support containing nothing unless the user adds it (**owner confirms**).
  - The prominent-disclosure requirement is met by D-45.

### D-64 · Suggestions and review

- **Lifecycle.** A job produces a `SuggestionSet` of typed `AiSuggestion`s: text, emotion, emoji, speaker, style, or translated track. Each carries `cueId`, `baseHash` (a hash of the cue's text, spans, words, emotion and speaker when the suggestion was made) and a state (`pending | accepted | rejected | stale`). Suggestions live **outside history and outside the project JSON**.
- **Storage.** A sidecar `<support>/danaview/editor/projects/<id>/ai/suggestions-<setId>.json` (atomic writes through core `StoreFs`, deleted through `OwnedFileDeleter`) keeps paid-for results across app kills. It is removed when a set is fully resolved and with the project bundle on project delete. It sits inside the project bundle, so it follows the bundle's backup rules (ARCH §8.1).
- **Accepting.**
  - **Accept** on one suggestion runs one command and adds one history entry.
  - **Accept all** in a group runs one `ApplyCueEdits` and adds one entry.
  - Translation is one `AddDerivedSubtitleTrack` entry.
  - **Reject** is not a history entry.
  - Undo restores the snapshot, and the suggestion goes back to pending.
- **Stale handling.** If a cue's current hash ≠ `baseHash` (the user edited it), the suggestion shows as "Changed since suggested". Accept re-diffs it against the current text when only the text changed outside the edited range; otherwise accept is disabled ("Dismiss"). A deleted cue invalidates its suggestions.
- **Provenance.** Each accepted group appends an `AiEditRecord {action, provider, model, contract, at, accepted, rejected}` to the track's provenance (capped at 50).

### D-65 · Gating

- **AI Studio** sits behind the compile-time define `DANAVIEW_AI_STUDIO` (default **false** until AIS-38/AIS-39/AIS-40 pass; AIS-41 enables it in release builds) **and** the runtime master switch (D-45).
- **Rich subtitles, fonts and presets** use no network and ship unconditionally under the existing `DANAVIEW_EDITOR`, because schema 2 is needed either way.
- **Desktop** keeps the editor hidden (D-17).

### D-66 · Endpoints **[OWNER]**

The allow-list is exactly [VERIFY each]:
- `generativelanguage.googleapis.com` (Gemini)
- `api.openai.com`
- `api.anthropic.com`
- `openrouter.ai`
- `api.x.ai`

There are no user-configurable base URLs in 1.2.0. Debug and profile builds accept `--dart-define=DANAVIEW_AI_FAKE_HOST=127.0.0.1:<port>`, which reroutes every provider to a loopback fake server for tests. It is asserted unreachable in release (`kReleaseMode` guard plus an architecture test). The owner confirms that no custom endpoints are offered.

### D-67 · Ask AI with a free-text instruction

- **Scope.** The selection: whole cues (one or many) or a sub-range of one cue. A sub-range is sent with the full cue and markers `⟦…⟧`, and the contract requires the text outside the markers to come back unchanged (validated). Otherwise the item is rejected.
- **What can change.** Only text (plus emoji). No timing, cue count, styles or other cues.
- **Instruction.** At most 500 characters, placed in the prompt as the user's instruction. The system prompt fixes the output schema and forbids other changes.
- **Presets.** Translate (language), Fix grammar, Shorten, Change tone (formal, casual, friendly, excited, neutral), Add emojis, Remove emojis. "Remove emojis" on a selection runs **locally** with no request (D-55).
- **Result.** A diff that the user accepts or rejects, with Try again and undo.

### D-68 · Karaoke rendering

- **Sprites.** For a cue with karaoke on, the export plan holds the normal sprite `<cueId>#c` plus a **highlight sprite** `<cueId>#k` at `z` sub **+1** (within `ZOrder`'s −5…5). The highlight sprite has the same layout with the karaoke highlight style (colour, glyph background, outline colour only, so the metrics are identical), is rasterized with the **union raster extent** of both variants so the two align pixel for pixel, and carries the glyph-order map with an animated `reveal` channel.
- **Progressive mode.** Keys step to each word's end-grapheme count at the word's start time: two keys, `[tw − 1 µs, n_prev]` and `[tw, n_w]`.
- **Fill mode.** Keys rise linearly from `n_prev` to `n_w` across the word.
- **Speaker prefix.** Grapheme counts are offset by the prefix's clusters.
- **No contract change.** This uses only existing contract features: sprite assets with `reveal: true`, the `reveal` channel, and opaque layer ids (ARCH §11.2, §11.6). RenderPlan `v` stays 1, and the iOS and Android engines need no change. AIS-14 adds a contract fixture so the Swift and Kotlin decode tests cover it.
- **Preview.** The overlay paints the base layout, then the highlight layout clipped with v1's `revealClip` at `karaokeRevealAt(cue, t)`. The compiler's keys and the overlay come from the same core function (`eval/karaoke_eval.dart`), so they agree by construction.
- **Cost.** Two sprites per karaoke cue roughly doubles the sprite pre-pass for those tracks. It is measured against V-D7's budget in AIS-39.

### D-69 · Word timings

- **Storage.** Word timings are **stored on cues** (`CueWord`, times relative to the cue start, in µs and not on the grid, because they only feed `reveal` keys and snapping).
- **Why on cues.** v1 keeps whisper words only in the transcript cache, which is an LRU cache, backup-excluded and source-timed (AI-10). That is not durable project data.
- **Sources.**
  - Auto captions: AI-11's segmenter passes words into the drafts (AIS-15).
  - VTT timestamp-tag import.
  - "Estimate timings": proportional to graphemes, with `estimated = true`.
- **Edits.** Text edits mark the affected words estimated (D-52). Trimming a cue drops the words outside it.

### D-70 · 1.2.0 process

- 1.2.0 tickets use the prefix **AIS-**. BP §1 (how to work a ticket) and §2 (ownership) apply, with the additions in §5.1.
- A v1 file may be edited by a 1.2.0 ticket only if that ticket lists the file in **Owns** with "(extends <v1 ticket>)".
- Each v1 file is extended by at most one 1.2.0 ticket, except the files in the register (§5.6).
- AIS-01 is the skeleton ticket (D-33 placeholders for every new 1.2.0 file).

---

## 3. Architecture

### 3.1 Package graph (1.2.0 additions in **bold**)

```
app root (lib/: main.dart, app.dart, router/)
 ├─ danaview_features ─────────► (unchanged deps; legal_texts.dart gains AI/font text)
 ├─ danaview_editor (UX)
 │    ├─ danaview_editor_core (pure Dart; rich cues, schema 2, commands, sfnt inspector, font/preset stores)
 │    ├─ danaview_editor_engine_api (render prep v2)
 │    ├─ danaview_transcription (segmenter with words)
 │    ├─ **danaview_ai_studio** (Dart, no widgets) ──► danaview_ai_providers, danaview_editor_core, danaview_transcription
 │    ├─ **danaview_ai_providers** (pure Dart + dart:io) ──► meta, collection, crypto only
 │    ├─ danaview_editor_fonts (+ Noto families)
 │    └─ danaview_ui_kit, danaview_data, danaview_platform, danaview_domain, danaview_features (chrome/orientation/storage only)
 ├─ danaview_editor_engine (font pick kind)
 ├─ danaview_whisper
 ├─ **danaview_secure_keys** (Flutter plugin iOS+Android, Pigeon) ──► no danaview_* package
 │
 │  added 2026-10-16 (§7):
 ├─ **danaview_ai** (pure Dart: switch, feature registry, shared client) ──► danaview_ai_providers
 │    used by danaview_ai_studio (editor), danaview_search (search), later danaview_camera and documents
 ├─ **danaview_ai_ui** (Flutter: the one send view, AI Studio settings) ──► danaview_ai, danaview_ui_kit
 ├─ **danaview_ai_genkit** (only if AIS-42 adopts Genkit: Genkit-backed LlmProvider adapters) ──► danaview_ai_providers, genkit
 ├─ **danaview_diarization** (Flutter FFI plugin: sherpa-onnx diarization) ──► no danaview_* package
 ├─ **danaview_media_analysis** (Flutter plugin: Apple Vision / ML Kit labels and text recognition) ──► no danaview_* package
 └─ **danaview_search** (Dart: on-device index, query engine, AI filters and deep indexing through danaview_ai)
```

New dependency rules, numbered after ARCH §4.2's eight and enforced by `test/architecture/dependency_rules_test.dart` (AIS-01):

9. `danaview_ai_providers` depends only on `meta`, `collection`, `crypto` and the SDK (`dart:io`, `dart:isolate`). No `package:flutter`, no `danaview_*`.
10. `danaview_ai_studio` depends on `danaview_ai_providers`, `danaview_editor_core`, `danaview_transcription`, `characters`, `collection`, `meta`. Never the engine packages, `danaview_editor`, `danaview_features` or `danaview_secure_keys`. No widget code.
11. `danaview_secure_keys` depends on no `danaview_*` package. Only the app root imports it.
12. `danaview_editor` may import `danaview_ai_studio` and `danaview_ai_providers` (types only). It never imports `danaview_secure_keys`.
13. `AiSendConsent.accepted(` appears only in `packages/danaview_editor/lib/src/editor/flows/ai/ai_send_view.dart`, and `ProviderProbeConsent.accepted(` only in `packages/danaview_editor/lib/src/settings/ai/provider_sheet.dart`.
14. `HttpClient(` is constructed in the AI packages only in `packages/danaview_ai_providers/lib/src/transport/http_transport.dart`.
15. No AI package source contains `?key=`, and no `print`/`debugPrint`/`log` call in the AI packages takes a request body, response body, key or caption text (grep test with an allow-list of format strings).

Rules added 2026-10-16 (§7.1; AIS-43 adds them to the same test):

16. `danaview_ai` depends only on `danaview_ai_providers`, `meta`, `collection` and the SDK. No `package:flutter`. Every feature that sends anything (editor, search, later camera and documents) goes through `danaview_ai`; no other package builds a provider or a transport.
17. **Rule 13 is amended:** the send view moves to `danaview_ai_ui`, so `AiSendConsent.accepted(` appears only in `packages/danaview_ai_ui/lib/src/ai_send_view.dart` and `ProviderProbeConsent.accepted(` only in `packages/danaview_ai_ui/lib/src/settings/provider_sheet.dart`.
18. `danaview_diarization`, `danaview_media_analysis` and `danaview_search` open no sockets (`HttpClient(` and `Socket.connect` banned by grep); model files arrive only through v1's consented downloader (AI-09).
19. If Genkit is adopted, only `danaview_ai_genkit` may import `package:genkit*`, and every Genkit call goes through the injected `HttpTransport` (D-70b).

### 3.2 New and changed files (owner ticket in brackets)

```
packages/danaview_ai_providers/  pubspec, analysis_options, lib/danaview_ai_providers.dart, lib/testing.dart          [AIS-01]
  lib/src/contracts/{llm_provider,provider_id,capabilities,llm_request,llm_response,model_info,ai_failure}.dart [AIS-08]
  lib/src/consent/{ai_send_consent,provider_probe_consent,send_ticket}.dart                                    [AIS-08]
  lib/src/transport/{http_transport,retry_policy,rate_limiter,cancel_token,host_allow_list}.dart               [AIS-08]
  lib/src/json/{json_extract,json_schema_lite}.dart  lib/src/tokens/token_estimator.dart                       [AIS-08]
  lib/src/fake/{fake_llm_server,fake_llm_provider}.dart   test/support/no_network.dart                          [AIS-08]
  lib/src/providers/{openai_compatible,openai_provider,gemini_provider}.dart  test/fixtures/providers/{openai,gemini}/   [AIS-09]
  lib/src/providers/{anthropic_provider,openrouter_provider,xai_provider}.dart test/fixtures/providers/{anthropic,openrouter,xai}/ [AIS-10]
  tool/live_check.dart (manual only)                                                                            [AIS-40]
packages/danaview_ai_studio/  pubspec, analysis_options, lib/danaview_ai_studio.dart, lib/testing.dart                [AIS-01]
  lib/src/{contracts,orchestrator,review,audio,usage,glossary}/                                                [AIS-28]
  lib/src/actions/{common,cleanup,emotion,emoji,speakers}/                                                     [AIS-29]
  lib/src/actions/{ask,translate}/, lib/src/translation/                                                       [AIS-30]
packages/danaview_secure_keys/  (whole plugin)                                                                     [AIS-11]
packages/danaview_editor_core/
  lib/src/model/cue_rich.dart; model/{items,subtitle,text_style}.dart (extends CORE-03); validate/ (extends CORE-08) [AIS-02]
  lib/src/eval/cue_text_ops.dart, lib/src/formats/emoji.dart                                                    [AIS-03]
  codec/{project_json,schema_version}.dart (extends CORE-22), codec/migrations/{migrations (extends CORE-23),s1_to_s2}.dart,
    schema/project.v2.schema.json, test/fixtures/projects/s2/                                                    [AIS-04]
  ops/commands/subtitle_commands.dart (extends CORE-15), ops/commands/rich_cue_commands.dart                     [AIS-05]
  ops/commands/caption_commands.dart (extends CORE-15), ops/commands/ai_cue_commands.dart                        [AIS-06]
  formats/{subtitle_codec,srt,vtt}.dart (extends CORE-20), plan/export_settings.dart (extends CORE-33)            [AIS-07]
  eval/text_layout_spec.dart (extends CORE-07), eval/karaoke_eval.dart                                           [AIS-12]
  plan/{lowering_text,sprite_requests}.dart (extends CORE-31), plan/sprite_request.dart (extends CORE-29),
    plan/z_order.dart (extends CORE-30)                                                                         [AIS-14]
  ops/speech_snap.dart                                                                                          [AIS-19]
  formats/sfnt_inspector.dart, store/{font_library_store,preset_store}.dart, model/subtitle_presets.dart,
    store/file_project_repository.dart (extends CORE-25: refs.json fonts)                                         [AIS-23]
packages/danaview_editor_engine_api/lib/src/render_prep/ (extends API-04)                                           [AIS-13]
packages/danaview_editor_engine_api/lib/src/platform_services.dart (extends API-01) + engine Pigeon/native pickers  [AIS-24]
packages/danaview_transcription/lib/src/segmentation/ (extends AI-11), pipeline/pipeline.dart (extends AI-13)       [AIS-15]
packages/danaview_editor_fonts/ (extends UX-30), lib/src/editor/text/font_catalog.dart (extends UX-30)              [AIS-22]
packages/danaview_editor/lib/src/
  editor/preview/{text_overlay_layer,text_overlay_painter} (extends UX-19), manipulation_overlay (extends UX-22),
    preview/cue_drag_controller.dart                                                                            [AIS-16]
  editor/panels/transcript/{transcript_view,transcript_row,transcript_controller,rich_cue_editor,rich_cue_controller}.dart,
    editor/panels/subtitles_panel.dart (extends UX-31)                                                          [AIS-17]
  editor/panels/transcript/style_toolbar.dart, editor/panels/cue/                                                [AIS-18]
  editor/panels/transcript/timing_tools.dart, editor/timeline/snapping.dart (extends UX-13)                      [AIS-19]
  editor/panels/subtitles/karaoke_section.dart, editor/flows/emoji/                                              [AIS-20]
  editor/panels/subtitle_io.dart (extends UX-32), editor/flows/export/export_sheet.dart (extends UX-39)          [AIS-21]
  editor/panels/font_picker.dart (extends UX-30), editor/text/{font_library_controller,font_import_flow,font_loader}.dart,
    settings/fonts_settings_section.dart                                                                       [AIS-25]
  editor/panels/presets/, editor/state/presets_controller.dart                                                  [AIS-26]
  settings/ai/, settings/editor_settings_screen.dart (extends UX-04)                                             [AIS-31]
  editor/flows/ai/{ai_studio_sheet,ai_studio_controller,ai_send_view,ai_progress_panel,ai_failure_copy}.dart     [AIS-32]
  editor/panels/review/                                                                                         [AIS-33]
  editor/flows/ai/{ask_ai_sheet,ask_ai_controller}.dart                                                         [AIS-34]
  editor/flows/ai/{translate_sheet,translate_controller,language_search}.dart                                   [AIS-35]
  app/adapters/{secure_key_store_adapter,engine_ai_audio_extractor,prefs_usage_ledger}.dart, app/editor_bootstrap.dart (extends INT-02) [AIS-37]
  editor/contracts/{action_ids,inspector_routes,tool_ids}.dart, editor/wiring/action_bindings.dart,
    app/{editor_providers,editor_availability}.dart, pubspec.yaml (all extend UX-01)                             [AIS-01]
packages/danaview_features/lib/src/more/legal_texts.dart (extends UX-42)                                            [AIS-36]
Per-feature bindings and strings: actions/bindings/<feature>_bindings.dart and app/strings/<feature>_strings.dart, owned by the feature ticket.
```

### 3.3 Domain model summary

D-52 lists the types. Validator additions (AIS-02, extending CORE-08's I1–I9):
- **I10.** Per cue:
  - `spans` sorted, non-overlapping, non-empty, within `[0, graphemeCount]`, normalized (adjacent equal styles merged, empty overrides absent);
  - `emojiMarks` within range and each on an emoji grapheme;
  - `words` sorted by range and by time, non-overlapping, `0 ≤ start < end ≤ duration`;
  - `sizeScale ∈ [0.5, 3]`; placement `x ∈ [0.05, 0.95]`; `CustomSubtitlePosition.y ∈ [0, 1]`.
- **I11.** Per track:
  - speaker ids unique (`sp_` prefix), at most 32 speakers, every cue's speaker present;
  - `presetRef` well-formed;
  - `translation.sourceTrack` may point to a deleted track (kept as history, never dereferenced).

`repair()` clamps or drops anything invalid, and never refuses (ARCH §6.9).

### 3.4 Rendering path

```
SubtitleCue + SubtitleTrackData (+ effective style, D-52)
   │  cueLayoutSpecOf(cue, track, canvas, variant: base|karaokeHighlight)      core eval (AIS-12)
   ▼
TextLayoutSpec v2 { runs: [TextRun(text, style override…)], direction, placement anchor, … }
   ├──► preview: TextOverlayLayer → TextLayoutEngine.layout → paint base; karaoke: paint highlight clipped
   │             by revealClip(karaokeRevealAt(cue, t))  (Flutter, UI isolate, per frame change)  (AIS-16)
   └──► export: collectSpriteRequests (base + #k variant) → SpritePrepass → TextSpriteRasterizer (same engine)
                → .vsprite v1 (+ glyph map for #k) → lowerCue: sprite layers #c (sub 0) and #k (sub +1,
                  `reveal` keys from karaokeRevealKeys) → RenderPlan v1 → native engines (unchanged)  (AIS-13/14)
```

`TextRun` JSON includes the new style fields only when they are not the defaults. Plain cues therefore keep the same canonical JSON as in v1. AIS-14 still bumps `contentFontsVersion` to 2, because the bundled fallback chain changes how those cues render.

### 3.5 Provider layer and transport

```
LlmRequest ──provider.prepare(model)──► PreparedRequest {bytes, sha256, path, headers(no key)}   (Isolate.run if > 256 kB)
PreparedRequest + ApiKey + AiSendTicket(from AiSendConsent) ──► HttpTransport.send
   ├ host ∈ allow-list (D-66); sha256 ∈ ticket.hashes; key only in header; followRedirects=false
   ├ RateLimiter (per provider) → RetryPolicy (identical bytes) → CancelToken
   └ response bytes → adapter.parse → LlmResponse{json text, usage, finish}  | AiFailure (typed)
```

`AiFailure` (sealed): `offline`, `timeout`, `connectionLost(maybeReceived)`, `keyMissing`, `keyInvalid`, `quotaExceeded`, `rateLimited(retryAfter)`, `modelUnavailable`, `requestTooLarge`, `contentBlocked`, `truncated`, `malformedResponse`, `providerError(status)`, `cancelled`, `hostNotAllowed` (a bug).

### 3.6 AI Studio service

```dart
abstract interface class AiStudioService {                  // danaview_ai_studio (AIS-28)
  Future<AiStudioStatus> status();                           // off | on(configured providers, models, capabilities)
  Future<AiActionPlan> plan(AiActionRequest r, EditProject p);   // local only: select, extract audio, batch, prepare, disclose
  AiJob run(AiActionPlan plan, AiSendConsent consent);       // progress stream, cancel, result SuggestionSet
  SuggestionStore suggestions(ProjectId id);                  // sidecar (D-64)
  UsageLedger get usage; GlossaryStore glossary(ProjectId id); }
final class AiSendDisclosure { AiProviderId provider; String host, model, actionLabel; int items, characters;
  IntRange estInputTokens; int maxOutputTokens; int audioClips; TimeUs audioDuration; int audioBytes;
  List<String> payloadSha256 /*one per batch*/; int totalBytes; }
```

`AiActionPlan` is immutable and holds the prepared requests, so the disclosure describes exactly the bytes that will be sent. Ports (implemented at the app root, AIS-37):
- `AiKeyStore`, adapting `danaview_secure_keys`;
- `AiAudioClipExtractor`, adapting `engine.jobs.extractSpeechAudio`;
- `UsageLedgerStore` (SharedPreferences);
- v1's `BackgroundLeaseProvider` for long jobs on Android.

### 3.7 Data flows

**(a) A Studio action** (clean-up, emotion, emoji, speakers)

```
Captions tool ▸ AI Studio ▸ choose action, track, scope, options
  └► AiStudioService.plan ─ select cues (scope) → short ids
        ├ [voice] ClipPlanner (AI-12 rules) → AiAudioClipExtractor (engine extractSpeechAudio per unit) → WavSlicer (isolate)
        ├ batching: ≤ 6k est. input tokens, ≤ 80 cues, sentence groups kept whole, ≤ 4 MB audio per request
        └ prepare bodies (isolate) → AiSendDisclosure
  └► AiSendView shows the disclosure ─[Send]─► AiSendConsent.accepted(disclosure)        (only call site)
  └► AiJob: per batch → HttpTransport → JSON extract → contract validate → AiSuggestion[]
        → SuggestionStore.save (sidecar) ; UsageLedger.record ; work/ai/<job>/ clips deleted
  └► "Review 290 suggestions" ─► Review panel ─[Accept]─► suggestion.toCommand → EditorController.apply
        → history entry → PlanSync → autosave            (Reject: state only)
```

**(b) Ask AI.** Selection (transcript view or cue rows) ▸ Ask AI sheet ▸ preset or free text ▸ inline disclosure ▸ Send ▸ one batch ▸ diff inline ▸ Accept (one command) or Reject or Try again (a new plan and disclosure).

**(c) Translation.** Track menu ▸ Translate… ▸ target language and options ▸ sentence groups ▸ batches ▸ disclosure ▸ Send ▸ per group translation ▸ aligner (proportional pseudo-times → AI-11 segmenter with the target profile) ▸ side-by-side review ▸ **Create track** (one `AddDerivedSubtitleTrack`).

**(d) Key test.** Provider sheet ▸ Test key ▸ `ProviderProbeConsent` ▸ list-models GET (no content) ▸ `valid(models) | keyInvalid | quotaExceeded | offline | …`.

### 3.8 Threading and isolates

| Work | Where |
|---|---|
| Span algebra on one cue, style commands, review accept | UI isolate (≤ 1 ms per cue) |
| Diffs for review lists > 500 cues, WAV slicing, base64, request body building > 256 kB, response JSON parse > 256 kB, translation alignment and re-segmentation, s1→s2 migration (decode isolate, as ARCH §8.5) | `Isolate.run` |
| HTTP | UI isolate async I/O (`HttpClient`), at most 2 in flight per provider |
| Speech-clip extraction | native engine job queue (v1, interactive priority) |
| Sprite rasterization (rich, karaoke) | v1 pre-pass in ≤ 4 ms UI slices (API-04) |
| Key store | platform main thread through Pigeon; Android Keystore crypto on a background executor |

**App lifecycle.** On iOS backgrounding, requests already in flight may fail when sockets are suspended. They come back as `connectionLost(maybeReceived: true)` and the job pauses. On foreground, the job asks "Continue sending?", which re-sends the identical bytes the disclosure already covers. On Android, long jobs (more than 3 batches) hold a `BackgroundLeaseProvider` lease, the same foreground service as v1 captions, and keep running.

### 3.9 Offline behaviour and error states

Everything except sending works offline. The editor never pre-checks connectivity, because a DNS lookup would itself be network use. A failure is mapped after the attempt:

| `AiFailure` | User copy (`ai_failure_copy.dart`) | Action |
|---|---|---|
| offline | "You're offline. Nothing was sent." | Try again |
| connectionLost | "The connection dropped. {Provider} may have received part of the request." | Try again |
| timeout | "{Provider} didn't answer in time." | Try again |
| keyMissing | "Add your {Provider} key in Settings › AI Studio." | Open settings |
| keyInvalid | "{Provider} didn't accept this key." | Open settings |
| quotaExceeded | "Your {Provider} quota or credit is used up. Check your {Provider} account." | – |
| rateLimited | "{Provider} is limiting requests. Trying again in {n} s." / "Try again later." | auto / Try again |
| modelUnavailable | "This model isn't available for your key." | Choose model |
| requestTooLarge / truncated | "This is too much for one request. Try fewer captions." | Retry with smaller batches |
| contentBlocked | "{Provider} declined {n} of {m} batches. The other suggestions are ready." | Review |
| malformedResponse | "{n} replies couldn't be read." | Retry batch |
| keysLost (key store) | "Your saved keys are no longer readable on this device. Add them again." | Open settings |

Partial results are always kept and reviewable ("38 of 40 batches done").

### 3.10 Testing strategy

| Layer | What | Ticket |
|---|---|---|
| Core unit and property | span algebra (1,000 seeded random edits: unchanged graphemes keep their style; split∘merge = identity; remap of the identity edit = identity); invariants I10/I11 and repair; every new command with goldens and rejections; codec round trip; s1→s2 on every s1 fixture; header classification; SRT/VTT corpus with `parse(serialize(x)) == x` under each option; emoji corpus | AIS-02 … AIS-07 |
| Fuzzer | CORE-34's random command sequences extended with rich-cue commands (validator after each step, undo/redo identity, JSON round trip) | AIS-05 (adds generators; CORE-34 harness unchanged) |
| Providers | **No real network**: each AI package's test bootstrap installs `HttpOverrides` that throw on any non-loopback host (`test/support/no_network.dart`). Transport tests use an in-process `HttpServer` on 127.0.0.1 with a fake clock (retries, backoff, Retry-After, timeouts, cancel, redirect refusal, host refusal, hash refusal). **Contract tests per provider use fixtures written by hand from the providers' public API references, never downloaded or recorded from live traffic**: golden request (method, path, headers with the key redacted, body JSON), and responses for success, schema-mode output, invalid JSON, schema-invalid, 400, 401, 403, 404 model, 413, 429 rate, 429/402 quota, 500, safety block and length-truncated | AIS-08 … AIS-10 |
| AI Studio | plan determinism (same project → same batches and hashes); disclosure = payload; no send without consent; validators per contract with fixtures of good, bad and adversarial outputs (unknown ids, extra fields, injected markup, too-long text, disallowed emoji); aligner properties (no overlap, grid edges, min/max duration, every group's text fully placed); sidecar persistence and stale detection | AIS-28 … AIS-30 |
| Rendering goldens | rich runs, decorations, highlight, per-run outline and shadow, karaoke frames, RTL/Arabic/Devanagari/Thai/mixed bidi, emoji. **Preview overlay vs sprite raster within 1 px** (extends UX-19's AC). Bundled test fonts are loaded with `FontLoader` (no system fallback in goldens) | AIS-13, AIS-16, AIS-39 |
| Compile | compile goldens for placement, karaoke `#k` layers and reveal keys; contract fixture `karaoke_cue.json` decoded by Dart, Swift and Kotlin suites | AIS-14 |
| Widget | every new surface and state with `FakeAiStudioService`, `FakeLlmProvider`, `InMemoryKeyStore`; matrix tests at 280–1280 px and 0.85–1.35 text scale; `expectOwnerUiRules`; semantics | AIS-17 … AIS-35 |
| Architecture | consent call sites, `HttpClient` construction site, host allow-list, no `?key=`, no logging of content, dependency rules 9–15 | AIS-01, AIS-37 |
| Network guard | an `HttpOverrides` spy through the real wiring: AI Studio off → zero requests in a full editor session; on → zero before Send; the first request goes to the chosen host only | AIS-37 |
| On-device E2E | iOS Simulator and Android Emulator with a **loopback fake provider** (`DANAVIEW_AI_FAKE_HOST`) | AIS-38 |
| Live | manual, the owner's keys, outside CI, checklist only; never commits keys or content | AIS-40 |

---

## 4. UX

### 4.1 Rules (binding, from ARCH §1.3, §17.9 and ux.md §6.7)

- Custom kit components only (no Material chrome). Figtree for every piece of chrome. Dark UI. Solid surfaces with soft shadows. Rounded-rectangle text buttons; only single-icon buttons are round.
- Computed contrast ≥ 4.5:1. Touch targets ≥ 44×44. Semantics on everything painted. Announcements throttled through `editorAnnounce()`. Reduced motion honoured.
- No overflow at widths 280–1280 and text scale 0.85–1.35, including the keyboard-inset cases. Toolstrips scroll and never wrap. Panels have a fixed header and a scrollable body.
- Flows that are modal use `showDanaviewSheet` (AI Studio, Ask AI, Translate, font import, presets, emoji review). Ongoing work uses inspector panels (Transcript, Review, Cue), as a dock in `compactPortrait` and a side pane elsewhere (ARCH §17.2).
- **User colours in the transcript.** User text colours are never used as the transcript's text colour on the dark UI, because they could fail contrast. Colour is shown as a 3 px underline bar in the span colour. Highlight is shown as a tinted chip whose text colour is computed with `DanaviewColors.foregroundOn`. Fonts and sizes appear as small badges ("Bebas · 120%"). The preview shows the true look.

### 4.2 Entry points and gating

| Condition | What the user sees |
|---|---|
| `DANAVIEW_AI_STUDIO=false` (development default) | Rich subtitles, transcript, fonts, presets, karaoke, emoji tools. **No** AI Studio row, buttons or Ask AI |
| Flag on, master switch off (default) | Same as above, plus Settings › Video editor › **AI Studio** row (off) |
| Master switch on, no provider key | AI buttons visible. Pressing one opens the "Add a provider" empty state, which links to Settings |
| On, at least one provider ready | Captions tool header: **AI Studio**, **Translate**; selection bars: **Ask AI**; a Review badge with the pending count |

### 4.3 Screens, sheets and panels

Each AI surface has these states: empty, loading, error, offline, key invalid, quota exceeded. Partial, rate-limited and blocked states appear where they apply.

**U1 · Settings › Video editor › AI Studio** (`/settings/editor/ai`, `AiSettingsScreen`, AIS-31)
- Header switch "Use AI Studio with my own key" (off). Below it, a plain explanation: "Off: everything stays on this device. On: you can send captions you choose to an AI provider using your own account. Nothing is sent until you tap Send."
- Provider rows: Google Gemini, OpenAI, Anthropic Claude, OpenRouter, xAI Grok. Each shows its status chip ("Not set up", "Key saved ··ab3f", "Checked 2 min ago", "Key not accepted") and default model.
- Sections: "Default provider", "This month on this device" (tokens in and out per provider, Reset), "Names and terms" help.

| State | Shown |
|---|---|
| Off | explanation only; provider rows disabled |
| On, empty | "Add a key for at least one provider to use AI Studio." |
| keysLost | banner "Saved keys can't be read on this device any more. Add them again." |

**U2 · Provider sheet** (`provider_sheet.dart`, AIS-31; the only `ProviderProbeConsent.accepted(` site)
- Disclosure paragraph: provider, host, "Their terms and privacy policy apply. Some free plans may use requests to improve their models." with an "Open {Provider} privacy policy" button that opens the system browser.
- `DanaviewTextField` for the key: obscured, paste button, show/hide while typing. After saving, only `··` plus the last four characters is shown. No copy-out.
- Model row (opens U3). **Test key** (one-line disclosure: "Contacts {host} with your key. No captions are sent."). **Remove key** (confirm).

| State | Shown |
|---|---|
| empty | key field, Save disabled |
| loading | Test key shows a spinner (kit `DanaviewSpinner`) and "Checking…" |
| valid | "Key works · {n} models available" |
| key invalid | "{Provider} didn't accept this key." |
| quota exceeded | "Key works, but your quota or credit is used up." |
| offline | "You're offline. The key was saved but not checked." |
| rate limited | "{Provider} is busy. Try again in a moment." |

**U3 · Model picker** (sheet with a search field)
- Rows show the curated models first, then loaded models, with capability chips "Text", "Listens to audio", "Structured replies".
- "Load models" (probe consent) and "Use a model id…" (free text).
- States: loading, offline, error, empty ("No models found for this key").

**U4 · Captions tool header** (extends UX-31's panel through AIS-17)
- Buttons: Auto captions (v1), Add, **Transcript**, **AI Studio**, **Translate**, menu. A Review badge appears when suggestions are pending.
- The track menu gains: Style presets…, Karaoke…, Speakers…, Remove all emojis…, Review emojis…, Translate…

**U5 · AI Studio sheet** (`showDanaviewSheet(title: 'AI Studio')` with `DanaviewStepIndicator`, AIS-32)
1. **Action**: Clean up the transcript · Detect emotion and tone · Add emojis · Label speakers · Emotion styles. Translate opens U10.
2. **Options**: track; scope (whole track, selected cues, current range); provider and model.
   - Clean up: punctuation and capitals, spelling, names and terms (glossary field), "Remove filler words" (off).
   - Emotion: "From the text" or "From the voice" (disabled with a reason when the model has no `audioInput`); "Also add emojis" (density none/light/heavy); "Also turn on emotion styles".
   - Emojis: density; source "From emotions (no request)" or "Let AI choose".
   - Speakers: max speakers (2–8); from text or voice.
3. **What will be sent** (U6, then Send).
4. **Progress**: batches `n/m`, a `DanaviewProgressBar`, Cancel ("Stop. Results so far are kept.").
5. **Result**: "290 suggestions ready", with Review now and Later.

| State | Shown |
|---|---|
| empty | "Add or generate captions first." with Auto captions and Add caption buttons |
| no provider | "Add a key in Settings › AI Studio." |
| loading (planning, extracting audio) | "Preparing… extracting 312 audio clips" |
| error, offline, key invalid, quota exceeded | §3.9 copy, with partial results kept |

**U6 · Send disclosure** (`ai_send_view.dart`, shared by U5, U9 and U10; the only `AiSendConsent.accepted(` site)

```
Send to Google Gemini
generativelanguage.googleapis.com · gemini-…
What's sent    The text of 312 captions (about 9,000–12,000 tokens; replies up to 14,000)
               312 audio clips of the voice (18 min, 35 MB)
Not sent       Video pictures, file names, the project name, your profile
               Your Gemini account is billed by Google under its terms.
[ Cancel ]                                   [ Send ]
```

When there are more than 200k estimated tokens, Send needs a second tap. Rows wrap; nothing truncates numbers.

**U7 · Pending-results banner**: "You have 120 AI suggestions to review" when a project opens with a sidecar. Actions: Review, Discard all (confirm).

**U8 · Review panel** (`SubtitlesPanelSection.review`, AIS-33)
- Filter chips by action and state.
- Rows: cue time, a diff (removed text struck through and announced "removed: …", added text underlined and announced "added: …"; colour is never the only signal), emotion and speaker chips, emoji inserts.
- Row actions: Accept, Reject, Edit (opens the text in the rich editor before accepting), Report a problem (D-63).
- Header: Accept all, Reject all (confirm), Previous/Next. A "Preview" toggle shows the suggestion on the preview without committing it (ghost project to the overlay only; nothing reaches PlanSync).
- Stale rows: "Changed since suggested" with Re-check or Dismiss.
- Empty: "Nothing to review." Undo works after every accept (snackbar-like kit toast "Accepted · Undo").

**U9 · Ask AI sheet** (AIS-34)
- Chips: Translate (language), Fix grammar, Shorten, Change tone ▸, Add emojis, Remove emojis (local).
- "Ask…" text field (500 characters); inline disclosure line ("Sends 2 captions (about 60 tokens) to OpenAI · gpt-…") with Send.
- The result is an inline diff with Accept, Reject, Try again.
- States: loading, error/offline/key invalid/quota per §3.9; "no change" ("The AI suggested no changes.").

**U10 · Translate sheet** (AIS-35)
- Steps: language search (endonym plus English name, recent languages first); options ("Keep line timing" off, "Keep emojis" on, formality default/formal/informal where the language has it); disclosure; progress; **side-by-side review** (source and translation rows, edit inline, reject lines); **Create track**.
- Errors per §3.9. Partial translation offers "Create track with 280 of 312 lines" or "Retry missing".

**U11 · Transcript view** (`SubtitlesPanelSection.transcript`, AIS-17)
- A virtualized list of rows: tabular timestamp `00:01:12.08` (tap seeks exactly and the player stays paused), speaker chip, emotion chip, rich text.
- The current line under the playhead is highlighted and auto-follows while playing; scrolling by hand pauses follow, and a "Follow" chip resumes it.
- Tapping the text edits it in place (`RichCueEditor`, one active editor at a time). Enter inserts a line break, ⌘/Ctrl+Enter splits at the cursor, Backspace at the start merges with the previous line (confirm-free, undoable).
- Long-press or Shift-click enters line selection: a bar with Ask AI, Style, Speaker, Delete, Merge.
- "Find in transcript" field.
- Empty state: "No captions on this track yet." Keyboard up: the dock pins above it (ux.md §10.8).

**U12 · Style toolbar** (AIS-18; above the keyboard or in the dock header; scrolls horizontally at narrow widths)
- B, I, U, S, Font (U16), Size (−/+ and value), Colour, Highlight, Outline, Shadow, Clear styling, Ask AI.
- Applies to the selected range, or to the whole cue(s) when there is no range. ⌘B, ⌘I and ⌘U work in the editor.

**U13 · Cue section** (`SubtitlesPanelSection.cue`, AIS-18)
- Placement: Track default / Top / Middle / Bottom / Custom, with "Drag the caption on the preview" when Custom is chosen.
- Alignment.
- "Style for this line": the override rows with **Reset to track style**.
- Speaker (picker plus "Edit speakers…": rename, colour, merge, delete). Emotion (chip with label and intensity, edit or clear; shows the source).
- Word timings: "Timed", "Estimated" or "None", with Estimate timings.
- Timing tools (AIS-19): start/end ±1 frame and ±100 ms, Set to playhead, Snap to speech, Split at cursor, Merge with previous/next.

**U14 · Karaoke section** (AIS-20; track menu ▸ Karaoke…)
- Mode Off / Progressive / Fill; highlight colour, glyph background, outline colour.
- Info: "Word timings: 290 timed, 22 estimated", with Estimate missing timings.
- Loop preview of the current cue.

**U15 · Emoji tools** (AIS-20)
- "Remove all emojis…": confirm with counts, choice of "Only emojis added by AI (24)" or "All emojis (31)", and a note when cues will become empty.
- "Review emojis": a stepper sheet, cue by cue (the preview seeks), with Remove this emoji, Keep, Next. Empty: "No emojis on this track."

**U16 · Font picker v2** (AIS-25)
- Search; tabs All / Favourites / Recent / Imported.
- Script filter chips (Latin, Arabic, Hebrew, Devanagari, Bengali, Tamil, Telugu, Thai, CJK (system), …).
- Rows render a live preview of the current selection's text (or the cue text, or the family name) in that font, with a star toggle and a script badge.
- "Import font…" runs the picker (AIS-24), validation, the rights reminder (D-61) and a done toast.
- Manage fonts lives in Settings › Video editor › Fonts: rename the display name, delete ("Used in 2 projects. Captions using it will show in Figtree.").
- Errors: "This file isn't a font Danaview can use (.ttf or .otf)." · "Font files up to 30 MB are supported." · "This font couldn't be loaded."
- Empty states per tab.

**U17 · Style presets sheet** (AIS-26)
- Grid of tiles: a sample caption rendered with `TextLayoutEngine` over a neutral gradient, with the name and a "Built-in" badge.
- Actions: Apply to track, Save current style as preset, Rename, Duplicate, Delete (confirm). The track shows a "Modified" chip when it has diverged.
- Empty "My presets": "Save a track's style to reuse it in any project."

**U18 · Subtitle files and export** (AIS-21)
- The SRT/VTT export sheet gains "Keep basic styling", "Speaker names", "Karaoke timings (VTT)" and "RTL marks".
- The import result lists the mapped styles and speakers.
- In the export sheet, translated tracks are labelled "Spanish (translated)", and burn-in and side files can be chosen per track, as in v1.

**U19 · Banners and toasts**: migration toast (D-53), missing fonts (D-61), pending suggestions (U7).

### 4.4 Action registry additions (AIS-01 extends `contracts/action_ids.dart`; handlers in new binding files)

`aiStudio, askAi, translateTrack, reviewAiChanges, transcriptView, cueStyleBold, cueStyleItalic, cueStyleUnderline, cueStyleClear, cuePlacement, splitCueAtCursor, mergeCueWithPrevious, snapCueToSpeech, estimateWordTimings, karaokeSettings, speakers, removeEmojis, reviewEmojis, subtitlePresets, importFont`.

Shortcuts: ⌘B/⌘I/⌘U (inside the rich editor only), ⌘/Ctrl+Enter (split at the cursor), ⌘⇧A (Ask AI on the selection, when AI Studio is on), T (Transcript view, outside text fields). The UX-15 focus guard applies.

`SubtitlesPanelSection` gains `transcript`, `review`, `cue`. New preview mode: cue drag (in `manipulation_overlay.dart`).

### 4.5 Accessibility

- Diff rows announce "removed" and "added" text.
- Karaoke and emotion colours are content, not state indicators.
- Every chip has a text label. Rich-editor style buttons are toggle buttons with semantics state.
- The cue drag on the preview has the semantic actions "Move caption up / down / to top / to middle / to bottom".
- The disclosure is read as a group before Send.
- QA (AIS-38) covers VoiceOver and TalkBack passes on U1, U5, U6, U8, U9, U11 and U16.

---

## 5. Tickets

### 5.1 Process rules for 1.2.0 (in addition to BP §1–§2)

1. **Read first:** ARCH §1–§4, §6, §10.3, §11, §16, §17, §20, then this plan's §2–§4 and the v1 files your ticket extends.
2. **Extends.** A 1.2.0 ticket may edit a v1 file only if its Owns lists the file with "(extends <v1 ticket>)". It keeps the v1 file's `// OWNER:` header and appends `// EXTENDED: AIS-xx`. It must not change behaviour that v1 tests pin unless the Spec says so, in which case it updates those tests.
3. **Skeleton.** AIS-01 creates D-33 placeholders (`// OWNER: AIS-xx`) for every new file in §3.2, the new `part` files and the new binding and string files.
4. **Definition of done** = BP §1 rule 4, plus:
   - AI packages pass `test/support/no_network.dart` (no non-loopback host in any test);
   - nothing logs keys, captions, prompts, responses or audio;
   - every UI surface has matrix tests for each state in §4.3.
5. **Flags.** `DANAVIEW_AI_STUDIO` defaults to false; AIS-41 flips release builds. Rich-subtitle work is not flagged (D-65).
6. **Fixtures for providers are hand-written** from the public API references and marked with the reference URL and date in a comment. Live traffic is never recorded into fixtures.

### 5.2 Milestones

| Milestone | Name | Scope | Exit criteria | Tickets |
|---|---|---|---|---|
| **S1** | Foundations and contracts | Skeleton, rich cue model, text algebra, schema 2 + migration, commands, SRT/VTT v2, provider layer and adapters, key store plugin | Core green with rich-cue property tests; s1 fixtures migrate; providers' contract tests green with no network; key store native tests on simulator and emulator | 11 |
| **S2** | Rich subtitles: rendering and editing | Layout spec v2, render prep v2, lowering v2 (karaoke), word timings from Auto captions, preview overlay v2 and cue drag, transcript view, style toolbar and cue section, timing tools, karaoke and emoji tools, subtitle file options | Rich, karaoke and placed cues look the same in preview and export on simulator and emulator; transcript editing works end to end; no network used | 10 |
| **S3** | Fonts and presets | Bundled Noto expansion and catalog v2, sfnt inspector and stores, engine font pick kind, font picker v2 and import, style presets; conditional CJK packs | Size budget met and recorded; imported fonts render in preview and export; presets reusable across projects | 6 (1 conditional) |
| **S4** | AI Studio | Studio core, contracts I and II (incl. translation alignment), settings, Studio sheet and disclosure, review, Ask AI, translate flow | All AI flows pass widget tests with fakes; disclosure equals payload; nothing is applied without review | 8 |
| **S5** | Integration, legal, QA, release | Legal texts, app wiring v3 and network guard, E2E with fake provider, render parity and performance, live provider validation, release | §6.4 text shipped; network guard green; E2E certified on iOS Simulator and Android Emulator; live checklist passed; release flags | 6 |
| **S1+** | Added to S1 on 2026-10-16 | Genkit spike (the first provider ticket), shared `danaview_ai` layer and `danaview_ai_ui` | Spike report with the go/no-go of D-70b; one switch and one send view used by the editor | 2 (AIS-42, AIS-43) |
| **S6** | Multi-speaker transcription and AI search (2026-10-16) | Diarization model pack and plugin, pipeline, word-to-speaker and overlaps, per-speaker lanes and UI, cloud diarization; on-device search index, search UI, query to filters, deep indexing; QA | Overlapping speech gives separate per-speaker cues on the eval set; the index answers the search eval set offline; AI search sends only what its disclosure shows | 11 (AIS-44…AIS-54) |

### 5.3 Critical path and lanes

**Longest chain** (11 tickets): AIS-01 → AIS-02 → AIS-03 → AIS-05 → AIS-06 → AIS-28 → AIS-29 → AIS-32 → AIS-37 → AIS-38 → AIS-41.

**Parallel lanes** after AIS-01:
- **Core** (AIS-02 … AIS-07).
- **Providers** (AIS-08 → AIS-09 → AIS-10), independent of core.
- **Key store** (AIS-11), native, independent.
- **Rendering** (AIS-12 → AIS-13 → AIS-14, AIS-16) once AIS-03 lands.
- **Transcription** (AIS-15) after AIS-06.
- **UI** (AIS-17 …) after AIS-05.
- **Fonts** (AIS-22 … AIS-26) after AIS-13 and AIS-14.
- **AI Studio** (AIS-28 …) after AIS-06 and AIS-08.

On the two-machine split: AIS-11's Android half, AIS-24's Android half and Android emulator QA belong to the Android lane.

**Added 2026-10-16:**
- **Providers** now start with the Genkit spike: AIS-42 → AIS-08 → AIS-09 → AIS-10.
- **Shared layer** AIS-43 after AIS-08; AIS-28, AIS-31, AIS-32 and AIS-37 wait for it.
- **Diarization** (AIS-44 → AIS-45 → AIS-46 → AIS-47 → AIS-48; AIS-49 after AIS-46 and AIS-28) after AIS-15. The native halves of AIS-45 split across the Mac and Android lanes.
- **Search** (AIS-50 → AIS-51 → AIS-52, AIS-53) needs HOM-16, HOM-17 and HOM-19 from the Files & Media Home plan; AIS-50's ML Kit half is Android-lane work.
- AIS-54 closes S6 and feeds AIS-41.

### 5.4 Ticket index (dependency-ordered)

Any prefix of this list has all its dependencies satisfied. v1 dependencies are satisfied because 1.2.0 starts after INT-05. **Exception since 2026-10-16:** AIS-42 and AIS-43 are numbered at the end but run early (AIS-42 before AIS-08, AIS-43 before AIS-28); the rows below say so in "Depends on".

| # | Ticket | Milestone | Area | Title | Depends on |
|---|---|---|---|---|---|
| 1 | **AIS-01** | S1 | Integration | [INTEGRATION] 1.2.0 foundations: packages, placeholders, contracts, dependency rules, flag, CI | INT-05, UX-01, INT-01, CORE-01, CORE-09 |
| 2 | **AIS-02** | S1 | Core (pure Dart) | Rich cue model, track additions, invariants and repair | AIS-01, CORE-03, CORE-08 |
| 3 | **AIS-03** | S1 | Core (pure Dart) | Cue text algebra, markup conversion and emoji scanner | AIS-02, CORE-07 |
| 4 | **AIS-04** | S1 | Core (pure Dart) | Project schema 2, codec, JSON Schema, s1→s2 migration | AIS-02, AIS-03, CORE-22, CORE-23 |
| 5 | **AIS-05** | S1 | Core (pure Dart) | Span-aware subtitle commands and style/placement commands | AIS-02, AIS-03, CORE-15, CORE-19, CORE-34 |
| 6 | **AIS-06** | S1 | Core (pure Dart) | AI batch commands, derived tracks, speakers, emoji removal | AIS-05 |
| 7 | **AIS-07** | S1 | Core (pure Dart) | SRT/VTT codec v2 and subtitle file options | AIS-03, CORE-20, CORE-33 |
| 8 | **AIS-08** | S1 | AI providers | Provider contracts, transport, consent tickets, retries, rate limits, tokens, JSON, fake server | AIS-01, AIS-42 |
| 9 | **AIS-09** | S1 | AI providers | OpenAI-compatible base, OpenAI and Gemini adapters with hand-written fixtures | AIS-08 |
| 10 | **AIS-10** | S1 | AI providers | Anthropic, OpenRouter and xAI adapters with hand-written fixtures | AIS-09 |
| 11 | **AIS-11** | S1 | Native (iOS + Android) | danaview_secure_keys plugin: Keychain and Keystore-wrapped key store | AIS-01 |
| 12 | **AIS-12** | S2 | Core (pure Dart) | Text layout spec v2: rich runs, effective style, placement, karaoke evaluation | AIS-02, AIS-03, CORE-07 |
| 13 | **AIS-13** | S2 | Engine (Dart) | Render prep v2: per-run styles, decorations, karaoke highlight sprite, script rules, fallbacks | AIS-12, API-04 |
| 14 | **AIS-14** | S2 | Core (pure Dart) | Lowering v2: per-cue placement, karaoke layers, sprite variants, contract fixture | AIS-12, CORE-29, CORE-30, CORE-31 |
| 15 | **AIS-15** | S2 | AI (transcription) | Word timings on generated cues (segmenter and pipeline) | AIS-06, AI-11, AI-13 |
| 16 | **AIS-16** | S2 | UI/UX | Preview overlay v2 and on-preview cue placement | AIS-13, AIS-05, UX-19, UX-22 |
| 17 | **AIS-17** | S2 | UI/UX | Transcript view and rich cue editor | AIS-05, UX-31, UX-14 |
| 18 | **AIS-18** | S2 | UI/UX | Style toolbar, cue section, speakers and emotion editing | AIS-17, AIS-16, AIS-06, UX-30 |
| 19 | **AIS-19** | S2 | UI/UX | Timing tools: snap to speech, split/merge at cursor, nudges | AIS-15, AIS-17, UX-13, UX-21, CORE-18 |
| 20 | **AIS-20** | S2 | UI/UX | Karaoke settings and emoji tools | AIS-14, AIS-16, AIS-17, AIS-06 |
| 21 | **AIS-21** | S2 | UI/UX | Subtitle file import/export options and export sheet labels | AIS-07, UX-32, UX-39 |
| 22 | **AIS-22** | S3 | UI/UX | Bundled font expansion and FontCatalog v2 | AIS-13, AIS-14, UX-30 |
| 23 | **AIS-23** | S3 | Core (pure Dart) | Font file inspector, font library store, preset store, built-in presets | AIS-02, CORE-24, CORE-25 |
| 24 | **AIS-24** | S3 | Integration | [INTEGRATION] Engine font pick kind (API, Pigeon, iOS, Android) | AIS-01, API-01, ENG-03, ENG-06, IOS-15, AND-14 |
| 25 | **AIS-25** | S3 | UI/UX | Font picker v2, font import flow, manage fonts, missing fonts | AIS-22, AIS-23, AIS-24 |
| 26 | **AIS-26** | S3 | UI/UX | Subtitle style presets sheet and controller | AIS-23, AIS-18, AIS-13 |
| 27 | **AIS-27** | S3 | UI/UX | On-demand CJK font packs (conditional: only on D-60 option b) | AIS-22, AIS-25, AI-09 |
| 28 | **AIS-28** | S4 | AI Studio | AI Studio core: service, planning, batching, job runner, suggestions, audio clips, usage | AIS-06, AIS-08, AIS-43, AI-08, AI-12 |
| 29 | **AIS-29** | S4 | AI Studio | Action contracts I: clean-up, emotion, emoji, speakers | AIS-28, AIS-03 |
| 30 | **AIS-30** | S4 | AI Studio | Action contracts II: Ask AI and translation with alignment | AIS-28, AIS-15, AI-11 |
| 31 | **AIS-31** | S4 | UI/UX | AI Studio settings: switch, providers, keys, model picker, test key, usage | AIS-28, AIS-43, UX-04 |
| 32 | **AIS-32** | S4 | UI/UX | AI Studio sheet, send disclosure, progress and error states | AIS-29, AIS-31, AIS-43, AIS-17 |
| 33 | **AIS-33** | S4 | UI/UX | Review mode panel | AIS-28, AIS-16, AIS-17 |
| 34 | **AIS-34** | S4 | UI/UX | Ask AI on selection | AIS-30, AIS-32, AIS-33, AIS-18 |
| 35 | **AIS-35** | S4 | UI/UX | Translate track flow and side-by-side review | AIS-30, AIS-32, AIS-33 |
| 36 | **AIS-36** | S5 | UI/UX | Privacy policy, terms and licences for 1.2.0 | UX-42 |
| 37 | **AIS-37** | S5 | Integration | [INTEGRATION] App wiring v3: AI Studio, key store, audio clips, routes, network guard | AIS-09, AIS-10, AIS-11, AIS-25, AIS-28, AIS-31, AIS-32, AIS-36, AIS-43, INT-04 |
| 38 | **AIS-38** | S5 | QA | On-device E2E with a loopback fake provider, overflow matrix, accessibility | AIS-37, AIS-19, AIS-20, AIS-21, AIS-26, AIS-33, AIS-34, AIS-35 |
| 39 | **AIS-39** | S5 | QA | Render parity (rich text, scripts, karaoke, emoji) and performance budgets | AIS-37, AIS-14, AIS-16, AIS-22, AIS-25 |
| 40 | **AIS-40** | S5 | QA | Live provider validation (manual) and store evidence | AIS-37 |
| 41 | **AIS-41** | S5 | Integration | [INTEGRATION] Release 1.2.0: flags, version, store metadata, privacy labels, docs | AIS-38, AIS-39, AIS-40, AIS-36, AIS-37, AIS-54 (+ AIS-27 if scheduled) |
| 42 | **AIS-42** | S1+ | AI providers | **Spike:** Genkit Dart 1.0 behind `LlmProvider` (first provider ticket; runs before AIS-08) | AIS-01 |
| 43 | **AIS-43** | S1+ | Integration | [INTEGRATION] Shared `danaview_ai` layer, `danaview_ai_ui` (send view, settings), app-level switch, feature registry | AIS-01, AIS-08 |
| 44 | **AIS-44** | S6 | AI (diarization) | **Spike:** sherpa-onnx diarization on device: models, licences, sizes, overlap output, speed | AIS-01, AI-10 |
| 45 | **AIS-45** | S6 | Native (iOS + Android) | `danaview_diarization` plugin and the consented speaker-model download | AIS-44, AI-09 |
| 46 | **AIS-46** | S6 | AI (diarization) | Diarization pipeline, word-to-speaker assignment and overlap cues | AIS-45, AIS-15 |
| 47 | **AIS-47** | S6 | Core (pure Dart) | Per-speaker subtitle lanes: model, commands, lowering, SRT/VTT rules | AIS-46, AIS-06, AIS-07, AIS-14 |
| 48 | **AIS-48** | S6 | UI/UX | Speaker lanes UI: generate with speakers, lane styles, rename/merge, overlap review | AIS-47, AIS-18 |
| 49 | **AIS-49** | S6 | AI Studio | Cloud diarization contract `dv.diarize.v1` behind Send | AIS-46, AIS-28, AIS-29 |
| 50 | **AIS-50** | S6 | Search | On-device search index: `danaview_media_analysis` plugin, extractors, index store | AIS-01, HOM-16, HOM-17 |
| 51 | **AIS-51** | S6 | Search | Search engine and Home search UI over the index | AIS-50, HOM-19 |
| 52 | **AIS-52** | S6 | Search + AI Studio | AI search (a): query to filters, `dv.search.filters.v1` | AIS-51, AIS-43, AIS-28 |
| 53 | **AIS-53** | S6 | Search + AI Studio | AI search (b): deep indexing per folder, descriptions and embeddings | AIS-52 |
| 54 | **AIS-54** | S6 | QA | Diarization and search eval sets, network guard extension, on-device E2E | AIS-48, AIS-49, AIS-53, AIS-37 |

### 5.5 Tickets

### S1: Foundations and contracts

#### AIS-01 · [INTEGRATION] 1.2.0 foundations: packages, placeholders, contracts, dependency rules, flag, CI

- **Milestone:** S1 · **Area:** Integration
- **Depends on:** INT-05, UX-01, INT-01, CORE-01, CORE-09
- **Owns:**
  - `packages/danaview_ai_providers/{pubspec.yaml, analysis_options.yaml, lib/danaview_ai_providers.dart, lib/testing.dart}`
  - `packages/danaview_ai_studio/{pubspec.yaml, analysis_options.yaml, lib/danaview_ai_studio.dart, lib/testing.dart}`
  - `packages/danaview_editor_core/lib/{model,ops,eval,formats,plan,codec,store}.dart` (extends CORE-01: export lines for the new files)
  - `packages/danaview_editor_core/lib/src/ops/edit_command.dart` (extends CORE-09: `part` directives for `rich_cue_commands.dart`, `ai_cue_commands.dart`)
  - `packages/danaview_editor/pubspec.yaml` (extends UX-01)
  - `packages/danaview_editor/lib/src/editor/contracts/action_ids.dart`, `inspector_routes.dart`, `tool_ids.dart` (extends UX-01)
  - `packages/danaview_editor/lib/src/editor/wiring/action_bindings.dart` (extends UX-01)
  - `packages/danaview_editor/lib/src/app/editor_providers.dart`, `editor_availability.dart` (extends UX-01)
  - `test/architecture/dependency_rules_test.dart` (extends INT-01)
  - `packages/danaview_editor/test/architecture/ai_call_sites_test.dart`
  - `.github/workflows/editor-ci.yml` (extends INT-01), `scripts/ci/editor/ai.sh`
  - `docs/v1.1/editor/ARCHITECTURE.md` ([INTEGRATION]: D-45…D-70 with the owner's answers, §4 additions)
- **Spec:**
  - **Placeholders (D-33)** for every new file in §3.2 and for the new binding and string files, each with `// OWNER: AIS-xx`.
  - **Manifests.**
    - `danaview_ai_providers`: `meta`, `collection`, `crypto`; dev `test`.
    - `danaview_ai_studio`: `flutter` (because `danaview_transcription` needs it), `characters`, `collection`, `meta`, `path`, `danaview_editor_core`, `danaview_transcription`, `danaview_ai_providers`.
    - `danaview_editor` adds `danaview_ai_studio` and `danaview_ai_providers`.
    - The `danaview_secure_keys` package is created whole by AIS-11.
  - **Contracts.**
    - The new `EditorActionId`s of §4.4 (groups: tools / editing).
    - `SubtitlesPanelSection.{transcript, review, cue}`.
    - The `aiStudioFlag` constant (`bool.fromEnvironment('DANAVIEW_AI_STUDIO')`).
    - Root providers `aiStudioServiceProvider` (default `AiStudioOff`), `fontLibraryProvider`, `subtitlePresetStoreProvider`, overridden by `EditorBootstrap` (AIS-37).
  - **Merge** the new binding files in `wiring/action_bindings.dart`.
  - **Dependency rules 9–15 (§3.1)** in the root architecture test. The call-site tests for `AiSendConsent.accepted(` and `ProviderProbeConsent.accepted(` are in the editor's architecture test.
  - **CI.** An `ai-dart` CI job runs `scripts/ci/editor/ai.sh` (analyze and test both AI packages).
  - **ARCH.** Record D-45…D-70 with the owner's answers.
- **Acceptance criteria and tests:**
  - Every new package analyzes and tests green with placeholders.
  - The architecture tests fail on a planted violation of each rule, then pass.
  - With `DANAVIEW_AI_STUDIO=false`, a widget test shows no AI action in the registry, tool sets or settings.
  - The editor compiles and the v1 test suite is unchanged.
  - The CI job runs on PRs touching the AI packages.

#### AIS-02 · Rich cue model, track additions, invariants and repair

- **Milestone:** S1 · **Area:** Core (pure Dart)
- **Depends on:** AIS-01, CORE-03, CORE-08
- **Owns:**
  - `packages/danaview_editor_core/lib/src/model/cue_rich.dart`
  - `packages/danaview_editor_core/lib/src/model/items.dart` (extends CORE-03)
  - `packages/danaview_editor_core/lib/src/model/subtitle.dart` (extends CORE-03)
  - `packages/danaview_editor_core/lib/src/model/text_style.dart` (extends CORE-03: `Opt<T>` helper only if shared)
  - `packages/danaview_editor_core/lib/src/validate/` (extends CORE-08)
  - `packages/danaview_editor_core/test/support/random_project.dart` (extends CORE-08)
  - `packages/danaview_editor_core/test/model/rich_cues/`, `packages/danaview_editor_core/test/validate/rich_cues/`
- **Spec:**
  - Types exactly as D-52: `GraphemeRange`, `CueStyleOverride` with `Opt<T>` (inherit | off | value), `CueSpan`, `CuePlacement`, `CueWord`, `CueEmotion` + `EmotionLabel` (D-58) + `EmotionSource`, `Speaker`/`SpeakerId` (`sp_` prefix, ids from `IdGenerator`).
  - `SubtitleCue` gains `spans`, `emojiMarks`, `override`, `placement`, `words`, `emotion`, `speaker`, all with defaults, immutable lists, `copyWith` and equality. `CueOrigin.translated`.
  - `SubtitleTrackData` gains `speakers`, `karaoke` (`KaraokeSettings{mode off|progressive|fill, highlight}`), `direction`, `speakerDisplay`, `emotionStyles`, `presetRef`.
  - `SubtitleStyle` gains `underline`, `letterSpacing`, `lineHeight` (defaults equal to v1's rendering: 0 and `cueLineHeight` 1.2).
  - `CaptionProvenance` gains `translation` (`TranslationProvenance`) and `aiEdits` (`AiEditRecord`, at most 50). `SubtitleCueDraft` gains optional `words` and `spans`.
  - Validator I10 and I11 (§3.3) with `Violation` kinds. `repair()` clamps or drops them with `ProjectOpenWarning`s.
  - `random_project.dart` generates rich cues (spans, words, emotions, speakers, placement) for CORE-34 and benchmarks.
- **Acceptance criteria and tests:**
  - Equality, `copyWith` and defaults tests. Every I10/I11 rule has a failing fixture and a repair test whose output validates.
  - Incremental `only:` validation equals full validation on 500 random rich projects.
  - Validating 3,000 rich cues on one track takes ≤ 2 ms (benchmark, 3× CI factor).
  - v1 tests stay green, because the defaults reproduce v1 cues exactly.

#### AIS-03 · Cue text algebra, markup conversion and emoji scanner

- **Milestone:** S1 · **Area:** Core (pure Dart)
- **Depends on:** AIS-02, CORE-07
- **Owns:**
  - `packages/danaview_editor_core/lib/src/eval/cue_text_ops.dart`
  - `packages/danaview_editor_core/lib/src/formats/emoji.dart`
  - `packages/danaview_editor_core/test/eval/cue_text_ops/`
  - `packages/danaview_editor_core/test/formats/emoji/`
- **Spec:** Pure functions (D-52):
  - `graphemes(text)`;
  - `applyStyle(spans, range, patch)` and `clearStyle(spans, range, fields?)`, which normalize;
  - `remapForEdit(old, new, spans, marks, words) → (spans, marks, words)`: common prefix/suffix plus a grapheme-level Myers diff on the middle, falling back to whole replacement above 2,000 graphemes; inserts inherit the style of the grapheme before them (after, at the start); words in changed regions become estimated with linear interpolation;
  - `splitRich(cue, k, at)` and `mergeRich(a, sep, b)`;
  - `fromMarkup(text)` (`<b> <i> <u> <font color>`) and `toMarkup(plain, spans, dialect srt|vtt|v1)`;
  - `stripEmojis(text, spans, marks, {onlyAiMarked})`, which collapses doubled spaces and trims;
  - `estimateWordTimings(text, duration)`: words split on whitespace, or per grapheme for no-space scripts, proportional to grapheme counts.

  `emoji.dart`: `isEmojiGrapheme` (`Extended_Pictographic` with RGI sequences, keycaps, flags, modifiers, VS16), `emojiAllowList` (about 400 entries, Emoji ≤ 12.0, version table, D-55), and `emojiRangesOf(text)`.
- **Acceptance criteria and tests:**
  - Properties on 1,000 seeded random edits: graphemes outside the changed region keep their style; the identity edit leaves everything unchanged; `merge(split(c, k)) == c` for spans and words; markup round trip.
  - The emoji corpus covers ZWJ families, flags, keycaps, skin tones, text-presentation selectors and lookalikes, with no false positives on CJK punctuation.
  - Remapping 3,000 cues of 80 graphemes takes ≤ 50 ms.

#### AIS-04 · Project schema 2, codec, JSON Schema, s1→s2 migration

- **Milestone:** S1 · **Area:** Core (pure Dart)
- **Depends on:** AIS-02, AIS-03, CORE-22, CORE-23
- **Owns:**
  - `packages/danaview_editor_core/lib/src/codec/project_json.dart` (extends CORE-22)
  - `packages/danaview_editor_core/lib/src/codec/schema_version.dart` (extends CORE-22)
  - `packages/danaview_editor_core/lib/src/codec/migrations/migrations.dart` (extends CORE-23)
  - `packages/danaview_editor_core/lib/src/codec/migrations/s1_to_s2.dart`
  - `packages/danaview_editor_core/schema/project.v2.schema.json`
  - `packages/danaview_editor_core/test/fixtures/projects/s2/`
  - `packages/danaview_editor_core/test/codec_migrations/s1_to_s2/`, `packages/danaview_editor_core/test/codec/rich_cues/`
- **Spec:** D-53.
  - `currentProjectSchema = 2`, `currentProjectMinReader = 1`.
  - Encode and decode every field added by AIS-02 with short keys pinned in `project.v2.schema.json`, following the ARCH §8.2 conventions (defaults omitted, fixed key order, colours `#RRGGBBAA`, unknown enums → default plus warning). Literal-tag rule: write `"sp":[]` when the plain text contains a literal `<b>`, `<i>` or `<u>`.
  - `Migrations.chain` gets its first production step, `s1 → s2` (`parseCueMarkup` → spans; cues that already have `sp` are untouched; unknown keys kept).
  - `project.v1.schema.json` is kept for the s1 fixtures.
  - `FragmentCache` handles the new fields incrementally.
- **Acceptance criteria and tests:**
  - Every existing s1 fixture migrates, validates, re-encodes and round-trips. The migration is idempotent.
  - `decode(encode(p)) == p` on 500 random rich projects, with deterministic bytes.
  - The literal-tag case round-trips without becoming bold.
  - A schema-2 header classified with `supported = 1` gives `readOnlyNewer` (header only).
  - Incremental re-encode after a one-cue style edit at 2,000 items plus 3,000 rich cues takes ≤ 3 ms.
  - The s2 fixtures validate against the schema.
  - No persisted string holds a container path (the CORE-22 test is extended).

#### AIS-05 · Span-aware subtitle commands and style/placement commands

- **Milestone:** S1 · **Area:** Core (pure Dart)
- **Depends on:** AIS-02, AIS-03, CORE-15, CORE-19, CORE-34
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/commands/subtitle_commands.dart` (extends CORE-15)
  - `packages/danaview_editor_core/lib/src/ops/commands/rich_cue_commands.dart`
  - `packages/danaview_editor_core/test/ops/subtitles_rich/`
  - `packages/danaview_editor_core/test/fuzz/rich_cue_fuzz_test.dart`
- **Spec:**
  - **Existing commands made span-aware.**
    - `SetCueText` remaps spans, marks and words (AIS-03).
    - `SplitCue(at, textSplit?)` partitions them.
    - New `SplitCueAtGrapheme(cue, k)`: the time comes from the words, else is proportional, snapped to the grid, and both halves are ≥ 1 frame.
    - `MergeCues` offsets them.
    - `SetCueRange`: moving keeps the relative word times; trimming drops words outside and clamps.
    - `ImportSubtitles` accepts rich drafts.
  - **New commands** (`rich_cue_commands.dart` part, self-dispatching per BP §2):
    - `ApplyCueStyle(cues, range?, patch)`: a null range means the cue-level override. Coalesce key `cuestyle:<cueId>`.
    - `ClearCueStyle(cues, range?, fields?)`.
    - `SetCuePlacement(cues, placement?)`.
    - `SetCueWords(cue, words)`.
    - `SetSubtitleKaraoke(track, settings)`, `SetSubtitleDirection(track, dir)`, `SetSpeakerDisplay(track, mode)`, `SetEmotionStyles(track, on)`.
    - `ApplySubtitlePreset(track, style, karaoke, position, speakerDisplay, emotionStyles, presetRef)`: one entry.
  - Style and placement edits set `editedAfterGeneration` on generated cues. Locked tracks reject.
  - The fuzz test drives the CORE-34 harness with these commands.
- **Acceptance criteria and tests:**
  - Golden tests for every command, including multi-cue (one entry), range splitting and merging spans, word partitioning, the trim policy and locked rejection.
  - Fuzz-lite (200 seeds × 500 steps) green: validator after each step, undo/redo identity, JSON round trip.

#### AIS-06 · AI batch commands, derived tracks, speakers, emoji removal

- **Milestone:** S1 · **Area:** Core (pure Dart)
- **Depends on:** AIS-05
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/commands/ai_cue_commands.dart`
  - `packages/danaview_editor_core/lib/src/ops/commands/caption_commands.dart` (extends CORE-15)
  - `packages/danaview_editor_core/test/ops/ai_cues/`
- **Spec:**
  - `ApplyCueEdits(track, edits: List<CueEdit{cue, baseHash, text?, spans?, marks?, emotion?, speaker?, override?}>, record: AiEditRecord?)`: one entry. Stale items (current hash ≠ `baseHash`) are skipped with an `EditNotice`, and the rest apply atomically. `cueContentHash(cue)` is exported for D-64.
  - `AddDerivedSubtitleTrack(sourceTrack, drafts (rich), data)`: new track directly above the source, `CueOrigin.translated`, burn-in off, provenance as D-57.
  - `SetTrackSpeakers(track, speakers)` (rename, colour, merge maps cues, delete clears them), `AssignSpeaker(cues, speaker?)`.
  - `RemoveEmojis(track, cues?, onlyAiAdded)`: one entry; cues that become empty are deleted, with a notice count.
  - `AddGeneratedCaptionTrack` and `ReplaceGeneratedCaptions` carry the drafts' words and spans.
- **Acceptance criteria and tests:**
  - One history entry each, and undo restores the exact snapshot.
  - The stale-item path is partial with notices.
  - The derived track's display position and language are correct, and the source is untouched.
  - Emoji removal counts and the empty-cue deletion work.
  - Generated tracks keep their words.
  - Locked tracks reject as data.

#### AIS-07 · SRT/VTT codec v2 and subtitle file options

- **Milestone:** S1 · **Area:** Core (pure Dart)
- **Depends on:** AIS-03, CORE-20, CORE-33
- **Owns:**
  - `packages/danaview_editor_core/lib/src/formats/subtitle_codec.dart`, `srt.dart`, `vtt.dart` (extends CORE-20)
  - `packages/danaview_editor_core/lib/src/plan/export_settings.dart` (extends CORE-33: `SubtitleFileOptions{keepStyling, speakerNames, karaokeTimings, rtlMarks}` on `ExportSettings`)
  - `packages/danaview_editor_core/test/formats/subtitles_v2/`, `packages/danaview_editor_core/test/fixtures/subtitles_v2/`
- **Spec:** The D-54 table.
  - The parser maps `<u>`, SRT `<font color>`, VTT `STYLE` classes (colour and background only), `<v Name>`, VTT timestamp tags (→ words) and the SRT `NAME:` speaker prefix heuristic (≥ 80%) into rich drafts, and strips U+200E/U+200F.
  - `serialize(cues, format, options)`. "Keep basic styling" off reproduces v1's bytes exactly.
  - The v1 corpus stays green.
- **Acceptance criteria and tests:**
  - Hand-written v2 fixtures (styles, voices, karaoke, RTL, emoji).
  - `parse(serialize(x, o)) == x` restricted to the features `o` carries (property test).
  - v1 corpus bytes unchanged with styling off.
  - 10k cues parse in ≤ 120 ms.

#### AIS-08 · Provider contracts, transport, consent tickets, retries, rate limits, tokens, JSON, fake server

- **Milestone:** S1 · **Area:** AI providers
- **Depends on:** AIS-01, AIS-42 (the Genkit spike decides whether AIS-09 and AIS-10 wrap Genkit or stay custom; this ticket's transport, consent and fake server are needed either way)
- **Owns:**
  - `packages/danaview_ai_providers/lib/src/contracts/`, `lib/src/consent/`, `lib/src/transport/`, `lib/src/json/`, `lib/src/tokens/`, `lib/src/fake/`
  - `packages/danaview_ai_providers/test/{contracts,consent,transport,json,tokens}/`
  - `packages/danaview_ai_providers/test/support/no_network.dart`
- **Spec:** D-47, D-48, D-51 and §3.5.
  - Types: `LlmProvider`, `ProviderCapabilities`, `AiModelInfo`, `LlmRequest`/`LlmPart(text|wavAudio)`, `PreparedRequest{bytes, sha256}`, `LlmResponse`, `LlmUsage`, `FinishReason`, `AiFailure`.
  - `ApiKey`: a wrapper whose `toString` is redacted, with no JSON form.
  - `AiSendDisclosure`, `AiSendConsent.accepted(disclosure, at)` → `AiSendTicket(hashes)`; `ProviderProbeDisclosure`, `ProviderProbeConsent.accepted(...)`.
  - `HttpTransport`: allow-list (D-66) with a debug-only loopback override honoured only when `!kReleaseMode` is passed in by the app (the package itself takes a `bool allowLoopback`); hash check; header-only keys; `followRedirects=false`; timeouts; `RetryPolicy` (identical bytes, jitter, `Retry-After`); `RateLimiter` (concurrency, RPM); `CancelToken`; gzip.
  - `json_extract` (fence and prefix stripping, one trailing comma); `json_schema_lite` (the subset used by the contracts: object, array, string with maxLength/enum, number with min/max, integer, required, additionalProperties false).
  - `TokenEstimator` (D-49).
  - `FakeLlmServer` (an `HttpServer` on 127.0.0.1 with scripted responses and latency) and `FakeLlmProvider`.
  - `no_network.dart` installs `HttpOverrides` that throw for any non-loopback host.
- **Acceptance criteria and tests:**
  - Transport against the fake server with a fake clock: success; retries for each retryable status; no retry for 400/401/403/404/413; `Retry-After` honoured and capped; timeouts; cancel mid-flight; a redirect becomes an error; a non-allow-listed host is refused before connecting; a body hash outside the ticket is refused; the key never appears in the URL, in logs (log spy) or in `toString`.
  - Rate limiter fairness.
  - Estimator within ±25% of reference counts on a hand-made corpus (Latin, CJK, Arabic, Devanagari, emoji).
  - Every test runs with `no_network.dart`.

#### AIS-09 · OpenAI-compatible base, OpenAI and Gemini adapters with hand-written fixtures

- **Milestone:** S1 · **Area:** AI providers
- **Depends on:** AIS-08
- **Owns:**
  - `packages/danaview_ai_providers/lib/src/providers/openai_compatible.dart`, `openai_provider.dart`, `gemini_provider.dart`
  - `packages/danaview_ai_providers/test/providers/{openai,gemini}/`, `packages/danaview_ai_providers/test/fixtures/providers/{openai,gemini}/`
- **Spec:**
  - **OpenAI-compatible base:** chat completions request building (system and user messages, `input_audio` parts, `response_format` json_schema strict or `json_object`, `max_tokens`/`max_completion_tokens` per model family [VERIFY], `temperature`, `store: false` where supported [VERIFY]); response parsing (content, usage, `finish_reason`); error-body mapping to `AiFailure` (`insufficient_quota` vs rate limit, `context_length_exceeded`, model not found).
  - **OpenAI** (`https://api.openai.com/v1`): `GET /models` for key test and list; `POST /chat/completions`; `Authorization: Bearer`; curated models recorded with ids and capabilities at implementation.
  - **Gemini** (`https://generativelanguage.googleapis.com/v1beta`): `GET /models` (key test and list, using `supportedGenerationMethods`); `POST /models/{m}:generateContent`; header `x-goog-api-key`; `systemInstruction`, `contents.parts` with `inline_data audio/wav`, `generationConfig.responseMimeType` + `responseSchema` (our schema converted to Gemini's OpenAPI subset); `usageMetadata`; `promptFeedback.blockReason` and `finishReason SAFETY` → `contentBlocked`, `RESOURCE_EXHAUSTED` → quota or rate (by detail).
  - All endpoint details carry [VERIFY] notes with reference URLs.
- **Acceptance criteria and tests:**
  - Golden request fixtures (method, path, headers with the key redacted, canonical body JSON) per contract shape (text-only, text + audio, schema mode).
  - Hand-written response fixtures for success, invalid JSON, schema-invalid, 400, 401, 403, 404, 413, 429 rate, 429 quota, 500, safety block, length truncation, each mapped correctly.
  - `testKey` and `listModels` parse the fixtures.
  - No network.

#### AIS-10 · Anthropic, OpenRouter and xAI adapters with hand-written fixtures

- **Milestone:** S1 · **Area:** AI providers
- **Depends on:** AIS-09
- **Owns:**
  - `packages/danaview_ai_providers/lib/src/providers/anthropic_provider.dart`, `openrouter_provider.dart`, `xai_provider.dart`
  - `packages/danaview_ai_providers/test/providers/{anthropic,openrouter,xai}/`, `packages/danaview_ai_providers/test/fixtures/providers/{anthropic,openrouter,xai}/`
- **Spec:**
  - **Anthropic** (`https://api.anthropic.com/v1`): `x-api-key`, `anthropic-version` header [VERIFY current value]; `GET /models`; `POST /messages` with `system`, a single forced tool whose `input_schema` is the contract schema, `max_tokens`; parse `tool_use.input`; `usage`; `stop_reason max_tokens` → truncated; overloaded (529) retryable; credit-balance errors → quota. Text only (no `audioInput`).
  - **OpenRouter** (`https://openrouter.ai/api/v1`): OpenAI-compatible base; `GET /models` gives `architecture.input_modalities` and `supported_parameters` → capabilities per model; `response_format` only when supported; no attribution headers (D-47); 402 → quota; the `cost` field is ignored (D-49).
  - **xAI** (`https://api.x.ai/v1`): OpenAI-compatible base; `GET /models`; structured output per capability [VERIFY]; text only unless verified.
- **Acceptance criteria and tests:** As AIS-09 for each provider, plus OpenRouter capability derivation from a hand-written models list (audio model → `audioInput`, a model without structured outputs → `jsonObject` fallback with local validation).

#### AIS-11 · danaview_secure_keys plugin: Keychain and Keystore-wrapped key store

- **Milestone:** S1 · **Area:** Native (iOS + Android)
- **Depends on:** AIS-01
- **Owns:**
  - `packages/danaview_secure_keys/` (pubspec, `pigeons/secure_keys_api.dart`, generated code, `lib/`, `ios/Classes/`, `ios/danaview_secure_keys.podspec`, `ios/Resources/PrivacyInfo.xcprivacy`, `android/`, `example/`, tests)
- **Spec:** D-46.
  - Pigeon (`^29`, as ENG-01) `SecureKeysHostApi { set(account, Uint8List secret), get(account) → Uint8List?, delete(account), list() → List<KeyInfo{account, last4, updatedAt}>, status() → ok|keysLost }`.
  - **iOS**: Keychain generic password, service `com.vecvel.danaview.ai`, `WhenUnlockedThisDeviceOnly`, not synchronizable; deployment target 15.0 with `-Werror=unguarded-availability-new`.
  - **Android**: an `AndroidKeyStore` AES-256-GCM key `danaview_ai_keys_v1` (random IV per entry), one file `noBackupFilesDir/danaview_ai_keys.bin` written atomically (temp + rename); a `KeyPermanentlyInvalidatedException` or missing key gives `keysLost` and wipes the file; crypto on a background executor.
  - Dart `SecureKeyStore` class plus `InMemorySecureKeyStore` for tests. Secrets are cleared from Dart memory after use where possible (`Uint8List.fillRange(0)`).
- **Acceptance criteria and tests:**
  - XCTest on the iOS simulator and JUnit plus instrumented tests on the Android emulator: set/get/delete/list round trip; the Android file is under `noBackupFilesDir`; a deleted Keystore key gives `keysLost`; the iOS item's accessibility attribute checked.
  - `check_ios_min_os.sh` clean for the pod.
  - The example app round-trips.
  - No secret is logged (grep).

### S2: Rich subtitles: rendering and editing

#### AIS-12 · Text layout spec v2: rich runs, effective style, placement, karaoke evaluation

- **Milestone:** S2 · **Area:** Core (pure Dart)
- **Depends on:** AIS-02, AIS-03, CORE-07
- **Owns:**
  - `packages/danaview_editor_core/lib/src/eval/text_layout_spec.dart` (extends CORE-07)
  - `packages/danaview_editor_core/lib/src/eval/karaoke_eval.dart`
  - `packages/danaview_editor_core/test/eval/layout_v2/`
- **Spec:**
  - `TextRun` gains `fontFamily?`, `fontSizePx?`, `color?`, `underline`, `strike`, `highlight?`, `stroke?` (`TextStrokeSpec`, or "none"), `shadow?`, `script hint`. `toJson` writes the new fields only when they are not the defaults (plain cues keep v1 JSON).
  - `effectiveCueStyle(cue, track, emotionTable)` implements the D-52 layer table.
  - `cueLayoutSpecOf(cue, track, canvas, {variant base|karaokeHighlight, speakers})` builds runs from spans (no markup parsing for schema 2), adds the speaker prefix run, applies the direction override, and uses the karaoke highlight patch for the highlight variant (metrics-neutral fields only; others are rejected by assert and ignored).
  - `cueAnchorOf(cue, track, spriteSize, canvas)` gives per-cue placement (vertical position, x, align) with the 0.06 safe margin.
  - `karaoke_eval.dart`: `karaokeRevealAt(cue, track, tLocal)` and `karaokeRevealKeys(cue, track) → [[tUs, n]]` (progressive step and fill ramp, offset by the prefix clusters, D-68), plus `estimatedWordsFor(cue)` when the cue has no words.
- **Acceptance criteria and tests:**
  - A plain v1 cue gives byte-identical spec JSON to v1.
  - Layer-order tests for every field. Prefix offsets.
  - Reveal keys exact at word boundaries and monotonic; fill ramps linear.
  - Placement for top/middle/bottom/custom/x with safe margins.
  - Highlight variant metrics equal to base (same JSON apart from paint fields).

#### AIS-13 · Render prep v2: per-run styles, decorations, karaoke highlight sprite, script rules, fallbacks

- **Milestone:** S2 · **Area:** Engine (Dart)
- **Depends on:** AIS-12, API-04
- **Owns:**
  - `packages/danaview_editor_engine_api/lib/src/render_prep/text_layout_engine.dart`, `text_sprite_rasterizer.dart`, `sprite_prepass.dart` (extends API-04)
  - `packages/danaview_editor_engine_api/test/render_prep/rich/`
  - `packages/danaview_editor_engine_api/test_fixtures/sprites/rich/`
  - `packages/danaview_editor_engine_api/test_fixtures/fonts/` (OFL test fonts with licence files)
- **Spec:**
  - Per-run `ui.TextStyle`:
    - family through `FontResolver`, size, weight, style;
    - decoration underline/lineThrough with thickness ∝ size;
    - highlight as a run `background` paint (rounded by padding 0.08 em);
    - per-run shadows;
    - outline as the stroke paragraph with a per-run foreground stroke (runs without outline transparent);
    - letter spacing forced to 0 for joining scripts (D-56).
  - `fallbackFamilies` from the injected catalog list (AIS-22).
  - The karaoke highlight variant is rasterized with the **union raster extent** of base and highlight, with the glyph-order map. `revealClip` works for RTL and mixed-direction lines.
  - The prepass handles variant requests.
- **Acceptance criteria and tests:**
  - Goldens (DPR 1 and 3) for each style field, mixed runs, a one-word style, per-run outline and shadow, Arabic with letter spacing set (joining intact), Hebrew, Devanagari conjuncts, Thai, mixed bidi, emoji.
  - Base and highlight sprites pixel-aligned (same extent and origin).
  - Reveal map correct for an RTL line (clusters revealed in logical order).
  - Glyph boxes equal `ui.Paragraph` boxes.
  - Per-slice UI time ≤ 4 ms.

#### AIS-14 · Lowering v2: per-cue placement, karaoke layers, sprite variants, contract fixture

- **Milestone:** S2 · **Area:** Core (pure Dart)
- **Depends on:** AIS-12, CORE-29, CORE-30, CORE-31
- **Owns:**
  - `packages/danaview_editor_core/lib/src/plan/lowering_text.dart`, `sprite_requests.dart` (extends CORE-31)
  - `packages/danaview_editor_core/lib/src/plan/sprite_request.dart` (extends CORE-29: `variant` in the key)
  - `packages/danaview_editor_core/lib/src/plan/z_order.dart` (extends CORE-30: `karaokeSub = 1`)
  - `packages/danaview_editor_core/test/fixtures/render_plans/contract/karaoke_cue.json` (extends CORE-29's corpus with one file)
  - `packages/danaview_editor_core/test/plan/compile_rich/`
- **Spec:** D-68 and §3.4.
  - `lowerCue` uses `cueAnchorOf`.
  - Karaoke cues add a `<cueId>#k` sprite layer at the cue lane's z + 1, with `reveal` keys from `karaokeRevealKeys` shifted to absolute µs.
  - `collectSpriteRequests` emits base and highlight variants (`reveal: true` only for the highlight).
  - `contentFontsVersion = 2`.
  - `ExportBlocked` if any variant is missing.
  - RenderPlan `v` stays 1. The plan validator needs no change (sub within −5…5; distinct z).
- **Acceptance criteria and tests:**
  - Compile goldens: placed cue, translated track burned, karaoke progressive and fill, speaker prefix, RTL karaoke.
  - The plan validator passes.
  - The contract fixture validates against the JSON Schema and round-trips in Dart.
  - The IOS-08 and AND-08 decode suites run on the new fixture unchanged (CI evidence, no native code edits).

#### AIS-15 · Word timings on generated cues (segmenter and pipeline)

- **Milestone:** S2 · **Area:** AI (transcription)
- **Depends on:** AIS-06, AI-11, AI-13
- **Owns:**
  - `packages/danaview_transcription/lib/src/segmentation/caption_segmenter.dart`, `caption_layout.dart` (extends AI-11)
  - `packages/danaview_transcription/lib/src/pipeline/pipeline.dart` (extends AI-13)
  - `packages/danaview_transcription/test/segmentation/words/`, `packages/danaview_transcription/test/pipeline/words/`
- **Spec:** D-69.
  - `DpCaptionSegmenter.segment` returns drafts whose `words` map each `TimedWord` to its grapheme range in the draft text (after normalization and line breaking), with times relative to the draft start. Words whose text was altered by the layout (trimmed punctuation) keep their nearest range.
  - The pipeline and `resegment` pass drafts with words to `AddGeneratedCaptionTrack`/`ReplaceGeneratedCaptions`.
  - The segmenter also accepts **pseudo-timed** words (used by the AIS-30 aligner) through the existing input type.
- **Acceptance criteria and tests:**
  - Every word of every draft has a range. Times are monotonic and within the draft.
  - The 9-language goldens (AI-11) are extended with words.
  - Re-split keeps words.
  - Performance stays within AI-11's budget (10k words ≤ 150 ms + 20%).

#### AIS-16 · Preview overlay v2 and on-preview cue placement

- **Milestone:** S2 · **Area:** UI/UX
- **Depends on:** AIS-13, AIS-05, UX-19, UX-22
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/preview/text_overlay_layer.dart`, `text_overlay_painter.dart` (extends UX-19)
  - `packages/danaview_editor/lib/src/editor/preview/manipulation_overlay.dart` (extends UX-22)
  - `packages/danaview_editor/lib/src/editor/preview/cue_drag_controller.dart`
  - `packages/danaview_editor/test/preview/rich_overlay/`
- **Spec:**
  - The overlay paints rich cues through AIS-12/13, applies per-cue placement, and paints karaoke as base plus the highlight clipped with `revealClip(karaokeRevealAt)`. It repaints only on frame change (v1 rule).
  - `ghostProject` input: the review panel's preview of a suggestion (overlay only; never PlanSync).
  - Cue drag: with a cue selected and its track position not "track default", dragging the cue block moves it. Snaps at top, middle and bottom safe positions and at the horizontal centre (8/12 px tolerance, v1 haptics). Runs as an `EditTransaction`; commit → one `SetCuePlacement`. Semantics actions per §4.5.
- **Acceptance criteria and tests:**
  - Overlay goldens match AIS-13 sprites within 1 px (rich, karaoke at word boundaries, RTL).
  - Per-frame cost ≤ 1 ms for 10 visible items including two karaoke cues (profile test).
  - One history entry per drag; snapping guides shown.
  - No scaffold rebuilds during playback.

#### AIS-17 · Transcript view and rich cue editor

- **Milestone:** S2 · **Area:** UI/UX
- **Depends on:** AIS-05, UX-31, UX-14
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/transcript/transcript_view.dart`, `transcript_row.dart`, `transcript_controller.dart`, `rich_cue_editor.dart`, `rich_cue_controller.dart`
  - `packages/danaview_editor/lib/src/editor/panels/subtitles_panel.dart` (extends UX-31: hosts the transcript, review and cue sections and the U4 header buttons)
  - `packages/danaview_editor/lib/src/editor/actions/bindings/transcript_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/transcript_strings.dart`
  - `packages/danaview_editor/test/panels/transcript/`
- **Spec:** U4 and U11.
  - `RichCueController` (a `TextEditingController` with `buildTextSpan` from spans using the §4.1 display rules; the composing region unstyled).
  - Edits → `SetCueText` (coalesced, spans remapped).
  - The selection exposes a grapheme range. Multi-line selection mode with an action bar. Current-line follow from `PlayheadController` without rebuilding the scaffold.
  - Tap timestamp → exact seek. Find in transcript.
  - Keys: Enter = line break, ⌘/Ctrl+Enter = split at cursor (AIS-05 `SplitCueAtGrapheme`), Backspace at start = merge with previous.
  - The custom context menu uses kit menus (no Material toolbar).
- **Acceptance criteria and tests:**
  - 3,000 cues scroll at ≤ 8 ms per frame (profile harness, as UX-31).
  - Typing produces one entry per coalesce window, and spans survive edits.
  - CJK IME composing (simulated) leaves spans intact.
  - Tap seeks; follow and unfollow; split/merge keys.
  - Matrix tests including the keyboard inset and 280×500 @1.35; `expectOwnerUiRules`.

#### AIS-18 · Style toolbar, cue section, speakers and emotion editing

- **Milestone:** S2 · **Area:** UI/UX
- **Depends on:** AIS-17, AIS-16, AIS-06, UX-30
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/transcript/style_toolbar.dart`
  - `packages/danaview_editor/lib/src/editor/panels/cue/` (`cue_section.dart`, `cue_placement_row.dart`, `cue_override_rows.dart`, `speaker_editor.dart`, `emotion_chip.dart`)
  - `packages/danaview_editor/lib/src/editor/actions/bindings/rich_text_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/rich_text_strings.dart`
  - `packages/danaview_editor/test/panels/rich_text/`
- **Spec:** U12 and U13.
  - Toolbar controls dispatch `ApplyCueStyle`/`ClearCueStyle` for a range or whole cues. ⌘B/⌘I/⌘U in the editor. Font button opens the v1 `FontPicker` (AIS-25 upgrades it behind the same API).
  - Cue section: placement row, alignment, override rows with Reset, speaker picker plus the speaker table editor (`SetTrackSpeakers`/`AssignSpeaker`), emotion chip (manual set or clear: `ApplyCueEdits` with source manual), word-timing status.
  - Track-level speaker display and emotion-styles switches.
- **Acceptance criteria and tests:**
  - Each control dispatches the right command with one history entry.
  - The toolbar scrolls at 280 px @1.35 without overflow.
  - Toggle semantics state. Speaker merge reassigns cues.
  - Matrix tests.

#### AIS-19 · Timing tools: snap to speech, split/merge at cursor, nudges

- **Milestone:** S2 · **Area:** UI/UX
- **Depends on:** AIS-15, AIS-17, UX-13, UX-21, CORE-18
- **Owns:**
  - `packages/danaview_editor_core/lib/src/ops/speech_snap.dart`
  - `packages/danaview_editor/lib/src/editor/panels/transcript/timing_tools.dart`
  - `packages/danaview_editor/lib/src/editor/timeline/snapping.dart` (extends UX-13: word boundaries of the edited cue's track as snap targets while dragging a cue edge)
  - `packages/danaview_editor/lib/src/editor/actions/bindings/timing_bindings.dart`
  - `packages/danaview_editor_core/test/ops/speech_snap/`, `packages/danaview_editor/test/panels/timing/`
- **Spec:**
  - `SpeechSnapIndex` from the cues' words (non-estimated first) plus an optional `EnergyEnvelope` (RMS from UX-21's waveform peaks of the audible clip, adapted in the editor).
  - `snapCueEdges(cue, tol 400 ms)`: start → first word start or speech onset within tolerance, end → last word end + 120 ms linger, capped by the next cue − 2 frames; on grid.
  - Actions for one cue, selected cues or a whole track (one `SetCueRange` composite).
  - Nudges ±1 frame/±100 ms on start, end or the whole cue. Set to playhead. Split at cursor (AIS-05). Merge with previous/next.
- **Acceptance criteria and tests:**
  - Snap results on fixtures (words, energy only, neither → no-op with a notice).
  - Never overlaps; always on grid; one history entry per action.
  - Timeline edge drag snaps to word boundaries.
  - Matrix tests.

#### AIS-20 · Karaoke settings and emoji tools

- **Milestone:** S2 · **Area:** UI/UX
- **Depends on:** AIS-14, AIS-16, AIS-17, AIS-06
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/subtitles/karaoke_section.dart`
  - `packages/danaview_editor/lib/src/editor/flows/emoji/` (`remove_emojis_sheet.dart`, `emoji_review_sheet.dart`)
  - `packages/danaview_editor/lib/src/editor/actions/bindings/emoji_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/karaoke_strings.dart`
  - `packages/danaview_editor/test/panels/karaoke/`, `packages/danaview_editor/test/flows/emoji/`
- **Spec:**
  - U14: mode, highlight fields (metrics-neutral only), timed/estimated counts, Estimate missing timings (`SetCueWords` composite, one entry), loop preview.
  - U15: Remove all emojis (counts from `emojiRangesOf`, AI-only vs all, empty-cue warning; `RemoveEmojis`). Review emojis stepper (seek per cue; remove one emoji → `SetCueText`).
- **Acceptance criteria and tests:**
  - Karaoke settings change the preview (goldens through the AIS-16 harness) and the export compile (`#k` layers present).
  - Emoji counts and removal are correct; undo restores.
  - Review stepper navigation.
  - Matrix tests.

#### AIS-21 · Subtitle file import/export options and export sheet labels

- **Milestone:** S2 · **Area:** UI/UX
- **Depends on:** AIS-07, UX-32, UX-39
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/subtitle_io.dart` (extends UX-32)
  - `packages/danaview_editor/lib/src/editor/flows/export/export_sheet.dart` (extends UX-39)
  - `packages/danaview_editor/test/panels/subtitle_io_v2/`
- **Spec:** U18.
  - SRT/VTT export options (`SubtitleFileOptions`, defaults per D-54).
  - The import summary lists mapped styles, speakers and karaoke timings.
  - The export sheet labels translated tracks "<Language> (translated)", and side-file options follow `SubtitleFileOptions`.
  - Suggested names stay `<project>.<bcp47>.srt|vtt`.
- **Acceptance criteria and tests:**
  - Exported bytes per option match the AIS-07 fixtures.
  - "Keep basic styling" off equals v1 output.
  - Translated track exports with its own language code.
  - Matrix tests.

### S3: Fonts and presets

#### AIS-22 · Bundled font expansion and FontCatalog v2

- **Milestone:** S3 · **Area:** UI/UX
- **Depends on:** AIS-13, AIS-14, UX-30
- **Owns:**
  - `packages/danaview_editor_fonts/` (extends UX-30: Noto families, `FONTS.md` with upstream commit and SHA-256 per file, OFL texts)
  - `packages/danaview_editor/lib/src/editor/text/font_catalog.dart` (extends UX-30)
  - `packages/danaview_editor/tool/measure_font_budget.dart`
  - `packages/danaview_editor/test/text/font_catalog_v2/`
- **Spec:** D-60.
  - Add the listed Noto families (Regular and Bold).
  - `FontCatalog` v2: entries carry id, family, category, scripts (from a generated table), weights, `bundled|imported|system`.
  - `fallbackChain()`: Inter, Noto Sans Arabic, Hebrew, Devanagari, Bengali, Gurmukhi, Gujarati, Tamil, Telugu, Kannada, Malayalam, Sinhala, Thai, then system. Injected into `TextLayoutEngine.fallbackFamilies` and the preview engine provider.
  - `fontsVersion` exposed for the sprite key (equal to AIS-14's `contentFontsVersion` 2).
  - Licence entries for the licences screen are registered by AIS-37.
- **Acceptance criteria and tests:**
  - The size budget (≤ 8 MB compressed delta on IPA and AAB) is measured and recorded in the PR; drop order applied if exceeded.
  - Each family loads in a golden.
  - Arabic/Devanagari text in a Figtree cue renders with the bundled Noto (glyph family check), not the system font.
  - The licence files are present.

#### AIS-23 · Font file inspector, font library store, preset store, built-in presets

- **Milestone:** S3 · **Area:** Core (pure Dart)
- **Depends on:** AIS-02, CORE-24, CORE-25
- **Owns:**
  - `packages/danaview_editor_core/lib/src/formats/sfnt_inspector.dart`
  - `packages/danaview_editor_core/lib/src/store/font_library_store.dart`, `preset_store.dart`
  - `packages/danaview_editor_core/lib/src/model/subtitle_presets.dart`
  - `packages/danaview_editor_core/lib/src/store/file_project_repository.dart` (extends CORE-25: `refs.json` gains `fonts`)
  - `packages/danaview_editor_core/test/formats/sfnt/`, `packages/danaview_editor_core/test/store/{fonts,presets}/`
  - `packages/danaview_editor_core/test/fixtures/fonts/` (hand-built minimal sfnt files and one OFL font)
- **Spec:**
  - D-61 validation and metadata (`SfntInfo{family, style, weightClass, italic, scripts, fsType, glyphCount}`), with errors as data.
  - `FontLibraryStore` (`<support>/danaview/editor/fonts/`): import from a picked temp file (copy, hash, dedupe, `index.json` atomic), list, rename the display name, delete (through `OwnedFileDeleter`), `usage()` from all `refs.json`.
  - `PresetStore` (`presets/subtitle_presets.json`, schema 1, atomic, at most 100).
  - The five built-ins of D-62 as constants with revision numbers.
- **Acceptance criteria and tests:**
  - Inspector accepts good fixtures and rejects TTC/WOFF/truncated/bad checksum/missing tables, with specific errors.
  - Library dedupe, rename, delete, and usage counting across fake projects.
  - Crash at every `FaultInjectingFs` step leaves a valid index and presets file.
  - `refs.json` lists fonts and contains no container paths.

#### AIS-24 · [INTEGRATION] Engine font pick kind (API, Pigeon, iOS, Android)

- **Milestone:** S3 · **Area:** Integration
- **Depends on:** AIS-01, API-01, ENG-03, ENG-06, IOS-15, AND-14
- **Owns:**
  - `packages/danaview_editor_engine_api/lib/src/platform_services.dart` (extends API-01: `MediaPickKind.font`)
  - `packages/danaview_editor_engine_api/lib/src/fake/fake_editor_engine.dart` (extends API-01)
  - `packages/danaview_editor_engine/pigeons/engine_api.dart` and the generated files (extends ENG-01/ENG-06)
  - `packages/danaview_editor_engine/lib/src/mobile_platform_services.dart` (extends ENG-03)
  - `packages/danaview_editor_engine/ios/Classes/Platform/MediaPicker.swift` (extends IOS-15)
  - `packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/platform/MediaPicker.kt` (extends AND-14)
  - `packages/danaview_editor_engine/example/ios/RunnerTests/FontPick/`
  - `packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/fontpick/`
- **Spec:**
  - A new enum value through the frozen Pigeon surface: a lead-approved [INTEGRATION] change per BP §2.
  - **iOS:** `UIDocumentPickerViewController` with `public.truetype-ttf-font`, `public.opentype-font`, `public.font` [VERIFY UTType ids], copy into `work/picks/` as for LUTs.
  - **Android:** SAF `OpenDocument` with mime types `font/ttf`, `font/otf`, `font/sfnt`, `application/x-font-ttf`, `application/x-font-otf`, `application/font-sfnt`, `application/octet-stream`, then an extension check in Dart.
  - The contract kit gets a font case.
- **Acceptance criteria and tests:**
  - Native unit tests for the type lists. Contract kit green on the fake.
  - Manual pick on the simulator and emulator recorded.
  - Pigeon generated files committed. Existing pick kinds unchanged (tests).

#### AIS-25 · Font picker v2, font import flow, manage fonts, missing fonts

- **Milestone:** S3 · **Area:** UI/UX
- **Depends on:** AIS-22, AIS-23, AIS-24
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/font_picker.dart` (extends UX-30)
  - `packages/danaview_editor/lib/src/editor/text/font_library_controller.dart`, `font_import_flow.dart`, `font_loader.dart`
  - `packages/danaview_editor/lib/src/settings/fonts_settings_section.dart`
  - `packages/danaview_editor/lib/src/app/strings/fonts_strings.dart`
  - `packages/danaview_editor/test/text/fonts_v2/`
- **Spec:** U16 and D-61.
  - Search, tabs, script chips, favourites/recent (prefs `editor.fonts.favourites`, `editor.fonts.recent`), and a live preview using the current selection text (paragraph cache, lazy).
  - Import: pick → inspector → rights reminder (with the stronger line for restricted fonts) → library → `ui.loadFontFromList` → done.
  - `FontLoader` loads the imported fonts used by the open project at editor open, and others lazily.
  - Missing-font banner with re-link by family plus hash.
  - Settings section to manage fonts.
- **Acceptance criteria and tests:**
  - Widget tests for every tab and state (empty, error copy per inspector error, too large, restricted).
  - An imported fixture font renders in preview and in a sprite (golden).
  - The missing-font fallback and re-link restore rendering.
  - Delete warns with the usage count.
  - 280 px @1.35 matrix.

#### AIS-26 · Subtitle style presets sheet and controller

- **Milestone:** S3 · **Area:** UI/UX
- **Depends on:** AIS-23, AIS-18, AIS-13
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/presets/` (`presets_sheet.dart`, `preset_tile.dart`)
  - `packages/danaview_editor/lib/src/editor/state/presets_controller.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/presets_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/presets_strings.dart`
  - `packages/danaview_editor/test/panels/presets/`
- **Spec:** U17 and D-62.
  - Tiles rendered with `TextLayoutEngine` (cached).
  - Apply → `ApplySubtitlePreset` (one entry). Save current, rename, duplicate built-in, delete.
  - "Modified" chip when the track values ≠ the preset's revision.
  - Presets referencing a missing imported font show a warning badge.
- **Acceptance criteria and tests:**
  - Built-ins apply exactly (golden of a cue per preset).
  - A user preset saved in project A applies in project B.
  - Deleting a preset doesn't change tracks that used it.
  - Matrix tests.

#### AIS-27 · On-demand CJK font packs (conditional: only on D-60 option b)

- **Milestone:** S3 · **Area:** UI/UX
- **Depends on:** AIS-22, AIS-25, AI-09
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/text/font_packs/`
  - `packages/danaview_editor_core/lib/src/store/font_pack_store.dart`
  - `packages/danaview_editor/test/text/font_packs/`
- **Spec:**
  - A catalog of pinned files (host, path, size, SHA-256).
  - A consent view with a `FontPackConsent.accepted(` call-site rule (same pattern as §16.3).
  - Downloader reusing AI-09's resumable logic with the same headers policy.
  - Packs stored under `<support>/danaview/editor/fonts/packs/` (backup-excluded on iOS).
  - The privacy text adds the host (AIS-36 coordinates).
- **Acceptance criteria and tests:** Fake HTTP for every status; hash mismatch deletes the file; zero network before consent (spy); pack fonts render in a golden.

### S4: AI Studio

#### AIS-28 · AI Studio core: service, planning, batching, job runner, suggestions, audio clips, usage

- **Milestone:** S4 · **Area:** AI Studio
- **Depends on:** AIS-06, AIS-08, AIS-43, AI-08, AI-12
- **Owns:**
  - `packages/danaview_ai_studio/lib/src/contracts/`, `orchestrator/`, `review/`, `audio/`, `usage/`, `glossary/`
  - `packages/danaview_ai_studio/test/{orchestrator,review,audio,usage}/`
- **Spec:** §3.6, D-49, D-50 and D-64.
  - `AiStudioService` with `plan` (local only) and `run`.
  - Ports: `AiKeyStore`, `AiAudioClipExtractor`, `UsageLedgerStore`, `BackgroundLeaseProvider` (v1 port), `ProjectFiles` (core `StoreFs` + `OwnedFileDeleter` roots).
  - Batching:
    - ≤ 6k estimated input tokens and ≤ 80 cues per batch;
    - sentence groups kept whole;
    - ≤ 4 MB raw audio per request;
    - ≤ 20 min audio per action (`PlanRefused(tooMuchAudio)` above that);
    - bodies prepared in `Isolate.run`.
  - `ClipPlanner` (AI-12 priority and units) and `WavSlicer` (RIFF parse, sample-exact slicing, ±150 ms padding, ≤ 15 s).
  - `JobRunner`: per-provider limiter, identical-byte retries, cancel, pause and continue (iOS lifecycle), partial results.
  - Suggestion types, `toCommand(project)`, `SuggestionStore` sidecar, stale detection with `cueContentHash`.
  - `GrammarDiff`: grapheme and word diff for display.
  - `UsageLedger`. `GlossaryStore` (per-project sidecar `ai/glossary.json`).
- **Acceptance criteria and tests:**
  - Plan determinism (same input → same hashes).
  - Disclosure totals equal the sum of the payload bytes.
  - `run` without a matching consent throws before any I/O (spy).
  - Cancel keeps completed batches. Partial failure is reported per batch.
  - Sidecar persists across a simulated kill, and the resume path requires a new consent.
  - Stale suggestions detected after an edit; `toCommand` round trip on fixtures.
  - WAV slicing is exact (sample counts).
  - Clips deleted after the job.

#### AIS-29 · Action contracts I: clean-up, emotion, emoji, speakers

- **Milestone:** S4 · **Area:** AI Studio
- **Depends on:** AIS-28, AIS-03
- **Owns:**
  - `packages/danaview_ai_studio/lib/src/actions/common/` (`prompt_kit.dart`, `contract_registry.dart`, `emotion_tables.dart`)
  - `packages/danaview_ai_studio/lib/src/actions/{cleanup,emotion,emoji,speakers}/`
  - `packages/danaview_ai_studio/test/actions/{cleanup,emotion,emoji,speakers}/`
  - `packages/danaview_ai_studio/test/fixtures/actions/`
- **Spec:** D-51, D-58 and D-59.
  - **`dv.cleanup.v1`.** Input `{lang, glossary[], options{punctuation, spelling, names, fillers}, cues:[{id, text}]}`. Output `{cues:[{id, text}]}`. Rules: no merging, splitting or reordering; keep the language, emoji and line breaks; a change > 30% of the length is flagged "large change".
  - **`dv.emotion.v1`.** Text or voice: the audio part per cue with an id label in the text part. Output `{cues:[{id, label, intensity, confidence}]}`. Optional local follow-ups: emotion styles, emoji from the D-58 tables with the density rules.
  - **`dv.emoji.v1`.** Output `{cues:[{id, inserts:[{afterWord, emoji}]}]}`. Allow-list and density enforced locally; `emojiMarks` set.
  - **`dv.speakers.v1`.** Windows of about 2 min carrying the roster `[{label, name?}]`. Output `{cues:[{id, speaker}], roster:[{label, name?}]}`. Names only when spoken (validated: the name must occur in some cue text). At most 8.
  - Prompts are versioned constants. The JSON Schemas are expressed in `json_schema_lite`.
  - Mappers produce `TextSuggestion`, `EmotionSuggestion`, `EmojiSuggestion`, `SpeakerSuggestion`, `StyleSuggestion`.
- **Acceptance criteria and tests:**
  - For each contract, hand-written good, bad and adversarial outputs: unknown and duplicate ids, extra fields, markup injected into text, over-long text, labels outside the set, confidence out of range, disallowed emoji, too many emoji, invented speaker names.
  - Valid items map, invalid items are dropped and counted.
  - Prompt snapshot tests (changing a prompt requires a contract version bump).
  - Emotion→emoji and style tables applied deterministically (seeded choice).

#### AIS-30 · Action contracts II: Ask AI and translation with alignment

- **Milestone:** S4 · **Area:** AI Studio
- **Depends on:** AIS-28, AIS-15, AI-11
- **Owns:**
  - `packages/danaview_ai_studio/lib/src/actions/{ask,translate}/`
  - `packages/danaview_ai_studio/lib/src/translation/` (`aligner.dart`, `sentence_groups.dart`, `languages.dart`)
  - `packages/danaview_ai_studio/test/actions/{ask,translate}/`, `packages/danaview_ai_studio/test/translation/`
- **Spec:** D-57 and D-67.
  - **`dv.ask.v1`.** Ops translate(lang), grammar, shorten, tone(kind), addEmoji, custom(instruction ≤ 500). Sub-range selections use the `⟦…⟧` markers, and text outside them must be unchanged. Output `{cues:[{id, text}]}`.
  - **`dv.translate.v1`.** Input sentence groups `{gid, text, cues:[{id, text, dur}]}` with source and target languages and formality. Output `{groups:[{gid, text}]}`. Option "keep line timing" uses per-cue items instead.
  - **Aligner:** proportional pseudo-times → AIS-15 segmenter with the target script profile and the project canvas (9:16 limits) → drafts with estimated words; overrides, placement, emotion and speaker taken from the dominant source cue; partial spans dropped, with the count reported.
  - `languages.dart`: about 180 BCP-47 tags with names, plus syntax validation for "Other".
  - Builds `TranslationTrackSuggestion`.
- **Acceptance criteria and tests:**
  - Aligner properties on random groups and translations: no overlap, grid edges, min/max duration, CPS within the profile or the line flagged, every grapheme placed exactly once, group span respected.
  - Goldens for en→de (longer), en→ja (no spaces), en→ar (RTL), en→hi.
  - Ask marker validation rejects edits outside the range.
  - Malformed and adversarial fixtures, as AIS-29.

#### AIS-31 · AI Studio settings: switch, providers, keys, model picker, test key, usage

- **Milestone:** S4 · **Area:** UI/UX
- **Depends on:** AIS-28, AIS-43, UX-04 (since 2026-10-16 the settings screen lives in `danaview_ai_ui` at Settings › AI Studio, D-70a)
- **Owns:**
  - `packages/danaview_editor/lib/src/settings/ai/` (`ai_settings_screen.dart`, `provider_sheet.dart`, `model_picker.dart`, `usage_section.dart`)
  - `packages/danaview_editor/lib/src/settings/editor_settings_screen.dart` (extends UX-04: "AI Studio" row through an `onOpenAiSettings` callback)
  - `packages/danaview_editor/lib/src/app/strings/ai_settings_strings.dart`
  - `packages/danaview_editor/test/settings/ai/`
- **Spec:** U1–U3, D-45, D-46 and D-49.
  - The master switch is stored in prefs `editor.ai.enabled`.
  - The provider sheet is the only `ProviderProbeConsent.accepted(` site. Key entry (obscured, paste), Save → `AiKeyStore.set`, Test key, Load models, Remove key, default model (`editor.ai.<provider>.model`), the provider privacy policy link (system browser).
  - Usage section from the ledger.
  - The `keysLost` banner.
- **Acceptance criteria and tests:**
  - Widget tests with `InMemoryKeyStore` and `FakeLlmProvider` for every state of U1–U3.
  - The saved key is never rendered in full, and the field never offers copy.
  - Turning the switch off hides the AI entry points immediately (provider test).
  - Matrix tests, a11y labels.

#### AIS-32 · AI Studio sheet, send disclosure, progress and error states

- **Milestone:** S4 · **Area:** UI/UX
- **Depends on:** AIS-29, AIS-31, AIS-43, AIS-17 (the send view itself lives in `danaview_ai_ui`, rule 17)
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/flows/ai/ai_studio_sheet.dart`, `ai_studio_controller.dart`, `ai_send_view.dart`, `ai_progress_panel.dart`, `ai_failure_copy.dart`
  - `packages/danaview_editor/lib/src/editor/actions/bindings/ai_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/ai_strings.dart`
  - `packages/danaview_editor/test/flows/ai/`
- **Spec:** U5–U7 and §3.9.
  - The controller state machine: choose → options → planning (audio extraction progress) → disclose → sending (batches) → result | failure | partial.
  - `AiSendView` is the only `AiSendConsent.accepted(` site, with the second tap above 200k tokens.
  - Copy for every `AiFailure`.
  - Pending-suggestions banner on editor open.
  - "From the voice" is disabled with a reason when the capability is missing.
- **Acceptance criteria and tests:**
  - Widget tests with `FakeAiStudioService` for every state, including offline, keyInvalid, quotaExceeded, rateLimited (countdown), contentBlocked partial, malformed retry, cancel (results kept).
  - The disclosure shows the numbers from the plan exactly.
  - No send without tapping Send (spy).
  - Matrix tests including 280×500 @1.35; VoiceOver order: the disclosure is read before Send.

#### AIS-33 · Review mode panel

- **Milestone:** S4 · **Area:** UI/UX
- **Depends on:** AIS-28, AIS-16, AIS-17
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/panels/review/` (`review_panel.dart`, `suggestion_row.dart`, `diff_text.dart`, `review_controller.dart`)
  - `packages/danaview_editor/lib/src/editor/actions/bindings/review_bindings.dart`
  - `packages/danaview_editor/lib/src/app/strings/review_strings.dart`
  - `packages/danaview_editor/test/panels/review/`
- **Spec:** U8 and D-64.
  - Filters, rows, accept/reject/edit, Accept all per group (one `ApplyCueEdits`).
  - Stale handling. Ghost preview (AIS-16 `ghostProject`).
  - Undo returns the suggestion to pending (listens to history).
  - "Report a problem" (D-63, behind an owner flag) opens a mail draft.
  - Virtualized for 3,000 suggestions.
- **Acceptance criteria and tests:**
  - Accept → exactly one history entry and the project equals the suggestion applied; reject → no entry.
  - Undo and redo keep panel state consistent.
  - Stale detection after a manual edit. Accept all is one entry.
  - Diff semantics announce added and removed text.
  - Scrolling 3,000 rows ≤ 8 ms per frame.
  - Matrix tests.

#### AIS-34 · Ask AI on selection

- **Milestone:** S4 · **Area:** UI/UX
- **Depends on:** AIS-30, AIS-32, AIS-33, AIS-18
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/flows/ai/ask_ai_sheet.dart`, `ask_ai_controller.dart`
  - `packages/danaview_editor/test/flows/ask_ai/`
- **Spec:** U9 and D-67.
  - Entry from the style toolbar, the line-selection bar, cue context menus and ⌘⇧A.
  - Preset chips and the free-text field.
  - The inline disclosure reuses `AiSendView` in compact mode.
  - Inline diff (`diff_text.dart`) with Accept (one command), Reject, Try again (a new plan).
  - "Remove emojis" runs locally.
- **Acceptance criteria and tests:**
  - Each op builds the right contract input (selection ranges with markers).
  - Results outside the selection are rejected.
  - Accept is one history entry and undoable. Local emoji removal sends nothing.
  - Error states per §3.9.
  - Matrix tests including the keyboard inset.

#### AIS-35 · Translate track flow and side-by-side review

- **Milestone:** S4 · **Area:** UI/UX
- **Depends on:** AIS-30, AIS-32, AIS-33
- **Owns:**
  - `packages/danaview_editor/lib/src/editor/flows/ai/translate_sheet.dart`, `translate_controller.dart`, `language_search.dart`
  - `packages/danaview_editor/test/flows/translate/`
- **Spec:** U10 and D-57.
  - Language search (recent languages in prefs `editor.ai.recentLanguages`), options, disclosure, progress.
  - Side-by-side review with inline edits and line rejects.
  - Create track → `AddDerivedSubtitleTrack` (one entry).
  - Partial results: create with N of M lines, or retry the missing ones.
- **Acceptance criteria and tests:**
  - Widget tests for every step and state.
  - The created track has the right language, provenance, position and burn-in off.
  - The source track is unchanged. Undo removes the new track.
  - Matrix tests at 280 px @1.35 (the two columns collapse to stacked rows below 600 px).

### S5: Integration, legal, QA, release

#### AIS-36 · Privacy policy, terms and licences for 1.2.0

- **Milestone:** S5 · **Area:** UI/UX
- **Depends on:** UX-42
- **Owns:**
  - `packages/danaview_features/lib/src/more/legal_texts.dart` (extends UX-42)
  - `test/editor_entry/legal_texts_ai_test.dart`
- **Spec:**
  - The §6.4 text, verbatim after owner review.
  - `legalEffectiveDate` set to the 1.2.0 release date.
  - Every AI and font bullet carries "On iPhone, iPad and Android".
- **Acceptance criteria and tests:**
  - The test asserts the summary mentions AI Studio and "your own key".
  - The internet section names all five hosts (from `danaview_ai_providers`' allow-list, through a root test in AIS-37) and the speech-model host.
  - Platform qualifiers present on every new bullet.
  - The terms contain the AI Studio and imported-fonts paragraphs.
  - No overflow at 280 px @1.35 on the legal screens.

#### AIS-37 · [INTEGRATION] App wiring v3: AI Studio, key store, audio clips, routes, network guard

- **Milestone:** S5 · **Area:** Integration
- **Depends on:** AIS-09, AIS-10, AIS-11, AIS-25, AIS-28, AIS-31, AIS-32, AIS-36, AIS-43, INT-04
- **Owns:**
  - `lib/main.dart`, `lib/router/app_router.dart`, `pubspec.yaml` (root; [INTEGRATION] after INT-05)
  - `packages/danaview_editor/lib/src/app/adapters/secure_key_store_adapter.dart`, `engine_ai_audio_extractor.dart`, `prefs_usage_ledger.dart`
  - `packages/danaview_editor/lib/src/app/editor_bootstrap.dart` (extends INT-02)
  - `test/ai_wiring_test.dart`, `test/ai_network_guard_test.dart`, `test/privacy_policy_ai_hosts_test.dart`
- **Spec:**
  - The root pubspec adds `danaview_secure_keys`.
  - `main.dart` constructs the providers (five adapters, transport with `allowLoopback: !kReleaseMode && DANAVIEW_AI_FAKE_HOST set`), the `AiStudioServiceImpl` with the adapters (key store → plugin, audio clips → `engine.jobs.extractSpeechAudio`, usage → prefs, background lease → `engine.background`), the font library and the preset store.
  - Register Noto `LicenseRegistry` entries.
  - Router: `/settings/editor/ai` (explicit child route, as BP §9 item 5) and `onOpenAiSettings`.
  - **Network guard tests** (`HttpOverrides` spy through the real wiring, as INT-04):
    1. A full editor session with AI Studio off makes zero requests.
    2. With it on, zero requests before Send or Test key.
    3. After Send, requests go only to the chosen provider's host, with the key in a header.
  - The privacy hosts test asserts the policy names every allow-listed host.
- **Acceptance criteria and tests:**
  - The wiring test boots the app with fakes and reaches U1, U5, U8, U9, U10 and U16.
  - The network guard and hosts tests are green.
  - Release build check: `DANAVIEW_AI_FAKE_HOST` is ignored (unit test with `kReleaseMode` simulation plus an architecture test).
  - iOS and Android builds; desktop unaffected (editor hidden).

#### AIS-38 · On-device E2E with a loopback fake provider, overflow matrix, accessibility

- **Milestone:** S5 · **Area:** QA
- **Depends on:** AIS-37, AIS-19, AIS-20, AIS-21, AIS-26, AIS-33, AIS-34, AIS-35
- **Owns:**
  - `integration_test/editor/ai_studio/`, `integration_test/editor/rich_subtitles/`
  - `scripts/ci/editor/ai_e2e.sh`
  - `packages/danaview_editor/test/overflow/ai_studio/`
  - `docs/v1.2/ai-studio/qa/e2e_report.md`
- **Spec:**
  - Run on the iOS Simulator (iPhone 17 Pro, iPad Pro with keyboard) and the Android Emulator (API 35 Pixel, API 29 minimal), with a loopback fake provider started by the test (`DANAVIEW_AI_FAKE_HOST`) serving hand-written fixtures.
  - Scenarios:
    1. Settings: enable, add key, Test key valid/invalid.
    2. Auto captions (tiny model) → Clean up → review → accept 3 / reject 1 → undo.
    3. Emotion from voice (fake audio-capable model) → emoji light → remove AI emojis.
    4. Speakers → rename → VTT export with `<v>`.
    5. Translate en→es → new track → export burn-in of the translated track and SRT of both.
    6. Ask AI shorten on a sub-range.
    7. Rich styling of one word + karaoke fill → export → frames show the highlight progressing at word boundaries (freeze-frame pulls, as QA-00 scenario 7).
    8. Import a font → use it → export.
    9. Apply a preset in project A, save a custom one, apply it in project B.
    10. Kill during a translation → reopen → pending banner → resume asks for consent again.
    11. Offline (fake server down) → offline copy → partial results kept.
  - The overflow matrix for every new surface and state (QA-09 method).
  - VoiceOver and TalkBack passes on U1, U5, U6, U8, U9, U11, U16.
- **Acceptance criteria and tests:** Every scenario passes on both platforms with evidence. Matrix green (PR subset plus nightly full). a11y checklist done. No request to any non-loopback host during the suite (spy log).

#### AIS-39 · Render parity (rich text, scripts, karaoke, emoji) and performance budgets

- **Milestone:** S5 · **Area:** QA
- **Depends on:** AIS-37, AIS-14, AIS-16, AIS-22, AIS-25
- **Owns:**
  - `integration_test/editor/rich_parity/`
  - `packages/danaview_editor/test/parity/rich_text/`
  - `docs/v1.2/ai-studio/qa/parity_and_performance.md`
- **Spec:**
  - On the simulator, the emulator and the device lab (iPhone SE 2 and the 4 GB Android): compare the preview overlay capture with export frames at cue midpoints and karaoke word boundaries for Latin, Arabic, Hebrew, Devanagari, Thai, CJK (system), mixed bidi and emoji (the QA-03 parity method, text regions only).
  - Budgets:
    - sprite pre-pass for 1,000 karaoke cues ≤ 16 s mid tier (2× V-D7);
    - transcript scroll ≤ 8 ms per frame;
    - overlay ≤ 1 ms per frame;
    - review accept ≤ 50 ms;
    - s1→s2 migration of a 3,000-cue project ≤ 300 ms in the isolate;
    - Dart heap +≤ 20 MB with 3,000 rich cues open.
- **Acceptance criteria and tests:** Parity within ARCH §11.6 tolerance for text regions (or recorded font-fallback differences only for system-CJK and emoji across devices). Budgets met or renegotiated in writing.

#### AIS-40 · Live provider validation (manual) and store evidence

- **Milestone:** S5 · **Area:** QA
- **Depends on:** AIS-37
- **Owns:**
  - `packages/danaview_ai_providers/tool/live_check.dart`
  - `docs/v1.2/ai-studio/qa/live_providers.md`
- **Spec:**
  - A manual tool, never run in CI. It reads keys from environment variables for the owner's accounts and runs each contract on a fixed public-domain sample text (and a CC0 speech clip from ENG-05's fixtures).
  - It records request and response **shapes** (keys present, field types, error bodies, usage fields) but never content or keys.
  - Checklist per provider: key test, models list, each contract in schema mode, audio where supported, 401, a forced 429 if feasible, safety block if reproducible.
  - Update curated model ids and capabilities, and the [VERIFY] items of §6.3, through follow-up FIX tickets on AIS-09/AIS-10 if anything differs.
  - Store evidence: screenshots of the disclosures for App Review and the Play Data safety form.
- **Acceptance criteria and tests:** All five providers validated on a real iPhone and a real Android device. Every [VERIFY] in §6.3 owned by this ticket is answered in the report. No key or content in the repo (grep in CI).

#### AIS-41 · [INTEGRATION] Release 1.2.0: flags, version, store metadata, privacy labels, docs

- **Milestone:** S5 · **Area:** Integration
- **Depends on:** AIS-38, AIS-39, AIS-40, AIS-36, AIS-37, AIS-54 (+ AIS-27 if scheduled)
- **Owns:**
  - `docs/v1.1/editor/release-checklist.md` (extends INT-05: 1.2.0 section)
  - Release dart-defines in the release lanes and workflows (extends INT-05)
  - Root `pubspec.yaml` version `1.2.0+N` ([INTEGRATION])
  - `ios/fastlane/metadata*/`, Android Play listing metadata
  - `docs/v1.1/editor/ARCHITECTURE.md` ([INTEGRATION]: 1.2.0 status, [VERIFY] closures)
- **Spec:**
  - Release builds pass `--dart-define=DANAVIEW_AI_STUDIO=true` alongside v1's flags.
  - Store descriptions and release notes ("AI Studio is optional and off by default. It uses your own key with Gemini, OpenAI, Claude, OpenRouter or Grok. Nothing is sent until you choose to.").
  - Privacy label and Data safety per the owner's D-63 decision, with evidence.
  - App Review notes (demo key or not, per D-63).
  - Hosted privacy policy updated at the store URLs (as INT-05).
  - Project schema 2, `minReader` 1; s2 fixtures committed.
- **Acceptance criteria and tests:** Checklist complete with evidence; release builds for iOS and Android; desktop builds unaffected; the hosted policy matches `legal_texts.dart` (diff attached).

### 5.6 Shared and v1-file register

These v1 files are edited by 1.2.0 tickets. Each row is edited by exactly one 1.2.0 ticket, except where an order is given.

| Path | v1 owner | 1.2.0 ticket(s), in order |
|---|---|---|
| `danaview_editor_core/lib/{model,ops,eval,formats,plan,codec,store}.dart` | CORE-01 | AIS-01 |
| `danaview_editor_core/lib/src/ops/edit_command.dart` | CORE-09 | AIS-01 |
| `danaview_editor_core/lib/src/model/{items,subtitle,text_style}.dart` | CORE-03 | AIS-02 |
| `danaview_editor_core/lib/src/validate/`, `test/support/random_project.dart` | CORE-08 | AIS-02 |
| `danaview_editor_core/lib/src/codec/{project_json,schema_version}.dart` | CORE-22 | AIS-04 |
| `danaview_editor_core/lib/src/codec/migrations/migrations.dart` | CORE-23 | AIS-04 |
| `danaview_editor_core/lib/src/ops/commands/subtitle_commands.dart` | CORE-15 | AIS-05 |
| `danaview_editor_core/lib/src/ops/commands/caption_commands.dart` | CORE-15 | AIS-06 |
| `danaview_editor_core/lib/src/formats/{subtitle_codec,srt,vtt}.dart` | CORE-20 | AIS-07 |
| `danaview_editor_core/lib/src/plan/export_settings.dart` | CORE-33 | AIS-07 |
| `danaview_editor_core/lib/src/eval/text_layout_spec.dart` | CORE-07 | AIS-12 |
| `danaview_editor_core/lib/src/plan/{lowering_text,sprite_requests}.dart` | CORE-31 | AIS-14 |
| `danaview_editor_core/lib/src/plan/sprite_request.dart`, `test/fixtures/render_plans/contract/` (one new file) | CORE-29 | AIS-14 |
| `danaview_editor_core/lib/src/plan/z_order.dart` | CORE-30 | AIS-14 |
| `danaview_editor_core/lib/src/store/file_project_repository.dart` | CORE-25 | AIS-23 |
| `danaview_editor_engine_api/lib/src/render_prep/` | API-04 | AIS-13 |
| `danaview_editor_engine_api/lib/src/{platform_services,fake/fake_editor_engine}.dart` | API-01 | AIS-24 |
| `danaview_editor_engine/pigeons/`, generated Pigeon files, `lib/src/mobile_platform_services.dart`, `ios/.../MediaPicker.swift`, `android/.../MediaPicker.kt` | ENG-01/ENG-06, ENG-03, IOS-15, AND-14 | AIS-24 ([INTEGRATION]) |
| `danaview_transcription/lib/src/segmentation/`, `pipeline/pipeline.dart` | AI-11, AI-13 | AIS-15 |
| `danaview_editor/pubspec.yaml`, `contracts/*`, `wiring/action_bindings.dart`, `app/{editor_providers,editor_availability}.dart` | UX-01 | AIS-01 |
| `danaview_editor/lib/src/editor/preview/{text_overlay_layer,text_overlay_painter}.dart` | UX-19 | AIS-16 |
| `danaview_editor/lib/src/editor/preview/manipulation_overlay.dart` | UX-22 | AIS-16 |
| `danaview_editor/lib/src/editor/panels/subtitles_panel.dart` | UX-31 | AIS-17 |
| `danaview_editor/lib/src/editor/timeline/snapping.dart` | UX-13 | AIS-19 |
| `danaview_editor/lib/src/editor/panels/subtitle_io.dart` | UX-32 | AIS-21 |
| `danaview_editor/lib/src/editor/flows/export/export_sheet.dart` | UX-39 | AIS-21 |
| `danaview_editor_fonts/`, `danaview_editor/lib/src/editor/text/font_catalog.dart` | UX-30 | AIS-22 |
| `danaview_editor/lib/src/editor/panels/font_picker.dart` | UX-30 | AIS-25 |
| `danaview_editor/lib/src/settings/editor_settings_screen.dart` | UX-04 | AIS-31 |
| `danaview_editor/lib/src/app/editor_bootstrap.dart` | INT-02 | AIS-37 |
| `danaview_features/lib/src/more/legal_texts.dart` | UX-42 | AIS-36 |
| `lib/main.dart`, `lib/router/app_router.dart`, root `pubspec.yaml` | INT-02/INT-04/INT-05 | AIS-37 → AIS-41 (version only) |
| `test/architecture/dependency_rules_test.dart`, `.github/workflows/editor-ci.yml` | INT-01 | AIS-01 |
| `docs/v1.1/editor/ARCHITECTURE.md` | INT-01/ENG-06/INT-05 | AIS-01 → AIS-41 |
| `docs/v1.1/editor/release-checklist.md`, release lanes | INT-05 | AIS-41 |

### 5.7 Feature coverage (owner's list → tickets)

| # | Owner feature | Tickets |
|---|---|---|
| 1 | BYO key, optional and off by default | D-45, D-65; AIS-31, AIS-37 |
| 1 | Providers: Gemini, OpenAI, Claude, OpenRouter, Grok | AIS-08, AIS-09, AIS-10, AIS-40 |
| 1 | Settings: key fields per provider, model picker, Test key | AIS-31 (U1–U3) |
| 1 | Keys in secure storage (Keychain / Keystore) | D-46; AIS-11, AIS-37 |
| 1 | Off = v1 behaviour, on device and offline | D-45, D-65; AIS-01 (flag test), AIS-37 (network guard) |
| 2 | Clean up the whisper transcript (punctuation, names, spelling) | AIS-29 (`dv.cleanup.v1`), AIS-32, AIS-33 |
| 2 | Emotion/tone per line from text (any provider) | AIS-29 (`dv.emotion.v1`), AIS-32 |
| 2 | Emotion/tone from voice (audio providers) | D-50; AIS-28 (clips), AIS-29, AIS-37 (extractor adapter) |
| 2 | Emojis by emotion, density none/light/heavy | D-55, D-58; AIS-29, AIS-32 |
| 2 | Optional emotion-driven style presets | D-58; AIS-12 (style layer), AIS-18 (switch), AIS-29 |
| 2 | Speaker labels | D-59; AIS-29 (`dv.speakers.v1`), AIS-06, AIS-18, AIS-07 (VTT voices) |
| 3 | Translate a track into any language as a NEW track; original kept | D-57; AIS-30, AIS-35, AIS-06 (`AddDerivedSubtitleTrack`) |
| 3 | Timing matched, lines re-split to fit | D-57; AIS-30 (aligner), AIS-15 (segmenter with words) |
| 3 | RTL and complex scripts render correctly | D-56, D-60; AIS-13, AIS-22, AIS-39 |
| 3 | Export either track (burn-in or SRT/VTT) | AIS-14, AIS-21, AIS-07, AIS-38 (scenario 5) |
| 4 | Transcript/document view with timestamps, tap to seek, edit in place | AIS-17 |
| 4 | Rich-text styling of any selected range (font, size, B/I/U/S, colour, highlight, outline, shadow) | D-52; AIS-02, AIS-03, AIS-05, AIS-12, AIS-13, AIS-16, AIS-18 |
| 4 | Per-line placement (top/middle/bottom or drag), alignment, per-line overrides | AIS-02, AIS-05, AIS-12, AIS-14, AIS-16, AIS-18 |
| 4 | Karaoke/word highlight using word timings | D-68, D-69; AIS-12, AIS-13, AIS-14, AIS-15, AIS-20 |
| 4 | Timing tools: drag edges, frame nudge, snap to speech, split/merge at cursor | AIS-19 (+ v1 UX-13 drag), AIS-05 |
| 4 | Remove all emojis or review one by one | AIS-03, AIS-06, AIS-20 |
| 4 | Review mode to accept/reject every AI change; full undo | D-64; AIS-28, AIS-33 |
| 5 | Ask AI on selected words, lines or range: translate, fix grammar, shorten, change tone, add/remove emojis | D-67; AIS-30, AIS-34 |
| 5 | Free-text instruction | D-67; AIS-30, AIS-34 |
| 5 | Result as a diff to accept or reject; undo always works | AIS-33 (`diff_text`), AIS-34 |
| 6 | More bundled open-licence fonts incl. Indic, Arabic (and CJK) | D-60; AIS-22 (+ AIS-27 conditional for CJK styles) |
| 6 | Import .ttf/.otf with a rights reminder | D-61; AIS-23, AIS-24, AIS-25 |
| 6 | Font picker with search, favourites, live preview | AIS-25 |
| 7 | Built-in presets: YouTube classic, TikTok bold, Karaoke, Cinema, Minimal | D-62; AIS-23, AIS-26 |
| 7 | User-saved presets reused across projects | D-62; AIS-23, AIS-26 |
| 8 | Multi-speaker transcription: on-device diarization after whisper (2026-10-16) | D-70c; AIS-44, AIS-45, AIS-46 |
| 8 | Words assigned to speakers from whisper word timestamps | D-70e; AIS-46 |
| 8 | Overlapping speech as separate cues on per-speaker lanes, exact timestamps, never merged | D-70e, D-70f; AIS-46, AIS-47, AIS-48 |
| 8 | Per-speaker style; renamable speakers | D-70f; AIS-47, AIS-48 |
| 8 | Optional cloud diarization (Gemini audio) behind Send | D-70g; AIS-49 |
| 9 | On-device search index over the Files & Media Home (labels, text in images, document text, captions, transcripts, metadata) | D-70d; AIS-50, AIS-51 |
| 9 | AI search (a): question → filters, only the question is sent | D-70h; AIS-52 |
| 9 | AI search (b): deep indexing per folder with a token estimate, behind Send | D-70i; AIS-53 |
| 10 | Shared `danaview_ai` layer behind one AI Studio switch | D-70a; AIS-43 |
| 11 | Genkit spike as the first provider ticket; adopt only if the transport is controllable | D-70b; AIS-42 |
| Rules | No overflow, custom components, Figtree chrome, touch targets, a11y | AIS-01 (`expectOwnerUiRules`), every UI ticket's matrix tests, AIS-38 |
| Rules | Project migration (schema 2) | D-53; AIS-04 |
| Rules | Privacy policy and terms | §6.4; AIS-36, AIS-37 |

---

## 6. Risks, open questions, legal text, effort

### 6.1 Risks

| # | Risk | Mitigation (ticket) |
|---|---|---|
| RS1 | Provider APIs drift: endpoints, JSON-mode parameters, model ids, error shapes | One adapter per provider behind `LlmProvider`; hand-written fixtures with reference dates; user-typed model ids; a live checklist every release (AIS-09, AIS-10, AIS-40) |
| RS2 | Model output quality: wrong translations, invented names, bad timing | Strict contracts and validators, review before anything changes, names only when spoken, translation reviewed as a whole track, undo (D-51, D-64; AIS-29, AIS-30, AIS-33) |
| RS3 | Surprise costs for users | Token estimates, a second tap above 200k tokens, a local usage ledger, batching caps, no automatic sends (D-49) |
| RS4 | Key leakage (logs, URLs, crash reports, screenshots, backups) | Header-only keys, redacted `ApiKey`, grep tests, obscured field with no copy-out, Keychain ThisDeviceOnly and `noBackupFilesDir`, no crash reporting in the app (D-46, D-47; AIS-08, AIS-11) |
| RS5 | App Store or Play rejection over AI data sharing or untestable features | D-45 disclosures, D-63 label and review-note decisions, a demo key option, store evidence (AIS-40, AIS-41) |
| RS6 | Rich text slows the transcript, timeline or overlay at 3,000 cues | One active editor, virtualized lists, paragraph caches, profile budgets (AIS-17, AIS-39) |
| RS7 | Karaoke doubles the sprite pre-pass time | Content-addressed sprites, highlight sprites only for karaoke tracks, measured budget (AIS-14, AIS-39) |
| RS8 | Grapheme segmentation changes between `characters` versions shift span ranges | Pinned version; decode clamps ranges (repair); styles only shorten, never corrupt text (D-52) |
| RS9 | Joining or complex-script rendering bugs (letter spacing, underline, reveal in RTL) | Script rules, bundled Noto, goldens in four scripts plus mixed bidi (AIS-13, AIS-39) |
| RS10 | A 1.1.x app shows 1.2.0 projects without styling | Read-only by D-12, with the newer-version banner; no data loss (D-53) |
| RS11 | Font licensing complaints | Rights reminder on every import, fsType warning, terms text (D-61, §6.4) |
| RS12 | iOS backgrounding drops in-flight requests | `connectionLost(maybeReceived)`, pause, then "Continue sending?" with identical bytes (§3.8) |
| RS13 | Emoji renders as missing-glyph boxes on old Android | Emoji ≤ 12.0 allow-list for AI emoji (D-55) |
| RS14 | Provider safety filters block ordinary captions (profanity in film dialogue) | Per-batch `contentBlocked` with partial results; the user can switch provider or model (§3.9) |
| RS15 | The size budget for Noto fonts is exceeded | A measurement tool and a fixed drop order (AIS-22) |
| RS16 | Whisper transcribes only the louder voice in overlapping speech, so the quieter speaker's words are missing | Overlap cues are still created on the second lane with exact times and a "needs text" mark; cloud diarization (D-70g) can transcribe both voices; review shows every overlap (D-70e; AIS-46, AIS-48) |
| RS17 | sherpa-onnx and ONNX Runtime add too much to the install size, or run too slowly on low-tier phones | Measured in AIS-44 against an owner-set budget; int8 models; diarization offered only on tiers that meet the speed target (D-70c) |
| RS18 | A bundled ML Kit library makes its own network requests (usage logging), breaking G-S1 | Device network spy in AIS-50 and AIS-54; if ML Kit calls home, disable its logging or fall back to a different on-device path (D-70d) |
| RS19 | Genkit pulls in heavy or changing dependencies, or hides the request bytes | The spike's criteria are hard gates; custom adapters stay the fallback (D-70b) |
| RS20 | Deep indexing a large folder costs the user more than expected | Token and size estimate before Send, per-folder scope, a cap with a second tap, resumable batches, no automatic re-indexing (D-70i) |

### 6.2 Open questions for the owner

1. **D-45:** Is one Send per action acceptable, or should text-only actions to an already-used provider skip the disclosure within a session? The recommendation is no: always show it.
2. **D-50:** Is sending voice clips acceptable at all? If not, emotion and speakers become text-only and D-50 is dropped.
3. **D-55 / D-60:** System emoji and system CJK (smaller app), or bundled for identical looks (larger app, or AIS-27 packs with a new download host)?
4. **D-58:** Are the label set, emoji pools and emotion colours acceptable?
5. **D-59:** Is AI speaker labelling (guessed from text on Claude and Grok) useful enough to ship, or should it be voice-only?
6. **D-61:** Wording of the rights reminder; whether to block or only warn when `fsType` restricts embedding (the recommendation is to warn).
7. **D-63:** Privacy label and Data safety declarations; a demo key for App Review; whether "Report a problem" is needed for Play's AI-generated content policy.
8. **D-66:** Confirm there are no custom endpoints in 1.2.0.
9. Should accepting AI clean-up on generated captions keep `CueOrigin.generated` (so Regenerate warns about the edits), as proposed?
10. Should the transcript view later replace v1's cue list entirely? This plan keeps both in 1.2.0.
11. **D-70c:** What install-size increase is acceptable for on-device diarization (ONNX Runtime plus sherpa-onnx in the app; models downloaded)? AIS-44 measures it.
12. **D-70e:** When whisper gives no words for the quieter speaker in an overlap, should the lane cue be left empty with a "needs text" mark (proposed) or show a placeholder such as "[overlapping speech]"?
13. **D-70h:** Should AI search ask for Send on every question (D-45 as written), or may the user allow "questions only" to one provider for the session? The recommendation is Send every time, with the question shown in the disclosure.
14. **D-70i:** May deep indexing send video keyframes (3 per video, proposed) as well as photo thumbnails and document text, or photos and documents only?

### 6.3 [VERIFY] register

| ID | Claim | Ticket |
|---|---|---|
| V-S1 | Endpoint paths, auth headers and JSON-mode parameters for each provider (§D-48), and Anthropic's `anthropic-version` value | AIS-09, AIS-10, AIS-40 |
| V-S2 | Which current models accept audio input (Gemini, OpenAI, OpenRouter), and that Claude and Grok do not for this API | AIS-09, AIS-10, AIS-40 |
| V-S3 | Inline request size limits (Gemini 20 MB, OpenAI and OpenRouter limits) against the D-50 caps | AIS-40 |
| V-S4 | Audio token rates per second (Gemini 32 tokens/s, OpenAI) for estimates | AIS-08, AIS-40 |
| V-S5 | Quota versus rate-limit error shapes per provider | AIS-09, AIS-10, AIS-40 |
| V-S6 | OpenAI `store: false` and `max_completion_tokens` applicability | AIS-09, AIS-40 |
| V-S7 | `flutter_secure_storage` Android behaviour (for the D-46 record only) | AIS-11 |
| V-S8 | iOS UTType ids for TTF/OTF in the document picker; Android font mime types delivered by common file providers | AIS-24 |
| V-S9 | Flutter letter spacing breaks Arabic joining (hence forcing 0) | AIS-13 |
| V-S10 | Impeller renders COLRv1 emoji in `Picture.toImage` (only if D-55 option b) | AIS-13 |
| V-S11 | Compressed size of the Noto set on IPA and AAB | AIS-22 |
| V-S12 | Size of Noto CJK pack files (only if AIS-27) | AIS-27 |
| V-S13 | App Store guideline 5.1.2(i) wording and the age-rating questions about AI | AIS-40, AIS-41 |
| V-S14 | Play Data safety treatment of transfers the user starts to a chosen AI provider; scope of the AI-generated content policy for text rewriting | AIS-40, AIS-41 |
| V-S15 | `ui.loadFontFromList` with imported OTF (CFF) fonts renders identically in the preview and in sprite rasterization on both platforms | AIS-25 |
| V-S16 | Genkit Dart 1.0 facts as given by the owner (Apache-2.0; plugins `genkit_google_genai`, `genkit_openai`, `genkit_anthropic`, `genkit_mcp`; structured output, tools, streaming, embeddings; agents and sessions experimental), and every D-70b criterion: injectable HTTP client, visible and hashable payload bytes, client-side keys, OpenRouter and xAI through the OpenAI plugin with a fixed base URL, no telemetry or dev server in release, dependency weight, embeddings and multimodal input | AIS-42 |
| V-S17 | Diarization model choice, sizes and licences: sherpa-onnx (Apache-2.0); pyannote segmentation 3.0 (MIT) as exported for sherpa-onnx, and whether its redistribution needs the Hugging Face gate terms; the speaker-embedding model (candidates from 3D-Speaker, WeSpeaker or NeMo, each with its own licence); a pinned Hugging Face mirror so no new host is needed | AIS-44 |
| V-S18 | sherpa-onnx's offline diarization keeps overlapping segments from pyannote's multi-speaker output (not only the dominant speaker); otherwise AIS-46 reads the segmentation model's per-frame activity directly | AIS-44 |
| V-S19 | Install-size increase of ONNX Runtime plus sherpa-onnx per platform (IPA, AAB per ABI) and diarization speed (real-time factor) on the low, mid and high tiers | AIS-44 |
| V-S20 | Apple Vision (`VNClassifyImageRequest`, `VNRecognizeTextRequest`) and ML Kit (image labeling and text recognition v2, bundled models) run fully offline; ML Kit's bundled models make no network requests from the app; their sizes and supported scripts | AIS-50 |
| V-S21 | Full-text search in the library database (SQLite FTS5 through the `sqlite3` package, or a pure-Dart inverted index if FTS5 isn't available on every platform) | AIS-50 |
| V-S22 | Provider support for image input and for embeddings (text and multimodal) per provider, and the token cost per image used in the D-70i estimate | AIS-53, AIS-40 |

### 6.4 Privacy policy and terms changes (draft text for `legal_texts.dart`, AIS-36)

The text follows the plain style of `packages/danaview_features/lib/src/more/legal_texts.dart` and its "On iPhone, iPad and Android" qualifiers.

**Privacy Policy › summary (replace):**
"Danaview keeps everything on your device. There are no accounts, no analytics, no ads and no tracking, and nothing you watch, edit or type is sent to us. The only extra download is the optional speech model for Auto captions, and only after you agree. If you turn on AI Studio and add your own key for an AI provider, the captions you choose are sent to that provider, only when you ask and after you see what will be sent."

**What Danaview stores on your device (add bullets):**
- "On iPhone, iPad and Android, if you use AI Studio: the API keys you enter, kept in your device's secure storage (the Keychain on iPhone and iPad, a key protected by Android Keystore on Android). Keys are not included in backups and are only ever sent to the provider they belong to."
- "On iPhone, iPad and Android, AI suggestions you haven't reviewed yet, and the names and terms you add to help AI Studio, saved with the project they belong to."
- "On iPhone, iPad and Android, fonts you import and the subtitle style presets you save, so you can use them in any project."

**When Danaview uses the internet (add bullet, lead "AI Studio with your own key"):**
"On iPhone, iPad and Android, AI Studio is off until you turn it on. If you turn it on and add an API key for Google Gemini, OpenAI, Anthropic Claude, OpenRouter or xAI Grok, Danaview connects to that provider (generativelanguage.googleapis.com, api.openai.com, api.anthropic.com, openrouter.ai or api.x.ai) only when you start an AI action, such as cleaning up, translating or adding emojis to captions, or when you tap Test key. Before anything is sent, Danaview shows what will be sent and to which provider. It sends the caption text you chose and, only for actions that listen to the voice, short audio clips of the parts of your video those captions cover. It never sends the video picture, file names, the project name or your profile. Your key is sent only to its provider, to identify your account. The provider handles the request under its own terms and privacy policy, which apply to your account with them, and may keep it for a time under those policies. Danaview has no access to your provider account and doesn't see what you are billed."

**When Danaview uses the internet, closing paragraph (replace):**
"Files on your device that you play, edit, inspect, export or browse are processed on your device and are never uploaded, except the captions and audio clips you choose to send with AI Studio."

**Files and permissions (add bullet, lead "Fonts"):**
"On iPhone, iPad and Android, when you import a font, Danaview copies only the file you pick into its own storage."

**Your choices (add bullets):**
- "On iPhone, iPad and Android, turn AI Studio off, and remove the keys you added, in Settings › Video editor › AI Studio. With AI Studio off, nothing is sent to an AI provider."
- "On iPhone, iPad and Android, delete imported fonts in Settings › Video editor › Fonts, and saved presets in the editor's Style presets."

**Terms of Use (add section "AI Studio"):**
"On iPhone, iPad and Android, AI Studio uses your own account with the AI provider you choose. You are responsible for your use of that provider, its charges and following its terms. AI suggestions, including translations, names, emotions, emojis and speaker labels, may be wrong or inappropriate. Review them before you publish. Danaview doesn't change your project until you accept a suggestion."

**Terms › Your content (add sentence):**
"Only import fonts you have the right to use; some font licences don't allow use in videos you publish."

**Terms › Trademarks (replace second sentence):**
"YouTube, Instagram, TikTok, Google Gemini, OpenAI, Anthropic Claude, OpenRouter, xAI and Grok are trademarks of their respective owners."

**Terms › No warranty (extend the list):**
"…, export size estimates, automatically created captions, AI suggestions and token estimates, are approximate."

**Licences screen:** the Noto font families (OFL-1.1) and imported fonts' own licences (shown from the font file when present).

**Added 2026-10-16 (AIS-54 coordinates with AIS-36):**
- **When Danaview uses the internet (add bullet, lead "Speaker detection model"):** "On iPhone, iPad and Android, only if you choose to detect speakers, and only after you agree, Danaview downloads a speaker detection model (about N MB) from Hugging Face (huggingface.co, delivered through hf.co). The request contains only the model's file name. After the download, speakers are detected entirely on your device." (N and the exact files come from AIS-44.)
- **What Danaview stores on your device (add bullet):** "On iPhone, iPad, Android and Mac, a search index of your Danaview library: file names and dates, labels and text found in your photos and documents, and your captions and transcripts. It stays on your device, isn't included in backups, and you can rebuild or delete it in Settings."
- **AI Studio with your own key (extend the bullet):** "…If you use AI search, Danaview sends only the question you typed, unless you turn on deep indexing for a folder. Deep indexing sends small previews of that folder's photos and the text of its documents to the provider you chose, after showing you what will be sent and an estimate of its size."

**Licences screen (add):** sherpa-onnx (Apache-2.0), ONNX Runtime (MIT), the speaker models' licences (from AIS-44), and Genkit (Apache-2.0) if adopted.

### 6.5 Effort estimate (ticket counts; no calendar)

| Milestone | Tickets | Of which large (≥ 1,000 hand-written lines expected) | Notes |
|---|---|---|---|
| S1 Foundations and contracts | 11 | AIS-04, AIS-08, AIS-09, AIS-10, AIS-11 | Core and provider lanes run in parallel; AIS-11 is native on both platforms |
| S2 Rich subtitles | 10 | AIS-13, AIS-17, AIS-18 | Rendering lane and UI lane in parallel after AIS-12 / AIS-05 |
| S3 Fonts and presets | 6 (5 + 1 conditional) | AIS-25 | AIS-24 touches the frozen Pigeon surface ([INTEGRATION]) |
| S4 AI Studio | 8 | AIS-28, AIS-30, AIS-32 | Starts once AIS-06 and AIS-08 land; UI work against fakes |
| S5 Integration, legal, QA, release | 6 | AIS-38 | AIS-40 needs the owner's provider keys |
| S1+ Genkit spike and shared layer (2026-10-16) | 2 | AIS-43 | AIS-42 is a spike (report, no production code unless adopted) |
| S6 Multi-speaker transcription and AI search (2026-10-16) | 11 | AIS-45, AIS-46, AIS-47, AIS-50, AIS-53 | AIS-44 is a spike; diarization and search lanes run in parallel |
| **Total** | **54 (53 unconditional)** | | Ticket size follows BP §1 rule 2 (about 300–1,500 lines) |

For comparison, the v1 plan has 158 tickets. 1.2.0 was about a quarter of v1's ticket count, with no new native engine work beyond AIS-11 and AIS-24. The 2026-10-16 additions bring it to about a third and add native work in AIS-45 (diarization) and AIS-50 (Vision / ML Kit).

### 6.6 Decisions that need the owner's confirmation

| ID | Question | Recommendation |
|---|---|---|
| D-45 | Privacy model | Master switch off by default; per-provider opt-in; disclosure and Send for every action; nothing automatic |
| D-49 | Usage display | Estimate before sending, recorded tokens after; no prices, no billing |
| D-50 | Sending voice clips | Yes, after disclosure, with size caps; audio-capable models only |
| D-55 | Emoji font | System emoji; AI emoji limited to Emoji ≤ 12.0 |
| D-58 | Emotion labels and mapping | 10 labels, the emoji pools and colours in D-58 |
| D-59 | Speaker labels | **Decided 2026-10-16:** manual, on-device diarization (D-70c), AI suggestions or cloud diarization when AI Studio is on |
| D-70c | Diarization install size and models | Budget set by the owner after AIS-44 measures it |
| D-70e | Overlap words whisper didn't catch | Empty lane cue marked "needs text" |
| D-70h | Send per AI search question | Yes, every time |
| D-70i | Deep indexing content | Photo thumbnails, document text, captions; video keyframes only if the owner agrees |
| D-60 | Bundled fonts | About 8 MB of non-CJK Noto; system CJK; no font packs unless asked (AIS-27) |
| D-61 | Font import reminder | Reminder on every import; warn, don't block, on restricted fsType |
| D-63 | Store declarations | Conservative labels; owner and legal choose; demo key decision; report option |
| D-66 | Endpoints | Five fixed provider hosts; no custom endpoints in 1.2.0 |

---

## 7. Additions of 2026-10-16: multi-speaker transcription, AI search, shared AI layer, Genkit spike

The owner approved these on 2026-10-16. They follow the D-45 privacy model without exceptions:
- **Send consent:** nothing that leaves the device is sent without a disclosure and a tap on Send.
- **Disclosure equals payload:** every disclosure is built from the prepared request bytes, and the transport refuses any body whose hash isn't in the consent (AIS-08).
- **Network guard:** with AI Studio off, the only network use is a consented model download; AIS-54 extends AIS-37's spy to cover every new feature.
- **Keys only to their own provider:** unchanged (D-46, D-47, D-66).

### 7.1 D-70a · Shared `danaview_ai` layer and one switch

**Why.** AI Studio was an editor feature. Search (this release) and the camera and documents (1.3.0) need the same switch, keys, consent, transport and usage ledger. Building them twice would mean two consent paths to audit.

**Design.**
- **`packages/danaview_ai`** (pure Dart) holds what every feature shares:
  - `AiStudioSwitch`: the one master switch, stored in prefs `ai.enabled` (migrated from `editor.ai.enabled`). While off, `aiClientProvider` returns `AiOff`, and no feature can build a provider.
  - `AiFeature` registry: `editor`, `search`, later `camera` and `documents`. Each feature declares the contracts it may send and the capabilities it needs (text, audio, image, embeddings).
  - `AiClient`: plan → disclose → send over `danaview_ai_providers` (prepared requests, consent tickets, transport). It adds two calls the editor didn't need: `embed(texts | images)` and image parts in `LlmRequest`.
  - The usage ledger moves here (one ledger per provider, all features).
- **`packages/danaview_ai_ui`** (Flutter): the one send view (`ai_send_view.dart`) and the AI Studio settings (U1–U3), moved out of `danaview_editor` (rule 17, §3.1). The settings route becomes **Settings › AI Studio**; Settings › Video editor keeps a row that opens it.
- `danaview_ai_studio` stays the editor's feature module, now built on `danaview_ai`.
- **Capabilities** (D-48) gain `imageInput` and `embeddings`.
- **Platforms:** iOS and Android in 1.2.0 (the key store is iOS and Android only, D-46). Desktop AI follows the desktop editor.

### 7.2 D-70b · Genkit Dart spike first

**Facts as given by the owner [VERIFY: AIS-42].** Genkit Dart 1.0 (`pub.dev/packages/genkit`, Apache-2.0), with plugins `genkit_google_genai`, `genkit_openai`, `genkit_anthropic` and `genkit_mcp`. It offers structured output, tools, streaming and embeddings; agents and sessions are experimental.

**Spike criteria (all must pass to adopt):**

| # | Criterion | How the spike checks it |
|---|---|---|
| 1 | Our guarded HTTP client can be injected, and the exact request bytes can be seen and hashed before sending | A Genkit call through `HttpTransport` against the loopback fake; the body hash must match the consent's hash, and a changed byte must be refused |
| 2 | User-supplied keys, client-side only | Keys passed per call from `AiKeyStore`, never in env, files or logs |
| 3 | OpenRouter and xAI through the OpenAI plugin with a custom base URL | The base URL is set by us to the D-66 host (`openrouter.ai`, `api.x.ai`), never by the user |
| 4 | Dependency weight | Transitive packages, licences, Flutter-free, AOT size delta; no telemetry, tracing exporter or developer reflection server in release builds |
| 5 | Embeddings and multimodal input | Text and image embeddings, image and audio parts, structured output in schema mode for each of the five providers |

**Rule.**
- If every criterion passes, Genkit is used **behind our own interface**: `LlmProvider` (D-48) stays, a new `danaview_ai_genkit` package implements it with Genkit, and only that package imports Genkit (rule 19). AIS-09 and AIS-10 then build Genkit-backed adapters, and their hand-written golden-request fixtures stay exactly as specified.
- If the transport can't be controlled (criterion 1 or 2 fails), the custom adapters AIS-08…AIS-10 are built as written, and D-47 (no vendor SDKs) stands.
- A partial pass (for example Gemini only) is allowed only if the owner agrees; the default is all or nothing, so there is one code path to audit.
- Tools, agents, sessions, MCP and streaming are not used in 1.2.0 either way.

### 7.3 D-70c, D-70e · On-device diarization and word-to-speaker assignment

**Pipeline** (all on device, after whisper, on the same 16 kHz mono WAV that v1's speech extraction already produces):

```
speech WAV (16 kHz mono, per media unit, AI-12)
  ├─► whisper (v1) ──► words with source-µs timestamps (TranscriptWord, AI-10)
  └─► segmentation (pyannote segmentation 3.0, 10 s windows, multi-speaker frames incl. overlap)
        └─► speaker embeddings per speech region ──► clustering (count given or estimated, ≤ 8)
              └─► speaker timeline: [(speaker, start, end)] with overlapping regions kept
words + speaker timeline ──► assignment ──► per-speaker drafts ──► per-speaker lanes (D-70f)
```

**Engine and models [VERIFY: AIS-44].**
- **sherpa-onnx** (Apache-2.0), used through FFI in a small `danaview_diarization` plugin (or the `sherpa_onnx` Dart package if its size and API fit), with ONNX Runtime underneath.
- **pyannote segmentation 3.0** (MIT), the ONNX export for sherpa-onnx. It detects overlapping speech (up to 3 speakers per 10 s window).
- **A speaker-embedding model**, chosen by the spike from the sherpa-onnx-supported families (3D-Speaker, WeSpeaker, NeMo) on accuracy, size and licence.
- **Download once, with consent,** through v1's downloader (AI-09) and consent view (§16.3 pattern), from a pinned Hugging Face revision so the privacy policy's hosts don't change. Stored with the speech models, backup-excluded (D-20).
- **Install size:** the model files are downloaded, but ONNX Runtime and sherpa-onnx code ship inside the app (iOS can't download code). AIS-44 measures the increase; the owner sets the budget **[OWNER]**.
- **Speed target:** diarization ≤ 0.3× real time on the mid tier (a 10-minute video in ≤ 3 minutes), measured in AIS-44. Tiers that miss it hide "Detect speakers".

**Word-to-speaker assignment (D-70e).**
1. A word inside a single-speaker region goes to that speaker.
2. A word in an overlap region goes to the speaker with the highest frame activity over the word's span (from the segmentation output).
3. Every other speaker active in the overlap still gets **their own cue on their own lane**, timed exactly to their active region (on the frame grid). If whisper produced words for them, those words go in; if not (whisper usually transcribes the louder voice), the cue is created empty and marked **"needs text"** for review **[OWNER: or a placeholder such as "[overlapping speech]"]**.
4. Overlapping speech is **never merged** into one cue.
5. Cues are then segmented per speaker with AI-11's segmenter (words kept, AIS-15), so line length and timing rules hold on each lane.

**Entry points.** Auto captions gains "Detect speakers" (off until the pack is downloaded; then remembered). An existing caption track can be split into speaker lanes with "Detect speakers…" from the track menu.

### 7.4 D-70f · Per-speaker subtitle lanes

**Model.** v1 cues on one track never overlap (ARCH I2), and v1's import already spills overlaps onto a second track. Lanes reuse that: **one subtitle track per speaker**, grouped.
- `SubtitleTrackData` gains `speakerLane {groupId, speakerId, laneIndex}` (optional, additive, part of schema 2 because 1.2.0 hasn't shipped; AIS-04 pins the key). The group's speaker table (names, colours) is shared; renaming a speaker renames the lane.
- Each lane has its own `SubtitleStyle` (per-speaker style: font, colour, box, position). A "Match lanes" action copies one lane's style to the others.
- **Placement when two lanes speak at once:** lane 1 sits at its position; each further lane active at the same time stacks above it by its line height, so overlapping cues never cover each other. Lanes can also be placed left and right (conversation layout). Dynamic stacking (a lane drops down when the other is silent) is evaluated in AIS-47 **[VERIFY]**; the fallback is fixed slots.
- **Commands:** `CreateSpeakerLanes(source | drafts)`, `SetLaneStyle`, `RenameSpeaker`, `MergeSpeakers` (moves cues to one lane, re-checking overlap), `MoveCuesToSpeaker`. One history entry each.
- **Export:**
  - Burn-in: each lane lowers like any subtitle track (no RenderPlan change).
  - SRT/VTT: the group exports as **one file** with overlapping cues allowed (both formats permit it), sorted by start, with `<v Name>` in VTT and `NAME: ` in SRT (D-54); or one file per speaker (option).
- **Karaoke and rich text** work per lane as on any track.

### 7.5 D-70g · Optional cloud diarization

When AI Studio is on and the chosen model has `audioInput`, "Detect speakers" offers **"With {Provider} (sends audio)"** next to "On this device".
- Contract `dv.diarize.v1`: input is audio windows of about 2 minutes (D-50 sizes and caps) plus the whisper words with ids; output is `{segments:[{speaker, start, end}], words:[{id, speaker}], extra:[{speaker, start, end, text}]}`. `extra` lets the model transcribe a quieter overlapping voice that whisper missed; those cues are marked "from {Provider}" in review.
- The roster is carried across windows, as `dv.speakers.v1`. At most 8 speakers. Names only when spoken (D-59).
- Behind the usual disclosure and Send (audio length and bytes shown). The output goes through review like every suggestion (D-64), then into the same lanes (D-70f).

### 7.6 D-70d · On-device search index

**What is indexed** (per library item of the Files & Media Home, HOM-16):

| Source | iOS / iPadOS / macOS | Android | Windows / Linux (1.2.0) |
|---|---|---|---|
| Names, folders, type, dates, size, dimensions, duration | library database | library database | library database |
| Image labels ("dog", "beach") | Apple Vision `VNClassifyImageRequest` | ML Kit image labeling (bundled model) | – |
| Text in photos and scans (OCR) | Apple Vision `VNRecognizeTextRequest` | ML Kit text recognition v2 (bundled Latin; other scripts as separate bundled models **[VERIFY: AIS-50]**) | – |
| Document text | PDFKit text; plain text, CSV | `PdfRenderer` text where available, else none; plain text, CSV | plain text, CSV |
| Captions and transcripts | project captions; transcript cache | same | – |
| Photo metadata | EXIF date, camera, place name only if the photo already has GPS and the user turns on "Search by place" (reverse geocoding is a network call, so it's off by default and disclosed) | same | – |

**Rules.**
- Indexing runs in the background while charging or idle, in small batches, and pauses when the app is busy (playback, export). It never sends anything.
- The index lives in the library database (HOM-17) as full-text tables **[VERIFY: AIS-50]**, is **excluded from backups** (it can be rebuilt), and can be rebuilt or deleted in Settings.
- `danaview_media_analysis` (Pigeon plugin) wraps Vision and ML Kit; the 1.3.0 camera's document OCR reuses it (NATIVE_CAMERA_PLAN D-115b).
- ML Kit must make no network requests of its own in our configuration **[VERIFY: AIS-50]** (device network spy; RS18).
- Linked folders (HOM §8.1) are indexed only while the app still has access to them.

### 7.7 D-70h · AI search level (a): query to filters

- A "Search with AI" chip appears under the search field when AI Studio is on.
- **What is sent: only the typed question**, plus the fixed filter schema and today's date. No file names, folder names, labels found in the library, counts or any other library data. The disclosure shows the question exactly as it will be sent.
- Contract `dv.search.filters.v1` returns structured filters: `{kinds[], subKinds[], dateFrom?, dateTo?, terms[], labels[], textContains[], people?: never, folderHint?, sizeMin?, sizeMax?, sort?}`. Labels and folder hints come back as plain words and are matched **locally** (synonyms table, folder-name match), so the model never sees the library.
- The filters run over the local index; results appear as usual, with the filter chips shown and editable.
- Send on every question **[OWNER]** (§6.2 question 13).

### 7.8 D-70i · AI search level (b): deep indexing per folder

- **Explicit per folder:** folder menu ▸ "Deep index with AI…". Never automatic, never for the whole library at once, and new files added later are not sent until the user runs it again ("12 new items not yet deep-indexed · Index now").
- **What is sent** (each item is listed by type and count in the disclosure):
  - photos: a 512 px JPEG thumbnail, no EXIF;
  - documents: extracted text, at most 4,000 characters per document;
  - videos: captions and transcripts, plus 3 keyframes as thumbnails only if the owner agrees **[OWNER]**;
  - never: file names, folder names, locations, other folders.
- **What comes back:** a short description per item (multimodal model, schema mode) and an embedding vector per item (provider embeddings). Both are stored locally in the index and can be removed per folder ("Remove deep index").
- **Search with a deep index:** the typed question is embedded by the same provider (the question is sent, as level a, with its own Send), then compared locally with the stored vectors (cosine similarity; brute force is fast enough below 100,000 items).
- **Estimate first:** the disclosure shows items, bytes, estimated input tokens (images at the provider's per-image rate **[VERIFY: AIS-53]**) and embedding counts; above 200k tokens Send needs a second tap (D-49). Batches are resumable, and a resumed job asks again.

### 7.9 Tickets AIS-42 to AIS-54

#### AIS-42 · Spike: Genkit Dart 1.0 behind `LlmProvider`

- **Milestone:** S1+ · **Area:** AI providers · first provider ticket, runs before AIS-08
- **Depends on:** AIS-01
- **Owns:** `docs/v1.2/ai-studio/spikes/AIS-42-genkit.md`; a throwaway spike package outside `packages/` (deleted after the report)
- **Spec:** D-70b. Run criteria 1–5 against the loopback fake server for Gemini, OpenAI, Anthropic, and OpenRouter and xAI through the OpenAI plugin. Record versions, transitive dependencies, licences and the AOT size delta.
- **Acceptance criteria and tests:** a report with pass/fail per criterion and provider, evidence for the hash check, and a go/no-go. The owner signs the outcome; AIS-01's ARCH record notes it.

#### AIS-43 · [INTEGRATION] Shared `danaview_ai` layer, `danaview_ai_ui`, app-level switch, feature registry

- **Milestone:** S1+ · **Area:** Integration
- **Depends on:** AIS-01, AIS-08
- **Owns:** `packages/danaview_ai/`, `packages/danaview_ai_ui/`, `test/architecture/dependency_rules_test.dart` (rules 16–19), the call-site test moved from `danaview_editor` (rule 17)
- **Spec:** D-70a. `AiStudioSwitch` (prefs `ai.enabled`, one-time migration from `editor.ai.enabled`), `AiFeature` registry, `AiClient` (`plan`, `send`, `embed`), image parts and the `imageInput`/`embeddings` capabilities, the shared usage ledger. Moves the send view and settings files of AIS-31/AIS-32 to `danaview_ai_ui` before those tickets start.
- **Acceptance criteria and tests:** with the switch off, no feature can build a provider (provider test); every planted rule violation fails the architecture test; the editor's AI flows compile against the moved send view.

#### AIS-44 · Spike: on-device diarization with sherpa-onnx

- **Milestone:** S6 · **Area:** AI (diarization)
- **Depends on:** AIS-01, AI-10
- **Owns:** `docs/v1.2/ai-studio/spikes/AIS-44-diarization.md`, an eval set manifest `docs/v1.2/ai-studio/qa/diarization_eval.md` (CC-licensed or owner-recorded clips with overlaps)
- **Spec:** D-70c. Closes V-S17, V-S18, V-S19: model candidates, licences, sizes, Hugging Face mirror, overlap output, install-size delta, real-time factor on three tiers, diarization error rate on the eval set.
- **Acceptance criteria and tests:** a report with a recommended model pair and the numbers; the owner sets the install-size budget **[OWNER]**.

#### AIS-45 · `danaview_diarization` plugin and the consented speaker-model download

- **Milestone:** S6 · **Area:** Native (iOS + Android)
- **Depends on:** AIS-44, AI-09
- **Owns:** `packages/danaview_diarization/` (FFI bindings, iOS and Android builds, `PrivacyInfo.xcprivacy`), `SpeakerModelSpec` entries next to the whisper model specs
- **Spec:** `diarize(wavPath, {numSpeakers?, maxSpeakers 8}) → SpeakerTimeline` on a background isolate, cancellable, with progress. Model download through v1's downloader and consent view (pinned revision and SHA-256).
- **Acceptance criteria and tests:** native and Dart tests on the simulator and emulator with fixture audio; zero network before consent (spy); a cancelled job leaves no files behind; rule 18 grep green.

#### AIS-46 · Diarization pipeline, word-to-speaker assignment and overlap cues

- **Milestone:** S6 · **Area:** AI (diarization)
- **Depends on:** AIS-45, AIS-15
- **Owns:** `packages/danaview_transcription/lib/src/speakers/` (assignment, overlap cue builder, per-speaker segmentation), its tests
- **Spec:** D-70e. Steps 1–5 of §7.3; source-µs to timeline mapping through `ClipTimeMap` (AI-12); "needs text" marks per the owner's answer.
- **Acceptance criteria and tests:** on the eval set, every overlap region yields one cue per active speaker with edges within 1 frame of the speaker timeline; no cue holds words from two speakers; property tests (every word assigned exactly once; lanes non-overlapping).

#### AIS-47 · Per-speaker subtitle lanes: model, commands, lowering, SRT/VTT rules

- **Milestone:** S6 · **Area:** Core (pure Dart)
- **Depends on:** AIS-46, AIS-06, AIS-07, AIS-14
- **Owns:** `packages/danaview_editor_core/lib/src/ops/commands/speaker_lane_commands.dart`, lane fields in `model/subtitle.dart` (extends AIS-02, coordinated with AIS-04's schema keys), lane stacking in `plan/lowering_text.dart` (extends AIS-14), group export in `formats/` (extends AIS-07)
- **Spec:** D-70f. Lane model, commands, stacking for concurrent lanes (dynamic stacking only if the spike in this ticket proves it; else fixed slots), single-file and per-speaker SRT/VTT export.
- **Acceptance criteria and tests:** goldens for two and three concurrent lanes (no collisions); one history entry per command; overlapping SRT/VTT round trip; v1 tracks unchanged.

#### AIS-48 · Speaker lanes UI

- **Milestone:** S6 · **Area:** UI/UX
- **Depends on:** AIS-47, AIS-18
- **Owns:** `packages/danaview_editor/lib/src/editor/panels/speakers/`, the "Detect speakers" option in the Auto captions flow
- **Spec:** "Detect speakers" (on device, or with a provider when AI Studio is on), lane headers on the timeline with speaker names and colours, per-lane style, rename and merge, an overlap review list that jumps to every "needs text" cue.
- **Acceptance criteria and tests:** widget tests for every state (pack missing, downloading, running, done, failed); matrix tests at 280–1280 px and text 0.85–1.35; a11y labels announce speaker names.

#### AIS-49 · Cloud diarization contract `dv.diarize.v1`

- **Milestone:** S6 · **Area:** AI Studio
- **Depends on:** AIS-46, AIS-28, AIS-29
- **Owns:** `packages/danaview_ai_studio/lib/src/actions/diarize/`, its fixtures
- **Spec:** D-70g. Windows, roster carry-over, `extra` cues, validation (ids, times inside the window, ≤ 8 speakers, names only when spoken), mapping into lane suggestions.
- **Acceptance criteria and tests:** good, bad and adversarial fixtures as AIS-29; disclosure equals payload; nothing applied without review.

#### AIS-50 · On-device search index

- **Milestone:** S6 · **Area:** Search
- **Depends on:** AIS-01, HOM-16, HOM-17
- **Owns:** `packages/danaview_media_analysis/` (Pigeon; Vision on iOS/macOS, ML Kit on Android), `packages/danaview_search/lib/src/index/`
- **Spec:** D-70d. Extractors per source in §7.6, background scheduler, index tables in the library database, rebuild and delete. Closes V-S20 and V-S21.
- **Acceptance criteria and tests:** a 10,000-item fixture library indexes in the background without dropped frames in the Home grid; device network spy shows zero requests during indexing; the index is backup-excluded.

#### AIS-51 · Search engine and Home search UI

- **Milestone:** S6 · **Area:** Search
- **Depends on:** AIS-50, HOM-19
- **Owns:** `packages/danaview_search/lib/src/query/`, the search screen in `danaview_features` (extends HOM-19's search field)
- **Spec:** as-you-type search over names, labels, OCR text, document text, captions and transcripts; filter chips (type, date, folder); result snippets showing where the match is.
- **Acceptance criteria and tests:** search eval set (`docs/v1.2/ai-studio/qa/search_eval.md`) top-5 recall recorded; results in ≤ 100 ms on 10,000 items on the mid tier; matrix and a11y tests.

#### AIS-52 · AI search (a): query to filters

- **Milestone:** S6 · **Area:** Search + AI Studio
- **Depends on:** AIS-51, AIS-43, AIS-28
- **Owns:** `packages/danaview_search/lib/src/ai/filters_contract.dart`, the "Search with AI" chip and its disclosure
- **Spec:** D-70h. `dv.search.filters.v1`, local matching of labels and folder hints, editable filter chips.
- **Acceptance criteria and tests:** the request body contains only the question, the schema and the date (test inspects the prepared bytes); adversarial outputs rejected; no send without Send (spy).

#### AIS-53 · AI search (b): deep indexing per folder

- **Milestone:** S6 · **Area:** Search + AI Studio
- **Depends on:** AIS-52
- **Owns:** `packages/danaview_search/lib/src/ai/deep_index/`, the folder menu entry and progress UI
- **Spec:** D-70i. Item selection per folder, thumbnails and text extraction, batching and resume, descriptions and embeddings, local vector search, "Remove deep index". Closes V-S22.
- **Acceptance criteria and tests:** the disclosure lists exactly what the batches contain; file names and EXIF never appear in a body (test); removing the deep index deletes every stored description and vector; resumed jobs require a new Send.

#### AIS-54 · Diarization and search QA, network guard extension, on-device E2E

- **Milestone:** S6 · **Area:** QA
- **Depends on:** AIS-48, AIS-49, AIS-53, AIS-37
- **Owns:** `integration_test/ai/speakers/`, `integration_test/ai/search/`, `docs/v1.2/ai-studio/qa/s6_report.md`
- **Spec:** E2E on the iOS Simulator and Android Emulator with the loopback fake provider: detect speakers on an overlap clip, review "needs text" cues, export burn-in and VTT; index a fixture library, search offline, AI filters, deep index one folder. Network guard: AI Studio off → only the consented model download; on → nothing before Send; each send goes to the chosen host only.
- **Acceptance criteria and tests:** every scenario passes on both platforms with evidence; the guard is green; the eval numbers from AIS-44 and AIS-51 are recorded in the report.
